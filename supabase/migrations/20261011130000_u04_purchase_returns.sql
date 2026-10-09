-- =============================================================================
-- U04 · Purchase returns (EC-56, D57)
--
-- Goods go back to the supplier against an approved purchase invoice, from the invoice's branch:
-- picked lines and quantities (exact units for serialized lines), never more than bought minus
-- what was returned before (RETURN_QTY_EXCEEDED). Stock leaves once (purchase_return_out at the
-- invoice's net unit cost); tax and gross per line come from app.return_line_tax (D41) so all the
-- returns of a line add back to it. The moving average is recomputed (user decision): with Q on
-- hand (every branch and state) and average A before the return, r units at cost c give
-- (Q*A - r*c) / (Q - r), half-up to 4 places, never below 0; Q - r <= 0 keeps A.
-- Refund: supplier_credit lowers the supplier balance (baseline views; it may go negative), or
-- cash: +total into an active safe or bank of the branch (or a shop-wide bank) as a
-- supplier_refund movement, the supplier balance unchanged. Numbered PR; idempotent by key.
-- Also the accounts read for U04 and U03 (list_payable_cash_accounts). Reads: any purchasing read
-- key (D53), the caller's branches; also in an expired shop. Numbered after K01 (D39).
-- =============================================================================

-- 1. JSON for the API --------------------------------------------------------------------------------

CREATE FUNCTION app.purchase_return_json(p_org uuid, p_id uuid, p_with_lines boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', r.id, 'number', r.number, 'purchase_invoice_id', r.purchase_invoice_id,
        'invoice_number', i.number, 'supplier_id', r.supplier_id, 'supplier_name', s.name,
        'branch_id', r.branch_id, 'refund_mode', r.refund_mode, 'cash_account_id', r.cash_account_id,
        'cash_account_name', a.name, 'subtotal', r.subtotal::text, 'tax_total', r.tax_total::text,
        'total', r.total::text, 'reason', r.reason, 'business_date', r.business_date,
        'created_by_name', e.full_name, 'created_at', r.created_at)
        || CASE WHEN p_with_lines THEN jsonb_build_object('lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'invoice_line_id', l.invoice_line_id, 'product_id', l.product_id,
                'name_ar', p.name_ar, 'name_en', p.name_en, 'sku', p.sku, 'unit_id', l.unit_id,
                'serial', u.serial, 'quantity', l.quantity, 'unit_cost', l.unit_cost::text,
                'tax_amount', l.tax_amount::text, 'net', (l.line_total - l.tax_amount)::numeric(18,2)::text,
                'line_total', l.line_total::text)
                ORDER BY p.name_ar, l.product_id, u.serial NULLS FIRST, l.id)
            FROM public.purchase_return_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
            WHERE l.organization_id = p_org AND l.return_id = r.id), '[]'::jsonb))
           ELSE jsonb_build_object('lines_count', (
            SELECT count(*) FROM public.purchase_return_lines l
            WHERE l.organization_id = p_org AND l.return_id = r.id)) END
    FROM public.purchase_returns r
    JOIN public.purchase_invoices i ON i.id = r.purchase_invoice_id AND i.organization_id = r.organization_id
    JOIN public.suppliers s ON s.id = r.supplier_id AND s.organization_id = r.organization_id
    LEFT JOIN public.cash_accounts a ON a.id = r.cash_account_id AND a.organization_id = r.organization_id
    LEFT JOIN public.employees e ON e.id = r.created_by AND e.organization_id = r.organization_id
    WHERE r.organization_id = p_org AND r.id = p_id
$$;

