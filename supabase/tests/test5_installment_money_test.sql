-- TEST-5 installment money tests (EC-136). Plan: docs/testing/plans/TEST-5.md.
-- Run by: node scripts/db-smoke.mjs supabase/tests/test5_installment_money_test.sql (inside BEGIN ... ROLLBACK).
-- Through the real write functions, one shop: (1) every contract's schedule adds up exactly, over
-- many prices, down payments, counts, markup tiers and two rounding steps; (2) payments go to the
-- oldest installment first, profit before principal, at the counter, in the field and after a
-- reschedule (there are no late fees to come first: rule 4); (3) a late installment never costs
-- more: no charge, grace respected, a second run of the check changes nothing; (4) the credit limit
-- is enforced by the database whoever calls it, and a refused sale writes nothing; (5) a new policy
-- version applies only to new contracts; (6) a collector's wallet equals its cash ledger after a
-- mixed day; every cached balance of the shop matches its ledger.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from n06_collector_wallets_test.sql).
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
CREATE FUNCTION t.line(c text,s integer) RETURNS public.v_schedule_line_status LANGUAGE sql SECURITY DEFINER AS $$
  SELECT ls.* FROM public.v_schedule_line_status ls WHERE ls.contract_id=t.id(c) AND ls.seq=s AND NOT ls.superseded $$;
CREATE FUNCTION t.left(c text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.contract_remaining(t.org('a'),t.id(c)) $$;
-- Days pass for one contract: its line `seq` becomes due `k` days ago (shop date).
CREATE FUNCTION t.late(c text,s integer,k integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE d integer;
BEGIN
  SELECT due_date-(t.today()-k) INTO d FROM public.schedule_lines WHERE contract_id=t.id(c) AND seq=s AND NOT superseded;
  SET LOCAL session_replication_role = replica;
  UPDATE public.schedule_lines SET due_date=due_date-d WHERE contract_id=t.id(c);
  UPDATE public.overdue_actions SET business_date=business_date-d WHERE contract_id=t.id(c);
  SET LOCAL session_replication_role = origin;
END $$;
CREATE FUNCTION t.run() RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN PERFORM t.as_user(NULL); RETURN public.jobs_overdue_run(t.org('a')); END $$;
-- An installment sale of `qty` of product `p` with down payment `down` over `n` months.
CREATE FUNCTION t.sell(p text,qty integer,p_customer text,down text,n integer,p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id(p),'quantity',qty)),
    'expected_total',((SELECT cash_price FROM public.products WHERE id=t.id(p))*qty)::numeric(18,2)::text,
    'customer_id',t.id(p_customer),
    'terms',jsonb_build_object('down_payment',down,'installments_count',n,'frequency','monthly','policy_version',t.pv())),p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
