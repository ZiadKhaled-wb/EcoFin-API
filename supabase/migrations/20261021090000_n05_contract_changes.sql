-- =============================================================================
-- N05 · Early settlement, rescheduling, write-off (EC-84, D80)
--
-- Three controlled changes to an open installment contract. Each runs in one transaction and leaves
-- a contract_changes row and an audit row; nothing that exists is edited or deleted: old schedule
-- lines only become superseded, the contract only moves status / current_version / closed_at.
-- Islamic finance (docs/ISLAMIC_FINANCE_RULES.md, binding): a reschedule never increases what is
-- owed (rule 5); an early-settlement waiver is a manager's voluntary decision at settlement time,
-- the policy's rule only a suggestion (rule 6); a write-off forgives debt (rule 8). No fees (rule 4).
-- User-visible words say profit, never interest or discount.
--
-- Rules (docs/tasks/N05.md, D80):
--   1. Settlement and reschedule write schedule version current_version + 1 carrying exactly the
--      old version's remaining principal and profit (minus the waiver at settlement) and supersede
--      the old lines. Paid amounts stay on the superseded lines, so D74's contract total and
--      v_contract_balances need no change.
--   2. app.schedule_lines_sum_check checks every version > 1 against its contract_changes row: the
--      database refuses a version that adds to what is owed.
--   3. Settlement (contract.settle_early): payoff = remaining; waiver 0 .. the remaining profit of
--      the lines not yet due; one line due today, paid by N03's collection core in the caller's
--      open shift; the contract completes. Its collection can't be reversed.
--   4. Reschedule (schedule.change): count, frequency (the policy's), first due date (today + 1 ..
--      + 60) and a reason; N01's spread (app.schedule_split); status rescheduled.
--   5. Write-off: the owner only; status written_off, no new version.
--   6. A collection can't be reversed once its contract changed after it.
--   7. The customer statement shows a waiver and a write-off as credit rows.
--
-- Numbers: contracts 0.50.0, 7 routes. No new enum value and no new permission key.
-- =============================================================================

-- 1. Schema ------------------------------------------------------------------------------------------

ALTER TABLE public.contract_changes
    ADD COLUMN branch_id        uuid,
    ADD COLUMN principal_amount numeric(18,2) CHECK (principal_amount >= 0),
    ADD COLUMN profit_amount    numeric(18,2) CHECK (profit_amount >= 0),
    ADD COLUMN payment_id       uuid,
    ADD COLUMN business_date    date;
ALTER TABLE public.contract_changes
    ADD CONSTRAINT contract_changes_branch_fk FOREIGN KEY (branch_id, organization_id)
        REFERENCES public.branches (id, organization_id),
    ADD CONSTRAINT contract_changes_payment_fk FOREIGN KEY (payment_id, organization_id)
        REFERENCES public.payments (id, organization_id),
    ADD CONSTRAINT contract_changes_split_check
        CHECK (principal_amount IS NULL OR amount = principal_amount + profit_amount),
    ADD CONSTRAINT contract_changes_waiver_check
        CHECK (profit_waived = 0 OR (kind = 'early_settlement' AND profit_waived <= profit_amount));
CREATE INDEX contract_changes_kind_idx ON public.contract_changes (organization_id, kind, business_date);
CREATE UNIQUE INDEX contract_changes_version_idx ON public.contract_changes (contract_id, new_version)
    WHERE new_version IS NOT NULL;

-- 2. Helpers (schema app, no grants) -----------------------------------------------------------------

-- Who sees a contract: N03 / N04's rule, plus the settlement and reschedule keys (decision 10).
CREATE OR REPLACE FUNCTION app.can_see_contract(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT app.has_permission('collection.create') OR app.has_permission('collection.reverse')
        OR app.has_permission('overdue.view') OR app.has_permission('contract.settle_early')
        OR app.has_permission('schedule.change') OR app.has_branch_access(p_branch_id)
$$;

-- What is left on a contract's current schedule: principal, profit and the profit of the lines not
-- yet due (due after today). Effective allocations only.
CREATE FUNCTION app.contract_left(p_org uuid, p_contract_id uuid)
RETURNS TABLE (principal_left numeric, profit_left numeric, future_profit numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(sum(GREATEST(ls.principal - ls.paid_principal, 0)), 0)::numeric(18,2),
           COALESCE(sum(GREATEST(ls.profit - ls.paid_profit, 0)), 0)::numeric(18,2),
           COALESCE(sum(GREATEST(ls.profit - ls.paid_profit, 0))
                    FILTER (WHERE ls.due_date > app.org_today(p_org)), 0)::numeric(18,2)
    FROM public.v_schedule_line_status ls
    JOIN public.contracts c ON c.id = ls.contract_id AND c.organization_id = ls.organization_id
    WHERE ls.organization_id = p_org AND ls.contract_id = p_contract_id
      AND NOT ls.superseded AND ls.version = c.current_version
$$;

-- N01's spread of a total over n lines (app.installment_terms, the same arithmetic): regular lines
-- rounded up to the step, the last takes the rest; the profit in proportion to the amounts, largest
-- remainder in piasters. NULL when the last line would not be positive (the 'rounding' rule).
CREATE FUNCTION app.schedule_split(p_principal numeric, p_profit numeric, p_count integer,
                                   p_frequency public.installment_frequency, p_first date, p_step numeric)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_total numeric := p_principal + p_profit; v_inst numeric; v_last numeric; v_lines jsonb;
        v_markup_p numeric := p_profit * 100; v_total_p numeric;
BEGIN
    v_inst := app.installment_regular(v_total, p_count, p_step);
    v_last := v_total - v_inst * (p_count - 1);
    IF v_last <= 0 THEN
        RETURN NULL;
    END IF;
    v_total_p := v_total * 100;
    WITH l AS (
        SELECT s AS seq, CASE WHEN s = p_count THEN v_last ELSE v_inst END AS amount
        FROM generate_series(1, p_count) s
    ), f AS (
        SELECT seq, amount, div(v_markup_p * amount * 100, v_total_p) AS floor_p,
               mod(v_markup_p * amount * 100, v_total_p) AS rest
        FROM l
    ), r AS (
        SELECT seq, amount, floor_p,
               row_number() OVER (ORDER BY rest DESC, seq) AS rnk,
               v_markup_p - sum(floor_p) OVER () AS leftover
        FROM f
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'seq', seq,
               'due_date', app.installment_due_date(p_first, p_frequency, seq)::text,
               'principal', (amount - p)::numeric(18,2)::text,
               'profit', p::numeric(18,2)::text,
               'amount', amount::numeric(18,2)::text) ORDER BY seq), '[]')
    INTO v_lines
    FROM (SELECT seq, amount, (floor_p + CASE WHEN rnk <= leftover THEN 1 ELSE 0 END) / 100 AS p FROM r) x;
    RETURN v_lines;
