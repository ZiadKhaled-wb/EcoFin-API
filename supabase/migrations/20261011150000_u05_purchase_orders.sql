-- =============================================================================
-- U05 · Purchase orders (EC-57, D59)
--
-- A manager or warehouse keeper orders goods from a supplier before they arrive: a draft order
-- with lines and expected costs, sent, then received through purchase invoices made FROM the
-- order (U02 drafts with po_id and line po_line_id). "Received" means approved: only approved
-- invoices count (baseline view v_po_line_received). No over-receipt (user decision): a linked
-- invoice line never exceeds what is still to come, checked when the draft is saved and again at
-- approval under the order's lock (PO_OVER_RECEIPT). Approving an invoice of an order moves it to
-- partially_received or received. Cancel (with a reason) works until the order is received.
-- A PO line can fill a customer's special order line (sales_order_lines.po_line_id); S10 reads
-- app.sales_order_line_po_status. Reads: any purchasing read key (D53), the caller's branches.
-- U02 / U06 functions replaced here keep their behaviour for invoices without an order.
-- =============================================================================

-- 1. JSON for the API --------------------------------------------------------------------------------

CREATE FUNCTION app.purchase_order_json(p_org uuid, p_id uuid, p_with_lines boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', o.id, 'number', o.number, 'supplier_id', o.supplier_id, 'supplier_name', s.name,
        'branch_id', o.branch_id, 'status', o.status, 'expected_date', o.expected_date, 'notes', o.notes,
        'created_by_name', e.full_name, 'created_at', o.created_at, 'updated_at', o.updated_at)
        || CASE WHEN p_with_lines THEN jsonb_build_object(
            'lines', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'id', l.id, 'product_id', l.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
                    'sku', p.sku, 'is_serialized', p.is_serialized, 'quantity', l.quantity,
                    'expected_unit_cost', l.expected_unit_cost::text,
                    'received', r.received, 'remaining', r.remaining,
                    'on_draft_invoices', COALESCE((
                        SELECT sum(il.quantity) FROM public.purchase_invoice_lines il
                        JOIN public.purchase_invoices i ON i.id = il.invoice_id AND i.organization_id = il.organization_id
                        WHERE il.organization_id = p_org AND il.po_line_id = l.id
                          AND i.status IN ('draft', 'pending_approval')), 0),
                    'customer_order', (
                        SELECT jsonb_build_object('order_id', so.id, 'number', so.number, 'line_id', sl.id)
                        FROM public.sales_order_lines sl
                        JOIN public.sales_orders so ON so.id = sl.order_id AND so.organization_id = sl.organization_id
                        WHERE sl.organization_id = p_org AND sl.po_line_id = l.id
                        ORDER BY sl.created_at, sl.id LIMIT 1))
                    ORDER BY p.name_ar, l.product_id)
                FROM public.purchase_order_lines l
                JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
                JOIN public.v_po_line_received r ON r.po_line_id = l.id
                WHERE l.organization_id = p_org AND l.po_id = o.id), '[]'::jsonb),
            'invoices', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number, 'status', i.status,
                                                    'total', i.total::text)
                                 ORDER BY i.created_at, i.id)
                FROM public.purchase_invoices i
                WHERE i.organization_id = p_org AND i.po_id = o.id), '[]'::jsonb))
           ELSE (
            SELECT jsonb_build_object('lines_count', count(*), 'ordered', COALESCE(sum(r.quantity), 0),
                                      'received', COALESCE(sum(r.received), 0))
            FROM public.v_po_line_received r WHERE r.organization_id = p_org AND r.po_id = o.id) END
    FROM public.purchase_orders o
    JOIN public.suppliers s ON s.id = o.supplier_id AND s.organization_id = o.organization_id
    LEFT JOIN public.employees e ON e.id = o.created_by AND e.organization_id = o.organization_id
    WHERE o.organization_id = p_org AND o.id = p_id
$$;

-- What an order's lines are, for the audit: product, quantity, expected cost.
CREATE FUNCTION app.purchase_order_lines_json(p_org uuid, p_po_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', l.product_id, 'quantity', l.quantity,
               'expected_unit_cost', l.expected_unit_cost::text) ORDER BY l.product_id), '[]'::jsonb)
    FROM public.purchase_order_lines l
    WHERE l.organization_id = p_org AND l.po_id = p_po_id
$$;