CREATE FUNCTION t.pay(c text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_collection(jsonb_build_object('customer_id',(SELECT customer_id FROM public.contracts WHERE id=t.id(c)),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id(c),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
CREATE FUNCTION t.fpay(c text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_field_collection(jsonb_build_object('customer_id',(SELECT customer_id FROM public.contracts WHERE id=t.id(c)),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id(c),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
CREATE FUNCTION t.resched(c text,n integer,first_in integer,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.reschedule_contract(t.id(c),jsonb_build_object('installments_count',n,'frequency','monthly',
    'first_due_date',(t.today()+first_in)::text,'reason','Customer lost his job',
    'expected_remaining',t.left(c)::numeric(18,2)::text),p_key) $$;
CREATE FUNCTION t.wallet(tag text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.cash_accounts WHERE kind='collector_wallet' AND employee_id=t.id(tag) $$;
CREATE FUNCTION t.bal(a uuid) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=a),0) $$;
CREATE FUNCTION t.ledger(a uuid) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT sum(amount) FROM public.cash_movements WHERE cash_account_id=a),0) $$;
CREATE FUNCTION t.wsettle(w text,to_acc text,handed text,shortage text,reason text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.settle_collector_wallet(t.wallet(w),jsonb_strip_nulls(jsonb_build_object('to_account_id',t.id(to_acc),'handed',handed,
    'shortage',shortage,'reason',reason,'expected_balance',t.bal(t.wallet(w))::numeric(18,2)::text)),p_key) $$;
-- What the wallet should hold and whether it matches: cached = ledger = expected.
CREATE FUNCTION t.wallet_ok(w text,expected numeric) RETURNS boolean LANGUAGE sql SECURITY DEFINER AS $$
  SELECT t.bal(t.wallet(w))=expected AND t.ledger(t.wallet(w))=expected $$;
CREATE FUNCTION t.u(n text) RETURNS text LANGUAGE sql AS $$ SELECT CASE n
  WHEN 'owner' THEN 'a0950000-0000-0000-8000-000000000001' WHEN 'manager' THEN 'a0950000-0000-0000-8000-000000000002'
  WHEN 'col1' THEN 'a0950000-0000-0000-8000-000000000003' END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;

-- ---------------------------------------------------------------- setup: one shop
RESET ROLE;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT 'a',public.admin_provision_organization('TEST5 a','test5-key-a','retail_pro','Owner','atest5@example.com',NULL,'Main',repeat('t',64),now()+interval '1 day');
INSERT INTO auth.users(id,email) VALUES('a0950000-0000-0000-8000-000000000001','atest5@example.com'),
  ('a0950000-0000-0000-8000-000000000002','test5manager@example.com'),('a0950000-0000-0000-8000-000000000003','test5col1@example.com');
SELECT public.accept_invite(repeat('t',64),'a0950000-0000-0000-8000-000000000001');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',id FROM public.cash_accounts WHERE organization_id=t.org('a') AND kind='safe' AND branch_id=t.id('main');
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0 WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id=t.org('a');
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('manager','a0950000-0000-0000-8000-000000000002','TEST5 Manager','BRANCH_MANAGER');
SELECT t.emp('col1','a0950000-0000-0000-8000-000000000003','TEST5 Collector','COLLECTOR');
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text,p_limit numeric) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id,city,address)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],p_limit,'active','291010101005'||right(p_phone,2),'Cairo','5 B Street') RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('sums','Sums Samir','01035550001',100000000);
SELECT t.cust('alloc','Alloc Amal','01035550002',500000);
SELECT t.cust('field','Field Fady','01035550003',500000);
SELECT t.cust('limit','Limit Lamia','01035550004',15000);
-- Policy version 1: three markup tiers, rounding to whole pounds, 3 grace days.
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":10,"up_to_months":6},{"pct":15,"up_to_months":12},{"pct":20,"up_to_months":24}]',
         '{monthly}',1,3,'percent_of_future_profit',50,100000000,1,100000000
  FROM public.installment_policies WHERE organization_id=t.org('a');
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
RESET ROLE;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"T5-TV","cash_price":"12000"}'));
INSERT INTO t.ids VALUES('fan',public.create_product('{"name_ar":"مروحة","name_en":"Fan","sku":"T5-FAN","cash_price":"999.99"}'));
INSERT INTO t.ids VALUES('odd',public.create_product('{"name_ar":"غسالة","name_en":"Washer","sku":"T5-ODD","cash_price":"7777.77"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(
  jsonb_build_object('product_id',t.id('tv'),'quantity',200),jsonb_build_object('product_id',t.id('fan'),'quantity',200),
  jsonb_build_object('product_id',t.id('odd'),'quantity',200)),'test5-key-found');
RESET ROLE;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','test5-key-shift');
RESET ROLE;

