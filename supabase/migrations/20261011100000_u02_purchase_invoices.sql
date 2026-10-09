-- =============================================================================
-- U02 · Purchase invoices (EC-54, D54)
--
-- A supplier's invoice is recorded as a draft (lines, net unit costs, VAT per line), then
-- approved (stock in through the ledger, once; serial units created; moving-average cost
-- updated; the supplier balance rises by the total) or rejected with a reason.
-- Tables are in the baseline (purchase_invoices, purchase_invoice_lines); this adds the write and
-- read functions. No table, column or enum changes. Numbered after the newest migration (D39).
--
-- Rules (D54):
--   * Unit costs are entered before VAT. VAT comes from the line's tax class (the product's by
--     default) through app.compute_document_tax (D41), prices_include_vat = false, no discounts.
--   * Moving average per product across all branches, on the NET unit cost:
--       new_avg = (old_qty * old_avg + qty * unit_cost) / (old_qty + qty), half-up to 4 places,
--     old_qty = the product's total on_hand (every branch and stock state) before the line posts;
--     old_qty <= 0 -> new_avg = unit_cost. Lines post in product_id order, one line per product.
--   * Approve is idempotent by state: an approved invoice answers unchanged (no ledger rows, no
--     audit). A rejected one can't be approved. Only drafts are edited; supplier and branch are
--     fixed at creation. At approval the lines are recomputed with the current class rates.
--   * No PO link yet (U05) and no amount threshold yet (U06).
-- Reads: any purchasing read key (app.can_read_suppliers, D53), invoices of the caller's
-- branches only; they work in an expired (read-only) shop.
-- =============================================================================

-- 1. JSON for the API -------------------------------------------------------------------------------

CREATE FUNCTION app.purchase_invoice_json(p_org uuid, p_id uuid, p_with_lines boolean)
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
        'created_by_name', ce.full_name, 'created_at', i.created_at, 'updated_at', i.updated_at)
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
                                     '[]'::jsonb))
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

-- 2. Lines and totals -------------------------------------------------------------------------------

-- Recomputes every line's VAT with its class's CURRENT rate and writes the header totals.
-- Only while the invoice is still editable (the freeze triggers refuse it afterwards).
CREATE FUNCTION app.purchase_invoice_compute(p_org uuid, p_invoice_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_ids uuid[]; v_doc jsonb; v_tax jsonb; i integer;
BEGIN
    SELECT array_agg(l.id ORDER BY l.product_id),
           jsonb_build_object('prices_include_vat', false, 'document_discount', '0',
               'lines', jsonb_agg(jsonb_build_object('unit_price', l.unit_cost::text, 'quantity', l.quantity,
                                                     'line_discount', '0', 'tax_rate', tc.rate::text)
                                  ORDER BY l.product_id))
    INTO v_ids, v_doc
    FROM public.purchase_invoice_lines l
    JOIN public.tax_classes tc ON tc.id = l.tax_class_id AND tc.organization_id = l.organization_id
    WHERE l.organization_id = p_org AND l.invoice_id = p_invoice_id;
    IF v_ids IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    v_tax := app.compute_document_tax(v_doc);
    FOR i IN 1..array_length(v_ids, 1) LOOP
        UPDATE public.purchase_invoice_lines l
           SET tax_amount = (v_tax -> 'lines' -> (i - 1) ->> 'tax')::numeric,
               line_total = (v_tax -> 'lines' -> (i - 1) ->> 'gross')::numeric
         WHERE l.id = v_ids[i];
    END LOOP;
    UPDATE public.purchase_invoices pi
       SET subtotal = (v_tax ->> 'net_total')::numeric,
           tax_total = (v_tax ->> 'tax_total')::numeric,
           total = (v_tax ->> 'total')::numeric
     WHERE pi.id = p_invoice_id;
END;
$$;

-- Checks and stores the lines of a draft (replacing any old ones), then computes the totals.
-- p_lines: 1-200 of {product_id, quantity, unit_cost, tax_class_id?, serials?}.
CREATE FUNCTION app.set_purchase_invoice_lines(p_org uuid, p_emp uuid, p_invoice public.purchase_invoices,
                                               p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    e jsonb; v_key text; v_product public.products; v_qty numeric; v_cost text; v_class uuid;
    v_serials text[]; v_all text[] := '{}'; v_dup text[]; v_seen uuid[] := '{}'; v_serialized boolean := false;
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
        WHERE k <> ALL (ARRAY['product_id', 'quantity', 'unit_cost', 'tax_class_id', 'serials']) LIMIT 1;
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

        INSERT INTO public.purchase_invoice_lines (organization_id, invoice_id, product_id, quantity, unit_cost,
                                                   tax_class_id, tax_amount, line_total, serials, created_by)
        VALUES (p_org, p_invoice.id, v_product.id, v_qty::integer, v_cost::numeric, v_class, 0, 0, v_serials, p_emp);
    END LOOP;

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

-- What a draft's lines are, for the audit of an update: product, quantity, cost, class, serials.
CREATE FUNCTION app.purchase_invoice_lines_json(p_org uuid, p_invoice_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', l.product_id, 'quantity', l.quantity,
               'unit_cost', l.unit_cost::text, 'tax_class_id', l.tax_class_id, 'serials', to_jsonb(l.serials))
               ORDER BY l.product_id), '[]'::jsonb)
    FROM public.purchase_invoice_lines l
    WHERE l.organization_id = p_org AND l.invoice_id = p_invoice_id
