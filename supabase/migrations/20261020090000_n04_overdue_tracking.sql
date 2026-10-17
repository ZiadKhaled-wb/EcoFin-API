-- =============================================================================
-- N04 · Overdue tracking, no late fees (EC-83, D79)
--
-- Every day, in each shop's time zone, the server looks at every open installment contract and,
-- without ever changing what anyone owes: puts a warning on the staff's work list the first day a
-- contract is overdue and every N days after while it stays overdue, blocks a customer who is
-- late more than the shop's ban days from new installment sales, and flags a contract for legal
-- referral once it is late more than the shop's legal days for its frequency.
-- Islamic finance (docs/ISLAMIC_FINANCE_RULES.md, binding): no late fee or penalty of any kind
-- (rule 4). This migration also locks the policy's late-fee fields and refuses new charges.
--
-- Rules (docs/tasks/N04.md, owner decisions 17 Oct, D79):
--   1. Overdue stays derived: v_schedule_line_status marks a line overdue only after its due date
--      plus the grace days of the contract's own policy version. Days late count from the due
--      date. Inside grace a line is 'due' (payable, not late): no new status value.
--   2. The job only records events in overdue_actions, under unique keys: a second run in the
--      same day changes nothing. It never writes payments, schedule lines, charges or amounts.
--   3. Warning: the first overdue day, then every overdue_warning_interval_days while overdue.
--      Staff mark it handled with an outcome. Caught up -> the open warning is 'resolved'.
--   4. Ban: oldest overdue line late more than customer_ban_days (0 = off) -> one ban record per
--      line, the customer set to 'blocked' (R01) with a reason. Lifted only by hand (R01).
--   5. Legal referral: oldest overdue line late at least legal_referral_days[frequency] (missing
--      or 0 = off) -> one open referral per contract, kept until the owner dismisses it or L01
--      opens a case from it.
--   6. Who: overdue.view sees every branch of the shop; overdue.handle marks warnings handled;
--      only the owner dismisses a referral or runs the check by hand.
--
-- Numbers: contracts 0.49.0, 6 routes. Schema: overdue_actions + two enums, permissions
-- overdue.view / overdue.handle, a CHECK on new policy versions, a guard on charges.
-- =============================================================================

-- 1. Schema ------------------------------------------------------------------------------------------

CREATE TYPE public.overdue_action_kind   AS ENUM ('warning', 'ban', 'legal_referral');
CREATE TYPE public.overdue_action_status AS ENUM ('open', 'handled', 'superseded', 'resolved',
                                                  'dismissed', 'case_opened');

CREATE TABLE public.overdue_actions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL,
    kind             public.overdue_action_kind NOT NULL,
    contract_id      uuid NOT NULL,
    customer_id      uuid NOT NULL,
    branch_id        uuid NOT NULL,
    schedule_line_id uuid NOT NULL,                      -- the contract's oldest overdue line then
    business_date    date NOT NULL,
    days_late        integer NOT NULL CHECK (days_late > 0),
    overdue_amount   numeric(18,2) NOT NULL CHECK (overdue_amount > 0),
    status           public.overdue_action_status NOT NULL,
    outcome          text CHECK (outcome IN ('contacted', 'promised', 'no_answer', 'wrong_number', 'other')),
    note             text CHECK (length(note) <= 500),
    handled_by       uuid,
    handled_at       timestamptz,
    legal_case_id    uuid,                               -- L01 links the case it opened
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT overdue_actions_id_org_key UNIQUE (id, organization_id),
    FOREIGN KEY (contract_id, customer_id, organization_id)
        REFERENCES public.contracts (id, customer_id, organization_id),
    FOREIGN KEY (branch_id, organization_id)       REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (schedule_line_id)                 REFERENCES public.schedule_lines (id),
    FOREIGN KEY (handled_by, organization_id)      REFERENCES public.employees (id, organization_id),
    FOREIGN KEY (legal_case_id, organization_id)   REFERENCES public.legal_cases (id, organization_id),
    CHECK (kind = 'warning' OR outcome IS NULL),
    CHECK (status <> 'case_opened' OR (kind = 'legal_referral' AND legal_case_id IS NOT NULL))
);
CREATE UNIQUE INDEX overdue_actions_warning_day_key ON public.overdue_actions (contract_id, business_date)
    WHERE kind = 'warning';
