-- =============================================================================
-- N01 · Installment rules engine (EC-80, D76)
--
-- Every installment sale gets its terms from one calculation on the server: from the shop's
-- current policy version (P03) and the cashier's inputs (cash price, down payment, number of
-- installments, frequency, first due date) it gives the financed amount, the profit for the whole
-- term, the installment price and the schedule lines (principal + profit), all adding up exactly.
-- The installment sale is a sale at a fixed deferred price, not a loan
-- (docs/ISLAMIC_FINANCE_RULES.md): the price is fixed once at signing and nothing here is a rate
-- on time.
--
-- Numbered after the newest migration on main (D39). Everything below is NEW; no table, column,
-- enum or permission changes.
--   * app.installment_terms: the engine, pure (same inputs, same answer). Its TypeScript copy is
--     computeInstallmentTerms in the contracts; both run supabase/tests/fixtures/n01_terms_cases.json.
--   * app.check_installment_terms: the confirm side for N02 (POLICY_NOT_SET, POLICY_CHANGED,
--     INSTALLMENT_TERMS_INVALID), called inside the installment sale's transaction.
--   * trg_contracts_terms_check and trg_schedule_lines_sum_check: commit-time safety nets, so a
--     contract on an old policy version, terms that break the policy or lines that don't add up are
--     refused whoever writes them.
--   * public.preview_installment_terms: the POS preview (read only, works in an expired shop).
--
-- Rules (D76; the owner's answers of 15 Oct):
--   1. financed = cash price - down payment; markup % = the first markup tier whose up_to_months
--      covers the plan's duration, for the WHOLE term; markup = round(financed x % / 100, 2);
--      total = financed + markup.
--   2. Duration in months: monthly = n; weekly = ceil(7n / 30); daily = ceil(n / 30).
--   3. Installment = total / n rounded UP to a multiple of the policy's rounding step (n = 1: the
--      total); lines 1..n-1 carry it, the last line the rest (a last line <= 0 is `rounding`).
--   4. The markup is spread over the lines in proportion to their amounts, largest remainder in
--      piasters (ties to the earlier line); principal = amount - profit.
--   5. First due date: default one period after the sale; after the sale day and at most 60 days
--      after it. Line k is due k-1 periods after the first (months counted from the first date,
--      month ends clamped).
--   6. Policy rules, each reported as a violation: frequency allowed, minimum sale, down payment
--      below the cash price and the max %, down payment minimum by the frequency's rule (percent,
--      one installment, or for daily one installment per day of the month so far), months within
--      max_months and the amount tier, installment minimum (the last line is exempt), rounding,
--      first due date range.
-- =============================================================================

-- 1. The engine (no grants) --------------------------------------------------------------------

CREATE FUNCTION app.installment_duration_months(p_frequency public.installment_frequency, p_count integer)
RETURNS integer LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE p_frequency WHEN 'monthly' THEN p_count
                            WHEN 'weekly' THEN (p_count * 7 + 29) / 30
                            ELSE (p_count + 29) / 30 END
$$;

-- Due date of installment p_seq (1-based), always counted from the first due date.
CREATE FUNCTION app.installment_due_date(p_first date, p_frequency public.installment_frequency, p_seq integer)
RETURNS date LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE p_frequency WHEN 'monthly' THEN (p_first + make_interval(months => p_seq - 1))::date
                            WHEN 'weekly' THEN p_first + 7 * (p_seq - 1)
                            ELSE p_first + (p_seq - 1) END
$$;

