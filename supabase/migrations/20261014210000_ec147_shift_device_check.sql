-- EC-147: every POS write checks the still-paired device of its open shift.
-- NULL current_device_id is DEVICE_REVOKED (user correction); another valid device is DEVICE_MISMATCH.
CREATE FUNCTION app.require_shift_device(p_shift_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_device public.devices; v_current uuid;
BEGIN
    -- Trusted service-role platform jobs have no auth.uid() and may write without a POS token.
    IF auth.uid() IS NULL THEN RETURN; END IF;
    SELECT d.* INTO v_device FROM public.shifts s
    JOIN public.devices d ON d.id=s.device_id AND d.organization_id=s.organization_id
    WHERE s.id=p_shift_id AND s.organization_id=app.current_org_id() FOR SHARE OF d;
    IF NOT FOUND OR NOT v_device.is_active OR v_device.archived_at IS NOT NULL OR v_device.token_hash IS NULL THEN
        RAISE EXCEPTION 'DEVICE_REVOKED' USING ERRCODE='42501';
    END IF;
    v_current := app.current_device_id();
    IF v_current IS NULL THEN RAISE EXCEPTION 'DEVICE_REVOKED' USING ERRCODE='42501'; END IF;
    IF v_current <> v_device.id THEN RAISE EXCEPTION 'DEVICE_MISMATCH' USING ERRCODE='42501'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION app.require_shift_device(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app.sales_device_from_shift()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_device uuid;
BEGIN
    IF NEW.shift_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.device_id INTO v_device FROM public.shifts s
    WHERE s.id = NEW.shift_id AND s.organization_id = NEW.organization_id;
    IF NEW.device_id IS NOT NULL AND NEW.device_id IS DISTINCT FROM v_device THEN
        RAISE EXCEPTION 'DEVICE_MISMATCH: a sale is made on its shift''s device' USING ERRCODE = 'P0001';
    END IF;
    NEW.device_id := v_device;
    PERFORM app.require_shift_device(NEW.shift_id);
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION app.sales_device_from_shift() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.move_shift_cash(p_shift_id uuid, p_direction text, p_amount text, p_vault_id uuid,
                                       p_note text, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_s public.shifts; v_amount numeric(18,2); v_note text; v_vault public.cash_accounts;
    v_t public.cash_transfers; v_id uuid;
BEGIN
    v_emp := app.require_permission('shift.operate');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    v_s := app.shift_for_write(v_org, v_emp, p_shift_id);
    SELECT * INTO v_t FROM public.cash_transfers t
    WHERE t.organization_id = v_org AND t.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_s.drawer_account_id NOT IN (v_t.from_account_id, v_t.to_account_id) THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used for another transfer' USING ERRCODE = 'P0001';
        END IF;
        RETURN app.shift_json(v_org, v_s.id, true);          -- a repeat changes nothing
    END IF;
    PERFORM app.require_branch_access(v_s.branch_id);
    IF v_s.status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_shift_device(p_shift_id);
    v_note := btrim(p_note);
    IF p_direction IS NULL OR p_direction NOT IN ('in', 'out')
       OR v_note IS NULL OR length(v_note) NOT BETWEEN 3 AND 500 OR p_vault_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: cash move' USING ERRCODE = 'P0001';
    END IF;
    v_amount := app.cash_amount(p_amount);
    v_vault := app.shift_vault(v_org, p_vault_id, v_s.branch_id);
    v_id := app.shift_transfer(v_org, v_emp, v_s, v_vault, v_amount, p_direction = 'in', v_note, p_idempotency_key);

    PERFORM app.write_audit('shift.cash_moved', 'shift', v_s.id, NULL,
        jsonb_build_object('number', v_s.number, 'direction', p_direction, 'amount', v_amount::text,
                           'vault_id', p_vault_id, 'transfer_id', v_id),
        v_note, v_s.branch_id);
    RETURN app.shift_json(v_org, v_s.id, true);
END;
$$;
REVOKE ALL ON FUNCTION public.move_shift_cash(uuid,text,text,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.move_shift_cash(uuid,text,text,uuid,text,text) TO authenticated;

CREATE FUNCTION app.close_shift_internal(v_org uuid, v_emp uuid, v_s public.shifts, v_counted numeric, p_counts jsonb, p_vault_id uuid, p_difference_reason text, p_force boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE p_id uuid:=v_s.id; v_expected numeric(18,2); v_diff numeric(18,2); v_reason text; v_vault public.cash_accounts; v_transfer uuid;
BEGIN
    v_expected := app.shift_expected(v_org, v_s);
    v_diff := v_counted - v_expected;
    v_reason := NULLIF(btrim(p_difference_reason), '');
    IF length(v_reason) > 500 OR (v_diff <> 0 AND (v_reason IS NULL OR length(v_reason) < 3)) THEN
        RAISE EXCEPTION 'SHIFT_DIFFERENCE_REASON_REQUIRED: expected %, counted %', v_expected, v_counted
            USING ERRCODE = 'P0001',
                  DETAIL = jsonb_build_object('expected', v_expected::text, 'counted', v_counted::text,
                                              'difference', v_diff::text)::text;
    END IF;
    IF v_diff = 0 AND NOT p_force THEN
        v_reason := NULL;
    END IF;
    IF (v_counted > 0) <> (p_vault_id IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: counted cash needs the safe it goes to' USING ERRCODE = 'P0001';
    END IF;

    -- The drawer is brought to what was counted, then emptied into the safe.
    IF v_diff <> 0 THEN
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                           source_type, source_id, note, business_date, created_by, created_at)
        VALUES (v_org, v_s.drawer_account_id, v_s.branch_id, v_s.id, v_diff, 'adjustment', 'shift', v_s.id,
                v_reason, app.org_today(v_org), v_emp, clock_timestamp());
    END IF;
    IF v_counted > 0 THEN
        v_vault := app.shift_vault(v_org, p_vault_id, v_s.branch_id);
        v_transfer := app.shift_transfer(v_org, v_emp, v_s, v_vault, v_counted, false, v_s.number,
                                         'system:shift-close:' || v_s.id);
    END IF;
    UPDATE public.shifts s
       SET status = 'closed', closed_at = now(), closed_by = v_emp, counted_cash = v_counted,
           count_breakdown = p_counts, expected_cash = v_expected, difference_reason = v_reason, updated_by = v_emp
     WHERE s.id = p_id;

    PERFORM app.write_audit(CASE WHEN p_force THEN 'shift.force_closed' ELSE 'shift.closed' END, 'shift', p_id,
        jsonb_build_object('status', 'open'),
        jsonb_build_object('status', 'closed', 'number', v_s.number, 'expected', v_expected::text,
                           'counted', v_counted::text, 'difference', v_diff::text, 'vault_id', p_vault_id,
                           'transfer_id', v_transfer),
        v_reason, v_s.branch_id, CASE WHEN p_force OR v_diff <> 0 THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.shift_json(v_org, p_id, true);
END;
$$;
REVOKE ALL ON FUNCTION app.close_shift_internal(uuid,uuid,public.shifts,numeric,jsonb,uuid,text,boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.close_shift(p_id uuid, p_counts jsonb, p_vault_id uuid DEFAULT NULL,
                                   p_difference_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_s public.shifts; v_counted numeric(18,2); v_expected numeric(18,2);
    v_diff numeric(18,2); v_reason text; v_vault public.cash_accounts; v_transfer uuid;
BEGIN
    v_emp := app.require_permission('shift.operate');
    v_org := app.current_org_id();
    v_s := app.shift_for_write(v_org, v_emp, p_id);
    IF v_s.status = 'closed' THEN
        RETURN app.shift_json(v_org, p_id, true);            -- a repeat changes nothing
    END IF;
    PERFORM app.require_branch_access(v_s.branch_id);

    PERFORM app.require_shift_device(p_id);

    IF p_counts IS NULL OR jsonb_typeof(p_counts) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_each(p_counts) c
                  WHERE c.key NOT IN ('200', '100', '50', '20', '10', '5', '1', '0.5', '0.25')
                     OR jsonb_typeof(c.value) <> 'number'
                     OR (c.value #>> '{}')::numeric <> trunc((c.value #>> '{}')::numeric)
                     OR (c.value #>> '{}')::numeric NOT BETWEEN 0 AND 100000) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: counts' USING ERRCODE = 'P0001';
    END IF;
    SELECT COALESCE(sum(c.key::numeric * (c.value #>> '{}')::numeric), 0)::numeric(18,2) INTO v_counted
    FROM jsonb_each(p_counts) c;
    RETURN app.close_shift_internal(v_org,v_emp,v_s,v_counted,p_counts,p_vault_id,p_difference_reason,false);
END;
$$;
REVOKE ALL ON FUNCTION public.close_shift(uuid,jsonb,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_shift(uuid,jsonb,uuid,text) TO authenticated;

CREATE FUNCTION public.force_close_shift(p_shift_id uuid, p_counted_cash text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_s public.shifts; v_counted numeric(18,2); v_vault uuid; v_reason text;
BEGIN
    v_emp:=app.require_permission('cash.adjust');
    v_org:=app.current_org_id();
    SELECT * INTO v_s FROM public.shifts s WHERE s.id=p_shift_id AND s.organization_id=v_org FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(v_s.branch_id) THEN RAISE EXCEPTION 'SHIFT_NOT_FOUND' USING ERRCODE='P0001'; END IF;
    PERFORM app.require_branch_access(v_s.branch_id);
    v_reason:=NULLIF(btrim(p_reason),'');
    IF v_reason IS NULL THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='P0001'; END IF;
    IF length(v_reason) NOT BETWEEN 3 AND 500 OR p_counted_cash IS NULL OR p_counted_cash !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001';
    END IF;
    v_counted:=p_counted_cash::numeric(18,2);
    IF v_s.status='closed' THEN RETURN app.shift_json(v_org,p_shift_id,true); END IF;
    -- The endpoint has no vault selector: use this branch's configured default safe.
    IF v_counted>0 THEN SELECT b.default_cash_account_id INTO v_vault FROM public.branches b WHERE b.id=v_s.branch_id AND b.organization_id=v_org; END IF;
    RETURN app.close_shift_internal(v_org,v_emp,v_s,v_counted,NULL,v_vault,v_reason,true);
END;
$$;
REVOKE ALL ON FUNCTION public.force_close_shift(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.force_close_shift(uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.post_expense(p_category_id uuid, p_amount text, p_idempotency_key text,
                                    p_branch_id uuid DEFAULT NULL, p_cash_account_id uuid DEFAULT NULL,
                                    p_from_shift boolean DEFAULT false, p_note text DEFAULT NULL,
                                    p_receipt_file_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_x public.expenses; v_amount numeric(18,2); v_note text; v_archived timestamptz;
    v_account uuid; v_branch uuid; v_shift public.shifts; v_a public.cash_accounts; v_date date;
BEGIN
    v_emp := app.require_permission('expense.create');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_x FROM public.expenses x WHERE x.organization_id = v_org AND x.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.expense_json(v_org, v_x.id);              -- a repeat spends nothing
    END IF;

    SELECT c.archived_at INTO v_archived FROM public.expense_categories c
    WHERE c.id = p_category_id AND c.organization_id = v_org FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_archived IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_ARCHIVED' USING ERRCODE = 'P0001';
    END IF;
    v_amount := app.cash_amount(p_amount);
    v_note := NULLIF(btrim(p_note), '');
    IF length(v_note) > 500 OR COALESCE(p_from_shift, false) = (p_cash_account_id IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: an expense leaves a vault or the open shift, one of the two'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_receipt_file_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.files f
        WHERE f.id = p_receipt_file_id AND f.organization_id = v_org AND f.purpose = 'expense_receipt') THEN
        RAISE EXCEPTION 'FILE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    IF COALESCE(p_from_shift, false) THEN
        v_shift := app.require_open_shift(v_org, v_emp);
        PERFORM 1 FROM public.shifts s WHERE s.id = v_shift.id FOR UPDATE;
        PERFORM app.require_shift_device(v_shift.id);
        v_branch := v_shift.branch_id;
        v_account := v_shift.drawer_account_id;
        PERFORM app.require_branch_access(v_branch);
    ELSE
        IF p_branch_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.require_branch_access(p_branch_id);
        v_branch := p_branch_id;
        v_a := app.payable_cash_account(v_org, p_cash_account_id, p_branch_id);
        v_account := v_a.id;
    END IF;

    v_date := app.org_today(v_org);
    INSERT INTO public.expenses (organization_id, number, branch_id, category_id, amount, cash_account_id,
                                 shift_id, note, receipt_file_id, business_date, idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, v_branch, 'expense'), v_branch, p_category_id, v_amount,
            v_account, v_shift.id, v_note, p_receipt_file_id, v_date, p_idempotency_key, v_emp)
    RETURNING * INTO v_x;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                       source_type, source_id, note, business_date, created_by, created_at)
    VALUES (v_org, v_account, v_branch, v_shift.id, -v_amount, 'expense', 'expense', v_x.id, v_x.number,
            v_date, v_emp, clock_timestamp());

    PERFORM app.write_audit('expense.posted', 'expense', v_x.id, NULL,
        jsonb_build_object('number', v_x.number, 'category_id', p_category_id, 'amount', v_amount::text,
                           'cash_account_id', v_account, 'shift_id', v_shift.id,
                           'receipt_file_id', p_receipt_file_id),
        v_note, v_branch);
    RETURN app.expense_json(v_org, v_x.id);
END;
$$;
REVOKE ALL ON FUNCTION public.post_expense(uuid,text,text,uuid,uuid,boolean,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_expense(uuid,text,text,uuid,uuid,boolean,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.reverse_expense(p_id uuid, p_reason text, p_idempotency_key text,
                                       p_cash_account_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_x public.expenses; v_r public.expenses; v_reason text; v_date date;
    v_movement uuid; v_account uuid; v_shift uuid; v_a public.cash_accounts;
BEGIN
    v_emp := app.require_permission('expense.create');
    v_org := app.current_org_id();
    IF app.current_role() <> 'OWNER' THEN
        RAISE EXCEPTION 'APPROVAL_OWNER_ONLY' USING ERRCODE = '42501';
    END IF;
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_r FROM public.expenses x WHERE x.organization_id = v_org AND x.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_r.reverses_expense_id IS DISTINCT FROM p_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used for another expense' USING ERRCODE = 'P0001';
        END IF;
        RETURN app.expense_json(v_org, v_r.id);
    END IF;

    SELECT * INTO v_x FROM public.expenses x WHERE x.id = p_id AND x.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_x.branch_id);
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    IF v_x.reverses_expense_id IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a reversal cannot be reversed' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.expenses r WHERE r.organization_id = v_org AND r.reverses_expense_id = v_x.id) THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED' USING ERRCODE = 'P0001';
    END IF;

    -- Where the money goes back: the same account, with the shift when it is still open.
    v_account := v_x.cash_account_id;
    v_shift := v_x.shift_id;
    IF v_x.shift_id IS NOT NULL
       AND (SELECT s.status FROM public.shifts s WHERE s.id = v_x.shift_id FOR UPDATE) <> 'open' THEN
        IF p_cash_account_id IS NULL THEN
            RAISE EXCEPTION 'VAULT_INVALID: the shift is closed, choose the vault the money goes back to'
                USING ERRCODE = 'P0001';
        END IF;
        v_a := app.payable_cash_account(v_org, p_cash_account_id, v_x.branch_id);
        v_account := v_a.id;
        v_shift := NULL;
    ELSIF p_cash_account_id IS NOT NULL AND p_cash_account_id <> v_x.cash_account_id THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: the money goes back to the account it left' USING ERRCODE = 'P0001';
    END IF;

    IF v_shift IS NOT NULL THEN PERFORM app.require_shift_device(v_shift); END IF;

    SELECT m.id INTO v_movement FROM public.cash_movements m
    WHERE m.organization_id = v_org AND m.source_type = 'expense' AND m.source_id = v_x.id
      AND m.reverses_movement_id IS NULL;
    v_date := app.org_today(v_org);
    INSERT INTO public.expenses (organization_id, number, branch_id, category_id, amount, cash_account_id,
                                 shift_id, note, receipt_file_id, reverses_expense_id, business_date,
                                 idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, v_x.branch_id, 'expense'), v_x.branch_id, v_x.category_id,
            v_x.amount, v_account, v_shift, v_reason, NULL, v_x.id, v_date, p_idempotency_key, v_emp)
    RETURNING * INTO v_r;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                       source_type, source_id, reverses_movement_id, note, business_date,
                                       created_by, created_at)
    VALUES (v_org, v_account, v_x.branch_id, v_shift, v_x.amount, 'expense', 'expense', v_r.id, v_movement,
            v_r.number, v_date, v_emp, clock_timestamp());

    PERFORM app.write_audit('expense.reversed', 'expense', v_x.id,
        jsonb_build_object('number', v_x.number, 'amount', v_x.amount::text),
        jsonb_build_object('reversal_id', v_r.id, 'reversal_number', v_r.number, 'cash_account_id', v_account),
        v_reason, v_x.branch_id, 'warning');
    RETURN app.expense_json(v_org, v_r.id);
END;
$$;
REVOKE ALL ON FUNCTION public.reverse_expense(uuid,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_expense(uuid,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.void_sale(p_sale_id uuid,p_reason text,p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE emp uuid:=app.require_permission('sale.void'); o uuid:=app.current_org_id();
    s public.sales; sh public.shifts; v_return public.sales_returns; l public.sale_lines;
    m public.stock_movements; cm public.cash_movements; pay public.payments;
    v_line uuid; v_payment uuid; v_method public.refund_method;
BEGIN
    PERFORM app.lock_idempotency_key(o,p_idempotency_key);
    IF p_idempotency_key LIKE 'system:%' THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
    SELECT * INTO s FROM public.sales WHERE id=p_sale_id AND organization_id=o FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(s.branch_id) THEN RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
    PERFORM app.require_branch_access(s.branch_id);
    SELECT * INTO v_return FROM public.sales_returns WHERE organization_id=o AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_return.sale_id<>s.id OR v_return.kind<>'void' THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='P0001'; END IF;
        RETURN jsonb_build_object('return_id',v_return.id,'number',v_return.number);
    END IF;
    SELECT * INTO sh FROM public.shifts WHERE id=s.shift_id AND organization_id=o FOR UPDATE;
    IF sh.status='open' THEN PERFORM app.require_shift_device(sh.id); END IF;
    PERFORM 1 FROM public.sale_lines sl WHERE sl.sale_id=s.id ORDER BY sl.product_id,sl.id FOR UPDATE;
    PERFORM 1 FROM public.stock_movements sm WHERE sm.organization_id=o AND sm.source_type='sale' AND sm.source_id=s.id
        ORDER BY sm.product_id,sm.id FOR UPDATE;
    PERFORM 1 FROM public.stock_levels sl WHERE sl.organization_id=o AND sl.branch_id=s.branch_id
        AND sl.product_id IN(SELECT x.product_id FROM public.sale_lines x WHERE x.sale_id=s.id)
        ORDER BY sl.product_id,sl.stock_state FOR UPDATE;
    PERFORM 1 FROM public.fiscal_submissions f WHERE f.sale_id=s.id AND f.organization_id=o FOR UPDATE;
    IF EXISTS(SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id AND r.kind='void') THEN RAISE EXCEPTION 'ALREADY_VOIDED' USING ERRCODE='P0001'; END IF;
    IF s.business_date<>app.org_today(o) THEN RAISE EXCEPTION 'VOID_NOT_SAME_DAY' USING ERRCODE='P0001'; END IF;
    IF sh.id IS NULL OR sh.status<>'open' THEN RAISE EXCEPTION 'VOID_SHIFT_CLOSED' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id) THEN RAISE EXCEPTION 'VOID_HAS_RETURNS' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.warranty_claims w JOIN public.sale_lines sl ON sl.id=w.sale_line_id WHERE sl.sale_id=s.id) THEN RAISE EXCEPTION 'VOID_HAS_CLAIMS' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.contracts c WHERE c.sale_id=s.id) THEN RAISE EXCEPTION 'VOID_HAS_CONTRACT' USING ERRCODE='P0001'; END IF;
    IF EXISTS(SELECT 1 FROM public.fiscal_submissions f WHERE f.sale_id=s.id AND f.eta_uuid IS NOT NULL) THEN RAISE EXCEPTION 'VOID_FISCALIZED' USING ERRCODE='P0001'; END IF;
    IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 200 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='P0001'; END IF;
    SELECT p.method::text::public.refund_method INTO v_method FROM public.payments p
        JOIN public.payment_allocations a ON a.payment_id=p.id WHERE a.sale_id=s.id AND p.direction='in'
        ORDER BY p.amount DESC,p.id LIMIT 1;
    INSERT INTO public.sales_returns(organization_id,number,sale_id,branch_id,shift_id,kind,refund_method,
        subtotal,tax_total,total,reason,business_date,idempotency_key,created_by)
    VALUES(o,app.next_document_number(o,s.branch_id,'sales_return'),s.id,s.branch_id,s.shift_id,'void',v_method,
        s.subtotal,s.tax_total,s.total,btrim(p_reason),app.org_today(o),p_idempotency_key,emp) RETURNING * INTO v_return;
    FOR l IN SELECT * FROM public.sale_lines WHERE sale_id=s.id ORDER BY product_id,id LOOP
        INSERT INTO public.sales_return_lines(organization_id,return_id,sale_line_id,unit_id,quantity,condition,refund_amount,tax_amount,unit_cost,created_by)
        VALUES(o,v_return.id,l.id,l.unit_id,l.quantity,'resellable',l.line_total,l.tax_amount,l.unit_cost,emp) RETURNING id INTO v_line;
        FOR m IN SELECT * FROM public.stock_movements WHERE organization_id=o AND source_type='sale' AND source_id=s.id AND source_line_id=l.id AND type='sale_out' ORDER BY id LOOP
            INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,stock_state,unit_cost,source_type,source_id,source_line_id,reverses_movement_id,business_date,created_by)
            VALUES(o,m.product_id,m.branch_id,m.unit_id,-m.quantity,'sale_return_in',m.stock_state,m.unit_cost,'sales_return',v_return.id,v_line,m.id,app.org_today(o),emp);
        END LOOP;
    END LOOP;
    FOR pay IN SELECT p.* FROM public.payments p JOIN public.payment_allocations a ON a.payment_id=p.id
        WHERE a.sale_id=s.id AND p.organization_id=o AND p.direction='in' ORDER BY p.cash_account_id NULLS LAST,p.id LOOP
        INSERT INTO public.payments(organization_id,number,branch_id,direction,method,amount,customer_id,cash_account_id,shift_id,reference,received_by,business_date,reverses_payment_id,reason,idempotency_key,created_by)
        VALUES(o,app.next_document_number(o,s.branch_id,'payment'),s.branch_id,'out',pay.method,pay.amount,pay.customer_id,pay.cash_account_id,pay.shift_id,pay.reference,emp,app.org_today(o),pay.id,btrim(p_reason),'system:void:'||v_return.id||':'||pay.id,emp)
        RETURNING id INTO v_payment;
        INSERT INTO public.payment_allocations(organization_id,payment_id,amount,return_id,created_by) VALUES(o,v_payment,pay.amount,v_return.id,emp);
        IF pay.method='store_credit' THEN
            INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date,created_by)
            VALUES(o,pay.customer_id,pay.amount,'sales_return',v_return.id,s.branch_id,app.org_today(o),emp);
        END IF;
    END LOOP;
    FOR cm IN SELECT * FROM public.cash_movements WHERE organization_id=o AND source_type='sale' AND source_id=s.id AND type='sale' ORDER BY cash_account_id,id LOOP
        INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,shift_id,amount,type,source_type,source_id,reverses_movement_id,note,business_date,created_by)
        VALUES(o,cm.cash_account_id,cm.branch_id,cm.shift_id,-cm.amount,'refund','sales_return',v_return.id,cm.id,btrim(p_reason),app.org_today(o),emp);
    END LOOP;
    UPDATE public.fiscal_submissions SET status='cancelled',updated_at=now() WHERE organization_id=o AND sale_id=s.id AND eta_uuid IS NULL;
    PERFORM app.write_audit('sale.voided','sale',s.id,p_after=>jsonb_build_object('return_id',v_return.id,'number',v_return.number,'total',s.total::text),p_reason=>btrim(p_reason),p_severity=>'warning');
    RETURN jsonb_build_object('return_id',v_return.id,'number',v_return.number);
END $$;
REVOKE ALL ON FUNCTION public.void_sale(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_sale(uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION app.shift_json(p_org uuid, p_id uuid, p_with_movements boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'number', s.number, 'branch_id', s.branch_id, 'device_id', s.device_id,
        'device_name', d.name, 'device_revoked', (d.id IS NULL OR NOT d.is_active OR d.archived_at IS NOT NULL OR d.token_hash IS NULL), 'employee_id', s.employee_id, 'employee_name', e.full_name,
        'drawer_account_id', s.drawer_account_id, 'status', s.status,
        'opening_float', s.opening_float::text, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
        'closed_by_name', ce.full_name,
        'expected_cash', CASE WHEN s.status = 'open' THEN app.shift_expected(p_org, s)
                              ELSE s.expected_cash END::numeric(18,2)::text,
        'counted_cash', s.counted_cash::text,
        'difference', (s.counted_cash - s.expected_cash)::numeric(18,2)::text,
        'count_breakdown', s.count_breakdown, 'difference_reason', s.difference_reason,
        'sales_total', COALESCE((SELECT sum(x.total) FROM public.sales x
                                 WHERE x.organization_id = p_org AND x.shift_id = s.id), 0)::numeric(18,2)::text,
        'payment_totals', (
            SELECT jsonb_build_object(
                'cash', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'cash'), 0)::numeric(18,2)::text,
                'bank_transfer', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'bank_transfer'), 0)::numeric(18,2)::text,
                'store_credit', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'store_credit'), 0)::numeric(18,2)::text)
            FROM public.payments p
            WHERE p.organization_id = p_org AND p.shift_id = s.id AND p.direction = 'in'))
        || CASE WHEN p_with_movements THEN jsonb_build_object('movements', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', m.id, 'created_at', m.created_at, 'type', m.type, 'amount', m.amount::text,
                'source_type', m.source_type,
                'source_number', CASE m.source_type WHEN 'cash_transfer' THEN
                    (SELECT t.number FROM public.cash_transfers t
                     WHERE t.id = m.source_id AND t.organization_id = p_org) END,
                'note', m.note)
                ORDER BY m.created_at, m.id)
            FROM public.cash_movements m
            WHERE m.organization_id = p_org AND m.shift_id = s.id AND m.cash_account_id = s.drawer_account_id),
            '[]'::jsonb))
           ELSE '{}'::jsonb END
    FROM public.shifts s
    JOIN public.employees e ON e.id = s.employee_id AND e.organization_id = s.organization_id
    LEFT JOIN public.employees ce ON ce.id = s.closed_by AND ce.organization_id = s.organization_id
    LEFT JOIN public.devices d ON d.id = s.device_id AND d.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.id = p_id
$$;
REVOKE ALL ON FUNCTION app.shift_json(uuid,uuid,boolean) FROM PUBLIC, anon, authenticated;
