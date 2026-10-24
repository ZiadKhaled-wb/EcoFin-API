-- =============================================================================
-- EC-149 · BUG-2 · One sales rule across the dashboard, the shift and the day close (D94)
--
-- The owner dashboard (D01) and the sales report (D02) already left voided sales out; the day close
-- (K04) and the shift summary (K02 / S02) counted them, and the shift's "cash" also held the
-- collections taken on the shift. The rule (DECISIONS.md D94), now the same on every screen:
--   1. A voided sale (a sales_returns row of kind 'void') is out of sales: count, total, discount,
--      VAT, paid by method and on contract. The day close keeps its "voided (n) amount" line.
--   2. Returns stay gross: sales are not reduced; returns are their own line, now with their VAT.
--   3. An installment sale counts at its cash price; the method lines count only the money taken.
--   4. A shift's takings by method are the money of its counted sales only; the collections (N03) and
--      the order deposits (S10, not a sale until delivered) taken on the shift are their own figures.
--      The drawer's expected cash (the ledger) does not change.
-- Stored day closes are never rewritten. The day list shows a closed day's stored total, and the
-- drift check leaves out the figures added here (and the shifts' takings, which follow from the
-- day's sales and collections, compared on their own), so only a day closed with a void drifts.
-- Re-created from their latest versions: app.day_close_compute, app.day_close_comparable (K04),
-- public.list_day_closes (K04), app.shift_json (20261022100000). New: app.shift_takings.
-- No table, no enum value, no permission key, no route. Contracts 0.65.0 (additive fields).
-- =============================================================================

-- A shift's takings: its counted sales (voided ones left out), the money of those sales by method,
-- the collections (N03) and the order deposits (S10) taken on the shift by method. One definition for
-- the shift summary and the day close's shift rows.
CREATE FUNCTION app.shift_takings(p_org uuid, p_shift_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH s AS (
        SELECT x.id, x.total, x.tax_total FROM public.sales x
        WHERE x.organization_id = p_org AND x.shift_id = p_shift_id
          AND NOT EXISTS (SELECT 1 FROM public.sales_returns r
                          WHERE r.organization_id = p_org AND r.sale_id = x.id AND r.kind = 'void')
    ), paid AS (
        SELECT p.method, sum(a.amount) AS amount
        FROM s
        JOIN public.payment_allocations a ON a.organization_id = p_org AND a.sale_id = s.id
        JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = p_org AND p.direction = 'in'
        GROUP BY p.method
    ), col AS (
        SELECT p.method, sum(p.amount) AS amount FROM public.payments p
        WHERE p.organization_id = p_org AND p.shift_id = p_shift_id AND p.direction = 'in'
          AND p.collection_id IS NOT NULL
        GROUP BY p.method
    ), dep AS (
        SELECT p.method, sum(p.amount) AS amount FROM public.payments p
        WHERE p.organization_id = p_org AND p.shift_id = p_shift_id AND p.direction = 'in'
          AND EXISTS (SELECT 1 FROM public.payment_allocations a
                      WHERE a.organization_id = p_org AND a.payment_id = p.id AND a.order_id IS NOT NULL)
        GROUP BY p.method
    )
    SELECT jsonb_build_object(
        'sales_count', (SELECT count(*) FROM s),
        'sales_total', app.dc_money((SELECT sum(total) FROM s)),
        'tax_total', app.dc_money((SELECT sum(tax_total) FROM s)),
        'payment_totals', jsonb_build_object(
            'cash', app.dc_money((SELECT amount FROM paid WHERE method = 'cash')),
            'bank_transfer', app.dc_money((SELECT amount FROM paid WHERE method = 'bank_transfer')),
            'store_credit', app.dc_money((SELECT amount FROM paid WHERE method = 'store_credit'))),
        'collections', jsonb_build_object(
            'cash', app.dc_money((SELECT amount FROM col WHERE method = 'cash')),
            'bank_transfer', app.dc_money((SELECT amount FROM col WHERE method = 'bank_transfer')),
            'store_credit', app.dc_money((SELECT amount FROM col WHERE method = 'store_credit'))),
        'deposits', jsonb_build_object(
            'cash', app.dc_money((SELECT amount FROM dep WHERE method = 'cash')),
            'bank_transfer', app.dc_money((SELECT amount FROM dep WHERE method = 'bank_transfer')),
            'store_credit', app.dc_money((SELECT amount FROM dep WHERE method = 'store_credit'))))
$$;

-- K04's day numbers (from 20261025090000), with the EC-149 rule: voided sales out of sales, returns
-- with their VAT, each shift row with app.shift_takings.
CREATE OR REPLACE FUNCTION app.day_close_compute(p_org uuid, p_branch uuid, p_date date)
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

    -- Sales of the day, voided ones left out (EC-149, D94); the voids of the day are their own line
    -- (a void is only possible on the sale's own day, so both are the same day).
    WITH s AS (
        SELECT * FROM public.sales x
        WHERE x.organization_id = p_org AND x.branch_id = p_branch AND x.business_date = p_date
          AND NOT EXISTS (SELECT 1 FROM public.sales_returns r
                          WHERE r.organization_id = p_org AND r.sale_id = x.id AND r.kind = 'void')
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
        'tax_total', app.dc_money((SELECT sum(tax_total) FROM r)),
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
               app.shift_takings(p_org, sh.id) AS takings
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
            'difference_reason', difference_reason) || takings ORDER BY opened_at, id), '[]'::jsonb),
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

-- Drift compares what can't change after a close: everything but the ETA status (receipts keep
-- being accepted after the day is closed) and the closer's note. EC-149: also without the returns'
-- VAT and the shifts' takings, which follow from the returns, sales and collections compared above
-- and are missing or worked out by the old rule in days closed before it.
CREATE OR REPLACE FUNCTION app.day_close_comparable(p_totals jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT (p_totals - 'eta' - 'note')
        || jsonb_build_object(
               'returns', (p_totals -> 'returns') - 'tax_total',
               'shifts', jsonb_set(p_totals -> 'shifts', '{items}', COALESCE((
                   SELECT jsonb_agg(i - ARRAY['payment_totals', 'sales_count', 'sales_total', 'tax_total', 'collections', 'deposits']
                                    ORDER BY n)
                   FROM jsonb_array_elements(p_totals #> '{shifts,items}') WITH ORDINALITY x(i, n)), '[]'::jsonb)))
$$;

-- Route 1 of K04 (from 20261025090000). EC-149: an open or reopened day shows its counted sales (no
-- voids); a closed day shows the total stored in its snapshot, as its detail does.
CREATE OR REPLACE FUNCTION public.list_day_closes(p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL,
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
               CASE WHEN dc.status = 'closed' THEN (dc.totals #>> '{sales,total}')::numeric
                    ELSE (SELECT sum(s.total) FROM public.sales s
                          WHERE s.organization_id = v_org AND s.branch_id = d.branch_id
                            AND s.business_date = d.business_date
                            AND NOT EXISTS (SELECT 1 FROM public.sales_returns r
                                            WHERE r.organization_id = v_org AND r.sale_id = s.id
                                              AND r.kind = 'void')) END AS sales_total,
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

-- K02 / S02 shift (from 20261022100000). EC-149: sales_total, payment_totals and the new sales_count,
-- tax_total, collections and deposits come from app.shift_takings.
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
        'count_breakdown', s.count_breakdown, 'difference_reason', s.difference_reason)
        || app.shift_takings(p_org, s.id)
        || CASE WHEN p_with_movements THEN jsonb_build_object('movements', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', m.id, 'created_at', m.created_at, 'type', m.type, 'amount', m.amount::text,
                'source_type', m.source_type,
                'source_number', n.number,
                'note', CASE WHEN m.note = n.number THEN NULL ELSE m.note END)
                ORDER BY m.created_at, m.id)
            FROM public.cash_movements m
            CROSS JOIN LATERAL (SELECT CASE m.source_type
                WHEN 'cash_transfer' THEN (SELECT t.number FROM public.cash_transfers t
                                           WHERE t.id = m.source_id AND t.organization_id = p_org)
                WHEN 'sale' THEN (SELECT x.number FROM public.sales x
                                  WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'expense' THEN (SELECT x.number FROM public.expenses x
                                     WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'payment' THEN (SELECT x.number FROM public.payments x
                                     WHERE x.id = m.source_id AND x.organization_id = p_org)
                WHEN 'supplier_payment' THEN (SELECT x.number FROM public.supplier_payments x
                                              WHERE x.id = m.source_id AND x.organization_id = p_org)
                END AS number) n
            WHERE m.organization_id = p_org AND m.shift_id = s.id AND m.cash_account_id = s.drawer_account_id),
            '[]'::jsonb))
           ELSE '{}'::jsonb END
    FROM public.shifts s
    JOIN public.employees e ON e.id = s.employee_id AND e.organization_id = s.organization_id
    LEFT JOIN public.employees ce ON ce.id = s.closed_by AND ce.organization_id = s.organization_id
    LEFT JOIN public.devices d ON d.id = s.device_id AND d.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.id = p_id
$$;

REVOKE ALL ON FUNCTION app.shift_takings(uuid, uuid), app.day_close_compute(uuid, uuid, date),
                       app.day_close_comparable(jsonb), app.shift_json(uuid, uuid, boolean)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_day_closes(uuid, date, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_day_closes(uuid, date, date, text) TO authenticated;