-- The regular installment: total / n rounded up to a multiple of the step, in exact piasters.
CREATE FUNCTION app.installment_regular(p_total numeric, p_count integer, p_step numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE WHEN p_count = 1 THEN p_total
                ELSE div(p_total * 100 + p_step * 100 * p_count - 1, p_step * 100 * p_count) * p_step END
$$;

CREATE FUNCTION app.installment_terms(p_policy public.installment_policies, p_input jsonb, p_today date)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
    v_freq public.installment_frequency := (p_input ->> 'frequency')::public.installment_frequency;
    v_n integer := (p_input ->> 'installments_count')::integer;
    v_cash numeric := (p_input ->> 'cash_price')::numeric;
    v_down numeric := (p_input ->> 'down_payment')::numeric;
    v_step numeric := p_policy.rounding_step;
    v_duration integer; v_pct numeric; v_financed numeric; v_markup numeric := 0; v_total numeric;
    v_inst numeric; v_last numeric; v_lines_ok boolean := false;
    v_below numeric; v_cap numeric; v_max_down numeric; v_rule text; v_factor integer := 1;
    v_min_down numeric; v_lo bigint; v_hi bigint; v_mid bigint;
    v_max_months integer; v_first date; v_earliest date; v_latest date; v_min_inst numeric;
    v_violations jsonb := '[]'; v_lines jsonb := '[]';
    v_markup_p numeric; v_total_p numeric; v_seq integer; v_amount numeric; v_profit numeric;
BEGIN
    v_duration := app.installment_duration_months(v_freq, v_n);
    SELECT round((t ->> 'pct')::numeric, 4) INTO v_pct
    FROM jsonb_array_elements(p_policy.markup_tiers) WITH ORDINALITY x(t, o)
    WHERE (t ->> 'up_to_months')::integer >= v_duration ORDER BY o LIMIT 1;
    IF v_pct IS NULL THEN
        v_pct := round((p_policy.markup_tiers -> -1 ->> 'pct')::numeric, 4);
    END IF;

    v_financed := v_cash - v_down;
    IF v_financed > 0 THEN
        v_markup := round(v_financed * v_pct / 100, 2);
        v_total := v_financed + v_markup;
        v_inst := app.installment_regular(v_total, v_n, v_step);
        v_last := v_total - v_inst * (v_n - 1);
        v_lines_ok := v_last > 0;
    ELSE
        v_financed := 0;
        v_total := 0;
    END IF;

    -- Down payment limits.
    v_below := v_cash - 0.01;
    v_cap := CASE WHEN p_policy.max_down_payment_pct IS NULL THEN v_below
                  ELSE round(p_policy.max_down_payment_pct * v_cash / 100, 2) END;
    v_max_down := least(v_cap, v_below);
    v_rule := COALESCE(p_policy.down_payment_rules ->> v_freq::text, 'percent');
    IF v_rule = 'installment_per_day_of_month' THEN
        v_factor := extract(day FROM p_today)::integer;
    END IF;
    IF v_rule = 'percent' THEN
        v_min_down := round(p_policy.min_down_payment_pct * v_cash / 100, 2);
    ELSE
        -- The smallest down payment (in piasters, below the cash price) covering its installment(s).
        v_lo := 0;
        v_hi := (v_below * 100)::bigint;
        IF v_hi < 0 OR (v_hi::numeric / 100) < app.installment_regular(
                (v_cash - v_hi::numeric / 100) + round((v_cash - v_hi::numeric / 100) * v_pct / 100, 2),
                v_n, v_step) * v_factor THEN
            v_min_down := NULL;
        ELSE
            WHILE v_lo < v_hi LOOP
                v_mid := (v_lo + v_hi) / 2;
                IF (v_mid::numeric / 100) >= app.installment_regular(
                        (v_cash - v_mid::numeric / 100) + round((v_cash - v_mid::numeric / 100) * v_pct / 100, 2),
                        v_n, v_step) * v_factor THEN
                    v_hi := v_mid;
                ELSE
                    v_lo := v_mid + 1;
                END IF;
            END LOOP;
            v_min_down := v_lo::numeric / 100;
        END IF;
    END IF;

    -- Month limits: max_months and the max months of the first amount tier covering the price.
    SELECT (t ->> 'max_months')::integer INTO v_max_months
    FROM jsonb_array_elements(p_policy.amount_tiers) WITH ORDINALITY x(t, o)
    WHERE (t ->> 'up_to_amount')::numeric >= v_cash ORDER BY o LIMIT 1;
    v_max_months := least(p_policy.max_months, COALESCE(v_max_months, p_policy.max_months));

    -- Dates.
    v_first := COALESCE((p_input ->> 'first_due_date')::date,
                        CASE v_freq WHEN 'monthly' THEN (p_today + interval '1 month')::date
                                    WHEN 'weekly' THEN p_today + 7 ELSE p_today + 1 END);
    v_earliest := p_today + 1;
    v_latest := p_today + 60;

    -- Violations, in a fixed order (the TypeScript copy lists them the same way).
    IF v_freq <> ALL (p_policy.allowed_frequencies) THEN
        v_violations := v_violations || jsonb_build_object('rule', 'frequency_not_allowed',
            'allowed', to_jsonb(p_policy.allowed_frequencies));
    END IF;
    IF v_cash < p_policy.min_sale_amount THEN
        v_violations := v_violations || jsonb_build_object('rule', 'sale_below_minimum',
            'min_sale_amount', p_policy.min_sale_amount::numeric(18,2)::text);
    END IF;
    IF v_down > v_max_down THEN
        v_violations := v_violations || jsonb_build_object('rule', 'down_payment_too_high',
            'max_down_payment', v_max_down::numeric(18,2)::text);
    ELSIF v_min_down IS NULL OR v_down < v_min_down THEN
        v_violations := v_violations || jsonb_build_object('rule', 'down_payment_too_low',
            'min_down_payment', v_min_down::numeric(18,2)::text, 'down_payment_rule', v_rule);
    END IF;
    IF v_duration > v_max_months THEN
        v_violations := v_violations || jsonb_build_object('rule', 'too_many_months',
            'max_months', v_max_months, 'duration_months', v_duration);
    END IF;
    v_min_inst := greatest(p_policy.min_installment,
                           COALESCE((p_policy.min_installment_by_frequency ->> v_freq::text)::numeric, 0));
    IF v_inst IS NOT NULL AND v_inst < v_min_inst THEN
        v_violations := v_violations || jsonb_build_object('rule', 'installment_below_minimum',
            'min_installment', v_min_inst::numeric(18,2)::text);
    END IF;
    IF v_inst IS NOT NULL AND NOT v_lines_ok THEN
        v_violations := v_violations || jsonb_build_object('rule', 'rounding',
            'rounding_step', v_step::numeric(18,2)::text);
    END IF;
    IF v_first < v_earliest OR v_first > v_latest THEN
        v_violations := v_violations || jsonb_build_object('rule', 'first_due_date_out_of_range',
            'earliest', v_earliest::text, 'latest', v_latest::text);
    END IF;

    -- Lines: the profit spread in proportion to the amounts, largest remainder in piasters.
    IF v_lines_ok THEN
        v_markup_p := v_markup * 100;
        v_total_p := v_total * 100;
        WITH l AS (
            SELECT s AS seq, CASE WHEN s = v_n THEN v_last ELSE v_inst END AS amount
            FROM generate_series(1, v_n) s
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
                   'due_date', app.installment_due_date(v_first, v_freq, seq)::text,
                   'principal', (amount - p)::numeric(18,2)::text,
                   'profit', p::numeric(18,2)::text,
                   'amount', amount::numeric(18,2)::text) ORDER BY seq), '[]')
        INTO v_lines
        FROM (SELECT seq, amount, (floor_p + CASE WHEN rnk <= leftover THEN 1 ELSE 0 END) / 100 AS p FROM r) x;
    END IF;

    RETURN jsonb_build_object(
        'policy_id', p_policy.id,
        'policy_version', p_policy.version,
        'cash_price', v_cash::numeric(18,2)::text,
        'down_payment', v_down::numeric(18,2)::text,
        'financed_amount', v_financed::numeric(18,2)::text,
        'markup_pct', trim_scale(v_pct)::text,
        'markup_amount', v_markup::numeric(18,2)::text,
        'total_payable', v_total::numeric(18,2)::text,
        'installments_count', v_n,
        'frequency', v_freq,
        'duration_months', v_duration,
        'installment_amount', v_inst::numeric(18,2)::text,
        'last_installment_amount', CASE WHEN v_lines_ok THEN v_last::numeric(18,2)::text END,
        'first_due_date', v_first::text,
        'last_due_date', app.installment_due_date(v_first, v_freq, v_n)::text,
        'min_down_payment', v_min_down::numeric(18,2)::text,
        'max_down_payment', v_max_down::numeric(18,2)::text,
        'max_months_allowed', v_max_months,
        'lines', v_lines,
        'violations', v_violations);
