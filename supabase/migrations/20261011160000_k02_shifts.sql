-- =============================================================================
-- K02 · Shifts / cash drawer (EC-60, D60)
--
-- A cashier opens a shift in a branch (optionally on a POS device) with a starting float taken
-- from a safe of that branch. The shift has its own drawer account; every cash movement of the
-- shift carries shift_id on that drawer, so expected cash = the shift's drawer ledger sum (the
-- float is its first row), never the whole safe. During the shift cash can be added from a safe
-- (pay-in) or dropped into one (pay-out). Close: the cash is counted by denomination, expected
-- and counted are compared, a difference needs a reason and is booked as an adjustment on the
-- drawer, and the counted cash goes back to a safe, leaving the drawer at 0.
-- One open shift per cashier (and per device and drawer: baseline unique indexes). A closed
-- shift takes no more cash movements (trigger), so it can't take sales (S01 uses
-- app.require_open_shift). Money moves between a safe and a drawer as K01 cash transfers (CX).
-- =============================================================================

-- 1. A closed shift takes no cash ----------------------------------------------------------------------

-- BEFORE INSERT on cash_movements: a row tagged with a shift must hit that shift's drawer while
-- the shift is open.
CREATE FUNCTION app.check_cash_movement_shift()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_status public.shift_status; v_drawer uuid;
BEGIN
    IF NEW.shift_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.status, s.drawer_account_id INTO v_status, v_drawer
    FROM public.shifts s WHERE s.id = NEW.shift_id AND s.organization_id = NEW.organization_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIFT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.cash_account_id <> v_drawer THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a shift movement must be on the shift''s drawer' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_cash_movements_c_shift BEFORE INSERT ON public.cash_movements
    FOR EACH ROW EXECUTE FUNCTION app.check_cash_movement_shift();

-- 2. Helpers -------------------------------------------------------------------------------------------

-- The cash a shift should hold now: its drawer ledger sum (the float included).
CREATE FUNCTION app.shift_expected(p_org uuid, p_shift public.shifts)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(sum(m.amount), 0)::numeric(18,2) FROM public.cash_movements m
    WHERE m.organization_id = p_org AND m.shift_id = p_shift.id AND m.cash_account_id = p_shift.drawer_account_id
$$;

CREATE FUNCTION app.shift_json(p_org uuid, p_id uuid, p_with_movements boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'number', s.number, 'branch_id', s.branch_id, 'device_id', s.device_id,
        'device_name', d.name, 'employee_id', s.employee_id, 'employee_name', e.full_name,
        'drawer_account_id', s.drawer_account_id, 'status', s.status,
        'opening_float', s.opening_float::text, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
        'closed_by_name', ce.full_name,
        'expected_cash', CASE WHEN s.status = 'open' THEN app.shift_expected(p_org, s)
                              ELSE s.expected_cash END::numeric(18,2)::text,
        'counted_cash', s.counted_cash::text,
        'difference', (s.counted_cash - s.expected_cash)::numeric(18,2)::text,
        'count_breakdown', s.count_breakdown, 'difference_reason', s.difference_reason)
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

-- A float comes from, and counted cash goes back to, an active safe of the shift's branch.
CREATE FUNCTION app.shift_vault(p_org uuid, p_id uuid, p_branch_id uuid)
RETURNS public.cash_accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_a public.cash_accounts;
BEGIN
    SELECT * INTO v_a FROM public.cash_accounts a WHERE a.id = p_id AND a.organization_id = p_org FOR UPDATE;
    IF NOT FOUND OR v_a.kind <> 'safe' OR v_a.branch_id IS DISTINCT FROM p_branch_id THEN
        RAISE EXCEPTION 'VAULT_INVALID' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_a.is_active THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_a;
END;
$$;