-- ================================================================ 1. schedules add up exactly
-- 3 prices x 3 down payments (10 %, 25 %, a third) x 6 counts over the three tiers, on policy 1
-- (whole pounds); the same again after policy 2 (piastres, one tier). 108 contracts.
CREATE TABLE t.sums(policy integer,product text,down text,n integer,contract_id uuid);
CREATE FUNCTION t.sweep(p_policy integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text; pct numeric; n integer; d text; r jsonb; BEGIN
  FOREACH p IN ARRAY ARRAY['tv','fan','odd'] LOOP
    FOREACH pct IN ARRAY ARRAY[0.10,0.25,0.3333] LOOP
      FOREACH n IN ARRAY ARRAY[1,5,6,7,13,24] LOOP
        SELECT ceil(cash_price*pct*100)/100 INTO d FROM public.products WHERE id=t.id(p);
        d := d::numeric(18,2)::text;
        r := t.sell(p,1,'sums',d,n,format('test5-key-sum-%s-%s-%s-%s',p_policy,p,pct,n));
        INSERT INTO t.sums VALUES(p_policy,p,d,n,(r->'contract'->>'id')::uuid);
      END LOOP;
    END LOOP;
  END LOOP; END $$;
GRANT INSERT,SELECT ON t.sums TO authenticated;
GRANT EXECUTE ON FUNCTION t.sweep(integer) TO authenticated;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.sweep(1);
RESET ROLE;
-- Kept to prove (5) below: policy 1's contracts must not move when policy 2 is published.
CREATE TABLE t.v1_before AS
  SELECT c.id,c.policy_id,c.markup_pct,c.markup_amount,c.total_payable,
         (SELECT jsonb_agg(to_jsonb(l)-'created_at' ORDER BY l.seq) FROM public.schedule_lines l WHERE l.contract_id=c.id) lines
  FROM public.contracts c JOIN t.sums s ON s.contract_id=c.id;
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),max(version)+1,10,24,'[{"pct":18,"up_to_months":24}]','{monthly}',0.01,3,'percent_of_future_profit',50,
         100000000,1,100000000
  FROM public.installment_policies WHERE organization_id=t.org('a');
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.sweep(2);
RESET ROLE;

CREATE TABLE t.sum_rows AS
  SELECT s.*,c.cash_price,c.down_payment,c.financed_amount,c.markup_amount,c.total_payable,c.installments_count,
         (SELECT count(*) FROM public.schedule_lines l WHERE l.contract_id=c.id) lines,
         (SELECT sum(l.amount) FROM public.schedule_lines l WHERE l.contract_id=c.id) amount_sum,
         (SELECT sum(l.principal) FROM public.schedule_lines l WHERE l.contract_id=c.id) principal_sum,
         (SELECT sum(l.profit) FROM public.schedule_lines l WHERE l.contract_id=c.id) profit_sum,
         (SELECT bool_and(l.amount>0) FROM public.schedule_lines l WHERE l.contract_id=c.id) all_positive
  FROM t.sums s JOIN public.contracts c ON c.id=s.contract_id;
SELECT t.expect('sums: 108 contracts sold (3 prices x 3 down payments x 6 counts x 2 policies)',
  (SELECT count(*)=108 AND count(DISTINCT contract_id)=108 FROM t.sum_rows),(SELECT count(*)::text FROM t.sum_rows));
SELECT t.expect('sums: every schedule has its count of lines and adds up to the total payable, to the piastre',
  NOT EXISTS (SELECT 1 FROM t.sum_rows WHERE lines<>n OR installments_count<>n OR amount_sum<>total_payable OR NOT all_positive),
  (SELECT string_agg(product||'/'||down||'/'||n||': '||amount_sum||' vs '||total_payable,', ') FROM t.sum_rows WHERE amount_sum<>total_payable));
SELECT t.expect('sums: principals add up to what is financed, profits to the markup; total = cash price - down payment + markup',
  NOT EXISTS (SELECT 1 FROM t.sum_rows WHERE principal_sum<>financed_amount OR profit_sum<>markup_amount
                OR financed_amount<>cash_price-down_payment OR total_payable<>cash_price-down_payment+markup_amount));