-- What was already returned of each line of an invoice.
CREATE FUNCTION app.returned_by_line(p_org uuid, p_invoice_id uuid)
RETURNS TABLE (invoice_line_id uuid, qty integer, tax numeric, gross numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT l.invoice_line_id, sum(l.quantity)::integer, sum(l.tax_amount), sum(l.line_total)
    FROM public.purchase_return_lines l
    JOIN public.purchase_returns r ON r.id = l.return_id AND r.organization_id = l.organization_id
    WHERE l.organization_id = p_org AND r.purchase_invoice_id = p_invoice_id
    GROUP BY l.invoice_line_id
$$;

-- A cash account money can move through for a branch: an active safe or bank of that branch, or
-- a shop-wide bank. Shared by U04's cash refunds and U03's payments.
CREATE FUNCTION app.payable_cash_account(p_org uuid, p_id uuid, p_branch_id uuid)
RETURNS public.cash_accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_a public.cash_accounts;
BEGIN
    SELECT * INTO v_a FROM public.cash_accounts a WHERE a.id = p_id AND a.organization_id = p_org FOR UPDATE;
    IF NOT FOUND OR v_a.kind NOT IN ('safe', 'bank')
       OR (v_a.branch_id IS DISTINCT FROM p_branch_id AND NOT (v_a.kind = 'bank' AND v_a.branch_id IS NULL)) THEN
        RAISE EXCEPTION 'VAULT_INVALID' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_a.is_active THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_a;
END;
$$;

-- 2. Posting -----------------------------------------------------------------------------------------

-- p_lines: [{invoice_line_id, quantity}] for normal lines, [{invoice_line_id, unit_ids: [...]}]
-- for serialized ones (decision 4: units this line created, in stock in the invoice's branch).
CREATE FUNCTION public.post_purchase_return(p_invoice_id uuid, p_refund_mode text, p_reason text, p_lines jsonb,
                                            p_idempotency_key text, p_cash_account_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_r public.purchase_returns; v_a public.cash_accounts;
    v_reason text; v_mode public.purchase_refund_mode; v_date date; e jsonb; r record; u record;
    v_line public.purchase_invoice_lines; v_serialized boolean; v_prev_qty integer; v_prev_tax numeric;
    v_prev_gross numeric; v_qty integer; v_tax jsonb; v_rl uuid; v_lines jsonb := '[]'; v_plan jsonb := '[]';
    v_net numeric; v_taxes numeric;
    v_q bigint; v_avg numeric(18,4); v_new numeric(18,4); v_raw numeric; v_costs jsonb := '[]';
BEGIN
    v_emp := app.require_permission('purchase.return_create');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_r FROM public.purchase_returns x
    WHERE x.organization_id = v_org AND x.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.purchase_return_json(v_org, v_r.id, true);     -- a repeat changes nothing
    END IF;

    SELECT * INTO v_i FROM public.purchase_invoices x WHERE x.id = p_invoice_id AND x.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_i.branch_id);
    IF v_i.status <> 'approved' THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_APPROVED: the invoice is %', v_i.status USING ERRCODE = 'P0001';
    END IF;
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500
       OR p_refund_mode IS NULL OR p_refund_mode NOT IN ('supplier_credit', 'cash')
       OR (p_refund_mode = 'cash') <> (p_cash_account_id IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: return' USING ERRCODE = 'P0001';
    END IF;
    v_mode := p_refund_mode::public.purchase_refund_mode;
    IF v_mode = 'cash' THEN
        v_a := app.payable_cash_account(v_org, p_cash_account_id, v_i.branch_id);
    END IF;

    -- The lines' shape: objects with invoice_line_id and exactly one of quantity / unit_ids.
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) x
                  WHERE jsonb_typeof(x) <> 'object'
                     OR EXISTS (SELECT 1 FROM jsonb_object_keys(x) k WHERE k NOT IN ('invoice_line_id', 'quantity', 'unit_ids'))
                     OR jsonb_typeof(x -> 'invoice_line_id') IS DISTINCT FROM 'string'
                     OR (x ? 'quantity') = (x ? 'unit_ids')
                     OR (x ? 'quantity' AND CASE WHEN jsonb_typeof(x -> 'quantity') = 'number'
                                                 THEN (x ->> 'quantity')::numeric <> trunc((x ->> 'quantity')::numeric)
                                                      OR (x ->> 'quantity')::numeric NOT BETWEEN 1 AND 1000000
                                                 ELSE true END)
                     OR (x ? 'unit_ids' AND (jsonb_typeof(x -> 'unit_ids') <> 'array'
                                             OR jsonb_array_length(x -> 'unit_ids') < 1
                                             OR EXISTS (SELECT 1 FROM jsonb_array_elements(x -> 'unit_ids') ui
                                                        WHERE jsonb_typeof(ui) <> 'string'))))
       OR (SELECT count(DISTINCT x ->> 'invoice_line_id') FROM jsonb_array_elements(p_lines) x) <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
        PERFORM (x ->> 'invoice_line_id')::uuid, ui::text::uuid
        FROM jsonb_array_elements(p_lines) x
        LEFT JOIN LATERAL jsonb_array_elements_text(COALESCE(x -> 'unit_ids', '[]')) ui ON true;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END;

    -- Pass 1, product order (an invoice has each product once): check every line and work out
    -- its return rows (tax split unit by unit for serials) before anything is written; the
    -- header is append-only, so it is inserted with its final totals.
    FOR e IN SELECT x FROM jsonb_array_elements(p_lines) x
             LEFT JOIN public.purchase_invoice_lines l
                    ON l.id = (x ->> 'invoice_line_id')::uuid AND l.organization_id = v_org AND l.invoice_id = v_i.id
             ORDER BY l.product_id NULLS FIRST LOOP
        SELECT * INTO v_line FROM public.purchase_invoice_lines l
        WHERE l.id = (e ->> 'invoice_line_id')::uuid AND l.organization_id = v_org AND l.invoice_id = v_i.id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: a line is not on this invoice' USING ERRCODE = 'P0001';
        END IF;
        SELECT p.is_serialized INTO v_serialized FROM public.products p WHERE p.id = v_line.product_id;
        IF v_serialized <> (e ? 'unit_ids') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: % needs %', v_line.id,
                CASE WHEN v_serialized THEN 'unit_ids' ELSE 'quantity' END USING ERRCODE = 'P0001';
        END IF;
        v_qty := CASE WHEN v_serialized THEN jsonb_array_length(e -> 'unit_ids') ELSE (e ->> 'quantity')::integer END;
        SELECT COALESCE(sum(rl.quantity), 0)::integer, COALESCE(sum(rl.tax_amount), 0), COALESCE(sum(rl.line_total), 0)
        INTO v_prev_qty, v_prev_tax, v_prev_gross
        FROM public.purchase_return_lines rl
        WHERE rl.organization_id = v_org AND rl.invoice_line_id = v_line.id;
        IF v_qty > v_line.quantity - v_prev_qty THEN
            RAISE EXCEPTION 'RETURN_QTY_EXCEEDED: % can take % more', v_line.id, v_line.quantity - v_prev_qty
                USING ERRCODE = 'P0001',
                      DETAIL = jsonb_build_object('invoice_line_id', v_line.id,
                                                  'returnable', v_line.quantity - v_prev_qty)::text;
        END IF;
        v_lines := v_lines || jsonb_build_object('product_id', v_line.product_id, 'qty', v_qty,
                                                 'unit_cost', v_line.unit_cost);

        IF v_serialized THEN
            IF (SELECT count(DISTINCT ui) FROM jsonb_array_elements_text(e -> 'unit_ids') ui) <> v_qty
               OR (SELECT count(*) FROM public.units un WHERE un.organization_id = v_org
                     AND un.id IN (SELECT ui::uuid FROM jsonb_array_elements_text(e -> 'unit_ids') ui)) <> v_qty THEN
                RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            FOR u IN SELECT un.* FROM public.units un
                     WHERE un.organization_id = v_org
                       AND un.id IN (SELECT ui::uuid FROM jsonb_array_elements_text(e -> 'unit_ids') ui)
                     ORDER BY un.id FOR UPDATE LOOP
                IF u.purchase_invoice_line_id IS DISTINCT FROM v_line.id OR u.status <> 'in_stock'
                   OR u.branch_id <> v_i.branch_id THEN
                    RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: % is not in stock here from this invoice line (reserved units are released first)',
                        u.serial USING ERRCODE = 'P0001';
                END IF;
                v_tax := app.return_line_tax(v_line.quantity, v_line.tax_amount, v_line.line_total,
                                             v_prev_qty, v_prev_tax, v_prev_gross, 1);
                v_plan := v_plan || jsonb_build_object('line_id', v_line.id, 'product_id', v_line.product_id,
                    'unit_id', u.id, 'qty', 1, 'unit_cost', v_line.unit_cost,
                    'tax', v_tax ->> 'tax', 'gross', v_tax ->> 'gross');
                v_prev_qty := v_prev_qty + 1;
                v_prev_tax := v_prev_tax + (v_tax ->> 'tax')::numeric;
                v_prev_gross := v_prev_gross + (v_tax ->> 'gross')::numeric;
            END LOOP;
        ELSE
            v_tax := app.return_line_tax(v_line.quantity, v_line.tax_amount, v_line.line_total,
                                         v_prev_qty, v_prev_tax, v_prev_gross, v_qty);
            v_plan := v_plan || jsonb_build_object('line_id', v_line.id, 'product_id', v_line.product_id,
                'unit_id', NULL, 'qty', v_qty, 'unit_cost', v_line.unit_cost,
                'tax', v_tax ->> 'tax', 'gross', v_tax ->> 'gross');
        END IF;
    END LOOP;

    v_date := app.org_today(v_org);
    SELECT COALESCE(sum((p ->> 'gross')::numeric - (p ->> 'tax')::numeric), 0), COALESCE(sum((p ->> 'tax')::numeric), 0)
    INTO v_net, v_taxes FROM jsonb_array_elements(v_plan) p;
    INSERT INTO public.purchase_returns (organization_id, number, purchase_invoice_id, supplier_id, branch_id,
        refund_mode, cash_account_id, subtotal, tax_total, total, reason, business_date, idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, v_i.branch_id, 'purchase_return'), v_i.id, v_i.supplier_id,
        v_i.branch_id, v_mode, p_cash_account_id, v_net, v_taxes, v_net + v_taxes, v_reason, v_date,
        p_idempotency_key, v_emp)
    RETURNING * INTO v_r;

    -- Pass 2, product order: the average before the stock leaves (decision 1), then the rows.
    FOR r IN SELECT (x ->> 'product_id')::uuid AS product_id, (x ->> 'qty')::integer AS qty,
                    (x ->> 'unit_cost')::numeric AS unit_cost
             FROM jsonb_array_elements(v_lines) x ORDER BY 1 LOOP
        SELECT p.avg_cost INTO v_avg FROM public.products p
        WHERE p.id = r.product_id AND p.organization_id = v_org FOR UPDATE;
        SELECT COALESCE(sum(sl.on_hand), 0) INTO v_q FROM public.stock_levels sl
        WHERE sl.organization_id = v_org AND sl.product_id = r.product_id;
        IF v_q - r.qty > 0 THEN
            v_raw := round((v_q * v_avg - r.qty * r.unit_cost) / (v_q - r.qty), 4);
            v_new := greatest(v_raw, 0);
        ELSE
            v_raw := NULL;
            v_new := v_avg;
        END IF;
        IF v_new IS DISTINCT FROM v_avg THEN
            UPDATE public.products p SET avg_cost = v_new, updated_by = v_emp WHERE p.id = r.product_id;
        END IF;
        v_costs := v_costs || jsonb_build_object('product_id', r.product_id, 'before', v_avg::text,
                                                 'after', v_new::text, 'clamped', v_raw IS NOT NULL AND v_raw < 0);

        FOR e IN SELECT x FROM jsonb_array_elements(v_plan) x
                 WHERE (x ->> 'product_id')::uuid = r.product_id ORDER BY x ->> 'unit_id' NULLS FIRST LOOP
            INSERT INTO public.purchase_return_lines (organization_id, return_id, invoice_line_id, product_id,
                unit_id, quantity, unit_cost, tax_amount, line_total, created_by)
            VALUES (v_org, v_r.id, (e ->> 'line_id')::uuid, r.product_id, (e ->> 'unit_id')::uuid,
                (e ->> 'qty')::integer, r.unit_cost, (e ->> 'tax')::numeric, (e ->> 'gross')::numeric, v_emp)
            RETURNING id INTO v_rl;
            INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type,
                stock_state, unit_cost, source_type, source_id, source_line_id, created_by)
            VALUES (v_org, r.product_id, v_i.branch_id, (e ->> 'unit_id')::uuid, -(e ->> 'qty')::integer,
                'purchase_return_out', 'sellable', r.unit_cost, 'purchase_return', v_r.id, v_rl, v_emp);
        END LOOP;
    END LOOP;
    IF v_mode = 'cash' AND v_r.total > 0 THEN
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                           source_id, note, business_date, created_by, created_at)
        VALUES (v_org, v_a.id, COALESCE(v_a.branch_id, v_i.branch_id), v_r.total, 'supplier_refund',
                'purchase_return', v_r.id, v_r.number, v_date, v_emp, clock_timestamp());
    END IF;

    PERFORM app.write_audit('purchase_return.posted', 'purchase_return', v_r.id, NULL,
        jsonb_build_object('number', v_r.number, 'invoice_number', v_i.number, 'total', v_r.total::text,
                           'refund_mode', v_mode, 'cash_account_id', p_cash_account_id, 'lines', p_lines,
                           'avg_cost', v_costs),
        v_reason, v_i.branch_id);
    RETURN app.purchase_return_json(v_org, v_r.id, true);