-- The cashier's drawer in a branch: the one of their last shift there, else a new drawer account.
CREATE FUNCTION app.shift_drawer(p_org uuid, p_emp uuid, p_branch_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_id uuid; v_name text; v_try text; v_n integer := 1;
BEGIN
    SELECT s.drawer_account_id INTO v_id
    FROM public.shifts s
    JOIN public.cash_accounts a ON a.id = s.drawer_account_id AND a.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.employee_id = p_emp AND s.branch_id = p_branch_id
      AND a.kind = 'drawer' AND a.is_active
    ORDER BY s.opened_at DESC LIMIT 1;
    IF FOUND THEN
        RETURN v_id;
    END IF;
    SELECT 'درج ' || left(e.full_name, 80) INTO v_name
    FROM public.employees e WHERE e.id = p_emp AND e.organization_id = p_org;
    v_try := v_name;
    WHILE EXISTS (SELECT 1 FROM public.cash_accounts a
                  WHERE a.organization_id = p_org AND a.branch_id = p_branch_id AND a.name = v_try) LOOP
        v_n := v_n + 1;
        v_try := v_name || ' ' || v_n;
    END LOOP;
    INSERT INTO public.cash_accounts (organization_id, branch_id, name, kind, created_by, updated_by)
    VALUES (p_org, p_branch_id, v_try, 'drawer', p_emp, p_emp)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- Money between a safe and the shift's drawer, as a K01 cash transfer (CX). p_into_drawer: the
-- safe pays the drawer (float, pay-in); else the drawer pays the safe (pay-out, closing).
CREATE FUNCTION app.shift_transfer(p_org uuid, p_emp uuid, p_shift public.shifts, p_vault public.cash_accounts,
                                   p_amount numeric, p_into_drawer boolean, p_note text, p_key text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_id uuid; v_date date := app.org_today(p_org); v_from uuid; v_to uuid;
BEGIN
    v_from := CASE WHEN p_into_drawer THEN p_vault.id ELSE p_shift.drawer_account_id END;
    v_to := CASE WHEN p_into_drawer THEN p_shift.drawer_account_id ELSE p_vault.id END;
    INSERT INTO public.cash_transfers (organization_id, number, from_account_id, to_account_id, amount, kind,
                                       reason, business_date, idempotency_key, created_by, created_at)
    VALUES (p_org, app.next_document_number(p_org, p_shift.branch_id, 'cash_transfer'), v_from, v_to, p_amount,
            'transfer', p_note, v_date, p_key, p_emp, clock_timestamp())
    RETURNING id INTO v_id;
    -- Money out first, so a safe or drawer that can't cover it refuses before anything comes in.
    IF p_into_drawer THEN
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                           source_id, note, business_date, created_by, created_at)
        VALUES (p_org, p_vault.id, p_shift.branch_id, -p_amount, 'transfer_out', 'cash_transfer', v_id, p_note,
                v_date, p_emp, clock_timestamp());
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                           source_type, source_id, note, business_date, created_by, created_at)
        VALUES (p_org, p_shift.drawer_account_id, p_shift.branch_id, p_shift.id, p_amount, 'float_in',
                'cash_transfer', v_id, p_note, v_date, p_emp, clock_timestamp());
    ELSE
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                           source_type, source_id, note, business_date, created_by, created_at)
        VALUES (p_org, p_shift.drawer_account_id, p_shift.branch_id, p_shift.id, -p_amount, 'float_out',
                'cash_transfer', v_id, p_note, v_date, p_emp, clock_timestamp());
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                           source_id, note, business_date, created_by, created_at)
        VALUES (p_org, p_vault.id, p_shift.branch_id, p_amount, 'transfer_in', 'cash_transfer', v_id, p_note,
                v_date, p_emp, clock_timestamp());
    END IF;
    RETURN v_id;
END;
$$;

-- Loads a shift for a write, locked: the cashier's own, or (with cash.transfer too) any shift of
-- a branch the caller works in. Others: not found.
CREATE FUNCTION app.shift_for_write(p_org uuid, p_emp uuid, p_id uuid)
RETURNS public.shifts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_s public.shifts;
BEGIN
    SELECT * INTO v_s FROM public.shifts s WHERE s.id = p_id AND s.organization_id = p_org FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(v_s.branch_id)
       OR (v_s.employee_id <> p_emp AND NOT app.has_permission('cash.transfer')) THEN
        RAISE EXCEPTION 'SHIFT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_s;
END;
$$;

-- S01 calls this before a sale: the cashier's open shift, or SHIFT_REQUIRED.
CREATE FUNCTION app.require_open_shift(p_org uuid, p_emp uuid)
RETURNS public.shifts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_s public.shifts;
BEGIN
    SELECT * INTO v_s FROM public.shifts s
    WHERE s.organization_id = p_org AND s.employee_id = p_emp AND s.status = 'open';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIFT_REQUIRED: open a shift first' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_s;
END;
$$;

-- 3. Writes --------------------------------------------------------------------------------------------

