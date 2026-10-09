-- =============================================================================
-- U01 · Suppliers (EC-53, D53)
--
-- Add, edit, archive and restore the suppliers a shop buys from, and read a supplier statement:
-- approved invoices, payments (and their reversals) and returns with a running balance, ending at
-- what the shop owes. Writes need supplier.manage; reads are open to anyone who works with
-- purchases (decision 3 below). Every write that changes something writes exactly one audit row.
--
-- Numbered after the newest migration on main (D39). Everything below is NEW: the baseline's
-- suppliers table, its indexes, the RLS tenant policy, the updated_at trigger and the view
-- v_supplier_balances stay as they are. No new tables, columns or enums.
--
-- Rules (D53):
--   1. Names and phones are unique among ACTIVE suppliers (name case-insensitive and trimmed;
--      the phone is stored normalised: spaces and dashes removed). Archived ones block nothing.
--   2. Archive is refused while the balance is not 0 (SUPPLIER_HAS_BALANCE) or the supplier has
--      open documents (SUPPLIER_HAS_OPEN_DOCUMENTS): invoices in draft / pending_approval, or
--      purchase orders in draft / sent / partially_received. Restore re-checks rule 1.
--   3. Reads: any of supplier.manage, purchase.order_manage, purchase.invoice_create,
--      purchase.invoice_approve, purchase.return_create, supplier.payment_create, report.financial.
--      They check app.has_permission, so an expired (read-only) shop can still read.
--   4. A statement is shop-wide: documents of every branch (the balance is shop-level).
--   5. The statement's closing balance (no dates) equals v_supplier_balances.balance.
-- =============================================================================

-- 1. Uniqueness among active suppliers --------------------------------------------------------

CREATE UNIQUE INDEX suppliers_active_name_key ON public.suppliers (organization_id, lower(btrim(name)))
    WHERE archived_at IS NULL;
CREATE UNIQUE INDEX suppliers_active_phone_key ON public.suppliers (organization_id, phone)
    WHERE archived_at IS NULL AND phone IS NOT NULL;

-- 2. Helpers (no grants) ----------------------------------------------------------------------

-- Decision 3: who may read suppliers and statements.
CREATE FUNCTION app.can_read_suppliers()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT app.has_permission('supplier.manage') OR app.has_permission('purchase.order_manage')
        OR app.has_permission('purchase.invoice_create') OR app.has_permission('purchase.invoice_approve')
        OR app.has_permission('purchase.return_create') OR app.has_permission('supplier.payment_create')
        OR app.has_permission('report.financial')
$$;

-- The start of every read: an employee with one of the decision-3 keys.
CREATE FUNCTION app.supplier_read_guard()
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.can_read_suppliers() THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: supplier.manage' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Row shape of the contract's Supplier; balance from v_supplier_balances (0 without a row).
CREATE FUNCTION app.supplier_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'name', s.name, 'phone', s.phone, 'tax_registration_no', s.tax_registration_no,
        'address', s.address, 'payment_terms_days', s.payment_terms_days, 'notes', s.notes,
        'archived_at', s.archived_at, 'created_at', s.created_at, 'updated_at', s.updated_at,
        'balance', COALESCE((SELECT b.balance FROM public.v_supplier_balances b
                             WHERE b.supplier_id = s.id AND b.organization_id = p_org), 0)::numeric(18,2)::text)
    FROM public.suppliers s
    WHERE s.id = p_id AND s.organization_id = p_org
$$;

-- The editable fields (the audit before/after of an update).
CREATE FUNCTION app.supplier_fields_json(s public.suppliers)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object('name', s.name, 'phone', s.phone, 'tax_registration_no', s.tax_registration_no,
        'address', s.address, 'payment_terms_days', s.payment_terms_days, 'notes', s.notes)
$$;