SELECT t.expect('sums: on policy 1 every line but the last is in whole pounds (rounding step 1.00)',
  NOT EXISTS (SELECT 1 FROM t.sums s JOIN public.contracts c ON c.id=s.contract_id JOIN public.schedule_lines l ON l.contract_id=c.id
              WHERE s.policy=1 AND l.seq<c.installments_count AND l.amount<>trunc(l.amount)));
SELECT t.expect('sums: the markup tier follows the count (10 % to 6 months, 15 % to 12, 20 % to 24) on policy 1, 18 % on policy 2',
  NOT EXISTS (SELECT 1 FROM t.sums s JOIN public.contracts c ON c.id=s.contract_id
              WHERE c.markup_pct<>CASE WHEN s.policy=2 THEN 18 WHEN s.n<=6 THEN 10 WHEN s.n<=12 THEN 15 ELSE 20 END));

-- ================================================================ 5. a new policy applies only to new contracts
SELECT t.expect('policy: publishing version 2 left every version 1 contract and its lines exactly as they were',
  NOT EXISTS (SELECT 1 FROM t.v1_before b JOIN public.contracts c ON c.id=b.id
              WHERE c.policy_id<>b.policy_id OR c.markup_pct<>b.markup_pct OR c.markup_amount<>b.markup_amount
                 OR c.total_payable<>b.total_payable
                 OR b.lines<>(SELECT jsonb_agg(to_jsonb(l)-'created_at' ORDER BY l.seq) FROM public.schedule_lines l WHERE l.contract_id=c.id))
  AND (SELECT count(*)=54 FROM t.v1_before));
SELECT t.expect('policy: version 1 contracts point at version 1, the new ones at version 2',
  (SELECT bool_and(ip.version=t.pv()-1) FROM t.sums s JOIN public.contracts c ON c.id=s.contract_id
     JOIN public.installment_policies ip ON ip.id=c.policy_id WHERE s.policy=1)
  AND (SELECT bool_and(ip.version=t.pv()) FROM t.sums s JOIN public.contracts c ON c.id=s.contract_id
     JOIN public.installment_policies ip ON ip.id=c.policy_id WHERE s.policy=2));
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('policy: a sale on terms of the old version is refused (POLICY_CHANGED)',
  format($q$SELECT public.post_installment_sale(%L::jsonb,'test5-key-oldpolicy')$q$,
    jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),
      'expected_total','12000.00','customer_id',t.id('sums'),
      'terms',jsonb_build_object('down_payment','2000.00','installments_count',12,'frequency','monthly','policy_version',t.pv()-1))),
  'POLICY_CHANGED');
RESET ROLE;

-- ================================================================ 2. allocation order
-- A TV over 12 months on policy 2 (18 %, piastres): the lines are read back from the contract and the
-- allocation is checked against them, so the test does not depend on how the engine rounds.
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's-alloc',t.sell('tv',1,'alloc','2000.00',12,'test5-key-sale-alloc');
INSERT INTO t.docs SELECT 's-field',t.sell('tv',1,'field','2000.00',12,'test5-key-sale-field');
INSERT INTO t.docs SELECT 's-field2',t.sell('fan',1,'field','100.00',6,'test5-key-sale-field2');
RESET ROLE;
INSERT INTO t.ids SELECT 'k-alloc',(t.doc('s-alloc')->'contract'->>'id')::uuid;
INSERT INTO t.ids SELECT 'k-field',(t.doc('s-field')->'contract'->>'id')::uuid;
INSERT INTO t.ids SELECT 'k-field2',(t.doc('s-field2')->'contract'->>'id')::uuid;
CREATE TABLE t.sched AS SELECT seq,amount,principal,profit FROM public.schedule_lines WHERE contract_id=t.id('k-alloc') ORDER BY seq;
-- Pays line 1, line 2 and part of line 3 at the counter.
CREATE TABLE t.amt AS SELECT (SELECT amount FROM t.sched WHERE seq=1)+(SELECT amount FROM t.sched WHERE seq=2)
  +least((SELECT profit FROM t.sched WHERE seq=3)+5,(SELECT amount FROM t.sched WHERE seq=3)-1) v;
