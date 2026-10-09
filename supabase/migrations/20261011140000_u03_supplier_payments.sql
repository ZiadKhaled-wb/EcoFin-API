-- =============================================================================
-- U03 · Supplier payments (EC-55, D58)
--
-- An accountant, manager or owner pays a supplier from an active safe or bank of the payment's
-- branch (or a shop-wide bank). Every payment is fully allocated to the supplier's approved
-- invoices: the given allocations (each at most that invoice's outstanding, adding up to the
-- amount), or oldest invoice first when none are given. Never more than what is owed
-- (PAYMENT_EXCEEDS_OUTSTANDING); no payments on account. The money leaves through the cash
-- ledger (supplier_payment, -amount): the ledger trigger refuses a safe below 0
-- (INSUFFICIENT_FUNDS) and a closed day. Numbered SP; idempotent by key (a double click pays once).
-- The owner reverses a payment with a reason: a linked SP row and a +amount movement; the
-- baseline views then leave both out, so the invoice and supplier balances go back up.
-- Reads: any purchasing read key (D53), the caller's branches; also in an expired shop.
-- =============================================================================

-- 1. JSON for the API --------------------------------------------------------------------------------

CREATE FUNCTION app.supplier_payment_json(p_org uuid, p_id uuid, p_with_allocations boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', p.id, 'number', p.number, 'supplier_id', p.supplier_id, 'supplier_name', s.name,
        'branch_id', p.branch_id, 'cash_account_id', p.cash_account_id, 'cash_account_name', a.name,
        'amount', p.amount::text, 'reference', p.reference, 'business_date', p.business_date,
        'paid_at', p.paid_at, 'reverses_payment_id', p.reverses_payment_id,
        'reversed_by_payment_id', (SELECT r.id FROM public.supplier_payments r
                                   WHERE r.organization_id = p_org AND r.reverses_payment_id = p.id),
        'reason', p.reason, 'created_by_name', e.full_name)
        || CASE WHEN p_with_allocations THEN jsonb_build_object('allocations', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('purchase_invoice_id', al.purchase_invoice_id,
                                                'invoice_number', i.number, 'amount', al.amount::text)
                             ORDER BY i.invoice_date, i.number, al.id)
            FROM public.supplier_payment_allocations al
            JOIN public.purchase_invoices i ON i.id = al.purchase_invoice_id AND i.organization_id = al.organization_id
            WHERE al.organization_id = p_org AND al.supplier_payment_id = p.id), '[]'::jsonb))
           ELSE '{}'::jsonb END
    FROM public.supplier_payments p
    JOIN public.suppliers s ON s.id = p.supplier_id AND s.organization_id = p.organization_id
    JOIN public.cash_accounts a ON a.id = p.cash_account_id AND a.organization_id = p.organization_id
    LEFT JOIN public.employees e ON e.id = p.created_by AND e.organization_id = p.organization_id
    WHERE p.organization_id = p_org AND p.id = p_id
$$;

-- 2. Posting -----------------------------------------------------------------------------------------