CREATE UNIQUE INDEX overdue_actions_ban_line_key ON public.overdue_actions (schedule_line_id)
    WHERE kind = 'ban';
CREATE UNIQUE INDEX overdue_actions_legal_line_key ON public.overdue_actions (schedule_line_id)
    WHERE kind = 'legal_referral';
CREATE UNIQUE INDEX overdue_actions_legal_open_key ON public.overdue_actions (contract_id)
    WHERE kind = 'legal_referral' AND status = 'open';
CREATE INDEX overdue_actions_list_idx ON public.overdue_actions (organization_id, kind, status, business_date);
CREATE INDEX overdue_actions_contract_idx ON public.overdue_actions (contract_id, kind, business_date DESC);

ALTER TABLE public.overdue_actions ENABLE ROW LEVEL SECURITY;
-- Notes and dismissal reasons are for the overdue readers only, not every employee of the shop.
CREATE POLICY overdue_actions_tenant_read ON public.overdue_actions
    FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id()) AND (SELECT app.has_permission('overdue.view')));
REVOKE ALL ON public.overdue_actions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.overdue_actions TO authenticated;
GRANT ALL ON public.overdue_actions TO service_role;

INSERT INTO public.permissions (key, module, description) VALUES
    ('overdue.view',   'installments', 'See overdue contracts, warnings and legal referrals'),
    ('overdue.handle', 'installments', 'Mark overdue warnings handled');
INSERT INTO public.role_permissions (role, permission_key) VALUES
    ('BRANCH_MANAGER', 'overdue.view'), ('COLLECTOR', 'overdue.view'), ('ACCOUNTANT', 'overdue.view'),
    ('LAWYER', 'overdue.view'),
    ('BRANCH_MANAGER', 'overdue.handle'), ('COLLECTOR', 'overdue.handle');

-- 2. No late fees (rule 4) ---------------------------------------------------------------------------

-- New policy versions can't carry a fee; versions written before stay readable (none exist on
-- dev, checked 17 Oct).
ALTER TABLE public.installment_policies ADD CONSTRAINT installment_policies_no_late_fee
    CHECK (late_fee_type = 'none' AND late_fee_value = 0 AND NOT late_fee_recurring AND late_fee_cap IS NULL)
    NOT VALID;

CREATE FUNCTION app.refuse_charges()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    RAISE EXCEPTION 'LATE_FEES_NOT_ALLOWED' USING ERRCODE = 'P0001';
END;
$$;
CREATE TRIGGER trg_charges_refuse BEFORE INSERT ON public.charges
    FOR EACH ROW EXECUTE FUNCTION app.refuse_charges();

