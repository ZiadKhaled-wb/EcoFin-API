-- N05 early settlement, rescheduling, write-off (EC-84, D80).
-- Run by: node scripts/db-smoke.mjs supabase/tests/n05_contract_changes_test.sql (inside BEGIN ... ROLLBACK).
-- A reschedule spreads exactly what is left over a new version (rule 5) and keeps the old one; an
-- early settlement takes the payoff minus a manager's waiver (at most the not-yet-due profit, rule
-- 6) through N03's collection and closes the contract; the owner writes off what is left. Balances
-- after each, the version check, the reversal guard, the statement rows, idempotency, access.
-- t.late() (copied from n04_overdue_tracking_test.sql) moves a contract's due dates back.
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
INSERT INTO t.shops SELECT s,public.admin_provision_organization('N05 '||s,'n05-key-'||s,p,'Owner',s||'n05@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('v',64)),('b','retail',repeat('w',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0800000-0000-0000-8000-000000000001','an05@example.com'),('a0800000-0000-0000-8000-000000000002','bn05@example.com'),
  ('a0800000-0000-0000-8000-000000000003','n05cashier@example.com'),('a0800000-0000-0000-8000-000000000004','n05manager@example.com'),
  ('a0800000-0000-0000-8000-000000000005','n05manager2@example.com');
SELECT public.accept_invite(repeat('v',64),'a0800000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('w',64),'a0800000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0,overdue_warning_interval_days=10
  WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'));
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"N5-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',30)),'n05-key-found');
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0800000-0000-0000-8000-000000000003','N05 Cashier','CASHIER');
SELECT t.emp('manager','a0800000-0000-0000-8000-000000000004','N05 Manager','BRANCH_MANAGER');
SELECT t.emp('manager2','a0800000-0000-0000-8000-000000000005','N05 Manager Two','BRANCH_MANAGER');
-- manager2 was granted the write-off key: still not the owner.
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted)
  VALUES(t.org('a'),t.id('manager2'),'contract.write_off',true);
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,'active','291010101005'||right(p_phone,2)) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('r','Rami Reschedule','01022220001');
SELECT t.cust('s','Sara Settle','01022220002');
SELECT t.cust('s0','Samy NoWaiver','01022220003');
SELECT t.cust('wo','Walid WriteOff','01022220004');
SELECT t.cust('rv','Rana Reverse','01022220005');
SELECT t.cust('od','Omar Overdue','01022220006');
-- The policy: 20 % up to 24 months, monthly only, 3 grace days; the suggested waiver is half the
-- not-yet-due profit.
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'percent_of_future_profit',50,
         1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');

-- The manager sells, collects and changes contracts in one open shift.
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','n05-key-shift');
INSERT INTO t.docs SELECT 's-'||c,t.sell(c,'n05-key-sale-'||c) FROM unnest(ARRAY['r','s','s0','wo','rv','od']) c;
RESET ROLE;
INSERT INTO t.ids SELECT 'c-'||c,(t.doc('s-'||c)->'contract'->>'id')::uuid FROM unnest(ARRAY['r','s','s0','wo','rv','od']) c;
SELECT t.expect('setup: six contracts of 12 lines of 1000 (10000 financed + 2000 profit)',
  (SELECT count(*)=6 FROM public.contracts WHERE organization_id=t.org('a'))
  AND (SELECT bool_and(amount=1000) FROM public.schedule_lines WHERE organization_id=t.org('a'))
  AND (t.k('c-r')).total_payable=12000 AND (t.k('c-r')).markup_amount=2000);
SELECT t.expect('split: app.schedule_split gives N01''s lines (same arithmetic as the sale)',
  app.schedule_split(10000,2000,12,'monthly',(t.k('c-r')).first_due_date,1)
  =(SELECT jsonb_agg(jsonb_build_object('seq',seq,'due_date',due_date::text,'principal',principal::text,'profit',profit::text,
                     'amount',amount::text) ORDER BY seq) FROM public.schedule_lines WHERE contract_id=t.id('c-r')));

RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'pay-r',t.pay('c-r','1500.00','n05-key-pay-r');
INSERT INTO t.docs SELECT 'pay-s',t.pay('c-s','1000.00','n05-key-pay-s');
INSERT INTO t.docs SELECT 'pay-wo',t.pay('c-wo','1000.00','n05-key-pay-wo');
INSERT INTO t.docs SELECT 'pay-rv',t.pay('c-rv','1000.00','n05-key-pay-rv');
RESET ROLE;

-- ================================================================ reschedule (decision 6)
INSERT INTO t.docs SELECT 'r-before',jsonb_build_object('remaining',t.left('c-r'),'total',t.total('c-r'),'paid',(t.cb('c-r')).paid,
  'open',t.open_balance('r'),'stmt',t.stmt('r'),'principal',(t.cb('c-r')).principal_outstanding);
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r-preview',public.preview_reschedule(t.id('c-r'),jsonb_build_object('installments_count',7,'frequency','monthly','first_due_date',(t.today()+30)::text));
INSERT INTO t.docs SELECT 'r-bad',public.preview_reschedule(t.id('c-r'),jsonb_build_object('installments_count',7,'frequency','weekly','first_due_date',(t.today()+61)::text));
SELECT t.error('reschedule: an unknown body key is refused',
  format('SELECT public.preview_reschedule(%L,%L)',t.id('c-r'),'{"installments_count":3,"frequency":"monthly","first_due_date":"2030-01-01","fee":1}'),'VALIDATION_FAILED');
SELECT t.error('reschedule: a count of 0 is refused',
  format('SELECT public.preview_reschedule(%L,%L)',t.id('c-r'),'{"installments_count":0,"frequency":"monthly","first_due_date":"2030-01-01"}'),'VALIDATION_FAILED');
SELECT t.error('reschedule: no reason is refused',
  format('SELECT public.reschedule_contract(%L,%L,%L)',t.id('c-r'),jsonb_build_object('installments_count',3,'frequency','monthly',
    'first_due_date',(t.today()+30)::text,'expected_remaining','10500.00'),'n05-key-noreason'),'VALIDATION_FAILED');
SELECT t.error('reschedule: rules broken are INSTALLMENT_TERMS_INVALID',
  format('SELECT t.resched(%L,7,61,%L)','c-r','n05-key-r-far'),'INSTALLMENT_TERMS_INVALID');
SELECT t.error_detail('reschedule: a stale expected remaining is COLLECTION_DUE_CHANGED',
  format('SELECT t.resched(%L,7,30,%L,%L)','c-r','n05-key-r-stale','11500.00'),'COLLECTION_DUE_CHANGED','{"remaining":"10500.00"}');
INSERT INTO t.docs SELECT 'r1',t.resched('c-r',7,30,'n05-key-r1');
INSERT INTO t.docs SELECT 'r1-again',t.resched('c-r',7,30,'n05-key-r1');
SELECT t.error('reschedule: the key of another contract''s change is IDEMPOTENCY_CONFLICT',
  format('SELECT t.resched(%L,7,30,%L)','c-s','n05-key-r1'),'IDEMPOTENCY_CONFLICT');
SELECT t.error('reschedule: a sale''s key is IDEMPOTENCY_CONFLICT',
  format('SELECT t.resched(%L,7,30,%L)','c-s','n05-key-sale-s'),'IDEMPOTENCY_CONFLICT');