END;
$$;

-- The reschedule body, checked (decision 6): {installments_count, frequency, first_due_date} and,
-- for the write, reason + expected_remaining. Returns {lines, violations, ...} for a contract.
CREATE FUNCTION app.reschedule_plan(p_org uuid, c public.contracts, p_body jsonb, p_write boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_key text; v_n integer; v_freq public.installment_frequency; v_first date; v_today date := app.org_today(p_org);
    v_policy public.installment_policies; v_left record; v_lines jsonb; v_violations jsonb := '[]'::jsonb;
BEGIN
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_body) LOOP
        IF v_key NOT IN ('installments_count', 'frequency', 'first_due_date')
           AND NOT (p_write AND v_key IN ('reason', 'expected_remaining')) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        IF jsonb_typeof(p_body -> 'installments_count') IS DISTINCT FROM 'number' THEN
            RAISE EXCEPTION USING ERRCODE = '22023';
        END IF;
        v_n := (p_body ->> 'installments_count')::integer;
        v_freq := (p_body ->> 'frequency')::public.installment_frequency;
        v_first := (p_body ->> 'first_due_date')::date;
    EXCEPTION WHEN data_exception OR invalid_text_representation OR invalid_parameter_value THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END;
    IF v_n IS NULL OR v_n NOT BETWEEN 1 AND 520 OR v_freq IS NULL OR v_first IS NULL
       OR (p_body ->> 'first_due_date') !~ '^\d{4}-\d{2}-\d{2}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    IF p_write AND (jsonb_typeof(p_body -> 'reason') IS DISTINCT FROM 'string'
                    OR length(btrim(p_body ->> 'reason')) NOT BETWEEN 3 AND 300
                    OR jsonb_typeof(p_body -> 'expected_remaining') IS DISTINCT FROM 'string'
                    OR (p_body ->> 'expected_remaining') !~ '^\d{1,16}(\.\d{1,2})?$') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_policy FROM public.installment_policies p WHERE p.id = c.policy_id AND p.organization_id = p_org;
    SELECT * INTO v_left FROM app.contract_left(p_org, c.id);

    IF v_freq <> ALL (v_policy.allowed_frequencies) THEN
        v_violations := v_violations || jsonb_build_object('rule', 'frequency_not_allowed',
            'allowed', to_jsonb(v_policy.allowed_frequencies));
    END IF;
    IF v_first < v_today + 1 OR v_first > v_today + 60 THEN
        v_violations := v_violations || jsonb_build_object('rule', 'first_due_date_out_of_range',
            'earliest', (v_today + 1)::text, 'latest', (v_today + 60)::text);
    END IF;
    v_lines := app.schedule_split(v_left.principal_left, v_left.profit_left, v_n, v_freq, v_first,
                                  v_policy.rounding_step);
    IF v_lines IS NULL THEN
        v_violations := v_violations || jsonb_build_object('rule', 'rounding',
            'rounding_step', v_policy.rounding_step::numeric(18,2)::text);
    END IF;

    RETURN jsonb_build_object(
        'remaining', (v_left.principal_left + v_left.profit_left)::numeric(18,2)::text,
        'principal_left', v_left.principal_left::text, 'profit_left', v_left.profit_left::text,
        'lines', COALESCE(v_lines, '[]'::jsonb), 'violations', v_violations);
END;
$$;

-- Supersede the contract's current lines and write the next version (decision 3). The caller locked
-- the contract and wrote the contract_changes row (the deferred check reads it at commit).
CREATE FUNCTION app.write_schedule_version(p_org uuid, p_contract_id uuid, p_lines jsonb, p_emp uuid,
                                           p_status public.contract_status)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE c public.contracts; v_new integer;
BEGIN
    SELECT * INTO c FROM public.contracts k WHERE k.id = p_contract_id AND k.organization_id = p_org;
    v_new := c.current_version + 1;
    UPDATE public.schedule_lines l SET superseded = true
    WHERE l.organization_id = p_org AND l.contract_id = p_contract_id AND l.version = c.current_version
      AND NOT l.superseded;
    INSERT INTO public.schedule_lines (organization_id, contract_id, version, seq, due_date, principal, profit, created_by)
    SELECT p_org, p_contract_id, v_new, (x ->> 'seq')::integer, (x ->> 'due_date')::date,
           (x ->> 'principal')::numeric, (x ->> 'profit')::numeric, p_emp
    FROM jsonb_array_elements(p_lines) x;
    UPDATE public.contracts k SET current_version = v_new, status = p_status, updated_at = now(), updated_by = p_emp
    WHERE k.id = p_contract_id;
    RETURN v_new;
END;
$$;

-- A contract change as the API shows it.
CREATE FUNCTION app.contract_change_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', x.id, 'kind', x.kind, 'contract_id', x.contract_id,
        'old_version', x.old_version, 'new_version', x.new_version,
        'amount', x.amount::text, 'principal_amount', x.principal_amount::text,
        'profit_amount', x.profit_amount::text, 'profit_waived', x.profit_waived::text,
        'reason', x.reason, 'business_date', x.business_date, 'created_at', x.created_at,
        'created_by', jsonb_build_object('id', x.created_by, 'name', e.full_name),
        'approved_by', x.approved_by, 'payment_id', x.payment_id)
    FROM public.contract_changes x
    LEFT JOIN public.employees e ON e.id = x.created_by AND e.organization_id = x.organization_id
    WHERE x.organization_id = p_org AND x.id = p_id
$$;

