-- N07 printed contract and promissory notes (EC-86, D82).
-- Run by: node scripts/db-smoke.mjs supabase/tests/n07_printed_documents_test.sql (inside BEGIN ... ROLLBACK).
-- The documents read matches the contract (figures, schedule) without the cash price; the notes sum to
-- what is left (per installment and single) and follow payments; the terms text refuses forbidden
-- wording and unknown placeholders (diacritics too); prints are numbered per document and schedule
-- version (original, then copies; a reschedule starts an original again); closed contracts print the
-- contract only; other shops, other roles and an expired shop are refused where the spec says.
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
INSERT INTO t.shops SELECT s,public.admin_provision_organization('N07 '||s,'n07-key-'||s,p,'Owner',s||'n07@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('v',64)),('b','retail',repeat('w',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0910000-0000-0000-8000-000000000001','an07@example.com'),('a0910000-0000-0000-8000-000000000002','bn07@example.com'),
  ('a0910000-0000-0000-8000-000000000003','n07col1@example.com'),('a0910000-0000-0000-8000-000000000004','n07col2@example.com'),
  ('a0910000-0000-0000-8000-000000000005','n07manager@example.com'),('a0910000-0000-0000-8000-000000000006','n07cashier@example.com'),
  ('a0910000-0000-0000-8000-000000000007','n07accountant@example.com'),('a0910000-0000-0000-8000-000000000008','n07warehouse@example.com'),
  ('a0910000-0000-0000-8000-000000000009','n07colb@example.com');
SELECT public.accept_invite(repeat('v',64),'a0910000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('w',64),'a0910000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',id FROM public.cash_accounts WHERE organization_id=t.org('a') AND kind='safe' AND branch_id=t.id('main');
INSERT INTO t.ids SELECT 'safe-b',id FROM public.cash_accounts WHERE organization_id=t.org('b') AND kind='safe';
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0,overdue_warning_interval_days=10
  WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'));
RESET ROLE;
SELECT t.as_user('a0910000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"N7-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',30)),'n07-key-found');
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,o text DEFAULT 'a') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; b uuid; BEGIN
  SELECT id INTO b FROM public.branches WHERE organization_id=t.org(o) AND is_main;
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org(o),sub,name,r,b) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org(o),v,b);
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('col1','a0910000-0000-0000-8000-000000000003','N07 Collector One','COLLECTOR');
SELECT t.emp('col2','a0910000-0000-0000-8000-000000000004','N07 Collector Two','COLLECTOR');
SELECT t.emp('manager','a0910000-0000-0000-8000-000000000005','N07 Manager','BRANCH_MANAGER');
SELECT t.emp('cashier','a0910000-0000-0000-8000-000000000006','N07 Cashier','CASHIER');
SELECT t.emp('accountant','a0910000-0000-0000-8000-000000000007','N07 Accountant','ACCOUNTANT');
SELECT t.emp('warehouse','a0910000-0000-0000-8000-000000000008','N07 Warehouse','WAREHOUSE');
SELECT t.emp('colb','a0910000-0000-0000-8000-000000000009','N07 Collector B','COLLECTOR','b');
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
  WHEN 'owner' THEN 'a0910000-0000-0000-8000-000000000001' WHEN 'col1' THEN 'a0910000-0000-0000-8000-000000000003'
  WHEN 'col2' THEN 'a0910000-0000-0000-8000-000000000004' WHEN 'manager' THEN 'a0910000-0000-0000-8000-000000000005'
  WHEN 'cashier' THEN 'a0910000-0000-0000-8000-000000000006' WHEN 'accountant' THEN 'a0910000-0000-0000-8000-000000000007'
  WHEN 'warehouse' THEN 'a0910000-0000-0000-8000-000000000008' END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- The manager opens a shift and sells four contracts (12 lines of 1000: 10000 financed + 2000 profit; down payment 2000).
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','n07-key-shift');
INSERT INTO t.docs SELECT 's-'||c,t.sell(c,'n07-key-sale-'||c) FROM unnest(ARRAY['c1','c1b','c2','c3']) c;
RESET ROLE;
INSERT INTO t.ids SELECT 'c-'||c,(t.doc('s-'||c)->'contract'->>'id')::uuid FROM unnest(ARRAY['c1','c1b','c2','c3']) c;
SELECT t.expect('setup: four contracts of 12 lines of 1000',
  (SELECT count(*)=4 FROM public.contracts WHERE organization_id=t.org('a'))
  AND (SELECT bool_and(amount=1000) FROM public.schedule_lines WHERE organization_id=t.org('a')));