-- p_allocations: [{purchase_invoice_id, amount}] or NULL (oldest invoice first).
CREATE FUNCTION public.post_supplier_payment(p_supplier_id uuid, p_branch_id uuid, p_cash_account_id uuid,
                                             p_amount text, p_idempotency_key text,
                                             p_reference text DEFAULT NULL, p_allocations jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_p public.supplier_payments; v_a public.cash_accounts; v_amount numeric(18,2);
    v_ref text; v_date date; r record; v_left numeric(18,2); v_take numeric(18,2); v_total numeric(18,2);
    v_plan jsonb := '[]';
BEGIN
    v_emp := app.require_permission('supplier.payment_create');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_p FROM public.supplier_payments x
    WHERE x.organization_id = v_org AND x.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.supplier_payment_json(v_org, v_p.id, true);     -- a repeat pays nothing
    END IF;

    -- The supplier row is locked: two payments to one supplier never share the same outstanding.
    PERFORM 1 FROM public.suppliers s WHERE s.id = p_supplier_id AND s.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    v_amount := app.cash_amount(p_amount);
    v_ref := NULLIF(btrim(p_reference), '');
    IF length(v_ref) > 100 OR p_cash_account_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: payment' USING ERRCODE = 'P0001';
    END IF;
    v_a := app.payable_cash_account(v_org, p_cash_account_id, p_branch_id);

    -- The supplier's approved invoices the caller can reach, locked in id order (a credit return
    -- locks its invoice too), then read with what is still owed on each.
    PERFORM 1 FROM public.purchase_invoices i
    WHERE i.organization_id = v_org AND i.supplier_id = p_supplier_id AND i.status = 'approved'
    ORDER BY i.id FOR UPDATE;

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) = 'null' THEN
        -- Oldest invoice first.
        v_left := v_amount;
        FOR r IN SELECT i.id, i.number, b.outstanding
                 FROM public.purchase_invoices i
                 JOIN public.v_purchase_invoice_balances b ON b.purchase_invoice_id = i.id
                 WHERE i.organization_id = v_org AND i.supplier_id = p_supplier_id AND i.status = 'approved'
                   AND b.outstanding > 0 AND app.has_branch_access(i.branch_id)
                 ORDER BY i.invoice_date, i.number, i.id LOOP
            EXIT WHEN v_left = 0;
            v_take := least(v_left, r.outstanding);
            v_plan := v_plan || jsonb_build_object('purchase_invoice_id', r.id, 'amount', v_take::text);
            v_left := v_left - v_take;
        END LOOP;
        IF v_left > 0 THEN
            RAISE EXCEPTION 'PAYMENT_EXCEEDS_OUTSTANDING: the supplier is owed %', v_amount - v_left
                USING ERRCODE = 'P0001',
                      DETAIL = jsonb_build_object('purchase_invoice_id', NULL,
                                                  'outstanding', (v_amount - v_left)::text)::text;
        END IF;
    ELSE
        IF jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations) NOT BETWEEN 1 AND 100
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_allocations) x
                      WHERE jsonb_typeof(x) <> 'object'
                         OR EXISTS (SELECT 1 FROM jsonb_object_keys(x) k WHERE k NOT IN ('purchase_invoice_id', 'amount'))
                         OR jsonb_typeof(x -> 'purchase_invoice_id') IS DISTINCT FROM 'string'
                         OR (x ->> 'purchase_invoice_id') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                         OR jsonb_typeof(x -> 'amount') IS DISTINCT FROM 'string'
                         OR (x ->> 'amount') !~ '^\d{1,16}(\.\d{1,2})?$'
                         OR (x ->> 'amount')::numeric <= 0)
           OR (SELECT count(DISTINCT x ->> 'purchase_invoice_id') FROM jsonb_array_elements(p_allocations) x)
              <> jsonb_array_length(p_allocations) THEN
            RAISE EXCEPTION 'ALLOCATION_INVALID: allocations' USING ERRCODE = 'P0001';
        END IF;
        SELECT sum((x ->> 'amount')::numeric(18,2)) INTO v_total FROM jsonb_array_elements(p_allocations) x;
        IF v_total <> v_amount THEN
            RAISE EXCEPTION 'ALLOCATION_INVALID: the allocations add up to %, not %', v_total, v_amount
                USING ERRCODE = 'P0001';
        END IF;
        FOR r IN SELECT (x ->> 'purchase_invoice_id')::uuid AS id, (x ->> 'amount')::numeric(18,2) AS amount,
                        i.id AS found, i.branch_id, b.outstanding
                 FROM jsonb_array_elements(p_allocations) x
                 LEFT JOIN public.purchase_invoices i
                        ON i.id = (x ->> 'purchase_invoice_id')::uuid AND i.organization_id = v_org
                       AND i.supplier_id = p_supplier_id AND i.status = 'approved'
                 LEFT JOIN public.v_purchase_invoice_balances b ON b.purchase_invoice_id = i.id
                 ORDER BY 1 LOOP
            IF r.found IS NULL OR NOT app.has_branch_access(r.branch_id) THEN
                RAISE EXCEPTION 'ALLOCATION_INVALID: % is not an approved invoice of this supplier', r.id
                    USING ERRCODE = 'P0001';
            END IF;
            IF r.amount > r.outstanding THEN
                RAISE EXCEPTION 'PAYMENT_EXCEEDS_OUTSTANDING: % is owed %', r.id, r.outstanding
                    USING ERRCODE = 'P0001',
                          DETAIL = jsonb_build_object('purchase_invoice_id', r.id,
                                                      'outstanding', r.outstanding::text)::text;
            END IF;
            v_plan := v_plan || jsonb_build_object('purchase_invoice_id', r.id, 'amount', r.amount::text);
        END LOOP;
    END IF;

    v_date := app.org_today(v_org);
    INSERT INTO public.supplier_payments (organization_id, number, supplier_id, branch_id, cash_account_id,
        amount, business_date, reference, idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, p_branch_id, 'supplier_payment'), p_supplier_id, p_branch_id,
        v_a.id, v_amount, v_date, v_ref, p_idempotency_key, v_emp)
    RETURNING * INTO v_p;
    INSERT INTO public.supplier_payment_allocations (organization_id, supplier_payment_id, purchase_invoice_id,
                                                     amount, created_by)
    SELECT v_org, v_p.id, (x ->> 'purchase_invoice_id')::uuid, (x ->> 'amount')::numeric(18,2), v_emp
    FROM jsonb_array_elements(v_plan) x;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                       source_id, note, business_date, created_by, created_at)
    VALUES (v_org, v_a.id, COALESCE(v_a.branch_id, p_branch_id), -v_amount, 'supplier_payment',
            'supplier_payment', v_p.id, v_p.number, v_date, v_emp, clock_timestamp());

    PERFORM app.write_audit('supplier_payment.posted', 'supplier_payment', v_p.id, NULL,
        jsonb_build_object('number', v_p.number, 'supplier_id', p_supplier_id, 'amount', v_amount::text,
                           'cash_account_id', v_a.id, 'reference', v_ref, 'allocations', v_plan),
        NULL, p_branch_id);
    RETURN app.supplier_payment_json(v_org, v_p.id, true);