-- p_opening_float: "0" or more; above 0 it leaves p_vault_id (an active safe of the branch).
CREATE FUNCTION public.open_shift(p_branch_id uuid, p_opening_float text, p_idempotency_key text,
                                  p_vault_id uuid DEFAULT NULL, p_device_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_s public.shifts; v_float numeric(18,2); v_vault public.cash_accounts;
    v_drawer uuid; v_transfer uuid;
BEGIN
    v_emp := app.require_permission('shift.operate');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_s FROM public.shifts s WHERE s.organization_id = v_org AND s.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.shift_json(v_org, v_s.id, true);          -- a repeat changes nothing
    END IF;

    IF p_branch_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    IF p_opening_float IS NULL OR p_opening_float !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: opening_float' USING ERRCODE = 'P0001';
    END IF;
    v_float := p_opening_float::numeric(18,2);
    IF (v_float > 0) <> (p_vault_id IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a float needs the safe it comes from' USING ERRCODE = 'P0001';
    END IF;
    -- The employee row is locked: two opens by one cashier run one after the other.
    PERFORM 1 FROM public.employees e WHERE e.id = v_emp AND e.organization_id = v_org FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.shifts s
               WHERE s.organization_id = v_org AND s.employee_id = v_emp AND s.status = 'open') THEN
        RAISE EXCEPTION 'SHIFT_ALREADY_OPEN: close your open shift first' USING ERRCODE = 'P0001';
    END IF;
    IF p_device_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.devices d
                       WHERE d.id = p_device_id AND d.organization_id = v_org AND d.branch_id = p_branch_id
                         AND d.is_active AND d.archived_at IS NULL) THEN
            RAISE EXCEPTION 'DEVICE_INVALID' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM public.shifts s
                   WHERE s.organization_id = v_org AND s.device_id = p_device_id AND s.status = 'open') THEN
            RAISE EXCEPTION 'SHIFT_ALREADY_OPEN: this device has an open shift' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    IF v_float > 0 THEN
        v_vault := app.shift_vault(v_org, p_vault_id, p_branch_id);
    END IF;
    v_drawer := app.shift_drawer(v_org, v_emp, p_branch_id);

    INSERT INTO public.shifts (organization_id, number, branch_id, device_id, employee_id, drawer_account_id,
                               opening_float, status, idempotency_key, created_by, updated_by)
    VALUES (v_org, app.next_document_number(v_org, p_branch_id, 'shift'), p_branch_id, p_device_id, v_emp,
            v_drawer, v_float, 'open', p_idempotency_key, v_emp, v_emp)
    RETURNING * INTO v_s;
    IF v_float > 0 THEN
        v_transfer := app.shift_transfer(v_org, v_emp, v_s, v_vault, v_float, true, v_s.number,
                                         'system:shift-open:' || v_s.id);
    END IF;

    PERFORM app.write_audit('shift.opened', 'shift', v_s.id, NULL,
        jsonb_build_object('number', v_s.number, 'opening_float', v_float::text, 'vault_id', p_vault_id,
                           'device_id', p_device_id, 'drawer_account_id', v_drawer, 'transfer_id', v_transfer),
        NULL, p_branch_id);
    RETURN app.shift_json(v_org, v_s.id, true);
END;
$$;

