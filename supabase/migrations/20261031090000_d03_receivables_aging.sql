-- =============================================================================
-- D03 · Receivables aging (EC-95, D90)
--
-- One read, public.report_receivables(...), answers who owes the shop money today and how late they are,
-- grouped by customer, branch, collector or contract (docs/tasks/D03.md decisions 1-10). Every number is a
-- SQL aggregate; the API and the browser never add money up.
--
--   counted lines  every current (not superseded) schedule line of every open contract (active or
--                  rescheduled) in the branches the caller can see, with something left on it; closed
--                  contracts (completed, written off, returned) are out (owner answer 5)
--   buckets        N04's own rule (owner answer 1): a line is late only after its due date plus the grace
--                  days of the contract's policy version; its days late count from the due date. not_due =
--                  not yet due, due today or inside grace; late_1_30 .. late_90_plus = overdue by days late.
--                  Exactly v_receivables_aging's columns and list_overdue_contracts' totals.
--   principal      principal - paid principal per line; profit = profit - paid profit (N03 pays profit first)
--   no fees        rule 4: there are none; fees_due is not read
--   totals / check totals are summed per contract (every open contract in scope once, whatever row it is in);
--                  check = the rows of all pages minus the totals (must be 0), principal + profit and the
--                  buckets add up to the outstanding, and no open contract lacks a current schedule line
--
-- The counted lines are the baseline's v_schedule_line_status definition (N04's replacement) inlined for the
-- open contracts in scope only. Through the view (or v_contract_balances / v_receivables_aging, built on it) the
-- paid amounts of every allocation of every shop are added up first (the function runs as its owner, so RLS
-- doesn't narrow it): the time would grow with the whole database, not with the shop. So the totals don't read
-- those views at run time either; the SQL test proves, contract by contract, that the report equals
-- v_contract_balances and v_receivables_aging (D90).
-- The read needs a signed-in employee with report.financial (owner answer 3) and also works in an expired
-- shop (app.has_permission, as D01 and D02). As of the shop's today (owner answer 2). The branch of a balance
-- is the contract's selling branch (owner answer 6); the collector is the customer's current one (answer 4).
-- No table, no view change, no enum value, no permission key. Contracts 0.60.0, 1 route.
-- =============================================================================

-- 1. The measures of one row or of the totals, in the contract's shape (schema app, nothing granted) ---------

CREATE FUNCTION app.receivables_measures(
    p_outstanding numeric, p_principal numeric, p_profit numeric,
    p_not_due numeric, p_l30 numeric, p_l60 numeric, p_l90 numeric, p_l90p numeric,
    p_contracts bigint, p_customers bigint, p_overdue_contracts bigint, p_max_days_late integer,
    p_oldest_due_date date, p_migrated bigint)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'outstanding', app.report_money(p_outstanding),
        'principal', app.report_money(p_principal), 'profit', app.report_money(p_profit),
        'not_due', app.report_money(p_not_due), 'late_1_30', app.report_money(p_l30),
        'late_31_60', app.report_money(p_l60), 'late_61_90', app.report_money(p_l90),
        'late_90_plus', app.report_money(p_l90p),
        'overdue', app.report_money(p_l30 + p_l60 + p_l90 + p_l90p),
        'overdue_pct', CASE WHEN p_outstanding <> 0
                            THEN round((p_l30 + p_l60 + p_l90 + p_l90p) / p_outstanding * 100, 1)::text END,
        'contracts', p_contracts, 'customers', p_customers, 'overdue_contracts', p_overdue_contracts,
        'max_days_late', p_max_days_late, 'oldest_due_date', p_oldest_due_date, 'migrated_contracts', p_migrated)
$$;

-- 2. The read ------------------------------------------------------------------------------------------------