-- The policy publisher (P03, R04) keeps all its checks; it moves to app and the public function
-- in front of it refuses a fee and writes none / 0 for the fields left out, so a version copied
-- from an older one never inherits a fee.
ALTER FUNCTION public.publish_installment_policy(jsonb) SET SCHEMA app;
ALTER FUNCTION app.publish_installment_policy(jsonb) RENAME TO publish_installment_policy_core;
REVOKE ALL ON FUNCTION app.publish_installment_policy_core(jsonb) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.publish_installment_policy(p_policy jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    PERFORM app.require_permission('org.settings_manage');
    PERFORM app.require_module('installments');
    IF p_policy IS NULL OR jsonb_typeof(p_policy) <> 'object' THEN
        RAISE EXCEPTION 'POLICY_INVALID: body' USING ERRCODE = 'P0001';
    END IF;
    IF (p_policy ? 'late_fee_type' AND p_policy -> 'late_fee_type' IS DISTINCT FROM '"none"'::jsonb)
       OR (p_policy ? 'late_fee_value' AND (jsonb_typeof(p_policy -> 'late_fee_value') NOT IN ('number', 'string')
                                            OR (p_policy ->> 'late_fee_value') !~ '^0+(\.0+)?$'))
       OR (p_policy ? 'late_fee_recurring' AND p_policy -> 'late_fee_recurring' IS DISTINCT FROM 'false'::jsonb)
       OR (p_policy ? 'late_fee_cap' AND jsonb_typeof(p_policy -> 'late_fee_cap') <> 'null') THEN
        RAISE EXCEPTION 'LATE_FEES_NOT_ALLOWED' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.publish_installment_policy_core(p_policy || jsonb_build_object(
        'late_fee_type', 'none', 'late_fee_value', 0, 'late_fee_recurring', false, 'late_fee_cap', NULL));
END;
$$;

-- 3. Overdue after grace (decision 1) ----------------------------------------------------------------

-- Same columns in the same order as the baseline, so the views built on it stay as they are.
CREATE OR REPLACE VIEW public.v_schedule_line_status WITH (security_invoker = true) AS
WITH paid AS (
    SELECT schedule_line_id,
           SUM(amount) AS paid, SUM(principal_amount) AS paid_principal, SUM(profit_amount) AS paid_profit
    FROM public.v_effective_allocations WHERE schedule_line_id IS NOT NULL
    GROUP BY schedule_line_id
), fees AS (
    SELECT ch.schedule_line_id,
           SUM(ch.amount) AS charged,
           SUM(COALESCE(w.waived, 0)) AS waived,
           SUM(COALESCE(fp.paid, 0)) AS fees_paid
    FROM public.charges ch
    LEFT JOIN (SELECT charge_id, SUM(amount) AS waived FROM public.charge_waivers GROUP BY charge_id) w ON w.charge_id = ch.id
    LEFT JOIN (SELECT charge_id, SUM(amount) AS paid FROM public.v_effective_allocations
               WHERE charge_id IS NOT NULL GROUP BY charge_id) fp ON fp.charge_id = ch.id
    GROUP BY ch.schedule_line_id
)
SELECT sl.organization_id, sl.id AS schedule_line_id, sl.contract_id, sl.version, sl.seq,
       sl.due_date, sl.principal, sl.profit, sl.amount, sl.superseded,
       COALESCE(p.paid, 0)::numeric(18,2)           AS paid,
       COALESCE(p.paid_principal, 0)::numeric(18,2) AS paid_principal,
       COALESCE(p.paid_profit, 0)::numeric(18,2)    AS paid_profit,
       (sl.amount - COALESCE(p.paid, 0))::numeric(18,2) AS remaining,
       (sl.principal - COALESCE(p.paid_principal, 0))::numeric(18,2) AS principal_remaining,
       (COALESCE(f.charged, 0) - COALESCE(f.waived, 0) - COALESCE(f.fees_paid, 0))::numeric(18,2) AS fees_due,
       GREATEST((now() AT TIME ZONE o.timezone)::date - sl.due_date, 0) AS days_late,
       CASE
           WHEN sl.superseded THEN 'superseded'
           WHEN sl.amount - COALESCE(p.paid, 0) <= 0 THEN 'paid'
           WHEN c.status NOT IN ('active', 'rescheduled') THEN 'closed'     -- written off / returned / settled
           WHEN sl.due_date + ip.grace_days < (now() AT TIME ZONE o.timezone)::date THEN 'overdue'
           WHEN COALESCE(p.paid, 0) > 0 THEN 'partly_paid'
           WHEN sl.due_date <= (now() AT TIME ZONE o.timezone)::date THEN 'due'   -- today, or inside grace
           ELSE 'upcoming'
       END AS status
FROM public.schedule_lines sl
JOIN public.contracts c ON c.id = sl.contract_id
JOIN public.installment_policies ip ON ip.id = c.policy_id
JOIN public.organizations o ON o.id = sl.organization_id
LEFT JOIN paid p ON p.schedule_line_id = sl.id
LEFT JOIN fees f ON f.schedule_line_id = sl.id;

-- 4. Who sees a contract: the overdue list readers see every branch too (decision 10) ------------------

CREATE OR REPLACE FUNCTION app.can_see_contract(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT app.has_permission('collection.create') OR app.has_permission('collection.reverse')
        OR app.has_permission('overdue.view') OR app.has_branch_access(p_branch_id)
$$;

-- 5. The daily check (decisions 2-8) -----------------------------------------------------------------

-- One shop, today. Safe to run any number of times: every insert has a unique key and every update
-- only moves rows that are still in the state it looks for.
CREATE FUNCTION app.overdue_run(p_org uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_today date; v_s public.org_settings; v_resolved integer; v_created integer; v_bans integer := 0;
    v_blocked integer := 0; v_legal integer := 0; r record; v_interval integer; v_ban_days integer;
    v_legal_days jsonb;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('overdue_run:' || p_org::text, 0));
    v_today := app.org_today(p_org);
    SELECT * INTO v_s FROM public.org_settings WHERE organization_id = p_org;
    v_interval := COALESCE(v_s.overdue_warning_interval_days, 10);
    v_ban_days := COALESCE(v_s.customer_ban_days, 0);
    v_legal_days := COALESCE(v_s.legal_referral_days, '{}'::jsonb);

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.overdue_now (
        contract_id uuid PRIMARY KEY, customer_id uuid, branch_id uuid, number text, frequency text,
        line_id uuid, days_late integer, overdue_amount numeric(18,2)) ON COMMIT DROP;
    TRUNCATE pg_temp.overdue_now;
    -- Open contracts with an overdue line: the oldest overdue line is the anchor.
    INSERT INTO pg_temp.overdue_now
    SELECT DISTINCT ON (c.id) c.id, c.customer_id, c.branch_id, c.number, c.frequency::text,
           ls.schedule_line_id, ls.days_late,
           SUM(ls.remaining) OVER (PARTITION BY c.id)
    FROM public.contracts c
    JOIN public.v_schedule_line_status ls ON ls.contract_id = c.id AND ls.status = 'overdue'
    WHERE c.organization_id = p_org AND c.status IN ('active', 'rescheduled')
    ORDER BY c.id, ls.due_date, ls.seq;

    -- Warnings (decision 4). Caught up or closed: the open warning is resolved.
    UPDATE public.overdue_actions a SET status = 'resolved'
    WHERE a.organization_id = p_org AND a.kind = 'warning' AND a.status = 'open'
      AND NOT EXISTS (SELECT 1 FROM pg_temp.overdue_now n WHERE n.contract_id = a.contract_id);
    GET DIAGNOSTICS v_resolved = ROW_COUNT;

    INSERT INTO public.overdue_actions (organization_id, kind, contract_id, customer_id, branch_id,
        schedule_line_id, business_date, days_late, overdue_amount, status)
    SELECT p_org, 'warning', n.contract_id, n.customer_id, n.branch_id, n.line_id, v_today,
           n.days_late, n.overdue_amount, 'open'
    FROM pg_temp.overdue_now n
    LEFT JOIN LATERAL (
        SELECT a.business_date, a.status FROM public.overdue_actions a
        WHERE a.contract_id = n.contract_id AND a.kind = 'warning'
        ORDER BY a.business_date DESC LIMIT 1) last ON true
    WHERE last.business_date IS NULL OR last.status = 'resolved'
       OR last.business_date <= v_today - v_interval
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_created = ROW_COUNT;

    UPDATE public.overdue_actions a SET status = 'superseded'
    WHERE a.organization_id = p_org AND a.kind = 'warning' AND a.status = 'open' AND a.business_date < v_today
      AND EXISTS (SELECT 1 FROM public.overdue_actions t
                  WHERE t.contract_id = a.contract_id AND t.kind = 'warning' AND t.business_date = v_today);

    -- Ban (decision 5): one record per anchor line; the customer blocked once.
    IF v_ban_days > 0 THEN
        CREATE TEMP TABLE IF NOT EXISTS pg_temp.overdue_bans (customer_id uuid, contract_id uuid) ON COMMIT DROP;
        TRUNCATE pg_temp.overdue_bans;
        WITH ins AS (
            INSERT INTO public.overdue_actions (organization_id, kind, contract_id, customer_id, branch_id,
                schedule_line_id, business_date, days_late, overdue_amount, status, handled_at)
            SELECT p_org, 'ban', n.contract_id, n.customer_id, n.branch_id, n.line_id, v_today,
                   n.days_late, n.overdue_amount, 'handled', now()
            FROM pg_temp.overdue_now n
            WHERE n.days_late > v_ban_days
            ON CONFLICT DO NOTHING
            RETURNING customer_id, contract_id)
        INSERT INTO pg_temp.overdue_bans SELECT customer_id, contract_id FROM ins;
        FOR r IN
            SELECT b.customer_id, min(n.number) AS number, count(*) AS rows
            FROM pg_temp.overdue_bans b JOIN pg_temp.overdue_now n ON n.contract_id = b.contract_id
            GROUP BY b.customer_id ORDER BY b.customer_id
        LOOP
            v_bans := v_bans + r.rows;
            UPDATE public.customers cu SET status = 'blocked', updated_at = now()
            WHERE cu.id = r.customer_id AND cu.organization_id = p_org AND cu.status <> 'blocked';
            IF FOUND THEN
                v_blocked := v_blocked + 1;
                PERFORM app.write_audit('customer.status_set', 'customer', r.customer_id,
                    p_before => jsonb_build_object('status', 'active'),
                    p_after => jsonb_build_object('status', 'blocked', 'by', 'overdue_check'),
                    p_reason => format('Late more than %s days on contract %s', v_ban_days, r.number),
                    p_severity => 'warning', p_organization_id => p_org);
            END IF;
        END LOOP;
    END IF;

    -- Legal referral (decision 6): one open referral per contract, one per anchor line ever.
    FOR r IN
        INSERT INTO public.overdue_actions (organization_id, kind, contract_id, customer_id, branch_id,
            schedule_line_id, business_date, days_late, overdue_amount, status)
        SELECT p_org, 'legal_referral', n.contract_id, n.customer_id, n.branch_id, n.line_id, v_today,
               n.days_late, n.overdue_amount, 'open'
        FROM pg_temp.overdue_now n
        WHERE COALESCE((v_legal_days ->> n.frequency)::integer, 0) > 0
          AND n.days_late >= (v_legal_days ->> n.frequency)::integer
        ON CONFLICT DO NOTHING
        RETURNING id, contract_id, branch_id, days_late, overdue_amount
    LOOP
        v_legal := v_legal + 1;
        PERFORM app.write_audit('contract.legal_referred', 'contract', r.contract_id,
            p_after => jsonb_build_object('referral_id', r.id, 'days_late', r.days_late,
                                          'overdue_amount', r.overdue_amount::text),
            p_branch_id => r.branch_id, p_severity => 'warning', p_organization_id => p_org);
    END LOOP;

    RETURN jsonb_build_object('business_date', v_today, 'warnings_created', v_created,
        'warnings_resolved', v_resolved, 'bans', v_bans, 'customers_blocked', v_blocked,
        'legal_referrals', v_legal);
END;
$$;

-- The nightly 'installments.overdue' job (service role only, like jobs_ledger_mismatches).
CREATE FUNCTION public.jobs_overdue_run(p_organization_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_organization_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = p_organization_id) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a shop is required' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.org_has_module(p_organization_id, 'installments') THEN
        RETURN jsonb_build_object('skipped', 'module');
    END IF;
    IF app.org_is_expired(p_organization_id) THEN
        RETURN jsonb_build_object('skipped', 'expired');
    END IF;
    RETURN app.overdue_run(p_organization_id);
END;
$$;

-- The owner runs the same check by hand (decision 9).
CREATE FUNCTION public.run_overdue_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    PERFORM app.require_permission('overdue.view');
    PERFORM app.require_module('installments');
    IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: owner' USING ERRCODE = '42501';
    END IF;
    RETURN app.overdue_run(app.current_org_id());
END;
$$;

-- 6. Reads ---------------------------------------------------------------------------------------------

CREATE FUNCTION app.overdue_read_guard()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_org_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    IF NOT app.has_permission('overdue.view') THEN          -- an expired shop may still read
        RAISE EXCEPTION 'PERMISSION_DENIED: overdue.view' USING ERRCODE = '42501';
    END IF;
    RETURN app.current_org_id();
END;
$$;

CREATE FUNCTION app.overdue_action_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'kind', a.kind, 'status', a.status, 'business_date', a.business_date,
        'days_late', a.days_late, 'overdue_amount', a.overdue_amount::text,
        'contract', jsonb_build_object('id', c.id, 'number', c.number, 'frequency', c.frequency,
                                       'branch_id', c.branch_id),
        'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name, 'phone', cu.phones[1],
                                       'status', cu.status),
        'current', jsonb_build_object('overdue_amount', cb.overdue_amount::text,
                                      'max_days_late', cb.max_days_late),
        'outcome', a.outcome, 'note', a.note, 'handled_at', a.handled_at,
        'handled_by_name', e.full_name, 'legal_case_id', a.legal_case_id, 'created_at', a.created_at)
    FROM public.overdue_actions a
    JOIN public.contracts c ON c.id = a.contract_id
    JOIN public.customers cu ON cu.id = a.customer_id
    JOIN public.v_contract_balances cb ON cb.contract_id = a.contract_id
    LEFT JOIN public.employees e ON e.id = a.handled_by
    WHERE a.organization_id = p_org AND a.id = p_id
