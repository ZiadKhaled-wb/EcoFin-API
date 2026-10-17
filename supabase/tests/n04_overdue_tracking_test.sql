-- N04 overdue tracking, no late fees (EC-83, D79).
-- Run by: node scripts/db-smoke.mjs supabase/tests/n04_overdue_tracking_test.sql (inside BEGIN ... ROLLBACK).
-- The daily check: overdue only after the policy's grace days, a warning on the first overdue day
-- and every N days after, a ban past the shop's ban days (lifted by hand), a legal referral past
-- the legal days, nothing ever added to what a customer owes, a second run changing nothing. The
-- lists and the two writes (handle a warning, dismiss a referral), the late-fee lock, access.
-- The clock can't move in a test: t.late() moves a contract's due dates (and its warning dates)
-- back by the same number of days, which is the same as those days passing for that contract.
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

-- ---------------------------------------------------------------- setup: shops a and b (both with installments)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('N04 '||s,'n04-key-'||s,p,'Owner',s||'n04@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('s',64)),('b','retail',repeat('u',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0790000-0000-0000-8000-000000000001','an04@example.com'),('a0790000-0000-0000-8000-000000000002','bn04@example.com'),
  ('a0790000-0000-0000-8000-000000000003','n04cashier@example.com'),('a0790000-0000-0000-8000-000000000004','n04manager@example.com'),
  ('a0790000-0000-0000-8000-000000000005','n04collector@example.com');
SELECT public.accept_invite(repeat('s',64),'a0790000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('u',64),'a0790000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=30,overdue_warning_interval_days=10,
    legal_referral_days='{"daily":35,"weekly":63,"monthly":63}'
  WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'));
SELECT t.as_user('a0790000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"N4-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',30)),'n04-key-found');
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0790000-0000-0000-8000-000000000003','N04 Cashier','CASHIER');
SELECT t.emp('manager','a0790000-0000-0000-8000-000000000004','N04 Manager','BRANCH_MANAGER');
SELECT t.emp('collector','a0790000-0000-0000-8000-000000000005','N04 Collector','COLLECTOR');
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,'active','291010101004'||right(p_phone,2)) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('g','Gamal Grace','01011110001');
SELECT t.cust('w','Wael Warning','01011110002');
SELECT t.cust('bn','Bassem Ban','01011110003');
SELECT t.cust('x','Khaled Blocked','01011110004');
SELECT t.cust('lg','Laila Legal','01011110005');
SELECT t.cust('z','Zeina Zero','01011110006');
SELECT t.cust('ok','Omar OnTime','01011110007');
-- The policy: 20 % up to 24 months, 3 grace days, no guarantor or survey needed below 1 000 000.
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');

SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','n04-key-shift');
INSERT INTO t.docs SELECT 's-'||c,t.sell(c,'n04-key-sale-'||c) FROM unnest(ARRAY['g','w','bn','x','lg','z','ok']) c;
INSERT INTO t.docs SELECT 's-bn2',t.sell('bn','n04-key-sale-bn2');
RESET ROLE;
INSERT INTO t.ids SELECT 'c-'||c,(t.doc('s-'||c)->'contract'->>'id')::uuid FROM unnest(ARRAY['g','w','bn','x','lg','z','ok','bn2']) c;
SELECT t.expect('setup: eight contracts of 12 lines, every line in the future, the policy has 3 grace days',
  (SELECT count(*)=8 FROM public.contracts WHERE organization_id=t.org('a'))
  AND (SELECT min(due_date)>t.today() FROM public.schedule_lines WHERE organization_id=t.org('a'))
  AND (SELECT ip.grace_days=3 FROM public.contracts c JOIN public.installment_policies ip ON ip.id=c.policy_id WHERE c.id=t.id('c-g')));

-- ================================================================ grace (owner decision 1)
SELECT t.late('c-g',1,3);
SELECT t.expect('grace: 3 days after the due date the line is due, not overdue (inside grace)',
  (t.line('c-g',1)).status='due' AND (SELECT overdue_amount=0 FROM public.v_contract_balances WHERE contract_id=t.id('c-g')));