-- Cash into the drawer from a safe ('in') or out of it into a safe ('out'), with a note.
CREATE FUNCTION public.move_shift_cash(p_shift_id uuid, p_direction text, p_amount text, p_vault_id uuid,
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

-- p_counts: {"200": 5, "100": 3, ...} (EGP notes and coins). A difference needs a reason and is
-- booked on the drawer; the counted cash goes to p_vault_id. A closed shift is answered unchanged.
CREATE FUNCTION public.close_shift(p_id uuid, p_counts jsonb, p_vault_id uuid DEFAULT NULL,
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
    v_expected := app.shift_expected(v_org, v_s);
    v_diff := v_counted - v_expected;
    v_reason := NULLIF(btrim(p_difference_reason), '');
    IF length(v_reason) > 500 OR (v_diff <> 0 AND (v_reason IS NULL OR length(v_reason) < 3)) THEN
        RAISE EXCEPTION 'SHIFT_DIFFERENCE_REASON_REQUIRED: expected %, counted %', v_expected, v_counted
            USING ERRCODE = 'P0001',
                  DETAIL = jsonb_build_object('expected', v_expected::text, 'counted', v_counted::text,
                                              'difference', v_diff::text)::text;
    END IF;
    IF v_diff = 0 THEN
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

    PERFORM app.write_audit('shift.closed', 'shift', p_id,
        jsonb_build_object('status', 'open'),
        jsonb_build_object('status', 'closed', 'number', v_s.number, 'expected', v_expected::text,
                           'counted', v_counted::text, 'difference', v_diff::text, 'vault_id', p_vault_id,
                           'transfer_id', v_transfer),
        v_reason, v_s.branch_id, CASE WHEN v_diff <> 0 THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.shift_json(v_org, p_id, true);
END;
$$;

-- 4. Reads ---------------------------------------------------------------------------------------------

-- Readers: a cashier (shift.operate) sees their own shifts; cash.view sees every shift of the
-- caller's branches. Also in an expired shop.
CREATE FUNCTION app.require_shift_read()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid := app.current_employee_id();
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('shift.operate') OR app.has_permission('cash.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: shift.operate' USING ERRCODE = '42501';
    END IF;
    RETURN v_emp;
END;
$$;

-- The caller's open shift with its drawer movements, or null.
CREATE FUNCTION public.get_current_shift()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_id uuid;
BEGIN
    v_emp := app.require_shift_read();
    v_org := app.current_org_id();
    SELECT s.id INTO v_id FROM public.shifts s
    WHERE s.organization_id = v_org AND s.employee_id = v_emp AND s.status = 'open';
    RETURN app.shift_json(v_org, v_id, true);
END;
$$;

CREATE FUNCTION public.get_shift(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_s public.shifts;
BEGIN
    v_emp := app.require_shift_read();
    v_org := app.current_org_id();
    SELECT * INTO v_s FROM public.shifts s WHERE s.id = p_id AND s.organization_id = v_org;
    IF NOT FOUND OR NOT (v_s.employee_id = v_emp
                         OR (app.has_permission('cash.view') AND app.has_branch_access(v_s.branch_id))) THEN
        RAISE EXCEPTION 'SHIFT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.shift_json(v_org, p_id, true);
END;
$$;

CREATE FUNCTION public.list_shifts(p_branch_id uuid DEFAULT NULL, p_employee_id uuid DEFAULT NULL,
                                   p_status text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL,
                                   p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_all boolean; v_branches uuid[]; v_tz text; v_result jsonb;
BEGIN
    v_emp := app.require_shift_read();
    v_org := app.current_org_id();
    v_all := app.has_permission('cash.view');
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 OR p_from > p_to
       OR (p_status IS NOT NULL AND p_status NOT IN ('open', 'closed')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
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
    IF p_employee_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.employees e WHERE e.id = p_employee_id AND e.organization_id = v_org) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    -- Shifts are filtered by the shop's day they were opened on.
    SELECT o.timezone INTO v_tz FROM public.organizations o WHERE o.id = v_org;

    WITH found AS (
        SELECT s.id, s.opened_at FROM public.shifts s
        WHERE s.organization_id = v_org AND s.branch_id = ANY(v_branches)
          AND (v_all OR s.employee_id = v_emp)
          AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
          AND (p_status IS NULL OR s.status = p_status::public.shift_status)
          AND (p_from IS NULL OR (s.opened_at AT TIME ZONE v_tz)::date >= p_from)
          AND (p_to IS NULL OR (s.opened_at AT TIME ZONE v_tz)::date <= p_to)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.shift_json(v_org, f.id, false) ORDER BY f.opened_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY opened_at DESC, id DESC LIMIT p_limit OFFSET p_offset) f),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- The active safes of a branch a float can come from or cash can go to. Names only: a cashier
-- doesn't see vault balances.
CREATE FUNCTION public.list_shift_vaults(p_branch_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_shift_read();
    v_org := app.current_org_id();
    IF p_branch_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.has_branch_access(p_branch_id) THEN
        RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object('items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) ORDER BY a.name, a.id)
        FROM public.cash_accounts a
        WHERE a.organization_id = v_org AND a.branch_id = p_branch_id AND a.kind = 'safe' AND a.is_active),
        '[]'::jsonb));
END;
$$;

-- 5. Grants --------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.check_cash_movement_shift(), app.shift_expected(uuid, public.shifts),
    app.shift_json(uuid, uuid, boolean), app.shift_vault(uuid, uuid, uuid), app.shift_drawer(uuid, uuid, uuid),
    app.shift_transfer(uuid, uuid, public.shifts, public.cash_accounts, numeric, boolean, text, text),
    app.shift_for_write(uuid, uuid, uuid), app.require_open_shift(uuid, uuid), app.require_shift_read()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.open_shift(uuid, text, text, uuid, uuid),
    public.move_shift_cash(uuid, text, text, uuid, text, text), public.close_shift(uuid, jsonb, uuid, text),
    public.get_current_shift(), public.get_shift(uuid),
    public.list_shifts(uuid, uuid, text, date, date, integer, integer), public.list_shift_vaults(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.open_shift(uuid, text, text, uuid, uuid),
    public.move_shift_cash(uuid, text, text, uuid, text, text), public.close_shift(uuid, jsonb, uuid, text),
    public.get_current_shift(), public.get_shift(uuid),
    public.list_shifts(uuid, uuid, text, date, date, integer, integer), public.list_shift_vaults(uuid)
    TO authenticated;