END;
$$;

-- The engine's input from a request body: the five keys, checked like the contract
-- (InstallmentTermsInput). Extra keys are the caller's (the preview adds customer and guarantors).
CREATE FUNCTION app.installment_input(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_key text;
BEGIN
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    FOREACH v_key IN ARRAY ARRAY['cash_price', 'down_payment'] LOOP
        IF jsonb_typeof(p_body -> v_key) IS DISTINCT FROM 'string'
           OR (p_body ->> v_key) !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF (p_body ->> 'cash_price')::numeric <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: cash_price' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_body -> 'installments_count') IS DISTINCT FROM 'number'
       OR (p_body ->> 'installments_count') !~ '^[0-9]{1,3}$'
       OR (p_body ->> 'installments_count')::integer NOT BETWEEN 1 AND 520 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: installments_count' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_body -> 'frequency') IS DISTINCT FROM 'string'
       OR (p_body ->> 'frequency') NOT IN (SELECT unnest(enum_range(NULL::public.installment_frequency))::text) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: frequency' USING ERRCODE = 'P0001';
    END IF;
    IF p_body ? 'first_due_date' THEN
        IF jsonb_typeof(p_body -> 'first_due_date') IS DISTINCT FROM 'string'
           OR (p_body ->> 'first_due_date') !~ '^\d{4}-\d{2}-\d{2}$'
           OR to_char(to_date(p_body ->> 'first_due_date', 'YYYY-MM-DD'), 'YYYY-MM-DD') <> (p_body ->> 'first_due_date') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: first_due_date' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN jsonb_strip_nulls(jsonb_build_object(
        'cash_price', p_body ->> 'cash_price', 'down_payment', p_body ->> 'down_payment',
        'installments_count', (p_body ->> 'installments_count')::integer,
        'frequency', p_body ->> 'frequency', 'first_due_date', p_body ->> 'first_due_date'));
