-- D02 timing proof (D89, decision 10): how long public.report_sales(...) takes (a) for one month on the dev
-- seed shop as it is and (b) after a generated data set of 50 000 sales over 365 days (150 000 sale lines,
-- 5 000 of them installment sales, 3 000 returns, 500 voided sales, a cash payment for every sale), for one
-- month and for a whole year, in every grouping.
-- Local stack only. The generated data is committed and vacuumed first (a report on rows written in the same open
-- transaction is much slower than on committed rows, and that is not how a shop reads its report), so it stays
-- behind: run npx -y supabase@2.119.0 db reset afterwards.
--   docker exec -i supabase_db_ecofin-api psql -U postgres -v ON_ERROR_STOP=1 < scripts/d02-report-timing.sql
-- Prints the milliseconds of 5 runs (the first is cold) per grouping. Targets: month < 500 ms on the seed
-- shop, year < 2 s on the generated shop.
CREATE SCHEMA p;
CREATE FUNCTION p.as_owner() RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000011',false),
         set_config('app.org_id','',false),
         set_config('request.headers','{"x-org-id":"d1000000-0000-0000-0000-000000000001"}',false) $$;
CREATE TABLE p.ms(label text, run int, ms numeric);
CREATE FUNCTION p.time_it(p_label text, p_from date, p_to date, p_group text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE i int; t0 timestamptz; r jsonb;
BEGIN
  FOR i IN 1..5 LOOP
    t0 := clock_timestamp();
    r := public.report_sales(p_from, p_to, p_group, p_page_size => 1000);
    INSERT INTO p.ms VALUES (p_label, i, round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1));
  END LOOP;
END $$;
CREATE FUNCTION p.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today('d1000000-0000-0000-0000-000000000001') $$;
GRANT USAGE ON SCHEMA p TO authenticated;
GRANT ALL ON p.ms TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA p TO authenticated;

SELECT p.as_owner();
SET ROLE authenticated;
SELECT p.time_it('seed shop, one month, ' || g, p.today() - 29, p.today(), g)
FROM unnest(ARRAY['day','branch','employee','category','product','sale_type','payment_type']) g;
RESET ROLE;

