-- L01 + N09 legal module (EC-108, EC-88, D92).
-- Run by: node scripts/db-smoke.mjs supabase/tests/l01_legal_module_test.sql (inside BEGIN ... ROLLBACK).
-- A defaulted contract becomes a legal case (from N04's referral or straight from the contract), one open case
-- per contract, a lawyer sees only the cases assigned to them, the status chain, hearings, notes, the claim
-- rule, the customer block, the flag on the contract (N09), what was paid since the case opened, and: nothing
-- a legal function does ever changes what a customer owes (Islamic finance rule 4: no fee, no cost).
-- The clock can't move in a test: t.late() / t.backdate() / t.age_hearings() move dates back, which is the same
-- as those days passing.
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
-- The nightly job for shop a (service role in production; here as the test's superuser).
CREATE FUNCTION t.run(s text DEFAULT 'a') RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN PERFORM t.as_user(NULL); RETURN public.jobs_overdue_run(t.org(s)); END $$;
CREATE FUNCTION t.zero(r jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT (r->>'warnings_created')::int=0 AND (r->>'warnings_resolved')::int=0 AND (r->>'bans')::int=0
     AND (r->>'customers_blocked')::int=0 AND (r->>'legal_referrals')::int=0 $$;
CREATE FUNCTION t.acts(c text,k text,st text DEFAULT NULL) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.overdue_actions WHERE contract_id=t.id(c) AND kind::text=k AND (st IS NULL OR status::text=st) $$;
CREATE FUNCTION t.cstatus(c text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT status::text FROM public.customers WHERE id=t.id(c) $$;
-- What anyone owes, for every contract of shop a, and everything the check may write.
CREATE FUNCTION t.owed() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws(':',cb.contract_id,cb.total_payable,cb.paid,cb.remaining,cb.fees_due),',' ORDER BY cb.contract_id)
       ||'/'||(SELECT count(*) FROM public.payments WHERE organization_id=t.org('a'))
       ||'/'||(SELECT count(*) FROM public.charges WHERE organization_id=t.org('a'))
       ||'/'||(SELECT count(*) FROM public.schedule_lines WHERE organization_id=t.org('a'))
  FROM public.v_contract_balances cb WHERE cb.organization_id=t.org('a') $$;
CREATE FUNCTION t.footprint() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',
    (SELECT count(*) FROM public.overdue_actions WHERE organization_id=t.org('a')),
    (SELECT string_agg(status::text,',' ORDER BY id) FROM public.overdue_actions WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a')),
    (SELECT string_agg(status::text,',' ORDER BY id) FROM public.customers WHERE organization_id=t.org('a'))) $$;
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
CREATE FUNCTION t.sell_q(p_customer text) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT t.sell(%L,%L)',p_customer,'n04-key-'||md5(random()::text)) $$;
-- The cashier pays one contract in cash (N03).
CREATE FUNCTION t.pay(c text,cust text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_collection(jsonb_build_object('customer_id',t.id(cust),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id(c),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;


-- ---------------------------------------------------------------- L01 helpers
CREATE FUNCTION t.audits(a text) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.audit_log WHERE organization_id=t.org('a') AND action=a $$;
CREATE FUNCTION t.cases(c text) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int FROM public.legal_cases WHERE contract_id=t.id(c) $$;
-- What every legal function must leave alone: what anyone owes, every money row, the schedule.
CREATE FUNCTION t.money() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT t.owed()||'/'||(SELECT count(*) FROM public.payment_allocations WHERE organization_id=t.org('a'))
    ||'/'||(SELECT count(*) FROM public.cash_movements WHERE organization_id=t.org('a'))
    ||'/'||(SELECT count(*) FROM public.stock_movements WHERE organization_id=t.org('a'))
    ||'/'||(SELECT string_agg(due_date::text||amount::text,',' ORDER BY id) FROM public.schedule_lines WHERE organization_id=t.org('a')) $$;
CREATE FUNCTION t.caseid(tag text) RETURNS uuid LANGUAGE sql AS $$ SELECT (t.doc(tag)->>'id')::uuid $$;
CREATE FUNCTION t.who(sub text,o text) RETURNS void LANGUAGE sql AS $$ SELECT t.as_user(sub,t.org(o)) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a and b (legal), c (no legal module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('L01 '||s,'l01-key-'||s,p,'Owner',s||'l01@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','enterprise',repeat('s',64)),('b','enterprise',repeat('u',64)),('c','retail',repeat('v',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES
  ('a1010000-0000-0000-8000-000000000001','al01@example.com'),('a1010000-0000-0000-8000-000000000002','bl01@example.com'),
  ('a1010000-0000-0000-8000-000000000003','l01cashier@example.com'),('a1010000-0000-0000-8000-000000000004','l01manager@example.com'),
  ('a1010000-0000-0000-8000-000000000005','l01collector@example.com'),('a1010000-0000-0000-8000-000000000006','l01lawyer1@example.com'),
  ('a1010000-0000-0000-8000-000000000007','l01lawyer2@example.com'),('a1010000-0000-0000-8000-000000000008','cl01@example.com');
SELECT public.accept_invite(repeat('s',64),'a1010000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('u',64),'a1010000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('v',64),'a1010000-0000-0000-8000-000000000008');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0,overdue_warning_interval_days=10,
    legal_referral_days='{"daily":35,"weekly":63,"monthly":63}'
  WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'),t.org('c'));
SELECT t.as_user('a1010000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"L1-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',30)),'l01-key-found');
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id,phone) VALUES(t.org('a'),sub,name,r,t.id('main'),'0100000'||right(tag,1)||'000') RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a1010000-0000-0000-8000-000000000003','L01 Cashier','CASHIER');
SELECT t.emp('manager','a1010000-0000-0000-8000-000000000004','L01 Manager','BRANCH_MANAGER');
SELECT t.emp('collector','a1010000-0000-0000-8000-000000000005','L01 Collector','COLLECTOR');
SELECT t.emp('lawyer1','a1010000-0000-0000-8000-000000000006','L01 Lawyer One','LAWYER');
SELECT t.emp('lawyer2','a1010000-0000-0000-8000-000000000007','L01 Lawyer Two','LAWYER');
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,'active','291010101004'||right(p_phone,2)) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('r','Rania Referral','01022220001');
SELECT t.cust('d','Dina Direct','01022220002');
SELECT t.cust('k','Karim OnTime','01022220003');
SELECT t.cust('bk','Basma Blocked','01022220004');
SELECT t.cust('tw','Tarek Twice','01022220005');
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');

SELECT t.as_user('a1010000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','l01-key-shift');
INSERT INTO t.docs SELECT 's-'||c,t.sell(c,'l01-key-sale-'||c) FROM unnest(ARRAY['r','d','k','bk','tw']) c;
RESET ROLE;
INSERT INTO t.ids SELECT 'c-'||c,(t.doc('s-'||c)->'contract'->>'id')::uuid FROM unnest(ARRAY['r','d','k','bk','tw']) c;
-- The customer of c-bk was blocked by hand before any case.
UPDATE public.customers SET status='blocked' WHERE id=t.id('bk');
SELECT t.expect('setup: five contracts of 12 lines, every line in the future; shop a and b have the legal module, c does not',
  (SELECT count(*)=5 FROM public.contracts WHERE organization_id=t.org('a'))
  AND (SELECT min(due_date)>t.today() FROM public.schedule_lines WHERE organization_id=t.org('a'))
  AND app.org_has_module(t.org('a'),'legal') AND app.org_has_module(t.org('b'),'legal') AND NOT app.org_has_module(t.org('c'),'legal'));
-- c-r: 63 days late -> a legal referral; the others fall behind a few days; c-k stays on time.
SELECT t.late('c-r',1,63);
SELECT t.late('c-d',1,5);
SELECT t.late('c-bk',1,10);
SELECT t.late('c-tw',1,10);
INSERT INTO t.docs SELECT 'run',t.run();
SELECT t.expect('setup: the check made one open legal referral (c-r) and blocked nobody (ban days 0)',
  t.acts('c-r','legal_referral','open')=1 AND t.acts('c-d','legal_referral')=0 AND (t.doc('run')->>'customers_blocked')::int=0
  AND t.cstatus('r')='active' AND t.cstatus('bk')='blocked');
INSERT INTO t.ids SELECT 'ref-r',id FROM public.overdue_actions WHERE contract_id=t.id('c-r') AND kind='legal_referral';

-- A payment of 1 000 before any case, dated 3 days back, so the "paid before the case" cut-off has something to cut.
SELECT t.as_user('a1010000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.pay('c-r','r','1000.00','l01-key-pay-before');
RESET ROLE;
CREATE FUNCTION t.backdate(c text,k integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SET LOCAL session_replication_role = replica;
  UPDATE public.payments SET business_date=business_date-k WHERE id IN (
    SELECT pa.payment_id FROM public.payment_allocations pa WHERE pa.contract_id=t.id(c));
  SET LOCAL session_replication_role = origin;
END $$;
SELECT t.backdate('c-r',3);
INSERT INTO t.docs SELECT 'money0',to_jsonb(t.money());

-- ================================================================ the schema and the grants (decision 2, 14)
SELECT t.expect('schema: opened_on is NOT NULL, outcome_kind exists, the closed/outcome CHECK exists',
  (SELECT is_nullable='NO' FROM information_schema.columns WHERE table_schema='public' AND table_name='legal_cases' AND column_name='opened_on')
  AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='legal_cases' AND column_name='outcome_kind')
  AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.legal_cases'::regclass AND conname='legal_cases_closed_outcome_check'));
SELECT t.expect('no fee: no column of the three legal tables is about a fee, a cost or a charge',
  NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
              AND table_name IN ('legal_cases','legal_hearings','legal_case_notes') AND column_name ~* 'fee|cost|charge|penalt|interest'));
SELECT t.expect('rls: the three tables have no policy and no grant for authenticated or anon',
  NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename IN ('legal_cases','legal_hearings','legal_case_notes'))
  AND NOT has_table_privilege('authenticated','public.legal_cases','SELECT') AND NOT has_table_privilege('authenticated','public.legal_hearings','SELECT')
  AND NOT has_table_privilege('authenticated','public.legal_case_notes','SELECT') AND NOT has_table_privilege('anon','public.legal_cases','SELECT')
  AND NOT has_table_privilege('authenticated','public.legal_cases','INSERT') AND NOT has_table_privilege('authenticated','public.legal_cases','UPDATE'));
SELECT t.expect('lawyer role: exactly legal.view, legal.manage, customer.view_pii and overdue.view, nothing about sales or cash',
  (SELECT array_agg(permission_key ORDER BY permission_key) FROM public.role_permissions WHERE role='LAWYER')
    =ARRAY['customer.view_pii','legal.manage','legal.view','overdue.view']);
SELECT t.expect('grants: helpers are not executable; the nine public functions are, for authenticated only',
  NOT has_function_privilege('authenticated','app.can_see_legal_case(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.legal_case_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.legal_case_for_write(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.open_legal_case(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.open_legal_case(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.update_legal_case(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_legal_case_status(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.add_legal_hearing(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.update_legal_hearing(uuid,uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.add_legal_case_note(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_legal_case(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_legal_cases(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_lawyers()','EXECUTE'));

-- ================================================================ who can open (decision 4, 6)
SELECT t.who('a1010000-0000-0000-8000-000000000003','a');
SET ROLE authenticated;
SELECT t.error('open: a cashier is refused',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r')),'l01-key-x-cashier'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.who('a1010000-0000-0000-8000-000000000005','a');
SET ROLE authenticated;
SELECT t.error('open: a collector is refused',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r')),'l01-key-x-collector'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.who('a1010000-0000-0000-8000-000000000004','a');
SET ROLE authenticated;
SELECT t.error('open: a branch manager (legal.view only) is refused',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r')),'l01-key-x-manager'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
SELECT t.error('open: a lawyer (legal.manage) can''t open, only the owner',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r')),'l01-key-x-lawyer'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.expect('open: the refusals wrote nothing',t.cases('c-r')=0 AND t.audits('legal.case_opened')=0);

-- ================================================================ open from the referral (decision 6)
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
SELECT t.error('open: an unknown key in the body',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r'),'fee','5'),'l01-key-x-unknown'),'VALIDATION_FAILED');
SELECT t.error('open: no contract id',$q$SELECT public.open_legal_case('{}','l01-key-x-nocontract')$q$,'VALIDATION_FAILED');
SELECT t.error('open: a claim that is not a money string',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r'),'claim_amount',100),'l01-key-x-num'),'VALIDATION_FAILED');
SELECT t.error('open: a claim of 0',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r'),'claim_amount','0.00'),'l01-key-x-zero'),'VALIDATION_FAILED');
SELECT t.error_detail('open: a claim above what the contract still owes',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r'),'claim_amount','11000.01'),'l01-key-x-high'),
  'LEGAL_CLAIM_TOO_HIGH','{"remaining":"11000.00"}');
SELECT t.error('open: the lawyer must be a LAWYER employee (a cashier is not)',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r'),'lawyer_employee_id',t.id('cashier')),'l01-key-x-badlawyer'),'LAWYER_INVALID');
SELECT t.error('open: a contract with nothing overdue and no referral',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-k')),'l01-key-x-notdefaulted'),'LEGAL_CONTRACT_NOT_DEFAULTED');
SELECT t.error('open: an unknown contract',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',gen_random_uuid()),'l01-key-x-unknowncontract'),'CONTRACT_NOT_FOUND');
SELECT t.error('open: the idempotency key is required (8+ characters)',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r')),'short'),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('open: every refusal wrote nothing',t.cases('c-r')=0 AND t.cases('c-k')=0 AND t.audits('legal.case_opened')=0 AND t.cstatus('r')='active');

INSERT INTO t.docs SELECT 'audits0',to_jsonb(t.audits('customer.status_set'));
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'open-r',public.open_legal_case(jsonb_build_object('contract_id',t.id('c-r'),'lawyer_employee_id',t.id('lawyer1'),
  'court','Cairo Economic Court','case_type','Civil','note','First note: referral from the overdue list'),'l01-key-open-r');
RESET ROLE;
INSERT INTO t.ids SELECT 'case-r',t.caseid('open-r');
SELECT t.expect('open (referral): preparing, number LC, opened today, claim = what the contract still owes (11 000), the first note',
  t.doc('open-r')->>'status'='preparing' AND t.doc('open-r')->>'number' ~ '-LC-' AND (t.doc('open-r')->>'opened_on')::date=t.today()
  AND t.doc('open-r')->>'claim_amount'='11000.00' AND t.doc('open-r')->>'remaining'='11000.00'
  AND jsonb_array_length(t.doc('open-r')->'notes')=1 AND t.doc('open-r')->'notes'->0->>'created_by_name'='Owner'
  AND t.doc('open-r')->'contract'->>'id'=t.id('c-r')::text AND t.doc('open-r')->'customer'->>'id'=t.id('r')::text
  AND t.doc('open-r')->'lawyer'->>'name'='L01 Lawyer One',t.doc('open-r')::text);
SELECT t.expect('open (referral): the referral became case_opened with the case id; the detail names it',
  (SELECT status::text='case_opened' AND legal_case_id=t.id('case-r') FROM public.overdue_actions WHERE id=t.id('ref-r'))
  AND t.doc('open-r')->'referral'->>'id'=t.id('ref-r')::text AND (t.doc('open-r')->'referral'->>'days_late')::int=63);
SELECT t.expect('open (customer block): an active customer is blocked, with one audit row (warning, reason names the case)',
  t.cstatus('r')='blocked' AND t.audits('customer.status_set')=(t.doc('audits0')#>>'{}')::int+1
  AND (SELECT severity='warning' AND reason=format('Legal case %s opened',t.doc('open-r')->>'number') AND employee_id IS NOT NULL
       FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.status_set' AND entity_id=t.id('r')));
SELECT t.expect('open (audit): legal.case_opened once, with the case, the contract, the claim and the referral',
  (SELECT count(*)=1 AND bool_and(after->>'legal_case_id'=t.id('case-r')::text AND after->>'contract_id'=t.id('c-r')::text
        AND after->>'claim_amount'='11000.00' AND after->>'referral_id'=t.id('ref-r')::text)
   FROM public.audit_log WHERE organization_id=t.org('a') AND action='legal.case_opened'));
SELECT t.expect('done when: the detail''s guarantors equal the contract''s',
  t.doc('open-r')->'guarantors'=app.contract_json(t.org('a'),t.id('c-r'))->'guarantors');
SELECT t.expect('done when: paid before the case + paid since opened = what the contract has paid (1 000 before)',
  (t.doc('open-r')->'amounts'->>'paid_before_case')::numeric=1000 AND (t.doc('open-r')->'amounts'->>'paid_since_opened')::numeric=0
  AND (t.doc('open-r')->'amounts'->>'paid_before_case')::numeric+(t.doc('open-r')->'amounts'->>'paid_since_opened')::numeric
      =(SELECT paid FROM public.v_contract_balances WHERE contract_id=t.id('c-r'))
  AND t.doc('open-r')->'amounts'->>'total_payable'=(SELECT total_payable::text FROM public.contracts WHERE id=t.id('c-r'))
  AND jsonb_array_length(t.doc('open-r')->'collections_since_opened')=0);

-- Idempotency (decision 6)
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'open-r2',public.open_legal_case(jsonb_build_object('contract_id',t.id('c-r'),'lawyer_employee_id',t.id('lawyer1'),
  'court','Cairo Economic Court','case_type','Civil','note','First note: referral from the overdue list'),'l01-key-open-r');
SELECT t.error('idempotency: the same key with another body is a conflict',format('SELECT public.open_legal_case(%L,%L)',
  jsonb_build_object('contract_id',t.id('c-r'),'lawyer_employee_id',t.id('lawyer1'),'court','Alexandria Court'),'l01-key-open-r'),'IDEMPOTENCY_CONFLICT');
SELECT t.error_detail('one open case: a second open on the same contract answers with the first case',format('SELECT public.open_legal_case(%L,%L)',
  jsonb_build_object('contract_id',t.id('c-r')),'l01-key-open-r-again'),'LEGAL_CASE_ALREADY_OPEN',jsonb_build_object('legal_case_id',t.id('case-r')));
RESET ROLE;
SELECT t.expect('done when (idempotency): the same request twice gives one case and the same answer',
  t.caseid('open-r2')=t.id('case-r') AND t.cases('c-r')=1 AND t.audits('legal.case_opened')=1 AND t.doc('open-r2')=t.doc('open-r'));

-- ================================================================ open straight from a contract; a blocked customer
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'open-d',public.open_legal_case(jsonb_build_object('contract_id',t.id('c-d'),'lawyer_employee_id',t.id('lawyer1'),'claim_amount','11000.00'),'l01-key-open-d');
INSERT INTO t.docs SELECT 'audits1',to_jsonb(t.audits('customer.status_set'));
INSERT INTO t.docs SELECT 'open-bk',public.open_legal_case(jsonb_build_object('contract_id',t.id('c-bk'),'lawyer_employee_id',t.id('lawyer2')),'l01-key-open-bk');
INSERT INTO t.docs SELECT 'open-tw',public.open_legal_case(jsonb_build_object('contract_id',t.id('c-tw')),'l01-key-open-tw');
RESET ROLE;
INSERT INTO t.ids SELECT 'case-d',t.caseid('open-d');
INSERT INTO t.ids SELECT 'case-bk',t.caseid('open-bk');
INSERT INTO t.ids SELECT 'case-tw',t.caseid('open-tw');
SELECT t.expect('open (direct): no referral needed, the claim as given, no referral on the detail, the customer blocked',
  t.doc('open-d')->>'claim_amount'='11000.00' AND t.doc('open-d')->'referral'='null'::jsonb AND t.cstatus('d')='blocked'
  AND jsonb_array_length(t.doc('open-d')->'notes')=0,t.doc('open-d')::text);
SELECT t.expect('open: a customer who was already blocked gets no second status change or audit row',
  t.cstatus('bk')='blocked' AND t.audits('customer.status_set')=(t.doc('audits1')#>>'{}')::int+1
  AND NOT EXISTS (SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.status_set' AND entity_id=t.id('bk')));
SELECT t.expect('open: a case without a lawyer stays in preparing with no lawyer',t.doc('open-tw')->'lawyer'='null'::jsonb AND t.doc('open-tw')->>'status'='preparing');
SELECT t.expect('open (done when): the case, the customer and the audit rows exist once per contract',
  t.cases('c-d')=1 AND t.cases('c-bk')=1 AND t.cases('c-tw')=1 AND t.audits('legal.case_opened')=4);

-- ================================================================ the flag on the contract (N09, decision 13)
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'gc-owner',public.get_contract(t.id('c-r'));
INSERT INTO t.docs SELECT 'gc-ok',public.get_contract(t.id('c-k'));
INSERT INTO t.docs SELECT 'overdue-owner',public.list_overdue_contracts('{}');
RESET ROLE;
SELECT t.expect('flag: the contract carries the open case (id, number, status, opened_on); a contract without one carries null',
  t.doc('gc-owner')->'legal_case'->>'id'=t.id('case-r')::text AND t.doc('gc-owner')->'legal_case'->>'status'='preparing'
  AND t.doc('gc-owner')->'legal_case'->>'number'=t.doc('open-r')->>'number' AND (t.doc('gc-owner')->'legal_case'->>'opened_on')::date=t.today()
  AND t.doc('gc-ok')->'legal_case'='null'::jsonb);
SELECT t.expect('flag: the customer account''s contract row carries it too',
  app.customer_contract_json(t.org('a'),t.id('c-r'))->'legal_case'->>'id'=t.id('case-r')::text
  AND app.customer_contract_json(t.org('a'),t.id('c-k'))->'legal_case'='null'::jsonb);
SELECT t.expect('flag: the overdue list rows carry it (id, number, status), and null when there is none',
  (SELECT bool_and((r->'legal_case'->>'id')=t.id('case-r')::text) FROM jsonb_array_elements(t.doc('overdue-owner')->'items') r WHERE r->'contract'->>'id'=t.id('c-r')::text)
  AND (SELECT count(*)=4 FROM jsonb_array_elements(t.doc('overdue-owner')->'items') r WHERE r->'legal_case' <> 'null'::jsonb)
  AND (SELECT r->'legal_case'->>'status'='preparing' FROM jsonb_array_elements(t.doc('overdue-owner')->'items') r WHERE r->'contract'->>'id'=t.id('c-d')::text));
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'gc-lawyer1',public.get_contract(t.id('c-r'));
INSERT INTO t.docs SELECT 'gc-lawyer1-other',public.get_contract(t.id('c-bk'));
RESET ROLE;
SELECT t.expect('flag: a lawyer reads the contract and sees the flag of any open case (the id only opens for their own)',
  t.doc('gc-lawyer1')->'legal_case'->>'id'=t.id('case-r')::text AND t.doc('gc-lawyer1-other')->'legal_case'->>'id'=t.id('case-bk')::text);

-- ================================================================ a lawyer sees only their cases (decision 3)
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'list-l1',public.list_legal_cases('{"status":"all"}');
INSERT INTO t.docs SELECT 'list-l1-filter',public.list_legal_cases(jsonb_build_object('status','all','lawyer_id',t.id('lawyer2')));
INSERT INTO t.docs SELECT 'get-l1',public.get_legal_case(t.id('case-r'));
SELECT t.error('lawyer: another lawyer''s case reads as not found',format('SELECT public.get_legal_case(%L)',t.id('case-bk')),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('lawyer: a case without a lawyer is not theirs either',format('SELECT public.get_legal_case(%L)',t.id('case-tw')),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('lawyer: can''t change another lawyer''s case',format('SELECT public.update_legal_case(%L,%L)',t.id('case-bk'),'{"court":"X"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('lawyer: can''t move another lawyer''s case',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-bk'),'{"status":"filed"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('lawyer: can''t add a hearing to another lawyer''s case',format('SELECT public.add_legal_hearing(%L,%L)',t.id('case-bk'),'{"hearing_date":"2030-01-01"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('lawyer: can''t add a note to another lawyer''s case',format('SELECT public.add_legal_case_note(%L,%L)',t.id('case-bk'),'{"note":"hello there"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('lawyer: can''t list the lawyers (owner only)','SELECT public.list_lawyers()','PERMISSION_DENIED');
SELECT t.error('lawyer: a direct table read is refused','SELECT count(*) FROM public.legal_cases','permission denied for table legal_cases');
RESET ROLE;
SELECT t.expect('lawyer: lawyer one''s list is their two cases (a lawyer_id filter is ignored); the detail opens',
  jsonb_array_length(t.doc('list-l1')->'rows')=2 AND jsonb_array_length(t.doc('list-l1-filter')->'rows')=2
  AND (SELECT array_agg((r->>'id')::uuid ORDER BY r->>'id') FROM jsonb_array_elements(t.doc('list-l1')->'rows') r)
      =(SELECT array_agg(i ORDER BY i::text) FROM unnest(ARRAY[t.id('case-r'),t.id('case-d')]) i)
  AND t.doc('get-l1')->>'id'=t.id('case-r')::text);
SELECT t.who('a1010000-0000-0000-8000-000000000007','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'list-l2',public.list_legal_cases('{"status":"all"}');
RESET ROLE;
SELECT t.expect('lawyer: lawyer two sees only theirs (the case of the blocked customer)',
  jsonb_array_length(t.doc('list-l2')->'rows')=1 AND t.doc('list-l2')->'rows'->0->>'id'=t.id('case-bk')::text);
SELECT t.who('a1010000-0000-0000-8000-000000000004','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'list-mgr',public.list_legal_cases('{"status":"all"}');
SELECT t.error('manager: reads of a case that is not assigned to them are refused',format('SELECT public.get_legal_case(%L)',t.id('case-r')),'LEGAL_CASE_NOT_FOUND');
RESET ROLE;
SELECT t.expect('manager: holds legal.view but sees no case that is not assigned to them',jsonb_array_length(t.doc('list-mgr')->'rows')=0);
SELECT t.who('a1010000-0000-0000-8000-000000000003','a');
SET ROLE authenticated;
SELECT t.error('cashier: no legal.view, no list','SELECT public.list_legal_cases()','PERMISSION_DENIED');
SELECT t.error('cashier: no legal.view, no case',format('SELECT public.get_legal_case(%L)',t.id('case-r')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.who('a1010000-0000-0000-8000-000000000005','a');
SET ROLE authenticated;
SELECT t.error('collector: no legal.view, no list','SELECT public.list_legal_cases()','PERMISSION_DENIED');
RESET ROLE;

-- ================================================================ the owner's list: order, filters, paging (route 1)
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'h-d',public.add_legal_hearing(t.id('case-d'),jsonb_build_object('hearing_date',(t.today()+3)::text));
INSERT INTO t.docs SELECT 'h-r',public.add_legal_hearing(t.id('case-r'),jsonb_build_object('hearing_date',(t.today()+10)::text,'notes','First hearing'));
INSERT INTO t.docs SELECT 'list-o',public.list_legal_cases('{}');
INSERT INTO t.docs SELECT 'page1',public.list_legal_cases('{"limit":1}');
INSERT INTO t.docs SELECT 'page2',public.list_legal_cases(jsonb_build_object('limit',1,'cursor',t.doc('page1')->>'next_cursor'));
INSERT INTO t.docs SELECT 'page3',public.list_legal_cases(jsonb_build_object('limit',1,'cursor',t.doc('page2')->>'next_cursor'));
INSERT INTO t.docs SELECT 'page4',public.list_legal_cases(jsonb_build_object('limit',2,'cursor',t.doc('page2')->>'next_cursor'));
INSERT INTO t.docs SELECT 'list-q-name',public.list_legal_cases('{"q":"Rania"}');
INSERT INTO t.docs SELECT 'list-q-phone',public.list_legal_cases('{"q":"0102222000"}');
INSERT INTO t.docs SELECT 'list-q-contract',public.list_legal_cases(jsonb_build_object('q',(SELECT number FROM public.contracts WHERE id=t.id('c-tw'))));
INSERT INTO t.docs SELECT 'list-q-case',public.list_legal_cases(jsonb_build_object('q',t.doc('open-bk')->>'number'));
INSERT INTO t.docs SELECT 'list-lawyer',public.list_legal_cases(jsonb_build_object('lawyer_id',t.id('lawyer2')));
INSERT INTO t.docs SELECT 'list-closed',public.list_legal_cases('{"status":"closed"}');
SELECT t.error('list: an unknown filter','SELECT public.list_legal_cases(''{"fee":"1"}'')','VALIDATION_FAILED');
SELECT t.error('list: a bad status','SELECT public.list_legal_cases(''{"status":"filed"}'')','VALIDATION_FAILED');
SELECT t.error('list: limit 101','SELECT public.list_legal_cases(''{"limit":101}'')','VALIDATION_FAILED');
SELECT t.error('list: a broken cursor','SELECT public.list_legal_cases(''{"cursor":"x|y"}'')','VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('list: the owner sees the four open cases, the soonest hearing first (d in 3 days, r in 10), then those without one',
  jsonb_array_length(t.doc('list-o')->'rows')=4 AND t.doc('list-o')->'rows'->0->>'id'=t.id('case-d')::text
  AND t.doc('list-o')->'rows'->1->>'id'=t.id('case-r')::text AND t.doc('list-o')->'rows'->0->>'next_hearing_date'=(t.today()+3)::text
  AND t.doc('list-o')->'rows'->2->>'next_hearing_date' IS NULL AND t.doc('list-o')->>'next_cursor' IS NULL);
SELECT t.expect('list: a row has the contract, the customer (with status), the lawyer and the amounts',
  t.doc('list-o')->'rows'->0->'contract'->>'number'=(SELECT number FROM public.contracts WHERE id=t.id('c-d'))
  AND t.doc('list-o')->'rows'->0->'customer'->>'name'='Dina Direct' AND t.doc('list-o')->'rows'->0->'customer'->>'status'='blocked'
  AND t.doc('list-o')->'rows'->0->'lawyer'->>'name'='L01 Lawyer One' AND t.doc('list-o')->'rows'->0->>'claim_amount'='11000.00'
  AND t.doc('list-o')->'rows'->0->>'remaining'='12000.00');
SELECT t.expect('list: keyset paging one by one walks the same order and ends with no cursor',
  t.doc('page1')->'rows'->0->>'id'=t.doc('list-o')->'rows'->0->>'id' AND t.doc('page2')->'rows'->0->>'id'=t.doc('list-o')->'rows'->1->>'id'
  AND t.doc('page3')->'rows'->0->>'id'=t.doc('list-o')->'rows'->2->>'id' AND t.doc('page1')->>'next_cursor' IS NOT NULL
  AND t.doc('page4')->'rows'->1->>'id'=t.doc('list-o')->'rows'->3->>'id' AND t.doc('page4')->>'next_cursor' IS NULL);
SELECT t.expect('list: search by customer name, phone, contract number and case number; the lawyer filter works for the owner',
  jsonb_array_length(t.doc('list-q-name')->'rows')=1 AND t.doc('list-q-name')->'rows'->0->>'id'=t.id('case-r')::text
  AND jsonb_array_length(t.doc('list-q-phone')->'rows')=4
  AND jsonb_array_length(t.doc('list-q-contract')->'rows')=1 AND t.doc('list-q-contract')->'rows'->0->>'id'=t.id('case-tw')::text
  AND jsonb_array_length(t.doc('list-q-case')->'rows')=1 AND t.doc('list-q-case')->'rows'->0->>'id'=t.id('case-bk')::text
  AND jsonb_array_length(t.doc('list-lawyer')->'rows')=1 AND t.doc('list-lawyer')->'rows'->0->>'id'=t.id('case-bk')::text
  AND jsonb_array_length(t.doc('list-closed')->'rows')=0);
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'lawyers',public.list_lawyers();
RESET ROLE;
SELECT t.expect('lawyers: the owner picks from the two active lawyers with their open cases',
  jsonb_array_length(t.doc('lawyers')->'items')=2
  AND (SELECT (i->>'open_cases')::int FROM jsonb_array_elements(t.doc('lawyers')->'items') i WHERE i->>'id'=t.id('lawyer1')::text)=2
  AND (SELECT (i->>'open_cases')::int FROM jsonb_array_elements(t.doc('lawyers')->'items') i WHERE i->>'id'=t.id('lawyer2')::text)=1
  AND (SELECT i->>'phone' IS NOT NULL FROM jsonb_array_elements(t.doc('lawyers')->'items') i WHERE i->>'id'=t.id('lawyer1')::text));

-- ================================================================ money received through the court (decision 12)
-- The cashier collects 500 after the case was opened: a normal N03 collection, the case only reads it.
SELECT t.who('a1010000-0000-0000-8000-000000000003','a');
SET ROLE authenticated;
SELECT t.pay('c-r','r','500.00','l01-key-pay-after');
RESET ROLE;
INSERT INTO t.docs SELECT 'money1',to_jsonb(t.money());
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'get-r2',public.get_legal_case(t.id('case-r'));
RESET ROLE;
SELECT t.expect('amounts: 1 000 paid before, 500 since the case was opened, 10 500 left; claim stays as opened',
  (t.doc('get-r2')->'amounts'->>'paid_before_case')::numeric=1000 AND (t.doc('get-r2')->'amounts'->>'paid_since_opened')::numeric=500
  AND (t.doc('get-r2')->'amounts'->>'remaining')::numeric=10500 AND t.doc('get-r2')->'amounts'->>'claim_amount'='11000.00'
  AND (t.doc('get-r2')->'amounts'->>'paid_before_case')::numeric+(t.doc('get-r2')->'amounts'->>'paid_since_opened')::numeric
      =(SELECT paid FROM public.v_contract_balances WHERE contract_id=t.id('c-r')),(t.doc('get-r2')->'amounts')::text);
SELECT t.expect('amounts: the collections since opened list the receipt, its date, the amount on this contract and who took it',
  jsonb_array_length(t.doc('get-r2')->'collections_since_opened')=1
  AND (t.doc('get-r2')->'collections_since_opened'->0->>'amount')::numeric=500
  AND t.doc('get-r2')->'collections_since_opened'->0->>'taken_by'='L01 Cashier'
  AND (t.doc('get-r2')->'collections_since_opened'->0->>'date')::date=t.today()
  AND t.doc('get-r2')->'collections_since_opened'->0->>'number' IS NOT NULL,(t.doc('get-r2')->'collections_since_opened')::text);

-- ================================================================ update the details (decision 7)
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
SELECT t.error('update: a lawyer can''t change the lawyer (owner only)',format('SELECT public.update_legal_case(%L,%L)',t.id('case-r'),jsonb_build_object('lawyer_employee_id',t.id('lawyer2'))),'PERMISSION_DENIED');
SELECT t.error('update: an empty body',format('SELECT public.update_legal_case(%L,%L)',t.id('case-r'),'{}'),'VALIDATION_FAILED');
SELECT t.error('update: an unknown field (no fee, no cost)',format('SELECT public.update_legal_case(%L,%L)',t.id('case-r'),'{"court_fee":"100.00"}'),'VALIDATION_FAILED');
SELECT t.error_detail('update: a claim above what is still owed',format('SELECT public.update_legal_case(%L,%L)',t.id('case-r'),'{"claim_amount":"10500.01"}'),'LEGAL_CLAIM_TOO_HIGH','{"remaining":"10500.00"}');
INSERT INTO t.docs SELECT 'upd-r',public.update_legal_case(t.id('case-r'),'{"case_number":"123/2026","claim_amount":"10500.00","case_type":"Civil claim"}');
RESET ROLE;
SELECT t.expect('update: the assigned lawyer sets the court number, type and (while preparing) the claim; the audit row has before and after of what changed',
  t.doc('upd-r')->>'case_number'='123/2026' AND t.doc('upd-r')->>'claim_amount'='10500.00' AND t.doc('upd-r')->>'case_type'='Civil claim'
  AND (SELECT count(*)=1 AND bool_and(before ? 'case_number' AND after->>'case_number'='123/2026' AND before->>'claim_amount'='11000.00'
        AND after->>'claim_amount'='10500.00' AND NOT (after ? 'court'))
      FROM public.audit_log WHERE organization_id=t.org('a') AND action='legal.case_updated' AND entity_id=t.id('case-r')));
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'upd-same',public.update_legal_case(t.id('case-r'),'{"case_number":"123/2026"}');
SELECT t.error('update: the owner can''t assign a non-lawyer',format('SELECT public.update_legal_case(%L,%L)',t.id('case-tw'),jsonb_build_object('lawyer_employee_id',t.id('manager'))),'LAWYER_INVALID');
INSERT INTO t.docs SELECT 'upd-tw',public.update_legal_case(t.id('case-tw'),jsonb_build_object('lawyer_employee_id',t.id('lawyer2'),'court','Giza Court'));
RESET ROLE;
SELECT t.expect('update: nothing changed -> no second audit row; the owner assigns a lawyer to a case that had none',
  (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='legal.case_updated' AND entity_id=t.id('case-r'))
  AND t.doc('upd-tw')->'lawyer'->>'name'='L01 Lawyer Two' AND t.doc('upd-tw')->>'court'='Giza Court');

-- ================================================================ hearings (decision 9)
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
SELECT t.error('hearing: a bad date',format('SELECT public.add_legal_hearing(%L,%L)',t.id('case-r'),'{"hearing_date":"2026-13-45"}'),'VALIDATION_FAILED');
SELECT t.error('hearing: no date',format('SELECT public.add_legal_hearing(%L,%L)',t.id('case-r'),'{"notes":"x"}'),'VALIDATION_FAILED');
SELECT t.error('hearing: an unknown field',format('SELECT public.add_legal_hearing(%L,%L)',t.id('case-r'),'{"hearing_date":"2030-01-01","fee":"5"}'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'h-past',public.add_legal_hearing(t.id('case-r'),jsonb_build_object('hearing_date',(t.today()-5)::text,'notes','History'));
SELECT t.error('hearing: a hearing of another case is not found',format('SELECT public.update_legal_hearing(%L,%L,%L)',t.id('case-r'),
  (SELECT (h->>'id')::uuid FROM jsonb_array_elements(t.doc('h-d')->'hearings') h LIMIT 1),'{"outcome":"x"}'),'HEARING_NOT_FOUND');
RESET ROLE;
INSERT INTO t.ids SELECT 'hearing-past',(h->>'id')::uuid FROM jsonb_array_elements(t.doc('h-past')->'hearings') h WHERE h->>'hearing_date'=(t.today()-5)::text;
INSERT INTO t.ids SELECT 'hearing-future',(h->>'id')::uuid FROM jsonb_array_elements(t.doc('h-past')->'hearings') h WHERE h->>'hearing_date'=(t.today()+10)::text;
SELECT t.expect('hearing: a past date is allowed (history); hearings come back by date; the next hearing is the future one with no outcome',
  jsonb_array_length(t.doc('h-past')->'hearings')=2 AND t.doc('h-past')->'hearings'->0->>'hearing_date'=(t.today()-5)::text
  AND t.doc('h-past')->>'next_hearing_date'=(t.today()+10)::text
  AND (SELECT next_hearing_date=t.today()+10 FROM public.legal_cases WHERE id=t.id('case-r')));
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'h-out',public.update_legal_hearing(t.id('case-r'),t.id('hearing-future'),'{"outcome":"Adjourned to a later date"}');
INSERT INTO t.docs SELECT 'h-next',public.add_legal_hearing(t.id('case-r'),jsonb_build_object('hearing_date',(t.today()+20)::text));
INSERT INTO t.docs SELECT 'h-move',public.update_legal_hearing(t.id('case-r'),t.id('hearing-past'),jsonb_build_object('notes','Corrected note'));
RESET ROLE;
SELECT t.expect('hearing: recording the outcome of the next hearing moves "next" on; the stored date follows',
  t.doc('h-out')->>'next_hearing_date' IS NULL AND t.doc('h-next')->>'next_hearing_date'=(t.today()+20)::text
  AND (SELECT next_hearing_date=t.today()+20 FROM public.legal_cases WHERE id=t.id('case-r'))
  AND (SELECT h->>'outcome' FROM jsonb_array_elements(t.doc('h-out')->'hearings') h WHERE h->>'id'=t.id('hearing-future')::text)='Adjourned to a later date');
SELECT t.expect('hearing: the audit rows (added x4, updated x2) and the note edit stays on the hearing',
  t.audits('legal.hearing_added')=4 AND t.audits('legal.hearing_updated')=2
  AND (SELECT h->>'notes' FROM jsonb_array_elements(t.doc('h-move')->'hearings') h WHERE h->>'id'=t.id('hearing-past')::text)='Corrected note');

-- A date that passed overnight is never shown as "next": move case d's only hearing 30 days back
-- (the stored date stays as it was; the reads compute it live).
CREATE FUNCTION t.age_hearings(c text,k integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SET LOCAL session_replication_role = replica;
  UPDATE public.legal_hearings SET hearing_date=hearing_date-k WHERE case_id=t.id(c);
  SET LOCAL session_replication_role = origin;
END $$;
SELECT t.age_hearings('case-d',30);
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'aged',public.get_legal_case(t.id('case-d'));
INSERT INTO t.docs SELECT 'aged-list',public.list_legal_cases('{}');
RESET ROLE;
SELECT t.expect('hearing: a hearing date that has passed is not shown as "next", although the stored date is still the old one',
  t.doc('aged')->>'next_hearing_date' IS NULL AND (SELECT next_hearing_date=t.today()+3 FROM public.legal_cases WHERE id=t.id('case-d'))
  AND (SELECT r->>'next_hearing_date' IS NULL FROM jsonb_array_elements(t.doc('aged-list')->'rows') r WHERE r->>'id'=t.id('case-d')::text));

-- ================================================================ notes (decision 10)
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
SELECT t.error('note: an empty note',format('SELECT public.add_legal_case_note(%L,%L)',t.id('case-r'),'{"note":"   "}'),'VALIDATION_FAILED');
SELECT t.error('note: a note over 2 000 characters',format('SELECT public.add_legal_case_note(%L,%L)',t.id('case-r'),jsonb_build_object('note',repeat('x',2001))),'VALIDATION_FAILED');
SELECT t.error('note: an unknown field',format('SELECT public.add_legal_case_note(%L,%L)',t.id('case-r'),'{"note":"ok ok","cost":"5"}'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'note1',public.add_legal_case_note(t.id('case-r'),'{"note":"Spoke to the customer''s guarantor"}');
RESET ROLE;
-- (Newest first is by created_at, which is the transaction time: inside one test transaction the order of ties is by id.)
SELECT t.expect('note: appended with the author''s name and one audit row; the first note stays',
  jsonb_array_length(t.doc('note1')->'notes')=2
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('note1')->'notes') n WHERE n->>'note'='Spoke to the customer''s guarantor' AND n->>'created_by_name'='L01 Lawyer One')
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('note1')->'notes') n WHERE n->>'created_by_name'='Owner') AND t.audits('legal.note_added')=1);
SELECT t.error('note: append-only (update and delete are blocked even for the database owner)',
  format('UPDATE public.legal_case_notes SET note=%L WHERE case_id=%L','changed',t.id('case-r')),'APPEND_ONLY');
SELECT t.expect('note: the append-only trigger is on the table',
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.legal_case_notes'::regclass AND tgname='trg_legal_case_notes_append_only'));

-- ================================================================ status (decision 8)
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
SELECT t.error_detail('status: preparing -> judgment is refused',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"judgment"}'),'LEGAL_STATUS_INVALID','{"from":"preparing","to":"judgment"}');
SELECT t.error('status: preparing -> preparing is refused',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"preparing"}'),'LEGAL_STATUS_INVALID');
SELECT t.error('status: a status that does not exist',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"appealed"}'),'VALIDATION_FAILED');
SELECT t.error('status: an outcome on a move that is not a close',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"filed","outcome_kind":"paid"}'),'VALIDATION_FAILED');
RESET ROLE;
-- Filed needs a lawyer, a court and a court case number: case tw has a lawyer and a court, not a number.
SELECT t.who('a1010000-0000-0000-8000-000000000007','a');
SET ROLE authenticated;
SELECT t.error('status: filed without a case number is refused naming the field',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-tw'),'{"status":"filed"}'),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('status: the refusal named case_number',(SELECT status::text='preparing' FROM public.legal_cases WHERE id=t.id('case-tw')));
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
SELECT t.error('status: filed without a court is refused (case bk has a lawyer, no court, no number)',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-bk'),'{"status":"filed"}'),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'st-filed',public.set_legal_case_status(t.id('case-r'),'{"status":"filed"}');
SELECT t.error('claim: can''t change once filed',format('SELECT public.update_legal_case(%L,%L)',t.id('case-r'),'{"claim_amount":"10000.00"}'),'LEGAL_CASE_FILED');
INSERT INTO t.docs SELECT 'upd-court',public.update_legal_case(t.id('case-r'),'{"court":"Cairo Appeal Court"}');
SELECT t.error('court: a filed case keeps its court (can''t be cleared)',format('SELECT public.update_legal_case(%L,%L)',t.id('case-r'),'{"court":null}'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'st-court',public.set_legal_case_status(t.id('case-r'),'{"status":"in_court"}');
INSERT INTO t.docs SELECT 'st-judgment',public.set_legal_case_status(t.id('case-r'),'{"status":"judgment"}');
INSERT INTO t.docs SELECT 'st-appeal',public.set_legal_case_status(t.id('case-r'),'{"status":"in_court"}');
INSERT INTO t.docs SELECT 'st-judgment2',public.set_legal_case_status(t.id('case-r'),'{"status":"judgment"}');
SELECT t.error_detail('status: judgment -> filed is refused',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"filed"}'),'LEGAL_STATUS_INVALID','{"from":"judgment","to":"filed"}');
SELECT t.error('close: without an outcome kind',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"closed"}'),'VALIDATION_FAILED');
SELECT t.error('close: an outcome kind that does not exist',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"closed","outcome_kind":"won"}'),'VALIDATION_FAILED');
SELECT t.error('close: "other" needs a note',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"closed","outcome_kind":"other"}'),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('status: the allowed chain worked (filed, in_court, judgment, appeal back to in_court, judgment again), one audit row each',
  t.doc('st-filed')->>'status'='filed' AND t.doc('st-court')->>'status'='in_court' AND t.doc('st-judgment')->>'status'='judgment'
  AND t.doc('st-appeal')->>'status'='in_court' AND t.doc('st-judgment2')->>'status'='judgment'
  AND (SELECT count(*)=5 FROM public.audit_log WHERE organization_id=t.org('a') AND action='legal.case_status_changed' AND entity_id=t.id('case-r'))
  AND t.audits('legal.case_closed')=0 AND t.doc('st-judgment2')->>'closed_at' IS NULL);
SELECT t.expect('status: every refusal left the case where it was',(SELECT status::text='judgment' AND closed_at IS NULL AND outcome_kind IS NULL FROM public.legal_cases WHERE id=t.id('case-r')));

-- Close with an outcome. From here on nothing may change what is owed (done when).
INSERT INTO t.docs SELECT 'audits2',to_jsonb(t.audits('customer.status_set'));
SELECT t.who('a1010000-0000-0000-8000-000000000006','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'closed-r',public.set_legal_case_status(t.id('case-r'),'{"status":"closed","outcome_kind":"settled_out_of_court","outcome":"Paid the rest in a plan agreed at the court"}');
RESET ROLE;
SELECT t.expect('close: status closed, closed_at set, the outcome kind and note kept, "next hearing" cleared; the audit row is legal.case_closed',
  t.doc('closed-r')->>'status'='closed' AND t.doc('closed-r')->>'closed_at' IS NOT NULL AND t.doc('closed-r')->>'outcome_kind'='settled_out_of_court'
  AND t.doc('closed-r')->>'outcome'='Paid the rest in a plan agreed at the court' AND t.doc('closed-r')->>'next_hearing_date' IS NULL
  AND t.audits('legal.case_closed')=1 AND (SELECT next_hearing_date IS NULL FROM public.legal_cases WHERE id=t.id('case-r')));
SELECT t.expect('done when: the contract, the customer and the referral are untouched by the close (the block stays)',
  t.cstatus('r')='blocked' AND t.audits('customer.status_set')=(t.doc('audits2')#>>'{}')::int
  AND (SELECT status::text='case_opened' FROM public.overdue_actions WHERE id=t.id('ref-r'))
  AND (SELECT status::text='active' FROM public.contracts WHERE id=t.id('c-r')));
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
SELECT t.error('closed: a closed case never reopens (closed -> in_court)',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"in_court"}'),'LEGAL_STATUS_INVALID');
SELECT t.error('closed: closed -> closed',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-r'),'{"status":"closed","outcome_kind":"paid"}'),'LEGAL_STATUS_INVALID');
SELECT t.error('closed: the details can''t change',format('SELECT public.update_legal_case(%L,%L)',t.id('case-r'),'{"court":"Another court"}'),'LEGAL_CASE_CLOSED');
SELECT t.error('closed: no new hearing',format('SELECT public.add_legal_hearing(%L,%L)',t.id('case-r'),'{"hearing_date":"2030-01-01"}'),'LEGAL_CASE_CLOSED');
SELECT t.error('closed: no hearing change',format('SELECT public.update_legal_hearing(%L,%L,%L)',t.id('case-r'),t.id('hearing-past'),'{"notes":"late edit"}'),'LEGAL_CASE_CLOSED');
INSERT INTO t.docs SELECT 'note-closed',public.add_legal_case_note(t.id('case-r'),'{"note":"Follow-up after the judgment"}');
INSERT INTO t.docs SELECT 'list-closed2',public.list_legal_cases('{"status":"closed"}');
INSERT INTO t.docs SELECT 'list-open2',public.list_legal_cases('{}');
INSERT INTO t.docs SELECT 'list-all2',public.list_legal_cases('{"status":"all"}');
RESET ROLE;
SELECT t.expect('closed: a note is still allowed (follow-up after the judgment)',jsonb_array_length(t.doc('note-closed')->'notes')=3);
SELECT t.expect('list: the closed case moves to the closed tab; "all" lists open ones first',
  jsonb_array_length(t.doc('list-closed2')->'rows')=1 AND jsonb_array_length(t.doc('list-open2')->'rows')=3
  AND jsonb_array_length(t.doc('list-all2')->'rows')=4 AND t.doc('list-all2')->'rows'->3->>'id'=t.id('case-r')::text);
SELECT t.expect('flag: after the close the contract no longer carries the legal flag',
  app.contract_json(t.org('a'),t.id('c-r'))->'legal_case'='null'::jsonb AND app.customer_contract_json(t.org('a'),t.id('c-r'))->'legal_case'='null'::jsonb);
-- A new case can be opened on the same contract after the close (the one-open index allows it).
SELECT t.who('a1010000-0000-0000-8000-000000000001','a');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'open-r-again',public.open_legal_case(jsonb_build_object('contract_id',t.id('c-r'),'lawyer_employee_id',t.id('lawyer1')),'l01-key-open-r-again2');
RESET ROLE;
SELECT t.expect('done when: after closing, a new case can be opened on the same contract (a different case, no referral, no second block audit)',
  t.caseid('open-r-again')<>t.id('case-r') AND t.cases('c-r')=2 AND t.doc('open-r-again')->'referral'='null'::jsonb
  AND t.audits('customer.status_set')=(t.doc('audits2')#>>'{}')::int);
-- The customer stays blocked: an installment sale for them is refused (N02), and closing never unblocks.
SELECT t.who('a1010000-0000-0000-8000-000000000003','a');
SET ROLE authenticated;
SELECT t.error('done when: an installment sale for the customer of a legal case is refused CUSTOMER_BLOCKED',t.sell_q('r'),'CUSTOMER_BLOCKED');
RESET ROLE;

-- ================================================================ owed never changes
SELECT t.expect('done when: what anyone owes (total, paid, remaining) and every money, ledger and schedule row are identical after opening, every case write and the close',
  t.money()=(t.doc('money1')#>>'{}'),'owed changed');
SELECT t.expect('done when: the contract''s figures after the close are the ones the payments left: paid 1 500, remaining 10 500',
  (SELECT paid=1500 AND remaining=10500 FROM public.v_contract_balances WHERE contract_id=t.id('c-r')));

-- ================================================================ isolation: shop b, shop c
SELECT t.who('a1010000-0000-0000-8000-000000000002','b');
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'list-b',public.list_legal_cases('{"status":"all"}');
SELECT t.error('isolation: shop b can''t read shop a''s case',format('SELECT public.get_legal_case(%L)',t.id('case-d')),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('isolation: shop b can''t change it',format('SELECT public.update_legal_case(%L,%L)',t.id('case-d'),'{"court":"X"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('isolation: shop b can''t move it',format('SELECT public.set_legal_case_status(%L,%L)',t.id('case-d'),'{"status":"filed"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('isolation: shop b can''t add a hearing',format('SELECT public.add_legal_hearing(%L,%L)',t.id('case-d'),'{"hearing_date":"2030-01-01"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('isolation: shop b can''t add a note',format('SELECT public.add_legal_case_note(%L,%L)',t.id('case-d'),'{"note":"not yours"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('isolation: shop b can''t change shop a''s hearing (case and hearing ids of shop a)',format('SELECT public.update_legal_hearing(%L,%L,%L)',t.id('case-r'),t.id('hearing-past'),'{"outcome":"x"}'),'LEGAL_CASE_NOT_FOUND');
SELECT t.error('isolation: shop b can''t open a case on shop a''s contract',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-k')),'l01-key-b-open'),'CONTRACT_NOT_FOUND');
INSERT INTO t.docs SELECT 'lawyers-b',public.list_lawyers();
RESET ROLE;
SELECT t.expect('isolation: shop b''s list and lawyer pick list are empty',
  jsonb_array_length(t.doc('list-b')->'rows')=0 AND jsonb_array_length(t.doc('lawyers-b')->'items')=0);
SELECT t.who('a1010000-0000-0000-8000-000000000008','c');
SET ROLE authenticated;
SELECT t.error('module: a shop without the legal module can''t list','SELECT public.list_legal_cases()','MODULE_NOT_IN_PLAN');
SELECT t.error('module: nor open',format('SELECT public.open_legal_case(%L,%L)',jsonb_build_object('contract_id',t.id('c-r')),'l01-key-c-open'),'MODULE_NOT_IN_PLAN');
SELECT t.error('module: nor read a case',format('SELECT public.get_legal_case(%L)',t.id('case-d')),'MODULE_NOT_IN_PLAN');
SELECT t.error('module: nor list lawyers','SELECT public.list_lawyers()','MODULE_NOT_IN_PLAN');
RESET ROLE;

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT COALESCE(ok,false)) AS failed FROM t.results;