GRANT SELECT ON t.sched,t.amt TO authenticated;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p1',t.pay('k-alloc',(SELECT v FROM t.amt)::text,'test5-key-p1');
RESET ROLE;
SELECT t.expect('allocation: at the counter the oldest lines are paid first, in full',
  (SELECT status='paid' AND paid=amount AND paid_profit=profit AND paid_principal=principal FROM t.line('k-alloc',1))
  AND (SELECT status='paid' AND paid=amount AND paid_profit=profit AND paid_principal=principal FROM t.line('k-alloc',2)));
SELECT t.expect('allocation: the part payment of line 3 covers its profit first, then 5.00 of principal',
  (SELECT paid_profit=profit AND paid_principal=5 AND remaining=amount-profit-5 FROM t.line('k-alloc',3))
  AND (SELECT paid=0 FROM t.line('k-alloc',4)));
SELECT t.expect('allocation: the collection''s rows add up to the payment and go to lines 1-3 only',
  (SELECT sum(pa.amount)=(SELECT v FROM t.amt) AND array_agg(DISTINCT sl.seq ORDER BY sl.seq)=ARRAY[1,2,3]
   FROM public.payment_allocations pa JOIN public.schedule_lines sl ON sl.id=pa.schedule_line_id
   WHERE pa.payment_id=(t.doc('p1')->>'id')::uuid));

-- Line 4 is late (10 days): a payment still goes to the oldest open line (3) first, then line 4.
SELECT t.late('k-alloc',4,10);
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p2',t.pay('k-alloc',(SELECT remaining+10 FROM t.line('k-alloc',3))::text,'test5-key-p2');
RESET ROLE;
SELECT t.expect('allocation: with line 4 late, line 3 is finished first, then line 4''s profit (no fee in between)',
  (SELECT status='paid' FROM t.line('k-alloc',3))
  AND (SELECT paid=10 AND paid_profit=least(10,profit) AND paid_principal=10-least(10,profit) FROM t.line('k-alloc',4)));

-- After a reschedule the new version's lines are paid the same way; nothing goes to superseded lines.
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r1',t.resched('k-alloc',6,20,'test5-key-r1');
RESET ROLE;
CREATE TABLE t.v2 AS SELECT seq,amount,principal,profit FROM public.schedule_lines
  WHERE contract_id=t.id('k-alloc') AND version=2 ORDER BY seq;
GRANT SELECT ON t.v2 TO authenticated;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p3',t.pay('k-alloc',((SELECT amount FROM t.v2 WHERE seq=1)+1)::text,'test5-key-p3');
RESET ROLE;
SELECT t.expect('allocation: after the reschedule, line 1 of version 2 is paid in full, then 1.00 of line 2''s profit',
  (SELECT status='paid' AND paid=amount FROM t.line('k-alloc',1))
  AND (SELECT paid=1 AND paid_profit=1 AND paid_principal=0 FROM t.line('k-alloc',2))
  AND (SELECT (SELECT profit FROM t.v2 WHERE seq=2)>=1));
SELECT t.expect('allocation: the payment after the reschedule touches only version 2 lines',
  (SELECT bool_and(sl.version=2 AND NOT sl.superseded) FROM public.payment_allocations pa
     JOIN public.schedule_lines sl ON sl.id=pa.schedule_line_id WHERE pa.payment_id=(t.doc('p3')->>'id')::uuid));