END;
$$;

-- 3. Reads -------------------------------------------------------------------------------------------

CREATE FUNCTION public.list_purchase_returns(p_supplier_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
                                             p_purchase_invoice_id uuid DEFAULT NULL, p_from date DEFAULT NULL,
                                             p_to date DEFAULT NULL, p_limit integer DEFAULT 50,
                                             p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_result jsonb;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 OR p_from > p_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_supplier_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.suppliers s WHERE s.id = p_supplier_id AND s.organization_id = v_org) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_purchase_invoice_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.purchase_invoices i WHERE i.id = p_purchase_invoice_id AND i.organization_id = v_org) THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
        END IF;
        v_branches := ARRAY[p_branch_id];
    ELSE
        SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
        FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    END IF;

    WITH found AS (
        SELECT r.id, r.business_date, r.created_at FROM public.purchase_returns r
        WHERE r.organization_id = v_org AND r.branch_id = ANY(v_branches)
          AND (p_supplier_id IS NULL OR r.supplier_id = p_supplier_id)
          AND (p_purchase_invoice_id IS NULL OR r.purchase_invoice_id = p_purchase_invoice_id)
          AND (p_from IS NULL OR r.business_date >= p_from)
          AND (p_to IS NULL OR r.business_date <= p_to)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.purchase_return_json(v_org, f.id, false)
                             ORDER BY f.business_date DESC, f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY business_date DESC, created_at DESC, id DESC
                  LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Another shop's return, or one of a branch the caller doesn't work in: not found.
CREATE FUNCTION public.get_purchase_return(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    SELECT r.branch_id INTO v_branch FROM public.purchase_returns r WHERE r.id = p_id AND r.organization_id = v_org;
    IF NOT FOUND OR NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.purchase_return_json(v_org, p_id, true);
END;
$$;

-- What can still go back from an invoice, line by line, with the units in stock in its branch.
CREATE FUNCTION public.get_returnable_invoice(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_i public.purchase_invoices;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('purchase.return_create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: purchase.return_create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    SELECT * INTO v_i FROM public.purchase_invoices i WHERE i.id = p_invoice_id AND i.organization_id = v_org;
    IF NOT FOUND OR NOT app.has_branch_access(v_i.branch_id) THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object(
        'invoice', app.purchase_invoice_json(v_org, v_i.id, false),
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'invoice_line_id', l.id, 'product_id', l.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'sku', p.sku, 'is_serialized', p.is_serialized, 'purchased', l.quantity,
                'returned', COALESCE(rb.qty, 0), 'returnable', l.quantity - COALESCE(rb.qty, 0),
                'unit_cost', l.unit_cost::text,
                'units_in_stock', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('unit_id', u.id, 'serial', u.serial) ORDER BY u.serial)
                    FROM public.units u
                    WHERE u.organization_id = v_org AND u.purchase_invoice_line_id = l.id
                      AND u.status = 'in_stock' AND u.branch_id = v_i.branch_id), '[]'::jsonb))
                ORDER BY p.name_ar, l.product_id)
            FROM public.purchase_invoice_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            LEFT JOIN app.returned_by_line(v_org, v_i.id) rb ON rb.invoice_line_id = l.id
            WHERE l.organization_id = v_org AND l.invoice_id = v_i.id), '[]'::jsonb));