-- Owed, before any run.
INSERT INTO t.docs SELECT 'owed0',to_jsonb(t.owed());
INSERT INTO t.docs SELECT 'run1',t.run();
SELECT t.expect('grace: no warning inside grace',t.acts('c-g','warning')=0);
SELECT t.late('c-g',1,4);
SELECT t.expect('grace: on day 4 the line is overdue and its days late count from the due date',
  (t.line('c-g',1)).status='overdue' AND (t.line('c-g',1)).days_late=4
  AND (SELECT overdue_amount=1000 AND max_days_late=4 FROM public.v_contract_balances WHERE contract_id=t.id('c-g')));

-- ================================================================ the other contracts fall behind
SELECT t.late('c-w',1,4);       -- first overdue day
SELECT t.late('c-bn',1,31);     -- past the 30 ban days
SELECT t.late('c-x',1,31);      -- past the ban days, the customer already blocked by hand
SELECT t.late('c-lg',1,63);     -- legal referral day for monthly
SELECT t.as_user('a0790000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.set_customer_status(t.id('x'),'blocked','Bounced cheque');
RESET ROLE;

INSERT INTO t.docs SELECT 'owed1',to_jsonb(t.owed());
INSERT INTO t.docs SELECT 'audit1',to_jsonb((SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a')));
INSERT INTO t.docs SELECT 'run2',t.run();
INSERT INTO t.docs SELECT 'fp2',to_jsonb(t.footprint());
INSERT INTO t.docs SELECT 'run3',t.run();
SELECT t.expect('run: warnings for the five overdue contracts, bans for bn and x, bn blocked, one legal referral',
  (t.doc('run2')->>'warnings_created')::int=5 AND (t.doc('run2')->>'bans')::int=3
  AND (t.doc('run2')->>'customers_blocked')::int=2 AND (t.doc('run2')->>'legal_referrals')::int=1,
  t.doc('run2')::text);
SELECT t.expect('done when: running the check twice in a day changes nothing',
  t.zero(t.doc('run3')) AND t.footprint()=(t.doc('fp2')#>>'{}'),t.doc('run3')::text);
SELECT t.expect('done when: a late customer''s total owed never changes (balances, payments, charges, lines)',
  t.owed()=(t.doc('owed1')#>>'{}') AND (SELECT count(*)=0 FROM public.charges WHERE organization_id=t.org('a')));
SELECT t.expect('done when: shop b''s job touches nothing in shop a',
  (SELECT t.footprint()=(t.doc('fp2')#>>'{}') AND t.zero(t.run('b'))));

-- ================================================================ warnings (owner decision 3)
SELECT t.expect('warning: one open warning on the first overdue day, with the anchor line and amounts',
  (SELECT count(*)=1 AND bool_and(status='open' AND business_date=t.today() AND days_late=4 AND overdue_amount=1000
          AND schedule_line_id=(t.line('c-w',1)).schedule_line_id)
   FROM public.overdue_actions WHERE contract_id=t.id('c-w') AND kind='warning'));
SELECT t.late('c-w',1,9);
SELECT t.expect('warning: five days later, no new warning',t.zero(t.run()) AND t.acts('c-w','warning')=1);
SELECT t.late('c-w',1,14);
INSERT INTO t.docs SELECT 'run-w',t.run();
SELECT t.expect('warning: ten days after the first, a second one; the first is superseded',
  t.acts('c-w','warning','open')=1 AND t.acts('c-w','warning','superseded')=1
  AND (SELECT business_date=t.today() FROM public.overdue_actions WHERE contract_id=t.id('c-w') AND kind='warning' AND status='open'));
-- The cashier collects the overdue installment: the contract has caught up.
SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.pay('c-w','w','1000.00','n04-key-pay-w1');
RESET ROLE;
INSERT INTO t.docs SELECT 'run-w2',t.run();
SELECT t.expect('warning: caught up, the open warning is resolved',
  (t.doc('run-w2')->>'warnings_resolved')::int=1 AND t.acts('c-w','warning','open')=0 AND t.acts('c-w','warning','resolved')=1);
SELECT t.late('c-w',2,4);
SELECT t.expect('warning: late again (line 2), a new warning that day although the last one is recent',
  (t.run()->>'warnings_created')::int=1 AND t.acts('c-w','warning','open')=1);

-- ================================================================ ban (owner decision 2)
SELECT t.expect('ban: bn blocked by the check with a reason, no employee on the audit row',
  t.cstatus('bn')='blocked'
  AND (SELECT count(*)=1 AND bool_and(employee_id IS NULL AND reason LIKE 'Late more than 30 days on contract %' AND severity='warning')
       FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.status_set' AND entity_id=t.id('bn')));
SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('ban: a banned customer can''t buy on installments',t.sell_q('bn'),'CUSTOMER_BLOCKED');
RESET ROLE;
SELECT t.expect('ban: x was already blocked by hand: the ban is recorded, no second status change',
  t.cstatus('x')='blocked' AND t.acts('c-x','ban')=1
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.status_set' AND entity_id=t.id('x')));
SELECT t.expect('ban: the customer with two contracts got one ban record per late contract line, one status change',
  t.acts('c-bn','ban')=1 AND t.acts('c-bn2','ban')=0);
-- The owner lifts the ban by hand (R01): the same late line never bans again.
SELECT t.as_user('a0790000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.set_customer_status(t.id('bn'),'active');
RESET ROLE;
SELECT t.late('c-bn',1,40);
SELECT t.expect('ban: lifted by the owner, the same line doesn''t ban again',
  (t.run()->>'customers_blocked')::int=0 AND t.cstatus('bn')='active' AND t.acts('c-bn','ban')=1);
-- bn pays the late installment; later the next one crosses the ban days: banned again.
SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.pay('c-bn','bn','1000.00','n04-key-pay-bn1');
RESET ROLE;
SELECT t.late('c-bn',2,31);
SELECT t.expect('ban: a later line crossing the ban days bans again',
  (t.run()->>'customers_blocked')::int=1 AND t.cstatus('bn')='blocked' AND t.acts('c-bn','ban')=2);
-- Ban days 0 turns the ban off.
UPDATE public.org_settings SET customer_ban_days=0 WHERE organization_id=t.org('a');
SELECT t.late('c-z',1,90);
SELECT t.expect('ban: ban days 0 never bans',
  (t.run()->>'bans')::int=0 AND t.cstatus('z')='active' AND t.acts('c-z','ban')=0);
UPDATE public.org_settings SET customer_ban_days=30 WHERE organization_id=t.org('a');

-- ================================================================ legal referral (owner decision 4)
SELECT t.expect('legal: day 63 on a monthly contract -> one open referral and its audit row',
  t.acts('c-lg','legal_referral','open')=1
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='contract.legal_referred' AND entity_id=t.id('c-lg'))
  AND t.acts('c-bn','legal_referral')=0);
SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.pay('c-lg','lg','400.00','n04-key-pay-lg-part');
RESET ROLE;
SELECT t.run();
SELECT t.expect('legal: a part payment keeps the referral open',t.acts('c-lg','legal_referral','open')=1 AND t.acts('c-lg','legal_referral')=1);
INSERT INTO t.ids SELECT 'ref-lg',id FROM public.overdue_actions WHERE contract_id=t.id('c-lg') AND kind='legal_referral';
SELECT t.as_user('a0790000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('legal: a branch manager can''t dismiss',format('SELECT public.dismiss_legal_referral(%L,%L)',t.id('ref-lg'),'Paid at the office'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0790000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('legal: a two-letter reason',format('SELECT public.dismiss_legal_referral(%L,%L)',t.id('ref-lg'),'no'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'dismissed',public.dismiss_legal_referral(t.id('ref-lg'),'Agreed a payment plan with the owner');
SELECT t.error_detail('legal: dismissing twice',format('SELECT public.dismiss_legal_referral(%L,%L)',t.id('ref-lg'),'Again please'),
  'OVERDUE_ACTION_NOT_OPEN','{"status":"dismissed"}');
RESET ROLE;
SELECT t.expect('legal: dismissed with the reason, the owner and an audit row',
  t.doc('dismissed')->>'status'='dismissed' AND t.doc('dismissed')->>'note'='Agreed a payment plan with the owner'
  AND t.doc('dismissed')->>'handled_by_name' IS NOT NULL
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='contract.legal_referral_dismissed' AND entity_id=t.id('c-lg')));
SELECT t.expect('legal: after a dismissal the same line is not referred again',
  (t.run()->>'legal_referrals')::int=0 AND t.acts('c-lg','legal_referral')=1);
SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.pay('c-lg','lg','600.00','n04-key-pay-lg-rest');
RESET ROLE;
SELECT t.late('c-lg',2,63);
SELECT t.expect('legal: a later line crossing the legal days -> a new referral',
  (t.run()->>'legal_referrals')::int=1 AND t.acts('c-lg','legal_referral','open')=1 AND t.acts('c-lg','legal_referral')=2);

-- ================================================================ lists and handling a warning
SELECT t.as_user('a0790000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'list',public.list_overdue_contracts('{}');
INSERT INTO t.docs SELECT 'list1',public.list_overdue_contracts('{"limit":1}');
INSERT INTO t.docs SELECT 'list2',public.list_overdue_contracts(jsonb_build_object('limit',1,'cursor',t.doc('list1')->>'next_cursor'));
INSERT INTO t.docs SELECT 'list-min',public.list_overdue_contracts('{"min_days":60}');
INSERT INTO t.docs SELECT 'list-q',public.list_overdue_contracts('{"q":"Gamal"}');
INSERT INTO t.docs SELECT 'warns',public.list_overdue_warnings('{}');
INSERT INTO t.docs SELECT 'refs',public.list_legal_referrals('{"status":"all"}');
RESET ROLE;
SELECT t.expect('list: every overdue contract, worst first, with the customer, flags and fee-free totals',
  (SELECT jsonb_array_length(x->'items')=(SELECT count(*) FROM public.v_contract_balances WHERE organization_id=t.org('a') AND overdue_amount>0)
     AND (x->'items'->0->>'max_days_late')::int=(SELECT max(max_days_late) FROM public.v_contract_balances WHERE organization_id=t.org('a'))
     AND (x->'totals'->>'contracts')::int=jsonb_array_length(x->'items')
     AND (x->'totals'->>'overdue_amount')::numeric=(SELECT sum(overdue_amount) FROM public.v_contract_balances WHERE organization_id=t.org('a'))
     AND (x->'totals'->>'late_1_30')::numeric+(x->'totals'->>'late_31_60')::numeric+(x->'totals'->>'late_61_90')::numeric
         +(x->'totals'->>'late_90_plus')::numeric=(x->'totals'->>'overdue_amount')::numeric
     AND NOT (x::text LIKE '%fee%')
   FROM (SELECT t.doc('list') x) y));
SELECT t.expect('list: the legal flag and the open warning are on the row; the customer status shows the ban',
  (SELECT bool_or(i->'legal_referral'->>'status'='open' AND i->'contract'->>'id'=t.id('c-lg')::text)
      AND bool_or(i->'customer'->>'status'='blocked' AND i->'contract'->>'id'=t.id('c-bn')::text)
      AND bool_or(i->'open_warning' IS NOT NULL AND jsonb_typeof(i->'open_warning')='object')
   FROM jsonb_array_elements(t.doc('list')->'items') i));
SELECT t.expect('list: the cursor pages one row at a time without repeats; min_days and search filter',
  t.doc('list1')->>'next_cursor' IS NOT NULL
  AND t.doc('list2')->'items'->0->'contract'->>'id'=t.doc('list')->'items'->1->'contract'->>'id'
  AND (SELECT bool_and((i->>'max_days_late')::int>=60) FROM jsonb_array_elements(t.doc('list-min')->'items') i)
  AND jsonb_array_length(t.doc('list-q')->'items')=1 AND t.doc('list-q')->'items'->0->'customer'->>'name'='Gamal Grace');
SELECT t.expect('warnings list: open warnings oldest first with the contract, the customer and the current state',
  (SELECT bool_and(i->>'status'='open' AND i->>'kind'='warning' AND i->'contract'->>'number' IS NOT NULL
                   AND i->'current'->>'overdue_amount' IS NOT NULL)
   FROM jsonb_array_elements(t.doc('warns')->'items') i)
  AND jsonb_array_length(t.doc('warns')->'items')=(SELECT count(*) FROM public.overdue_actions WHERE organization_id=t.org('a') AND kind='warning' AND status='open'));
SELECT t.expect('referrals list: open and dismissed ones with status all',
  jsonb_array_length(t.doc('refs')->'items')=(SELECT count(*) FROM public.overdue_actions WHERE organization_id=t.org('a') AND kind='legal_referral')
  AND (SELECT count(*)=1 FROM jsonb_array_elements(t.doc('refs')->'items') i WHERE i->>'status'='dismissed'));

INSERT INTO t.ids SELECT 'warn-g',id FROM public.overdue_actions WHERE contract_id=t.id('c-g') AND kind='warning' AND status='open';
SELECT t.as_user('a0790000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('handle: other without a note',format('SELECT public.handle_overdue_warning(%L,%L)',t.id('warn-g'),'other'),'VALIDATION_FAILED');
SELECT t.error('handle: an unknown outcome',format('SELECT public.handle_overdue_warning(%L,%L)',t.id('warn-g'),'shouted'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'handled',public.handle_overdue_warning(t.id('warn-g'),'promised','Will pay on Thursday');
SELECT t.error_detail('handle: twice',format('SELECT public.handle_overdue_warning(%L,%L)',t.id('warn-g'),'contacted'),
  'OVERDUE_ACTION_NOT_OPEN','{"status":"handled"}');
SELECT t.error('handle: a legal referral is not a warning',format('SELECT public.handle_overdue_warning(%L,%L)',t.id('ref-lg'),'contacted'),'OVERDUE_ACTION_NOT_FOUND');
RESET ROLE;
SELECT t.expect('handle: the collector marks it handled with the outcome, note and audit row',
  t.doc('handled')->>'status'='handled' AND t.doc('handled')->>'outcome'='promised'
  AND t.doc('handled')->>'handled_by_name'='N04 Collector'
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='overdue.warning_handled' AND entity_id=t.id('c-g')));
SELECT t.late('c-g',1,14);
SELECT t.expect('handle: a handled warning still counts for the cadence (next one ten days after it)',
  (t.run()->>'warnings_created')::int>=1 AND t.acts('c-g','warning','open')=1 AND t.acts('c-g','warning','handled')=1);

-- ================================================================ access and isolation
SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('access: a cashier reads no overdue rows directly (RLS needs overdue.view)',(SELECT count(*)=0 FROM public.overdue_actions));
SELECT t.error('access: a cashier has no overdue.view','SELECT public.list_overdue_contracts(''{}'')','PERMISSION_DENIED');
SELECT t.error('access: a cashier can''t list warnings','SELECT public.list_overdue_warnings(''{}'')','PERMISSION_DENIED');
SELECT t.error('access: a cashier can''t handle a warning',format('SELECT public.handle_overdue_warning(%L,%L)',t.id('warn-g'),'contacted'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0790000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('access: only the owner runs the check by hand','SELECT public.run_overdue_check()','PERMISSION_DENIED');
SELECT t.error('lists: an unknown filter','SELECT public.list_overdue_contracts(''{"collector_id":"x"}'')','VALIDATION_FAILED');
SELECT t.error('lists: a bad status','SELECT public.list_overdue_warnings(''{"status":"dismissed"}'')','VALIDATION_FAILED');
RESET ROLE;
SELECT t.as_user('a0790000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'manual',public.run_overdue_check();
RESET ROLE;
SELECT t.expect('manual run: the owner runs the same check; right after the job it finds nothing new',t.zero(t.doc('manual')),t.doc('manual')::text);
SELECT t.as_user('a0790000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('isolation: shop b can''t handle shop a''s warning',format('SELECT public.handle_overdue_warning(%L,%L)',t.id('warn-g'),'contacted'),'OVERDUE_ACTION_NOT_FOUND');
SELECT t.error('isolation: shop b can''t dismiss shop a''s referral',format('SELECT public.dismiss_legal_referral(%L,%L)',t.id('ref-lg'),'Not ours at all'),'OVERDUE_ACTION_NOT_FOUND');
INSERT INTO t.docs SELECT 'list-b',public.list_overdue_contracts('{}');
INSERT INTO t.docs SELECT 'warns-b',public.list_overdue_warnings('{"status":"all"}');
SELECT t.expect('isolation: shop b reads none of shop a''s rows (RLS too)',
  (SELECT count(*)=0 FROM public.overdue_actions));
RESET ROLE;
SELECT t.expect('isolation: shop b''s lists are empty',
  jsonb_array_length(t.doc('list-b')->'items')=0 AND jsonb_array_length(t.doc('warns-b')->'items')=0);

-- ================================================================ no late fees (owner decision 5)
SELECT t.as_user('a0790000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('fee lock: a fixed late fee is refused',$q$SELECT public.publish_installment_policy('{"late_fee_type":"fixed","late_fee_value":50}')$q$,'LATE_FEES_NOT_ALLOWED');
SELECT t.error('fee lock: a fee value with type none is refused',$q$SELECT public.publish_installment_policy('{"late_fee_type":"none","late_fee_value":"5.00"}')$q$,'LATE_FEES_NOT_ALLOWED');
SELECT t.error('fee lock: a recurring fee is refused',$q$SELECT public.publish_installment_policy('{"late_fee_recurring":true}')$q$,'LATE_FEES_NOT_ALLOWED');
SELECT t.error('fee lock: a fee cap is refused',$q$SELECT public.publish_installment_policy('{"late_fee_cap":"100.00"}')$q$,'LATE_FEES_NOT_ALLOWED');
INSERT INTO t.ids VALUES('pv-none',public.publish_installment_policy('{"late_fee_type":"none","late_fee_value":0,"late_fee_recurring":false,"late_fee_cap":null,"grace_days":5}'));
INSERT INTO t.ids VALUES('pv-omit',public.publish_installment_policy('{"grace_days":2}'));
RESET ROLE;
SELECT t.as_user('a0790000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('fee lock: a cashier still gets PERMISSION_DENIED first',$q$SELECT public.publish_installment_policy('{"late_fee_type":"fixed"}')$q$,'PERMISSION_DENIED');
RESET ROLE;
SELECT t.expect('fee lock: none / 0 or the fields left out publish a version with no fee',
  (SELECT count(*)=2 AND bool_and(late_fee_type='none' AND late_fee_value=0 AND NOT late_fee_recurring AND late_fee_cap IS NULL)
   FROM public.installment_policies WHERE id IN (t.id('pv-none'),t.id('pv-omit'))));
SELECT t.error('fee lock: a charge row is refused',
  format('INSERT INTO public.charges(organization_id,contract_id,schedule_line_id,kind,assessed_on,amount) VALUES(%L,%L,%L,%L,%L,10)',
    t.org('a'),t.id('c-g'),(t.line('c-g',1)).schedule_line_id,'late_fee',t.today()),'LATE_FEES_NOT_ALLOWED');
SELECT t.error('fee lock: a direct policy row with a fee breaks the CHECK',
  format('INSERT INTO public.installment_policies(organization_id,version,max_months,markup_tiers,late_fee_type,late_fee_value) VALUES(%L,99,12,%L,%L,5)',
    t.org('a'),'[{"pct":0,"up_to_months":12}]','fixed'),'new row for relation "installment_policies" violates check constraint "installment_policies_no_late_fee"');

-- ================================================================ grants and the view
SELECT t.expect('view: same columns as before; an on-time contract has nothing overdue',
  (SELECT array_agg(attname ORDER BY attnum) FROM pg_attribute WHERE attrelid='public.v_schedule_line_status'::regclass AND attnum>0)
    =ARRAY['organization_id','schedule_line_id','contract_id','version','seq','due_date','principal','profit','amount','superseded',
           'paid','paid_principal','paid_profit','remaining','principal_remaining','fees_due','days_late','status']::name[]
  AND (SELECT overdue_amount=0 FROM public.v_contract_balances WHERE contract_id=t.id('c-ok'))
  AND t.acts('c-ok','warning')=0);
SELECT t.expect('grants: the job function is service role only; helpers not executable; the six public functions are',
  NOT has_function_privilege('authenticated','public.jobs_overdue_run(uuid)','EXECUTE')
  AND has_function_privilege('service_role','public.jobs_overdue_run(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.overdue_run(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.publish_installment_policy_core(jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.list_overdue_actions(public.overdue_action_kind,jsonb,text[])','EXECUTE')
  AND NOT has_function_privilege('anon','public.list_overdue_contracts(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_overdue_contracts(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_overdue_warnings(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_legal_referrals(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.handle_overdue_warning(uuid,text,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.dismiss_legal_referral(uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.run_overdue_check()','EXECUTE')
  AND has_function_privilege('authenticated','public.publish_installment_policy(jsonb)','EXECUTE')
  AND NOT has_table_privilege('authenticated','public.overdue_actions','INSERT'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
