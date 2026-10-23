-- D03 receivables aging (EC-95, D91).
-- Run by: node scripts/db-smoke.mjs supabase/tests/d03_receivables_aging_test.sql (inside BEGIN ... ROLLBACK).
-- Shop a sells six TVs on installments (12 000 = 2 000 down + 10 000 financed + 2 000 profit, 12 monthly lines
-- of 1 000) to five customers with two collectors (two customers have none), in two branches, with a policy of
-- 3 grace days. The clock can't move in a test: t.place() dates a contract's lines that many days ago (shop
-- date), the other lines stay in the future. Then: a line inside grace, lines on every bucket edge (4, 30, 31,
-- 60, 61, 90, 91, 100 days late), a partly paid line (profit paid first), a rescheduled contract (only the new
-- version counts), a migrated contract, and a completed, a written-off and a returned contract (all out).
-- Worked by hand (open contracts k1..k6):
--   k1 c1 main   [3]          not_due 12 000                                       outstanding 12 000
--   k2 c1 main   [30, 4]      late_1_30 2 000, not_due 10 000                      outstanding 12 000
--   k3 c2 main   [60, 31]     line 1 paid 300 -> late_31_60 700 + 1 000, not_due 10 000   11 700
--   k4 c3 second [91, 90, 61] late_90_plus 1 000, late_61_90 2 000, not_due 9 000  outstanding 12 000
--   k5 c4 main   rescheduled to 6 lines of 1 000 (800 + 200), [45]: late_31_60 1 000, not_due 5 000   6 000
--   k6 c5 second migrated, [100]: late_90_plus 1 000, not_due 11 000             outstanding 12 000
--   total 65 700 = not_due 57 000 + 1-30 2 000 + 31-60 2 700 + 61-90 2 000 + 90+ 2 000
-- Every grouping is checked against these numbers, the totals against the balance and aging views, the
-- customer rows against R02, the late buckets against the overdue list, and the filters, sorting, paging,
-- permissions and isolation.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from n04_overdue_tracking_test.sql).
CREATE FUNCTION t.pos(p_branch uuid, p_device uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_org uuid := app.current_org_id(); v_id uuid := p_device; v_hash text;
BEGIN
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch AND b.organization_id = v_org) THEN
    RETURN NULL;
  END IF;
  IF v_id IS NULL THEN
    SELECT d.id INTO v_id FROM public.devices d
    WHERE d.organization_id = v_org AND d.branch_id = p_branch AND d.is_active AND d.archived_at IS NULL AND d.name LIKE 'Test POS %'
      AND NOT EXISTS (SELECT 1 FROM public.shifts s WHERE s.device_id = d.id AND s.status = 'open')
    ORDER BY d.name LIMIT 1;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.devices (organization_id, branch_id, name) VALUES (v_org, p_branch, 'Test POS ' || gen_random_uuid())
    RETURNING id INTO v_id;
  END IF;
  UPDATE public.devices d
     SET token_hash = COALESCE(d.token_hash, encode(sha256(convert_to(d.id::text, 'UTF8')), 'hex')),
         paired_at = COALESCE(d.paired_at, now())
   WHERE d.id = v_id AND d.organization_id = v_org
  RETURNING d.token_hash INTO v_hash;
  PERFORM set_config('request.headers',
    (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb
       || jsonb_build_object('x-device-id', v_id, 'x-device-token-hash', v_hash))::text, false);
  RETURN v_id;
END $$;
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(p_branch, NULL);
  RETURN public.open_shift(p_branch, p_float, p_key, NULL, NULL);