-- The generated data set, as the database owner (triggers off for the bulk insert only).
BEGIN;
SET session_replication_role = replica;
INSERT INTO public.categories(organization_id, name, parent_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf root ' || g, NULL FROM generate_series(1, 3) g;
INSERT INTO public.categories(organization_id, name, parent_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf child ' || g,
         (SELECT id FROM public.categories WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND name = 'Perf root ' || (1 + g % 3))
  FROM generate_series(1, 7) g;
INSERT INTO public.products(organization_id, name_ar, sku, cash_price, avg_cost, tax_class_id, category_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'منتج ' || g, 'PERF-' || g, 100 + g, 60,
         (SELECT id FROM public.tax_classes WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND kind = 'standard'),
         CASE WHEN g % 10 = 0 THEN NULL
              ELSE (SELECT id FROM public.categories WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND name = 'Perf child ' || (1 + g % 7)) END
  FROM generate_series(1, 200) g;
INSERT INTO public.customers(organization_id, full_name, phones, credit_limit, status)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf customer ' || g, ARRAY['0100000' || lpad(g::text, 4, '0')], 100000, 'active'
  FROM generate_series(1, 500) g;
INSERT INTO public.cash_accounts(organization_id, name, kind, branch_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf safe', 'safe', id FROM public.branches
  WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND is_main;
INSERT INTO public.installment_policies(organization_id, version, max_months, markup_tiers)
  VALUES ('d1000000-0000-0000-0000-000000000001', 9001, 24, '[{"pct":20,"up_to_months":24}]');
CREATE TABLE p.emp AS SELECT row_number() OVER (ORDER BY id) AS n, id FROM public.employees WHERE organization_id = 'd1000000-0000-0000-0000-000000000001';
CREATE TABLE p.br AS SELECT row_number() OVER (ORDER BY id) AS n, id FROM public.branches WHERE organization_id = 'd1000000-0000-0000-0000-000000000001';
CREATE TABLE p.prod AS SELECT row_number() OVER (ORDER BY sku) AS n, id FROM public.products WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND sku LIKE 'PERF-%';
CREATE TABLE p.tax AS SELECT id FROM public.tax_classes WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND kind = 'standard';
-- 50 000 sales of three lines each: line total 100 + g % 50, quantity 1 + g % 3, VAT-inclusive at 14 %.
INSERT INTO public.sales(organization_id, number, branch_id, kind, is_b2b, prices_include_vat, subtotal, discount_total, tax_total, total, cost_total,
                         business_date, idempotency_key, issued_at, created_by)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'PERF-S-' || g, (SELECT id FROM p.br WHERE n = 1 + g % 2), 'pos', false, true,
         3 * (100 + g % 50), 0, 3 * round((100 + g % 50) * 14 / 114.0, 2), 3 * (100 + g % 50),
         3 * (1 + g % 3) * 60,
         app.org_today('d1000000-0000-0000-0000-000000000001') - (g % 365), 'perf-sale-' || g, now(),
         (SELECT id FROM p.emp WHERE n = 1 + g % 3)
  FROM generate_series(1, 50000) g;
INSERT INTO public.sale_lines(organization_id, sale_id, line_no, product_id, quantity, unit_price, tax_class_id, tax_rate, tax_amount, line_total, unit_cost)
  SELECT s.organization_id, s.id, l.n, (SELECT id FROM p.prod WHERE n = 1 + (g.g * 7 + l.n * 13) % 200), 1 + g.g % 3,
         (100 + g.g % 50) / (1 + g.g % 3), (SELECT id FROM p.tax), 14, round((100 + g.g % 50) * 14 / 114.0, 2), 100 + g.g % 50, 60
  FROM generate_series(1, 50000) g(g)
  JOIN public.sales s ON s.organization_id = 'd1000000-0000-0000-0000-000000000001' AND s.idempotency_key = 'perf-sale-' || g.g
  CROSS JOIN generate_series(1, 3) l(n);
-- A cash payment for every sale.
WITH pay AS (
  INSERT INTO public.payments(organization_id, number, branch_id, direction, method, amount, business_date, idempotency_key, cash_account_id)
  SELECT s.organization_id, 'PERF-P-' || s.number, s.branch_id, 'in', 'cash', s.total, s.business_date, 'perf-pay-' || s.number,
         (SELECT a.id FROM public.cash_accounts a WHERE a.organization_id = s.organization_id AND a.name = 'Perf safe')
  FROM public.sales s WHERE s.number LIKE 'PERF-S-%'
  RETURNING id, idempotency_key, amount
)
INSERT INTO public.payment_allocations(organization_id, payment_id, amount, sale_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', pay.id, pay.amount,
         (SELECT s.id FROM public.sales s WHERE s.organization_id = 'd1000000-0000-0000-0000-000000000001' AND s.idempotency_key = replace(pay.idempotency_key, 'perf-pay-PERF-S-', 'perf-sale-'))
  FROM pay;
-- 5 000 installment sales.
INSERT INTO public.contracts(organization_id, number, customer_id, branch_id, policy_id, creditor, cash_price, down_payment, financed_amount, markup_pct, markup_amount,
                             total_payable, installments_count, frequency, first_due_date, idempotency_key, sale_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'PERF-C-' || g,
         (SELECT id FROM public.customers WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND full_name = 'Perf customer ' || (1 + g % 500)),
         (SELECT id FROM p.br WHERE n = 1 + g % 2),
         (SELECT id FROM public.installment_policies WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND version = 9001),
         'in_house', 12000, 2000, 10000, 20, 2000, 12000, 12, 'monthly', app.org_today('d1000000-0000-0000-0000-000000000001'),
         'perf-contract-' || g,
         (SELECT x.id FROM public.sales x WHERE x.organization_id = 'd1000000-0000-0000-0000-000000000001' AND x.idempotency_key = 'perf-sale-' || g)
  FROM generate_series(1, 5000) g;
-- 3 000 returns of one piece each (the day after the sale), 500 voids.
INSERT INTO public.sales_returns(organization_id, number, sale_id, branch_id, kind, refund_method, subtotal, tax_total, total, reason, business_date, idempotency_key)
  SELECT s.organization_id, 'PERF-R-' || g, s.id, s.branch_id, 'return', 'cash', 100 + g % 50 - round((100 + g % 50) * 14 / 114.0, 2),
         round((100 + g % 50) * 14 / 114.0, 2), 100 + g % 50, 'perf', LEAST(s.business_date + 1, app.org_today(s.organization_id)), 'perf-return-' || g
  FROM generate_series(1, 3000) g
  JOIN public.sales s ON s.organization_id = 'd1000000-0000-0000-0000-000000000001' AND s.idempotency_key = 'perf-sale-' || g;
INSERT INTO public.sales_return_lines(organization_id, return_id, sale_line_id, quantity, refund_amount, tax_amount, unit_cost)
  SELECT r.organization_id, r.id, (SELECT l.id FROM public.sale_lines l WHERE l.sale_id = r.sale_id AND l.line_no = 1), 1, r.total, r.tax_total, 60
  FROM public.sales_returns r WHERE r.number LIKE 'PERF-R-%';
INSERT INTO public.sales_returns(organization_id, number, sale_id, branch_id, kind, refund_method, subtotal, total, reason, business_date, idempotency_key)
  SELECT s.organization_id, 'PERF-V-' || g, s.id, s.branch_id, 'void', 'cash', s.subtotal, s.total, 'perf', s.business_date, 'perf-void-' || g
  FROM generate_series(40001, 40500) g
  JOIN public.sales s ON s.organization_id = 'd1000000-0000-0000-0000-000000000001' AND s.idempotency_key = 'perf-sale-' || g;
SET session_replication_role = origin;
COMMIT;
VACUUM (ANALYZE) public.sales; VACUUM (ANALYZE) public.sale_lines; VACUUM (ANALYZE) public.sales_returns;
VACUUM (ANALYZE) public.sales_return_lines; VACUUM (ANALYZE) public.contracts; VACUUM (ANALYZE) public.payments;
VACUUM (ANALYZE) public.payment_allocations; VACUUM (ANALYZE) public.products; VACUUM (ANALYZE) public.categories;

SELECT p.as_owner();
SET ROLE authenticated;
SELECT p.time_it('50k sales, one month, ' || g, p.today() - 29, p.today(), g)
FROM unnest(ARRAY['day','branch','employee','category','product','sale_type','payment_type']) g;
SELECT p.time_it('50k sales, a year (366 days), ' || g, p.today() - 365, p.today(), g)
FROM unnest(ARRAY['day','month','branch','employee','category','product','sale_type','payment_type']) g;
SELECT (public.report_sales(p.today() - 365, p.today(), 'month') -> 'totals' ->> 'sales_count') AS sales_counted,
       (public.report_sales(p.today() - 365, p.today(), 'month') -> 'check' ->> 'rows_match') AS rows_match;
RESET ROLE;

SELECT label, min(ms) AS best_ms, round(avg(ms) FILTER (WHERE run > 1), 1) AS warm_avg_ms, max(ms) AS worst_ms,
       (array_agg(ms ORDER BY run))[1] AS cold_ms
FROM p.ms GROUP BY label ORDER BY min(label);
DROP SCHEMA p CASCADE;