END;
$$;

-- The owner undoes a payment made by mistake: a linked SP row and the money back in the account.
CREATE FUNCTION public.reverse_supplier_payment(p_id uuid, p_reason text, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_p public.supplier_payments; v_r public.supplier_payments; v_reason text;
    v_date date; v_movement uuid; v_account_branch uuid;
BEGIN
    v_emp := app.require_permission('supplier.payment_create');
    v_org := app.current_org_id();
    IF app.current_role() <> 'OWNER' THEN
        RAISE EXCEPTION 'APPROVAL_OWNER_ONLY' USING ERRCODE = '42501';
    END IF;
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_r FROM public.supplier_payments x
    WHERE x.organization_id = v_org AND x.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_r.reverses_payment_id IS DISTINCT FROM p_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used for another payment' USING ERRCODE = 'P0001';
        END IF;
        RETURN app.supplier_payment_json(v_org, v_r.id, true);
    END IF;

    SELECT * INTO v_p FROM public.supplier_payments x WHERE x.id = p_id AND x.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_p.branch_id);
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    IF v_p.reverses_payment_id IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a reversal cannot be reversed' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.supplier_payments x
               WHERE x.organization_id = v_org AND x.reverses_payment_id = v_p.id) THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED' USING ERRCODE = 'P0001';
    END IF;

    SELECT m.id, m.branch_id INTO v_movement, v_account_branch FROM public.cash_movements m
    WHERE m.organization_id = v_org AND m.source_type = 'supplier_payment' AND m.source_id = v_p.id
      AND m.reverses_movement_id IS NULL;
    v_date := app.org_today(v_org);
    INSERT INTO public.supplier_payments (organization_id, number, supplier_id, branch_id, cash_account_id,
        amount, business_date, reference, reverses_payment_id, reason, idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, v_p.branch_id, 'supplier_payment'), v_p.supplier_id,
        v_p.branch_id, v_p.cash_account_id, v_p.amount, v_date, v_p.reference, v_p.id, v_reason,
        p_idempotency_key, v_emp)
    RETURNING * INTO v_r;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                       source_id, reverses_movement_id, note, business_date, created_by, created_at)
    VALUES (v_org, v_p.cash_account_id, COALESCE(v_account_branch, v_p.branch_id), v_p.amount, 'supplier_payment',
            'supplier_payment', v_r.id, v_movement, v_r.number, v_date, v_emp, clock_timestamp());

    PERFORM app.write_audit('supplier_payment.reversed', 'supplier_payment', v_p.id,
        jsonb_build_object('number', v_p.number, 'amount', v_p.amount::text),
        jsonb_build_object('reversal_id', v_r.id, 'reversal_number', v_r.number),
        v_reason, v_p.branch_id, 'warning');
    RETURN app.supplier_payment_json(v_org, v_r.id, true);