-- ================================================================ 3. a late installment never costs more
CREATE TABLE t.before_late AS SELECT t.left('k-alloc') v;
SELECT t.late('k-field',1,3);
INSERT INTO t.docs SELECT 'run1',t.run();
SELECT t.expect('late: inside the 3 grace days the line is not overdue and no warning is made',
  (SELECT status<>'overdue' FROM t.line('k-field',1))
  AND NOT EXISTS (SELECT 1 FROM public.overdue_actions WHERE contract_id=t.id('k-field')));
SELECT t.late('k-field',1,4);
INSERT INTO t.docs SELECT 'run2',t.run();
INSERT INTO t.docs SELECT 'run3',t.run();
SELECT t.expect('late: a day after the grace the line is overdue, with one warning; the second run that day adds nothing; the rescheduled contract is not late',
  (SELECT status='overdue' FROM t.line('k-field',1))
  AND (SELECT count(*)=1 FROM public.overdue_actions WHERE contract_id=t.id('k-field') AND kind='warning')
  AND NOT EXISTS (SELECT 1 FROM public.overdue_actions WHERE contract_id=t.id('k-alloc')),
  t.doc('run3')::text);
SELECT t.expect('late: no charge row anywhere, the policies carry no fee, and what is owed did not grow',
  NOT EXISTS (SELECT 1 FROM public.charges WHERE organization_id=t.org('a'))
  AND NOT EXISTS (SELECT 1 FROM public.installment_policies WHERE organization_id=t.org('a') AND (late_fee_type<>'none' OR late_fee_value<>0))
  AND t.left('k-alloc')=(SELECT v FROM t.before_late)
  AND t.left('k-field')=(SELECT total_payable FROM public.contracts WHERE id=t.id('k-field')));
SELECT t.error('late: a policy with a late fee can''t be stored (rule 4)',
  format($q$INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,late_fee_type,late_fee_value) VALUES(%L,99,10,24,'[{"pct":18,"up_to_months":24}]','{monthly}',1,'fixed',50)$q$,t.org('a')),
  'new row for relation "installment_policies" violates check constraint "installment_policies_no_late_fee"');

-- ================================================================ 4. the credit limit, whoever calls
-- Limit 15 000: a TV (10 000 financed) fits; a second one (another 10 000) does not.
CREATE FUNCTION t.counts() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'contracts',(SELECT count(*) FROM public.contracts WHERE organization_id=t.org('a')),
    'sales',(SELECT count(*) FROM public.sales WHERE organization_id=t.org('a')),
    'lines',(SELECT count(*) FROM public.schedule_lines WHERE organization_id=t.org('a')),
    'stock',(SELECT sum(on_hand) FROM public.stock_levels WHERE organization_id=t.org('a')),
    'cash',(SELECT sum(balance) FROM public.cash_balances WHERE organization_id=t.org('a')),
    'counters',(SELECT jsonb_object_agg(doc_type||'/'||period_year,next_value) FROM public.document_counters WHERE organization_id=t.org('a')),
    'audit',(SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a'))) $$;
GRANT EXECUTE ON FUNCTION t.counts() TO authenticated;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's-limit1',t.sell('tv',1,'limit','2000.00',12,'test5-key-limit1');
INSERT INTO t.docs SELECT 'before-refused',t.counts();
SELECT t.error('credit: a second contract above the limit is refused by the database (CREDIT_LIMIT_EXCEEDED)',
  $q$SELECT t.sell('tv',1,'limit','2000.00',12,'test5-key-limit2')$q$,'CREDIT_LIMIT_EXCEEDED');
INSERT INTO t.docs SELECT 'after-refused',t.counts();
RESET ROLE;
SELECT t.expect('credit: the refused sale wrote nothing (no contract, sale, line, stock or cash move, number or audit row)',
  t.doc('before-refused')=t.doc('after-refused'),t.doc('after-refused')::text);
SELECT t.expect('credit: the open contract''s unpaid principal is the exposure; 5 000 is still available',
  (SELECT (app.customer_credit_profile_json(t.org('a'),t.id('limit'))->>'available')::numeric=5000));
-- Owner too: no role is above the limit without an approved exception.
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift-owner',t.open_shift(t.id('main'),'0','test5-key-shift-owner');
RESET ROLE;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('credit: the owner is refused as well',
  $q$SELECT t.sell('tv',1,'limit','2000.00',12,'test5-key-limit3')$q$,'CREDIT_LIMIT_EXCEEDED');
RESET ROLE;
SELECT t.error('credit: a contract row can''t be written around the functions',
  format($q$SET LOCAL ROLE authenticated; INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,policy_id,creditor,cash_price,
    financed_amount,markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,idempotency_key)
    SELECT %L,'X',%L,%L,policy_id,creditor,1,1,0,0,1,1,'monthly',current_date,'test5-key-direct' FROM public.contracts WHERE id=%L$q$,
    t.org('a'),t.id('limit'),t.id('main'),t.id('k-alloc')),'permission denied for table contracts');