-- S10 shows this next to a customer's special order line: the purchase order that will fill it.
CREATE FUNCTION app.sales_order_line_po_status(p_org uuid, p_line_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('po_id', o.id, 'number', o.number, 'status', o.status,
                              'ordered', r.quantity, 'received', r.received, 'remaining', r.remaining)
    FROM public.sales_order_lines sl
    JOIN public.purchase_order_lines l ON l.id = sl.po_line_id AND l.organization_id = sl.organization_id
    JOIN public.purchase_orders o ON o.id = l.po_id AND o.organization_id = l.organization_id
    JOIN public.v_po_line_received r ON r.po_line_id = l.id
    WHERE sl.organization_id = p_org AND sl.id = p_line_id
$$;

-- 2. Order lines -------------------------------------------------------------------------------------

-- Checks and stores the lines of a draft order (replacing any old ones).
-- p_lines: 1-200 of {product_id, quantity, expected_unit_cost?, sales_order_line_id?}.
CREATE FUNCTION app.set_purchase_order_lines(p_org uuid, p_emp uuid, p_po public.purchase_orders, p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    e jsonb; v_key text; v_product public.products; v_qty numeric; v_cost text; v_seen uuid[] := '{}';
    v_line uuid; v_sales uuid; v_ok boolean;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    -- Customer order lines pointing at the old lines are released first; kept ones link again below.
    UPDATE public.sales_order_lines sl SET po_line_id = NULL
    WHERE sl.organization_id = p_org
      AND sl.po_line_id IN (SELECT l.id FROM public.purchase_order_lines l
                            WHERE l.organization_id = p_org AND l.po_id = p_po.id);
    DELETE FROM public.purchase_order_lines l WHERE l.organization_id = p_org AND l.po_id = p_po.id;

    FOR e IN SELECT x FROM jsonb_array_elements(p_lines) x LOOP
        IF jsonb_typeof(e) <> 'object' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: line' USING ERRCODE = 'P0001';
        END IF;
        SELECT k INTO v_key FROM jsonb_object_keys(e) k
        WHERE k <> ALL (ARRAY['product_id', 'quantity', 'expected_unit_cost', 'sales_order_line_id']) LIMIT 1;
        IF v_key IS NOT NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;

        SELECT * INTO v_product FROM public.products p
        WHERE p.id = (e ->> 'product_id')::uuid AND p.organization_id = p_org;
        IF NOT FOUND OR v_product.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_product.id = ANY(v_seen) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: duplicate product' USING ERRCODE = 'P0001';
        END IF;
        v_seen := v_seen || v_product.id;

        v_qty := (e ->> 'quantity')::numeric;
        IF jsonb_typeof(e -> 'quantity') <> 'number' OR v_qty IS NULL OR v_qty <> trunc(v_qty)
           OR v_qty < 1 OR v_qty > 100000 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: quantity' USING ERRCODE = 'P0001';
        END IF;
        v_cost := NULL;
        IF e ? 'expected_unit_cost' AND jsonb_typeof(e -> 'expected_unit_cost') <> 'null' THEN
            v_cost := e ->> 'expected_unit_cost';
            IF jsonb_typeof(e -> 'expected_unit_cost') NOT IN ('string', 'number')
               OR v_cost !~ '^\d{1,16}(\.\d{1,2})?$' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: expected_unit_cost' USING ERRCODE = 'P0001';
            END IF;
        END IF;

        INSERT INTO public.purchase_order_lines (organization_id, po_id, product_id, quantity,
                                                 expected_unit_cost, created_by)
        VALUES (p_org, p_po.id, v_product.id, v_qty::integer, v_cost::numeric, p_emp)
        RETURNING id INTO v_line;

        -- Decision 5: the line fills a customer's special order line.
        IF e ? 'sales_order_line_id' AND jsonb_typeof(e -> 'sales_order_line_id') <> 'null' THEN
            v_sales := (e ->> 'sales_order_line_id')::uuid;
            SELECT (sl.fulfilment = 'to_order' AND sl.product_id = v_product.id AND sl.po_line_id IS NULL
                    AND so.status = 'open')
            INTO v_ok
            FROM public.sales_order_lines sl
            JOIN public.sales_orders so ON so.id = sl.order_id AND so.organization_id = sl.organization_id
            WHERE sl.id = v_sales AND sl.organization_id = p_org
            FOR UPDATE OF sl;
            IF NOT FOUND OR NOT v_ok THEN
                RAISE EXCEPTION 'SALES_ORDER_LINE_INVALID' USING ERRCODE = 'P0001';
            END IF;
            UPDATE public.sales_order_lines sl SET po_line_id = v_line WHERE sl.id = v_sales;
        END IF;
    END LOOP;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
END;
$$;

-- Loads an order for a write: the caller's shop and branch, locked.
CREATE FUNCTION app.purchase_order_for_write(p_org uuid, p_id uuid)
RETURNS public.purchase_orders LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_o public.purchase_orders;
BEGIN
    SELECT * INTO v_o FROM public.purchase_orders o WHERE o.id = p_id AND o.organization_id = p_org FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(v_o.branch_id) THEN
        RAISE EXCEPTION 'PURCHASE_ORDER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_o.branch_id);
    RETURN v_o;
END;
$$;

-- Trimmed notes: up to 1000 characters, or NULL.
CREATE FUNCTION app.purchase_order_notes(p_value text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := NULLIF(btrim(p_value), '');
BEGIN
    IF length(v) > 1000 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: notes' USING ERRCODE = 'P0001';
    END IF;
    RETURN v;
END;
$$;

-- 3. Order writes ------------------------------------------------------------------------------------

CREATE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_branch_id uuid, p_lines jsonb,
                                             p_idempotency_key text, p_expected_date date DEFAULT NULL,
                                             p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_o public.purchase_orders; v_notes text;
BEGIN
    v_emp := app.require_permission('purchase.order_manage');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_o FROM public.purchase_orders o
    WHERE o.organization_id = v_org AND o.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.purchase_order_json(v_org, v_o.id, true);     -- a repeat changes nothing
    END IF;

    PERFORM app.require_active_supplier(v_org, p_supplier_id);
    IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    v_notes := app.purchase_order_notes(p_notes);

    INSERT INTO public.purchase_orders (organization_id, number, supplier_id, branch_id, status, expected_date,
                                        notes, idempotency_key, created_by, updated_by)
    VALUES (v_org, app.next_document_number(v_org, p_branch_id, 'purchase_order'), p_supplier_id, p_branch_id,
            'draft', p_expected_date, v_notes, p_idempotency_key, v_emp, v_emp)
    RETURNING * INTO v_o;
    PERFORM app.set_purchase_order_lines(v_org, v_emp, v_o, p_lines);

    PERFORM app.write_audit('purchase_order.created', 'purchase_order', v_o.id, NULL,
        jsonb_build_object('number', v_o.number, 'supplier_id', p_supplier_id, 'expected_date', p_expected_date,
                           'lines', app.purchase_order_lines_json(v_org, v_o.id)),
        NULL, p_branch_id);
    RETURN app.purchase_order_json(v_org, v_o.id, true);
END;
$$;

-- Changes a draft: expected_date, notes and/or lines (all lines replaced).
CREATE FUNCTION public.update_purchase_order(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_o public.purchase_orders; v_key text; v_date date; v_notes text;
    v_before jsonb := '{}'; v_after jsonb := '{}'; v_old_lines jsonb; v_new_lines jsonb;
BEGIN
    v_emp := app.require_permission('purchase.order_manage');
    v_org := app.current_org_id();
    v_o := app.purchase_order_for_write(v_org, p_id);
    IF v_o.status <> 'draft' THEN
        RAISE EXCEPTION 'PURCHASE_ORDER_NOT_EDITABLE: the order is %', v_o.status USING ERRCODE = 'P0001';
    END IF;
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(p_changes) k
    WHERE k <> ALL (ARRAY['expected_date', 'notes', 'lines']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;

    IF p_changes ? 'expected_date' THEN
        v_date := (p_changes ->> 'expected_date')::date;
        IF v_date IS DISTINCT FROM v_o.expected_date THEN
            UPDATE public.purchase_orders o SET expected_date = v_date, updated_by = v_emp WHERE o.id = p_id;
            v_before := v_before || jsonb_build_object('expected_date', v_o.expected_date);
            v_after := v_after || jsonb_build_object('expected_date', v_date);
        END IF;
    END IF;
    IF p_changes ? 'notes' THEN
        v_notes := app.purchase_order_notes(p_changes ->> 'notes');
        IF v_notes IS DISTINCT FROM v_o.notes THEN
            UPDATE public.purchase_orders o SET notes = v_notes, updated_by = v_emp WHERE o.id = p_id;
            v_before := v_before || jsonb_build_object('notes', v_o.notes);
            v_after := v_after || jsonb_build_object('notes', v_notes);
        END IF;
    END IF;
    IF p_changes ? 'lines' THEN
        v_old_lines := app.purchase_order_lines_json(v_org, p_id);
        PERFORM app.set_purchase_order_lines(v_org, v_emp, v_o, p_changes -> 'lines');
        v_new_lines := app.purchase_order_lines_json(v_org, p_id);
        IF v_new_lines <> v_old_lines THEN
            UPDATE public.purchase_orders o SET updated_by = v_emp WHERE o.id = p_id;
            v_before := v_before || jsonb_build_object('lines', v_old_lines);
            v_after := v_after || jsonb_build_object('lines', v_new_lines);
        END IF;
    END IF;

    IF v_after <> '{}'::jsonb THEN                          -- no change: no audit row
        PERFORM app.write_audit('purchase_order.updated', 'purchase_order', p_id, v_before,
            v_after || jsonb_build_object('number', v_o.number), NULL, v_o.branch_id);
    END IF;
    RETURN app.purchase_order_json(v_org, p_id, true);
EXCEPTION
    WHEN invalid_text_representation OR datetime_field_overflow OR invalid_datetime_format THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
END;
$$;

-- draft -> sent. Sent (or further) again: answered unchanged. Cancelled: not editable.
CREATE FUNCTION public.send_purchase_order(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_o public.purchase_orders;
BEGIN
    v_emp := app.require_permission('purchase.order_manage');
    v_org := app.current_org_id();
    v_o := app.purchase_order_for_write(v_org, p_id);
    IF v_o.status = 'cancelled' THEN
        RAISE EXCEPTION 'PURCHASE_ORDER_NOT_EDITABLE: the order is cancelled' USING ERRCODE = 'P0001';
    END IF;
    IF v_o.status = 'draft' THEN
        PERFORM app.require_active_supplier(v_org, v_o.supplier_id);
        UPDATE public.purchase_orders o SET status = 'sent', updated_by = v_emp WHERE o.id = p_id;
        PERFORM app.write_audit('purchase_order.sent', 'purchase_order', p_id,
            jsonb_build_object('status', 'draft'),
            jsonb_build_object('status', 'sent', 'number', v_o.number), NULL, v_o.branch_id);
    END IF;
    RETURN app.purchase_order_json(v_org, p_id, true);
END;
$$;

-- Closes what is left of a draft, sent or partly received order. Received and cancelled are final.
CREATE FUNCTION public.cancel_purchase_order(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_o public.purchase_orders; v_reason text;
BEGIN
    v_emp := app.require_permission('purchase.order_manage');
    v_org := app.current_org_id();
    v_o := app.purchase_order_for_write(v_org, p_id);
    IF v_o.status IN ('received', 'cancelled') THEN
        RAISE EXCEPTION 'PURCHASE_ORDER_NOT_EDITABLE: the order is %', v_o.status USING ERRCODE = 'P0001';
    END IF;
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.purchase_orders o SET status = 'cancelled', updated_by = v_emp WHERE o.id = p_id;
    PERFORM app.write_audit('purchase_order.cancelled', 'purchase_order', p_id,
        jsonb_build_object('status', v_o.status),
        jsonb_build_object('status', 'cancelled', 'number', v_o.number), v_reason, v_o.branch_id, 'warning');
    RETURN app.purchase_order_json(v_org, p_id, true);
END;
$$;

-- 4. Order reads -------------------------------------------------------------------------------------

CREATE FUNCTION public.list_purchase_orders(p_supplier_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
                                            p_status text DEFAULT NULL, p_search text DEFAULT NULL,
                                            p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_search text; v_result jsonb;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    v_search := NULLIF(btrim(p_search), '');
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 OR length(v_search) > 40
       OR (p_status IS NOT NULL AND p_status NOT IN ('draft', 'sent', 'partially_received', 'received', 'cancelled')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_supplier_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.suppliers s WHERE s.id = p_supplier_id AND s.organization_id = v_org) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
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
        SELECT o.id, o.created_at FROM public.purchase_orders o
        WHERE o.organization_id = v_org AND o.branch_id = ANY(v_branches)
          AND (p_supplier_id IS NULL OR o.supplier_id = p_supplier_id)
          AND (p_status IS NULL OR o.status = p_status::public.po_status)
          AND (v_search IS NULL OR position(lower(v_search) IN lower(o.number)) > 0)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.purchase_order_json(v_org, f.id, false) ORDER BY f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) f),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Another shop's order, or one of a branch the caller doesn't work in: not found.
CREATE FUNCTION public.get_purchase_order(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    SELECT o.branch_id INTO v_branch FROM public.purchase_orders o WHERE o.id = p_id AND o.organization_id = v_org;
    IF NOT FOUND OR NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'PURCHASE_ORDER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.purchase_order_json(v_org, p_id, true);
END;
$$;

-- 5. Invoices of an order (U02 pieces, extended) -------------------------------------------------------

-- An invoice's order must be open for receiving: sent or partly received.
CREATE FUNCTION app.require_receivable_po(p_org uuid, p_po_id uuid)
RETURNS public.purchase_orders LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_o public.purchase_orders;
BEGIN
    SELECT * INTO v_o FROM public.purchase_orders o WHERE o.id = p_po_id AND o.organization_id = p_org FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(v_o.branch_id) THEN
        RAISE EXCEPTION 'PURCHASE_ORDER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_o.status = 'draft' THEN
        RAISE EXCEPTION 'PO_NOT_SENT: the order is still a draft' USING ERRCODE = 'P0001';
    ELSIF v_o.status IN ('received', 'cancelled') THEN
        RAISE EXCEPTION 'PO_CLOSED: the order is %', v_o.status USING ERRCODE = 'P0001';
    END IF;
    RETURN v_o;
END;
$$;

-- Every line of an invoice that is linked to an order line fits in what is still to come there
-- (approved invoices only count as received). Called on save and again at approval, under the
-- order's lock.
CREATE FUNCTION app.check_po_receipt(p_org uuid, p_invoice_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT il.po_line_id, il.quantity, v.remaining
             FROM public.purchase_invoice_lines il
             JOIN public.v_po_line_received v ON v.po_line_id = il.po_line_id
             WHERE il.organization_id = p_org AND il.invoice_id = p_invoice_id AND il.po_line_id IS NOT NULL
             ORDER BY il.product_id LOOP
        IF r.quantity > r.remaining THEN
            RAISE EXCEPTION 'PO_OVER_RECEIPT: % can take % more', r.po_line_id, r.remaining
                USING ERRCODE = 'P0001',
                      DETAIL = jsonb_build_object('po_line_id', r.po_line_id, 'remaining', r.remaining)::text;
        END IF;
    END LOOP;
END;
$$;

-- U02's line helper, plus po_line_id: a linked line needs the invoice's order (open for
-- receiving), must be that order's line and product, each order line once, within what remains.
-- p_lines: 1-200 of {product_id, quantity, unit_cost, tax_class_id?, serials?, po_line_id?}.
CREATE OR REPLACE FUNCTION app.set_purchase_invoice_lines(p_org uuid, p_emp uuid, p_invoice public.purchase_invoices,
                                                          p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    e jsonb; v_key text; v_product public.products; v_qty numeric; v_cost text; v_class uuid;
    v_serials text[]; v_all text[] := '{}'; v_dup text[]; v_seen uuid[] := '{}'; v_serialized boolean := false;
    v_po_line uuid; v_po_product uuid; v_linked boolean := false;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    DELETE FROM public.purchase_invoice_lines l WHERE l.organization_id = p_org AND l.invoice_id = p_invoice.id;

    FOR e IN SELECT x FROM jsonb_array_elements(p_lines) x LOOP
        IF jsonb_typeof(e) <> 'object' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: line' USING ERRCODE = 'P0001';
        END IF;
        SELECT k INTO v_key FROM jsonb_object_keys(e) k
        WHERE k <> ALL (ARRAY['product_id', 'quantity', 'unit_cost', 'tax_class_id', 'serials', 'po_line_id']) LIMIT 1;
        IF v_key IS NOT NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;

        SELECT * INTO v_product FROM public.products p
        WHERE p.id = (e ->> 'product_id')::uuid AND p.organization_id = p_org;
        IF NOT FOUND OR v_product.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_product.id = ANY(v_seen) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: duplicate product' USING ERRCODE = 'P0001';
        END IF;
        v_seen := v_seen || v_product.id;

        v_qty := (e ->> 'quantity')::numeric;
        IF jsonb_typeof(e -> 'quantity') <> 'number' OR v_qty IS NULL OR v_qty <> trunc(v_qty)
           OR v_qty < 1 OR v_qty > 100000 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: quantity' USING ERRCODE = 'P0001';
        END IF;
        v_cost := e ->> 'unit_cost';
        IF jsonb_typeof(e -> 'unit_cost') NOT IN ('string', 'number') OR v_cost IS NULL
           OR v_cost !~ '^\d{1,16}(\.\d{1,2})?$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: unit_cost' USING ERRCODE = 'P0001';
        END IF;

        IF e ? 'tax_class_id' AND jsonb_typeof(e -> 'tax_class_id') <> 'null' THEN
            v_class := (e ->> 'tax_class_id')::uuid;
        ELSE
            v_class := v_product.tax_class_id;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.tax_classes tc
                       WHERE tc.id = v_class AND tc.organization_id = p_org AND tc.archived_at IS NULL) THEN
            RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;

        v_serials := NULL;
        IF e ? 'serials' AND jsonb_typeof(e -> 'serials') <> 'null' THEN
            IF NOT v_product.is_serialized THEN
                RAISE EXCEPTION 'UNIT_NOT_ALLOWED: the product is not serialized' USING ERRCODE = 'P0001';
            END IF;
            v_serials := app.parse_serials(e -> 'serials');
            IF cardinality(v_serials) <> v_qty THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: serials must match the quantity' USING ERRCODE = 'P0001';
            END IF;
            v_all := v_all || v_serials;
        END IF;
        v_serialized := v_serialized OR v_product.is_serialized;

        -- U05: a line received against an order line. The product being once per invoice also
        -- keeps each order line once (an order has each product once).
        v_po_line := NULL;
        IF e ? 'po_line_id' AND jsonb_typeof(e -> 'po_line_id') <> 'null' THEN
            v_po_line := (e ->> 'po_line_id')::uuid;
            SELECT pl.product_id INTO v_po_product FROM public.purchase_order_lines pl
            WHERE pl.id = v_po_line AND pl.organization_id = p_org AND pl.po_id = p_invoice.po_id;
            IF NOT FOUND OR v_po_product <> v_product.id THEN
                RAISE EXCEPTION 'PO_LINE_MISMATCH: the line is not this order''s line for this product'
                    USING ERRCODE = 'P0001';
            END IF;
            v_linked := true;
        END IF;

        INSERT INTO public.purchase_invoice_lines (organization_id, invoice_id, product_id, po_line_id, quantity,
                                                   unit_cost, tax_class_id, tax_amount, line_total, serials, created_by)
        VALUES (p_org, p_invoice.id, v_product.id, v_po_line, v_qty::integer, v_cost::numeric, v_class, 0, 0,
                v_serials, p_emp);
    END LOOP;

    IF v_linked THEN
        PERFORM app.require_receivable_po(p_org, p_invoice.po_id);
        PERFORM app.check_po_receipt(p_org, p_invoice.id);
    END IF;
    IF v_serialized THEN
        PERFORM app.require_module('serials');
    END IF;
    SELECT array_agg(DISTINCT s ORDER BY s) INTO v_dup FROM unnest(v_all) s GROUP BY s HAVING count(*) > 1;
    IF v_dup IS NOT NULL THEN
        RAISE EXCEPTION 'SERIAL_TAKEN: repeated in the invoice' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('serials', to_jsonb(v_dup))::text;
    END IF;
    -- Serials already in the shop are refused now too (approval checks again under a lock).
    SELECT array_agg(u.serial ORDER BY u.serial) INTO v_dup
    FROM public.units u WHERE u.organization_id = p_org AND u.serial = ANY(v_all);
    IF v_dup IS NOT NULL THEN
        RAISE EXCEPTION 'SERIAL_TAKEN: % already in the shop', array_length(v_dup, 1) USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('serials', to_jsonb(v_dup))::text;
    END IF;

    PERFORM app.purchase_invoice_compute(p_org, p_invoice.id);
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
END;
$$;

-- The audit shape of a draft's lines; a linked line also names its order line.
CREATE OR REPLACE FUNCTION app.purchase_invoice_lines_json(p_org uuid, p_invoice_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', l.product_id, 'quantity', l.quantity,
               'unit_cost', l.unit_cost::text, 'tax_class_id', l.tax_class_id, 'serials', to_jsonb(l.serials))
               || CASE WHEN l.po_line_id IS NULL THEN '{}'::jsonb
                       ELSE jsonb_build_object('po_line_id', l.po_line_id) END
               ORDER BY l.product_id), '[]'::jsonb)
    FROM public.purchase_invoice_lines l
    WHERE l.organization_id = p_org AND l.invoice_id = p_invoice_id
$$;

-- U06's invoice JSON plus the order it receives (po_id, po_number) and each line's po_line_id.
CREATE OR REPLACE FUNCTION app.purchase_invoice_json(p_org uuid, p_id uuid, p_with_lines boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', i.id, 'number', i.number, 'supplier_id', i.supplier_id, 'supplier_name', s.name,
        'branch_id', i.branch_id, 'supplier_invoice_no', i.supplier_invoice_no,
        'invoice_date', i.invoice_date, 'status', i.status,
        'subtotal', i.subtotal::text, 'tax_total', i.tax_total::text, 'total', i.total::text,
        'outstanding', CASE WHEN i.status = 'approved' THEN COALESCE((
            SELECT b.outstanding FROM public.v_purchase_invoice_balances b
            WHERE b.organization_id = p_org AND b.purchase_invoice_id = i.id), i.total)::numeric(18,2)::text END,
        'approved_by_name', ae.full_name, 'approved_at', i.approved_at,
        'rejected_reason', i.rejected_reason,
        'created_by_name', ce.full_name, 'created_at', i.created_at, 'updated_at', i.updated_at,
        'approval', (SELECT app.purchase_approval_json(p_org, a.id) FROM public.approvals a
                     WHERE a.organization_id = p_org AND a.kind = 'purchase_invoice' AND a.entity_id = i.id
                     ORDER BY a.created_at DESC, a.id DESC LIMIT 1),
        'po_id', i.po_id,
        'po_number', (SELECT o.number FROM public.purchase_orders o
                      WHERE o.organization_id = p_org AND o.id = i.po_id))
        || CASE WHEN p_with_lines THEN jsonb_build_object('lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'product_id', l.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'sku', p.sku, 'is_serialized', p.is_serialized, 'quantity', l.quantity,
                'unit_cost', l.unit_cost::text, 'tax_class_id', l.tax_class_id, 'tax_rate', tc.rate::text,
                'tax_amount', l.tax_amount::text,
                'net', (l.quantity * l.unit_cost)::numeric(18,2)::text,
                'line_total', l.line_total::text, 'serials', to_jsonb(l.serials),
                'unit_ids', COALESCE((SELECT jsonb_agg(u.id ORDER BY u.serial) FROM public.units u
                                      WHERE u.organization_id = p_org AND u.purchase_invoice_line_id = l.id),
                                     '[]'::jsonb),
                'po_line_id', l.po_line_id)
                ORDER BY p.name_ar, l.product_id)
            FROM public.purchase_invoice_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            JOIN public.tax_classes tc ON tc.id = l.tax_class_id AND tc.organization_id = l.organization_id
            WHERE l.organization_id = p_org AND l.invoice_id = i.id), '[]'::jsonb))
           ELSE jsonb_build_object('lines_count', (
            SELECT count(*) FROM public.purchase_invoice_lines l
            WHERE l.organization_id = p_org AND l.invoice_id = i.id)) END
    FROM public.purchase_invoices i
    JOIN public.suppliers s ON s.id = i.supplier_id AND s.organization_id = i.organization_id
    LEFT JOIN public.employees ce ON ce.id = i.created_by AND ce.organization_id = i.organization_id
    LEFT JOIN public.employees ae ON ae.id = i.approved_by AND ae.organization_id = i.organization_id
    WHERE i.organization_id = p_org AND i.id = p_id
$$;

-- U02's create, plus an optional order: the invoice takes the order's supplier and branch (they
-- can't differ) and its lines may name the order's lines. p_po_id never changes afterwards.
DROP FUNCTION public.create_purchase_invoice(uuid, uuid, text, date, jsonb, text);

CREATE FUNCTION public.create_purchase_invoice(p_supplier_id uuid, p_branch_id uuid, p_supplier_invoice_no text,
                                               p_invoice_date date, p_lines jsonb, p_idempotency_key text,
                                               p_po_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_no text; v_o public.purchase_orders;
BEGIN
    v_emp := app.require_permission('purchase.invoice_create');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_i FROM public.purchase_invoices i
    WHERE i.organization_id = v_org AND i.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.purchase_invoice_json(v_org, v_i.id, true);   -- a repeat changes nothing
    END IF;

    PERFORM app.require_active_supplier(v_org, p_supplier_id);
    IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    IF p_invoice_date IS NULL OR p_invoice_date > app.org_today(v_org) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: date' USING ERRCODE = 'P0001';
    END IF;
    v_no := app.supplier_invoice_no(p_supplier_invoice_no);
    IF p_po_id IS NOT NULL THEN
        v_o := app.require_receivable_po(v_org, p_po_id);
        IF v_o.supplier_id <> p_supplier_id OR v_o.branch_id <> p_branch_id THEN
            RAISE EXCEPTION 'PO_LINE_MISMATCH: the invoice must have the order''s supplier and branch'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    BEGIN
        INSERT INTO public.purchase_invoices (organization_id, number, supplier_invoice_no, supplier_id, branch_id,
                                              po_id, invoice_date, status, idempotency_key, created_by, updated_by)
        VALUES (v_org, app.next_document_number(v_org, p_branch_id, 'purchase_invoice'), v_no, p_supplier_id,
                p_branch_id, p_po_id, p_invoice_date, 'draft', p_idempotency_key, v_emp, v_emp)
        RETURNING * INTO v_i;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_NO_TAKEN' USING ERRCODE = 'P0001';
    END;
    PERFORM app.set_purchase_invoice_lines(v_org, v_emp, v_i, p_lines);

    PERFORM app.write_audit('purchase_invoice.created', 'purchase_invoice', v_i.id, NULL,
        jsonb_build_object('number', v_i.number, 'supplier_id', p_supplier_id, 'supplier_invoice_no', v_no,
                           'invoice_date', p_invoice_date,
                           'total', (SELECT i.total::text FROM public.purchase_invoices i WHERE i.id = v_i.id),
                           'lines', app.purchase_invoice_lines_json(v_org, v_i.id))
        || CASE WHEN p_po_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('po_id', p_po_id) END,
        NULL, p_branch_id);
    RETURN app.purchase_invoice_json(v_org, v_i.id, true);
END;
$$;

-- "Receive": a draft invoice from a sent or partly received order. p_lines NULL: every line with
-- something still to come, for what remains, at its expected cost (0 when none).
-- p_lines: [{po_line_id, quantity, unit_cost?}].
CREATE FUNCTION public.create_invoice_from_po(p_po_id uuid, p_idempotency_key text, p_lines jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_o public.purchase_orders; v_built jsonb;
BEGIN
    v_emp := app.require_permission('purchase.invoice_create');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_i FROM public.purchase_invoices i
    WHERE i.organization_id = v_org AND i.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.purchase_invoice_json(v_org, v_i.id, true);   -- a repeat changes nothing
    END IF;

    v_o := app.require_receivable_po(v_org, p_po_id);
    PERFORM app.require_branch_access(v_o.branch_id);
    PERFORM app.require_active_supplier(v_org, v_o.supplier_id);

    IF p_lines IS NULL OR jsonb_typeof(p_lines) = 'null' THEN
        SELECT jsonb_agg(jsonb_build_object('product_id', l.product_id, 'quantity', r.remaining,
                   'unit_cost', COALESCE(l.expected_unit_cost, 0)::text, 'po_line_id', l.id) ORDER BY l.product_id)
        INTO v_built
        FROM public.purchase_order_lines l
        JOIN public.v_po_line_received r ON r.po_line_id = l.id
        WHERE l.organization_id = v_org AND l.po_id = v_o.id AND r.remaining > 0;
    ELSE
        IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) x
                      WHERE jsonb_typeof(x) <> 'object'
                         OR EXISTS (SELECT 1 FROM jsonb_object_keys(x) k WHERE k NOT IN ('po_line_id', 'quantity', 'unit_cost'))
                         OR jsonb_typeof(x -> 'po_line_id') IS DISTINCT FROM 'string'
                         OR (x ->> 'po_line_id') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                         OR jsonb_typeof(x -> 'quantity') IS DISTINCT FROM 'number')
           OR (SELECT count(DISTINCT x ->> 'po_line_id') FROM jsonb_array_elements(p_lines) x)
              <> jsonb_array_length(p_lines) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) x
                   WHERE NOT EXISTS (SELECT 1 FROM public.purchase_order_lines l
                                     WHERE l.id = (x ->> 'po_line_id')::uuid AND l.organization_id = v_org
                                       AND l.po_id = v_o.id)) THEN
            RAISE EXCEPTION 'PO_LINE_MISMATCH: a line is not on this order' USING ERRCODE = 'P0001';
        END IF;
        SELECT jsonb_agg(jsonb_build_object('product_id', l.product_id, 'quantity', x -> 'quantity',
                   'unit_cost', COALESCE(x -> 'unit_cost', to_jsonb(COALESCE(l.expected_unit_cost, 0)::text)),
                   'po_line_id', l.id) ORDER BY l.product_id)
        INTO v_built
        FROM jsonb_array_elements(p_lines) x
        JOIN public.purchase_order_lines l ON l.id = (x ->> 'po_line_id')::uuid AND l.organization_id = v_org;
    END IF;
    IF v_built IS NULL THEN
        RAISE EXCEPTION 'PO_CLOSED: nothing is still to come on this order' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.purchase_invoices (organization_id, number, supplier_id, branch_id, po_id, invoice_date,
                                          status, idempotency_key, created_by, updated_by)
    VALUES (v_org, app.next_document_number(v_org, v_o.branch_id, 'purchase_invoice'), v_o.supplier_id,
            v_o.branch_id, v_o.id, app.org_today(v_org), 'draft', p_idempotency_key, v_emp, v_emp)
    RETURNING * INTO v_i;
    PERFORM app.set_purchase_invoice_lines(v_org, v_emp, v_i, v_built);

    PERFORM app.write_audit('purchase_invoice.created', 'purchase_invoice', v_i.id, NULL,
        jsonb_build_object('number', v_i.number, 'supplier_id', v_o.supplier_id, 'po_id', v_o.id,
                           'po_number', v_o.number, 'invoice_date', v_i.invoice_date,
                           'total', (SELECT i.total::text FROM public.purchase_invoices i WHERE i.id = v_i.id),
                           'lines', app.purchase_invoice_lines_json(v_org, v_i.id)),
        NULL, v_o.branch_id);
    RETURN app.purchase_invoice_json(v_org, v_i.id, true);
END;
$$;

-- After an invoice of an order is approved: everything arrived -> received, else partly received.
CREATE FUNCTION app.po_after_receipt(p_org uuid, p_emp uuid, p_po_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_left bigint; v_got bigint;
BEGIN
    SELECT COALESCE(sum(r.remaining), 0), COALESCE(sum(r.received), 0) INTO v_left, v_got
    FROM public.v_po_line_received r WHERE r.organization_id = p_org AND r.po_id = p_po_id;
    UPDATE public.purchase_orders o
       SET status = CASE WHEN v_left <= 0 THEN 'received' ELSE 'partially_received' END::public.po_status,
           updated_by = p_emp
     WHERE o.id = p_po_id AND o.organization_id = p_org AND v_got > 0
       AND o.status IN ('sent', 'partially_received');
END;
$$;

-- U06's approve (same signature), plus the order of the invoice: it must still be open
-- (PO_CLOSED), every linked line must fit in what is still to come (PO_OVER_RECEIPT; two drafts
-- can each claim the rest, the second approval is refused), and after posting the order moves to
-- partially_received or received in the same transaction.
CREATE OR REPLACE FUNCTION public.approve_purchase_invoice(p_id uuid, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_missing jsonb; v_owner boolean; v_note text;
    v_threshold numeric(18,2); v_total numeric(18,2); v_above boolean; v_costs jsonb; v_approval uuid;
    v_po_status public.po_status;
BEGIN
    v_emp := app.require_permission('purchase.invoice_approve');
    v_org := app.current_org_id();
    v_i := app.purchase_invoice_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_i.branch_id);
    IF v_i.status = 'approved' THEN
        RETURN app.purchase_invoice_json(v_org, p_id, true);     -- a repeat posts nothing again
    ELSIF v_i.status = 'rejected' THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_EDITABLE: the invoice is rejected' USING ERRCODE = 'P0001';
    END IF;
    v_owner := app.current_role() = 'OWNER';
    IF v_i.status = 'pending_approval' THEN
        -- Only the owner decides, whatever the threshold is now (it may have changed since).
        IF NOT v_owner THEN
            RAISE EXCEPTION 'APPROVAL_OWNER_ONLY' USING ERRCODE = '42501';
        END IF;
        v_note := btrim(p_note);
        IF v_note IS NULL OR length(v_note) NOT BETWEEN 3 AND 500 THEN
            RAISE EXCEPTION 'APPROVAL_NOTE_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    PERFORM app.require_active_supplier(v_org, v_i.supplier_id);
    -- U05: the order is locked until the end, so two approvals can't both take what is left.
    -- A cancelled order takes nothing more; a fully received one refuses its lines as over-receipt.
    IF v_i.po_id IS NOT NULL THEN
        SELECT o.status INTO v_po_status FROM public.purchase_orders o
        WHERE o.id = v_i.po_id AND o.organization_id = v_org FOR UPDATE;
        IF v_po_status = 'cancelled' THEN
            RAISE EXCEPTION 'PO_CLOSED: the order is cancelled' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.check_po_receipt(v_org, p_id);
    END IF;

    SELECT jsonb_agg(l.id ORDER BY l.product_id) INTO v_missing
    FROM public.purchase_invoice_lines l
    JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
    WHERE l.organization_id = v_org AND l.invoice_id = p_id AND p.is_serialized AND l.serials IS NULL;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'SERIALS_REQUIRED: % line(s) need serials', jsonb_array_length(v_missing) USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('line_ids', v_missing)::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.purchase_invoice_lines l
               JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
               WHERE l.organization_id = v_org AND l.invoice_id = p_id AND p.is_serialized) THEN
        PERFORM app.require_module('serials');
    END IF;

    -- Current class rates (a rate changed since the draft applies).
    PERFORM app.purchase_invoice_compute(v_org, p_id);
    SELECT i.total INTO v_total FROM public.purchase_invoices i WHERE i.id = p_id;

    IF v_i.status = 'pending_approval' THEN
        -- The owner's decision on a waiting invoice: post, then close the approval in one statement.
        v_costs := app.post_purchase_invoice(v_org, v_emp, v_i);
        IF v_i.po_id IS NOT NULL THEN
            PERFORM app.po_after_receipt(v_org, v_emp, v_i.po_id);
        END IF;
        UPDATE public.approvals a
           SET status = 'approved', decided_by = v_emp, decided_at = now(), decision_note = v_note
         WHERE a.organization_id = v_org AND a.kind = 'purchase_invoice' AND a.entity_id = p_id
           AND a.status = 'pending'
        RETURNING a.id INTO v_approval;
        PERFORM app.write_audit('purchase_invoice.approved', 'purchase_invoice', p_id,
            jsonb_build_object('status', 'pending_approval'),
            jsonb_build_object('status', 'approved', 'number', v_i.number, 'total', v_total::text,
                               'lines', (SELECT count(*) FROM public.purchase_invoice_lines x
                                         WHERE x.organization_id = v_org AND x.invoice_id = p_id),
                               'avg_cost', v_costs, 'approval_id', v_approval),
            v_note, v_i.branch_id);
        RETURN app.purchase_invoice_json(v_org, p_id, true);
    END IF;

    -- U06: a draft above the threshold waits for the owner (strictly greater, VAT included).
    SELECT s.purchase_approval_threshold INTO v_threshold
    FROM public.org_settings s WHERE s.organization_id = v_org;
    v_above := v_threshold IS NOT NULL AND v_total > v_threshold;
    IF v_above AND NOT v_owner THEN
        UPDATE public.purchase_invoices i SET status = 'pending_approval', updated_by = v_emp WHERE i.id = p_id;
        INSERT INTO public.approvals (organization_id, branch_id, kind, entity_type, entity_id, amount, payload,
                                     status, requested_by, created_by)
        VALUES (v_org, v_i.branch_id, 'purchase_invoice', 'purchase_invoice', p_id, v_total,
                jsonb_build_object('threshold', v_threshold::text, 'number', v_i.number),
                'pending', v_emp, v_emp)
        RETURNING id INTO v_approval;
        PERFORM app.write_audit('purchase_invoice.approval_requested', 'purchase_invoice', p_id,
            jsonb_build_object('status', 'draft'),
            jsonb_build_object('status', 'pending_approval', 'number', v_i.number, 'total', v_total::text,
                               'threshold', v_threshold::text, 'approval_id', v_approval),
            NULL, v_i.branch_id);
        RETURN app.purchase_invoice_json(v_org, p_id, true);
    END IF;

    v_costs := app.post_purchase_invoice(v_org, v_emp, v_i);
    IF v_i.po_id IS NOT NULL THEN
        PERFORM app.po_after_receipt(v_org, v_emp, v_i.po_id);
    END IF;
    PERFORM app.write_audit('purchase_invoice.approved', 'purchase_invoice', p_id,
        jsonb_build_object('status', v_i.status),
        jsonb_build_object('status', 'approved', 'number', v_i.number, 'total', v_total::text,
                           'lines', (SELECT count(*) FROM public.purchase_invoice_lines x
                                     WHERE x.organization_id = v_org AND x.invoice_id = p_id),
                           'avg_cost', v_costs, 'threshold', v_threshold::text, 'above', v_above),
        NULL, v_i.branch_id);
    RETURN app.purchase_invoice_json(v_org, p_id, true);
END;
$$;

-- 6. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.purchase_order_json(uuid, uuid, boolean), app.purchase_order_lines_json(uuid, uuid),
    app.sales_order_line_po_status(uuid, uuid),
    app.set_purchase_order_lines(uuid, uuid, public.purchase_orders, jsonb),
    app.purchase_order_for_write(uuid, uuid), app.purchase_order_notes(text),
    app.require_receivable_po(uuid, uuid), app.check_po_receipt(uuid, uuid), app.po_after_receipt(uuid, uuid, uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_purchase_order(uuid, uuid, jsonb, text, date, text),
    public.update_purchase_order(uuid, jsonb), public.send_purchase_order(uuid),
    public.cancel_purchase_order(uuid, text),
    public.list_purchase_orders(uuid, uuid, text, text, integer, integer), public.get_purchase_order(uuid),
    public.create_purchase_invoice(uuid, uuid, text, date, jsonb, text, uuid),
    public.create_invoice_from_po(uuid, text, jsonb)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_purchase_order(uuid, uuid, jsonb, text, date, text),
    public.update_purchase_order(uuid, jsonb), public.send_purchase_order(uuid),
    public.cancel_purchase_order(uuid, text),
    public.list_purchase_orders(uuid, uuid, text, text, integer, integer), public.get_purchase_order(uuid),
    public.create_purchase_invoice(uuid, uuid, text, date, jsonb, text, uuid),
    public.create_invoice_from_po(uuid, text, jsonb)
    TO authenticated;