$$;

-- Overdue contracts, worst first, with totals and aging for the same filters.
CREATE FUNCTION public.list_overdue_contracts(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_q text; v_like text;
    v_branch uuid; v_min integer; v_limit integer := 25; v_cur_days integer; v_cur_id uuid;
    v_items jsonb; v_next text; v_totals jsonb;
BEGIN
    v_org := app.overdue_read_guard();
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('q', 'branch_id', 'min_days', 'limit', 'cursor') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_q := NULLIF(btrim(f ->> 'q'), '');
        v_branch := (f ->> 'branch_id')::uuid;
        v_min := COALESCE((f ->> 'min_days')::integer, 1);
        v_limit := COALESCE((f ->> 'limit')::integer, 25);
        IF f ->> 'cursor' IS NOT NULL THEN
            v_cur_days := split_part(f ->> 'cursor', '|', 1)::integer;
            v_cur_id := split_part(f ->> 'cursor', '|', 2)::uuid;
        END IF;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_limit NOT BETWEEN 1 AND 100 OR v_min NOT BETWEEN 1 AND 100000 OR length(v_q) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

    WITH base AS (
        SELECT c.id AS contract_id, c.number, c.frequency::text AS frequency, c.branch_id, cu.id AS customer_id,
               cu.full_name, cu.phones[1] AS phone, cu.status::text AS customer_status, cb.overdue_amount,
               cb.overdue_lines, cb.max_days_late, cb.remaining
        FROM public.contracts c
        JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
        JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
        WHERE c.organization_id = v_org AND c.status IN ('active', 'rescheduled') AND cb.overdue_amount > 0
          AND cb.max_days_late >= v_min
          AND (v_branch IS NULL OR c.branch_id = v_branch)
          AND (v_q IS NULL OR c.number ILIKE v_like || '%' OR cu.full_name ILIKE '%' || v_like || '%'
               OR EXISTS (SELECT 1 FROM unnest(cu.phones) ph WHERE ph ILIKE '%' || v_like || '%')
               OR cu.national_id = v_q)
    ), totals AS (
        SELECT jsonb_build_object(
            'contracts', count(DISTINCT b.contract_id),
            'overdue_amount', COALESCE(sum(ls.remaining), 0)::numeric(18,2)::text,
            'late_1_30',   COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late BETWEEN 1 AND 30), 0)::numeric(18,2)::text,
            'late_31_60',  COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late BETWEEN 31 AND 60), 0)::numeric(18,2)::text,
            'late_61_90',  COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late BETWEEN 61 AND 90), 0)::numeric(18,2)::text,
            'late_90_plus', COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late > 90), 0)::numeric(18,2)::text) AS t
        FROM base b
        JOIN public.v_schedule_line_status ls ON ls.contract_id = b.contract_id AND ls.status = 'overdue'
    ), page AS (
        SELECT b.*, row_number() OVER (ORDER BY b.max_days_late DESC, b.contract_id) AS n
        FROM base b
        WHERE v_cur_id IS NULL OR b.max_days_late < v_cur_days
              OR (b.max_days_late = v_cur_days AND b.contract_id > v_cur_id)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'contract', jsonb_build_object('id', p.contract_id, 'number', p.number,
                                              'frequency', p.frequency, 'branch_id', p.branch_id),
               'customer', jsonb_build_object('id', p.customer_id, 'name', p.full_name, 'phone', p.phone,
                                              'status', p.customer_status),
               'overdue_amount', p.overdue_amount::text, 'overdue_lines', p.overdue_lines,
               'max_days_late', p.max_days_late, 'remaining', p.remaining::text,
               'oldest_due_date', (SELECT min(ls.due_date) FROM public.v_schedule_line_status ls
                                   WHERE ls.contract_id = p.contract_id AND ls.status = 'overdue'),
               'last_payment_at', (SELECT max(ea.paid_at) FROM public.v_effective_allocations ea
                                   WHERE ea.contract_id = p.contract_id AND ea.direction = 'in'),
               'open_warning', (SELECT jsonb_build_object('id', a.id, 'business_date', a.business_date)
                                FROM public.overdue_actions a
                                WHERE a.contract_id = p.contract_id AND a.kind = 'warning' AND a.status = 'open'
                                ORDER BY a.business_date DESC LIMIT 1),
               'legal_referral', (SELECT jsonb_build_object('id', a.id, 'status', a.status,
                                                           'business_date', a.business_date)
                                  FROM public.overdue_actions a
                                  WHERE a.contract_id = p.contract_id AND a.kind = 'legal_referral'
                                    AND a.status IN ('open', 'case_opened')
                                  ORDER BY a.business_date DESC LIMIT 1))
               ORDER BY p.max_days_late DESC, p.contract_id) FILTER (WHERE p.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN p.n = v_limit THEN p.max_days_late::text || '|' || p.contract_id::text END) END,
           (SELECT t FROM totals)
    INTO v_items, v_next, v_totals
    FROM page p;
    RETURN jsonb_build_object('items', v_items, 'next_cursor', v_next, 'totals', v_totals);
