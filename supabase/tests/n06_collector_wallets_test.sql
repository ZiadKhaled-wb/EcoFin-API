-- N06 collector wallets (EC-85, D81).
-- Run by: node scripts/db-smoke.mjs supabase/tests/n06_collector_wallets_test.sql (inside BEGIN ... ROLLBACK).
-- A field collection puts the cash in the collector's own wallet (no shift, no drawer) and is counted
-- once; a manager settles the wallet into a safe (partial, with a recorded shortage); the assigned
-- collector or a collector.settle holder may collect; a same-day field collection reverses while its
-- cash is still in the wallet; the route and the overdue list follow the assignment; no commission.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from n03_collections_test.sql).
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
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE (jsonb_build_object('x-org-id',o) || COALESCE((SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.employees e ON e.id=s.employee_id JOIN public.devices d ON d.id=s.device_id WHERE s.organization_id=o AND s.status='open' AND d.is_active AND d.archived_at IS NULL AND d.token_hash IS NOT NULL ORDER BY (e.auth_user_id::text=u) DESC,s.opened_at DESC,s.id DESC LIMIT 1),'{}'::jsonb))::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
CREATE FUNCTION t.pv() RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT (app.current_installment_policy(t.org('a'))).version $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
CREATE FUNCTION t.line(c text,s integer) RETURNS public.v_schedule_line_status LANGUAGE sql SECURITY DEFINER AS $$
  SELECT ls.* FROM public.v_schedule_line_status ls WHERE ls.contract_id=t.id(c) AND ls.seq=s AND NOT ls.superseded $$;
