-- =============================================================================
-- D01 · Owner dashboard (EC-93, D87)
--
-- One read, public.get_owner_dashboard(p_branch_id), answers how the business is doing today for all
-- the caller's branches or one branch. Every tile is computed by the same definition as the page it
-- links to, so the two cannot drift (docs/tasks/D01.md decisions 1-4):
--
--   tile              definition                                        detail it must equal
--   ----------------  ------------------------------------------------  ---------------------------------------
--   sales_today       app.dashboard_sales: today's sales, voided left   search_sales(from = to = today), pages
--                     out (S07 status rule); paid by method and         summed, status <> 'voided'; K04's
--                     on_contract as K04 (D84 decision 2)               paid_by_method / on_contract
--   collections_today app.dashboard_collections: K04's collections      get_day_close_preview(branch, today)
--                     (count, total, in_field) over the branches        .totals.collections, summed
--   cash              app.dashboard_cash: safes / banks (K01 visible    list_cash_accounts('active') by kind,
--                     active accounts), drawers (K02 expected cash of   list_shifts('open') expected cash,
--                     open shifts), wallets (N06 balances)              list_collector_wallets balances
--   open_shifts       app.dashboard_shifts: open shifts of the branches list_shifts(status => 'open').total
--   overdue           list_overdue_contracts(...).totals (the object)   list_overdue_contracts(...).totals
--   low_stock         low_stock_summary: total, or the branch's low     low_stock_summary
--   eta               app.fiscal_alert_counts (extracted from           fiscal_alert_summary
--                     fiscal_alert_summary, same answer)
--   unclosed_days     day_close_alerts().branches[].unclosed_days       day_close_alerts
--   approvals         pending discount / purchase / credit rows         list_discount_approvals,
--                                                                       list_purchase_approvals,
--                                                                       list_credit_exceptions ('pending')
--
-- A tile is null when the caller lacks the key its detail page needs (decision 3). The read needs only
-- a signed-in employee and also works in an expired shop. No table, no enum value, no permission key.
-- "Today" is the shop's date (app.org_today), never the browser's. Contracts 0.57.0, 1 route.
-- =============================================================================

-- 1. Helpers (schema app, nothing granted) -------------------------------------------------------------

-- The branches a dashboard covers: the given one (it must belong to the shop and be visible), else every
-- active branch the caller can see (an owner: all active branches). Inactive branches are left out of "all".
CREATE FUNCTION app.dashboard_branches(p_org uuid, p_branch_id uuid)
RETURNS uuid[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_out uuid[];
BEGIN
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = p_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED: %', p_branch_id USING ERRCODE = '42501';
        END IF;
        RETURN ARRAY[p_branch_id];
    END IF;
    SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_out
    FROM public.branches b
    WHERE b.organization_id = p_org AND b.is_active AND app.has_branch_access(b.id);
    RETURN v_out;
END;
$$;

-- sales_today: the sales dated p_date in the branches, voided ones left out (a sale with a 'void' return
-- is voided, as search_sales). count / total = search_sales summed over its pages without 'voided'.
-- paid_by_method and on_contract use K04's definitions (app.day_close_compute) for the same sales.
CREATE FUNCTION app.dashboard_sales(p_org uuid, p_branches uuid[], p_date date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH s AS (
        SELECT x.id, x.total FROM public.sales x
        WHERE x.organization_id = p_org AND x.branch_id = ANY (p_branches) AND x.business_date = p_date
          AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id = x.id AND r.kind = 'void')
    ), paid AS (
        SELECT p.method, sum(a.amount) AS amount
        FROM s
        JOIN public.payment_allocations a ON a.organization_id = p_org AND a.sale_id = s.id
        JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = p_org AND p.direction = 'in'
        GROUP BY p.method
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM s),
        'total', app.dc_money((SELECT sum(total) FROM s)),
        'paid_by_method', jsonb_build_object(
            'cash', app.dc_money((SELECT amount FROM paid WHERE method = 'cash')),
            'bank_transfer', app.dc_money((SELECT amount FROM paid WHERE method = 'bank_transfer')),
            'store_credit', app.dc_money((SELECT amount FROM paid WHERE method = 'store_credit'))),
        'on_contract', app.dc_money((SELECT sum(c.financed_amount) FROM public.contracts c
                                     JOIN s ON s.id = c.sale_id WHERE c.organization_id = p_org)))