END;
$$;

-- 2. The confirm side for N02 (no grants) --------------------------------------------------------

-- The installment sale calls this inside its transaction with what the preview showed: the shop's
-- current policy must still be the version the POS previewed, and the terms must pass every rule.
-- Returns the terms; N02 stores exactly these (contract columns and version-1 schedule lines).
CREATE FUNCTION app.check_installment_terms(p_org uuid, p_input jsonb, p_policy_version integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_policy public.installment_policies; v_terms jsonb;
BEGIN
    v_policy := app.current_installment_policy(p_org);
    IF v_policy.id IS NULL THEN
        RAISE EXCEPTION 'POLICY_NOT_SET' USING ERRCODE = 'P0001';
    END IF;
    IF p_policy_version IS DISTINCT FROM v_policy.version THEN
        RAISE EXCEPTION 'POLICY_CHANGED' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('current_version', v_policy.version)::text;
    END IF;
    v_terms := app.installment_terms(v_policy, app.installment_input(p_input), app.org_today(p_org));
    IF jsonb_array_length(v_terms -> 'violations') > 0 THEN
        RAISE EXCEPTION 'INSTALLMENT_TERMS_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('violations', v_terms -> 'violations')::text;
    END IF;
    RETURN v_terms;
END;
$$;

-- 3. Safety nets at commit (any writer) ---------------------------------------------------------

-- A new contract must use the shop's current policy version, pass every rule of the engine for
-- the day it was made, and carry exactly the engine's markup, total, count, first due date and
-- version-1 lines. Migrated (M02) contracts keep the terms they had.
CREATE FUNCTION app.contracts_terms_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_current public.installment_policies; v_policy public.installment_policies; v_today date;
        v_terms jsonb; v_lines jsonb;
BEGIN
    IF NEW.is_migrated THEN
        RETURN NULL;
    END IF;
    v_current := app.current_installment_policy(NEW.organization_id);
    IF v_current.id IS DISTINCT FROM NEW.policy_id THEN
        RAISE EXCEPTION 'POLICY_CHANGED' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('current_version', v_current.version)::text;
    END IF;
    SELECT * INTO v_policy FROM public.installment_policies
    WHERE id = NEW.policy_id AND organization_id = NEW.organization_id;
    SELECT (NEW.created_at AT TIME ZONE o.timezone)::date INTO v_today
    FROM public.organizations o WHERE o.id = NEW.organization_id;
    v_terms := app.installment_terms(v_policy, jsonb_build_object(
        'cash_price', NEW.cash_price::numeric(18,2)::text, 'down_payment', NEW.down_payment::numeric(18,2)::text,
        'installments_count', NEW.installments_count, 'frequency', NEW.frequency,
        'first_due_date', NEW.first_due_date::text), v_today);
    IF jsonb_array_length(v_terms -> 'violations') > 0 THEN
        RAISE EXCEPTION 'INSTALLMENT_TERMS_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('violations', v_terms -> 'violations')::text;
    END IF;
    IF NEW.markup_pct <> (v_terms ->> 'markup_pct')::numeric THEN
        RAISE EXCEPTION 'INSTALLMENT_TERMS_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('mismatch', 'markup_pct')::text;
    END IF;
    IF NEW.markup_amount <> (v_terms ->> 'markup_amount')::numeric
       OR NEW.total_payable <> (v_terms ->> 'total_payable')::numeric THEN
        RAISE EXCEPTION 'INSTALLMENT_TERMS_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('mismatch', 'markup_amount')::text;
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'seq', l.seq, 'due_date', l.due_date::text, 'principal', l.principal::numeric(18,2)::text,
               'profit', l.profit::numeric(18,2)::text, 'amount', l.amount::numeric(18,2)::text) ORDER BY l.seq), '[]')
    INTO v_lines
    FROM public.schedule_lines l
    WHERE l.contract_id = NEW.id AND l.organization_id = NEW.organization_id AND l.version = 1;
    IF v_lines <> v_terms -> 'lines' THEN
        RAISE EXCEPTION 'INSTALLMENT_TERMS_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('mismatch', 'lines')::text;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_contracts_terms_check
    AFTER INSERT ON public.contracts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION app.contracts_terms_check();