-- Days pass for one contract: its line `seq` becomes due `k` days ago (shop date), the other lines
-- and the contract's overdue actions move back by the same number of days.
CREATE FUNCTION t.late(c text,s integer,k integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE d integer;
BEGIN
  SELECT due_date-(t.today()-k) INTO d FROM public.schedule_lines WHERE contract_id=t.id(c) AND seq=s AND NOT superseded;
  SET LOCAL session_replication_role = replica;
  UPDATE public.schedule_lines SET due_date=due_date-d WHERE contract_id=t.id(c);
  UPDATE public.overdue_actions SET business_date=business_date-d WHERE contract_id=t.id(c);
  SET LOCAL session_replication_role = origin;
END $$;
-- The nightly overdue job (N04) for shop a, as the test's superuser.
CREATE FUNCTION t.run() RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN PERFORM t.as_user(NULL); RETURN public.jobs_overdue_run(t.org('a')); END $$;
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
CREATE FUNCTION t.pay(c text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_collection(jsonb_build_object('customer_id',(SELECT customer_id FROM public.contracts WHERE id=t.id(c)),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id(c),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
-- The commit-time checks, now.
CREATE FUNCTION t.commit_checks() RETURNS void LANGUAGE plpgsql AS $$
BEGIN SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED; END $$;
CREATE FUNCTION t.left(c text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.contract_remaining(t.org('a'),t.id(c)) $$;
CREATE FUNCTION t.cb(c text) RETURNS public.v_contract_balances LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.v_contract_balances WHERE contract_id=t.id(c) $$;
CREATE FUNCTION t.total(c text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.customer_contract_total(t.org('a'),t.id(c)) $$;
CREATE FUNCTION t.k(c text) RETURNS public.contracts LANGUAGE sql SECURITY DEFINER AS $$ SELECT * FROM public.contracts WHERE id=t.id(c) $$;
CREATE FUNCTION t.lines(c text,v integer) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.schedule_lines WHERE contract_id=t.id(c) AND version=v $$;
CREATE FUNCTION t.changes(c text) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.contract_changes WHERE contract_id=t.id(c) $$;
-- The customer's statement: what the rows add up to (debit - credit).
CREATE FUNCTION t.stmt(cust text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT sum(debit-credit) FROM app.customer_statement_rows(t.org('a'),t.id(cust)) $$;
CREATE FUNCTION t.stmt_kind(cust text,k text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT sum(credit) FROM app.customer_statement_rows(t.org('a'),t.id(cust)) WHERE kind=k $$;
CREATE FUNCTION t.open_balance(cust text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT (app.customer_open_balance(t.org('a'),t.id(cust))->>'open_balance')::numeric $$;
CREATE FUNCTION t.resched(c text,n integer,first_in integer,p_key text,expected text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.reschedule_contract(t.id(c),jsonb_build_object('installments_count',n,'frequency','monthly',
    'first_due_date',(t.today()+first_in)::text,'reason','Customer lost his job',
    'expected_remaining',COALESCE(expected,t.left(c)::numeric(18,2)::text)),p_key) $$;
CREATE FUNCTION t.settle(c text,waiver text,reason text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.settle_contract_early(t.id(c),jsonb_strip_nulls(jsonb_build_object('waiver',waiver,'reason',reason,
    'expected_remaining',t.left(c)::numeric(18,2)::text,
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',(t.left(c)-waiver::numeric)::numeric(18,2)::text)))),p_key) $$;
CREATE FUNCTION t.write_off(c text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.write_off_contract(t.id(c),jsonb_build_object('reason','Customer emigrated, nothing to collect',
    'expected_remaining',t.left(c)::numeric(18,2)::text),p_key) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a and b
RESET ROLE;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('N06 '||s,'n06-key-'||s,p,'Owner',s||'n06@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('v',64)),('b','retail',repeat('w',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0900000-0000-0000-8000-000000000001','an06@example.com'),('a0900000-0000-0000-8000-000000000002','bn06@example.com'),
  ('a0900000-0000-0000-8000-000000000003','n06col1@example.com'),('a0900000-0000-0000-8000-000000000004','n06col2@example.com'),
  ('a0900000-0000-0000-8000-000000000005','n06manager@example.com'),('a0900000-0000-0000-8000-000000000006','n06cashier@example.com'),
  ('a0900000-0000-0000-8000-000000000007','n06accountant@example.com'),('a0900000-0000-0000-8000-000000000008','n06warehouse@example.com'),
  ('a0900000-0000-0000-8000-000000000009','n06colb@example.com');
SELECT public.accept_invite(repeat('v',64),'a0900000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('w',64),'a0900000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',id FROM public.cash_accounts WHERE organization_id=t.org('a') AND kind='safe' AND branch_id=t.id('main');
INSERT INTO t.ids SELECT 'safe-b',id FROM public.cash_accounts WHERE organization_id=t.org('b') AND kind='safe';
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0,overdue_warning_interval_days=10
  WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'));
RESET ROLE;
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"N6-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',30)),'n06-key-found');
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,o text DEFAULT 'a') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; b uuid; BEGIN
  SELECT id INTO b FROM public.branches WHERE organization_id=t.org(o) AND is_main;
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org(o),sub,name,r,b) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org(o),v,b);
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('col1','a0900000-0000-0000-8000-000000000003','N06 Collector One','COLLECTOR');
SELECT t.emp('col2','a0900000-0000-0000-8000-000000000004','N06 Collector Two','COLLECTOR');
SELECT t.emp('manager','a0900000-0000-0000-8000-000000000005','N06 Manager','BRANCH_MANAGER');
SELECT t.emp('cashier','a0900000-0000-0000-8000-000000000006','N06 Cashier','CASHIER');
SELECT t.emp('accountant','a0900000-0000-0000-8000-000000000007','N06 Accountant','ACCOUNTANT');
SELECT t.emp('warehouse','a0900000-0000-0000-8000-000000000008','N06 Warehouse','WAREHOUSE');
SELECT t.emp('colb','a0900000-0000-0000-8000-000000000009','N06 Collector B','COLLECTOR','b');
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text,p_city text,p_addr text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id,city,address)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,'active','291010101005'||right(p_phone,2),p_city,p_addr) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('c1','Cairo Ahmed','01033330001','Cairo','5 B Street');
SELECT t.cust('c1b','Alex Basma','01033330002','Alexandria','1 A Street');
SELECT t.cust('c2','Giza Chady','01033330003','Giza','9 C Street');
SELECT t.cust('c3','Nobody Nour','01033330004','Cairo','7 D Street');
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'percent_of_future_profit',50,
         1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');
-- Shop b: a customer.
WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status)
  VALUES(t.org('b'),'Shop B Customer',ARRAY['01044440001'],1000,'active') RETURNING id) INSERT INTO t.ids SELECT 'cb',id FROM x;
CREATE FUNCTION t.wallet(tag text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.cash_accounts WHERE kind='collector_wallet' AND employee_id=t.id(tag) $$;
CREATE FUNCTION t.bal(a uuid) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=a),0) $$;
CREATE FUNCTION t.allcash() RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(sum(balance),0) FROM public.cash_balances WHERE organization_id=t.org('a') $$;
CREATE FUNCTION t.drawers() RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(sum(cb.balance),0) FROM public.cash_balances cb JOIN public.cash_accounts a ON a.id=cb.cash_account_id
  WHERE a.organization_id=t.org('a') AND a.kind IN ('drawer','safe','bank') $$;
CREATE FUNCTION t.fpay(c text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_field_collection(jsonb_build_object('customer_id',(SELECT customer_id FROM public.contracts WHERE id=t.id(c)),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id(c),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
CREATE FUNCTION t.wsettle(w text,to_acc text,handed text,shortage text,reason text,expected text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.settle_collector_wallet(t.wallet(w),jsonb_strip_nulls(jsonb_build_object('to_account_id',t.id(to_acc),'handed',handed,
    'shortage',shortage,'reason',reason,'expected_balance',expected)),p_key) $$;
CREATE FUNCTION t.u(n text) RETURNS text LANGUAGE sql AS $$ SELECT CASE n
  WHEN 'owner' THEN 'a0900000-0000-0000-8000-000000000001' WHEN 'col1' THEN 'a0900000-0000-0000-8000-000000000003'
  WHEN 'col2' THEN 'a0900000-0000-0000-8000-000000000004' WHEN 'manager' THEN 'a0900000-0000-0000-8000-000000000005'
  WHEN 'cashier' THEN 'a0900000-0000-0000-8000-000000000006' WHEN 'accountant' THEN 'a0900000-0000-0000-8000-000000000007'
  WHEN 'warehouse' THEN 'a0900000-0000-0000-8000-000000000008' END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- The manager opens a shift and sells four contracts (12 lines of 1000: 10000 financed + 2000 profit; down payment 2000).
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','n06-key-shift');
INSERT INTO t.docs SELECT 's-'||c,t.sell(c,'n06-key-sale-'||c) FROM unnest(ARRAY['c1','c1b','c2','c3']) c;
RESET ROLE;
INSERT INTO t.ids SELECT 'c-'||c,(t.doc('s-'||c)->'contract'->>'id')::uuid FROM unnest(ARRAY['c1','c1b','c2','c3']) c;
SELECT t.expect('setup: four contracts of 12 lines of 1000',
  (SELECT count(*)=4 FROM public.contracts WHERE organization_id=t.org('a'))
  AND (SELECT bool_and(amount=1000) FROM public.schedule_lines WHERE organization_id=t.org('a')));

-- ================================================================ assignment (decision 3)
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('assign: a warehouse employee (no collection.create) is COLLECTOR_INVALID',
  format('SELECT public.set_customer_collector(%L,%L)',t.id('c1'),t.id('warehouse')),'COLLECTOR_INVALID');
SELECT t.error('assign: another shop''s employee is COLLECTOR_INVALID',
  format('SELECT public.set_customer_collector(%L,%L)',t.id('c1'),t.id('colb')),'COLLECTOR_INVALID');
SELECT t.error('assign: an unknown customer is CUSTOMER_NOT_FOUND',
  format('SELECT public.set_customer_collector(%L,%L)',gen_random_uuid(),t.id('col1')),'CUSTOMER_NOT_FOUND');
SELECT t.error('assign: another shop''s customer is CUSTOMER_NOT_FOUND',
  format('SELECT public.set_customer_collector(%L,%L)',t.id('cb'),t.id('col1')),'CUSTOMER_NOT_FOUND');
SELECT t.error('assign: a reason of 2 characters is refused',
  format('SELECT public.set_customer_collector(%L,%L,%L)',t.id('c1'),t.id('col1'),'ab'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'as-c1',public.set_customer_collector(t.id('c1'),t.id('col1'),'Covers the east side');
INSERT INTO t.docs SELECT 'as-c1-again',public.set_customer_collector(t.id('c1'),t.id('col1'));
SELECT public.set_customer_collector(t.id('c1b'),t.id('col1'));
SELECT public.set_customer_collector(t.id('c2'),t.id('col2'));
INSERT INTO t.docs SELECT 'get-c1',public.get_customer(t.id('c1'));
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('assign: a collector has no customer.edit',
  format('SELECT public.set_customer_collector(%L,%L)',t.id('c3'),t.id('col1')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.expect('assign: the customer answer carries the collector; the same assignment writes one audit row',
  t.doc('as-c1')->'collector'->>'id'=t.id('col1')::text AND t.doc('as-c1')->'collector'->>'name'='N06 Collector One'
  AND t.doc('get-c1')->'collector'->>'id'=t.id('col1')::text AND t.doc('as-c1-again')->'collector'->>'id'=t.id('col1')::text
  AND (SELECT count(*)=1 AND bool_and("before"->>'collector_id' IS NULL AND "after"->>'collector_id'=t.id('col1')::text
        AND reason='Covers the east side') FROM public.audit_log
       WHERE organization_id=t.org('a') AND action='customer.collector_set' AND entity_id=t.id('c1')));
SELECT t.expect('assign: a customer without a collector shows null',
  (SELECT jsonb_typeof(app.customer_json(t.org('a'),t.id('c3'),false)->'collector'))='null');

-- ================================================================ field collection (decision 4)
INSERT INTO t.docs SELECT 'before-f1',jsonb_build_object('all',t.allcash(),'cash',t.drawers(),'left',t.left('c-c1'),'cb',(t.cb('c-c1')).paid);
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('field: a customer assigned to another collector is CUSTOMER_NOT_ASSIGNED',
  format('SELECT t.fpay(%L,%L,%L)','c-c2','100.00','n06-key-f-na'),'CUSTOMER_NOT_ASSIGNED');
SELECT t.error('field: an unassigned customer is CUSTOMER_NOT_ASSIGNED',
  format('SELECT t.fpay(%L,%L,%L)','c-c3','100.00','n06-key-f-na2'),'CUSTOMER_NOT_ASSIGNED');
SELECT t.error('field: another shop''s customer is CUSTOMER_NOT_FOUND',
  format('SELECT public.post_field_collection(%L,%L)',
    jsonb_build_object('customer_id',t.id('cb'),'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id('c-c1'),'amount','100.00')),
      'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','100.00'))),'n06-key-f-b'),'CUSTOMER_NOT_FOUND');
SELECT t.error('field: a body with a shift_id or other key is refused',
  format('SELECT public.post_field_collection(%L,%L)',
    jsonb_build_object('customer_id',t.id('c1'),'shift_id',gen_random_uuid(),'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id('c-c1'),'amount','100.00')),
      'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','100.00'))),'n06-key-f-bad'),'VALIDATION_FAILED');
SELECT t.error('field: more than the contract has left is COLLECTION_EXCEEDS_REMAINING',
  format('SELECT t.fpay(%L,%L,%L)','c-c1','99999.00','n06-key-f-exc'),'COLLECTION_EXCEEDS_REMAINING');
INSERT INTO t.docs SELECT 'f1',t.fpay('c-c1','1000.00','n06-key-f1');
INSERT INTO t.docs SELECT 'f1-again',t.fpay('c-c1','1000.00','n06-key-f1');
SELECT t.error('field: a sale''s key is IDEMPOTENCY_CONFLICT',format('SELECT t.fpay(%L,%L,%L)','c-c1','100.00','n06-key-sale-c1'),'IDEMPOTENCY_CONFLICT');
RESET ROLE;
SELECT t.as_user(t.u('col2'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('field: another collector can''t replay the key',format('SELECT t.fpay(%L,%L,%L)','c-c2','1000.00','n06-key-f1'),'IDEMPOTENCY_CONFLICT');
RESET ROLE;
SELECT t.expect('field: the wallet exists under the collector''s default branch, named after them, one only',
  (SELECT count(*)=1 AND bool_and(branch_id=t.id('main') AND name='Wallet · N06 Collector One' AND is_active) FROM public.cash_accounts
   WHERE kind='collector_wallet' AND employee_id=t.id('col1')));
SELECT t.expect('counted once: the wallet is +1000, no drawer / safe / bank moved, all cash +1000, the contract owes 1000 less',
  t.bal(t.wallet('col1'))=1000 AND t.drawers()=(t.doc('before-f1')->>'cash')::numeric
  AND t.allcash()=(t.doc('before-f1')->>'all')::numeric+1000 AND t.left('c-c1')=(t.doc('before-f1')->>'left')::numeric-1000
  AND (t.cb('c-c1')).paid=(t.doc('before-f1')->>'cb')::numeric+1000,
  t.bal(t.wallet('col1'))||' / '||t.drawers()||' / '||t.allcash());
SELECT t.expect('field: a repeat of the key returns the first receipt and collects nothing',
  t.doc('f1-again')->>'id'=t.doc('f1')->>'id' AND (SELECT count(*)=1 FROM public.payments WHERE organization_id=t.org('a') AND collection_id=(t.doc('f1')->>'id')::uuid));
SELECT t.expect('field: the receipt has no shift; the payment and the movement have none; the movement is in the wallet',
  t.doc('f1')->>'shift_id' IS NULL AND t.doc('f1')->>'received_by_name'='N06 Collector One' AND t.doc('f1')->>'amount'='1000.00'
  AND (SELECT bool_and(shift_id IS NULL AND cash_account_id=t.wallet('col1') AND branch_id=t.id('main')) FROM public.payments
       WHERE organization_id=t.org('a') AND collection_id=(t.doc('f1')->>'id')::uuid)
  AND (SELECT count(*)=1 AND bool_and(shift_id IS NULL AND type='collection' AND amount=1000 AND cash_account_id=t.wallet('col1'))
       FROM public.cash_movements WHERE organization_id=t.org('a') AND source_type='payment'
        AND source_id=(t.doc('f1')->>'id')::uuid));
SELECT t.expect('field: audit collection.created with no shift',
  (SELECT count(*)=1 AND bool_and("after"->>'shift_id' IS NULL AND "after"->>'total'='1000.00') FROM public.audit_log
   WHERE organization_id=t.org('a') AND action='collection.created' AND entity_id=(t.doc('f1')->>'id')::uuid));

-- A cashier holds collection.create but the customer is not theirs; the manager may collect for anyone.
RESET ROLE;
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('field: a cashier (collection.create) for an unassigned customer is CUSTOMER_NOT_ASSIGNED',
  format('SELECT t.fpay(%L,%L,%L)','c-c3','100.00','n06-key-f-cash'),'CUSTOMER_NOT_ASSIGNED');
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'fm',t.fpay('c-c3','400.00','n06-key-fm');
RESET ROLE;
SELECT t.expect('field: a collector.settle holder may collect for an unassigned customer, into their own wallet',
  t.bal(t.wallet('manager'))=400 AND t.bal(t.wallet('col1'))=1000
  AND (SELECT count(*)=1 FROM public.cash_accounts WHERE kind='collector_wallet' AND employee_id=t.id('manager')));
SELECT t.expect('wallets: the shop has two (the collector and the manager), the other shop none',
  (SELECT count(*)=2 FROM public.cash_accounts WHERE organization_id=t.org('a') AND kind='collector_wallet')
  AND (SELECT count(*)=0 FROM public.cash_accounts WHERE organization_id=t.org('b') AND kind='collector_wallet'));

-- ================================================================ reversal (decision 5)
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'f2',t.fpay('c-c1','200.00','n06-key-f2');
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'rev2',public.reverse_collection((t.doc('f2')->>'id')::uuid,'{"reason":"Wrong amount typed"}','n06-key-rev2');
INSERT INTO t.docs SELECT 'rev2-again',public.reverse_collection((t.doc('f2')->>'id')::uuid,'{"reason":"Wrong amount typed"}','n06-key-rev2');
SELECT t.error_detail('reverse: a second reversal is already_reversed',
  format('SELECT public.reverse_collection(%L,%L,%L)',(t.doc('f2')->>'id')::uuid,'{"reason":"Again please"}','n06-key-rev2b'),'COLLECTION_NOT_REVERSIBLE','{"reason":"already_reversed"}');
RESET ROLE;
SELECT t.expect('reverse: a same-day field collection leaves the wallet at 1000 again and the contract unpaid by it',
  t.bal(t.wallet('col1'))=1000 AND t.left('c-c1')=(t.doc('before-f1')->>'left')::numeric-1000
  AND t.doc('rev2')->'reversal'->>'reason'='Wrong amount typed' AND t.doc('rev2-again')->'reversal'->>'id'=t.doc('rev2')->'reversal'->>'id'
  AND (SELECT count(*)=2 AND sum(amount)=0 FROM public.cash_movements WHERE organization_id=t.org('a') AND cash_account_id=t.wallet('col1')
       AND source_id IN (SELECT id FROM public.payments WHERE collection_id IN ((t.doc('f2')->>'id')::uuid,(t.doc('rev2')->'reversal'->>'id')::uuid))));

-- ================================================================ settlement (decision 6)
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'f3',t.fpay('c-c1','500.00','n06-key-f3');
RESET ROLE;
SELECT t.expect('settle: the wallet holds 1500 before settling',t.bal(t.wallet('col1'))=1500);
INSERT INTO t.docs SELECT 'before-settle',jsonb_build_object('all',t.allcash(),'safe',t.bal(t.id('safe')),'wallet',t.bal(t.wallet('col1')));
RESET ROLE;
SELECT t.as_user(t.u('accountant'),t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('settle: a stale expected balance is WALLET_BALANCE_CHANGED with the balance',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','col1','safe','900.00','1400.00','n06-key-s-stale'),'WALLET_BALANCE_CHANGED','{"balance":"1500.00"}');
SELECT t.error('settle: handed + shortage above the balance is refused (no surplus)',
  format('SELECT t.wsettle(%L,%L,%L,%L,%L,%L,%L)','col1','safe','1450.00','100.00','Counted twice','1500.00','n06-key-s-over'),'INSUFFICIENT_FUNDS');
SELECT t.error('settle: handing in more than the wallet holds is refused',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','col1','safe','1500.01','1500.00','n06-key-s-over2'),'INSUFFICIENT_FUNDS');
SELECT t.error('settle: a shortage needs a reason',
  format('SELECT t.wsettle(%L,%L,%L,%L,NULL,%L,%L)','col1','safe','900.00','100.00','1500.00','n06-key-s-noreason'),'VALIDATION_FAILED');
SELECT t.error('settle: a reason of 2 characters with a shortage is refused',
  format('SELECT t.wsettle(%L,%L,%L,%L,%L,%L,%L)','col1','safe','900.00','100.00','ab','1500.00','n06-key-s-short'),'VALIDATION_FAILED');
SELECT t.error('settle: handing in nothing is refused',
  format('SELECT t.wsettle(%L,%L,%L,%L,%L,%L,%L)','col1','safe','0.00','100.00','Lost it','1500.00','n06-key-s-zero'),'VALIDATION_FAILED');
SELECT t.error('settle: a 3-decimal amount is refused',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','col1','safe','10.005','1500.00','n06-key-s-dec'),'VALIDATION_FAILED');
SELECT t.error('settle: an unknown body key is refused',
  format('SELECT public.settle_collector_wallet(%L,%L,%L)',t.wallet('col1'),
    jsonb_build_object('to_account_id',t.id('safe'),'handed','10.00','expected_balance','1500.00','fee','1.00'),'n06-key-s-key'),'VALIDATION_FAILED');
SELECT t.error('settle: the target must be a safe (a wallet is not)',
  format('SELECT public.settle_collector_wallet(%L,%L,%L)',t.wallet('col1'),
    jsonb_build_object('to_account_id',t.wallet('manager'),'handed','10.00','expected_balance','1500.00'),'n06-key-s-w'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('settle: another shop''s safe is CASH_ACCOUNT_NOT_FOUND',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','col1','safe-b','10.00','1500.00','n06-key-s-b'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('settle: an unknown wallet is WALLET_NOT_FOUND',
  format('SELECT public.settle_collector_wallet(%L,%L,%L)',gen_random_uuid(),
    jsonb_build_object('to_account_id',t.id('safe'),'handed','10.00','expected_balance','0.00'),'n06-key-s-nf'),'WALLET_NOT_FOUND');
INSERT INTO t.docs SELECT 'st1',t.wsettle('col1','safe','900.00','100.00','Note torn in half','1500.00','n06-key-st1');
INSERT INTO t.docs SELECT 'st1-again',t.wsettle('col1','safe','900.00','100.00','Note torn in half','1500.00','n06-key-st1');
SELECT t.error('settle: the same key on another wallet is IDEMPOTENCY_CONFLICT',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','manager','safe','100.00','400.00','n06-key-st1'),'IDEMPOTENCY_CONFLICT');
RESET ROLE;
SELECT t.expect('settle: partial with a shortage: wallet 1500 -> 500, safe +900, all cash down by the shortage only',
  t.bal(t.wallet('col1'))=500 AND t.bal(t.id('safe'))=(t.doc('before-settle')->>'safe')::numeric+900
  AND t.allcash()=(t.doc('before-settle')->>'all')::numeric-100,
  t.bal(t.wallet('col1'))||' / '||t.bal(t.id('safe'))||' / '||t.allcash());
SELECT t.expect('settle: one transfer row, kind collector_settlement, amount = handed, shortage and reason recorded, CX number',
  (SELECT count(*)=1 AND bool_and(kind='collector_settlement' AND amount=900 AND shortage_amount=100 AND reason='Note torn in half'
     AND from_account_id=t.wallet('col1') AND to_account_id=t.id('safe') AND number LIKE '%-CX-%')
   FROM public.cash_transfers WHERE organization_id=t.org('a') AND idempotency_key='n06-key-st1')
  AND t.doc('st1-again')->>'id'=t.doc('st1')->>'id' AND t.doc('st1')->>'handed'='900.00' AND t.doc('st1')->>'shortage'='100.00'
  AND t.doc('st1')->>'balance_after'='500.00' AND t.doc('st1')->'collector'->>'name'='N06 Collector One',t.doc('st1')::text);
SELECT t.expect('settle: movements = transfer_out -900 (wallet), transfer_in +900 (safe), adjustment -100 (wallet), all of that transfer',
  (SELECT jsonb_agg(jsonb_build_object('t',type,'a',amount,'acc',CASE cash_account_id WHEN t.wallet('col1') THEN 'w' WHEN t.id('safe') THEN 's' END) ORDER BY type)
   FROM public.cash_movements WHERE source_type='cash_transfer' AND source_id=(t.doc('st1')->>'id')::uuid)
  ='[{"a": 900.00, "t": "transfer_in", "acc": "s"}, {"a": -900.00, "t": "transfer_out", "acc": "w"}, {"a": -100.00, "t": "adjustment", "acc": "w"}]'::jsonb,
  (SELECT jsonb_agg(jsonb_build_object('t',type,'a',amount,'acc',CASE cash_account_id WHEN t.wallet('col1') THEN 'w' WHEN t.id('safe') THEN 's' END) ORDER BY type) FROM public.cash_movements WHERE source_type='cash_transfer' AND source_id=(t.doc('st1')->>'id')::uuid)::text);
SELECT t.expect('settle: audit collector.wallet_settled (warning with a shortage) with the balances',
  (SELECT count(*)=1 AND bool_and(severity='warning' AND "after"->>'handed'='900.00' AND "after"->>'shortage'='100.00'
     AND "after"->>'balance_before'='1500.00' AND "after"->>'balance_after'='500.00' AND reason='Note torn in half')
   FROM public.audit_log WHERE organization_id=t.org('a') AND action='collector.wallet_settled' AND entity_id=(t.doc('st1')->>'id')::uuid));
SELECT t.expect('settle: nothing was deducted from anyone and no commission exists (owner decisions 1, 4)',
  (SELECT count(*)=0 FROM public.collector_commissions) AND (SELECT bool_and(collector_commission_pct=0) FROM public.org_settings));
-- Reversal after a settlement: the f3 cash (500) is in the wallet by number but a settlement came after it.
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('reverse: a field collection with a settlement after it is handed_in',
  format('SELECT public.reverse_collection(%L,%L,%L)',(t.doc('f3')->>'id')::uuid,'{"reason":"Customer disputes it"}','n06-key-rev3'),'COLLECTION_NOT_REVERSIBLE','{"reason":"handed_in"}');
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'f4',t.fpay('c-c1','300.00','n06-key-f4');
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'rev4',public.reverse_collection((t.doc('f4')->>'id')::uuid,'{"reason":"Customer paid twice"}','n06-key-rev4');
RESET ROLE;
SELECT t.expect('reverse: a collection after the settlement still reverses; the wallet is back at 500',t.bal(t.wallet('col1'))=500);
-- A manager can't settle their own wallet; the owner can.
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('settle: settling your own wallet is SELF_SETTLEMENT',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','manager','safe','400.00','400.00','n06-key-s-self'),'SELF_SETTLEMENT');
RESET ROLE;
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('settle: a cashier has no collector.settle',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','col1','safe','100.00','500.00','n06-key-s-cash'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('settle: a collector can''t settle their own wallet (no collector.settle)',
  format('SELECT t.wsettle(%L,%L,%L,NULL,NULL,%L,%L)','col1','safe','100.00','500.00','n06-key-s-col'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'st2',t.wsettle('manager','safe','400.00',NULL,NULL,'400.00','n06-key-st2');
INSERT INTO t.docs SELECT 'st3',t.wsettle('col1','safe','500.00',NULL,NULL,'500.00','n06-key-st3');
RESET ROLE;
SELECT t.expect('settle: the owner settles other wallets in full with no shortage; both wallets are empty',
  t.bal(t.wallet('manager'))=0 AND t.bal(t.wallet('col1'))=0 AND t.doc('st2')->>'shortage'='0.00' AND jsonb_typeof(t.doc('st3')->'reason')='null'
  AND (SELECT count(*)=0 FROM public.cash_movements WHERE type='adjustment' AND source_id IN ((t.doc('st2')->>'id')::uuid,(t.doc('st3')->>'id')::uuid))
  AND (SELECT bool_and(severity='info') FROM public.audit_log WHERE action='collector.wallet_settled' AND entity_id IN ((t.doc('st2')->>'id')::uuid,(t.doc('st3')->>'id')::uuid)));
SELECT t.expect('ledger: every wallet''s balance equals the sum of its movements',
  (SELECT bool_and(COALESCE(cb.balance,0)=COALESCE((SELECT sum(m.amount) FROM public.cash_movements m WHERE m.cash_account_id=a.id),0))
   FROM public.cash_accounts a LEFT JOIN public.cash_balances cb ON cb.cash_account_id=a.id WHERE a.kind='collector_wallet'));

-- ================================================================ reads (decision 8)
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'my-col1',public.get_my_wallet();
SELECT t.error('reads: a collector can''t list all wallets (no collector.settle / cash.view)',
  'SELECT public.list_collector_wallets()','PERMISSION_DENIED');
INSERT INTO t.docs SELECT 'led-own',public.list_wallet_movements(t.wallet('col1'));
RESET ROLE;
SELECT t.as_user(t.u('col2'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'my-col2',public.get_my_wallet();
SELECT t.error('reads: a collector can''t read another collector''s ledger',
  format('SELECT public.list_wallet_movements(%L)',t.wallet('col1')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('warehouse'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('reads: my wallet needs collection.create','SELECT public.get_my_wallet()','PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('accountant'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'wallets',public.list_collector_wallets();
INSERT INTO t.docs SELECT 'wallets-branch',public.list_collector_wallets(jsonb_build_object('branch_id',t.id('main')));
INSERT INTO t.docs SELECT 'led-p1',public.list_wallet_movements(t.wallet('col1'),'{"limit":3}');
INSERT INTO t.docs SELECT 'led-p2',public.list_wallet_movements(t.wallet('col1'),jsonb_build_object('limit',3,'cursor',(SELECT public.list_wallet_movements(t.wallet('col1'),'{"limit":3}')->>'next_cursor')));
INSERT INTO t.docs SELECT 'led-all',public.list_wallet_movements(t.wallet('col1'));
SELECT t.error('reads: an unknown wallet is WALLET_NOT_FOUND',format('SELECT public.list_wallet_movements(%L)',gen_random_uuid()),'WALLET_NOT_FOUND');
SELECT t.error('reads: an unknown filter key is refused',format('SELECT public.list_wallet_movements(%L,%L)',t.wallet('col1'),'{"x":1}'),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('my wallet: collector one: balance 0, a last settlement, f1 f3 counted today (f2 and f4 reversed)',
  t.doc('my-col1')->>'balance'='0.00' AND t.doc('my-col1')->'wallet'->>'name'='Wallet · N06 Collector One'
  AND t.doc('my-col1')->'last_settlement'->>'handed'='500.00' AND jsonb_typeof(t.doc('my-col1')->'oldest_unsettled_date')='null'
  AND (t.doc('my-col1')->'today'->>'count')::int=2 AND t.doc('my-col1')->'today'->>'amount'='1500.00' AND t.doc('my-col1')->'today'->>'cash'='1500.00',
  t.doc('my-col1')::text);
SELECT t.expect('my wallet: a collector with no wallet yet gets zeros and no wallet',
  jsonb_typeof(t.doc('my-col2')->'wallet')='null' AND t.doc('my-col2')->>'balance'='0.00' AND (t.doc('my-col2')->'today'->>'count')::int=0);
SELECT t.expect('wallets: the list shows the two wallets of the shop with collector and branch; the branch filter keeps them',
  jsonb_array_length(t.doc('wallets')->'items')=2 AND jsonb_array_length(t.doc('wallets-branch')->'items')=2
  AND (SELECT bool_and(i->'collector'->>'name' IS NOT NULL AND i->>'balance'='0.00') FROM jsonb_array_elements(t.doc('wallets')->'items') i));
SELECT t.expect('ledger: newest first with running balance; paging covers every movement once; settlements carry their shortage',
  jsonb_array_length(t.doc('led-p1')->'items')=3 AND t.doc('led-p1')->>'next_cursor' IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('led-p1')->'items') a JOIN jsonb_array_elements(t.doc('led-p2')->'items') b ON a->>'id'=b->>'id')
  AND t.doc('led-all')->'items'->0->>'balance_after'='0.00' AND jsonb_typeof(t.doc('led-all')->'next_cursor')='null'
  AND (SELECT count(*)=2 FROM jsonb_array_elements(t.doc('led-all')->'items') i WHERE i->'settlement'->>'shortage'='100.00')
  AND t.doc('led-all')->'items'->0=t.doc('led-own')->'items'->0,
  (t.doc('led-all')->'items'->0)::text);

-- ================================================================ route and overdue filter (decisions 8, 9)
SELECT t.late('c-c1',3,10);
SELECT t.late('c-c2',1,10);
RESET ROLE;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'route1',public.get_collector_route();
INSERT INTO t.docs SELECT 'route1-future',public.get_collector_route(jsonb_build_object('date',(t.today()+45)::text));
SELECT t.error('route: a collector can''t read another collector''s route',
  format('SELECT public.get_collector_route(%L)',jsonb_build_object('employee_id',t.id('col2'))),'PERMISSION_DENIED');
INSERT INTO t.docs SELECT 'od-col1',public.list_overdue_contracts();
INSERT INTO t.docs SELECT 'od-col1-other',public.list_overdue_contracts(jsonb_build_object('collector_id',t.id('col2')));
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'route2',public.get_collector_route(jsonb_build_object('employee_id',t.id('col2')));
INSERT INTO t.docs SELECT 'od-all',public.list_overdue_contracts();
INSERT INTO t.docs SELECT 'od-c2',public.list_overdue_contracts(jsonb_build_object('collector_id',t.id('col2')));
SELECT t.error('route: an unknown employee is EMPLOYEE_NOT_FOUND',
  format('SELECT public.get_collector_route(%L)',jsonb_build_object('employee_id',gen_random_uuid())),'EMPLOYEE_NOT_FOUND');
RESET ROLE;
SELECT t.expect('route: collector one''s route today has only the assigned customer with something due (Cairo Ahmed), amounts from the schedule',
  jsonb_array_length(t.doc('route1')->'stops')=1 AND t.doc('route1')->'stops'->0->'customer'->>'name'='Cairo Ahmed'
  AND t.doc('route1')->'stops'->0->>'amount_due'=(SELECT sum(remaining)::numeric(18,2)::text FROM public.v_schedule_line_status
     WHERE contract_id=t.id('c-c1') AND NOT superseded AND remaining>0 AND due_date<=t.today())
  AND (t.doc('route1')->'stops'->0->>'max_days_late')::int>0 AND (t.doc('route1')->'stops'->0->>'amount_overdue')::numeric>0
  AND t.doc('route1')->'totals'->>'customers'='1' AND t.doc('route1')->>'date'=t.today()::text,
  t.doc('route1')::text);
SELECT t.expect('route: 45 days ahead the second customer appears; stops sort by city then address (Alexandria before Cairo)',
  jsonb_array_length(t.doc('route1-future')->'stops')=2 AND t.doc('route1-future')->'stops'->0->'customer'->>'city'='Alexandria'
  AND t.doc('route1-future')->'stops'->1->'customer'->>'city'='Cairo',t.doc('route1-future')::text);
SELECT t.expect('route: a manager reads collector two''s route (the one assigned customer)',
  jsonb_array_length(t.doc('route2')->'stops')=1 AND t.doc('route2')->'stops'->0->'customer'->>'name'='Giza Chady'
  AND t.doc('route2')->>'employee_name'='N06 Collector Two');
SELECT t.expect('overdue: a collector sees only their own customers, whatever collector_id they ask for',
  jsonb_array_length(t.doc('od-col1')->'items')=1 AND t.doc('od-col1')->'items'->0->'customer'->>'name'='Cairo Ahmed'
  AND t.doc('od-col1')->'items'->0->'customer'->>'collector_id'=t.id('col1')::text
  AND jsonb_array_length(t.doc('od-col1-other')->'items')=1 AND t.doc('od-col1-other')->'items'->0->'customer'->>'name'='Cairo Ahmed'
  AND t.doc('od-col1')->'totals'->>'contracts'='1');
SELECT t.expect('overdue: a manager sees both and filters by collector',
  jsonb_array_length(t.doc('od-all')->'items')=2 AND jsonb_array_length(t.doc('od-c2')->'items')=1
  AND t.doc('od-c2')->'items'->0->'customer'->>'name'='Giza Chady' AND t.doc('od-all')->'totals'->>'contracts'='2');

-- ================================================================ isolation and grants
RESET ROLE;
SELECT t.as_user('a0900000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('isolation: shop b can''t settle shop a''s wallet',
  format('SELECT public.settle_collector_wallet(%L,%L,%L)',t.wallet('col1'),
    jsonb_build_object('to_account_id',t.id('safe-b'),'handed','1.00','expected_balance','0.00'),'n06-key-b-s'),'WALLET_NOT_FOUND');
SELECT t.error('isolation: shop b can''t read shop a''s ledger',format('SELECT public.list_wallet_movements(%L)',t.wallet('col1')),'WALLET_NOT_FOUND');
SELECT t.error('isolation: shop b can''t assign shop a''s customer',
  format('SELECT public.set_customer_collector(%L,NULL)',t.id('c1')),'CUSTOMER_NOT_FOUND');
SELECT t.error('isolation: shop b can''t field-collect shop a''s customer',
  format('SELECT public.post_field_collection(%L,%L)',
    jsonb_build_object('customer_id',t.id('c1'),'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id('c-c1'),'amount','10.00')),
      'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','10.00'))),'n06-key-b-f'),'CUSTOMER_NOT_FOUND');
INSERT INTO t.docs SELECT 'wallets-b',public.list_collector_wallets();
INSERT INTO t.docs SELECT 'route-b',public.get_collector_route();
RESET ROLE;
SELECT t.expect('isolation: shop b sees no wallets and an empty route',
  jsonb_array_length(t.doc('wallets-b')->'items')=0 AND jsonb_array_length(t.doc('route-b')->'stops')=0);
-- Clearing the assignment.
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'clear-c1b',public.set_customer_collector(t.id('c1b'),NULL,'Moved to the office');
RESET ROLE;
SELECT t.expect('assign: clearing sets the collector to null and audits before / after',
  jsonb_typeof(t.doc('clear-c1b')->'collector')='null'
  AND (SELECT count(*)=2 FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.collector_set' AND entity_id=t.id('c1b'))
  AND (SELECT bool_and("after"->>'collector_id' IS NULL) FROM public.audit_log
       WHERE organization_id=t.org('a') AND action='customer.collector_set' AND entity_id=t.id('c1b') AND reason='Moved to the office'));
SELECT t.expect('grants: the seven new functions and the changed ones are executable; the helpers are not; no direct wallet writes',
  has_function_privilege('authenticated','public.post_field_collection(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.settle_collector_wallet(uuid,jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_customer_collector(uuid,uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_my_wallet()','EXECUTE')
  AND has_function_privilege('authenticated','public.list_collector_wallets(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_wallet_movements(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_collector_route(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_overdue_contracts(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.reverse_collection(uuid,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_field_collection(jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.settle_collector_wallet(uuid,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.wallet_for(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.wallet_settlement_json(uuid,uuid)','EXECUTE')
  AND NOT has_table_privilege('authenticated','public.cash_accounts','INSERT')
  AND NOT has_table_privilege('authenticated','public.cash_movements','INSERT'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