-- The idempotency check shared by the three writes (decision 9): the change already made under the
-- key (for this contract and kind) or NULL; a key used by anything else is IDEMPOTENCY_CONFLICT.
CREATE FUNCTION app.contract_change_by_key(p_org uuid, p_key text, p_contract_id uuid,
                                           p_kind public.change_kind)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE x public.contract_changes;
BEGIN
    IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 OR p_key LIKE 'system:%' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: idempotency key' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO x FROM public.contract_changes k WHERE k.organization_id = p_org AND k.idempotency_key = p_key;
    IF FOUND THEN
        IF x.contract_id = p_contract_id AND x.kind = p_kind THEN
            RETURN x.id;
        END IF;
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by another contract change' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.payments p WHERE p.organization_id = p_org AND p.idempotency_key = p_key)
       OR EXISTS (SELECT 1 FROM public.sales s WHERE s.organization_id = p_org AND s.idempotency_key = p_key) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by a payment or a sale' USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END;
$$;

-- The contract to change, locked, open, with what is left matching what the screen saw.
CREATE FUNCTION app.lock_open_contract(p_org uuid, p_contract_id uuid, p_expected text)
RETURNS public.contracts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE c public.contracts; v_remaining numeric;
BEGIN
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = p_org AND k.id = p_contract_id FOR UPDATE;
    IF NOT FOUND OR NOT app.can_see_contract(c.branch_id) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_remaining := app.contract_remaining(p_org, c.id);
    IF c.status NOT IN ('active', 'rescheduled') OR v_remaining <= 0 THEN
        RAISE EXCEPTION 'CONTRACT_NOT_OPEN: %', c.number USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('contract_id', c.id, 'status', c.status)::text;
    END IF;
    IF p_expected IS NULL OR p_expected !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: expected_remaining' USING ERRCODE = 'P0001';
    END IF;
    IF p_expected::numeric <> v_remaining THEN
        RAISE EXCEPTION 'COLLECTION_DUE_CHANGED: % has % left', c.number, v_remaining USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('contract_id', c.id, 'remaining', v_remaining::text)::text;
    END IF;
    RETURN c;
END;
$$;

-- The settlement quote (decision 5).
CREATE FUNCTION app.settlement_quote(p_org uuid, c public.contracts)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_policy public.installment_policies; v_left record; v_suggested numeric; v_max numeric;
BEGIN
    SELECT * INTO v_policy FROM public.installment_policies p WHERE p.id = c.policy_id AND p.organization_id = p_org;
    SELECT * INTO v_left FROM app.contract_left(p_org, c.id);
    -- Something is always paid: the waiver leaves at least one piaster.
    v_max := GREATEST(LEAST(v_left.future_profit, v_left.principal_left + v_left.profit_left - 0.01), 0);
    v_suggested := CASE v_policy.early_settlement_rule
        WHEN 'waive_future_profit' THEN v_left.future_profit
        WHEN 'percent_of_future_profit' THEN trunc(v_left.future_profit * v_policy.early_settlement_pct / 100, 2)
        ELSE 0 END;
    RETURN jsonb_build_object(
        'contract_id', c.id, 'number', c.number, 'status', c.status,
        'remaining', (v_left.principal_left + v_left.profit_left)::numeric(18,2)::text,
        'principal_left', v_left.principal_left::text, 'profit_left', v_left.profit_left::text,
        'future_profit', v_left.future_profit::text,
        'suggested_waiver', LEAST(v_suggested, v_max)::numeric(18,2)::text,
        'max_waiver', v_max::numeric(18,2)::text,
        'policy_rule', jsonb_build_object('early_settlement_rule', v_policy.early_settlement_rule,
                                          'early_settlement_pct', v_policy.early_settlement_pct::text));
END;
$$;