RESET ROLE;

-- ================================================================ 6. the collector's wallet = its ledger
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT public.set_customer_collector(t.id('field'),t.id('col1'),'Covers the east side');
RESET ROLE;
CREATE TABLE t.safe0 AS SELECT t.bal(t.id('safe')) v;
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'f1',t.fpay('k-field','1000.00','test5-key-f1');
INSERT INTO t.docs SELECT 'f2',t.fpay('k-field2','150.00','test5-key-f2');
RESET ROLE;
SELECT t.expect('wallet: two field collections, 1 150.00 = its ledger',t.wallet_ok('col1',1150));
SELECT t.expect('wallet: the field collection paid the overdue line 1 of the contract first',
  (SELECT paid=least(1000,amount) FROM t.line('k-field',1)));
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'rev',public.reverse_collection((t.doc('f2')->>'id')::uuid,'{"reason":"Wrong amount typed"}','test5-key-rev');
RESET ROLE;
SELECT t.expect('wallet: reversed while the cash is in the wallet: 1 000.00 = its ledger; the fan contract owes it again',
  t.wallet_ok('col1',1000) AND t.left('k-field2')=(SELECT total_payable FROM public.contracts WHERE id=t.id('k-field2')));
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'st1',t.wsettle('col1','safe','700.00','100.00','Torn note','test5-key-st1');
RESET ROLE;
SELECT t.expect('wallet: settled 700.00 with a 100.00 shortage: 200.00 left = its ledger; the safe got 700.00 only',
  t.wallet_ok('col1',200) AND t.bal(t.id('safe'))=(SELECT v FROM t.safe0)+700);
SELECT t.as_user(t.u('col1'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'f3',t.fpay('k-field2','300.00','test5-key-f3');
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'st2',t.wsettle('col1','safe','500.00',NULL,NULL,'test5-key-st2');
RESET ROLE;
SELECT t.expect('wallet: collected again and settled in full: 0.00 = its ledger; the safe holds every pound handed in',
  t.wallet_ok('col1',0) AND t.bal(t.id('safe'))=(SELECT v FROM t.safe0)+1200);
SELECT t.expect('wallet: net collections into the wallet (1 000 + 150 - 150 + 300) = handed in (1 200) + shortage (100) + left (0)',
  (SELECT sum(CASE WHEN direction='in' THEN amount ELSE -amount END) FROM public.payments WHERE cash_account_id=t.wallet('col1'))=1300);

-- ================================================================ every cache = its ledger (F10)
SELECT t.expect('reconcile: every cached stock and cash balance of the shop matches its ledger',
  NOT EXISTS (SELECT 1 FROM app.ledger_mismatches() WHERE organization_id=t.org('a')),
  (SELECT string_agg(ledger||' '||subject_id||' '||cached||'/'||from_ledger,', ') FROM app.ledger_mismatches() WHERE organization_id=t.org('a')));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