$$;

-- Loads an invoice for a write: the caller's shop, locked.
CREATE FUNCTION app.purchase_invoice_for_write(p_org uuid, p_id uuid)
RETURNS public.purchase_invoices LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_i public.purchase_invoices;
BEGIN
    SELECT * INTO v_i FROM public.purchase_invoices i WHERE i.id = p_id AND i.organization_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_i;
END;
$$;

-- The supplier of a document must be the shop's and active; FOR SHARE so an archive waits (D53).
CREATE FUNCTION app.require_active_supplier(p_org uuid, p_supplier_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_archived timestamptz;
BEGIN
    SELECT s.archived_at INTO v_archived FROM public.suppliers s
    WHERE s.id = p_supplier_id AND s.organization_id = p_org FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_archived IS NOT NULL THEN
        RAISE EXCEPTION 'SUPPLIER_ARCHIVED' USING ERRCODE = 'P0001';
    END IF;
END;
$$;

-- Trimmed supplier invoice number: 1-40 characters, or NULL.
CREATE FUNCTION app.supplier_invoice_no(p_value text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := NULLIF(btrim(p_value), '');
BEGIN
    IF length(v) > 40 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: supplier_invoice_no' USING ERRCODE = 'P0001';
    END IF;
    RETURN v;
END;
$$;

-- 3. Writes ----------------------------------------------------------------------------------------

CREATE FUNCTION public.create_purchase_invoice(p_supplier_id uuid, p_branch_id uuid, p_supplier_invoice_no text,
                                               p_invoice_date date, p_lines jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_no text;
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

    BEGIN
        INSERT INTO public.purchase_invoices (organization_id, number, supplier_invoice_no, supplier_id, branch_id,
                                              invoice_date, status, idempotency_key, created_by, updated_by)
        VALUES (v_org, app.next_document_number(v_org, p_branch_id, 'purchase_invoice'), v_no, p_supplier_id,
                p_branch_id, p_invoice_date, 'draft', p_idempotency_key, v_emp, v_emp)
        RETURNING * INTO v_i;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'SUPPLIER_INVOICE_NO_TAKEN' USING ERRCODE = 'P0001';
    END;
    PERFORM app.set_purchase_invoice_lines(v_org, v_emp, v_i, p_lines);

    PERFORM app.write_audit('purchase_invoice.created', 'purchase_invoice', v_i.id, NULL,
        jsonb_build_object('number', v_i.number, 'supplier_id', p_supplier_id, 'supplier_invoice_no', v_no,
                           'invoice_date', p_invoice_date,
                           'total', (SELECT i.total::text FROM public.purchase_invoices i WHERE i.id = v_i.id),
                           'lines', app.purchase_invoice_lines_json(v_org, v_i.id)),
        NULL, p_branch_id);
    RETURN app.purchase_invoice_json(v_org, v_i.id, true);
END;
$$;

-- Changes a draft: supplier_invoice_no, invoice_date and/or lines (all lines replaced).
CREATE FUNCTION public.update_purchase_invoice(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_key text; v_no text; v_date date;
    v_before jsonb := '{}'; v_after jsonb := '{}'; v_old_lines jsonb; v_new_lines jsonb; v_total text;
BEGIN
    v_emp := app.require_permission('purchase.invoice_create');
    v_org := app.current_org_id();
    v_i := app.purchase_invoice_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_i.branch_id);
    IF v_i.status NOT IN ('draft', 'pending_approval') THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_EDITABLE: the invoice is %', v_i.status USING ERRCODE = 'P0001';
    END IF;
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(p_changes) k
    WHERE k <> ALL (ARRAY['supplier_invoice_no', 'invoice_date', 'lines']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;

    IF p_changes ? 'supplier_invoice_no' THEN
        v_no := app.supplier_invoice_no(p_changes ->> 'supplier_invoice_no');
        IF v_no IS DISTINCT FROM v_i.supplier_invoice_no THEN
            BEGIN
                UPDATE public.purchase_invoices i SET supplier_invoice_no = v_no, updated_by = v_emp WHERE i.id = p_id;
            EXCEPTION WHEN unique_violation THEN
                RAISE EXCEPTION 'SUPPLIER_INVOICE_NO_TAKEN' USING ERRCODE = 'P0001';
            END;
            v_before := v_before || jsonb_build_object('supplier_invoice_no', v_i.supplier_invoice_no);
            v_after := v_after || jsonb_build_object('supplier_invoice_no', v_no);
        END IF;
    END IF;
    IF p_changes ? 'invoice_date' THEN
        v_date := (p_changes ->> 'invoice_date')::date;
        IF v_date IS NULL OR v_date > app.org_today(v_org) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: date' USING ERRCODE = 'P0001';
        END IF;
        IF v_date <> v_i.invoice_date THEN
            UPDATE public.purchase_invoices i SET invoice_date = v_date, updated_by = v_emp WHERE i.id = p_id;
            v_before := v_before || jsonb_build_object('invoice_date', v_i.invoice_date);
            v_after := v_after || jsonb_build_object('invoice_date', v_date);
        END IF;
    END IF;
    IF p_changes ? 'lines' THEN
        v_old_lines := app.purchase_invoice_lines_json(v_org, p_id);
        PERFORM app.set_purchase_invoice_lines(v_org, v_emp, v_i, p_changes -> 'lines');
        v_new_lines := app.purchase_invoice_lines_json(v_org, p_id);
        IF v_new_lines <> v_old_lines THEN
            SELECT i.total::text INTO v_total FROM public.purchase_invoices i WHERE i.id = p_id;
            UPDATE public.purchase_invoices i SET updated_by = v_emp WHERE i.id = p_id;
            v_before := v_before || jsonb_build_object('lines', v_old_lines, 'total', v_i.total::text);
            v_after := v_after || jsonb_build_object('lines', v_new_lines, 'total', v_total);
        END IF;
    END IF;

    IF v_after <> '{}'::jsonb THEN                          -- no change: no audit row
        PERFORM app.write_audit('purchase_invoice.updated', 'purchase_invoice', p_id, v_before,
            v_after || jsonb_build_object('number', v_i.number), NULL, v_i.branch_id);
    END IF;
    RETURN app.purchase_invoice_json(v_org, p_id, true);
EXCEPTION
    WHEN invalid_text_representation OR datetime_field_overflow OR invalid_datetime_format THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
END;
$$;

-- Posts a draft: stock in (once), serial units, moving-average cost, supplier balance up.
CREATE FUNCTION public.approve_purchase_invoice(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_missing jsonb; r record;
    v_old_qty bigint; v_old_avg numeric(18,4); v_new_avg numeric(18,4); v_costs jsonb := '[]';
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
    PERFORM app.require_active_supplier(v_org, v_i.supplier_id);

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

    -- U06: threshold check goes here

    FOR r IN SELECT * FROM public.purchase_invoice_lines x
             WHERE x.organization_id = v_org AND x.invoice_id = p_id ORDER BY x.product_id LOOP
        SELECT p.avg_cost INTO v_old_avg FROM public.products p
        WHERE p.id = r.product_id AND p.organization_id = v_org FOR UPDATE;
        SELECT COALESCE(sum(sl.on_hand), 0) INTO v_old_qty FROM public.stock_levels sl
        WHERE sl.organization_id = v_org AND sl.product_id = r.product_id;
        v_new_avg := CASE WHEN v_old_qty <= 0 THEN r.unit_cost
                          ELSE round((v_old_qty * v_old_avg + r.quantity * r.unit_cost) / (v_old_qty + r.quantity), 4) END;
        UPDATE public.products p SET avg_cost = v_new_avg, updated_by = v_emp WHERE p.id = r.product_id;
        v_costs := v_costs || jsonb_build_object('product_id', r.product_id, 'before', v_old_avg::text,
                                                 'after', v_new_avg::text);

        IF r.serials IS NOT NULL THEN
            PERFORM app.create_units(v_org, v_emp, r.product_id, v_i.branch_id, r.serials, r.unit_cost,
                                     'purchase_in', 'purchase_invoice', p_id, r.id);
        ELSE
            INSERT INTO public.stock_movements (organization_id, product_id, branch_id, quantity, type, stock_state,
                                                unit_cost, source_type, source_id, source_line_id, created_by)
            VALUES (v_org, r.product_id, v_i.branch_id, r.quantity, 'purchase_in', 'sellable', r.unit_cost,
                    'purchase_invoice', p_id, r.id, v_emp);
        END IF;
    END LOOP;

    UPDATE public.purchase_invoices i
       SET status = 'approved', approved_by = v_emp, approved_at = now(), updated_by = v_emp
     WHERE i.id = p_id;
    PERFORM app.write_audit('purchase_invoice.approved', 'purchase_invoice', p_id,
        jsonb_build_object('status', v_i.status),
        (SELECT jsonb_build_object('status', 'approved', 'number', i.number, 'total', i.total::text,
                                   'lines', (SELECT count(*) FROM public.purchase_invoice_lines x
                                             WHERE x.organization_id = v_org AND x.invoice_id = p_id),
                                   'avg_cost', v_costs)
         FROM public.purchase_invoices i WHERE i.id = p_id),
        NULL, v_i.branch_id);
    RETURN app.purchase_invoice_json(v_org, p_id, true);
END;
$$;

CREATE FUNCTION public.reject_purchase_invoice(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_i public.purchase_invoices; v_reason text;
BEGIN
    v_emp := app.require_permission('purchase.invoice_approve');
    v_org := app.current_org_id();
    v_i := app.purchase_invoice_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_i.branch_id);
    IF v_i.status NOT IN ('draft', 'pending_approval') THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_EDITABLE: the invoice is %', v_i.status USING ERRCODE = 'P0001';
    END IF;
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.purchase_invoices i
       SET status = 'rejected', rejected_reason = v_reason, updated_by = v_emp
     WHERE i.id = p_id;
    PERFORM app.write_audit('purchase_invoice.rejected', 'purchase_invoice', p_id,
        jsonb_build_object('status', v_i.status),
        jsonb_build_object('status', 'rejected', 'number', v_i.number, 'total', v_i.total::text),
        v_reason, v_i.branch_id, 'warning'::public.audit_severity);
    RETURN app.purchase_invoice_json(v_org, p_id, true);
END;
$$;

-- 4. Reads -----------------------------------------------------------------------------------------

-- Invoices of the caller's branches, newest invoice date first. search: the PI number or the
-- supplier's invoice number (contains, any letter case).
CREATE FUNCTION public.list_purchase_invoices(p_supplier_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
                                              p_status text DEFAULT NULL, p_from date DEFAULT NULL,
                                              p_to date DEFAULT NULL, p_search text DEFAULT NULL,
                                              p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_search text; v_like text; v_result jsonb;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR (p_status IS NOT NULL AND p_status NOT IN ('draft', 'pending_approval', 'approved', 'rejected'))
       OR p_from > p_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := NULLIF(btrim(p_search), '');
    IF length(v_search) > 40 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: search' USING ERRCODE = 'P0001';
    END IF;
    v_like := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');
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
        SELECT i.id, i.invoice_date, i.created_at FROM public.purchase_invoices i
        WHERE i.organization_id = v_org AND i.branch_id = ANY(v_branches)
          AND (p_supplier_id IS NULL OR i.supplier_id = p_supplier_id)
          AND (p_status IS NULL OR i.status::text = p_status)
          AND (p_from IS NULL OR i.invoice_date >= p_from)
          AND (p_to IS NULL OR i.invoice_date <= p_to)
          AND (v_search IS NULL OR i.number ILIKE '%' || v_like || '%'
               OR i.supplier_invoice_no ILIKE '%' || v_like || '%')
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.purchase_invoice_json(v_org, f.id, false)
                             ORDER BY f.invoice_date DESC, f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY invoice_date DESC, created_at DESC, id DESC
                  LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Another shop's invoice, or one of a branch the caller doesn't work in: not found.
CREATE FUNCTION public.get_purchase_invoice(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    SELECT i.branch_id INTO v_branch FROM public.purchase_invoices i WHERE i.id = p_id AND i.organization_id = v_org;
    IF NOT FOUND OR NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'PURCHASE_INVOICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.purchase_invoice_json(v_org, p_id, true);
END;
$$;

-- 5. Grants ----------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.purchase_invoice_json(uuid, uuid, boolean), app.purchase_invoice_compute(uuid, uuid),
    app.set_purchase_invoice_lines(uuid, uuid, public.purchase_invoices, jsonb),
    app.purchase_invoice_lines_json(uuid, uuid), app.purchase_invoice_for_write(uuid, uuid),
    app.require_active_supplier(uuid, uuid), app.supplier_invoice_no(text)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_purchase_invoice(uuid, uuid, text, date, jsonb, text),
    public.update_purchase_invoice(uuid, jsonb), public.approve_purchase_invoice(uuid),
    public.reject_purchase_invoice(uuid, text),
    public.list_purchase_invoices(uuid, uuid, text, date, date, text, integer, integer),
    public.get_purchase_invoice(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_purchase_invoice(uuid, uuid, text, date, jsonb, text),
    public.update_purchase_invoice(uuid, jsonb), public.approve_purchase_invoice(uuid),
    public.reject_purchase_invoice(uuid, text),
    public.list_purchase_invoices(uuid, uuid, text, date, date, text, integer, integer),
    public.get_purchase_invoice(uuid)
    TO authenticated;
