-- =============================================================================
-- D02 · Sales and margin report (EC-94, D89)
--
-- One read, public.report_sales(...), answers what sold in a period and what it earned, grouped by day,
-- month, branch, employee, category, product, sale type or payment type (docs/tasks/D02.md decisions 1-9).
-- Every number is a SQL aggregate; the API and the browser never add money up.
--
--   counted sales    every sale of the period (business_date) in the branches the caller can see, except a
--                    voided one (a sales_returns row of kind 'void'): D01's "sales not voided"
--   counted returns  every return / exchange whose own business_date is in the period, in those branches
--   revenue          line_total - tax_amount (after discounts, without VAT); cost = quantity x unit_cost
--                    (the snapshot taken at the sale); margin = revenue - cost
--   contract profit  contracts.markup_amount, apart from margin (split over a sale's lines in proportion to
--                    line_total, the last line takes the rest); a return takes app.stored_return_profit_share
--   totals / check   totals come from the document headers (sales, sales_returns) unless a row filter is
--                    given; check = the sum of the rows of all pages minus the totals
--
-- Two sets feed the rows, the totals and the check, built once in the one statement of report_sales: the counted
-- sale lines (sl) and the counted return lines (rl, with their sale line's dimensions). (They began as two set-returning
-- app. functions; the tuplestore of a function result cost about a second on a year of 50 000 sales, so they are CTEs.)
-- The read needs a signed-in employee with report.view and also works in an expired shop
-- (app.has_permission, as D01); cost, margin and contract profit also need report.financial.
-- No table, no enum value, no permission key. Contracts 0.59.0, 1 route.
-- =============================================================================

-- 1. Small helpers (schema app, nothing granted) --------------------------------------------------------

-- Money for the report: NULL stays NULL (a hidden column), else 2 decimals as text.
CREATE FUNCTION app.report_money(p numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$ SELECT CASE WHEN p IS NULL THEN NULL ELSE p::numeric(18,2)::text END $$;

-- The measures of one row or of the totals, in the contract's shape. p_fin = the caller has
-- report.financial: without it every cost-derived value is null. A null input stays null (a column the
-- grouping does not have, e.g. quantity under payment_type).
CREATE FUNCTION app.report_measures(p_fin boolean,
    p_sales_count bigint, p_quantity bigint, p_revenue numeric, p_gross numeric, p_tax numeric, p_discount numeric,
    p_cost numeric, p_cp numeric,
    p_return_count bigint, p_rq bigint, p_rgross numeric, p_rrev numeric, p_rtax numeric, p_rcost numeric, p_rcp numeric,
    p_amount numeric, p_refunded numeric)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'sales_count', p_sales_count, 'quantity', p_quantity,
        'revenue', app.report_money(p_revenue), 'gross', app.report_money(p_gross),
        'tax', app.report_money(p_tax), 'discount', app.report_money(p_discount),
        'cost', CASE WHEN p_fin THEN app.report_money(p_cost) END,
        'margin', CASE WHEN p_fin THEN app.report_money(p_revenue - round(p_cost, 2)) END,
        'margin_pct', CASE WHEN p_fin AND p_revenue <> 0 AND p_cost IS NOT NULL
                           THEN round((p_revenue - round(p_cost, 2)) / p_revenue * 100, 1)::text END,
        'return_count', p_return_count, 'returned_quantity', p_rq,
        'returned_gross', app.report_money(p_rgross), 'returned_revenue', app.report_money(p_rrev),
        'returned_tax', app.report_money(p_rtax),
        'returned_cost', CASE WHEN p_fin THEN app.report_money(p_rcost) END,
        'returned_margin', CASE WHEN p_fin THEN app.report_money(p_rrev - round(p_rcost, 2)) END,
        'net_quantity', p_quantity - p_rq,
        'net_revenue', app.report_money(p_revenue - p_rrev),
        'net_cost', CASE WHEN p_fin THEN app.report_money(round(p_cost, 2) - round(p_rcost, 2)) END,
        'net_margin', CASE WHEN p_fin THEN app.report_money((p_revenue - p_rrev) - (round(p_cost, 2) - round(p_rcost, 2))) END,
        'net_margin_pct', CASE WHEN p_fin AND (p_revenue - p_rrev) <> 0 AND p_cost IS NOT NULL
                               THEN round(((p_revenue - p_rrev) - (round(p_cost, 2) - round(p_rcost, 2)))
                                          / (p_revenue - p_rrev) * 100, 1)::text END,
        'contract_profit', CASE WHEN p_fin THEN app.report_money(p_cp) END,
        'contract_profit_returned', CASE WHEN p_fin THEN app.report_money(p_rcp) END,
        'amount', app.report_money(p_amount), 'refunded', app.report_money(p_refunded),
        'net_amount', app.report_money(p_amount - p_refunded))