-- The version-1 lines of a contract (migrated ones too) add up to its total, financed amount and
-- markup, and run 1..n without a gap. TODO(N05): later versions (reschedules) need their own
-- check against what N05 stores; a reschedule never increases what is owed.
CREATE FUNCTION app.schedule_lines_sum_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_c public.contracts; v_n integer; v_max integer; v_amount numeric; v_principal numeric; v_profit numeric;
BEGIN
    IF NEW.version <> 1 THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_c FROM public.contracts WHERE id = NEW.contract_id AND organization_id = NEW.organization_id;
    SELECT count(*), max(seq), sum(amount), sum(principal), sum(profit)
    INTO v_n, v_max, v_amount, v_principal, v_profit
    FROM public.schedule_lines
    WHERE contract_id = NEW.contract_id AND organization_id = NEW.organization_id AND version = 1;
    IF v_max <> v_n OR v_amount <> v_c.total_payable OR v_principal <> v_c.financed_amount
       OR v_profit <> v_c.markup_amount THEN
        RAISE EXCEPTION 'SCHEDULE_NOT_BALANCED: %', v_c.number USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_schedule_lines_sum_check
    AFTER INSERT ON public.schedule_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION app.schedule_lines_sum_check();

REVOKE ALL ON FUNCTION app.installment_duration_months(public.installment_frequency, integer),
    app.installment_due_date(date, public.installment_frequency, integer),
    app.installment_regular(numeric, integer, numeric),
    app.installment_terms(public.installment_policies, jsonb, date), app.installment_input(jsonb),
    app.check_installment_terms(uuid, jsonb, integer), app.contracts_terms_check(),
    app.schedule_lines_sum_check()
    FROM PUBLIC, anon, authenticated;

-- 4. The POS preview -----------------------------------------------------------------------------