-- A guarantor on c1 (full details are on the paper).
INSERT INTO public.guarantors(id,organization_id,full_name,phone,national_id,address,job)
  VALUES('a0910000-0000-0000-8000-0000000000a1',t.org('a'),'Guarantor Gamal','01055550001','29001010100123','3 G Street, Cairo','Teacher');
INSERT INTO t.ids VALUES('g1','a0910000-0000-0000-8000-0000000000a1');
INSERT INTO public.customer_guarantors(organization_id,customer_id,guarantor_id,relation) VALUES(t.org('a'),t.id('c1'),t.id('g1'),'Uncle');
INSERT INTO public.contract_guarantors(organization_id,contract_id,guarantor_id) VALUES(t.org('a'),t.id('c-c1'),t.id('g1'));
SELECT t.commit_checks();
UPDATE public.customers SET job='Engineer' WHERE id=t.id('c1');

-- ================================================================ the documents read matches the contract
RESET ROLE;
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'd1',public.get_contract_documents(t.id('c-c1'));
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'k1',public.get_contract(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('docs: the cashier (installment.create) reads the documents; all keys are there',
  (SELECT bool_and(t.doc('d1') ? k) FROM unnest(ARRAY['contract','customer','guarantors','goods','shop','terms','notes_mode','notes','prints','status_mark','replaces','today']) k));
SELECT t.expect('docs: the schedule lines equal the contract''s, date and amount for every line',
  t.doc('d1')->'contract'->'lines' = t.doc('k1')->'lines' AND jsonb_array_length(t.doc('d1')->'contract'->'lines')=12);
SELECT t.expect('docs: price, down payment, financed amount, profit, count and dates equal the contract''s',
  (t.doc('d1')->'contract'->>'total_payable',t.doc('d1')->'contract'->>'down_payment',t.doc('d1')->'contract'->>'financed_amount',
   t.doc('d1')->'contract'->>'markup_amount',t.doc('d1')->'contract'->>'installments_count',t.doc('d1')->'contract'->>'first_due_date',
   t.doc('d1')->'contract'->>'last_due_date',t.doc('d1')->'contract'->>'number')
  IS NOT DISTINCT FROM
  (t.doc('k1')->>'total_payable',t.doc('k1')->>'down_payment',t.doc('k1')->>'financed_amount',t.doc('k1')->>'markup_amount',
   t.doc('k1')->>'installments_count',t.doc('k1')->>'first_due_date',t.doc('k1')->>'last_due_date',t.doc('k1')->>'number'));
SELECT t.expect('docs: no cash price on the paper (rule 1), no customer or guarantor stub, no goods line total',
  NOT (t.doc('d1')->'contract' ? 'cash_price') AND NOT (t.doc('d1')->'contract' ? 'customer') AND NOT (t.doc('d1')->'contract' ? 'guarantors')
  AND NOT (t.doc('d1')::text LIKE '%cash_price%') AND NOT (t.doc('d1')->'goods'->0 ? 'line_total'));
SELECT t.expect('docs: the customer and the guarantor carry the full national ID, address and job',
  t.doc('d1')->'customer'->>'name'='Cairo Ahmed' AND t.doc('d1')->'customer'->>'national_id'='29101010100501'
  AND t.doc('d1')->'customer'->>'address'='5 B Street' AND t.doc('d1')->'customer'->>'job'='Engineer'
  AND t.doc('d1')->'customer'->>'phone'='01033330001'
  AND jsonb_array_length(t.doc('d1')->'guarantors')=1 AND t.doc('d1')->'guarantors'->0->>'national_id'='29001010100123'
  AND t.doc('d1')->'guarantors'->0->>'relation'='Uncle' AND t.doc('d1')->'guarantors'->0->>'job'='Teacher'
  AND t.doc('d1')->'guarantors'->0->>'address'='3 G Street, Cairo', (t.doc('d1')->'customer')::text);
SELECT t.expect('docs: goods are the sale''s lines (name and quantity)',
  t.doc('d1')->'goods' = '[{"name":"تلفزيون","quantity":1}]'::jsonb, (t.doc('d1')->'goods')::text);
SELECT t.expect('docs: the shop block names the shop and the branch',
  t.doc('d1')->'shop'->>'name'='N07 a' AND t.doc('d1')->'shop'->'branch'->>'name' IS NOT NULL AND (t.doc('d1')->'shop' ? 'logo_file_id'));
SELECT t.expect('docs: default terms (null text, is_default), mode per installment, version 1, no replaces, no mark',
  t.doc('d1')->'terms'='{"text":null,"is_default":true}'::jsonb AND t.doc('d1')->>'notes_mode'='per_installment'
  AND (t.doc('d1')->'contract'->>'current_version')='1' AND t.doc('d1')->'replaces'='null'::jsonb AND t.doc('d1')->'status_mark'='null'::jsonb);
SELECT t.expect('docs: the contract date is the sale''s date',
  t.doc('d1')->'contract'->>'contract_date' = (SELECT business_date::text FROM public.sales WHERE id=(t.doc('s-c1')->'sale'->>'id')::uuid));
SELECT t.expect('docs: nothing printed yet (next print is the original) for both documents',
  t.doc('d1')->'prints'='{"contract":{"next_print_no":1,"copy":false},"promissory_notes":{"next_print_no":1,"copy":false}}'::jsonb);

-- ================================================================ promissory notes: per installment
SELECT t.expect('notes: 12 notes, one per installment, numbered contract-seq, amount = the line, due = the line''s date',
  jsonb_array_length(t.doc('d1')->'notes')=12
  AND (SELECT bool_and(n->>'number' = (t.doc('d1')->'contract'->>'number')||'-'||(n->>'seq') AND (n->>'amount')::numeric = (l->>'amount')::numeric AND n->>'due_date' = l->>'due_date')
       FROM jsonb_array_elements(t.doc('d1')->'notes') WITH ORDINALITY a(n,i) JOIN jsonb_array_elements(t.doc('d1')->'contract'->'lines') WITH ORDINALITY b(l,j) ON i=j));
SELECT t.expect('notes: their sum is the contract''s remaining',
  (SELECT sum((n->>'amount')::numeric) FROM jsonb_array_elements(t.doc('d1')->'notes') n) = (t.doc('k1')->'balance'->>'remaining')::numeric);
SELECT t.expect('notes: the issue date is the contract date (version 1)',
  (SELECT bool_and(n->>'issue_date' = t.doc('d1')->'contract'->>'contract_date') FROM jsonb_array_elements(t.doc('d1')->'notes') n));

-- A collection of 1400: line 1 and 400 of line 2. The notes follow what is left.
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.pay('c-c1','1400.00','n07-key-pay-1');
INSERT INTO t.docs SELECT 'd2',public.get_contract_documents(t.id('c-c1'));
INSERT INTO t.docs SELECT 'k2',public.get_contract(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('notes after a payment: 11 notes, the first of 600 (line 2 part paid), sum = remaining',
  jsonb_array_length(t.doc('d2')->'notes')=11 AND (t.doc('d2')->'notes'->0->>'seq')='2' AND (t.doc('d2')->'notes'->0->>'amount')::numeric=600
  AND (SELECT sum((n->>'amount')::numeric) FROM jsonb_array_elements(t.doc('d2')->'notes') n) = (t.doc('k2')->'balance'->>'remaining')::numeric
  AND (t.doc('k2')->'balance'->>'remaining')::numeric = 10600, (t.doc('d2')->'notes'->0)::text);

-- ================================================================ promissory notes: a single note
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('settings: a cashier cannot change the notes mode',$$SELECT public.update_org_settings('{"promissory_notes_mode":"single"}')$$,'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('settings: an unknown mode is SETTINGS_INVALID',$$SELECT public.update_org_settings('{"promissory_notes_mode":"three"}')$$,'SETTINGS_INVALID');
SELECT t.error('settings: terms that are not text are SETTINGS_INVALID',$$SELECT public.update_org_settings('{"contract_terms":5}')$$,'SETTINGS_INVALID');
SELECT t.error('settings: terms above 20000 characters are SETTINGS_INVALID',
  format('SELECT public.update_org_settings(jsonb_build_object(''contract_terms'',%L))',repeat('x',20001)),'SETTINGS_INVALID');
SELECT public.update_org_settings('{"promissory_notes_mode":"single"}');
INSERT INTO t.docs SELECT 'settings',public.get_shop_settings();
RESET ROLE;
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'd3',public.get_contract_documents(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('settings: GET answers the two new fields next to the old ones',
  t.doc('settings')->>'promissory_notes_mode'='single' AND t.doc('settings')->'contract_terms'='null'::jsonb AND (t.doc('settings') ? 'receipt_header'));
SELECT t.expect('notes single: one note, number contract-T, amount = remaining, due = the last installment''s date',
  jsonb_array_length(t.doc('d3')->'notes')=1 AND t.doc('d3')->'notes'->0->>'number' = (t.doc('k2')->>'number')||'-T'
  AND t.doc('d3')->'notes'->0->'seq'='null'::jsonb
  AND (t.doc('d3')->'notes'->0->>'amount')::numeric = (t.doc('k2')->'balance'->>'remaining')::numeric
  AND t.doc('d3')->'notes'->0->>'due_date' = t.doc('k2')->>'last_due_date');

-- ================================================================ the terms text
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('terms: a forbidden Arabic word is TEMPLATE_NOT_ALLOWED with the words',
  $$SELECT public.update_org_settings('{"contract_terms":"يسدد العميل فائدة شهرية"}')$$,'TEMPLATE_NOT_ALLOWED','{"words":["فائدة"]}');
SELECT t.error_detail('terms: the same word with diacritics is refused',
  format('SELECT public.update_org_settings(jsonb_build_object(''contract_terms'',%L))',U&'\0641\064E\0627\0626\0650\062F\064E\0629'),'TEMPLATE_NOT_ALLOWED','{"words":["فائدة"]}');
SELECT t.error_detail('terms: an English word in any case is refused',
  $$SELECT public.update_org_settings('{"contract_terms":"A Late FEE of 5% applies"}')$$,'TEMPLATE_NOT_ALLOWED','{"words":["late fee"]}');
SELECT t.error_detail('terms: a late fee phrase lists both overlapping words',
  $$SELECT public.update_org_settings('{"contract_terms":"غرامة تأخير"}')$$,'TEMPLATE_NOT_ALLOWED','{"words":["غرامة","غرامة تأخير"]}');
SELECT t.error('terms: early settlement discount wording is refused',
  $$SELECT public.update_org_settings('{"contract_terms":"خصم السداد المبكر"}')$$,'TEMPLATE_NOT_ALLOWED');
SELECT t.error_detail('terms: an unknown placeholder is TEMPLATE_INVALID with its name',
  $$SELECT public.update_org_settings('{"contract_terms":"Dear {{ customer_nam }} and {{shop_name}}"}')$$,'TEMPLATE_INVALID','{"unknown":["customer_nam"]}');
RESET ROLE;
SELECT t.expect('terms: nothing was saved by the refused calls',
  (SELECT contract_terms IS NULL FROM public.org_settings WHERE organization_id=t.org('a')));
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT public.update_org_settings('{"contract_terms":"العميل {{customer_name}} يلتزم بسداد {{installment_price}} ({{installment_price_words}})"}');
RESET ROLE;
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'd4',public.get_contract_documents(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('terms: a good text is saved and the documents carry it (not the default)',
  t.doc('d4')->'terms'->>'text' LIKE 'العميل {{customer_name}}%' AND (t.doc('d4')->'terms'->>'is_default')='false');
SELECT t.expect('terms: the change is in the audit log (org.settings_updated with before and after)',
  EXISTS (SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='org.settings_updated' AND after ? 'contract_terms' AND before ? 'contract_terms'));
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT public.update_org_settings('{"contract_terms":null,"promissory_notes_mode":"per_installment","receipt_footer":"Thanks"}');
RESET ROLE;
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'd5',public.get_contract_documents(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('terms: null restores the default; the mode and an ordinary setting go through in the same call',
  t.doc('d5')->'terms'='{"text":null,"is_default":true}'::jsonb AND t.doc('d5')->>'notes_mode'='per_installment'
  AND (SELECT receipt_footer='Thanks' FROM public.org_settings WHERE organization_id=t.org('a')));

-- ================================================================ the print log
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('print: an unknown document is refused',format('SELECT public.record_contract_document_print(%L,%L)',t.id('c-c1'),'receipt'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'p1',public.record_contract_document_print(t.id('c-c1'),'contract');
INSERT INTO t.docs SELECT 'p2',public.record_contract_document_print(t.id('c-c1'),'contract');
INSERT INTO t.docs SELECT 'p3',public.record_contract_document_print(t.id('c-c1'),'promissory_notes');
INSERT INTO t.docs SELECT 'd6',public.get_contract_documents(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('print: the first print is the original, the second a copy (per document)',
  t.doc('p1')='{"print_no":1,"copy":false}'::jsonb AND t.doc('p2')='{"print_no":2,"copy":true}'::jsonb AND t.doc('p3')='{"print_no":1,"copy":false}'::jsonb);
SELECT t.expect('print: the read answers the next number per document',
  t.doc('d6')->'prints'='{"contract":{"next_print_no":3,"copy":true},"promissory_notes":{"next_print_no":2,"copy":true}}'::jsonb);
SELECT t.expect('print: each print is one audit row (contract.document_printed) with number, document, version, print_no, copy, and who',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND entity_id=t.id('c-c1') AND action='contract.document_printed')=3
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND entity_id=t.id('c-c1') AND action='contract.document_printed'
              AND after @> jsonb_build_object('document','contract','version',1,'print_no',2,'copy',true,'number',t.doc('k1')->>'number')
              AND employee_id=t.id('cashier')));

-- ================================================================ a reschedule starts a new original
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.resched('c-c1',6,30,'n07-key-resched');
INSERT INTO t.docs SELECT 'd7',public.get_contract_documents(t.id('c-c1'));
INSERT INTO t.docs SELECT 'p4',public.record_contract_document_print(t.id('c-c1'),'promissory_notes');
INSERT INTO t.docs SELECT 'p5',public.record_contract_document_print(t.id('c-c1'),'promissory_notes');
INSERT INTO t.docs SELECT 'p6',public.record_contract_document_print(t.id('c-c1'),'contract');
INSERT INTO t.docs SELECT 'k7',public.get_contract(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('reschedule: version 2, the counters start again and the documents say what they replace',
  (t.doc('d7')->'contract'->>'current_version')='2'
  AND t.doc('d7')->'prints'='{"contract":{"next_print_no":1,"copy":false},"promissory_notes":{"next_print_no":1,"copy":false}}'::jsonb
  AND t.doc('d7')->'replaces'=jsonb_build_object('version',1,'date',t.doc('d7')->'contract'->>'contract_date'), (t.doc('d7')->'replaces')::text);
SELECT t.expect('reschedule: 6 notes of the new schedule, summing to what is left, issued on the print date',
  jsonb_array_length(t.doc('d7')->'notes')=6
  AND (SELECT sum((n->>'amount')::numeric) FROM jsonb_array_elements(t.doc('d7')->'notes') n)=(t.doc('k7')->'balance'->>'remaining')::numeric
  AND (SELECT bool_and(n->>'issue_date'=t.doc('d7')->>'today') FROM jsonb_array_elements(t.doc('d7')->'notes') n));
SELECT t.expect('reschedule: the first print of the new version is an original, the second a copy; the log keeps the version',
  t.doc('p4')='{"print_no":1,"copy":false}'::jsonb AND t.doc('p5')='{"print_no":2,"copy":true}'::jsonb AND t.doc('p6')='{"print_no":1,"copy":false}'::jsonb
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE entity_id=t.id('c-c1') AND action='contract.document_printed' AND (after->>'version')='2' AND after->>'document'='promissory_notes'));

-- A second reschedule says it replaces the first one's date.
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.resched('c-c1',3,45,'n07-key-resched-2');
INSERT INTO t.docs SELECT 'd8',public.get_contract_documents(t.id('c-c1'));
RESET ROLE;
SELECT t.expect('reschedule twice: version 3 replaces version 2, dated by the change',
  (t.doc('d8')->'replaces'->>'version')='2' AND t.doc('d8')->'replaces'->>'date'=t.today()::text, (t.doc('d8')->'replaces')::text);

-- ================================================================ closed contracts
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.settle('c-c1b','0.00','Customer pays everything today','n07-key-settle');
RESET ROLE;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.write_off('c-c3','n07-key-writeoff');
RESET ROLE;
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'dc',public.get_contract_documents(t.id('c-c1b'));
INSERT INTO t.docs SELECT 'dw',public.get_contract_documents(t.id('c-c3'));
INSERT INTO t.docs SELECT 'pc',public.record_contract_document_print(t.id('c-c1b'),'contract');
SELECT t.error_detail('closed: the notes of a settled contract are CONTRACT_NOT_OPEN',
  format('SELECT public.record_contract_document_print(%L,%L)',t.id('c-c1b'),'promissory_notes'),'CONTRACT_NOT_OPEN',
  jsonb_build_object('contract_id',t.id('c-c1b'),'status','completed'));
SELECT t.error('closed: the notes of a written-off contract are CONTRACT_NOT_OPEN',
  format('SELECT public.record_contract_document_print(%L,%L)',t.id('c-c3'),'promissory_notes'),'CONTRACT_NOT_OPEN');
RESET ROLE;
SELECT t.expect('closed: the contract still prints for the file, with its status mark and no notes',
  t.doc('dc')->>'status_mark'='completed' AND t.doc('dc')->'notes'='[]'::jsonb AND t.doc('pc')='{"print_no":1,"copy":false}'::jsonb
  AND t.doc('dw')->>'status_mark'='written_off' AND t.doc('dw')->'notes'='[]'::jsonb);

-- ================================================================ access and isolation
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('access: an unknown contract is CONTRACT_NOT_FOUND (read)',format('SELECT public.get_contract_documents(%L)',gen_random_uuid()),'CONTRACT_NOT_FOUND');
SELECT t.error('access: an unknown contract is CONTRACT_NOT_FOUND (print)',format('SELECT public.record_contract_document_print(%L,%L)',gen_random_uuid(),'contract'),'CONTRACT_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0910000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('isolation: another shop''s contract is CONTRACT_NOT_FOUND (read)',format('SELECT public.get_contract_documents(%L)',t.id('c-c2')),'CONTRACT_NOT_FOUND');
SELECT t.error('isolation: another shop''s contract is CONTRACT_NOT_FOUND (print)',format('SELECT public.record_contract_document_print(%L,%L)',t.id('c-c2'),'contract'),'CONTRACT_NOT_FOUND');
RESET ROLE;
SELECT t.expect('isolation: shop b''s refused print wrote nothing for contract c2',
  NOT EXISTS (SELECT 1 FROM public.audit_log WHERE entity_id=t.id('c-c2') AND action='contract.document_printed'));
CREATE FUNCTION t.denied(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_err text;
BEGIN
  PERFORM t.as_user(t.u(p_who),t.org('a'));
  SET LOCAL ROLE authenticated;
  BEGIN EXECUTE p_sql; v_err := ''; EXCEPTION WHEN others THEN v_err := SQLERRM; END;
  RESET ROLE;
  RETURN v_err;
END $$;
GRANT EXECUTE ON FUNCTION t.denied(text,text) TO authenticated;
SELECT t.expect('permission: '||w||' cannot read the documents',
  t.denied(w,format('SELECT public.get_contract_documents(%L)',t.id('c-c2'))) LIKE 'PERMISSION_DENIED%')
FROM unnest(ARRAY['accountant','warehouse','col1','col2']) w;
SELECT t.expect('permission: '||w||' cannot log a print',
  t.denied(w,format('SELECT public.record_contract_document_print(%L,%L)',t.id('c-c2'),'contract')) LIKE 'PERMISSION_DENIED%')
FROM unnest(ARRAY['accountant','warehouse','col1','col2']) w;
SELECT t.expect('permission: the documents need installment.create or customer.view_pii (the roles that hold one)',
  (SELECT array_agg(DISTINCT rp.role::text ORDER BY rp.role::text) FROM public.role_permissions rp WHERE rp.permission_key IN ('installment.create','customer.view_pii'))
  = ARRAY['BRANCH_MANAGER','CASHIER','LAWYER'],
  (SELECT string_agg(DISTINCT rp.role::text,',') FROM public.role_permissions rp WHERE rp.permission_key IN ('installment.create','customer.view_pii')));

-- ================================================================ an expired shop
RESET ROLE;
UPDATE public.organizations SET subscription_start=NULL, subscription_end=app.org_today(id)-1 WHERE id=t.org('a');
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired: the documents can still be read',
  (public.get_contract_documents(t.id('c-c2'))->'contract'->>'id')=t.id('c-c2')::text);
SELECT t.error('expired: a print is refused (the client prints a copy)',format('SELECT public.record_contract_document_print(%L,%L)',t.id('c-c2'),'contract'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;

-- ================================================================ the word lists and the grants
SELECT t.expect('lists: the SQL checks find every forbidden word and accept all sixteen placeholders',
  (SELECT bool_and((app.contract_template_problems('x '||w||' y')->'words') <> '[]'::jsonb) FROM unnest(ARRAY['فائدة','فوائد','سعر الفائدة','قرض','غرامة','غرامات','غرامة تأخير','خصم السداد المبكر','interest','loan','late fee','penalty']) w)
  AND app.contract_template_problems('{{shop_name}}{{shop_legal_name}}{{commercial_register}}{{branch_name}}{{city}}{{contract_number}}{{contract_date}}{{customer_name}}{{customer_national_id}}{{installment_price}}{{installment_price_words}}{{down_payment}}{{installments_count}}{{frequency}}{{first_due_date}}{{last_due_date}}')
      = '{"unknown":[],"words":[]}'::jsonb);
SELECT t.expect('grants: the two functions are for authenticated only; the helpers are not callable',
  has_function_privilege('authenticated','public.get_contract_documents(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.record_contract_document_print(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_contract_documents(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.record_contract_document_print(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.contract_document_prints(uuid,uuid,text,integer)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.contract_template_problems(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.get_shop_settings_t01()','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.update_org_settings_p04(jsonb)','EXECUTE')
  AND NOT has_function_privilege('anon','public.update_org_settings(jsonb)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