-- 3. The version check (decision 4; replaces N01's TODO) ----------------------------------------------

-- Version 1: N01's check, unchanged. A later version: its lines run 1..n, it is the contract's
-- current version, and its sums equal what its contract_changes row carried over (principal, and
-- profit minus the waiver). A version without its row is refused: nothing adds to what is owed.
CREATE OR REPLACE FUNCTION app.schedule_lines_sum_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_c public.contracts; v_n integer; v_max integer; v_amount numeric; v_principal numeric; v_profit numeric;
        v_x public.contract_changes;
BEGIN
    IF NEW.seq <> (SELECT max(l.seq) FROM public.schedule_lines l
                   WHERE l.contract_id = NEW.contract_id AND l.version = NEW.version) THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_c FROM public.contracts WHERE id = NEW.contract_id AND organization_id = NEW.organization_id;
    SELECT count(*), max(seq), sum(amount), sum(principal), sum(profit)
    INTO v_n, v_max, v_amount, v_principal, v_profit
    FROM public.schedule_lines
    WHERE contract_id = NEW.contract_id AND organization_id = NEW.organization_id AND version = NEW.version;
    IF NEW.version = 1 THEN
        IF v_max <> v_n OR v_amount <> v_c.total_payable OR v_principal <> v_c.financed_amount
           OR v_profit <> v_c.markup_amount THEN
            RAISE EXCEPTION 'SCHEDULE_NOT_BALANCED: %', v_c.number USING ERRCODE = 'P0001';
        END IF;
        RETURN NULL;
    END IF;
    SELECT * INTO v_x FROM public.contract_changes x
    WHERE x.organization_id = NEW.organization_id AND x.contract_id = NEW.contract_id AND x.new_version = NEW.version;
    IF NOT FOUND OR v_max <> v_n OR v_c.current_version <> NEW.version
       OR v_principal <> v_x.principal_amount OR v_profit <> v_x.profit_amount - v_x.profit_waived THEN
        RAISE EXCEPTION 'SCHEDULE_NOT_BALANCED: %', v_c.number USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION app.contract_left(uuid, uuid),
    app.schedule_split(numeric, numeric, integer, public.installment_frequency, date, numeric),
    app.reschedule_plan(uuid, public.contracts, jsonb, boolean),
    app.write_schedule_version(uuid, uuid, jsonb, uuid, public.contract_status),
    app.contract_change_json(uuid, uuid), app.contract_change_by_key(uuid, text, uuid, public.change_kind),
    app.lock_open_contract(uuid, uuid, text), app.settlement_quote(uuid, public.contracts),
    app.schedule_lines_sum_check()
    FROM PUBLIC, anon, authenticated;

-- 4. Early settlement (decision 5) ---------------------------------------------------------------------

-- Read only; an expired shop may look.
CREATE FUNCTION public.get_settlement_quote(p_contract_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; c public.contracts;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('contract.settle_early') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: contract.settle_early' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = v_org AND k.id = p_contract_id;
    IF NOT FOUND OR NOT app.can_see_contract(c.branch_id) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF c.status NOT IN ('active', 'rescheduled') OR app.contract_remaining(v_org, c.id) <= 0 THEN
        RAISE EXCEPTION 'CONTRACT_NOT_OPEN: %', c.number USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('contract_id', c.id, 'status', c.status)::text;
    END IF;
    RETURN app.settlement_quote(v_org, c);
END;
$$;

-- Body (strict): waiver, reason (required when waiver > 0), expected_remaining, payments (N03's
-- lines). The same key again returns the first answer.
CREATE FUNCTION public.settle_contract_early(p_contract_id uuid, p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_key text; v_done uuid; c public.contracts; v_shift public.shifts; v_quote jsonb;
    v_waiver numeric; v_reason text; v_left record; v_pay numeric; v_change uuid := gen_random_uuid();
    v_in jsonb; v_receipt uuid; v_new integer;
BEGIN
    v_emp := app.require_permission('contract.settle_early');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    v_done := app.contract_change_by_key(v_org, p_idempotency_key, p_contract_id, 'early_settlement');
    IF v_done IS NOT NULL THEN
        RETURN jsonb_build_object('change', app.contract_change_json(v_org, v_done),
            'collection', app.collection_json(v_org, (SELECT x.payment_id FROM public.contract_changes x WHERE x.id = v_done)));
    END IF;

    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_body) LOOP
        IF v_key NOT IN ('waiver', 'reason', 'expected_remaining', 'payments') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF jsonb_typeof(p_body -> 'waiver') IS DISTINCT FROM 'string'
       OR (p_body ->> 'waiver') !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: waiver' USING ERRCODE = 'P0001';
    END IF;
    v_waiver := (p_body ->> 'waiver')::numeric;
    v_reason := NULLIF(btrim(p_body ->> 'reason'), '');
    IF (p_body ? 'reason' AND jsonb_typeof(p_body -> 'reason') <> 'string')
       OR (v_reason IS NOT NULL AND length(v_reason) NOT BETWEEN 3 AND 300)
       OR (v_waiver > 0 AND v_reason IS NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;

    -- The caller's open shift, locked, on its device (N03's order).
    v_shift := app.require_open_shift(v_org, v_emp);
    SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_shift.id FOR UPDATE;
    IF v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_shift.branch_id);
    PERFORM app.require_shift_device(v_shift.id);

    c := app.lock_open_contract(v_org, p_contract_id, p_body ->> 'expected_remaining');
    v_quote := app.settlement_quote(v_org, c);
    IF v_waiver > (v_quote ->> 'max_waiver')::numeric THEN
        RAISE EXCEPTION 'WAIVER_TOO_HIGH: at most %', v_quote ->> 'max_waiver' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('max_waiver', v_quote ->> 'max_waiver')::text;
    END IF;
    SELECT * INTO v_left FROM app.contract_left(v_org, c.id);
    v_pay := v_left.principal_left + v_left.profit_left - v_waiver;
    -- N03's body shape, checked by N03 (payment lines add up to the amount, bank accounts, ...).
    v_in := app.collection_input(jsonb_build_object(
        'customer_id', c.customer_id,
        'contracts', jsonb_build_array(jsonb_build_object('contract_id', c.id, 'amount', v_pay::numeric(18,2)::text)),
        'payments', p_body -> 'payments'));

    v_new := app.write_schedule_version(v_org, c.id, jsonb_build_array(jsonb_build_object(
                 'seq', 1, 'due_date', app.org_today(v_org)::text, 'principal', v_left.principal_left::text,
                 'profit', (v_left.profit_left - v_waiver)::numeric(18,2)::text)),
             v_emp, c.status);
    -- The collection pays the one line and completes the contract (N03's core and audit rows).
    v_receipt := app.post_collection_core(v_org, v_emp, v_shift.branch_id, v_shift, v_shift.drawer_account_id,
                                          v_in, p_idempotency_key);
    -- The change row (append-only) once the receipt exists; the version check runs at commit.
    INSERT INTO public.contract_changes (id, organization_id, contract_id, kind, old_version, new_version, amount,
                                         principal_amount, profit_amount, profit_waived, reason, approved_by,
                                         idempotency_key, branch_id, business_date, payment_id, created_at, created_by)
    VALUES (v_change, v_org, c.id, 'early_settlement', c.current_version, v_new,
            v_left.principal_left + v_left.profit_left, v_left.principal_left, v_left.profit_left, v_waiver,
            COALESCE(v_reason, 'Early settlement'), CASE WHEN v_waiver > 0 THEN v_emp END, p_idempotency_key,
            c.branch_id, app.org_today(v_org), v_receipt, clock_timestamp(), v_emp);

    PERFORM app.write_audit('contract.settled_early', 'contract', c.id, NULL,
        jsonb_build_object('number', c.number, 'change_id', v_change, 'collection_id', v_receipt,
                           'payoff', (v_left.principal_left + v_left.profit_left)::numeric(18,2)::text,
                           'profit_waived', v_waiver::numeric(18,2)::text,
                           'suggested_waiver', v_quote ->> 'suggested_waiver', 'paid', v_pay::numeric(18,2)::text,
                           'old_version', c.current_version, 'new_version', v_new),
        v_reason, c.branch_id, CASE WHEN v_waiver > 0 THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN jsonb_build_object('change', app.contract_change_json(v_org, v_change),
                              'collection', app.collection_json(v_org, v_receipt));
END;
$$;

-- 5. Rescheduling (decision 6) -------------------------------------------------------------------------

CREATE FUNCTION public.preview_reschedule(p_contract_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; c public.contracts;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('schedule.change') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: schedule.change' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = v_org AND k.id = p_contract_id;
    IF NOT FOUND OR NOT app.can_see_contract(c.branch_id) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF c.status NOT IN ('active', 'rescheduled') OR app.contract_remaining(v_org, c.id) <= 0 THEN
        RAISE EXCEPTION 'CONTRACT_NOT_OPEN: %', c.number USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('contract_id', c.id, 'status', c.status)::text;
    END IF;
    RETURN app.reschedule_plan(v_org, c, p_body, false);
END;
$$;

CREATE FUNCTION public.reschedule_contract(p_contract_id uuid, p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_done uuid; c public.contracts; v_plan jsonb; v_change uuid := gen_random_uuid();
        v_new integer; v_reason text;
BEGIN
    v_emp := app.require_permission('schedule.change');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    v_done := app.contract_change_by_key(v_org, p_idempotency_key, p_contract_id, 'reschedule');
    IF v_done IS NOT NULL THEN
        RETURN jsonb_build_object('change', app.contract_change_json(v_org, v_done),
                                  'contract', app.contract_json(v_org, p_contract_id));
    END IF;
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    c := app.lock_open_contract(v_org, p_contract_id, p_body ->> 'expected_remaining');
    v_plan := app.reschedule_plan(v_org, c, p_body, true);
    IF jsonb_array_length(v_plan -> 'violations') > 0 THEN
        RAISE EXCEPTION 'INSTALLMENT_TERMS_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('violations', v_plan -> 'violations')::text;
    END IF;
    v_reason := btrim(p_body ->> 'reason');

    INSERT INTO public.contract_changes (id, organization_id, contract_id, kind, old_version, new_version, amount,
                                         principal_amount, profit_amount, reason, idempotency_key, branch_id,
                                         business_date, created_at, created_by)
    VALUES (v_change, v_org, c.id, 'reschedule', c.current_version, c.current_version + 1,
            (v_plan ->> 'remaining')::numeric, (v_plan ->> 'principal_left')::numeric,
            (v_plan ->> 'profit_left')::numeric, v_reason, p_idempotency_key, c.branch_id, app.org_today(v_org),
            clock_timestamp(), v_emp);
    v_new := app.write_schedule_version(v_org, c.id, v_plan -> 'lines', v_emp, 'rescheduled');

    PERFORM app.write_audit('contract.rescheduled', 'contract', c.id, NULL,
        jsonb_build_object('number', c.number, 'change_id', v_change, 'remaining', v_plan ->> 'remaining',
                           'old_version', c.current_version, 'new_version', v_new,
                           'old_lines', (SELECT count(*) FROM public.schedule_lines l
                                         WHERE l.contract_id = c.id AND l.version = c.current_version),
                           'new_lines', jsonb_array_length(v_plan -> 'lines'),
                           'frequency', p_body ->> 'frequency',
                           'first_due_date', v_plan -> 'lines' -> 0 ->> 'due_date',
                           'last_due_date', v_plan -> 'lines' -> (jsonb_array_length(v_plan -> 'lines') - 1) ->> 'due_date'),
        v_reason, c.branch_id, 'warning');
    RETURN jsonb_build_object('change', app.contract_change_json(v_org, v_change),
                              'contract', app.contract_json(v_org, c.id));
END;
$$;

-- 6. Write-off (decision 7: the owner only) -----------------------------------------------------------

CREATE FUNCTION public.write_off_contract(p_contract_id uuid, p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_done uuid; c public.contracts; v_left record; v_change uuid := gen_random_uuid();
        v_reason text;
BEGIN
    v_emp := app.require_permission('contract.write_off');
    IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: owner' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    v_done := app.contract_change_by_key(v_org, p_idempotency_key, p_contract_id, 'write_off');
    IF v_done IS NOT NULL THEN
        RETURN jsonb_build_object('change', app.contract_change_json(v_org, v_done),
                                  'contract', app.contract_json(v_org, p_contract_id));
    END IF;
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_body) k WHERE k NOT IN ('reason', 'expected_remaining'))
       OR jsonb_typeof(p_body -> 'reason') IS DISTINCT FROM 'string'
       OR length(btrim(p_body ->> 'reason')) NOT BETWEEN 3 AND 300
       OR jsonb_typeof(p_body -> 'expected_remaining') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    v_reason := btrim(p_body ->> 'reason');
    c := app.lock_open_contract(v_org, p_contract_id, p_body ->> 'expected_remaining');
    SELECT * INTO v_left FROM app.contract_left(v_org, c.id);

    INSERT INTO public.contract_changes (id, organization_id, contract_id, kind, old_version, amount,
                                         principal_amount, profit_amount, reason, approved_by, idempotency_key,
                                         branch_id, business_date, created_at, created_by)
    VALUES (v_change, v_org, c.id, 'write_off', c.current_version, v_left.principal_left + v_left.profit_left,
            v_left.principal_left, v_left.profit_left, v_reason, v_emp, p_idempotency_key, c.branch_id,
            app.org_today(v_org), clock_timestamp(), v_emp);
    UPDATE public.contracts k SET status = 'written_off', closed_at = now(), updated_at = now(), updated_by = v_emp
    WHERE k.id = c.id;

    PERFORM app.write_audit('contract.written_off', 'contract', c.id, NULL,
        jsonb_build_object('number', c.number, 'change_id', v_change,
                           'amount', (v_left.principal_left + v_left.profit_left)::numeric(18,2)::text,
                           'principal', v_left.principal_left::text, 'profit', v_left.profit_left::text),
        v_reason, c.branch_id, 'critical');
    RETURN jsonb_build_object('change', app.contract_change_json(v_org, v_change),
                              'contract', app.contract_json(v_org, c.id));
END;
$$;

-- 7. Reads: a contract's changes and versions, the shop's changes (decision 11) -------------------------

CREATE FUNCTION public.list_contract_changes_for(p_contract_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; c public.contracts;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('contract.settle_early') OR app.has_permission('schedule.change')
            OR app.has_permission('contract.write_off') OR app.has_permission('collection.create')
            OR app.has_permission('report.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: schedule.change' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = v_org AND k.id = p_contract_id;
    IF NOT FOUND OR NOT app.can_see_contract(c.branch_id) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object(
        'changes', COALESCE((SELECT jsonb_agg(app.contract_change_json(v_org, x.id) ORDER BY x.created_at DESC, x.id)
                             FROM public.contract_changes x
                             WHERE x.organization_id = v_org AND x.contract_id = c.id), '[]'::jsonb),
        'versions', (
            SELECT jsonb_agg(jsonb_build_object(
                       'version', v.version, 'superseded', v.version <> c.current_version,
                       'change_id', (SELECT x.id FROM public.contract_changes x
                                     WHERE x.organization_id = v_org AND x.contract_id = c.id
                                       AND x.new_version = v.version),
                       'lines', (SELECT jsonb_agg(jsonb_build_object(
                                     'seq', ls.seq, 'due_date', ls.due_date, 'principal', ls.principal::text,
                                     'profit', ls.profit::text, 'amount', ls.amount::text, 'paid', ls.paid::text,
                                     'remaining', GREATEST(ls.remaining, 0)::numeric(18,2)::text,
                                     'status', ls.status) ORDER BY ls.seq)
                                 FROM public.v_schedule_line_status ls
                                 WHERE ls.organization_id = v_org AND ls.contract_id = c.id
                                   AND ls.version = v.version))
                   ORDER BY v.version DESC)
            FROM (SELECT DISTINCT l.version FROM public.schedule_lines l
                  WHERE l.organization_id = v_org AND l.contract_id = c.id) v));
END;
$$;

-- Filters (strict): kind, branch_id, from, to (business dates), limit (1-100, 25), cursor. Newest
-- first; totals by kind for the same filters (cursor excluded).
CREATE FUNCTION public.list_contract_changes(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_kind public.change_kind;
    v_branch uuid; v_from date; v_to date; v_limit integer := 25; v_cur_at timestamptz; v_cur_id uuid;
    v_items jsonb; v_next text; v_totals jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('report.financial') OR app.has_permission('contract.settle_early')
            OR app.has_permission('schedule.change') OR app.has_permission('contract.write_off')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: report.financial' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('kind', 'branch_id', 'from', 'to', 'limit', 'cursor') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_kind := (f ->> 'kind')::public.change_kind;
        v_branch := (f ->> 'branch_id')::uuid;
        v_from := (f ->> 'from')::date;
        v_to := (f ->> 'to')::date;
        v_limit := COALESCE((f ->> 'limit')::integer, 25);
        IF f ->> 'cursor' IS NOT NULL THEN
            v_cur_at := split_part(f ->> 'cursor', '|', 1)::timestamptz;
            v_cur_id := split_part(f ->> 'cursor', '|', 2)::uuid;
        END IF;
    EXCEPTION WHEN data_exception OR invalid_text_representation THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_limit NOT BETWEEN 1 AND 100 OR v_from > v_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;

    WITH base AS (
        SELECT x.id, x.created_at, x.kind, x.amount, x.profit_waived
        FROM public.contract_changes x
        JOIN public.contracts c ON c.id = x.contract_id AND c.organization_id = x.organization_id
        WHERE x.organization_id = v_org
          AND (v_kind IS NULL OR x.kind = v_kind)
          AND (v_branch IS NULL OR c.branch_id = v_branch)
          AND (v_from IS NULL OR x.business_date >= v_from) AND (v_to IS NULL OR x.business_date <= v_to)
          AND app.can_see_contract(c.branch_id)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', t.kind, 'count', t.n, 'amount', t.amount::text,
                                                 'profit_waived', t.waived::text) ORDER BY t.kind), '[]'::jsonb)
    INTO v_totals
    FROM (SELECT b.kind, count(*) n, sum(b.amount)::numeric(18,2) amount, sum(b.profit_waived)::numeric(18,2) waived
          FROM base b GROUP BY b.kind) t;

    WITH base AS (
        SELECT x.id, x.created_at
        FROM public.contract_changes x
        JOIN public.contracts c ON c.id = x.contract_id AND c.organization_id = x.organization_id
        WHERE x.organization_id = v_org
          AND (v_kind IS NULL OR x.kind = v_kind)
          AND (v_branch IS NULL OR c.branch_id = v_branch)
          AND (v_from IS NULL OR x.business_date >= v_from) AND (v_to IS NULL OR x.business_date <= v_to)
          AND app.can_see_contract(c.branch_id)
          AND (v_cur_id IS NULL OR x.created_at < v_cur_at OR (x.created_at = v_cur_at AND x.id < v_cur_id))
    ), page AS (
        SELECT b.id, b.created_at, row_number() OVER (ORDER BY b.created_at DESC, b.id DESC) AS n FROM base b
    )
    SELECT COALESCE(jsonb_agg(app.contract_change_json(v_org, p.id) || jsonb_build_object(
               'contract', jsonb_build_object('id', c.id, 'number', c.number, 'branch_id', c.branch_id),
               'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name)) ORDER BY p.n)
               FILTER (WHERE p.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN p.n = v_limit
                              THEN to_char(p.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' || p.id::text END) END
    INTO v_items, v_next
    FROM (SELECT * FROM page WHERE n <= v_limit + 1) p
    JOIN public.contract_changes x ON x.id = p.id
    JOIN public.contracts c ON c.id = x.contract_id AND c.organization_id = x.organization_id
    JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id;
    RETURN jsonb_build_object('items', v_items, 'next_cursor', v_next, 'totals', v_totals);
END;
$$;

-- 8. Collections: the reversal guard (decision 8; N03's function, two checks added) --------------------

CREATE OR REPLACE FUNCTION public.reverse_collection(p_id uuid, p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_receipt public.payments; v_existing public.payments; v_shift public.shifts;
    v_reason text; v_date date; v_first uuid := gen_random_uuid(); v_rid uuid; v_n integer := 0;
    pay public.payments; cm public.cash_movements; c public.contracts; v_later uuid; v_status public.contract_status;
    v_contracts jsonb := '[]'::jsonb; v_reopened uuid[] := '{}'; i integer;
BEGIN
    v_emp := app.require_permission('collection.reverse');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    IF p_idempotency_key LIKE 'system:%' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: idempotency key' USING ERRCODE = 'P0001';
    END IF;
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_body) k WHERE k <> 'reason')
       OR jsonb_typeof(p_body -> 'reason') IS DISTINCT FROM 'string'
       OR length(btrim(p_body ->> 'reason')) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    v_reason := btrim(p_body ->> 'reason');

    v_receipt := app.collection_receipt(v_org, p_id);
    IF v_receipt.id IS NULL THEN
        RAISE EXCEPTION 'COLLECTION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.payments p WHERE p.id = v_receipt.id FOR UPDATE;
    PERFORM app.require_branch_access(v_receipt.branch_id);

    SELECT * INTO v_existing FROM public.payments p
    WHERE p.organization_id = v_org AND p.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_existing.reverses_payment_id = v_receipt.id THEN
            RETURN app.collection_json(v_org, v_receipt.id);    -- a repeat reverses nothing
        END IF;
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by another payment' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM public.payments r WHERE r.organization_id = v_org AND r.reverses_payment_id = v_receipt.id) THEN
        RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: already reversed' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason', 'already_reversed')::text;
    END IF;
    v_date := app.org_today(v_org);
    IF v_receipt.business_date <> v_date THEN
        RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: not the same day' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason', 'not_same_day')::text;
    END IF;
    -- The money goes back out of the drawer that took it: that shift must still be open.
    SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_receipt.shift_id AND s.organization_id = v_org FOR UPDATE;
    IF v_shift.id IS NULL OR v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: the shift is closed' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason', 'shift_closed')::text;
    END IF;
    PERFORM app.require_shift_device(v_shift.id);

    -- Every contract it paid, locked; it must be the latest effective collection on each.
    FOR c IN SELECT k.* FROM public.contracts k
             WHERE k.organization_id = v_org
               AND k.id IN (SELECT pa.contract_id FROM public.payment_allocations pa
                            JOIN public.payments p ON p.id = pa.payment_id
                            WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id)
             ORDER BY k.id FOR UPDATE LOOP
        SELECT p.collection_id INTO v_later FROM public.v_effective_allocations ea
        JOIN public.payments p ON p.id = ea.payment_id
        WHERE ea.organization_id = v_org AND ea.contract_id = c.id AND p.collection_id <> v_receipt.id
          AND p.paid_at > v_receipt.paid_at
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: a later collection on %', c.number USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('reason', 'not_latest', 'contract_id', c.id)::text;
        END IF;
        -- N05 (decision 8): a settlement's collection carries its waiver; a contract changed since
        -- the collection no longer carries the lines it paid.
        IF EXISTS (SELECT 1 FROM public.contract_changes x
                   WHERE x.organization_id = v_org AND x.contract_id = c.id AND x.payment_id = v_receipt.id) THEN
            RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: an early settlement' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('reason', 'settlement', 'contract_id', c.id)::text;
        END IF;
        IF EXISTS (SELECT 1 FROM public.contract_changes x
                   WHERE x.organization_id = v_org AND x.contract_id = c.id AND x.created_at > v_receipt.paid_at) THEN
            RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: % changed since', c.number USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('reason', 'contract_changed', 'contract_id', c.id)::text;
        END IF;
    END LOOP;

    -- One reversing row per payment row (the first carries the key), the money back out.
    FOR pay IN SELECT p.* FROM public.payments p
               WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id
               ORDER BY (p.id = v_receipt.id) DESC, p.number, p.id LOOP
        v_n := v_n + 1;
        v_rid := CASE WHEN v_n = 1 THEN v_first ELSE gen_random_uuid() END;
        INSERT INTO public.payments (id, organization_id, number, branch_id, direction, method, amount, customer_id,
                                     cash_account_id, shift_id, reference, received_by, paid_at, business_date,
                                     reverses_payment_id, reason, idempotency_key, collection_id, created_by)
        VALUES (v_rid, v_org, app.next_document_number(v_org, pay.branch_id, 'payment'), pay.branch_id, 'out',
                pay.method, pay.amount, pay.customer_id, pay.cash_account_id, pay.shift_id, pay.reference, v_emp,
                clock_timestamp(), v_date, pay.id, v_reason,
                CASE WHEN v_n = 1 THEN p_idempotency_key ELSE 'system:collection-reversal:' || v_first::text || ':' || v_n END,
                v_first, v_emp);
        FOR cm IN SELECT m.* FROM public.cash_movements m
                  WHERE m.organization_id = v_org AND m.source_type = 'payment' AND m.source_id = pay.id
                    AND m.type = 'collection' ORDER BY m.id LOOP
            INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                               source_type, source_id, reverses_movement_id, note, business_date,
                                               created_by, created_at)
            VALUES (v_org, cm.cash_account_id, cm.branch_id, cm.shift_id, -cm.amount, 'collection', 'payment', v_rid,
                    cm.id, left(v_reason, 200), v_date, v_emp, clock_timestamp());
        END LOOP;
    END LOOP;

    -- A contract this collection completed is open again.
    FOR c IN SELECT k.* FROM public.contracts k
             WHERE k.organization_id = v_org
               AND k.id IN (SELECT pa.contract_id FROM public.payment_allocations pa
                            JOIN public.payments p ON p.id = pa.payment_id
                            WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id)
             ORDER BY k.id LOOP
        v_status := c.status;
        IF c.status = 'completed' THEN
            v_status := CASE WHEN c.current_version > 1 THEN 'rescheduled' ELSE 'active' END;
            UPDATE public.contracts k SET status = v_status, closed_at = NULL, updated_at = now(), updated_by = v_emp
            WHERE k.id = c.id;
            v_reopened := v_reopened || c.id;
        END IF;
        v_contracts := v_contracts || jsonb_build_object('id', c.id, 'number', c.number, 'status_before', c.status,
            'status_after', v_status, 'remaining_after', app.contract_remaining(v_org, c.id)::text);
    END LOOP;

    PERFORM app.write_audit('collection.reversed', 'payment', v_receipt.id, NULL,
        jsonb_build_object('number', v_receipt.number,
                           'reversal_number', (SELECT p.number FROM public.payments p WHERE p.id = v_first),
                           'amount', (SELECT sum(p.amount) FROM public.payments p
                                      WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id)::numeric(18,2)::text,
                           'contracts', v_contracts),
        v_reason, v_receipt.branch_id, 'warning');
    FOR i IN 1..cardinality(v_reopened) LOOP
        PERFORM app.write_audit('contract.reopened', 'contract', v_reopened[i], NULL,
            jsonb_build_object('number', (SELECT k.number FROM public.contracts k WHERE k.id = v_reopened[i]),
                               'collection_id', v_receipt.id),
            v_reason, v_receipt.branch_id, 'warning');
    END LOOP;
    RETURN app.collection_json(v_org, v_receipt.id);
END;
$$;

-- 9. The customer statement (R02 rule 4; its TODO(N05)): waiver and write-off credit rows ----------------

CREATE OR REPLACE FUNCTION app.customer_statement_rows(p_org uuid, p_customer_id uuid)
RETURNS TABLE (d date, created_at timestamptz, ord integer, kind text, id uuid, number text,
               detail text, reference text, debit numeric, credit numeric)
LANGUAGE sql STABLE SET search_path = ''
AS $$
    WITH o AS (SELECT og.timezone FROM public.organizations og WHERE og.id = p_org)
    -- every sale of the customer; a void is its own return row
    SELECT s.business_date, s.created_at, 1, 'sale', s.id, s.number, NULL::text, NULL::text, s.total, 0::numeric
    FROM public.sales s
    WHERE s.organization_id = p_org AND s.customer_id = p_customer_id
    UNION ALL
    -- a contract adds to its sale what it costs above the financed amount (the markup, plus what a
    -- reschedule added); one without a sale (M02) adds its whole contract total.
    -- TODO(S10): a contract from an order is issued with the delivery's sale; revisit with S10.
    -- N05: a waiver at early settlement is added back here and shown as its own credit row below.
    SELECT COALESCE(s.business_date, (c.created_at AT TIME ZONE (SELECT o.timezone FROM o))::date),
           c.created_at, 2, 'contract', c.id, c.number, s.number, NULL,
           app.customer_contract_total(p_org, c.id)
               + COALESCE((SELECT sum(x.profit_waived) FROM public.contract_changes x
                           WHERE x.organization_id = c.organization_id AND x.contract_id = c.id), 0)
               - CASE WHEN c.sale_id IS NULL THEN 0 ELSE c.financed_amount END, 0
    FROM public.contracts c
    LEFT JOIN public.sales s ON s.id = c.sale_id AND s.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.customer_id = p_customer_id
    UNION ALL
    -- payments and refunds in cash or by bank transfer; a reversal undoes its original
    -- TODO(S10): an order deposit is a payment in (a credit) until the delivery issues the sale.
    SELECT p.business_date, p.created_at, 3,
           CASE WHEN p.reverses_payment_id IS NOT NULL THEN 'payment_reversal'
                WHEN p.direction = 'in' THEN 'payment_in' ELSE 'payment_out' END,
           p.id, p.number, p.method::text, p.reference,
           CASE WHEN COALESCE(orig.direction, p.direction) = 'in' AND p.reverses_payment_id IS NULL THEN 0
                WHEN COALESCE(orig.direction, p.direction) = 'out' AND p.reverses_payment_id IS NOT NULL THEN 0
                ELSE p.amount END,
           CASE WHEN COALESCE(orig.direction, p.direction) = 'in' AND p.reverses_payment_id IS NULL THEN p.amount
                WHEN COALESCE(orig.direction, p.direction) = 'out' AND p.reverses_payment_id IS NOT NULL THEN p.amount
                ELSE 0 END
    FROM public.payments p
    LEFT JOIN public.payments orig ON orig.id = p.reverses_payment_id AND orig.organization_id = p.organization_id
    WHERE p.organization_id = p_org AND p.customer_id = p_customer_id AND p.method <> 'store_credit'
    UNION ALL
    -- returns, voids and exchanges of the customer's sales
    SELECT r.business_date, r.created_at, 4, 'return', r.id, r.number, r.kind::text, NULL, 0, r.total
    FROM public.sales_returns r
    JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
    WHERE r.organization_id = p_org AND s.customer_id = p_customer_id
    UNION ALL
    -- late fees (N04) and their waivers; the number is the contract's
    SELECT ch.assessed_on, ch.created_at, 5, 'fee', ch.id, c.number, ch.kind::text, NULL, ch.amount, 0
    FROM public.charges ch
    JOIN public.contracts c ON c.id = ch.contract_id AND c.organization_id = ch.organization_id
    WHERE ch.organization_id = p_org AND c.customer_id = p_customer_id
    UNION ALL
    SELECT (w.created_at AT TIME ZONE (SELECT o.timezone FROM o))::date, w.created_at, 6, 'fee_waiver', w.id,
           c.number, w.reason, NULL, 0, w.amount
    FROM public.charge_waivers w
    JOIN public.charges ch ON ch.id = w.charge_id AND ch.organization_id = w.organization_id
    JOIN public.contracts c ON c.id = ch.contract_id AND c.organization_id = ch.organization_id
    WHERE w.organization_id = p_org AND c.customer_id = p_customer_id
    UNION ALL
    -- N05: profit waived at an early settlement and a written-off balance (credits); the number is
    -- the contract's
    SELECT x.business_date, x.created_at, 7, CASE x.kind WHEN 'write_off' THEN 'write_off' ELSE 'profit_waiver' END,
           x.id, c.number, x.reason, NULL, 0,
           CASE x.kind WHEN 'write_off' THEN x.amount ELSE x.profit_waived END
    FROM public.contract_changes x
    JOIN public.contracts c ON c.id = x.contract_id AND c.organization_id = x.organization_id
    WHERE x.organization_id = p_org AND c.customer_id = p_customer_id
      AND ((x.kind = 'early_settlement' AND x.profit_waived > 0) OR x.kind = 'write_off')
$$;

REVOKE ALL ON FUNCTION app.customer_statement_rows(uuid, uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.get_settlement_quote(uuid), public.settle_contract_early(uuid, jsonb, text),
    public.preview_reschedule(uuid, jsonb), public.reschedule_contract(uuid, jsonb, text),
    public.write_off_contract(uuid, jsonb, text), public.list_contract_changes_for(uuid),
    public.list_contract_changes(jsonb), public.reverse_collection(uuid, jsonb, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_settlement_quote(uuid), public.settle_contract_early(uuid, jsonb, text),
    public.preview_reschedule(uuid, jsonb), public.reschedule_contract(uuid, jsonb, text),
    public.write_off_contract(uuid, jsonb, text), public.list_contract_changes_for(uuid),
    public.list_contract_changes(jsonb), public.reverse_collection(uuid, jsonb, text)
    TO authenticated;