-- Read only (nothing is written, no audit row): installment.create, the installments module and
-- the shop's installments switch. Works in an expired (read-only) shop; N02's write refuses it.
-- With a customer, the R03 credit check, the R04 guarantor requirement and the R05 survey
-- requirement are added (their own guards apply).
CREATE FUNCTION public.preview_installment_terms(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.current_employee_id(); v_org uuid; v_policy public.installment_policies;
    v_input jsonb; v_terms jsonb; v_key text; v_customer uuid; v_ids uuid[] := '{}'; v_financed text;
    v_credit jsonb; v_guar jsonb; v_survey jsonb; v_selected integer; v_selected_met boolean;
    v_can boolean;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('installment.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: installment.create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    IF NOT (SELECT o.installments_enabled FROM public.organizations o WHERE o.id = v_org) THEN
        RAISE EXCEPTION 'INSTALLMENTS_DISABLED' USING ERRCODE = 'P0001';
    END IF;

    v_input := app.installment_input(p_body);
    FOR v_key IN SELECT jsonb_object_keys(p_body) LOOP
        IF v_key NOT IN ('cash_price', 'down_payment', 'installments_count', 'frequency', 'first_due_date',
                         'customer_id', 'guarantor_ids') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF p_body ? 'customer_id' THEN
        IF jsonb_typeof(p_body -> 'customer_id') IS DISTINCT FROM 'string'
           OR (p_body ->> 'customer_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: customer_id' USING ERRCODE = 'P0001';
        END IF;
        v_customer := (p_body ->> 'customer_id')::uuid;
    END IF;
    IF p_body ? 'guarantor_ids' THEN
        IF jsonb_typeof(p_body -> 'guarantor_ids') IS DISTINCT FROM 'array'
           OR jsonb_array_length(p_body -> 'guarantor_ids') > 3
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_body -> 'guarantor_ids') g
                      WHERE jsonb_typeof(g) <> 'string'
                         OR (g #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
           OR (SELECT count(DISTINCT g #>> '{}') FROM jsonb_array_elements(p_body -> 'guarantor_ids') g)
              <> jsonb_array_length(p_body -> 'guarantor_ids') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: guarantor_ids' USING ERRCODE = 'P0001';
        END IF;
        SELECT COALESCE(array_agg((g #>> '{}')::uuid), '{}') INTO v_ids
        FROM jsonb_array_elements(p_body -> 'guarantor_ids') g;
    END IF;

    v_policy := app.current_installment_policy(v_org);
    IF v_policy.id IS NULL THEN
        RAISE EXCEPTION 'POLICY_NOT_SET' USING ERRCODE = 'P0001';
    END IF;
    v_terms := app.installment_terms(v_policy, v_input, app.org_today(v_org));
    v_can := jsonb_array_length(v_terms -> 'violations') = 0;

    IF v_customer IS NULL OR (v_terms ->> 'financed_amount')::numeric <= 0 THEN
        RETURN jsonb_build_object('terms', v_terms, 'customer', NULL, 'can_confirm', false);
    END IF;

    v_financed := v_terms ->> 'financed_amount';
    v_credit := public.get_customer_credit_check(v_customer, v_financed);
    v_guar := public.get_guarantor_requirement(v_customer, v_financed);
    v_survey := public.get_survey_requirement(v_customer, v_financed);
    SELECT count(*) INTO v_selected
    FROM public.customer_guarantors cg
    JOIN public.guarantors g ON g.id = cg.guarantor_id AND g.organization_id = cg.organization_id
    WHERE cg.organization_id = v_org AND cg.customer_id = v_customer AND g.archived_at IS NULL
      AND cg.guarantor_id = ANY (v_ids);
    BEGIN
        PERFORM app.check_contract_guarantors(v_org, v_customer, v_policy.id, v_financed::numeric, v_ids);
        v_selected_met := true;
    EXCEPTION WHEN raise_exception THEN
        v_selected_met := false;
    END;
    v_guar := v_guar || jsonb_build_object('selected', v_selected, 'selected_met', v_selected_met);

    v_can := v_can
        AND ((v_credit ->> 'allowed')::boolean OR v_credit ->> 'approved_approval_id' IS NOT NULL)
        AND v_selected_met
        AND (v_survey ->> 'met')::boolean;
    RETURN jsonb_build_object(
        'terms', v_terms,
        'customer', jsonb_build_object('credit', v_credit, 'guarantors', v_guar, 'survey', v_survey),
        'can_confirm', v_can);
END;
$$;

REVOKE ALL ON FUNCTION public.preview_installment_terms(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_installment_terms(jsonb) TO authenticated;