RESET ROLE;
SELECT t.commit_checks();
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('reschedule: a cashier has no schedule.change',format('SELECT t.resched(%L,7,30,%L)','c-s','n05-key-r-cashier'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.expect('preview: 7 lines adding up to what is left (10500), principal and profit exactly as left, no violation',
  jsonb_array_length(t.doc('r-preview')->'lines')=7 AND jsonb_array_length(t.doc('r-preview')->'violations')=0
  AND t.doc('r-preview')->>'remaining'='10500.00'
  AND (SELECT sum((l->>'amount')::numeric)=10500 AND sum((l->>'principal')::numeric)=(t.doc('r-preview')->>'principal_left')::numeric
         AND sum((l->>'profit')::numeric)=(t.doc('r-preview')->>'profit_left')::numeric
       FROM jsonb_array_elements(t.doc('r-preview')->'lines') l)
  AND (t.doc('r-preview')->'lines'->0->>'due_date')::date=t.today()+30,t.doc('r-preview')::text);
SELECT t.expect('preview: a weekly plan (not in the policy) and a date past 60 days are violations',
  (SELECT array_agg(v->>'rule' ORDER BY v->>'rule') FROM jsonb_array_elements(t.doc('r-bad')->'violations') v)
    =ARRAY['first_due_date_out_of_range','frequency_not_allowed'],t.doc('r-bad')::text);
SELECT t.expect('reschedule: rescheduled, version 2 current, the 12 old lines kept and superseded, 7 new lines',
  (t.k('c-r')).status='rescheduled' AND (t.k('c-r')).current_version=2 AND (t.k('c-r')).closed_at IS NULL
  AND t.lines('c-r',1)=12 AND (SELECT bool_and(superseded) FROM public.schedule_lines WHERE contract_id=t.id('c-r') AND version=1)
  AND t.lines('c-r',2)=7 AND t.doc('r1')->'contract'->>'current_version'='2'
  AND jsonb_array_length(t.doc('r1')->'contract'->'lines')=7);
SELECT t.expect('reschedule: the total never grows (rule 5): same remaining, contract total, paid, principal, open balance, statement',
  t.left('c-r')=(t.doc('r-before')->>'remaining')::numeric AND t.total('c-r')=(t.doc('r-before')->>'total')::numeric
  AND t.total('c-r')=12000 AND (t.cb('c-r')).paid=(t.doc('r-before')->>'paid')::numeric
  AND (t.cb('c-r')).principal_outstanding=(t.doc('r-before')->>'principal')::numeric
  AND t.open_balance('r')=(t.doc('r-before')->>'open')::numeric AND t.stmt('r')=(t.doc('r-before')->>'stmt')::numeric,
  t.doc('r-before')::text||' now '||t.left('c-r')||'/'||t.total('c-r')||'/'||t.open_balance('r')||'/'||t.stmt('r'));
SELECT t.expect('reschedule: the change row links both versions and carries what was left; the same key returns it again',
  t.changes('c-r')=1 AND t.doc('r1')->'change'->>'kind'='reschedule' AND t.doc('r1')->'change'->>'old_version'='1'
  AND t.doc('r1')->'change'->>'new_version'='2' AND t.doc('r1')->'change'->>'amount'='10500.00'
  AND t.doc('r1')->'change'->>'profit_waived'='0.00' AND t.doc('r1')->'change'->>'reason'='Customer lost his job'
  AND t.doc('r1-again')->'change'->>'id'=t.doc('r1')->'change'->>'id');
SELECT t.expect('reschedule: audit contract.rescheduled (warning) with old and new line counts',
  (SELECT count(*)=1 AND bool_and(severity='warning' AND "after"->>'old_lines'='12' AND "after"->>'new_lines'='7')
   FROM public.audit_log WHERE organization_id=t.org('a') AND action='contract.rescheduled' AND entity_id=t.id('c-r')));

-- Collections follow the new version; a second reschedule makes version 3.
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'pay-r2',t.pay('c-r','1600.00','n05-key-pay-r2');
INSERT INTO t.docs SELECT 'r2-paid',to_jsonb((SELECT paid FROM public.v_schedule_line_status WHERE contract_id=t.id('c-r') AND version=2 AND seq=1));
INSERT INTO t.docs SELECT 'r2',t.resched('c-r',4,20,'n05-key-r2');
INSERT INTO t.docs SELECT 'r-hist',public.list_contract_changes_for(t.id('c-r'));
RESET ROLE;
SELECT t.commit_checks();
SELECT t.expect('collect after a reschedule: the new version''s first line is paid first',
  (t.doc('r2-paid')#>>'{}')::numeric=(SELECT amount FROM public.schedule_lines WHERE contract_id=t.id('c-r') AND version=2 AND seq=1),
  t.doc('r2-paid')::text);
SELECT t.expect('history: 3 versions newest first, the two old ones superseded and linked to their change; 2 changes',
  jsonb_array_length(t.doc('r-hist')->'versions')=3 AND jsonb_array_length(t.doc('r-hist')->'changes')=2
  AND t.doc('r-hist')->'versions'->0->>'version'='3' AND t.doc('r-hist')->'versions'->0->>'superseded'='false'
  AND t.doc('r-hist')->'versions'->1->>'superseded'='true' AND t.doc('r-hist')->'versions'->2->>'superseded'='true'
  AND t.doc('r-hist')->'versions'->0->>'change_id'=t.doc('r2')->'change'->>'id'
  AND t.doc('r-hist')->'versions'->1->>'change_id'=t.doc('r1')->'change'->>'id'
  AND t.doc('r-hist')->'versions'->2->'change_id'='null'::jsonb
  AND jsonb_array_length(t.doc('r-hist')->'versions'->2->'lines')=12
  AND t.lines('c-r',1)=12 AND t.lines('c-r',2)=7 AND t.lines('c-r',3)=4
  AND t.total('c-r')=12000 AND t.left('c-r')=8900,t.left('c-r')::text);

-- ================================================================ the version check (decision 4)
SELECT t.error('version check: a version > 1 without its change row is SCHEDULE_NOT_BALANCED',
  format($q$UPDATE public.contracts SET current_version=4 WHERE id=%L; INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit) VALUES(%L,%L,4,1,%L,100,10); SET CONSTRAINTS ALL IMMEDIATE$q$,
    t.id('c-r'),t.org('a'),t.id('c-r'),t.today()+5),'SCHEDULE_NOT_BALANCED');
SELECT t.error('version check: a version adding to what was left is SCHEDULE_NOT_BALANCED',
  format($q$INSERT INTO public.contract_changes(organization_id,contract_id,kind,old_version,new_version,amount,principal_amount,profit_amount,reason,idempotency_key) VALUES(%L,%L,'reschedule',3,4,8900,%s,%s,'x','n05-key-direct'); UPDATE public.contracts SET current_version=4 WHERE id=%L; INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit) VALUES(%L,%L,4,1,%L,%s,%s); SET CONSTRAINTS ALL IMMEDIATE$q$,
    t.org('a'),t.id('c-r'),(t.cb('c-r')).principal_outstanding,8900-(t.cb('c-r')).principal_outstanding,t.id('c-r'),t.org('a'),t.id('c-r'),t.today()+5,
    (t.cb('c-r')).principal_outstanding,8900-(t.cb('c-r')).principal_outstanding+100),'SCHEDULE_NOT_BALANCED');
SELECT t.error('frozen: an old line''s amount can''t change',
  format('UPDATE public.schedule_lines SET principal=1 WHERE contract_id=%L AND version=1 AND seq=2',t.id('c-r')),'FROZEN_ROW');

-- ================================================================ early settlement (decision 5)
SELECT t.late('c-s',2,5);   -- line 2 is overdue (5 days, past the 3 grace days); lines 3-12 not yet due
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'q-s',public.get_settlement_quote(t.id('c-s'));
RESET ROLE;
INSERT INTO t.docs SELECT 's-future',to_jsonb((SELECT sum(profit) FROM public.schedule_lines WHERE contract_id=t.id('c-s') AND seq>2));
SELECT t.expect('quote: payoff = what is left; max waiver = the profit of the lines not yet due; suggestion = 50 % of it, cut to the piaster',
  t.doc('q-s')->>'remaining'='11000.00' AND (t.doc('q-s')->>'future_profit')::numeric=(t.doc('s-future')#>>'{}')::numeric
  AND (t.doc('q-s')->>'max_waiver')::numeric=(t.doc('s-future')#>>'{}')::numeric
  AND (t.doc('q-s')->>'suggested_waiver')::numeric=trunc((t.doc('s-future')#>>'{}')::numeric/2,2)
  AND t.doc('q-s')->'policy_rule'->>'early_settlement_rule'='percent_of_future_profit'
  AND (t.doc('q-s')->>'principal_left')::numeric+(t.doc('q-s')->>'profit_left')::numeric=11000,t.doc('q-s')::text);
INSERT INTO t.docs SELECT 's-before',jsonb_build_object('payments',(SELECT count(*) FROM public.payments WHERE organization_id=t.org('a')));
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('settle: a cashier has no contract.settle_early',format('SELECT t.settle(%L,%L,NULL,%L)','c-s','0.00','n05-key-s-cashier'),'PERMISSION_DENIED');
SELECT t.error('quote: a cashier has no contract.settle_early',format('SELECT public.get_settlement_quote(%L)',t.id('c-s')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('settle: a waiver above the not-yet-due profit is WAIVER_TOO_HIGH',
  format('SELECT t.settle(%L,%L,%L,%L)','c-s',((t.doc('q-s')->>'max_waiver')::numeric+0.01)::text,'Good customer','n05-key-s-high'),
  'WAIVER_TOO_HIGH',jsonb_build_object('max_waiver',t.doc('q-s')->>'max_waiver'));
SELECT t.error('settle: a waiver without a reason is refused',format('SELECT t.settle(%L,%L,NULL,%L)','c-s','10.00','n05-key-s-noreason'),'VALIDATION_FAILED');
SELECT t.error('settle: payments short of the payoff minus the waiver are refused',
  format('SELECT public.settle_contract_early(%L,%L,%L)',t.id('c-s'),jsonb_build_object('waiver','0.00','expected_remaining','11000.00',
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','100.00'))),'n05-key-s-short'),'PAYMENT_TOTAL_MISMATCH');
RESET ROLE;
SELECT t.expect('settle: the refused attempts wrote nothing',t.changes('c-s')=0 AND (t.k('c-s')).current_version=1);
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's1',t.settle('c-s',t.doc('q-s')->>'suggested_waiver','Good customer, paid early','n05-key-s1');
INSERT INTO t.docs SELECT 's1-again',public.settle_contract_early(t.id('c-s'),'{}','n05-key-s1');
INSERT INTO t.docs SELECT 's0',t.settle('c-s0','0.00',NULL,'n05-key-s0');
RESET ROLE;
SELECT t.commit_checks();
INSERT INTO t.docs SELECT 'w',to_jsonb((t.doc('q-s')->>'suggested_waiver')::numeric);
SELECT t.expect('settle: the contract is completed; one line due today carries the payoff minus the waiver; the old lines superseded',
  (t.k('c-s')).status='completed' AND (t.k('c-s')).closed_at IS NOT NULL AND (t.k('c-s')).current_version=2
  AND t.lines('c-s',2)=1 AND (SELECT due_date=t.today() AND amount=11000-(t.doc('w')#>>'{}')::numeric
                              FROM public.schedule_lines WHERE contract_id=t.id('c-s') AND version=2)
  AND (SELECT bool_and(superseded) FROM public.schedule_lines WHERE contract_id=t.id('c-s') AND version=1)
  AND t.left('c-s')=0);
SELECT t.expect('settle: balances: paid = earlier + payoff - waiver, contract total = total payable - waiver, nothing left',
  (t.cb('c-s')).paid=1000+11000-(t.doc('w')#>>'{}')::numeric AND (t.cb('c-s')).remaining=0
  AND t.total('c-s')=12000-(t.doc('w')#>>'{}')::numeric,(t.cb('c-s')).paid||' / '||t.total('c-s'));
SELECT t.expect('settle: the statement nets to zero and shows the waiver as its own credit row; the open balance is 0',
  t.stmt('s')=0 AND t.stmt_kind('s','profit_waiver')=(t.doc('w')#>>'{}')::numeric AND t.open_balance('s')=0,
  t.stmt('s')::text);
SELECT t.expect('settle: the change row (waiver, approver, receipt) and N03''s receipt; the same key returns both',
  t.doc('s1')->'change'->>'kind'='early_settlement' AND t.doc('s1')->'change'->>'amount'='11000.00'
  AND (t.doc('s1')->'change'->>'profit_waived')::numeric=(t.doc('w')#>>'{}')::numeric
  AND t.doc('s1')->'change'->>'approved_by'=t.id('manager')::text
  AND t.doc('s1')->'change'->>'payment_id'=t.doc('s1')->'collection'->>'id'
  AND (t.doc('s1')->'collection'->>'amount')::numeric=11000-(t.doc('w')#>>'{}')::numeric
  AND t.doc('s1')->'collection'->'contracts'->0->>'status'='completed'
  AND t.doc('s1-again')->'change'->>'id'=t.doc('s1')->'change'->>'id'
  AND t.doc('s1-again')->'collection'->>'id'=t.doc('s1')->'collection'->>'id',t.doc('s1')::text);
SELECT t.expect('settle: a repeat key collects nothing more (two settlements = two payments)',
  (SELECT count(*) FROM public.payments WHERE organization_id=t.org('a'))=(t.doc('s-before')->>'payments')::int+2);
SELECT t.expect('settle: audit contract.settled_early (warning with a waiver, info without) + contract.completed',
  (SELECT severity='warning' AND "after"->>'profit_waived'=(t.doc('w')#>>'{}')
   FROM public.audit_log WHERE organization_id=t.org('a') AND action='contract.settled_early' AND entity_id=t.id('c-s'))
  AND (SELECT severity='info' AND reason IS NULL FROM public.audit_log WHERE organization_id=t.org('a') AND action='contract.settled_early' AND entity_id=t.id('c-s0'))
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='contract.completed' AND entity_id=t.id('c-s')));
SELECT t.expect('settle without a waiver: paid in full, contract total unchanged, no waiver row in the statement',
  (t.k('c-s0')).status='completed' AND t.total('c-s0')=12000 AND (t.cb('c-s0')).paid=12000
  AND t.stmt_kind('s0','profit_waiver') IS NULL AND t.stmt('s0')=0);
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('settle: its collection can''t be reversed',
  format('SELECT public.reverse_collection(%L,%L,%L)',(t.doc('s1')->'collection'->>'id')::uuid,'{"reason":"Wrong customer"}','n05-key-rev-s1'),
  'COLLECTION_NOT_REVERSIBLE','{"reason":"settlement"}');
SELECT t.error('settle: a completed contract is CONTRACT_NOT_OPEN',format('SELECT public.get_settlement_quote(%L)',t.id('c-s')),'CONTRACT_NOT_OPEN');
SELECT t.error('reschedule: a completed contract is CONTRACT_NOT_OPEN',
  format('SELECT public.preview_reschedule(%L,%L)',t.id('c-s'),'{"installments_count":3,"frequency":"monthly","first_due_date":"2030-01-01"}'),'CONTRACT_NOT_OPEN');

-- ================================================================ the reversal guard (decision 8)
INSERT INTO t.docs SELECT 'rv1',t.resched('c-rv',6,30,'n05-key-rv1');
SELECT t.error_detail('reversal: a collection made before a reschedule can''t be reversed',
  format('SELECT public.reverse_collection(%L,%L,%L)',(t.doc('pay-rv')->>'id')::uuid,'{"reason":"Wrong customer"}','n05-key-rev-rv'),
  'COLLECTION_NOT_REVERSIBLE',jsonb_build_object('reason','contract_changed','contract_id',t.id('c-rv')));
INSERT INTO t.docs SELECT 'pay-rv2',t.pay('c-rv','100.00','n05-key-pay-rv2');
INSERT INTO t.docs SELECT 'rev-rv2',public.reverse_collection((t.doc('pay-rv2')->>'id')::uuid,'{"reason":"Typed the wrong amount"}','n05-key-rev-rv2');
RESET ROLE;
SELECT t.commit_checks();
SELECT t.expect('reversal: a collection made after the change can still be reversed',
  jsonb_typeof(t.doc('rev-rv2')->'reversal')='object' AND t.left('c-rv')=11000,t.left('c-rv')::text);

-- ================================================================ write-off (decision 7)
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('write-off: a branch manager can''t',format('SELECT t.write_off(%L,%L)','c-wo','n05-key-wo-bm'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('write-off: a manager granted contract.write_off still can''t (the owner only)',format('SELECT t.write_off(%L,%L)','c-wo','n05-key-wo-bm2'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('write-off: a too short reason is refused',
  format('SELECT public.write_off_contract(%L,%L,%L)',t.id('c-wo'),'{"reason":"x","expected_remaining":"11000.00"}','n05-key-wo-x'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'wo-before',jsonb_build_object('paid',(t.cb('c-wo')).paid);
INSERT INTO t.docs SELECT 'wo1',t.write_off('c-wo','n05-key-wo1');
INSERT INTO t.docs SELECT 'wo1-again',public.write_off_contract(t.id('c-wo'),'{}','n05-key-wo1');
SELECT t.error('write-off: twice is CONTRACT_NOT_OPEN',format('SELECT t.write_off(%L,%L)','c-wo','n05-key-wo2'),'CONTRACT_NOT_OPEN');
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('write-off: no collection on a written-off contract',format('SELECT t.pay(%L,%L,%L)','c-wo','100.00','n05-key-pay-wo2'),'CONTRACT_NOT_OPEN');
RESET ROLE;
SELECT t.commit_checks();
SELECT t.expect('write-off: written off and closed, no new version, the lines untouched (shown closed)',
  (t.k('c-wo')).status='written_off' AND (t.k('c-wo')).closed_at IS NOT NULL AND (t.k('c-wo')).current_version=1
  AND t.lines('c-wo',1)=12 AND t.lines('c-wo',2)=0
  AND (SELECT count(*)=11 FROM public.v_schedule_line_status WHERE contract_id=t.id('c-wo') AND status='closed')
  AND (t.cb('c-wo')).paid=(t.doc('wo-before')->>'paid')::numeric);
SELECT t.expect('write-off: the change row holds what was lost (principal + profit), approved by the owner; the same key returns it',
  t.doc('wo1')->'change'->>'kind'='write_off' AND t.doc('wo1')->'change'->>'amount'='11000.00'
  AND (t.doc('wo1')->'change'->>'principal_amount')::numeric+(t.doc('wo1')->'change'->>'profit_amount')::numeric=11000
  AND t.doc('wo1')->'change'->>'new_version' IS NULL AND t.doc('wo1')->'change'->>'approved_by' IS NOT NULL
  AND t.doc('wo1-again')->'change'->>'id'=t.doc('wo1')->'change'->>'id' AND t.changes('c-wo')=1,t.doc('wo1')::text);
SELECT t.expect('write-off: the open balance drops the contract; the statement nets to zero with a write-off credit row',
  t.open_balance('wo')=0 AND t.stmt('wo')=0 AND t.stmt_kind('wo','write_off')=11000);
SELECT t.expect('write-off: audit contract.written_off (critical) with the reason',
  (SELECT severity='critical' AND reason='Customer emigrated, nothing to collect' FROM public.audit_log
   WHERE organization_id=t.org('a') AND action='contract.written_off' AND entity_id=t.id('c-wo')));

-- ================================================================ N04 interplay
SELECT t.late('c-od',1,10);
INSERT INTO t.docs SELECT 'od-run1',t.run();
SELECT t.expect('N04: an overdue contract gets its warning',
  (SELECT count(*)=1 FROM public.overdue_actions WHERE contract_id=t.id('c-od') AND kind='warning' AND status='open'));
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'od1',t.resched('c-od',12,30,'n05-key-od1');
RESET ROLE;
SELECT t.commit_checks();
INSERT INTO t.docs SELECT 'od-run2',t.run();
SELECT t.expect('N04: after a reschedule nothing is overdue and the next run resolves the warning',
  (t.cb('c-od')).overdue_amount=0
  AND (SELECT count(*)=1 FROM public.overdue_actions WHERE contract_id=t.id('c-od') AND kind='warning' AND status='resolved'),
  t.doc('od-run2')::text);

-- ================================================================ the shop's list (decision 11) and isolation
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'list',public.list_contract_changes('{}');
INSERT INTO t.docs SELECT 'list-wo',public.list_contract_changes('{"kind":"write_off"}');
INSERT INTO t.docs SELECT 'list-p1',public.list_contract_changes('{"limit":2}');
INSERT INTO t.docs SELECT 'list-p2',public.list_contract_changes(jsonb_build_object('limit',100,'cursor',t.doc('list-p1')->>'next_cursor'));
SELECT t.error('list: an unknown filter is refused',$q$SELECT public.list_contract_changes('{"fee":1}')$q$,'VALIDATION_FAILED');
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('list: a cashier can''t',$q$SELECT public.list_contract_changes('{}')$q$,'PERMISSION_DENIED');
INSERT INTO t.docs SELECT 'cashier-hist',public.list_contract_changes_for(t.id('c-r'));
RESET ROLE;
SELECT t.as_user('a0800000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('isolation: shop b can''t quote shop a''s contract',format('SELECT public.get_settlement_quote(%L)',t.id('c-r')),'CONTRACT_NOT_FOUND');
SELECT t.error('isolation: shop b can''t read its changes',format('SELECT public.list_contract_changes_for(%L)',t.id('c-r')),'CONTRACT_NOT_FOUND');
SELECT t.error('isolation: shop b can''t write it off',
  format('SELECT public.write_off_contract(%L,%L,%L)',t.id('c-r'),'{"reason":"Not mine","expected_remaining":"8900.00"}','n05-key-b-wo'),'CONTRACT_NOT_FOUND');
INSERT INTO t.docs SELECT 'list-b',public.list_contract_changes('{}');
RESET ROLE;
SELECT t.expect('list: every change of the shop newest first, with totals by kind',
  jsonb_array_length(t.doc('list')->'items')=7
  AND (SELECT jsonb_object_agg(x->>'kind',x->>'count') FROM jsonb_array_elements(t.doc('list')->'totals') x)
      ='{"reschedule":"4","early_settlement":"2","write_off":"1"}'::jsonb
  AND t.doc('list')->'items'->0->>'kind'='reschedule' AND t.doc('list')->'items'->0->'customer'->>'name'='Omar Overdue',
  (t.doc('list')->'totals')::text);
SELECT t.expect('list: kind filter, paging with the cursor covers every row once',
  jsonb_array_length(t.doc('list-wo')->'items')=1 AND t.doc('list-wo')->'items'->0->'contract'->>'number'=(t.k('c-wo')).number
  AND jsonb_array_length(t.doc('list-p1')->'items')=2 AND t.doc('list-p1')->>'next_cursor' IS NOT NULL
  AND jsonb_array_length(t.doc('list-p2')->'items')=5 AND t.doc('list-p2')->'next_cursor'='null'::jsonb
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('list-p1')->'items') a JOIN jsonb_array_elements(t.doc('list-p2')->'items') b ON a->>'id'=b->>'id'));
SELECT t.expect('history: a collection holder (cashier) can read a contract''s versions',
  jsonb_array_length(t.doc('cashier-hist')->'versions')=3);
SELECT t.expect('isolation: shop b sees none of shop a''s changes',jsonb_array_length(t.doc('list-b')->'items')=0);

-- ================================================================ grants
SELECT t.expect('grants: the seven public functions and the reversal are executable; the helpers are not; no direct writes',
  has_function_privilege('authenticated','public.get_settlement_quote(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.settle_contract_early(uuid,jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.preview_reschedule(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.reschedule_contract(uuid,jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.write_off_contract(uuid,jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_contract_changes_for(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_contract_changes(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.reverse_collection(uuid,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.settle_contract_early(uuid,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.write_schedule_version(uuid,uuid,jsonb,uuid,public.contract_status)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.schedule_split(numeric,numeric,integer,public.installment_frequency,date,numeric)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.customer_statement_rows(uuid,uuid)','EXECUTE')
  AND NOT has_table_privilege('authenticated','public.contract_changes','INSERT')
  AND NOT has_table_privilege('authenticated','public.schedule_lines','UPDATE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