-- Applies the keys of c to the row r and validates them (the contract's rules, repeated here).
CREATE FUNCTION app.supplier_apply(r public.suppliers, c jsonb)
RETURNS public.suppliers LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_key text; v_txt text; v_num numeric;
BEGIN
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    -- organization_id, archived_at and anything unknown are refused.
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE k <> ALL (ARRAY['name', 'phone', 'tax_registration_no', 'address', 'payment_terms_days', 'notes'])
    LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;
    -- Text fields are strings (or null where the field is optional).
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE (k = 'name' AND jsonb_typeof(c -> k) <> 'string')
       OR (k IN ('phone', 'tax_registration_no', 'address', 'notes') AND jsonb_typeof(c -> k) NOT IN ('string', 'null'))
       OR (k = 'payment_terms_days' AND jsonb_typeof(c -> k) <> 'number')
    LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;

    IF c ? 'name' THEN
        v_txt := btrim(c ->> 'name');
        IF length(v_txt) < 1 OR length(v_txt) > 150 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: name' USING ERRCODE = 'P0001';
        END IF;
        r.name := v_txt;
    END IF;
    IF c ? 'phone' THEN
        v_txt := NULLIF(regexp_replace(btrim(c ->> 'phone'), '[[:space:]-]', '', 'g'), '');
        IF v_txt IS NOT NULL AND v_txt !~ '^\+?[0-9]{6,15}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: phone' USING ERRCODE = 'P0001';
        END IF;
        r.phone := v_txt;
    END IF;
    IF c ? 'tax_registration_no' THEN
        v_txt := NULLIF(btrim(c ->> 'tax_registration_no'), '');
        IF v_txt IS NOT NULL AND v_txt !~ '^[0-9-]{9,20}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: tax_registration_no' USING ERRCODE = 'P0001';
        END IF;
        r.tax_registration_no := v_txt;
    END IF;
    IF c ? 'address' THEN
        v_txt := NULLIF(btrim(c ->> 'address'), '');
        IF length(v_txt) > 300 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: address' USING ERRCODE = 'P0001';
        END IF;
        r.address := v_txt;
    END IF;
    IF c ? 'notes' THEN
        v_txt := NULLIF(btrim(c ->> 'notes'), '');
        IF length(v_txt) > 1000 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: notes' USING ERRCODE = 'P0001';
        END IF;
        r.notes := v_txt;
    END IF;
    IF c ? 'payment_terms_days' THEN
        v_num := (c ->> 'payment_terms_days')::numeric;
        IF v_num <> trunc(v_num) OR v_num < 0 OR v_num > 365 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: payment_terms_days' USING ERRCODE = 'P0001';
        END IF;
        r.payment_terms_days := v_num::integer;
    END IF;
    RETURN r;
END;
$$;

-- A unique-index violation on suppliers as the contract's code.
CREATE FUNCTION app.supplier_unique_error(p_constraint text)
RETURNS void LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF p_constraint = 'suppliers_active_phone_key' THEN
        RAISE EXCEPTION 'SUPPLIER_PHONE_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'SUPPLIER_NAME_TAKEN' USING ERRCODE = 'P0001';
END;
$$;

-- Every statement row of a supplier, unordered and undated: approved invoices (debit), payments
-- (credit), payment reversals (debit), returns (credit for supplier_credit, 0 and 0 for cash).
-- Draft, pending and rejected invoices never appear. The reference of a return is the number of
-- the invoice it returns against.
CREATE FUNCTION app.supplier_statement_rows(p_org uuid, p_id uuid)
RETURNS TABLE (d date, created_at timestamptz, id uuid, kind text, number text, reference text,
               branch_id uuid, refund_mode text, debit numeric(18,2), credit numeric(18,2))
LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT pi.invoice_date, pi.created_at, pi.id, 'invoice', pi.number, pi.supplier_invoice_no,
           pi.branch_id, NULL::text, pi.total, 0::numeric(18,2)
    FROM public.purchase_invoices pi
    WHERE pi.organization_id = p_org AND pi.supplier_id = p_id AND pi.status = 'approved'
    UNION ALL
    SELECT sp.business_date, sp.created_at, sp.id,
           CASE WHEN sp.reverses_payment_id IS NULL THEN 'payment' ELSE 'payment_reversal' END,
           sp.number, sp.reference, sp.branch_id, NULL::text,
           CASE WHEN sp.reverses_payment_id IS NULL THEN 0 ELSE sp.amount END,
           CASE WHEN sp.reverses_payment_id IS NULL THEN sp.amount ELSE 0 END
    FROM public.supplier_payments sp
    WHERE sp.organization_id = p_org AND sp.supplier_id = p_id
    UNION ALL
    SELECT pr.business_date, pr.created_at, pr.id, 'return', pr.number,
           (SELECT pi.number FROM public.purchase_invoices pi
            WHERE pi.id = pr.purchase_invoice_id AND pi.organization_id = p_org),
           pr.branch_id, pr.refund_mode::text, 0::numeric(18,2),
           CASE WHEN pr.refund_mode = 'supplier_credit' THEN pr.total ELSE 0 END
    FROM public.purchase_returns pr
    WHERE pr.organization_id = p_org AND pr.supplier_id = p_id
$$;

REVOKE ALL ON FUNCTION app.can_read_suppliers(), app.supplier_read_guard(), app.supplier_json(uuid, uuid),
    app.supplier_fields_json(public.suppliers), app.supplier_apply(public.suppliers, jsonb),
    app.supplier_unique_error(text), app.supplier_statement_rows(uuid, uuid)
    FROM PUBLIC, anon, authenticated;

-- 3. Reads (decision 3) -------------------------------------------------------------------------

-- Search: the name (ILIKE, wildcards escaped) or, when the text is a phone number, a phone prefix.
CREATE FUNCTION public.list_suppliers(p_search text DEFAULT NULL, p_status text DEFAULT 'active',
                                      p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_search text; v_like text; v_phone text; v_result jsonb;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    IF COALESCE(p_status, 'active') NOT IN ('active', 'archived', 'all')
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := NULLIF(btrim(p_search), '');
    IF length(v_search) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: search' USING ERRCODE = 'P0001';
    END IF;
    v_like := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');
    -- Phones are stored without spaces or dashes; the prefix only ever holds '+' and digits.
    v_phone := regexp_replace(v_search, '[[:space:]-]', '', 'g');
    IF v_phone !~ '^\+?[0-9]+$' THEN
        v_phone := NULL;
    END IF;

    WITH found AS (
        SELECT s.id, s.name FROM public.suppliers s
        WHERE s.organization_id = v_org
          AND CASE COALESCE(p_status, 'active')
                WHEN 'active' THEN s.archived_at IS NULL
                WHEN 'archived' THEN s.archived_at IS NOT NULL
                ELSE true END
          AND (v_search IS NULL
               OR s.name ILIKE '%' || v_like || '%'
               OR (v_phone IS NOT NULL AND s.phone LIKE v_phone || '%'))
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.supplier_json(v_org, pg.id) ORDER BY pg.name, pg.id)
            FROM (SELECT f.* FROM found f ORDER BY f.name, f.id LIMIT p_limit OFFSET p_offset) pg), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Archived included: old documents keep showing the supplier.
CREATE FUNCTION public.get_supplier(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_json jsonb;
BEGIN
    PERFORM app.supplier_read_guard();
    v_json := app.supplier_json(app.current_org_id(), p_id);
    IF v_json IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_json;
END;
$$;

-- Rows: approved invoices (debit), payments (credit), payment reversals (debit) and returns
-- (credit when supplier_credit; 0 and 0 when the supplier refunded cash). Shop-wide (decision 4).
-- Ordered by date, created_at, id. opening = the net of the rows before p_from; each row's
-- balance runs from it; closing = opening + the net of the rows shown.
CREATE FUNCTION public.supplier_statement(p_id uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_supplier jsonb; v_opening numeric(18,2); v_result jsonb;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    v_supplier := app.supplier_json(v_org, p_id);
    IF v_supplier IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_from > p_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: from' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(sum(s.debit - s.credit), 0) INTO v_opening
    FROM app.supplier_statement_rows(v_org, p_id) s WHERE p_from IS NOT NULL AND s.d < p_from;

    WITH shown AS (
        SELECT s.*, v_opening + sum(s.debit - s.credit)
                   OVER (ORDER BY s.d, s.created_at, s.id ROWS UNBOUNDED PRECEDING) AS balance
        FROM app.supplier_statement_rows(v_org, p_id) s
        WHERE (p_from IS NULL OR s.d >= p_from) AND (p_to IS NULL OR s.d <= p_to)
    )
    SELECT jsonb_build_object(
        'supplier', v_supplier,
        'from', p_from,
        'to', p_to,
        'opening_balance', v_opening::text,
        'closing_balance', (v_opening + COALESCE((SELECT sum(x.debit - x.credit) FROM shown x), 0))::numeric(18,2)::text,
        'totals', jsonb_build_object(
            'invoiced', COALESCE((SELECT sum(x.debit) FROM shown x WHERE x.kind = 'invoice'), 0)::numeric(18,2)::text,
            'paid', COALESCE((SELECT sum(x.credit - x.debit) FROM shown x
                              WHERE x.kind IN ('payment', 'payment_reversal')), 0)::numeric(18,2)::text,
            'returned', COALESCE((SELECT sum(x.credit) FROM shown x WHERE x.kind = 'return'), 0)::numeric(18,2)::text),
        'rows', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'date', x.d, 'kind', x.kind, 'document_id', x.id, 'number', x.number,
                'reference', x.reference, 'branch_id', x.branch_id, 'refund_mode', x.refund_mode,
                'debit', x.debit::numeric(18,2)::text, 'credit', x.credit::numeric(18,2)::text,
                'balance', x.balance::numeric(18,2)::text)
                ORDER BY x.d, x.created_at, x.id)
            FROM shown x), '[]'::jsonb))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 4. Writes (supplier.manage) -----------------------------------------------------------------