CREATE FUNCTION public.report_receivables(
    p_group_by text, p_branch_id uuid DEFAULT NULL, p_collector_id text DEFAULT NULL,
    p_customer_id uuid DEFAULT NULL, p_q text DEFAULT NULL, p_min_days integer DEFAULT NULL,
    p_sort text DEFAULT NULL, p_page integer DEFAULT 1, p_page_size integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' SET plan_cache_mode = force_custom_plan
AS $$
-- force_custom_plan: as report_sales (D89), a generic plan knows neither the branches nor the contracts.
DECLARE
    v_org uuid; v_emp uuid; v_today date; v_branches uuid[]; v_sort text; v_q text; v_like text;
    v_collector uuid; v_no_collector boolean := false; v_contracts uuid[]; v_off integer; v_out jsonb;
BEGIN
    v_org := app.current_org_id();
    v_emp := app.current_employee_id();
    IF v_org IS NULL OR v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('report.financial') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: report.financial' USING ERRCODE = '42501';
    END IF;

    IF p_group_by IS NULL OR p_group_by NOT IN ('customer', 'branch', 'collector', 'contract') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: group_by' USING ERRCODE = 'P0001';
    END IF;
    v_q := NULLIF(btrim(p_q), '');
    IF v_q IS NOT NULL AND (p_group_by NOT IN ('customer', 'contract') OR length(v_q) > 100) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: q' USING ERRCODE = 'P0001';
    END IF;
    IF p_min_days IS NOT NULL AND p_min_days NOT BETWEEN 1 AND 100000 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: min_days' USING ERRCODE = 'P0001';
    END IF;
    IF p_page IS NULL OR p_page < 1 OR p_page_size IS NULL OR p_page_size < 1 OR p_page_size > 1000 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: page' USING ERRCODE = 'P0001';
    END IF;
    v_sort := COALESCE(p_sort, 'outstanding_desc');
    IF v_sort NOT IN ('outstanding_desc', 'outstanding_asc', 'overdue_desc', 'late_90_plus_desc',
                      'max_days_late_desc', 'key_asc') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: sort' USING ERRCODE = 'P0001';
    END IF;

    -- Branch scope (D02's rule): a given branch must be the shop's and visible; else every branch the caller
    -- can see, inactive ones included (their contracts are still owed).
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED: %', p_branch_id USING ERRCODE = '42501';
        END IF;
        v_branches := ARRAY[p_branch_id];
    ELSE
        SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
        FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    END IF;
    IF p_collector_id IS NOT NULL THEN
        IF p_collector_id = 'none' THEN
            v_no_collector := true;
        ELSE
            BEGIN
                v_collector := p_collector_id::uuid;
            EXCEPTION WHEN data_exception THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: collector_id' USING ERRCODE = 'P0001';
            END;
            IF NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = v_collector AND e.organization_id = v_org) THEN
                RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
        END IF;
    END IF;
    IF p_customer_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM public.customers c WHERE c.id = p_customer_id AND c.organization_id = v_org) THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    SELECT (now() AT TIME ZONE o.timezone)::date INTO v_today FROM public.organizations o WHERE o.id = v_org;
    v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
    v_off := (p_page - 1) * p_page_size;

    -- The open contracts in scope (decisions 3 and 7); min_days narrows them below (the overdue list's min_days:
    -- a current line overdue at least that many days).
    SELECT COALESCE(array_agg(c.id), ARRAY[]::uuid[]) INTO v_contracts
    FROM public.contracts c
    JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
    WHERE c.organization_id = v_org AND c.status IN ('active', 'rescheduled') AND c.branch_id = ANY (v_branches)
      AND (p_customer_id IS NULL OR c.customer_id = p_customer_id)
      AND (v_collector IS NULL OR cu.collector_id = v_collector)
      AND (NOT v_no_collector OR cu.collector_id IS NULL)
      AND (v_q IS NULL OR c.number ILIKE v_like || '%' OR cu.full_name ILIKE '%' || v_like || '%'
           OR EXISTS (SELECT 1 FROM unnest(cu.phones) ph WHERE ph ILIKE '%' || v_like || '%')
           OR cu.national_id = v_q);
    IF p_min_days IS NOT NULL THEN
        -- Only the contracts with a current line overdue at least that many days with something left on it (one
        -- pass over their lines and payments, as below; a per-line sum took minutes on a large shop).
        SELECT COALESCE(array_agg(DISTINCT sl.contract_id), ARRAY[]::uuid[]) INTO v_contracts
        FROM public.schedule_lines sl
        JOIN public.contracts c ON c.id = sl.contract_id AND c.organization_id = v_org
        JOIN public.installment_policies ip ON ip.id = c.policy_id
        LEFT JOIN (SELECT ea.schedule_line_id, sum(ea.amount) AS paid
                   FROM public.v_effective_allocations ea
                   WHERE ea.organization_id = v_org AND ea.contract_id = ANY (v_contracts)
                     AND ea.schedule_line_id IS NOT NULL
                   GROUP BY ea.schedule_line_id) p ON p.schedule_line_id = sl.id
        WHERE sl.organization_id = v_org AND sl.contract_id = ANY (v_contracts) AND NOT sl.superseded
          AND sl.due_date + ip.grace_days < v_today AND v_today - sl.due_date >= p_min_days
          AND sl.amount - COALESCE(p.paid, 0) > 0;
    END IF;

    WITH pd AS (
        -- What is paid on each current line of those contracts (the view's `paid`, narrowed to them).
        -- One pass also keeps the latest payment in (the allocations without a line too: the overdue list's rule).
        SELECT ea.contract_id, ea.schedule_line_id, sum(ea.amount) AS paid, sum(ea.principal_amount) AS paid_principal,
               sum(ea.profit_amount) AS paid_profit, max(ea.paid_at) FILTER (WHERE ea.direction = 'in') AS last_in
        FROM public.v_effective_allocations ea
        WHERE ea.organization_id = v_org AND ea.contract_id = ANY (v_contracts)
        GROUP BY ea.contract_id, ea.schedule_line_id
    ), lp AS (
        -- The latest payment in on each contract (as the overdue list shows it).
        SELECT pd.contract_id, max(pd.last_in) AS paid_at FROM pd GROUP BY pd.contract_id
    ), cl AS (
        -- The counted lines with their dimensions and bucket.
        SELECT c.id AS contract_id, c.customer_id, c.branch_id, cu.collector_id, c.is_migrated, sl.due_date,
               lp.paid_at AS last_paid,
               (sl.amount - COALESCE(p.paid, 0)) AS remaining,
               (sl.principal - COALESCE(p.paid_principal, 0)) AS principal,
               (sl.profit - COALESCE(p.paid_profit, 0)) AS profit,
               sl.due_date + ip.grace_days < v_today AS overdue,
               GREATEST(v_today - sl.due_date, 0) AS days_late,
               CASE p_group_by WHEN 'customer' THEN c.customer_id::text WHEN 'branch' THEN c.branch_id::text
                               WHEN 'collector' THEN COALESCE(cu.collector_id::text, 'none')
                               ELSE c.id::text END AS k
        FROM public.contracts c
        JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
        JOIN public.installment_policies ip ON ip.id = c.policy_id
        JOIN public.schedule_lines sl ON sl.contract_id = c.id AND sl.organization_id = v_org AND NOT sl.superseded
        LEFT JOIN pd p ON p.schedule_line_id = sl.id
        LEFT JOIN lp ON lp.contract_id = c.id
        WHERE c.organization_id = v_org AND c.id = ANY (v_contracts) AND sl.amount - COALESCE(p.paid, 0) > 0
    ), cb AS (
        SELECT cl.*,
               CASE WHEN NOT cl.overdue THEN 'not_due' WHEN cl.days_late <= 30 THEN 'l30'
                    WHEN cl.days_late <= 60 THEN 'l60' WHEN cl.days_late <= 90 THEN 'l90' ELSE 'l90p' END AS bucket
        FROM cl
    ), cc AS (
        -- Per contract first (no distinct counts over the lines: sorting every line took most of the time).
        SELECT cb.contract_id, cb.customer_id, cb.k, cb.is_migrated, cb.last_paid,
               sum(cb.remaining) AS outstanding, sum(cb.principal) AS principal, sum(cb.profit) AS profit,
               COALESCE(sum(cb.remaining) FILTER (WHERE cb.bucket = 'not_due'), 0) AS not_due,
               COALESCE(sum(cb.remaining) FILTER (WHERE cb.bucket = 'l30'), 0) AS l30,
               COALESCE(sum(cb.remaining) FILTER (WHERE cb.bucket = 'l60'), 0) AS l60,
               COALESCE(sum(cb.remaining) FILTER (WHERE cb.bucket = 'l90'), 0) AS l90,
               COALESCE(sum(cb.remaining) FILTER (WHERE cb.bucket = 'l90p'), 0) AS l90p,
               bool_or(cb.overdue) AS has_overdue,
               max(cb.days_late) FILTER (WHERE cb.overdue) AS max_days_late,
               min(cb.due_date) AS oldest_due_date
        FROM cb GROUP BY cb.contract_id, cb.customer_id, cb.k, cb.is_migrated, cb.last_paid
    ), ak AS (
        SELECT cc.k,
               sum(cc.outstanding) AS outstanding, sum(cc.principal) AS principal, sum(cc.profit) AS profit,
               sum(cc.not_due) AS not_due, sum(cc.l30) AS l30, sum(cc.l60) AS l60, sum(cc.l90) AS l90,
               sum(cc.l90p) AS l90p,
               count(*) AS contracts, count(DISTINCT cc.customer_id) AS customers,
               count(*) FILTER (WHERE cc.has_overdue) AS overdue_contracts,
               max(cc.max_days_late)::integer AS max_days_late,
               min(cc.oldest_due_date) AS oldest_due_date,
               count(*) FILTER (WHERE cc.is_migrated) AS migrated,
               max(cc.last_paid) AS last_payment_at
        FROM cc GROUP BY cc.k
    ), lab AS (
        SELECT ak.*,
               CASE p_group_by WHEN 'customer' THEN cu.full_name WHEN 'branch' THEN b.name
                               WHEN 'collector' THEN e.full_name ELSE c.number END AS label,
               CASE p_group_by WHEN 'customer' THEN cu.phones[1] WHEN 'branch' THEN b.code
                               WHEN 'contract' THEN ccu.full_name END AS sub_label,
               CASE p_group_by
                   WHEN 'customer' THEN jsonb_build_object(
                       'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name, 'phone', cu.phones[1]),
                       'collector', CASE WHEN cu.collector_id IS NULL THEN NULL
                                         ELSE jsonb_build_object('id', ce.id, 'name', ce.full_name) END)
                   WHEN 'branch' THEN jsonb_build_object('branch', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code))
                   WHEN 'collector' THEN jsonb_build_object(
                       'collector', CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object('id', e.id, 'name', e.full_name) END)
                   ELSE jsonb_build_object(
                       'customer', jsonb_build_object('id', ccu.id, 'name', ccu.full_name, 'phone', ccu.phones[1]),
                       'branch', jsonb_build_object('id', cbr.id, 'name', cbr.name, 'code', cbr.code),
                       'contract', jsonb_build_object('id', c.id, 'number', c.number, 'frequency', c.frequency,
                                                      'is_migrated', c.is_migrated, 'status', c.status,
                                                      'next_due_date', ak.oldest_due_date))
               END AS dims
        FROM ak
        LEFT JOIN public.customers cu ON p_group_by = 'customer' AND cu.organization_id = v_org AND cu.id::text = ak.k
        LEFT JOIN public.employees ce ON p_group_by = 'customer' AND ce.organization_id = v_org AND ce.id = cu.collector_id
        LEFT JOIN public.branches b ON p_group_by = 'branch' AND b.organization_id = v_org AND b.id::text = ak.k
        LEFT JOIN public.employees e ON p_group_by = 'collector' AND e.organization_id = v_org AND e.id::text = ak.k
        LEFT JOIN public.contracts c ON p_group_by = 'contract' AND c.organization_id = v_org AND c.id::text = ak.k
        LEFT JOIN public.customers ccu ON p_group_by = 'contract' AND ccu.organization_id = v_org AND ccu.id = c.customer_id
        LEFT JOIN public.branches cbr ON p_group_by = 'contract' AND cbr.organization_id = v_org AND cbr.id = c.branch_id
    ), srt AS (
        SELECT lab.*, row_number() OVER (ORDER BY
                   CASE v_sort WHEN 'outstanding_desc' THEN lab.outstanding
                               WHEN 'overdue_desc' THEN lab.l30 + lab.l60 + lab.l90 + lab.l90p
                               WHEN 'late_90_plus_desc' THEN lab.l90p
                               WHEN 'max_days_late_desc' THEN COALESCE(lab.max_days_late, 0)::numeric END DESC NULLS LAST,
                   CASE v_sort WHEN 'outstanding_asc' THEN lab.outstanding END ASC NULLS LAST,
                   lab.label NULLS LAST, lab.k) AS rn
        FROM lab
    ), cs AS (
        -- The bucket totals, each split into principal and profit (the slice's "totals of principal and markup").
        SELECT cb.bucket, sum(cb.remaining) AS amount, sum(cb.principal) AS principal, sum(cb.profit) AS profit
        FROM cb GROUP BY cb.bucket
    ), tot AS (
        -- Totals per contract (decision 8, see D90 for why not from the balance views at run time): every open
        -- contract in scope counted once, whatever row it lands in.
        SELECT COALESCE(sum(cc.outstanding), 0) AS outstanding, COALESCE(sum(cc.principal), 0) AS principal,
               COALESCE(sum(cc.profit), 0) AS profit,
               COALESCE(sum(cc.not_due), 0) AS not_due, COALESCE(sum(cc.l30), 0) AS l30, COALESCE(sum(cc.l60), 0) AS l60,
               COALESCE(sum(cc.l90), 0) AS l90, COALESCE(sum(cc.l90p), 0) AS l90p,
               count(*) AS contracts, count(DISTINCT cc.customer_id) AS customers,
               count(*) FILTER (WHERE cc.has_overdue) AS overdue_contracts, max(cc.max_days_late)::integer AS max_days_late,
               min(cc.oldest_due_date) AS oldest_due_date, count(*) FILTER (WHERE cc.is_migrated) AS migrated,
               -- An open contract with no current line can't be aged (R02 has a fallback for it); it should never exist.
               (SELECT count(*) FROM unnest(v_contracts) x(id)
                WHERE NOT EXISTS (SELECT 1 FROM public.schedule_lines s
                                  WHERE s.organization_id = v_org AND s.contract_id = x.id AND NOT s.superseded)) AS no_schedule
        FROM cc
    ), sums AS (
        -- The rows of all pages.
        SELECT COALESCE(sum(ak.outstanding), 0) AS outstanding, COALESCE(sum(ak.principal), 0) AS principal,
               COALESCE(sum(ak.not_due), 0) AS not_due, COALESCE(sum(ak.l30), 0) AS l30,
               COALESCE(sum(ak.l60), 0) AS l60, COALESCE(sum(ak.l90), 0) AS l90, COALESCE(sum(ak.l90p), 0) AS l90p,
               COALESCE(sum(ak.contracts), 0) AS contracts
        FROM ak
    )
    SELECT jsonb_build_object(
        'rows', COALESCE((
            SELECT jsonb_agg(
                       jsonb_build_object('key', srt.k, 'label', srt.label, 'sub_label', srt.sub_label,
                                          'last_payment_at', srt.last_payment_at)
                       || srt.dims
                       || app.receivables_measures(srt.outstanding, srt.principal, srt.profit, srt.not_due, srt.l30,
                                                   srt.l60, srt.l90, srt.l90p, srt.contracts, srt.customers,
                                                   srt.overdue_contracts, srt.max_days_late, srt.oldest_due_date,
                                                   srt.migrated)
                       ORDER BY srt.rn)
            FROM srt WHERE srt.rn > v_off AND srt.rn <= v_off + p_page_size), '[]'::jsonb),
        'total_count', (SELECT count(*) FROM ak),
        'totals', app.receivables_measures(tot.outstanding, tot.principal, tot.profit, tot.not_due, tot.l30, tot.l60,
                                           tot.l90, tot.l90p, tot.contracts, tot.customers, tot.overdue_contracts,
                                           tot.max_days_late, tot.oldest_due_date, tot.migrated)
                  || jsonb_build_object('buckets', (
                         SELECT jsonb_object_agg(v.b, jsonb_build_object(
                                    'amount', app.report_money(COALESCE(s.amount, 0)),
                                    'principal', app.report_money(COALESCE(s.principal, 0)),
                                    'profit', app.report_money(COALESCE(s.profit, 0))))
                         FROM (VALUES ('not_due', 'not_due'), ('late_1_30', 'l30'), ('late_31_60', 'l60'),
                                      ('late_61_90', 'l90'), ('late_90_plus', 'l90p')) v(b, k)
                         LEFT JOIN cs s ON s.bucket = v.k)),
        'check', jsonb_build_object(
            'rows_match', sums.outstanding = tot.outstanding AND sums.principal = tot.principal
                          AND sums.not_due = tot.not_due AND sums.l30 = tot.l30 AND sums.l60 = tot.l60
                          AND sums.l90 = tot.l90 AND sums.l90p = tot.l90p AND sums.contracts = tot.contracts
                          AND tot.principal + tot.profit = tot.outstanding
                          AND tot.not_due + tot.l30 + tot.l60 + tot.l90 + tot.l90p = tot.outstanding
                          AND tot.no_schedule = 0,
            'contracts_checked', tot.contracts,
            'contracts_without_schedule', tot.no_schedule,
            'differences', jsonb_build_object(
                'outstanding', app.report_money(sums.outstanding - tot.outstanding),
                'principal', app.report_money(sums.principal - tot.principal),
                'not_due', app.report_money(sums.not_due - tot.not_due),
                'late_1_30', app.report_money(sums.l30 - tot.l30),
                'late_31_60', app.report_money(sums.l60 - tot.l60),
                'late_61_90', app.report_money(sums.l90 - tot.l90),
                'late_90_plus', app.report_money(sums.l90p - tot.l90p))))
    INTO v_out
    FROM tot, sums;

    RETURN v_out || jsonb_build_object(
        'as_of', v_today, 'generated_at', now(), 'group_by', p_group_by,
        'filters', jsonb_build_object('branch_id', p_branch_id, 'collector_id', p_collector_id,
                                      'customer_id', p_customer_id, 'q', v_q, 'min_days', p_min_days),
        'sort', v_sort, 'page', p_page, 'page_size', p_page_size);
END;
$$;

-- 3. Grants: the public read to signed-in users, nothing for the app. helper --------------------------------

REVOKE ALL ON FUNCTION public.report_receivables(text, uuid, text, uuid, text, integer, text, integer, integer)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.report_receivables(text, uuid, text, uuid, text, integer, text, integer, integer)
    TO authenticated;
REVOKE ALL ON FUNCTION app.receivables_measures(numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric,
                                                bigint, bigint, bigint, integer, date, bigint)
    FROM PUBLIC, anon, authenticated;