END;
$$;

-- Warnings and legal referrals share one list function: open ones oldest first, the rest newest first.
CREATE FUNCTION app.list_overdue_actions(p_kind public.overdue_action_kind, p_filters jsonb, p_statuses text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_status text; v_branch uuid;
    v_limit integer := 25; v_cur_date date; v_cur_id uuid; v_asc boolean; v_items jsonb; v_next text;
BEGIN
    v_org := app.overdue_read_guard();
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('status', 'branch_id', 'limit', 'cursor') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_status := COALESCE(f ->> 'status', 'open');
        v_branch := (f ->> 'branch_id')::uuid;
        v_limit := COALESCE((f ->> 'limit')::integer, 25);
        IF f ->> 'cursor' IS NOT NULL THEN
            v_cur_date := split_part(f ->> 'cursor', '|', 1)::date;
            v_cur_id := split_part(f ->> 'cursor', '|', 2)::uuid;
        END IF;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_limit NOT BETWEEN 1 AND 100 OR v_status <> ALL (p_statuses) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    v_asc := v_status = 'open';

    WITH page AS (
        SELECT a.id, a.business_date,
               row_number() OVER (ORDER BY CASE WHEN v_asc THEN a.business_date END,
                                           CASE WHEN NOT v_asc THEN a.business_date END DESC, a.id) AS n
        FROM public.overdue_actions a
        WHERE a.organization_id = v_org AND a.kind = p_kind
          AND (v_status = 'all' OR a.status::text = v_status)
          AND (v_branch IS NULL OR a.branch_id = v_branch)
          AND (v_cur_id IS NULL
               OR (v_asc AND (a.business_date > v_cur_date OR (a.business_date = v_cur_date AND a.id > v_cur_id)))
               OR (NOT v_asc AND (a.business_date < v_cur_date OR (a.business_date = v_cur_date AND a.id > v_cur_id))))
    )
    SELECT COALESCE(jsonb_agg(app.overdue_action_json(v_org, p.id) ORDER BY p.n) FILTER (WHERE p.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN p.n = v_limit THEN p.business_date::text || '|' || p.id::text END) END
    INTO v_items, v_next
    FROM (SELECT * FROM page WHERE n <= v_limit + 1) p;
    RETURN jsonb_build_object('items', v_items, 'next_cursor', v_next);
END;
$$;

CREATE FUNCTION public.list_overdue_warnings(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.list_overdue_actions('warning', p_filters, ARRAY['open', 'handled', 'all'])
$$;

CREATE FUNCTION public.list_legal_referrals(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.list_overdue_actions('legal_referral', p_filters, ARRAY['open', 'dismissed', 'case_opened', 'all'])
$$;

-- 7. Writes ---------------------------------------------------------------------------------------------

CREATE FUNCTION public.handle_overdue_warning(p_id uuid, p_outcome text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.overdue_actions; v_note text;
BEGIN
    v_emp := app.require_permission('overdue.handle');
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    v_note := NULLIF(btrim(p_note), '');
    IF p_outcome IS NULL OR p_outcome NOT IN ('contacted', 'promised', 'no_answer', 'wrong_number', 'other') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: outcome' USING ERRCODE = 'P0001';
    END IF;
    IF length(v_note) > 500 OR (p_outcome = 'other' AND COALESCE(length(v_note), 0) < 3) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_a FROM public.overdue_actions a
    WHERE a.id = p_id AND a.organization_id = v_org AND a.kind = 'warning' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERDUE_ACTION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_a.status <> 'open' THEN
        RAISE EXCEPTION 'OVERDUE_ACTION_NOT_OPEN: %', v_a.status USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('status', v_a.status)::text;
    END IF;
    UPDATE public.overdue_actions SET status = 'handled', outcome = p_outcome, note = v_note,
        handled_by = v_emp, handled_at = now()
    WHERE id = p_id;
    PERFORM app.write_audit('overdue.warning_handled', 'contract', v_a.contract_id,
        p_after => jsonb_build_object('warning_id', p_id, 'outcome', p_outcome),
        p_reason => v_note, p_branch_id => v_a.branch_id);
    RETURN app.overdue_action_json(v_org, p_id);
END;
$$;

CREATE FUNCTION public.dismiss_legal_referral(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.overdue_actions; v_reason text;
BEGIN
    v_emp := app.require_permission('overdue.view');
    PERFORM app.require_module('installments');
    IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: owner' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    v_reason := NULLIF(btrim(p_reason), '');
    IF COALESCE(length(v_reason), 0) NOT BETWEEN 3 AND 300 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_a FROM public.overdue_actions a
    WHERE a.id = p_id AND a.organization_id = v_org AND a.kind = 'legal_referral' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERDUE_ACTION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_a.status <> 'open' THEN
        RAISE EXCEPTION 'OVERDUE_ACTION_NOT_OPEN: %', v_a.status USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('status', v_a.status)::text;
    END IF;
    UPDATE public.overdue_actions SET status = 'dismissed', note = v_reason, handled_by = v_emp, handled_at = now()
    WHERE id = p_id;
    PERFORM app.write_audit('contract.legal_referral_dismissed', 'contract', v_a.contract_id,
        p_after => jsonb_build_object('referral_id', p_id), p_reason => v_reason, p_branch_id => v_a.branch_id);
    RETURN app.overdue_action_json(v_org, p_id);
END;
$$;

-- 8. Grants ---------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.refuse_charges(), app.overdue_run(uuid), app.overdue_read_guard(),
    app.overdue_action_json(uuid, uuid), app.list_overdue_actions(public.overdue_action_kind, jsonb, text[])
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.jobs_overdue_run(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.jobs_overdue_run(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.publish_installment_policy(jsonb), public.run_overdue_check(),
    public.list_overdue_contracts(jsonb), public.list_overdue_warnings(jsonb), public.list_legal_referrals(jsonb),
    public.handle_overdue_warning(uuid, text, text), public.dismiss_legal_referral(uuid, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_installment_policy(jsonb), public.run_overdue_check(),
    public.list_overdue_contracts(jsonb), public.list_overdue_warnings(jsonb), public.list_legal_referrals(jsonb),
    public.handle_overdue_warning(uuid, text, text), public.dismiss_legal_referral(uuid, text)
    TO authenticated;