CREATE FUNCTION public.create_supplier(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; r public.suppliers; v_id uuid; v_constraint text; v_json jsonb;
BEGIN
    v_emp := app.require_permission('supplier.manage');
    v_org := app.current_org_id();
    IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (p ? 'name') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: name' USING ERRCODE = 'P0001';
    END IF;
    r.payment_terms_days := 0;
    r := app.supplier_apply(r, p);
    BEGIN
        INSERT INTO public.suppliers (organization_id, name, phone, tax_registration_no, address,
            payment_terms_days, notes, created_by, updated_by)
        VALUES (v_org, r.name, r.phone, r.tax_registration_no, r.address, r.payment_terms_days,
            r.notes, v_emp, v_emp)
        RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        PERFORM app.supplier_unique_error(v_constraint);
    END;
    v_json := app.supplier_json(v_org, v_id);
    PERFORM app.write_audit('supplier.created', 'supplier', v_id, p_after => v_json - 'balance');
    RETURN v_json;
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: supplier' USING ERRCODE = 'P0001';
END;
$$;

-- An archived supplier can't be edited (restore first). Before/after hold the changed keys only.
CREATE FUNCTION public.update_supplier(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_old public.suppliers; r public.suppliers; v_constraint text;
    v_old_json jsonb; v_new_json jsonb; v_before jsonb; v_after jsonb;
BEGIN
    v_emp := app.require_permission('supplier.manage');
    v_org := app.current_org_id();
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.suppliers
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND OR v_old.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    r := app.supplier_apply(v_old, p_changes);
    v_old_json := app.supplier_fields_json(v_old);
    v_new_json := app.supplier_fields_json(r);
    IF v_new_json = v_old_json THEN
        RETURN app.supplier_json(v_org, p_id);           -- no change: no update, no audit row
    END IF;

    BEGIN
        UPDATE public.suppliers SET
            name = r.name, phone = r.phone, tax_registration_no = r.tax_registration_no,
            address = r.address, payment_terms_days = r.payment_terms_days, notes = r.notes,
            updated_by = v_emp
        WHERE id = p_id;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        PERFORM app.supplier_unique_error(v_constraint);
    END;

    SELECT jsonb_object_agg(k, v_old_json -> k), jsonb_object_agg(k, v_new_json -> k)
    INTO v_before, v_after
    FROM jsonb_object_keys(v_new_json) k
    WHERE (v_old_json -> k) IS DISTINCT FROM (v_new_json -> k);
    PERFORM app.write_audit('supplier.updated', 'supplier', p_id, p_before => v_before, p_after => v_after);
    RETURN app.supplier_json(v_org, p_id);
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: supplier' USING ERRCODE = 'P0001';
END;
$$;

-- Archive: refused with a balance or open documents (decision 2). Restore: rule 1 applies again.
-- Same state again: nothing changes, no audit row.
CREATE FUNCTION public.set_supplier_archived(p_id uuid, p_archived boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_old public.suppliers; v_constraint text; v_new_archived timestamptz;
BEGIN
    v_emp := app.require_permission('supplier.manage');
    v_org := app.current_org_id();
    IF p_archived IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: archived' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.suppliers
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF (v_old.archived_at IS NOT NULL) = p_archived THEN
        RETURN app.supplier_json(v_org, p_id);
    END IF;

    IF p_archived THEN
        IF COALESCE((SELECT b.balance FROM public.v_supplier_balances b
                     WHERE b.supplier_id = p_id AND b.organization_id = v_org), 0) <> 0 THEN
            RAISE EXCEPTION 'SUPPLIER_HAS_BALANCE' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM public.purchase_invoices pi
                   WHERE pi.organization_id = v_org AND pi.supplier_id = p_id
                     AND pi.status IN ('draft', 'pending_approval'))
           OR EXISTS (SELECT 1 FROM public.purchase_orders po
                      WHERE po.organization_id = v_org AND po.supplier_id = p_id
                        AND po.status IN ('draft', 'sent', 'partially_received')) THEN
            RAISE EXCEPTION 'SUPPLIER_HAS_OPEN_DOCUMENTS' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    BEGIN
        UPDATE public.suppliers SET
            archived_at = CASE WHEN p_archived THEN now() END,
            updated_by = v_emp
        WHERE id = p_id
        RETURNING archived_at INTO v_new_archived;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        PERFORM app.supplier_unique_error(v_constraint);
    END;
    PERFORM app.write_audit(CASE WHEN p_archived THEN 'supplier.archived' ELSE 'supplier.restored' END,
        'supplier', p_id,
        p_before => jsonb_build_object('archived_at', v_old.archived_at),
        p_after => jsonb_build_object('archived_at', v_new_archived),
        p_severity => CASE WHEN p_archived THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.supplier_json(v_org, p_id);
END;
$$;

REVOKE ALL ON FUNCTION public.list_suppliers(text, text, integer, integer), public.get_supplier(uuid),
    public.supplier_statement(uuid, date, date), public.create_supplier(jsonb),
    public.update_supplier(uuid, jsonb), public.set_supplier_archived(uuid, boolean)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_suppliers(text, text, integer, integer), public.get_supplier(uuid),
    public.supplier_statement(uuid, date, date), public.create_supplier(jsonb),
    public.update_supplier(uuid, jsonb), public.set_supplier_archived(uuid, boolean)
    TO authenticated;