END;
$$;

-- 3. Reads -------------------------------------------------------------------------------------------

-- p_include_reversals false: only the payments that count (no reversals, no reversed payments).
CREATE FUNCTION public.list_supplier_payments(p_supplier_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
                                              p_from date DEFAULT NULL, p_to date DEFAULT NULL,
                                              p_include_reversals boolean DEFAULT true,
                                              p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
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
        SELECT p.id, p.business_date, p.paid_at FROM public.supplier_payments p
        WHERE p.organization_id = v_org AND p.branch_id = ANY(v_branches)
          AND (p_supplier_id IS NULL OR p.supplier_id = p_supplier_id)
          AND (p_from IS NULL OR p.business_date >= p_from)
          AND (p_to IS NULL OR p.business_date <= p_to)
          AND (COALESCE(p_include_reversals, true)
               OR (p.reverses_payment_id IS NULL
                   AND NOT EXISTS (SELECT 1 FROM public.supplier_payments r
                                   WHERE r.organization_id = v_org AND r.reverses_payment_id = p.id)))
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.supplier_payment_json(v_org, f.id, false)
                             ORDER BY f.business_date DESC, f.paid_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY business_date DESC, paid_at DESC, id DESC
                  LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Another shop's payment, or one of a branch the caller doesn't work in: not found.
CREATE FUNCTION public.get_supplier_payment(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    PERFORM app.supplier_read_guard();
    v_org := app.current_org_id();
    SELECT p.branch_id INTO v_branch FROM public.supplier_payments p WHERE p.id = p_id AND p.organization_id = v_org;
    IF NOT FOUND OR NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'SUPPLIER_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.supplier_payment_json(v_org, p_id, true);
END;
$$;

-- What a supplier is still owed, invoice by invoice (the caller's branches), oldest first. The due
-- date (invoice date + the supplier's payment terms) is for display only.
CREATE FUNCTION public.list_open_supplier_invoices(p_supplier_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_terms integer; v_today date;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('supplier.payment_create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: supplier.payment_create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    SELECT s.payment_terms_days INTO v_terms FROM public.suppliers s
    WHERE s.id = p_supplier_id AND s.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_today := app.org_today(v_org);
    RETURN (
        WITH open AS (
            SELECT i.id, i.number, i.supplier_invoice_no, i.branch_id, i.invoice_date,
                   b.total, b.paid, b.returned_credit, b.outstanding
            FROM public.purchase_invoices i
            JOIN public.v_purchase_invoice_balances b ON b.purchase_invoice_id = i.id
            WHERE i.organization_id = v_org AND i.supplier_id = p_supplier_id AND i.status = 'approved'
              AND b.outstanding > 0 AND app.has_branch_access(i.branch_id)
        )
        SELECT jsonb_build_object(
            'items', COALESCE(jsonb_agg(jsonb_build_object(
                'purchase_invoice_id', o.id, 'number', o.number, 'supplier_invoice_no', o.supplier_invoice_no,
                'branch_id', o.branch_id, 'invoice_date', o.invoice_date,
                'due_date', o.invoice_date + v_terms, 'overdue', o.invoice_date + v_terms < v_today,
                'total', o.total::text, 'paid', o.paid::text, 'returned_credit', o.returned_credit::text,
                'outstanding', o.outstanding::text)
                ORDER BY o.invoice_date, o.number, o.id), '[]'::jsonb),
            'total_outstanding', COALESCE(sum(o.outstanding), 0)::numeric(18,2)::text)
        FROM open o);
END;
$$;

-- 4. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.supplier_payment_json(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.post_supplier_payment(uuid, uuid, uuid, text, text, text, jsonb),
    public.reverse_supplier_payment(uuid, text, text),
    public.list_supplier_payments(uuid, uuid, date, date, boolean, integer, integer),
    public.get_supplier_payment(uuid), public.list_open_supplier_invoices(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_supplier_payment(uuid, uuid, uuid, text, text, text, jsonb),
    public.reverse_supplier_payment(uuid, text, text),
    public.list_supplier_payments(uuid, uuid, date, date, boolean, integer, integer),
    public.get_supplier_payment(uuid), public.list_open_supplier_invoices(uuid)
    TO authenticated;