END $$;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE TABLE t.docs(tag text,j jsonb);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE (jsonb_build_object('x-org-id',o) || COALESCE((SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.employees e ON e.id=s.employee_id JOIN public.devices d ON d.id=s.device_id WHERE s.organization_id=o AND s.status='open' AND d.is_active AND d.archived_at IS NULL AND d.token_hash IS NOT NULL ORDER BY (e.auth_user_id::text=u) DESC,s.opened_at DESC,s.id DESC LIMIT 1),'{}'::jsonb))::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
CREATE FUNCTION t.pv() RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT (app.current_installment_policy(t.org('a'))).version $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
-- Lines 1..n of a contract's current version become due days[1..n] ago (shop date); the others stay as they are.
CREATE FUNCTION t.place(c text,VARIADIC days integer[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE i integer;
BEGIN
  SET LOCAL session_replication_role = replica;
  FOR i IN 1..array_length(days,1) LOOP
    UPDATE public.schedule_lines SET due_date=t.today()-days[i] WHERE contract_id=t.id(c) AND seq=i AND NOT superseded;
  END LOOP;
  SET LOCAL session_replication_role = origin;
END $$;
-- An installment sale (N02) with the commit-time checks run now.
CREATE FUNCTION t.sell(p_customer text,p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),
    'expected_total','12000.00','customer_id',t.id(p_customer),
    'terms',jsonb_build_object('down_payment','2000.00','installments_count',12,'frequency','monthly','policy_version',t.pv())),p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
-- The cashier pays one contract in cash (N03).
CREATE FUNCTION t.pay(c text,cust text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_collection(jsonb_build_object('customer_id',t.id(cust),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id(c),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
-- One row of a report by its key; does it contain the expected members; the keys in order.
CREATE FUNCTION t.row(d jsonb,k text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT r FROM jsonb_array_elements(d->'rows') r WHERE r->>'key'=k $$;
CREATE FUNCTION t.has(d jsonb,k text,e jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(t.row(d,k) @> e,false) $$;
CREATE FUNCTION t.keys(d jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(r->>'key',',' ORDER BY ord),'') FROM jsonb_array_elements(d->'rows') WITH ORDINALITY x(r,ord) $$;
-- The row keys as tags (customers, branches, collectors, contracts) for readable comparisons.
CREATE FUNCTION t.tags(d jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(COALESCE((SELECT i.tag FROM t.ids i WHERE i.id::text=r->>'key' LIMIT 1),r->>'key'),',' ORDER BY ord),'')
  FROM jsonb_array_elements(d->'rows') WITH ORDINALITY x(r,ord) $$;
-- Σ of a money member over the rows (numeric, to compare with the totals).
CREATE FUNCTION t.sum(d jsonb,m text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(sum((r->>m)::numeric),0) FROM jsonb_array_elements(d->'rows') r $$;
CREATE FUNCTION t.m(o jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('outstanding',o->>'outstanding','not_due',o->>'not_due','late_1_30',o->>'late_1_30',
    'late_31_60',o->>'late_31_60','late_61_90',o->>'late_61_90','late_90_plus',o->>'late_90_plus') $$;
CREATE FUNCTION t.b(outstanding text,nd text,l30 text,l60 text,l90 text,l90p text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('outstanding',outstanding,'not_due',nd,'late_1_30',l30,'late_31_60',l60,'late_61_90',l90,'late_90_plus',l90p) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a and b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('D03 '||s,'d03-key-'||s,'retail_pro','Owner',s||'d03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('f',64)),('b',repeat('g',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a0300000-0000-0000-8000-000000000001','ad03@example.com'),('a0300000-0000-0000-8000-000000000002','bd03@example.com'),
  ('a0300000-0000-0000-8000-000000000003','d03cashier@example.com'),('a0300000-0000-0000-8000-000000000004','d03accountant@example.com'),
  ('a0300000-0000-0000-8000-000000000005','d03col1@example.com'),('a0300000-0000-0000-8000-000000000006','d03col2@example.com');
SELECT public.accept_invite(repeat('f',64),'a0300000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('g',64),'a0300000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main-b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'owner-b',id FROM public.employees WHERE organization_id=t.org('b') AND role='OWNER';
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0 WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id=t.org('a');
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"D3-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',30)),'d03-key-found');
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0300000-0000-0000-8000-000000000003','D03 Cashier','CASHIER');
SELECT t.emp('accountant','a0300000-0000-0000-8000-000000000004','D03 Accountant','ACCOUNTANT');
SELECT t.emp('col1','a0300000-0000-0000-8000-000000000005','D03 Collector One','COLLECTOR');
SELECT t.emp('col2','a0300000-0000-0000-8000-000000000006','D03 Collector Two','COLLECTOR');
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text,p_collector text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id,collector_id)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,'active','291010101003'||right(p_phone,2),t.id(p_collector)) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('c1','Amal Aging','01022220001','col1');
SELECT t.cust('c2','Bahaa Behind','01022220002','col1');
SELECT t.cust('c3','Dina Deep','01022220003','col2');
SELECT t.cust('c4','Fady Fresh','01022220004',NULL);
SELECT t.cust('c5','Hoda Heritage','01022220005',NULL);
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
  VALUES(t.org('b'),'Shop B Customer',ARRAY['01033330001'],1000,'active','29101010100399');
INSERT INTO t.ids SELECT 'cust-b',id FROM public.customers WHERE organization_id=t.org('b');
-- The policy: 20 % up to 24 months, 3 grace days, no guarantor or survey needed below 1 000 000.
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');

SELECT t.as_user('a0300000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','d03-key-shift');
INSERT INTO t.docs SELECT 's-'||k,t.sell(c,'d03-key-sale-'||k)
  FROM (VALUES('k1','c1'),('k2','c1'),('k3','c2'),('k4','c3'),('k5','c4'),('k6','c5'),('k7','c5'),('k8','c4'),('k9','c2')) v(k,c);
RESET ROLE;
INSERT INTO t.ids SELECT k,(t.doc('s-'||k)->'contract'->>'id')::uuid FROM unnest(ARRAY['k1','k2','k3','k4','k5','k6','k7','k8','k9']) k;
SELECT t.expect('setup: nine contracts of 12 lines of 1 000 each, every line in the future, 3 grace days',
  (SELECT count(*)=9 FROM public.contracts WHERE organization_id=t.org('a'))
  AND (SELECT count(*)=108 AND bool_and(amount=1000) AND min(due_date)>t.today() FROM public.schedule_lines WHERE organization_id=t.org('a'))
  AND (SELECT ip.grace_days=3 FROM public.contracts c JOIN public.installment_policies ip ON ip.id=c.policy_id WHERE c.id=t.id('k1')));

-- Time passes (decision 4's edges).
SELECT t.place('k1',3);
SELECT t.place('k2',30,4);
SELECT t.place('k3',60,31);
SELECT t.place('k4',91,90,61);
SELECT t.place('k6',100);
-- k3: the customer pays 300 on its oldest line (profit first).
SELECT t.as_user('a0300000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'pay-k3',t.pay('k3','c2','300','d03-key-pay-k3');
RESET ROLE;
-- k5 is rescheduled (N05's version mechanics, made by hand): version 1 superseded, version 2 = 6 lines of
-- 1 000 (800 principal + 200 profit), its first line 45 days late.
SET session_replication_role = replica;
UPDATE public.schedule_lines SET superseded=true WHERE contract_id=t.id('k5');
INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit)
  SELECT t.org('a'),t.id('k5'),2,i,CASE WHEN i=1 THEN t.today()-45 ELSE t.today()+30*i END,800,200 FROM generate_series(1,6) i;
UPDATE public.contracts SET status='rescheduled',current_version=2 WHERE id=t.id('k5');
-- k4 and k6 belong to the second branch; k6 is an M02 opening contract.
UPDATE public.contracts SET branch_id=t.id('second') WHERE id IN (t.id('k4'),t.id('k6'));
UPDATE public.contracts SET is_migrated=true WHERE id=t.id('k6');
-- Closed contracts, all of them late: completed, written off, returned.
UPDATE public.contracts SET status='completed',closed_at=now() WHERE id=t.id('k8');
UPDATE public.contracts SET status='written_off',closed_at=now() WHERE id=t.id('k7');
UPDATE public.contracts SET status='returned',closed_at=now() WHERE id=t.id('k9');
SET session_replication_role = origin;
SELECT t.place('k7',95);
SELECT t.place('k8',40);
SELECT t.place('k9',20);
SELECT t.expect('setup: k3''s first line is partly paid, profit first (the view)',
  (SELECT paid=300 AND paid_profit=profit AND remaining=700 AND status='overdue' AND days_late=60
   FROM public.v_schedule_line_status WHERE contract_id=t.id('k3') AND seq=1 AND NOT superseded));

-- ---------------------------------------------------------------- the reports (owner of shop a)
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'customer',public.report_receivables('customer');
INSERT INTO t.docs SELECT 'branch',public.report_receivables('branch');
INSERT INTO t.docs SELECT 'collector',public.report_receivables('collector');
INSERT INTO t.docs SELECT 'contract',public.report_receivables('contract');
INSERT INTO t.docs SELECT 'overdue-list',public.list_overdue_contracts('{"limit":1}');
INSERT INTO t.docs SELECT 'overdue-main',public.list_overdue_contracts(jsonb_build_object('branch_id',t.id('main'),'limit',1));
INSERT INTO t.docs SELECT 'overdue-col1',public.list_overdue_contracts(jsonb_build_object('collector_id',t.id('col1'),'limit',1));
INSERT INTO t.docs SELECT 'r-main',public.report_receivables('customer',t.id('main'));
INSERT INTO t.docs SELECT 'r-col1',public.report_receivables('customer',NULL,t.id('col1')::text);
INSERT INTO t.docs SELECT 'r-none',public.report_receivables('customer',NULL,'none');
INSERT INTO t.docs SELECT 'drill-c1',public.report_receivables('contract',NULL,NULL,t.id('c1'));
INSERT INTO t.docs SELECT 'min61',public.report_receivables('contract',NULL,NULL,NULL,NULL,61);
INSERT INTO t.docs SELECT 'q',public.report_receivables('customer',NULL,NULL,NULL,'bahaa');
INSERT INTO t.docs SELECT 'q-phone',public.report_receivables('contract',NULL,NULL,NULL,'2220003');
INSERT INTO t.docs SELECT 'p1',public.report_receivables('customer',NULL,NULL,NULL,NULL,NULL,'outstanding_desc',1,2);
INSERT INTO t.docs SELECT 'p2',public.report_receivables('customer',NULL,NULL,NULL,NULL,NULL,'outstanding_desc',2,2);
INSERT INTO t.docs SELECT 'asc',public.report_receivables('customer',NULL,NULL,NULL,NULL,NULL,'outstanding_asc');
INSERT INTO t.docs SELECT 'key',public.report_receivables('customer',NULL,NULL,NULL,NULL,NULL,'key_asc');
INSERT INTO t.docs SELECT 'l90p',public.report_receivables('customer',NULL,NULL,NULL,NULL,NULL,'late_90_plus_desc');
INSERT INTO t.docs SELECT 'days',public.report_receivables('contract',NULL,NULL,NULL,NULL,NULL,'max_days_late_desc');
INSERT INTO t.docs SELECT 'overdue',public.report_receivables('collector',NULL,NULL,NULL,NULL,NULL,'overdue_desc');
RESET ROLE;

-- ================================================================ totals (the slice's Done when)
SELECT t.expect('done when: the total equals the sum of the open contract balances (65 700), the buckets add up',
  t.m(t.doc('customer')->'totals')=t.b('65700.00','57000.00','2000.00','2700.00','2000.00','2000.00')
  AND (t.doc('customer')->'totals'->>'outstanding')::numeric=(SELECT sum(remaining) FROM public.v_contract_balances
                                                              WHERE organization_id=t.org('a') AND status IN ('active','rescheduled')),
  (t.doc('customer')->'totals')::text);
SELECT t.expect('done when: every grouping''s rows add up to the totals, and the check says so',
  (SELECT bool_and(t.sum(t.doc(g),'outstanding')=65700 AND t.sum(t.doc(g),'not_due')=57000 AND t.sum(t.doc(g),'late_1_30')=2000
                   AND t.sum(t.doc(g),'late_31_60')=2700 AND t.sum(t.doc(g),'late_61_90')=2000 AND t.sum(t.doc(g),'late_90_plus')=2000
                   AND (t.doc(g)->'check'->>'rows_match')::boolean
                   AND (t.doc(g)->'check'->>'contracts_checked')::int=6 AND (t.doc(g)->'check'->>'contracts_without_schedule')::int=0
                   AND t.doc(g)->'totals'=t.doc('customer')->'totals')
   FROM unnest(ARRAY['customer','branch','collector','contract']) g));
SELECT t.expect('totals: principal and profit from the balance view, counts, overdue %, the oldest due date, no fee member',
  (t.doc('customer')->'totals'->>'principal')::numeric=(SELECT sum(principal_outstanding) FROM public.v_contract_balances
                                                        WHERE organization_id=t.org('a') AND status IN ('active','rescheduled'))
  AND (t.doc('customer')->'totals'->>'principal')::numeric+(t.doc('customer')->'totals'->>'profit')::numeric=65700
  AND t.doc('customer')->'totals' @> jsonb_build_object('overdue','8700.00','overdue_pct','13.2','contracts',6,'customers',5,
        'overdue_contracts',5,'max_days_late',100,'migrated_contracts',1,'oldest_due_date',t.today()-100)
  AND NOT (t.doc('customer')->'totals' ? 'fees_due'),
  (t.doc('customer')->'totals')::text);
SELECT t.expect('totals: each bucket split into principal and profit (from the status view)',
  (SELECT bool_and((b.value->>'principal')::numeric+(b.value->>'profit')::numeric=(b.value->>'amount')::numeric)
   FROM jsonb_each(t.doc('customer')->'totals'->'buckets') b)
  AND t.doc('customer')->'totals'->'buckets'->'late_31_60'->>'amount'='2700.00'
  AND (t.doc('customer')->'totals'->'buckets'->'late_31_60'->>'principal')::numeric
      =(SELECT sum(principal_remaining) FROM public.v_schedule_line_status
        WHERE contract_id IN (t.id('k3'),t.id('k5')) AND NOT superseded AND status='overdue' AND days_late BETWEEN 31 AND 60),
  (t.doc('customer')->'totals'->'buckets')::text);

-- ================================================================ rows by hand
SELECT t.expect('customer: c1 24 000 (k1 in grace + k2), c2 11 700, c3 12 000, c4 6 000, c5 12 000 (closed contracts out)',
  t.has(t.doc('customer'),t.id('c1')::text,t.b('24000.00','22000.00','2000.00','0.00','0.00','0.00') || '{"contracts":2,"customers":1,"overdue_contracts":1,"max_days_late":30}')
  AND t.has(t.doc('customer'),t.id('c2')::text,t.b('11700.00','10000.00','0.00','1700.00','0.00','0.00') || '{"contracts":1,"max_days_late":60}')
  AND t.has(t.doc('customer'),t.id('c3')::text,t.b('12000.00','9000.00','0.00','0.00','2000.00','1000.00') || '{"max_days_late":91}')
  AND t.has(t.doc('customer'),t.id('c4')::text,t.b('6000.00','5000.00','0.00','1000.00','0.00','0.00') || '{"contracts":1,"max_days_late":45}')
  AND t.has(t.doc('customer'),t.id('c5')::text,t.b('12000.00','11000.00','0.00','0.00','0.00','1000.00') || '{"contracts":1,"migrated_contracts":1}')
  AND (t.doc('customer')->>'total_count')::int=5,
  (t.doc('customer')->'rows')::text);
SELECT t.expect('customer: the row carries the customer, the first phone and the collector (null when none)',
  t.has(t.doc('customer'),t.id('c1')::text,jsonb_build_object('label','Amal Aging','sub_label','01022220001',
        'customer',jsonb_build_object('id',t.id('c1'),'name','Amal Aging','phone','01022220001'),
        'collector',jsonb_build_object('id',t.id('col1'),'name','D03 Collector One')))
  AND t.row(t.doc('customer'),t.id('c4')::text)->'collector'='null'::jsonb,
  t.row(t.doc('customer'),t.id('c1')::text)::text);
SELECT t.expect('customer: principal + profit = outstanding and the buckets add up on every row',
  (SELECT bool_and((r->>'principal')::numeric+(r->>'profit')::numeric=(r->>'outstanding')::numeric
                   AND (r->>'not_due')::numeric+(r->>'overdue')::numeric=(r->>'outstanding')::numeric)
   FROM unnest(ARRAY['customer','branch','collector','contract']) g, jsonb_array_elements(t.doc(g)->'rows') r));
SELECT t.expect('customer: last payment shown for c2 (the 300 on k3), none for c1',
  t.row(t.doc('customer'),t.id('c2')::text)->>'last_payment_at' IS NOT NULL
  AND t.row(t.doc('customer'),t.id('c1')::text)->'last_payment_at'='null'::jsonb);
SELECT t.expect('branch: the contract''s branch: main 41 700 (k1 k2 k3 k5), second 24 000 (k4 k6), with codes',
  t.has(t.doc('branch'),t.id('main')::text,t.b('41700.00','37000.00','2000.00','2700.00','0.00','0.00') || '{"contracts":4,"customers":3}')
  AND t.has(t.doc('branch'),t.id('second')::text,t.b('24000.00','20000.00','0.00','0.00','2000.00','2000.00')
            || jsonb_build_object('sub_label','S2','branch',jsonb_build_object('id',t.id('second'),'name','Second','code','S2')))
  AND (t.doc('branch')->>'total_count')::int=2,
  (t.doc('branch')->'rows')::text);
SELECT t.expect('collector: the customer''s current collector: col1 35 700 (c1 c2), col2 12 000, none 18 000 (c4 c5)',
  t.has(t.doc('collector'),t.id('col1')::text,t.b('35700.00','32000.00','2000.00','1700.00','0.00','0.00') || '{"customers":2,"contracts":3,"label":"D03 Collector One"}')
  AND t.has(t.doc('collector'),t.id('col2')::text,t.b('12000.00','9000.00','0.00','0.00','2000.00','1000.00'))
  AND t.has(t.doc('collector'),'none',t.b('18000.00','16000.00','0.00','1000.00','0.00','1000.00') || '{"customers":2,"collector":null,"label":null}'),
  (t.doc('collector')->'rows')::text);
SELECT t.expect('contract: six rows; each equals the aging view and the balance view of that contract',
  (t.doc('contract')->>'total_count')::int=6
  AND (SELECT bool_and(t.row(t.doc('contract'),a.contract_id::text) @> t.b(cb.remaining::text,a.not_yet_due::text,a.late_1_30::text,
                         a.late_31_60::text,a.late_61_90::text,a.late_90_plus::text)
                       AND (t.row(t.doc('contract'),a.contract_id::text)->>'principal')::numeric=cb.principal_outstanding)
       FROM public.v_receivables_aging a JOIN public.v_contract_balances cb ON cb.contract_id=a.contract_id
       WHERE a.organization_id=t.org('a')),
  (t.doc('contract')->'rows')::text);
SELECT t.expect('contract: the row names the contract, its customer and branch, migrated flag and next due date',
  t.has(t.doc('contract'),t.id('k6')::text,jsonb_build_object('label',(SELECT number FROM public.contracts WHERE id=t.id('k6')),
        'sub_label','Hoda Heritage','contract',jsonb_build_object('id',t.id('k6'),'is_migrated',true,'frequency','monthly',
        'status','active','next_due_date',t.today()-100),
        'customer',jsonb_build_object('id',t.id('c5')),'branch',jsonb_build_object('id',t.id('second'),'code','S2')))
  AND t.has(t.doc('contract'),t.id('k5')::text,'{"contract":{"status":"rescheduled"},"outstanding":"6000.00"}')
  AND t.row(t.doc('contract'),t.id('k7')::text) IS NULL AND t.row(t.doc('contract'),t.id('k8')::text) IS NULL
  AND t.row(t.doc('contract'),t.id('k9')::text) IS NULL,
  t.row(t.doc('contract'),t.id('k6')::text)::text);
SELECT t.expect('grace: k1''s line 3 days late is not due; k2''s line 4 days late is late 1-30 (N04)',
  t.has(t.doc('contract'),t.id('k1')::text,'{"not_due":"12000.00","overdue":"0.00","overdue_contracts":0,"max_days_late":null}')
  AND t.has(t.doc('contract'),t.id('k2')::text,'{"late_1_30":"2000.00","max_days_late":30}'));
SELECT t.expect('edges: 30 and 31, 60 and 61, 90 and 91 days late fall in their buckets',
  t.has(t.doc('contract'),t.id('k2')::text,'{"late_1_30":"2000.00","late_31_60":"0.00"}')
  AND t.has(t.doc('contract'),t.id('k3')::text,'{"late_31_60":"1700.00","late_61_90":"0.00"}')
  AND t.has(t.doc('contract'),t.id('k4')::text,'{"late_61_90":"2000.00","late_90_plus":"1000.00"}'));

-- ================================================================ the same numbers as the other screens
SELECT t.expect('overdue list: the late buckets equal list_overdue_contracts'' totals (all, one branch, one collector)',
  (t.doc('overdue-list')->'totals'->>'overdue_amount')::numeric=t.sum(t.doc('customer'),'overdue')
  AND t.doc('overdue-list')->'totals' @> jsonb_build_object('late_1_30',t.doc('customer')->'totals'->>'late_1_30',
        'late_31_60',t.doc('customer')->'totals'->>'late_31_60','late_61_90',t.doc('customer')->'totals'->>'late_61_90',
        'late_90_plus',t.doc('customer')->'totals'->>'late_90_plus')
  AND (t.doc('overdue-main')->'totals'->>'overdue_amount')::numeric=(t.doc('r-main')->'totals'->>'overdue')::numeric
  AND (t.doc('overdue-col1')->'totals'->>'overdue_amount')::numeric=(t.doc('r-col1')->'totals'->>'overdue')::numeric
  AND (t.doc('r-main')->'check'->>'rows_match')::boolean AND (t.doc('r-col1')->'check'->>'rows_match')::boolean,
  concat_ws(' / ',t.doc('overdue-list')->'totals',t.doc('overdue-main')->'totals',t.doc('overdue-col1')->'totals'));
SELECT t.expect('R02: each customer row equals the customer page''s open balance and aging buckets',
  (SELECT bool_and((r->>'outstanding')::numeric=(app.customer_open_balance(t.org('a'),(r->>'key')::uuid)->>'open_balance')::numeric
                   AND app.customer_overdue_json(t.org('a'),(r->>'key')::uuid)->'aging'
                       =jsonb_build_object('not_yet_due',r->>'not_due','late_1_30',r->>'late_1_30','late_31_60',r->>'late_31_60',
                                           'late_61_90',r->>'late_61_90','late_90_plus',r->>'late_90_plus'))
   FROM jsonb_array_elements(t.doc('customer')->'rows') r));

-- ================================================================ filters and drill-down
SELECT t.expect('filter: one branch; its totals and check cover that branch only',
  t.tags(t.doc('r-main'))='c1,c2,c4' AND t.doc('r-main')->'totals'->>'outstanding'='41700.00'
  AND (t.doc('r-main')->'check'->>'rows_match')::boolean AND (t.doc('r-main')->'check'->>'contracts_checked')::int=4,
  t.tags(t.doc('r-main')));
SELECT t.expect('filter: one collector, and "none" (customers without a collector)',
  t.tags(t.doc('r-col1'))='c1,c2' AND t.doc('r-col1')->'totals'->>'outstanding'='35700.00'
  AND t.tags(t.doc('r-none'))='c5,c4' AND t.doc('r-none')->'totals'->>'outstanding'='18000.00',
  t.tags(t.doc('r-col1'))||' / '||t.tags(t.doc('r-none')));
SELECT t.expect('drill-down: a customer''s contracts (open ones only), checked',
  t.tags(t.doc('drill-c1')) IN ('k1,k2','k2,k1') AND t.doc('drill-c1')->'totals'->>'outstanding'='24000.00'
  AND (t.doc('drill-c1')->'check'->>'rows_match')::boolean,
  t.doc('drill-c1')::text);
SELECT t.expect('filter: min_days 61 keeps the contracts with a line late at least 61 days (k4, k6)',
  t.tags(t.doc('min61')) IN ('k4,k6','k6,k4') AND t.doc('min61')->'totals'->>'outstanding'='24000.00'
  AND (t.doc('min61')->'check'->>'rows_match')::boolean,
  t.tags(t.doc('min61')));
SELECT t.expect('filter: q finds a customer by name (any case) and a contract by phone',
  t.tags(t.doc('q'))='c2' AND t.tags(t.doc('q-phone'))='k4',
  t.tags(t.doc('q'))||' / '||t.tags(t.doc('q-phone')));

-- ================================================================ sorting and paging
SELECT t.expect('sort: outstanding desc, ties by name (Dina before Hoda); pages of 2',
  t.tags(t.doc('customer'))='c1,c3,c5,c2,c4' AND t.tags(t.doc('p1'))='c1,c3' AND t.tags(t.doc('p2'))='c5,c2'
  AND (t.doc('p2')->>'total_count')::int=5 AND t.doc('p2')->'totals'=t.doc('customer')->'totals'
  AND (t.doc('p2')->'check'->>'rows_match')::boolean,
  t.tags(t.doc('customer')));
SELECT t.expect('sort: outstanding asc, key asc (by name), 90+ desc, days late desc, overdue desc',
  t.tags(t.doc('asc'))='c4,c2,c3,c5,c1' AND t.tags(t.doc('key'))='c1,c2,c3,c4,c5'
  AND t.tags(t.doc('l90p')) LIKE 'c3,c5,%' AND t.tags(t.doc('days')) LIKE 'k6,k4,k3,k5,k2,%'
  AND t.tags(t.doc('overdue'))='col1,col2,none',
  concat_ws(' / ',t.tags(t.doc('asc')),t.tags(t.doc('key')),t.tags(t.doc('l90p')),t.tags(t.doc('days')),t.tags(t.doc('overdue'))));
SELECT t.expect('answer: as of the shop''s today, with the query echoed',
  t.doc('r-col1') @> jsonb_build_object('as_of',t.today(),'group_by','customer','sort','outstanding_desc','page',1,'page_size',50,
                                        'filters',jsonb_build_object('collector_id',t.id('col1')::text,'branch_id',NULL)));

-- ================================================================ validation
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('validation: unknown group_by','SELECT public.report_receivables(''product'')','VALIDATION_FAILED');
SELECT t.error('validation: q only with customer or contract','SELECT public.report_receivables(''branch'',NULL,NULL,NULL,''amal'')','VALIDATION_FAILED');
SELECT t.error('validation: q longer than 100','SELECT public.report_receivables(''customer'',NULL,NULL,NULL,repeat(''a'',101))','VALIDATION_FAILED');
SELECT t.error('validation: min_days 0','SELECT public.report_receivables(''customer'',NULL,NULL,NULL,NULL,0)','VALIDATION_FAILED');
SELECT t.error('validation: collector not a uuid or none','SELECT public.report_receivables(''customer'',NULL,''nobody'')','VALIDATION_FAILED');
SELECT t.error('validation: unknown sort','SELECT public.report_receivables(''customer'',NULL,NULL,NULL,NULL,NULL,''profit_desc'')','VALIDATION_FAILED');
SELECT t.error('validation: page size above 1000','SELECT public.report_receivables(''customer'',NULL,NULL,NULL,NULL,NULL,NULL,1,1001)','VALIDATION_FAILED');
SELECT t.error('validation: page 0','SELECT public.report_receivables(''customer'',NULL,NULL,NULL,NULL,NULL,NULL,0)','VALIDATION_FAILED');

-- ================================================================ isolation: another shop's ids
SELECT t.error('isolation: shop b''s branch is not found',format('SELECT public.report_receivables(''customer'',%L)',t.id('main-b')),'BRANCH_NOT_FOUND');
SELECT t.error('isolation: shop b''s employee as collector is not found',format('SELECT public.report_receivables(''customer'',NULL,%L)',t.id('owner-b')),'EMPLOYEE_NOT_FOUND');
SELECT t.error('isolation: shop b''s customer is not found',format('SELECT public.report_receivables(''contract'',NULL,NULL,%L)',t.id('cust-b')),'CUSTOMER_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0300000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shop-b',public.report_receivables('customer');
RESET ROLE;
SELECT t.expect('isolation: shop b sees none of shop a''s balances',
  t.doc('shop-b')->'rows'='[]'::jsonb AND t.doc('shop-b')->'totals'->>'outstanding'='0.00'
  AND (t.doc('shop-b')->'check'->>'contracts_checked')::int=0,
  t.doc('shop-b')::text);

-- ================================================================ who sees it
SELECT t.as_user('a0300000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('permission: a cashier (no report.financial) is refused','SELECT public.report_receivables(''customer'')','PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0300000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('permission: a collector is refused (the overdue list is theirs)','SELECT public.report_receivables(''customer'')','PERMISSION_DENIED');
RESET ROLE;
-- The accountant (report.financial) sees only the branch they belong to.
SELECT t.as_user('a0300000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'accountant',public.report_receivables('branch');
SELECT t.error('permission: a branch the accountant can''t see is refused',format('SELECT public.report_receivables(''customer'',%L)',t.id('second')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.expect('permission: the accountant reads the report for their own branch only',
  t.tags(t.doc('accountant'))='main' AND t.doc('accountant')->'totals'->>'outstanding'='41700.00',
  t.doc('accountant')::text);
SELECT t.as_user(NULL);
SET ROLE authenticated;
SELECT t.error('permission: no signed-in employee','SELECT public.report_receivables(''customer'')','NOT_AN_EMPLOYEE');
RESET ROLE;

-- ================================================================ an expired shop still reads it
UPDATE public.organizations SET subscription_start=NULL,subscription_end=t.today()-5 WHERE id=t.org('a');
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'expired',public.report_receivables('customer');
RESET ROLE;
SELECT t.expect('an expired shop still reads its receivables',
  t.doc('expired')->'totals'=t.doc('customer')->'totals' AND t.doc('expired')->'rows'=t.doc('customer')->'rows',
  t.doc('expired')::text);

-- ================================================================ no fees (rule 4)
SELECT t.error('rule 4: a charge (late fee) can''t be recorded at all',
  format('INSERT INTO public.charges(organization_id,contract_id,schedule_line_id,assessed_on,amount) SELECT %L,contract_id,id,%L,10 FROM public.schedule_lines WHERE contract_id=%L AND seq=1 AND NOT superseded',
         t.org('a'),t.today(),t.id('k4')),'LATE_FEES_NOT_ALLOWED');

-- ================================================================ grants
SELECT t.expect('grants: the read is granted to authenticated; the measures helper to nobody',
  has_function_privilege('authenticated','public.report_receivables(text,uuid,text,uuid,text,integer,text,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.report_receivables(text,uuid,text,uuid,text,integer,text,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.receivables_measures(numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,bigint,bigint,bigint,integer,date,bigint)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
