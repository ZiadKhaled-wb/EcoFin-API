-- =============================================================================
-- K04 · Day close and reconciliation (EC-62, D84)
--
-- At the end of a business day a manager closes it per branch. The numbers come from one
-- computation (app.day_close_compute) used by the preview, the close and the nightly job, so what
-- the manager saw, what is stored and what the job checks are the same numbers.
--
-- Rules (docs/tasks/K04.md, D84):
--   1. The baseline already refuses a ledger or document row dated in a closed day
--      (app.check_business_date, DAY_CLOSED) and gives close_day an exclusive day lock
--      (app.lock_day_for_close). K04 inserts / updates the day_closes row under that lock.
--   2. Totals: sales by payment method, voids, returns, collections (principal / profit, in the
--      field, reversed), expenses by category, supplier payments and refunds, every cash account
--      of the branch (opening, in, out, closing, by type), the shifts, the ETA status.
--   3. Issues with a link to their cause: SHIFT_OPEN (blocking), LEDGER_MISMATCH,
--      DOCUMENT_WITHOUT_LEDGER, ETA_NOT_ACCEPTED (warnings: the closer writes a note),
--      SHIFT_DIFFERENCE, WALLET_SHORTAGE, EARLIER_DAY_OPEN (info).
--   4. close_day checks the preview's hash (DAY_CHANGED when something was posted after the manager
--      looked); reopen_day (day.reopen, owner by default) needs a reason; closing again stores a
--      new snapshot. The history is in the audit log.
--   5. The nightly 'day.check' job (jobs_day_check) checks yesterday and the closed days of the last
--      7 days, stores what it found in day_checks and never closes a day.
--
-- Numbers: contracts 0.54.0, 6 routes. One new table (day_checks); no new enum value and no new
-- permission key (day.close and day.reopen are in the baseline).
-- =============================================================================

-- 1. Schema ------------------------------------------------------------------------------------------

-- What the nightly job found for a branch and day (decision 9). One row per day, replaced by the
-- next run. Read through the functions only.
CREATE TABLE public.day_checks (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES public.organizations (id),
    branch_id        uuid NOT NULL,
    business_date    date NOT NULL,
    checked_at       timestamptz NOT NULL DEFAULT now(),
    issues           jsonb NOT NULL DEFAULT '[]'::jsonb,
    drift            boolean NOT NULL DEFAULT false,
    CONSTRAINT day_checks_day_key UNIQUE (organization_id, branch_id, business_date),
    FOREIGN KEY (branch_id, organization_id) REFERENCES public.branches (id, organization_id),
    CHECK (jsonb_typeof(issues) = 'array')
);
ALTER TABLE public.day_checks ENABLE ROW LEVEL SECURITY;
CREATE POLICY day_checks_tenant_read ON public.day_checks
    FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id()));
REVOKE ALL ON public.day_checks FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.day_checks TO service_role;

-- 2. Helpers (schema app, no grants) -----------------------------------------------------------------

CREATE FUNCTION app.dc_money(p numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT COALESCE(p, 0)::numeric(18,2)::text
$$;

CREATE FUNCTION app.dc_issue(p_code text, p_severity text, p_params jsonb, p_kind text, p_id uuid)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'code', p_code, 'severity', p_severity, 'params', COALESCE(p_params, '{}'::jsonb),
        'link', CASE WHEN p_kind IS NULL THEN NULL
                     ELSE jsonb_build_object('kind', p_kind, 'id', p_id) END)
$$;

-- Days of a branch with any activity (documents or ledger rows) in a date range.
CREATE FUNCTION app.day_activity_dates(p_org uuid, p_branch uuid, p_from date, p_to date)
RETURNS TABLE (business_date date) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT m.business_date FROM public.cash_movements m
    WHERE m.organization_id = p_org AND m.branch_id = p_branch AND m.business_date BETWEEN p_from AND p_to
    UNION
    SELECT s.business_date FROM public.sales s
    WHERE s.organization_id = p_org AND s.branch_id = p_branch AND s.business_date BETWEEN p_from AND p_to
    UNION
    SELECT p.business_date FROM public.payments p
    WHERE p.organization_id = p_org AND p.branch_id = p_branch AND p.business_date BETWEEN p_from AND p_to
    UNION
    SELECT sm.business_date FROM public.stock_movements sm
    WHERE sm.organization_id = p_org AND sm.branch_id = p_branch AND sm.business_date BETWEEN p_from AND p_to
$$;