$$;

-- collections_today: K04's collections of the day (N03 at the counter, N06 in the field), gross: a
-- collection = its receipt row (collection_id = id) and the other method rows that share its
-- collection_id; reversals stay on the day close. Same rows as app.day_close_compute, over the branches.
CREATE FUNCTION app.dashboard_collections(p_org uuid, p_branches uuid[], p_date date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH rows AS (
        SELECT p.id, p.collection_id, p.amount, p.cash_account_id FROM public.payments p
        WHERE p.organization_id = p_org AND p.branch_id = ANY (p_branches) AND p.business_date = p_date
          AND p.collection_id IS NOT NULL AND p.direction = 'in'
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM rows WHERE rows.collection_id = rows.id),
        'total', app.dc_money((SELECT sum(amount) FROM rows)),
        'in_field', app.dc_money((SELECT sum(rows.amount) FROM rows
                                  JOIN public.cash_accounts ca ON ca.id = rows.cash_account_id
                                  WHERE ca.kind = 'collector_wallet')))
$$;

-- cash: safes and banks = K01's visible active accounts (a shop-wide bank only when no branch filter was
-- given), drawers = K02's expected cash of the open shifts, wallets = N06's active collector wallets.
-- total_in_branches = safes + drawers + wallets (banks apart, K04's total_closing_cash idea).
CREATE FUNCTION app.dashboard_cash(p_org uuid, p_branches uuid[], p_branch_filtered boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_safes numeric; v_banks numeric; v_drawers numeric; v_wallets numeric;
BEGIN
    SELECT COALESCE(sum(cb.balance) FILTER (WHERE a.kind = 'safe'), 0),
           COALESCE(sum(cb.balance) FILTER (WHERE a.kind = 'bank'), 0)
    INTO v_safes, v_banks
    FROM public.cash_accounts a
    LEFT JOIN public.cash_balances cb ON cb.cash_account_id = a.id
    WHERE a.organization_id = p_org AND app.cash_account_visible(a) AND a.is_active
      AND (a.branch_id = ANY (p_branches) OR (a.branch_id IS NULL AND NOT p_branch_filtered));

    SELECT COALESCE(sum(app.shift_expected(p_org, s)), 0) INTO v_drawers
    FROM public.shifts s
    WHERE s.organization_id = p_org AND s.branch_id = ANY (p_branches) AND s.status = 'open';

    v_wallets := 0;
    IF app.org_has_module(p_org, 'installments') THEN
        SELECT COALESCE(sum(app.wallet_balance(p_org, a.id)), 0) INTO v_wallets
        FROM public.cash_accounts a
        WHERE a.organization_id = p_org AND a.kind = 'collector_wallet' AND a.is_active
          AND a.branch_id = ANY (p_branches) AND app.has_branch_access(a.branch_id);
    END IF;

    RETURN jsonb_build_object(
        'safes', app.dc_money(v_safes), 'banks', app.dc_money(v_banks),
        'drawers', app.dc_money(v_drawers), 'wallets', app.dc_money(v_wallets),
        'total_in_branches', app.dc_money(v_safes + v_drawers + v_wallets));
END;
$$;

-- open_shifts: the open shifts of the branches (K02's list_shifts(status => 'open'): a caller with
-- cash.view sees every shift of their branches, a cashier only their own, p_only_employee).
-- from_earlier_days = opened before p_date in the shop's time zone (they block K04's close).
CREATE FUNCTION app.dashboard_shifts(p_org uuid, p_branches uuid[], p_date date, p_only_employee uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'count', count(*),
        'oldest_opened_at', min(s.opened_at),
        'from_earlier_days', count(*) FILTER (WHERE (s.opened_at AT TIME ZONE o.timezone)::date < p_date))
    FROM public.shifts s
    JOIN public.organizations o ON o.id = s.organization_id
    WHERE s.organization_id = p_org AND s.branch_id = ANY (p_branches) AND s.status = 'open'
      AND (p_only_employee IS NULL OR s.employee_id = p_only_employee)
$$;

-- overdue.customers: the distinct customers of the contracts list_overdue_contracts counts (N04 / N06:
-- active or rescheduled, overdue amount above 0, at least 1 day late; a collector without
-- collector.settle sees only their own customers). p_branches NULL = every branch of the shop.
CREATE FUNCTION app.dashboard_overdue_customers(p_org uuid, p_branches uuid[])
RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_collector uuid;
BEGIN
    IF app.has_permission('collection.create') AND NOT app.has_permission('collector.settle') THEN
        v_collector := app.current_employee_id();
    END IF;
    RETURN (SELECT count(DISTINCT cu.id)
            FROM public.contracts c
            JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
            JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
            WHERE c.organization_id = p_org AND c.status IN ('active', 'rescheduled') AND cb.overdue_amount > 0
              AND cb.max_days_late >= 1
              AND (p_branches IS NULL OR c.branch_id = ANY (p_branches))
              AND (v_collector IS NULL OR cu.collector_id = v_collector));
END;
$$;

-- The overdue tile: list_overdue_contracts' own totals. One branch, or a caller who sees every branch of
-- the shop, is a single call (the same object); a caller who sees only some branches gets the sum of
-- one call per branch (contracts and amount add up, each contract has one branch).
CREATE FUNCTION app.dashboard_overdue(p_org uuid, p_branches uuid[], p_branch_filtered boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_all_branches boolean; v_t jsonb; v_contracts bigint := 0; v_amount numeric := 0; v_b uuid;
    v_customers bigint;
BEGIN
    v_all_branches := NOT p_branch_filtered
        AND cardinality(p_branches) = (SELECT count(*) FROM public.branches b WHERE b.organization_id = p_org);
    IF p_branch_filtered THEN
        v_t := public.list_overdue_contracts(jsonb_build_object('branch_id', p_branches[1], 'limit', 1)) -> 'totals';
        v_contracts := (v_t ->> 'contracts')::bigint;
        v_amount := (v_t ->> 'overdue_amount')::numeric;
        v_customers := app.dashboard_overdue_customers(p_org, p_branches);
    ELSIF v_all_branches THEN
        v_t := public.list_overdue_contracts(jsonb_build_object('limit', 1)) -> 'totals';
        v_contracts := (v_t ->> 'contracts')::bigint;
        v_amount := (v_t ->> 'overdue_amount')::numeric;
        v_customers := app.dashboard_overdue_customers(p_org, NULL);
    ELSE
        FOREACH v_b IN ARRAY p_branches LOOP
            v_t := public.list_overdue_contracts(jsonb_build_object('branch_id', v_b, 'limit', 1)) -> 'totals';
            v_contracts := v_contracts + (v_t ->> 'contracts')::bigint;
            v_amount := v_amount + (v_t ->> 'overdue_amount')::numeric;
        END LOOP;
        v_customers := app.dashboard_overdue_customers(p_org, p_branches);
    END IF;
    RETURN jsonb_build_object('contracts', v_contracts, 'amount', app.dc_money(v_amount), 'customers', v_customers);
END;
$$;

-- ETA counts of fiscal_alert_summary, extracted so the dashboard can filter by branch. Same rows, same
-- answer; fiscal_alert_summary below calls it with the caller's branches.
CREATE FUNCTION app.fiscal_alert_counts(p_org uuid, p_branch_ids uuid[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
               'blocked', count(*) FILTER (WHERE x.situation = 'blocked'),
               'send_failed', count(*) FILTER (WHERE x.situation = 'send_failed'),
               'rejected', count(*) FILTER (WHERE x.situation = 'rejected'),
               'due_soon', count(*) FILTER (WHERE x.state = 'due_soon'),
               'overdue', count(*) FILTER (WHERE x.state = 'overdue'),
               'accepted_today', count(*) FILTER (WHERE x.status = 'accepted' AND x.accepted_date = x.today))
    FROM (
        SELECT f.status, app.fiscal_situation(f.status, f.eta_uuid, f.last_error) AS situation,
               app.fiscal_deadline_state(app.fiscal_deadline_at(f.status,
                   COALESCE(s.issued_at, r.created_at, f.created_at), f.reference_old_uuid)) AS state,
               (f.accepted_at AT TIME ZONE o.timezone)::date AS accepted_date,
               (now() AT TIME ZONE o.timezone)::date AS today
        FROM public.fiscal_submissions f
        JOIN public.organizations o ON o.id = f.organization_id
        LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        LEFT JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
        WHERE f.organization_id = p_org AND f.branch_id = ANY (p_branch_ids)
    ) x
$$;

-- fiscal_alert_summary (T03): the same answer as before, now through app.fiscal_alert_counts.
CREATE OR REPLACE FUNCTION public.fiscal_alert_summary()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[];
BEGIN
    PERFORM app.require_fiscal_view();
    v_org := app.current_org_id();
    SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
    FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    RETURN app.fiscal_alert_counts(v_org, v_branches);
END;
$$;

-- 2. The read ----------------------------------------------------------------------------------------------

CREATE FUNCTION public.get_owner_dashboard(p_branch_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; v_emp uuid; v_today date; v_branches uuid[]; v_filtered boolean := p_branch_id IS NOT NULL;
    v_can_cash boolean; v_can_day boolean; v_has_inst boolean;
    v_sales jsonb; v_coll jsonb; v_cash jsonb; v_shifts jsonb; v_overdue jsonb; v_low jsonb; v_eta jsonb;
    v_unclosed jsonb; v_approvals jsonb;
    v_disc integer; v_purch integer; v_credit integer; v_c jsonb;
BEGIN
    v_org := app.current_org_id();
    v_emp := app.current_employee_id();
    IF v_org IS NULL OR v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    v_today := app.org_today(v_org);
    v_branches := app.dashboard_branches(v_org, p_branch_id);
    v_can_cash := app.has_permission('cash.view');
    v_can_day := v_can_cash OR app.has_permission('day.close');
    v_has_inst := app.org_has_module(v_org, 'installments');

    IF app.has_permission('report.view') OR app.has_permission('sale.create') THEN
        v_sales := app.dashboard_sales(v_org, v_branches, v_today);
    END IF;

    IF v_can_day THEN
        v_coll := app.dashboard_collections(v_org, v_branches, v_today);
        -- Days not closed: day_close_alerts' own list (last 14 days, today left out), for these branches.
        SELECT jsonb_build_object(
                   'days', COALESCE(sum(jsonb_array_length(x -> 'unclosed_days')), 0),
                   'branches', count(*) FILTER (WHERE jsonb_array_length(x -> 'unclosed_days') > 0))
        INTO v_unclosed
        FROM jsonb_array_elements(public.day_close_alerts() -> 'branches') x
        WHERE (x ->> 'branch_id')::uuid = ANY (v_branches);
    END IF;

    IF v_can_cash THEN
        v_cash := app.dashboard_cash(v_org, v_branches, v_filtered);
    END IF;

    IF v_can_cash OR app.has_permission('shift.operate') THEN
        v_shifts := app.dashboard_shifts(v_org, v_branches, v_today, CASE WHEN v_can_cash THEN NULL ELSE v_emp END);
    END IF;

    IF v_has_inst AND app.has_permission('overdue.view') THEN
        v_overdue := app.dashboard_overdue(v_org, v_branches, v_filtered);
    END IF;

    IF app.has_permission('stock.view') THEN
        v_c := public.low_stock_summary(1);
        v_low := jsonb_build_object('products', CASE
            WHEN v_filtered THEN COALESCE((SELECT (x ->> 'low')::bigint FROM jsonb_array_elements(v_c -> 'branches') x
                                           WHERE (x ->> 'branch_id')::uuid = p_branch_id), 0)
            ELSE (v_c ->> 'total')::bigint END);
    END IF;

    IF app.has_permission('fiscal.view') AND app.org_has_module(v_org, 'eta') THEN
        v_c := app.fiscal_alert_counts(v_org, v_branches);
        v_eta := jsonb_build_object(
            'needs_action', (v_c ->> 'blocked')::bigint + (v_c ->> 'send_failed')::bigint + (v_c ->> 'rejected')::bigint
                            + (v_c ->> 'due_soon')::bigint + (v_c ->> 'overdue')::bigint,
            'blocked', (v_c ->> 'blocked')::bigint, 'send_failed', (v_c ->> 'send_failed')::bigint,
            'rejected', (v_c ->> 'rejected')::bigint, 'due_soon', (v_c ->> 'due_soon')::bigint,
            'overdue', (v_c ->> 'overdue')::bigint);
    END IF;

    -- Approvals waiting = the rows of S03's, U06's and R03's pending lists, counted (the lists stop at a
    -- page). S03's discount list and R03's credit list have no branch filter (every visible branch / the
    -- whole shop, whatever branch the dashboard shows); U06's purchase list has one (the dashboard's).
    IF app.has_permission('discount.above_cap') THEN
        SELECT count(*)::integer INTO v_disc FROM public.approvals a
        WHERE a.organization_id = v_org AND a.kind = 'discount_above_cap' AND a.status = 'pending'
          AND app.has_branch_access(a.branch_id);
    END IF;
    IF app.has_permission('purchase.invoice_approve') THEN
        SELECT count(*)::integer INTO v_purch FROM public.approvals a
        WHERE a.organization_id = v_org AND a.kind = 'purchase_invoice' AND a.status = 'pending'
          AND a.branch_id = ANY (v_branches);
    END IF;
    IF app.has_permission('credit.approve') AND app.org_has_module(v_org, 'customers') THEN
        SELECT count(*)::integer INTO v_credit FROM public.approvals a
        WHERE a.organization_id = v_org AND a.kind = 'credit_exception' AND a.status = 'pending';
    END IF;
    IF v_disc IS NOT NULL OR v_purch IS NOT NULL OR v_credit IS NOT NULL THEN
        v_approvals := jsonb_build_object('discount', v_disc, 'purchase', v_purch, 'credit', v_credit,
                                          'total', COALESCE(v_disc, 0) + COALESCE(v_purch, 0) + COALESCE(v_credit, 0));
    END IF;

    RETURN jsonb_build_object(
        'business_date', v_today, 'branch_id', p_branch_id, 'generated_at', now(),
        'tiles', jsonb_build_object(
            'sales_today', v_sales, 'collections_today', v_coll, 'cash', v_cash, 'open_shifts', v_shifts,
            'overdue', v_overdue, 'low_stock', v_low, 'eta', v_eta, 'unclosed_days', v_unclosed,
            'approvals', v_approvals));
END;
$$;

-- 3. Grants: the public read to signed-in users, nothing for the app. helpers ---------------------------

REVOKE ALL ON FUNCTION public.get_owner_dashboard(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_owner_dashboard(uuid) TO authenticated;
REVOKE ALL ON FUNCTION
    app.dashboard_branches(uuid, uuid), app.dashboard_sales(uuid, uuid[], date),
    app.dashboard_collections(uuid, uuid[], date), app.dashboard_cash(uuid, uuid[], boolean),
    app.dashboard_shifts(uuid, uuid[], date, uuid), app.dashboard_overdue_customers(uuid, uuid[]),
    app.dashboard_overdue(uuid, uuid[], boolean), app.fiscal_alert_counts(uuid, uuid[])
    FROM PUBLIC, anon, authenticated;