$$;

-- 3. The read ----------------------------------------------------------------------------------------------

CREATE FUNCTION public.report_sales(
    p_from date, p_to date, p_group_by text,
    p_branch_id uuid DEFAULT NULL, p_employee_id uuid DEFAULT NULL, p_category_id uuid DEFAULT NULL,
    p_product_id uuid DEFAULT NULL, p_sale_type text DEFAULT NULL, p_sort text DEFAULT NULL,
    p_page integer DEFAULT 1, p_page_size integer DEFAULT 50, p_category_level text DEFAULT 'leaf')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' SET plan_cache_mode = force_custom_plan
AS $$
-- force_custom_plan: after five calls on a pooled connection PostgreSQL would reuse a generic plan, which knows neither
-- the period nor the branches and is twice as slow on a year of 50 000 sales (measured, scripts/d02-report-timing.sql).
DECLARE
    v_org uuid; v_emp uuid; v_fin boolean; v_branches uuid[]; v_sort text;
    v_row_filter boolean; v_off integer; v_out jsonb;
BEGIN
    v_org := app.current_org_id();
    v_emp := app.current_employee_id();
    IF v_org IS NULL OR v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('report.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: report.view' USING ERRCODE = '42501';
    END IF;
    v_fin := app.has_permission('report.financial');

    IF p_from IS NULL OR p_to IS NULL OR p_from > p_to OR p_to - p_from + 1 > 366 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: period (from <= to, at most 366 days)' USING ERRCODE = 'P0001';
    END IF;
    IF p_group_by IS NULL OR p_group_by NOT IN ('day', 'month', 'branch', 'employee', 'category', 'product',
                                                'sale_type', 'payment_type') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: group_by' USING ERRCODE = 'P0001';
    END IF;
    IF p_sale_type IS NOT NULL AND p_sale_type NOT IN ('cash', 'installment') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: sale_type' USING ERRCODE = 'P0001';
    END IF;
    IF p_category_level IS NULL OR p_category_level NOT IN ('leaf', 'top') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: category_level' USING ERRCODE = 'P0001';
    END IF;
    IF p_page IS NULL OR p_page < 1 OR p_page_size IS NULL OR p_page_size < 1 OR p_page_size > 1000 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: page' USING ERRCODE = 'P0001';
    END IF;
    IF p_group_by = 'payment_type' AND (p_category_id IS NOT NULL OR p_product_id IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filter (money by payment type cannot be split by product or category)'
            USING ERRCODE = 'P0001';
    END IF;
    v_sort := COALESCE(p_sort, CASE WHEN p_group_by IN ('day', 'month') THEN 'key_asc' ELSE 'revenue_desc' END);
    IF v_sort NOT IN ('revenue_desc', 'revenue_asc', 'margin_desc', 'margin_asc', 'quantity_desc',
                      'net_revenue_desc', 'key_asc') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: sort' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_fin AND v_sort IN ('margin_desc', 'margin_asc') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: sort (margin needs report.financial)' USING ERRCODE = 'P0001';
    END IF;

    -- Branch scope: a given branch must be the shop's and visible; else every branch the caller can see
    -- (inactive ones included: old sales stay reportable).
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
    IF p_employee_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM public.employees e WHERE e.id = p_employee_id AND e.organization_id = v_org) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_category_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM public.categories c WHERE c.id = p_category_id AND c.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_product_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM public.products p WHERE p.id = p_product_id AND p.organization_id = v_org) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    v_row_filter := p_employee_id IS NOT NULL OR p_category_id IS NOT NULL OR p_product_id IS NOT NULL
                    OR p_sale_type IS NOT NULL;
    v_off := (p_page - 1) * p_page_size;

    -- One statement: the counted sale lines (sl) and the counted return lines (rl) are built once, each with
    -- its dimensions and its row key k, and the rows, the totals and the check all read these two sets.
    WITH RECURSIVE tree AS (
        -- Every category of the shop with the root of its tree.
        SELECT c.id, c.id AS root_id FROM public.categories c WHERE c.organization_id = v_org AND c.parent_id IS NULL
        UNION ALL
        SELECT c.id, t.root_id FROM public.categories c JOIN tree t ON c.parent_id = t.id WHERE c.organization_id = v_org
    ), sub AS (
        -- The category filter with all its sub-categories.
        SELECT c.id FROM public.categories c WHERE c.organization_id = v_org AND c.id = p_category_id
        UNION ALL
        SELECT c.id FROM public.categories c JOIN sub ON c.parent_id = sub.id WHERE c.organization_id = v_org
    ), cs AS NOT MATERIALIZED (
        -- Counted sales: in the period and the branches, voided ones left out (D01's definition).
        SELECT s.id, s.business_date, s.branch_id, s.created_by, c.markup_amount, s.total, s.tax_total, s.discount_total,
               CASE WHEN c.id IS NULL THEN 'cash' ELSE 'installment' END AS sale_type
        FROM public.sales s
        LEFT JOIN public.contracts c ON c.sale_id = s.id AND c.organization_id = s.organization_id
        WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to AND s.branch_id = ANY (v_branches)
          AND NOT EXISTS (SELECT 1 FROM public.sales_returns r
                          WHERE r.organization_id = v_org AND r.sale_id = s.id AND r.kind = 'void')
          AND (p_employee_id IS NULL OR s.created_by = p_employee_id)
          AND (p_sale_type IS NULL OR p_sale_type = CASE WHEN c.id IS NULL THEN 'cash' ELSE 'installment' END)
    ), ln AS (
        -- Their lines. A contract's markup is split over all the sale's lines in proportion to line_total
        -- (cum / tot), before a product or category filter keeps some of them; plain sales skip the windows.
        SELECT cs.*, l.product_id, l.quantity, l.line_total, l.tax_amount, l.discount_amount, l.unit_cost,
               NULL::numeric AS cum, NULL::numeric AS tot
        FROM cs JOIN public.sale_lines l ON l.organization_id = v_org AND l.sale_id = cs.id
        WHERE cs.markup_amount IS NULL
        UNION ALL
        SELECT cs.*, l.product_id, l.quantity, l.line_total, l.tax_amount, l.discount_amount, l.unit_cost,
               sum(l.line_total) OVER (PARTITION BY l.sale_id ORDER BY l.line_no),
               sum(l.line_total) OVER (PARTITION BY l.sale_id)
        FROM cs JOIN public.sale_lines l ON l.organization_id = v_org AND l.sale_id = cs.id
        WHERE cs.markup_amount IS NOT NULL
    ), sl AS NOT MATERIALIZED (
        SELECT ln.id AS sale_id, ln.business_date, ln.branch_id, ln.created_by AS seller_id, ln.sale_type, ln.quantity,
               ln.line_total AS gross, ln.tax_amount AS tax, ln.discount_amount AS discount,
               ln.line_total - ln.tax_amount AS revenue, ln.quantity * COALESCE(ln.unit_cost, 0) AS cost,
               CASE WHEN ln.markup_amount IS NULL OR ln.tot = 0 THEN 0
                    ELSE round(ln.markup_amount * ln.cum / ln.tot, 2)
                         - round(ln.markup_amount * (ln.cum - ln.line_total) / ln.tot, 2) END AS contract_profit,
               CASE p_group_by
                   WHEN 'day' THEN ln.business_date::text
                   WHEN 'month' THEN date_trunc('month', ln.business_date)::date::text
                   WHEN 'branch' THEN ln.branch_id::text
                   WHEN 'employee' THEN ln.created_by::text
                   WHEN 'category' THEN COALESCE((CASE WHEN p_category_level = 'top' THEN t.root_id ELSE p.category_id END)::text, 'none')
                   WHEN 'product' THEN ln.product_id::text
                   WHEN 'sale_type' THEN ln.sale_type
               END AS k
        FROM ln
        JOIN public.products p ON p.id = ln.product_id AND p.organization_id = v_org
        LEFT JOIN tree t ON t.id = p.category_id
        WHERE (p_product_id IS NULL OR ln.product_id = p_product_id)
          AND (p_category_id IS NULL OR p.category_id IN (SELECT sub.id FROM sub))
    ), cr AS (
        -- Counted returns: kind return / exchange, by the return's own business_date, in the branches.
        SELECT r.id, r.business_date, r.branch_id, s.created_by, r.total, r.tax_total,
               CASE WHEN c.id IS NULL THEN 'cash' ELSE 'installment' END AS sale_type,
               CASE WHEN c.id IS NULL THEN 0 ELSE app.stored_return_profit_share(v_org, r.id) END AS share
        FROM public.sales_returns r
        JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
        LEFT JOIN public.contracts c ON c.sale_id = s.id AND c.organization_id = s.organization_id
        WHERE r.organization_id = v_org AND r.kind IN ('return', 'exchange')
          AND r.business_date BETWEEN p_from AND p_to AND r.branch_id = ANY (v_branches)
          AND (p_employee_id IS NULL OR s.created_by = p_employee_id)
          AND (p_sale_type IS NULL OR p_sale_type = CASE WHEN c.id IS NULL THEN 'cash' ELSE 'installment' END)
    ), rn AS (
        -- Their lines; the return's profit share is split over them in proportion to refund_amount.
        SELECT cr.*, rl.sale_line_id, rl.quantity, rl.refund_amount, rl.tax_amount, rl.unit_cost,
               sum(rl.refund_amount) OVER (PARTITION BY cr.id ORDER BY rl.id) AS cum,
               sum(rl.refund_amount) OVER (PARTITION BY cr.id) AS tot
        FROM cr JOIN public.sales_return_lines rl ON rl.organization_id = v_org AND rl.return_id = cr.id
        WHERE cr.share <> 0
        UNION ALL
        SELECT cr.*, rl.sale_line_id, rl.quantity, rl.refund_amount, rl.tax_amount, rl.unit_cost, NULL::numeric, NULL::numeric
        FROM cr JOIN public.sales_return_lines rl ON rl.organization_id = v_org AND rl.return_id = cr.id
        WHERE cr.share = 0
    ), rl AS NOT MATERIALIZED (
        -- A return line takes the dimensions of its sale line and the seller of the returned sale.
        SELECT rn.id AS return_id, rn.business_date, rn.branch_id, rn.created_by AS seller_id, rn.sale_type, rn.quantity,
               rn.refund_amount AS gross, rn.tax_amount AS tax, rn.refund_amount - rn.tax_amount AS revenue,
               rn.quantity * COALESCE(rn.unit_cost, 0) AS cost,
               CASE WHEN rn.share = 0 OR rn.tot = 0 THEN 0
                    ELSE round(rn.share * rn.cum / rn.tot, 2) - round(rn.share * (rn.cum - rn.refund_amount) / rn.tot, 2)
               END AS contract_profit,
               CASE p_group_by
                   WHEN 'day' THEN rn.business_date::text
                   WHEN 'month' THEN date_trunc('month', rn.business_date)::date::text
                   WHEN 'branch' THEN rn.branch_id::text
                   WHEN 'employee' THEN rn.created_by::text
                   WHEN 'category' THEN COALESCE((CASE WHEN p_category_level = 'top' THEN t.root_id ELSE p.category_id END)::text, 'none')
                   WHEN 'product' THEN sl.product_id::text
                   WHEN 'sale_type' THEN rn.sale_type
               END AS k
        FROM rn
        JOIN public.sale_lines sl ON sl.id = rn.sale_line_id AND sl.organization_id = v_org
        JOIN public.products p ON p.id = sl.product_id AND p.organization_id = v_org
        LEFT JOIN tree t ON t.id = p.category_id
        WHERE (p_product_id IS NULL OR sl.product_id = p_product_id)
          AND (p_category_id IS NULL OR p.category_id IN (SELECT sub.id FROM sub))
    ), sk AS (
        SELECT sl.k, count(DISTINCT sl.sale_id) AS sales_count, sum(sl.quantity) AS quantity, sum(sl.revenue) AS revenue,
               sum(sl.gross) AS gross, sum(sl.tax) AS tax, sum(sl.discount) AS discount, sum(sl.cost) AS cost,
               sum(sl.contract_profit) AS cp
        FROM sl WHERE p_group_by <> 'payment_type' GROUP BY sl.k
    ), rk AS (
        SELECT rl.k, count(DISTINCT rl.return_id) AS return_count, sum(rl.quantity) AS rq, sum(rl.gross) AS rgross,
               sum(rl.revenue) AS rrev, sum(rl.tax) AS rtax, sum(rl.cost) AS rcost, sum(rl.contract_profit) AS rcp
        FROM rl WHERE p_group_by <> 'payment_type' GROUP BY rl.k
    ), paid AS (
        SELECT p.method::text AS m, sum(a.amount) AS amount
        FROM public.payment_allocations a
        JOIN public.payments p ON p.id = a.payment_id AND p.organization_id = a.organization_id AND p.direction = 'in'
        WHERE p_group_by = 'payment_type' AND a.organization_id = v_org
          AND a.sale_id IN (SELECT cs.id FROM cs)
        GROUP BY 1
    ), financed AS (
        SELECT sum(c.financed_amount) AS amount FROM public.contracts c
        WHERE p_group_by = 'payment_type' AND c.organization_id = v_org
          AND c.sale_id IN (SELECT cs.id FROM cs)
    ), refunds AS (
        SELECT CASE r.refund_method WHEN 'contract_adjustment' THEN 'on_contract' ELSE r.refund_method::text END AS m,
               sum(r.total) AS amount
        FROM public.sales_returns r
        WHERE p_group_by = 'payment_type' AND r.organization_id = v_org
          AND r.id IN (SELECT cr.id FROM cr)
        GROUP BY 1
    ), ak AS (
        SELECT COALESCE(s.k, r.k) AS k, NULL::integer AS o,
               COALESCE(s.sales_count, 0) AS sales_count, COALESCE(s.quantity, 0) AS quantity,
               COALESCE(s.revenue, 0) AS revenue, COALESCE(s.gross, 0) AS gross, COALESCE(s.tax, 0) AS tax,
               COALESCE(s.discount, 0) AS discount, COALESCE(s.cost, 0) AS cost, COALESCE(s.cp, 0) AS cp,
               COALESCE(r.return_count, 0) AS return_count, COALESCE(r.rq, 0) AS rq, COALESCE(r.rgross, 0) AS rgross,
               COALESCE(r.rrev, 0) AS rrev, COALESCE(r.rtax, 0) AS rtax, COALESCE(r.rcost, 0) AS rcost,
               COALESCE(r.rcp, 0) AS rcp, NULL::numeric AS amount, NULL::numeric AS refunded
        FROM sk s FULL JOIN rk r ON r.k = s.k
        UNION ALL
        SELECT v.k, v.o, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               COALESCE(CASE WHEN v.k = 'on_contract' THEN (SELECT f.amount FROM financed f)
                             ELSE (SELECT pd.amount FROM paid pd WHERE pd.m = v.k) END, 0),
               COALESCE((SELECT rf.amount FROM refunds rf WHERE rf.m = v.k), 0)
        FROM (VALUES ('cash', 1), ('bank_transfer', 2), ('store_credit', 3), ('on_contract', 4)) v(k, o)
        WHERE p_group_by = 'payment_type'
    ), lab AS (
        SELECT ak.*,
               CASE p_group_by
                   WHEN 'month' THEN left(ak.k, 7) WHEN 'branch' THEN b.name WHEN 'employee' THEN e.full_name
                   WHEN 'product' THEN pr.name_ar WHEN 'category' THEN c.name ELSE ak.k END AS label,
               pr.name_en AS label_en,
               CASE p_group_by WHEN 'branch' THEN b.code WHEN 'product' THEN pr.sku END AS sub_label
        FROM ak
        LEFT JOIN public.branches b ON p_group_by = 'branch' AND b.organization_id = v_org AND b.id::text = ak.k
        LEFT JOIN public.employees e ON p_group_by = 'employee' AND e.organization_id = v_org AND e.id::text = ak.k
        LEFT JOIN public.products pr ON p_group_by = 'product' AND pr.organization_id = v_org AND pr.id::text = ak.k
        LEFT JOIN public.categories c ON p_group_by = 'category' AND c.organization_id = v_org AND c.id::text = ak.k
    ), srt AS (
        SELECT lab.*, row_number() OVER (ORDER BY
                   lab.o ASC NULLS LAST,
                   CASE v_sort WHEN 'revenue_desc' THEN lab.revenue
                               WHEN 'margin_desc' THEN lab.revenue - round(lab.cost, 2)
                               WHEN 'quantity_desc' THEN lab.quantity::numeric
                               WHEN 'net_revenue_desc' THEN lab.revenue - lab.rrev END DESC NULLS LAST,
                   CASE v_sort WHEN 'revenue_asc' THEN lab.revenue
                               WHEN 'margin_asc' THEN lab.revenue - round(lab.cost, 2) END ASC NULLS LAST,
                   COALESCE(lab.label, lab.k), lab.k) AS rn
        FROM lab
    ), hs AS (
        SELECT count(*) AS cnt, sum(s.total) AS gross, sum(s.tax_total) AS tax, sum(s.discount_total) AS discount,
               sum(s.cost_total) AS cost
        FROM public.sales s
        WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to AND s.branch_id = ANY (v_branches)
          AND NOT EXISTS (SELECT 1 FROM public.sales_returns r
                          WHERE r.organization_id = v_org AND r.sale_id = s.id AND r.kind = 'void')
    ), hr AS (
        SELECT count(*) AS cnt, sum(r.total) AS gross, sum(r.tax_total) AS tax
        FROM public.sales_returns r
        WHERE r.organization_id = v_org AND r.kind IN ('return', 'exchange')
          AND r.business_date BETWEEN p_from AND p_to AND r.branch_id = ANY (v_branches)
    ), ts AS (
        -- Sums of the rows (the grouping adds nothing up twice); a distinct count only when a row filter needs it.
        SELECT (SELECT count(DISTINCT sl.sale_id) FROM sl WHERE v_row_filter AND p_group_by <> 'payment_type') AS cnt,
               sum(ak.quantity) AS quantity, sum(ak.revenue) AS revenue, sum(ak.gross) AS gross, sum(ak.tax) AS tax,
               sum(ak.discount) AS discount, sum(ak.cost) AS cost, sum(ak.cp) AS cp
        FROM ak
    ), tr AS (
        SELECT (SELECT count(DISTINCT rl.return_id) FROM rl WHERE v_row_filter AND p_group_by <> 'payment_type') AS cnt,
               sum(ak.rq) AS rq, sum(ak.rgross) AS gross, sum(ak.rtax) AS tax, sum(ak.rrev) AS revenue,
               sum(ak.rcost) AS cost, sum(ak.rcp) AS cp
        FROM ak
    ), cst AS (
        -- The counted documents' headers, for the payment type grouping with a row filter.
        SELECT count(*) AS cnt, sum(cs.total) AS gross, sum(cs.tax_total) AS tax, sum(cs.discount_total) AS discount
        FROM cs WHERE v_row_filter AND p_group_by = 'payment_type'
    ), crt AS (
        SELECT count(*) AS cnt, sum(cr.total) AS gross, sum(cr.tax_total) AS tax
        FROM cr WHERE v_row_filter AND p_group_by = 'payment_type'
    ), tot AS (
        -- Totals: from the document headers unless a row filter makes them incomparable (then from the rows,
        -- or from the counted documents' headers under the payment type grouping, which has no lines).
        SELECT CASE WHEN NOT v_row_filter THEN hs.cnt WHEN p_group_by = 'payment_type' THEN cst.cnt ELSE ts.cnt END AS sales_count,
               CASE WHEN p_group_by = 'payment_type' THEN NULL ELSE COALESCE(ts.quantity, 0)::bigint END AS quantity,
               CASE WHEN NOT v_row_filter THEN COALESCE(hs.gross, 0) - COALESCE(hs.tax, 0)
                    WHEN p_group_by = 'payment_type' THEN COALESCE(cst.gross, 0) - COALESCE(cst.tax, 0)
                    ELSE COALESCE(ts.revenue, 0) END AS revenue,
               CASE WHEN NOT v_row_filter THEN COALESCE(hs.gross, 0) WHEN p_group_by = 'payment_type' THEN COALESCE(cst.gross, 0)
                    ELSE COALESCE(ts.gross, 0) END AS gross,
               CASE WHEN NOT v_row_filter THEN COALESCE(hs.tax, 0) WHEN p_group_by = 'payment_type' THEN COALESCE(cst.tax, 0)
                    ELSE COALESCE(ts.tax, 0) END AS tax,
               CASE WHEN NOT v_row_filter THEN COALESCE(hs.discount, 0) WHEN p_group_by = 'payment_type' THEN COALESCE(cst.discount, 0)
                    ELSE COALESCE(ts.discount, 0) END AS discount,
               CASE WHEN p_group_by = 'payment_type' THEN NULL WHEN NOT v_row_filter THEN COALESCE(hs.cost, 0)
                    ELSE COALESCE(ts.cost, 0) END AS cost,
               CASE WHEN p_group_by = 'payment_type' THEN NULL ELSE COALESCE(ts.cp, 0) END AS cp,
               CASE WHEN NOT v_row_filter THEN hr.cnt WHEN p_group_by = 'payment_type' THEN crt.cnt ELSE tr.cnt END AS return_count,
               CASE WHEN p_group_by = 'payment_type' THEN NULL ELSE COALESCE(tr.rq, 0)::bigint END AS rq,
               CASE WHEN NOT v_row_filter THEN COALESCE(hr.gross, 0) WHEN p_group_by = 'payment_type' THEN COALESCE(crt.gross, 0)
                    ELSE COALESCE(tr.gross, 0) END AS rgross,
               CASE WHEN NOT v_row_filter THEN COALESCE(hr.gross, 0) - COALESCE(hr.tax, 0)
                    WHEN p_group_by = 'payment_type' THEN COALESCE(crt.gross, 0) - COALESCE(crt.tax, 0)
                    ELSE COALESCE(tr.revenue, 0) END AS rrev,
               CASE WHEN NOT v_row_filter THEN COALESCE(hr.tax, 0) WHEN p_group_by = 'payment_type' THEN COALESCE(crt.tax, 0)
                    ELSE COALESCE(tr.tax, 0) END AS rtax,
               CASE WHEN p_group_by = 'payment_type' THEN NULL ELSE COALESCE(tr.cost, 0) END AS rcost,
               CASE WHEN p_group_by = 'payment_type' THEN NULL ELSE COALESCE(tr.cp, 0) END AS rcp
        FROM ts, tr, cst, crt, hs, hr
    ), sums AS (
        SELECT COALESCE(sum(ak.revenue), 0) AS revenue, COALESCE(sum(ak.gross), 0) AS gross, COALESCE(sum(ak.tax), 0) AS tax,
               COALESCE(sum(ak.cost), 0) AS cost, COALESCE(sum(ak.rrev), 0) AS rrev, COALESCE(sum(ak.rgross), 0) AS rgross,
               COALESCE(sum(ak.amount), 0) AS amount, COALESCE(sum(ak.refunded), 0) AS refunded
        FROM ak
    )
    SELECT jsonb_build_object(
        'rows', COALESCE((
            SELECT jsonb_agg(
                       jsonb_build_object('key', srt.k, 'label', srt.label, 'label_en', srt.label_en,
                                          'sub_label', srt.sub_label)
                       || app.report_measures(v_fin, srt.sales_count, srt.quantity, srt.revenue, srt.gross, srt.tax,
                                              srt.discount, srt.cost, srt.cp, srt.return_count, srt.rq, srt.rgross,
                                              srt.rrev, srt.rtax, srt.rcost, srt.rcp, srt.amount, srt.refunded)
                       ORDER BY srt.rn)
            FROM srt WHERE srt.rn > v_off AND srt.rn <= v_off + p_page_size), '[]'::jsonb),
        'total_count', (SELECT count(*) FROM ak),
        'totals', app.report_measures(v_fin, tot.sales_count, tot.quantity, tot.revenue, tot.gross, tot.tax, tot.discount,
                                      tot.cost, tot.cp, tot.return_count, tot.rq, tot.rgross, tot.rrev, tot.rtax,
                                      tot.rcost, tot.rcp,
                                      CASE WHEN p_group_by = 'payment_type' THEN sums.amount END,
                                      CASE WHEN p_group_by = 'payment_type' THEN sums.refunded END),
        'check', CASE WHEN v_row_filter THEN NULL ELSE jsonb_build_object(
            'rows_match', CASE WHEN p_group_by = 'payment_type'
                               THEN sums.amount = tot.gross AND sums.refunded = tot.rgross
                               ELSE sums.revenue = tot.revenue AND sums.tax = tot.tax AND sums.gross = tot.gross
                                    AND sums.rrev = tot.rrev AND sums.rgross = tot.rgross
                                    AND abs(sums.cost - tot.cost) <= 0.01 * tot.sales_count END,
            'differences', jsonb_build_object(
                'revenue', CASE WHEN p_group_by <> 'payment_type' THEN app.report_money(sums.revenue - tot.revenue) END,
                'tax', CASE WHEN p_group_by <> 'payment_type' THEN app.report_money(sums.tax - tot.tax) END,
                'cost', CASE WHEN v_fin AND p_group_by <> 'payment_type' THEN app.report_money(sums.cost - tot.cost) END,
                'returned_revenue', CASE WHEN p_group_by <> 'payment_type' THEN app.report_money(sums.rrev - tot.rrev) END,
                'gross', app.report_money(CASE WHEN p_group_by = 'payment_type' THEN sums.amount ELSE sums.gross END - tot.gross),
                'returned_gross', app.report_money(CASE WHEN p_group_by = 'payment_type' THEN sums.refunded ELSE sums.rgross END - tot.rgross))) END)
    INTO v_out
    FROM tot, sums;

    RETURN v_out || jsonb_build_object(
        'from', p_from, 'to', p_to, 'group_by', p_group_by,
        'filters', jsonb_build_object('branch_id', p_branch_id, 'employee_id', p_employee_id, 'category_id', p_category_id,
                                      'category_level', CASE WHEN p_group_by = 'category' THEN p_category_level END,
                                      'product_id', p_product_id, 'sale_type', p_sale_type),
        'sort', v_sort, 'generated_at', now(), 'can_see_cost', v_fin, 'page', p_page, 'page_size', p_page_size);
END;
$$;

-- 4. Grants: the public read to signed-in users, nothing for the app. helpers ---------------------------

REVOKE ALL ON FUNCTION public.report_sales(date, date, text, uuid, uuid, uuid, uuid, text, text, integer, integer, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.report_sales(date, date, text, uuid, uuid, uuid, uuid, text, text, integer, integer, text)
    TO authenticated;
REVOKE ALL ON FUNCTION app.report_money(numeric),
    app.report_measures(boolean, bigint, bigint, numeric, numeric, numeric, numeric, numeric, numeric, bigint, bigint,
                        numeric, numeric, numeric, numeric, numeric, numeric, numeric)
    FROM PUBLIC, anon, authenticated;
