-- D01 timing proof (D87): how long public.get_owner_dashboard() takes (a) on the dev seed shop as it is
-- and (b) on the same shop after a generated data set of 50 000 sales (1 000 of them today), 5 000
-- contracts with 12 schedule lines each (most of them late) and 300 collections today.
-- Local stack only. Everything runs inside BEGIN ... ROLLBACK, so nothing stays behind:
--   docker exec -i supabase_db_ecofin-api psql -U postgres -v ON_ERROR_STOP=1 < scripts/d01-dashboard-timing.sql
-- Prints the milliseconds of 7 runs (the first is cold) for all branches and for the main branch.
BEGIN;
CREATE SCHEMA p;
CREATE FUNCTION p.as_owner() RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000011',false),
         set_config('app.org_id','',false),
         set_config('request.headers','{"x-org-id":"d1000000-0000-0000-0000-000000000001"}',false) $$;
CREATE TABLE p.ms(label text, run int, ms numeric);
CREATE FUNCTION p.time_it(p_label text, p_branch uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE i int; t0 timestamptz; r jsonb;
BEGIN
  FOR i IN 1..7 LOOP
    t0 := clock_timestamp();
    r := public.get_owner_dashboard(p_branch);
    INSERT INTO p.ms VALUES (p_label, i, round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1));
  END LOOP;
END $$;
GRANT USAGE ON SCHEMA p TO authenticated;
GRANT ALL ON p.ms TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA p TO authenticated;

SELECT p.as_owner();
SET ROLE authenticated;
SELECT p.time_it('seed shop, all branches', NULL);
SELECT p.time_it('seed shop, main branch', (SELECT id FROM public.branches WHERE is_main LIMIT 1));
RESET ROLE;

-- The generated data set, as the database owner (triggers off for the bulk insert only).
SET session_replication_role = replica;
INSERT INTO public.customers(organization_id, full_name, phones, credit_limit, status)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf customer ' || g, ARRAY['0100000' || lpad(g::text, 4, '0')], 100000, 'active'
  FROM generate_series(1, 500) g;
INSERT INTO public.cash_accounts(organization_id, name, kind, branch_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf safe', 'safe', id FROM public.branches
  WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND is_main;
INSERT INTO public.installment_policies(organization_id, version, max_months, markup_tiers)
  VALUES ('d1000000-0000-0000-0000-000000000001', 9001, 24, '[{"pct":20,"up_to_months":24}]');
INSERT INTO public.sales(organization_id, number, branch_id, kind, is_b2b, prices_include_vat, subtotal, total, business_date, idempotency_key, issued_at)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'PERF-S-' || g, (SELECT id FROM public.branches WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND is_main),
         'pos', false, true, 100 + g % 900, 100 + g % 900,
         CASE WHEN g <= 1000 THEN app.org_today('d1000000-0000-0000-0000-000000000001') ELSE app.org_today('d1000000-0000-0000-0000-000000000001') - (1 + g % 120) END,
         'perf-sale-' || g, now()
  FROM generate_series(1, 50000) g;
WITH pay AS (
  INSERT INTO public.payments(organization_id, number, branch_id, direction, method, amount, business_date, idempotency_key, cash_account_id)
  SELECT s.organization_id, 'PERF-P-' || s.number, s.branch_id, 'in', 'cash', s.total, s.business_date, 'perf-pay-' || s.number,
         (SELECT a.id FROM public.cash_accounts a WHERE a.organization_id = s.organization_id AND a.name = 'Perf safe')
  FROM public.sales s WHERE s.number LIKE 'PERF-S-%' AND s.business_date = app.org_today(s.organization_id)
  RETURNING id, idempotency_key, amount
)
INSERT INTO public.payment_allocations(organization_id, payment_id, amount, sale_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', pay.id, pay.amount,
         (SELECT s.id FROM public.sales s WHERE s.organization_id = 'd1000000-0000-0000-0000-000000000001' AND s.idempotency_key = replace(pay.idempotency_key, 'perf-pay-PERF-S-', 'perf-sale-'))
  FROM pay;
INSERT INTO public.contracts(organization_id, number, customer_id, branch_id, policy_id, creditor, cash_price, down_payment, financed_amount, markup_pct, markup_amount,
                             total_payable, installments_count, frequency, first_due_date, idempotency_key, sale_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'PERF-C-' || g,
         (SELECT id FROM public.customers WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND full_name = 'Perf customer ' || (1 + g % 500)),
         (SELECT id FROM public.branches WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND is_main),
         (SELECT id FROM public.installment_policies WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND version = 9001),
         'in_house', 12000, 2000, 10000, 20, 2000, 12000, 12, 'monthly',
         app.org_today('d1000000-0000-0000-0000-000000000001') - (g % 330), 'perf-contract-' || g,
         (SELECT x.id FROM public.sales x WHERE x.organization_id = 'd1000000-0000-0000-0000-000000000001' AND x.idempotency_key = 'perf-sale-' || (1000 + g))
  FROM generate_series(1, 5000) g;
INSERT INTO public.schedule_lines(organization_id, contract_id, version, seq, due_date, principal, profit)
  SELECT c.organization_id, c.id, 1, s.n, c.first_due_date + (s.n - 1) * 30, 833.33, 166.67
  FROM public.contracts c CROSS JOIN generate_series(1, 12) s(n)
  WHERE c.number LIKE 'PERF-C-%';
INSERT INTO public.payments(organization_id, number, branch_id, direction, method, amount, business_date, idempotency_key, collection_id, cash_account_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'PERF-COL-' || g, (SELECT id FROM public.branches WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND is_main),
         'in', 'cash', 1000, app.org_today('d1000000-0000-0000-0000-000000000001'), 'perf-col-' || g, gen_random_uuid(),
         (SELECT a.id FROM public.cash_accounts a WHERE a.organization_id = 'd1000000-0000-0000-0000-000000000001' AND a.name = 'Perf safe')
  FROM generate_series(1, 300) g;
UPDATE public.payments SET collection_id = id WHERE number LIKE 'PERF-COL-%';
SET session_replication_role = origin;
ANALYZE public.sales; ANALYZE public.contracts; ANALYZE public.schedule_lines; ANALYZE public.payments; ANALYZE public.payment_allocations;

SELECT p.as_owner();
SET ROLE authenticated;
SELECT p.time_it('50k sales / 5k contracts, all branches', NULL);
SELECT p.time_it('50k sales / 5k contracts, main branch', (SELECT id FROM public.branches WHERE is_main LIMIT 1));
SELECT (public.get_owner_dashboard() -> 'tiles' -> 'sales_today') AS sales_today,
       (public.get_owner_dashboard() -> 'tiles' -> 'overdue') AS overdue,
       (public.get_owner_dashboard() -> 'tiles' -> 'collections_today') AS collections;
RESET ROLE;

SELECT label, min(ms) AS best_ms, round(avg(ms) FILTER (WHERE run > 1), 1) AS warm_avg_ms, max(ms) AS worst_ms,
       (array_agg(ms ORDER BY run))[1] AS cold_ms
FROM p.ms GROUP BY label ORDER BY min(label);
ROLLBACK;