END;
$$;

-- Decision 8: the active safes and banks money can move through for a branch, with balances.
-- Readable with purchase.return_create or supplier.payment_create; the caller needs the branch.
CREATE FUNCTION public.list_payable_cash_accounts(p_branch_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('purchase.return_create') OR app.has_permission('supplier.payment_create')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: purchase.return_create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_branch_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.has_branch_access(p_branch_id) THEN
        RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object('items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id', a.id, 'name', a.name, 'kind', a.kind, 'branch_id', a.branch_id,
            'balance', COALESCE(cb.balance, 0)::numeric(18,2)::text)
            ORDER BY (a.branch_id IS NULL), a.kind DESC, a.name, a.id)
        FROM public.cash_accounts a
        LEFT JOIN public.cash_balances cb ON cb.cash_account_id = a.id
        WHERE a.organization_id = v_org AND a.is_active AND a.kind IN ('safe', 'bank')
          AND (a.branch_id = p_branch_id OR (a.kind = 'bank' AND a.branch_id IS NULL))), '[]'::jsonb));
END;
$$;

-- 4. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.purchase_return_json(uuid, uuid, boolean), app.returned_by_line(uuid, uuid),
    app.payable_cash_account(uuid, uuid, uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.post_purchase_return(uuid, text, text, jsonb, text, uuid),
    public.list_purchase_returns(uuid, uuid, uuid, date, date, integer, integer),
    public.get_purchase_return(uuid), public.get_returnable_invoice(uuid),
    public.list_payable_cash_accounts(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_purchase_return(uuid, text, text, jsonb, text, uuid),
    public.list_purchase_returns(uuid, uuid, uuid, date, date, integer, integer),
    public.get_purchase_return(uuid), public.get_returnable_invoice(uuid),
    public.list_payable_cash_accounts(uuid)
    TO authenticated;