-- The day's numbers and issues for a branch (decisions 1-3). Read only; the caller checks access.
CREATE FUNCTION app.day_close_compute(p_org uuid, p_branch uuid, p_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_tz          text;
    v_sales       jsonb;
    v_returns     jsonb;
    v_collections jsonb;
    v_expenses    jsonb;
    v_suppliers   jsonb;
    v_sup_refunds jsonb;
    v_cash        jsonb;
    v_shifts      jsonb;
    v_eta         jsonb;
    v_issues      jsonb := '[]'::jsonb;
    v_docs        jsonb;
    v_doc_count   integer;
    v_earlier     record;
BEGIN
    SELECT o.timezone INTO v_tz FROM public.organizations o WHERE o.id = p_org;

    -- Sales of the day. Voids are shown on the void's day; the sale stays counted on its own day.
    WITH s AS (
        SELECT * FROM public.sales x
        WHERE x.organization_id = p_org AND x.branch_id = p_branch AND x.business_date = p_date
    ), paid AS (
        SELECT p.method, sum(a.amount) AS amount
        FROM s
        JOIN public.payment_allocations a ON a.organization_id = p_org AND a.sale_id = s.id
        JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = p_org AND p.direction = 'in'
        GROUP BY p.method
    ), v AS (
        SELECT count(*) AS n, sum(r.total) AS total FROM public.sales_returns r
        WHERE r.organization_id = p_org AND r.branch_id = p_branch AND r.business_date = p_date AND r.kind = 'void'
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM s),
        'total', app.dc_money((SELECT sum(total) FROM s)),
        'discount_total', app.dc_money((SELECT sum(discount_total) FROM s)),
        'tax_total', app.dc_money((SELECT sum(tax_total) FROM s)),
        'paid_by_method', jsonb_build_object(
            'cash', app.dc_money((SELECT amount FROM paid WHERE method = 'cash')),
            'bank_transfer', app.dc_money((SELECT amount FROM paid WHERE method = 'bank_transfer')),
            'store_credit', app.dc_money((SELECT amount FROM paid WHERE method = 'store_credit'))),
        'on_contract', app.dc_money((SELECT sum(c.financed_amount) FROM public.contracts c
                                     JOIN s ON s.id = c.sale_id WHERE c.organization_id = p_org)),
        'voided', jsonb_build_object('count', (SELECT n FROM v), 'total', app.dc_money((SELECT total FROM v))))
    INTO v_sales;

    -- Returns (S05; voids are under sales.voided).
    WITH r AS (
        SELECT * FROM public.sales_returns x
        WHERE x.organization_id = p_org AND x.branch_id = p_branch AND x.business_date = p_date AND x.kind <> 'void'
    ), refunded AS (
        SELECT p.method, sum(a.amount) AS amount
        FROM r
        JOIN public.payment_allocations a ON a.organization_id = p_org AND a.return_id = r.id
        JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = p_org AND p.direction = 'out'
        GROUP BY p.method
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM r),
        'total', app.dc_money((SELECT sum(total) FROM r)),
        'refunded_by_method', jsonb_build_object(
            'cash', app.dc_money((SELECT amount FROM refunded WHERE method = 'cash')),
            'bank_transfer', app.dc_money((SELECT amount FROM refunded WHERE method = 'bank_transfer')),
            'store_credit', app.dc_money((SELECT amount FROM refunded WHERE method = 'store_credit'))))
    INTO v_returns;

    -- Collections (N03 at the counter, N06 in the field). A collection = its receipt row
    -- (collection_id = id) and the other method rows that share its collection_id.
    WITH rows AS (
        SELECT p.* FROM public.payments p
        WHERE p.organization_id = p_org AND p.branch_id = p_branch AND p.business_date = p_date
          AND p.collection_id IS NOT NULL AND p.direction = 'in'
    ), alloc AS (
        SELECT sum(a.principal_amount) AS principal, sum(a.profit_amount) AS profit
        FROM rows JOIN public.payment_allocations a ON a.organization_id = p_org AND a.payment_id = rows.id
    ), rev AS (
        SELECT count(DISTINCT p.collection_id) AS n, sum(p.amount) AS total FROM public.payments p
        WHERE p.organization_id = p_org AND p.branch_id = p_branch AND p.business_date = p_date
          AND p.collection_id IS NOT NULL AND p.direction = 'out'
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM rows WHERE rows.collection_id = rows.id),
        'total', app.dc_money((SELECT sum(amount) FROM rows)),
        'principal', app.dc_money((SELECT principal FROM alloc)),
        'profit', app.dc_money((SELECT profit FROM alloc)),
        'by_method', jsonb_build_object(
            'cash', app.dc_money((SELECT sum(amount) FROM rows WHERE method = 'cash')),
            'bank_transfer', app.dc_money((SELECT sum(amount) FROM rows WHERE method = 'bank_transfer')),
            'store_credit', app.dc_money((SELECT sum(amount) FROM rows WHERE method = 'store_credit'))),
        'in_field', app.dc_money((SELECT sum(rows.amount) FROM rows
                                  JOIN public.cash_accounts ca ON ca.id = rows.cash_account_id
                                  WHERE ca.kind = 'collector_wallet')),
        'reversed', jsonb_build_object('count', (SELECT n FROM rev), 'total', app.dc_money((SELECT total FROM rev))))
    INTO v_collections;

    -- Expenses (K03); reversals apart.
    WITH e AS (
        SELECT * FROM public.expenses x
        WHERE x.organization_id = p_org AND x.branch_id = p_branch AND x.business_date = p_date
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM e WHERE reverses_expense_id IS NULL),
        'total', app.dc_money((SELECT sum(amount) FROM e WHERE reverses_expense_id IS NULL)),
        'by_category', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('category_id', c.id, 'name', c.name,
                                                'total', app.dc_money(t.total)) ORDER BY c.name, c.id)
            FROM (SELECT category_id, sum(amount) AS total FROM e
                  WHERE reverses_expense_id IS NULL GROUP BY category_id) t
            JOIN public.expense_categories c ON c.id = t.category_id), '[]'::jsonb),
        'reversed', jsonb_build_object(
            'count', (SELECT count(*) FROM e WHERE reverses_expense_id IS NOT NULL),
            'total', app.dc_money((SELECT sum(amount) FROM e WHERE reverses_expense_id IS NOT NULL))))
    INTO v_expenses;

    -- Supplier payments (U03) and cash refunds from suppliers (U04).
    WITH sp AS (
        SELECT * FROM public.supplier_payments x
        WHERE x.organization_id = p_org AND x.branch_id = p_branch AND x.business_date = p_date
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM sp WHERE reverses_payment_id IS NULL),
        'total', app.dc_money((SELECT sum(amount) FROM sp WHERE reverses_payment_id IS NULL)),
        'reversed', jsonb_build_object(
            'count', (SELECT count(*) FROM sp WHERE reverses_payment_id IS NOT NULL),
            'total', app.dc_money((SELECT sum(amount) FROM sp WHERE reverses_payment_id IS NOT NULL))))
    INTO v_suppliers;

    SELECT jsonb_build_object('count', count(*), 'total', app.dc_money(sum(pr.total)))
    INTO v_sup_refunds
    FROM public.purchase_returns pr
    WHERE pr.organization_id = p_org AND pr.branch_id = p_branch AND pr.business_date = p_date
      AND pr.refund_mode = 'cash';

    -- Cash accounts of the branch: opening, in, out, closing and the day's movements by type. A
    -- shop-wide bank shows only what this branch booked on it that day (no opening or closing).
    WITH acc AS (
        SELECT a.* FROM public.cash_accounts a
        WHERE a.organization_id = p_org
          AND (a.branch_id = p_branch
               OR (a.branch_id IS NULL AND EXISTS (
                       SELECT 1 FROM public.cash_movements m
                       WHERE m.organization_id = p_org AND m.cash_account_id = a.id
                         AND m.branch_id = p_branch AND m.business_date = p_date)))
    ), per AS (
        SELECT acc.id, acc.name, acc.kind, acc.branch_id IS NULL AS shop_wide, acc.is_active,
               (SELECT sum(m.amount) FROM public.cash_movements m
                WHERE m.organization_id = p_org AND m.cash_account_id = acc.id AND m.business_date < p_date) AS opening,
               (SELECT sum(m.amount) FROM public.cash_movements m
                WHERE m.organization_id = p_org AND m.cash_account_id = acc.id AND m.business_date = p_date
                  AND m.amount > 0 AND (acc.branch_id IS NOT NULL OR m.branch_id = p_branch)) AS money_in,
               (SELECT -sum(m.amount) FROM public.cash_movements m
                WHERE m.organization_id = p_org AND m.cash_account_id = acc.id AND m.business_date = p_date
                  AND m.amount < 0 AND (acc.branch_id IS NOT NULL OR m.branch_id = p_branch)) AS money_out,
               (SELECT jsonb_object_agg(t.type, app.dc_money(t.amount) ORDER BY t.type)
                FROM (SELECT m.type::text AS type, sum(m.amount) AS amount FROM public.cash_movements m
                      WHERE m.organization_id = p_org AND m.cash_account_id = acc.id AND m.business_date = p_date
                        AND (acc.branch_id IS NOT NULL OR m.branch_id = p_branch)
                      GROUP BY m.type HAVING sum(m.amount) <> 0) t) AS by_type
        FROM acc
    ), shown AS (
        SELECT * FROM per
        WHERE is_active OR COALESCE(opening, 0) <> 0 OR money_in IS NOT NULL OR money_out IS NOT NULL
    )
    SELECT jsonb_build_object(
        'accounts', COALESCE(jsonb_agg(
            jsonb_build_object(
                'account', jsonb_build_object('id', id, 'name', name, 'kind', kind, 'shop_wide', shop_wide),
                'opening', CASE WHEN shop_wide THEN NULL ELSE app.dc_money(opening) END,
                'in', app.dc_money(money_in), 'out', app.dc_money(money_out),
                'closing', CASE WHEN shop_wide THEN NULL
                                ELSE app.dc_money(COALESCE(opening, 0) + COALESCE(money_in, 0) - COALESCE(money_out, 0)) END,
                'by_type', COALESCE(by_type, '{}'::jsonb))
            ORDER BY array_position(ARRAY['safe', 'drawer', 'collector_wallet', 'bank'], kind::text), name, id),
            '[]'::jsonb),
        'total_closing_cash', app.dc_money(sum(COALESCE(opening, 0) + COALESCE(money_in, 0) - COALESCE(money_out, 0))
                                           FILTER (WHERE kind IN ('safe', 'drawer', 'collector_wallet'))))
    INTO v_cash
    FROM shown;

    -- Shifts of the branch opened on the day, still open from before, or with movements dated the day.
    WITH sh AS (
        SELECT s.* FROM public.shifts s
        WHERE s.organization_id = p_org AND s.branch_id = p_branch
          AND ((s.opened_at AT TIME ZONE v_tz)::date = p_date
               OR (s.status = 'open' AND (s.opened_at AT TIME ZONE v_tz)::date <= p_date)
               OR EXISTS (SELECT 1 FROM public.cash_movements m
                          WHERE m.organization_id = p_org AND m.shift_id = s.id AND m.business_date = p_date))
    ), item AS (
        SELECT sh.*, e.full_name AS cashier_name, d.name AS device_name,
               CASE WHEN sh.status = 'closed' THEN sh.expected_cash
                    ELSE (SELECT COALESCE(sum(m.amount), 0) FROM public.cash_movements m      -- K02's expected
                          WHERE m.organization_id = p_org AND m.shift_id = sh.id
                            AND m.cash_account_id = sh.drawer_account_id) END AS expected,
               (SELECT jsonb_build_object(
                    'cash', app.dc_money(sum(p.amount) FILTER (WHERE p.method = 'cash')),
                    'bank_transfer', app.dc_money(sum(p.amount) FILTER (WHERE p.method = 'bank_transfer')),
                    'store_credit', app.dc_money(sum(p.amount) FILTER (WHERE p.method = 'store_credit')))
                FROM public.payments p
                WHERE p.organization_id = p_org AND p.shift_id = sh.id AND p.direction = 'in') AS payment_totals
        FROM sh
        JOIN public.employees e ON e.id = sh.employee_id AND e.organization_id = p_org
        LEFT JOIN public.devices d ON d.id = sh.device_id AND d.organization_id = p_org
    )
    SELECT jsonb_build_object(
        'items', COALESCE(jsonb_agg(jsonb_build_object(
            'id', id, 'number', number, 'status', status,
            'cashier', jsonb_build_object('id', employee_id, 'name', cashier_name),
            'device_name', device_name, 'opened_at', opened_at, 'closed_at', closed_at,
            'opening_float', app.dc_money(opening_float),
            'expected', app.dc_money(expected),
            'counted', CASE WHEN status = 'closed' THEN app.dc_money(counted_cash) END,
            'difference', CASE WHEN status = 'closed' THEN app.dc_money(counted_cash - expected_cash) END,
            'difference_reason', difference_reason,
            'payment_totals', payment_totals) ORDER BY opened_at, id), '[]'::jsonb),
        'difference_total', app.dc_money(sum(counted_cash - expected_cash) FILTER (WHERE status = 'closed')))
    INTO v_shifts
    FROM item;

    -- ETA receipts of the day (T03's day summary), null for a shop without the eta module.
    IF app.org_has_module(p_org, 'eta') THEN
        SELECT jsonb_build_object(
                   'total', count(*),
                   'accepted', count(*) FILTER (WHERE x.situation = 'accepted'),
                   'waiting', count(*) FILTER (WHERE x.situation = 'waiting'),
                   'cancelled', count(*) FILTER (WHERE x.situation = 'cancelled'),
                   'blocked', count(*) FILTER (WHERE x.situation = 'blocked'),
                   'send_failed', count(*) FILTER (WHERE x.situation = 'send_failed'),
                   'rejected', count(*) FILTER (WHERE x.situation = 'rejected'),
                   'all_accepted', count(*) FILTER (WHERE x.situation NOT IN ('accepted', 'cancelled')) = 0)
        INTO v_eta
        FROM (
            SELECT app.fiscal_situation(f.status, f.eta_uuid, f.last_error) AS situation
            FROM public.fiscal_submissions f
            LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
            LEFT JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
            WHERE f.organization_id = p_org AND f.branch_id = p_branch
              AND COALESCE(s.business_date, r.business_date) = p_date
        ) x;
    END IF;

    -- Issues -------------------------------------------------------------------------------------

    -- SHIFT_OPEN (blocking): the cashier closes it first, or a manager force-closes it (EC-147).
    SELECT v_issues || COALESCE(jsonb_agg(app.dc_issue('SHIFT_OPEN', 'blocking',
               jsonb_build_object('number', s.number, 'cashier_name', e.full_name, 'opened_at', s.opened_at),
               'shift', s.id) ORDER BY s.opened_at, s.id), '[]'::jsonb)
    INTO v_issues
    FROM public.shifts s
    JOIN public.employees e ON e.id = s.employee_id AND e.organization_id = p_org
    WHERE s.organization_id = p_org AND s.branch_id = p_branch AND s.status = 'open'
      AND (s.opened_at AT TIME ZONE v_tz)::date <= p_date;

    -- LEDGER_MISMATCH (warning): a cached balance that doesn't equal its ledger, for the branch's
    -- cash accounts, the shop-wide banks it moved that day, and its stock.
    SELECT v_issues || COALESCE(jsonb_agg(app.dc_issue('LEDGER_MISMATCH', 'warning',
               jsonb_build_object('ledger', lm.ledger, 'name', COALESCE(ca.name, pr.name_ar), 'detail', lm.detail,
                                  'cached', lm.cached::text, 'from_ledger', lm.from_ledger::text),
               CASE WHEN lm.ledger = 'cash' THEN 'cash_account' ELSE 'product' END, lm.subject_id)
               ORDER BY lm.ledger, lm.subject_id, lm.detail), '[]'::jsonb)
    INTO v_issues
    FROM app.ledger_mismatches(p_org) lm
    LEFT JOIN public.cash_accounts ca ON lm.ledger = 'cash' AND ca.id = lm.subject_id
    LEFT JOIN public.products pr ON lm.ledger LIKE 'stock%' AND pr.id = lm.subject_id
    WHERE (lm.ledger = 'cash'
           AND (ca.branch_id = p_branch
                OR (ca.branch_id IS NULL AND EXISTS (
                        SELECT 1 FROM public.cash_movements m
                        WHERE m.organization_id = p_org AND m.cash_account_id = ca.id
                          AND m.branch_id = p_branch AND m.business_date = p_date))))
       OR (lm.ledger LIKE 'stock%' AND lm.branch_id = p_branch);

    -- DOCUMENT_WITHOUT_LEDGER (warning): each document of the day against its cash movements
    -- (matched by source), and movements whose source document is missing.
    WITH expected AS (
        -- Sales: the cash and bank payments allocated to the sale = its 'sale' movements.
        SELECT 'sale'::text AS kind, s.id, s.number,
               COALESCE((SELECT sum(a.amount) FROM public.payment_allocations a
                         JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = p_org
                         WHERE a.organization_id = p_org AND a.sale_id = s.id AND p.direction = 'in'
                           AND p.method <> 'store_credit'), 0) AS doc_amount,
               COALESCE((SELECT sum(m.amount) FROM public.cash_movements m
                         WHERE m.organization_id = p_org AND m.source_type = 'sale' AND m.source_id = s.id
                           AND m.type = 'sale'), 0) AS ledger_amount
        FROM public.sales s
        WHERE s.organization_id = p_org AND s.branch_id = p_branch AND s.business_date = p_date
        UNION ALL
        -- Collection rows and their reversals: one movement each.
        SELECT 'payment', p.id, p.number,
               CASE WHEN p.direction = 'in' THEN p.amount ELSE -p.amount END,
               COALESCE((SELECT sum(m.amount) FROM public.cash_movements m
                         WHERE m.organization_id = p_org AND m.source_type = 'payment' AND m.source_id = p.id), 0)
        FROM public.payments p
        WHERE p.organization_id = p_org AND p.branch_id = p_branch AND p.business_date = p_date
          AND p.collection_id IS NOT NULL AND p.method <> 'store_credit'
        UNION ALL
        -- Returns and voids: the cash and bank refunds = their 'refund' movements.
        SELECT 'sales_return', r.id, r.number,
               -COALESCE((SELECT sum(a.amount) FROM public.payment_allocations a
                          JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = p_org
                          WHERE a.organization_id = p_org AND a.return_id = r.id AND p.direction = 'out'
                            AND p.method <> 'store_credit'), 0),
               COALESCE((SELECT sum(m.amount) FROM public.cash_movements m
                         WHERE m.organization_id = p_org AND m.source_type = 'sales_return' AND m.source_id = r.id), 0)
        FROM public.sales_returns r
        WHERE r.organization_id = p_org AND r.branch_id = p_branch AND r.business_date = p_date
        UNION ALL
        SELECT 'expense', e.id, e.number,
               CASE WHEN e.reverses_expense_id IS NULL THEN -e.amount ELSE e.amount END,
               COALESCE((SELECT sum(m.amount) FROM public.cash_movements m
                         WHERE m.organization_id = p_org AND m.source_type = 'expense' AND m.source_id = e.id), 0)
        FROM public.expenses e
        WHERE e.organization_id = p_org AND e.branch_id = p_branch AND e.business_date = p_date
        UNION ALL
        SELECT 'supplier_payment', sp.id, sp.number,
               CASE WHEN sp.reverses_payment_id IS NULL THEN -sp.amount ELSE sp.amount END,
               COALESCE((SELECT sum(m.amount) FROM public.cash_movements m
                         WHERE m.organization_id = p_org AND m.source_type = 'supplier_payment'
                           AND m.source_id = sp.id), 0)
        FROM public.supplier_payments sp
        WHERE sp.organization_id = p_org AND sp.branch_id = p_branch AND sp.business_date = p_date
        UNION ALL
        SELECT 'purchase_return', pr.id, pr.number, pr.total,
               COALESCE((SELECT sum(m.amount) FROM public.cash_movements m
                         WHERE m.organization_id = p_org AND m.source_type = 'purchase_return'
                           AND m.source_id = pr.id), 0)
        FROM public.purchase_returns pr
        WHERE pr.organization_id = p_org AND pr.branch_id = p_branch AND pr.business_date = p_date
          AND pr.refund_mode = 'cash'
        UNION ALL
        -- Transfers touching the branch: the money out of one account equals the transfer, and so
        -- does the money into the other (a settlement's shortage is an adjustment, not counted here).
        SELECT 'cash_transfer', t.id, t.number, t.amount * 2,
               COALESCE((SELECT sum(abs(m.amount)) FROM public.cash_movements m
                         WHERE m.organization_id = p_org AND m.source_type = 'cash_transfer' AND m.source_id = t.id
                           AND ((m.cash_account_id = t.from_account_id AND m.amount < 0
                                 AND m.type IN ('transfer_out', 'float_out'))
                                OR (m.cash_account_id = t.to_account_id AND m.amount > 0
                                    AND m.type IN ('transfer_in', 'float_in')))), 0)
        FROM public.cash_transfers t
        JOIN public.cash_accounts fa ON fa.id = t.from_account_id
        JOIN public.cash_accounts ta ON ta.id = t.to_account_id
        WHERE t.organization_id = p_org AND t.business_date = p_date
          AND (fa.branch_id = p_branch OR ta.branch_id = p_branch
               OR EXISTS (SELECT 1 FROM public.cash_movements m
                          WHERE m.organization_id = p_org AND m.source_type = 'cash_transfer'
                            AND m.source_id = t.id AND m.branch_id = p_branch))
    ), orphans AS (
        SELECT m.source_type::text AS kind, m.source_id AS id, NULL::text AS number,
               0::numeric AS doc_amount, sum(m.amount) AS ledger_amount
        FROM public.cash_movements m
        WHERE m.organization_id = p_org AND m.branch_id = p_branch AND m.business_date = p_date
          AND CASE m.source_type
                WHEN 'sale' THEN NOT EXISTS (SELECT 1 FROM public.sales x WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'payment' THEN NOT EXISTS (SELECT 1 FROM public.payments x WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'sales_return' THEN NOT EXISTS (SELECT 1 FROM public.sales_returns x WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'expense' THEN NOT EXISTS (SELECT 1 FROM public.expenses x WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'supplier_payment' THEN NOT EXISTS (SELECT 1 FROM public.supplier_payments x WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'purchase_return' THEN NOT EXISTS (SELECT 1 FROM public.purchase_returns x WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'cash_transfer' THEN NOT EXISTS (SELECT 1 FROM public.cash_transfers x WHERE x.id = m.source_id AND x.organization_id = p_org)
                ELSE false
              END
        GROUP BY m.source_type, m.source_id
    ), bad AS (
        SELECT * FROM expected WHERE doc_amount <> ledger_amount
        UNION ALL
        SELECT * FROM orphans
    )
    SELECT COALESCE(jsonb_agg(app.dc_issue('DOCUMENT_WITHOUT_LEDGER', 'warning',
               jsonb_build_object('document', b.kind, 'number', b.number, 'missing_document', b.number IS NULL,
                                  'document_amount', app.dc_money(b.doc_amount),
                                  'ledger_amount', app.dc_money(b.ledger_amount)),
               b.kind, b.id) ORDER BY b.kind, b.number, b.id) FILTER (WHERE b.rn <= 50), '[]'::jsonb),
           count(*)
    INTO v_docs, v_doc_count
    FROM (SELECT bad.*, row_number() OVER (ORDER BY bad.kind, bad.number, bad.id) AS rn FROM bad) b;
    IF v_doc_count > 50 THEN
        v_docs := v_docs || jsonb_build_array(app.dc_issue('DOCUMENT_WITHOUT_LEDGER', 'warning',
                      jsonb_build_object('more', v_doc_count - 50), NULL, NULL));
    END IF;
    v_issues := v_issues || v_docs;

    -- ETA_NOT_ACCEPTED (warning), linked to the ETA monitor for the branch and day.
    IF v_eta IS NOT NULL AND NOT (v_eta ->> 'all_accepted')::boolean THEN
        v_issues := v_issues || jsonb_build_array(app.dc_issue('ETA_NOT_ACCEPTED', 'warning',
                        v_eta - 'all_accepted', 'eta_monitor', p_branch));
    END IF;

    -- SHIFT_DIFFERENCE (info): each shift closed with a difference.
    SELECT v_issues || COALESCE(jsonb_agg(app.dc_issue('SHIFT_DIFFERENCE', 'info',
               jsonb_build_object('number', i ->> 'number', 'cashier_name', i #>> '{cashier,name}',
                                  'difference', i ->> 'difference', 'reason', i ->> 'difference_reason'),
               'shift', (i ->> 'id')::uuid)), '[]'::jsonb)
    INTO v_issues
    FROM jsonb_array_elements(v_shifts -> 'items') i
    WHERE i ->> 'status' = 'closed' AND (i ->> 'difference')::numeric <> 0;

    -- WALLET_SHORTAGE (info): N06 settlements of the day with a shortage, wallets of the branch.
    SELECT v_issues || COALESCE(jsonb_agg(app.dc_issue('WALLET_SHORTAGE', 'info',
               jsonb_build_object('number', t.number, 'wallet_name', w.name,
                                  'shortage', app.dc_money(t.shortage_amount), 'reason', t.reason),
               'cash_transfer', t.id) ORDER BY t.number), '[]'::jsonb)
    INTO v_issues
    FROM public.cash_transfers t
    JOIN public.cash_accounts w ON w.id = t.from_account_id AND w.organization_id = p_org
    WHERE t.organization_id = p_org AND t.business_date = p_date AND t.kind = 'collector_settlement'
      AND t.shortage_amount > 0 AND w.branch_id = p_branch;

    -- EARLIER_DAY_OPEN (info): days with activity in the 60 days before that are not closed.
    SELECT count(*) AS n, min(d.business_date) AS first_date INTO v_earlier
    FROM app.day_activity_dates(p_org, p_branch, p_date - 60, p_date - 1) d
    WHERE NOT EXISTS (SELECT 1 FROM public.day_closes dc
                      WHERE dc.organization_id = p_org AND dc.branch_id = p_branch
                        AND dc.business_date = d.business_date AND dc.status = 'closed');
    IF v_earlier.n > 0 THEN
        v_issues := v_issues || jsonb_build_array(app.dc_issue('EARLIER_DAY_OPEN', 'info',
                        jsonb_build_object('count', v_earlier.n, 'first_date', v_earlier.first_date),
                        'day_list', p_branch));
    END IF;

    RETURN jsonb_build_object(
        'totals', jsonb_build_object(
            'sales', v_sales, 'returns', v_returns, 'collections', v_collections, 'expenses', v_expenses,
            'supplier_payments', v_suppliers, 'supplier_refunds', v_sup_refunds, 'cash', v_cash,
            'shifts', v_shifts, 'eta', v_eta),
        'issues', v_issues);
END;
$$;

-- The hash the preview answers and close_day checks (decision 5).
CREATE FUNCTION app.day_close_hash(p_computed jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT md5(jsonb_build_object('totals', p_computed -> 'totals', 'issues', p_computed -> 'issues')::text)
$$;

-- Drift compares what can't change after a close: everything but the ETA status (receipts keep
-- being accepted after the day is closed) and the closer's note.
CREATE FUNCTION app.day_close_comparable(p_totals jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT p_totals - 'eta' - 'note'
$$;

-- Reads: day.close or cash.view (decision 7). An expired shop may still read.
CREATE FUNCTION app.day_close_read_guard()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL OR app.current_org_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('day.close') OR app.has_permission('cash.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: day.close' USING ERRCODE = '42501';
    END IF;
    RETURN app.current_org_id();
END;
$$;

-- A branch of the caller's shop they can see (BRANCH_NOT_FOUND for another shop's id).
CREATE FUNCTION app.day_close_branch(p_org uuid, p_branch uuid)
RETURNS public.branches LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_b public.branches;
BEGIN
    SELECT * INTO v_b FROM public.branches b WHERE b.id = p_branch AND b.organization_id = p_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.has_branch_access(p_branch) THEN
        RAISE EXCEPTION 'BRANCH_DENIED: %', p_branch USING ERRCODE = '42501';
    END IF;
    RETURN v_b;
END;
$$;

CREATE FUNCTION app.day_close_date(p_org uuid, p_date date)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: business_date' USING ERRCODE = 'P0001';
    END IF;
    IF p_date > app.org_today(p_org) THEN
        RAISE EXCEPTION 'FUTURE_BUSINESS_DATE: %', p_date USING ERRCODE = 'P0001';
    END IF;
END;
$$;

CREATE FUNCTION app.day_close_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', dc.id, 'branch_id', dc.branch_id, 'branch_name', b.name, 'business_date', dc.business_date,
        'status', dc.status, 'totals', dc.totals - 'note', 'issues', dc.issues, 'note', dc.totals ->> 'note',
        'closed_by', jsonb_build_object('id', dc.closed_by, 'name', ce.full_name), 'closed_at', dc.closed_at,
        'reopened_by', CASE WHEN dc.reopened_by IS NOT NULL
                            THEN jsonb_build_object('id', dc.reopened_by, 'name', re.full_name) END,
        'reopened_at', dc.reopened_at, 'reopen_reason', dc.reopen_reason)
    FROM public.day_closes dc
    JOIN public.branches b ON b.id = dc.branch_id AND b.organization_id = dc.organization_id
    LEFT JOIN public.employees ce ON ce.id = dc.closed_by AND ce.organization_id = dc.organization_id
    LEFT JOIN public.employees re ON re.id = dc.reopened_by AND re.organization_id = dc.organization_id
    WHERE dc.organization_id = p_org AND dc.id = p_id
$$;

-- Non-info issues that count on the list and the dashboard.
CREATE FUNCTION app.day_issue_count(p_issues jsonb)
RETURNS integer LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT count(*)::integer FROM jsonb_array_elements(COALESCE(p_issues, '[]'::jsonb)) i
    WHERE i ->> 'severity' <> 'info'
$$;

-- 3. Reads -----------------------------------------------------------------------------------------

-- Route 2: the live numbers of an open or reopened day (decisions 1-4).
CREATE FUNCTION public.get_day_close_preview(p_branch_id uuid, p_business_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_b public.branches; v_dc public.day_closes; v_c jsonb;
BEGIN
    v_org := app.day_close_read_guard();
    IF p_branch_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: branch_id' USING ERRCODE = 'P0001';
    END IF;
    v_b := app.day_close_branch(v_org, p_branch_id);
    PERFORM app.day_close_date(v_org, p_business_date);
    SELECT * INTO v_dc FROM public.day_closes dc
    WHERE dc.organization_id = v_org AND dc.branch_id = p_branch_id AND dc.business_date = p_business_date;
    IF v_dc.status = 'closed' THEN
        RAISE EXCEPTION 'DAY_ALREADY_CLOSED: %', p_business_date USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('id', v_dc.id)::text;
    END IF;
    v_c := app.day_close_compute(v_org, p_branch_id, p_business_date);
    RETURN jsonb_build_object(
        'branch_id', v_b.id, 'branch_name', v_b.name, 'business_date', p_business_date,
        'status', CASE WHEN v_dc.id IS NULL THEN 'open' ELSE 'reopened' END,
        'is_today', p_business_date = app.org_today(v_org),
        'totals', v_c -> 'totals', 'issues', v_c -> 'issues', 'hash', app.day_close_hash(v_c),
        'last_close', CASE WHEN v_dc.id IS NOT NULL THEN app.day_close_json(v_org, v_dc.id) END);
END;
$$;

-- Route 4: a stored day close, with drift against the live numbers (decision 8).
CREATE FUNCTION public.get_day_close(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_dc public.day_closes; v_drift boolean := false;
BEGIN
    v_org := app.day_close_read_guard();
    SELECT * INTO v_dc FROM public.day_closes dc WHERE dc.id = p_id AND dc.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_FOUND: day close' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.has_branch_access(v_dc.branch_id) THEN
        RAISE EXCEPTION 'BRANCH_DENIED: %', v_dc.branch_id USING ERRCODE = '42501';
    END IF;
    IF v_dc.status = 'closed' THEN
        v_drift := app.day_close_comparable(app.day_close_compute(v_org, v_dc.branch_id, v_dc.business_date) -> 'totals')
                   IS DISTINCT FROM app.day_close_comparable(v_dc.totals);
    END IF;
    RETURN app.day_close_json(v_org, v_dc.id) || jsonb_build_object('drift', v_drift);
END;
$$;

-- Route 1: the days of a range with activity or a day_closes row (decision 7).
CREATE FUNCTION public.list_day_closes(p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL,
                                       p_to date DEFAULT NULL, p_status text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_to date; v_from date; v_branches uuid[]; v_out jsonb;
BEGIN
    v_org := app.day_close_read_guard();
    v_to := COALESCE(p_to, app.org_today(v_org));
    v_from := COALESCE(p_from, v_to - 29);
    IF v_from > v_to OR v_to - v_from > 91 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: from / to (at most 92 days)' USING ERRCODE = 'P0001';
    END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('open', 'closed', 'reopened') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        PERFORM app.day_close_branch(v_org, p_branch_id);
        v_branches := ARRAY[p_branch_id];
    ELSE
        SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
        FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    END IF;

    WITH days AS (
        SELECT b.id AS branch_id, d.business_date
        FROM unnest(v_branches) AS b(id)
        CROSS JOIN LATERAL app.day_activity_dates(v_org, b.id, v_from, v_to) d
        UNION
        SELECT dc.branch_id, dc.business_date FROM public.day_closes dc
        WHERE dc.organization_id = v_org AND dc.branch_id = ANY (v_branches)
          AND dc.business_date BETWEEN v_from AND v_to
    ), rows AS (
        SELECT d.branch_id, br.name AS branch_name, d.business_date, dc.id, dc.closed_at, ce.full_name AS closed_by_name,
               COALESCE(dc.status::text, 'open') AS status,
               (SELECT sum(s.total) FROM public.sales s
                WHERE s.organization_id = v_org AND s.branch_id = d.branch_id
                  AND s.business_date = d.business_date) AS sales_total,
               CASE WHEN dc.status = 'closed' THEN app.day_issue_count(dc.issues)
                    ELSE (SELECT app.day_issue_count(ck.issues) FROM public.day_checks ck
                          WHERE ck.organization_id = v_org AND ck.branch_id = d.branch_id
                            AND ck.business_date = d.business_date) END AS issues_count
        FROM days d
        JOIN public.branches br ON br.id = d.branch_id
        LEFT JOIN public.day_closes dc ON dc.organization_id = v_org AND dc.branch_id = d.branch_id
                                      AND dc.business_date = d.business_date
        LEFT JOIN public.employees ce ON ce.id = dc.closed_by AND ce.organization_id = v_org
    )
    SELECT jsonb_build_object('items', COALESCE(jsonb_agg(jsonb_build_object(
               'branch_id', r.branch_id, 'branch_name', r.branch_name, 'business_date', r.business_date,
               'status', r.status, 'id', r.id, 'closed_by_name', r.closed_by_name, 'closed_at', r.closed_at,
               'sales_total', app.dc_money(r.sales_total), 'issues_count', r.issues_count)
               ORDER BY r.business_date DESC, r.branch_name, r.branch_id), '[]'::jsonb),
           'from', v_from, 'to', v_to)
    INTO v_out
    FROM rows r
    WHERE p_status IS NULL OR r.status = p_status;
    RETURN v_out;
END;
$$;

-- Route 6: the dashboard card (decision 10). Branches with days not closed in the last 14 days
-- (today left out) or with something above info in their last nightly check.
CREATE FUNCTION public.day_close_alerts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_today date; v_out jsonb;
BEGIN
    v_org := app.day_close_read_guard();
    v_today := app.org_today(v_org);
    WITH br AS (
        SELECT b.id, b.name FROM public.branches b
        WHERE b.organization_id = v_org AND b.is_active AND app.has_branch_access(b.id)
    ), x AS (
        SELECT br.id, br.name,
               (SELECT COALESCE(jsonb_agg(d.business_date ORDER BY d.business_date), '[]'::jsonb)
                FROM app.day_activity_dates(v_org, br.id, v_today - 14, v_today - 1) d
                WHERE NOT EXISTS (SELECT 1 FROM public.day_closes dc
                                  WHERE dc.organization_id = v_org AND dc.branch_id = br.id
                                    AND dc.business_date = d.business_date AND dc.status = 'closed')) AS unclosed,
               (SELECT jsonb_build_object(
                           'business_date', ck.business_date, 'checked_at', ck.checked_at, 'drift', ck.drift,
                           'warnings', app.day_issue_count(ck.issues),
                           'critical', (SELECT count(*) FROM jsonb_array_elements(ck.issues) i
                                        WHERE i ->> 'code' IN ('LEDGER_MISMATCH', 'DOCUMENT_WITHOUT_LEDGER', 'DAY_DRIFT')))
                FROM public.day_checks ck
                WHERE ck.organization_id = v_org AND ck.branch_id = br.id
                ORDER BY ck.checked_at DESC, ck.business_date DESC LIMIT 1) AS last_check
        FROM br
    )
    SELECT jsonb_build_object('branches', COALESCE(jsonb_agg(jsonb_build_object(
               'branch_id', x.id, 'branch_name', x.name, 'unclosed_days', x.unclosed, 'last_check', x.last_check)
               ORDER BY x.name, x.id), '[]'::jsonb))
    INTO v_out
    FROM x
    WHERE jsonb_array_length(x.unclosed) > 0 OR COALESCE((x.last_check ->> 'warnings')::integer, 0) > 0;
    RETURN v_out;
END;
$$;

-- 4. Writes ------------------------------------------------------------------------------------------

-- Route 3: close a branch's day (decision 5). One transaction under the exclusive day lock.
CREATE FUNCTION public.close_day(p_branch_id uuid, p_business_date date, p_preview_hash text,
                                 p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp  uuid;
    v_org  uuid;
    v_dc   public.day_closes;
    v_c    jsonb;
    v_note text := NULLIF(btrim(p_note), '');
    v_block jsonb;
    v_warn integer;
    v_id   uuid;
BEGIN
    v_emp := app.require_permission('day.close');
    v_org := app.current_org_id();
    IF p_branch_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: branch_id' USING ERRCODE = 'P0001';
    END IF;
    IF p_preview_hash IS NULL OR p_preview_hash !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: preview_hash' USING ERRCODE = 'P0001';
    END IF;
    IF length(v_note) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.day_close_branch(v_org, p_branch_id);
    PERFORM app.require_branch_access(p_branch_id);
    PERFORM app.day_close_date(v_org, p_business_date);

    -- Nothing can be posted into the day while it is being closed (shared locks wait for this one).
    PERFORM app.lock_day_for_close(v_org, p_branch_id, p_business_date);

    SELECT * INTO v_dc FROM public.day_closes dc
    WHERE dc.organization_id = v_org AND dc.branch_id = p_branch_id AND dc.business_date = p_business_date
    FOR UPDATE;
    IF v_dc.status = 'closed' THEN
        RAISE EXCEPTION 'DAY_ALREADY_CLOSED: %', p_business_date USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('id', v_dc.id)::text;
    END IF;

    v_c := app.day_close_compute(v_org, p_branch_id, p_business_date);
    SELECT COALESCE(jsonb_agg(i), '[]'::jsonb) INTO v_block
    FROM jsonb_array_elements(v_c -> 'issues') i WHERE i ->> 'severity' = 'blocking';
    IF jsonb_array_length(v_block) > 0 THEN
        RAISE EXCEPTION 'DAY_CLOSE_BLOCKED: %', p_business_date USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('issues', v_block)::text;
    END IF;
    IF app.day_close_hash(v_c) <> p_preview_hash THEN
        RAISE EXCEPTION 'DAY_CHANGED: something was posted after the preview' USING ERRCODE = 'P0001';
    END IF;
    SELECT count(*) INTO v_warn FROM jsonb_array_elements(v_c -> 'issues') i WHERE i ->> 'severity' = 'warning';
    IF v_warn > 0 AND (v_note IS NULL OR length(v_note) < 3) THEN
        RAISE EXCEPTION 'NOTE_REQUIRED: the day has warnings' USING ERRCODE = 'P0001';
    END IF;

    IF v_dc.id IS NULL THEN
        INSERT INTO public.day_closes (organization_id, branch_id, business_date, status, totals, issues,
                                       closed_by, closed_at, created_by, updated_by)
        VALUES (v_org, p_branch_id, p_business_date, 'closed',
                (v_c -> 'totals') || jsonb_build_object('note', v_note), v_c -> 'issues',
                v_emp, now(), v_emp, v_emp)
        RETURNING id INTO v_id;
    ELSE
        -- A reopened day closed again: a new snapshot; the reopen fields go (the CHECK ties them to
        -- the reopened status) and stay in the audit log.
        UPDATE public.day_closes SET
            status = 'closed', totals = (v_c -> 'totals') || jsonb_build_object('note', v_note),
            issues = v_c -> 'issues', closed_by = v_emp, closed_at = now(),
            reopened_by = NULL, reopened_at = NULL, reopen_reason = NULL,
            updated_at = now(), updated_by = v_emp
        WHERE id = v_dc.id
        RETURNING id INTO v_id;
    END IF;

    PERFORM app.write_audit('day.closed', 'day_close', v_id, NULL,
        jsonb_build_object('business_date', p_business_date, 'hash', app.day_close_hash(v_c),
                           'sales_total', v_c #>> '{totals,sales,total}',
                           'total_closing_cash', v_c #>> '{totals,cash,total_closing_cash}',
                           'warnings', v_warn, 'reclosed', v_dc.id IS NOT NULL),
        v_note, p_branch_id, CASE WHEN v_warn > 0 THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.day_close_json(v_org, v_id) || jsonb_build_object('drift', false);
END;
$$;

-- Route 5: reopen a closed day (decision 6). day.reopen: the owner by default.
CREATE FUNCTION public.reopen_day(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_dc public.day_closes; v_reason text := NULLIF(btrim(p_reason), '');
BEGIN
    v_emp := app.require_permission('day.reopen');
    v_org := app.current_org_id();
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_dc FROM public.day_closes dc WHERE dc.id = p_id AND dc.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_FOUND: day close' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_dc.branch_id);
    PERFORM app.lock_day_for_close(v_org, v_dc.branch_id, v_dc.business_date);
    SELECT * INTO v_dc FROM public.day_closes dc WHERE dc.id = p_id FOR UPDATE;
    IF v_dc.status <> 'closed' THEN
        RAISE EXCEPTION 'DAY_NOT_CLOSED' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.day_closes SET
        status = 'reopened', reopened_by = v_emp, reopened_at = now(), reopen_reason = v_reason,
        updated_at = now(), updated_by = v_emp
    WHERE id = v_dc.id;
    PERFORM app.write_audit('day.reopened', 'day_close', v_dc.id,
        jsonb_build_object('status', 'closed', 'hash', app.day_close_hash(
            jsonb_build_object('totals', v_dc.totals - 'note', 'issues', v_dc.issues)),
            'closed_by', v_dc.closed_by, 'closed_at', v_dc.closed_at),
        jsonb_build_object('status', 'reopened', 'business_date', v_dc.business_date),
        v_reason, v_dc.branch_id, 'warning');
    RETURN app.day_close_json(v_org, v_dc.id) || jsonb_build_object('drift', false);
END;
$$;

-- 5. The nightly job (decision 9) -----------------------------------------------------------------

-- 'day.check', service role only: yesterday of every active branch, and the closed days of the last
-- 7 days for drift. Never closes or changes a day; replaying it the same night changes nothing (the
-- audit row is written only when what was found changed). p_as_of (tests only) replaces the shop's
-- today.
CREATE FUNCTION public.jobs_day_check(p_organization_id uuid, p_as_of date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_today   date;
    b         record;
    d         record;
    v_c       jsonb;
    v_issues  jsonb;
    v_drift   boolean;
    v_dc      public.day_closes;
    v_old     public.day_checks;
    v_id      uuid;
    v_checked integer := 0;
    v_found   integer := 0;
    v_drifts  integer := 0;
    v_crit    boolean;
    v_report  jsonb := '[]'::jsonb;
BEGIN
    IF p_organization_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a shop is required' USING ERRCODE = 'P0001';
    END IF;
    v_today := COALESCE(p_as_of, app.org_today(p_organization_id));
    IF app.org_today(p_organization_id) IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: unknown shop' USING ERRCODE = 'P0001';
    END IF;

    FOR b IN SELECT br.id FROM public.branches br
             WHERE br.organization_id = p_organization_id AND br.is_active ORDER BY br.id LOOP
        FOR d IN
            SELECT v_today - 1 AS business_date
            UNION
            SELECT dc.business_date FROM public.day_closes dc
            WHERE dc.organization_id = p_organization_id AND dc.branch_id = b.id AND dc.status = 'closed'
              AND dc.business_date BETWEEN v_today - 7 AND v_today - 1
            ORDER BY 1
        LOOP
            SELECT * INTO v_dc FROM public.day_closes dc
            WHERE dc.organization_id = p_organization_id AND dc.branch_id = b.id
              AND dc.business_date = d.business_date;
            -- Yesterday with no activity, no open shift and no close: nothing to check.
            IF v_dc.id IS NULL
               AND NOT EXISTS (SELECT 1 FROM app.day_activity_dates(p_organization_id, b.id, d.business_date, d.business_date))
               AND NOT EXISTS (SELECT 1 FROM public.shifts s
                               WHERE s.organization_id = p_organization_id AND s.branch_id = b.id AND s.status = 'open') THEN
                CONTINUE;
            END IF;
            v_c := app.day_close_compute(p_organization_id, b.id, d.business_date);
            v_issues := v_c -> 'issues';
            v_drift := v_dc.status = 'closed'
                       AND app.day_close_comparable(v_c -> 'totals') IS DISTINCT FROM app.day_close_comparable(v_dc.totals);
            IF v_drift THEN
                v_issues := v_issues || jsonb_build_array(app.dc_issue('DAY_DRIFT', 'warning',
                                jsonb_build_object('business_date', d.business_date), 'day_close', v_dc.id));
                v_drifts := v_drifts + 1;
            END IF;
            v_checked := v_checked + 1;

            SELECT * INTO v_old FROM public.day_checks ck
            WHERE ck.organization_id = p_organization_id AND ck.branch_id = b.id AND ck.business_date = d.business_date;
            INSERT INTO public.day_checks (organization_id, branch_id, business_date, checked_at, issues, drift)
            VALUES (p_organization_id, b.id, d.business_date, now(), v_issues, COALESCE(v_drift, false))
            ON CONFLICT (organization_id, branch_id, business_date)
            DO UPDATE SET checked_at = excluded.checked_at, issues = excluded.issues, drift = excluded.drift
            RETURNING id INTO v_id;

            IF app.day_issue_count(v_issues) > 0 THEN
                v_found := v_found + 1;
                v_crit := EXISTS (SELECT 1 FROM jsonb_array_elements(v_issues) i
                                  WHERE i ->> 'code' IN ('LEDGER_MISMATCH', 'DOCUMENT_WITHOUT_LEDGER', 'DAY_DRIFT'));
                v_report := v_report || jsonb_build_array(jsonb_build_object(
                    'branch_id', b.id, 'business_date', d.business_date, 'critical', v_crit,
                    'codes', (SELECT jsonb_agg(DISTINCT i ->> 'code') FROM jsonb_array_elements(v_issues) i
                              WHERE i ->> 'severity' <> 'info')));
                IF v_old.id IS NULL OR v_old.issues IS DISTINCT FROM v_issues THEN
                    PERFORM app.write_audit('day.check_failed', 'day_check', v_id, NULL,
                        jsonb_build_object('business_date', d.business_date, 'drift', COALESCE(v_drift, false),
                                           'codes', (SELECT jsonb_agg(DISTINCT i ->> 'code')
                                                     FROM jsonb_array_elements(v_issues) i
                                                     WHERE i ->> 'severity' <> 'info')),
                        NULL, b.id, CASE WHEN v_crit THEN 'critical' ELSE 'warning' END::public.audit_severity,
                        p_organization_id);
                END IF;
            END IF;
        END LOOP;
    END LOOP;
    RETURN jsonb_build_object('checked', v_checked, 'with_issues', v_found, 'drift', v_drifts, 'found', v_report);
END;
$$;

-- 6. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.dc_money(numeric), app.dc_issue(text, text, jsonb, text, uuid),
                       app.day_activity_dates(uuid, uuid, date, date), app.day_close_compute(uuid, uuid, date),
                       app.day_close_hash(jsonb), app.day_close_comparable(jsonb), app.day_close_read_guard(),
                       app.day_close_branch(uuid, uuid), app.day_close_date(uuid, date),
                       app.day_close_json(uuid, uuid), app.day_issue_count(jsonb)
    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.get_day_close_preview(uuid, date), public.get_day_close(uuid),
                       public.list_day_closes(uuid, date, date, text), public.day_close_alerts(),
                       public.close_day(uuid, date, text, text), public.reopen_day(uuid, text),
                       public.jobs_day_check(uuid, date)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_day_close_preview(uuid, date), public.get_day_close(uuid),
                          public.list_day_closes(uuid, date, date, text), public.day_close_alerts(),
                          public.close_day(uuid, date, text, text), public.reopen_day(uuid, text)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.jobs_day_check(uuid, date) TO service_role;
