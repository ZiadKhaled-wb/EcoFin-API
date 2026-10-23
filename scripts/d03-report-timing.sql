-- D03 timing proof (D91, decision 10): how long public.report_receivables(...) takes (a) on the dev seed shop as
-- it is and (b) after a generated data set of 20 000 open contracts (12 monthly lines of 1 000 each, so 240 000
-- schedule lines, the first lines spread from 360 days ago to 30 days ahead) for 5 000 customers in two branches,
-- with 150 000 paid lines (one cash payment each, profit then principal), in every grouping and the drill-down.
-- Local stack only. The generated data is committed and vacuumed first (as D02's script), so it stays behind:
-- run npx -y supabase@2.119.0 db reset afterwards.
--   docker exec -i supabase_db_ecofin-api psql -U postgres -v ON_ERROR_STOP=1 < scripts/d03-report-timing.sql
-- Prints the milliseconds of 5 runs (the first is cold) per grouping. Targets: < 500 ms on the seed shop,
-- < 2 s on the generated shop.
CREATE SCHEMA p;
CREATE FUNCTION p.as_owner() RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000011',false),
         set_config('app.org_id','',false),
         set_config('request.headers','{"x-org-id":"d1000000-0000-0000-0000-000000000001"}',false) $$;
CREATE TABLE p.ms(label text, run int, ms numeric);
CREATE FUNCTION p.time_it(p_label text, p_group text, p_customer uuid DEFAULT NULL, p_min integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE i int; t0 timestamptz; r jsonb;
BEGIN
  FOR i IN 1..5 LOOP
    t0 := clock_timestamp();
    r := public.report_receivables(p_group, p_customer_id => p_customer, p_min_days => p_min, p_page_size => 50);
    INSERT INTO p.ms VALUES (p_label, i, round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1));
  END LOOP;
END $$;
GRANT USAGE ON SCHEMA p TO authenticated;
GRANT ALL ON p.ms TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA p TO authenticated;

SELECT p.as_owner();
SET ROLE authenticated;
SELECT p.time_it('seed shop, ' || g, g) FROM unnest(ARRAY['customer','branch','collector','contract']) g;
RESET ROLE;

-- The generated data set, as the database owner (triggers off for the bulk insert only).
BEGIN;
SET session_replication_role = replica;
CREATE TABLE p.br AS SELECT row_number() OVER (ORDER BY id) AS n, id FROM public.branches WHERE organization_id = 'd1000000-0000-0000-0000-000000000001';
INSERT INTO public.customers(organization_id, full_name, phones, credit_limit, status, collector_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf debtor ' || g, ARRAY['0110000' || lpad(g::text, 4, '0')], 100000, 'active',
         CASE WHEN g % 3 = 0 THEN NULL ELSE (SELECT e.id FROM public.employees e WHERE e.organization_id = 'd1000000-0000-0000-0000-000000000001' ORDER BY e.id LIMIT 1) END
  FROM generate_series(1, 5000) g;
CREATE TABLE p.cu AS SELECT row_number() OVER (ORDER BY id) AS n, id FROM public.customers
  WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND full_name LIKE 'Perf debtor %';
GRANT SELECT ON p.cu TO authenticated;
INSERT INTO public.installment_policies(organization_id, version, max_months, markup_tiers, grace_days)
  VALUES ('d1000000-0000-0000-0000-000000000001', 9003, 24, '[{"pct":20,"up_to_months":24}]', 3);
INSERT INTO public.cash_accounts(organization_id, name, kind, branch_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'Perf aging safe', 'safe', id FROM public.branches
  WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND is_main;
-- 20 000 opening contracts (no sale needed): 10 000 financed + 2 000 profit, 12 lines of 833.33 / 166.67 (last line takes the rest).
INSERT INTO public.contracts(organization_id, number, customer_id, branch_id, policy_id, creditor, cash_price, down_payment, financed_amount,
                             markup_pct, markup_amount, total_payable, installments_count, frequency, first_due_date, idempotency_key, is_migrated)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'PERF-AG-' || g, (SELECT id FROM p.cu WHERE n = 1 + g % 5000),
         (SELECT id FROM p.br WHERE n = 1 + g % 2),
         (SELECT id FROM public.installment_policies WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND version = 9003),
         'in_house', 12000, 2000, 10000, 20, 2000, 12000, 12, 'monthly',
         app.org_today('d1000000-0000-0000-0000-000000000001') - 360 + (g % 390), 'perf-aging-' || g, true
  FROM generate_series(1, 20000) g;
INSERT INTO public.schedule_lines(organization_id, contract_id, version, seq, due_date, principal, profit)
  SELECT c.organization_id, c.id, 1, s, c.first_due_date + (s - 1) * 30,
         CASE WHEN s = 12 THEN 10000 - 11 * 833.33 ELSE 833.33 END, CASE WHEN s = 12 THEN 2000 - 11 * 166.67 ELSE 166.67 END
  FROM public.contracts c CROSS JOIN generate_series(1, 12) s
  WHERE c.organization_id = 'd1000000-0000-0000-0000-000000000001' AND c.number LIKE 'PERF-AG-%';
-- 150 000 paid lines: for each contract, its first lines up to 7 or 8 (whatever is due first), paid in full.
CREATE TABLE p.paid AS
  SELECT sl.id AS line_id, sl.contract_id, sl.amount, sl.principal, sl.profit, row_number() OVER (ORDER BY sl.id) AS n
  FROM public.schedule_lines sl JOIN public.contracts c ON c.id = sl.contract_id
  WHERE c.number LIKE 'PERF-AG-%' AND sl.seq <= CASE WHEN c.number::text ~ '[02468]$' THEN 8 ELSE 7 END
  LIMIT 150000;
WITH pay AS (
  INSERT INTO public.payments(organization_id, number, branch_id, direction, method, amount, business_date, idempotency_key, cash_account_id)
  SELECT 'd1000000-0000-0000-0000-000000000001', 'PERF-AGP-' || pd.n, (SELECT id FROM p.br WHERE n = 1), 'in', 'cash', pd.amount,
         app.org_today('d1000000-0000-0000-0000-000000000001'), 'perf-agpay-' || pd.n,
         (SELECT a.id FROM public.cash_accounts a WHERE a.organization_id = 'd1000000-0000-0000-0000-000000000001' AND a.name = 'Perf aging safe')
  FROM p.paid pd
  RETURNING id, idempotency_key
)
INSERT INTO public.payment_allocations(organization_id, payment_id, amount, schedule_line_id, contract_id, principal_amount, profit_amount)
  SELECT 'd1000000-0000-0000-0000-000000000001', pay.id, pd.amount, pd.line_id, pd.contract_id, pd.principal, pd.profit
  FROM pay JOIN p.paid pd ON 'perf-agpay-' || pd.n = pay.idempotency_key;
SET session_replication_role = origin;
COMMIT;
VACUUM (ANALYZE) public.contracts; VACUUM (ANALYZE) public.schedule_lines; VACUUM (ANALYZE) public.payments;
VACUUM (ANALYZE) public.payment_allocations; VACUUM (ANALYZE) public.customers;

SELECT p.as_owner();
SET ROLE authenticated;
SELECT p.time_it('20k contracts, ' || g, g) FROM unnest(ARRAY['customer','branch','collector','contract']) g;
SELECT p.time_it('20k contracts, customer, min_days 30', 'customer', NULL, 30);
SELECT p.time_it('20k contracts, drill-down one customer', 'contract', (SELECT id FROM p.cu WHERE n = 7));
SELECT p.time_it('20k contracts, contract, min_days 90', 'contract', NULL, 90);
SELECT (public.report_receivables('branch') -> 'check') AS check_branch,
       (public.report_receivables('branch') -> 'totals' ->> 'contracts') AS contracts_counted;
RESET ROLE;

SELECT label, min(ms) AS best_ms, round(avg(ms) FILTER (WHERE run > 1), 1) AS warm_avg_ms, max(ms) AS worst_ms,
       (array_agg(ms ORDER BY run))[1] AS cold_ms
FROM p.ms GROUP BY label ORDER BY min(label);
SELECT (SELECT count(*) FROM public.contracts WHERE number LIKE 'PERF-AG-%') AS contracts,
       (SELECT count(*) FROM public.schedule_lines sl JOIN public.contracts c ON c.id = sl.contract_id WHERE c.number LIKE 'PERF-AG-%') AS lines,
       (SELECT count(*) FROM public.payment_allocations pa JOIN public.payments py ON py.id = pa.payment_id WHERE py.number LIKE 'PERF-AGP-%') AS allocations;
DROP SCHEMA p CASCADE;
