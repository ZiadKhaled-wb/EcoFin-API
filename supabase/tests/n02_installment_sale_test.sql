-- N02 installment sale and contract (EC-81, D77).
-- Run by: node scripts/db-smoke.mjs supabase/tests/n02_installment_sale_test.sql (inside BEGIN ... ROLLBACK).
-- A cashier sells on installments in one request: the sale, its stock, the down payment, the
-- contract with its number and version-1 schedule, its guarantors and the credit exception it
-- used, two audit rows. Every refusal leaves nothing behind. The commit-time safety nets of
-- R03/R04/R05/N01 are fired after each sale (t.commit) and must accept what N02 wrote.
-- (Many requests at the same moment: scripts/db-stock-cash-proof.mjs.)
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from s02_split_payments_test.sql).
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
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
CREATE FUNCTION t.pv() RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT (app.current_installment_policy(t.org('a'))).version $$;
-- Everything an installment sale writes, counted for shop a.
CREATE FUNCTION t.footprint() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',
    (SELECT count(*) FROM public.sales WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.stock_movements WHERE organization_id=t.org('a') AND type='sale_out'),
    (SELECT count(*) FROM public.payments WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.cash_movements WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.contracts WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.schedule_lines WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.contract_guarantors WHERE organization_id=t.org('a')),
    (SELECT COALESCE(sum(next_value),0) FROM public.document_counters WHERE organization_id=t.org('a') AND doc_type IN ('sale','payment','contract')),
    (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action IN ('sale.created','contract.created'))) $$;
-- The body of an installment sale.
CREATE FUNCTION t.body(p_lines jsonb,p_expected text,p_customer uuid,p_down text,p_count integer,p_freq text DEFAULT 'monthly',p_extra jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('lines',p_lines,'expected_total',p_expected,'customer_id',p_customer,
    'terms',jsonb_build_object('down_payment',p_down,'installments_count',p_count,'frequency',p_freq,'policy_version',t.pv())
      || COALESCE(p_extra->'terms','{}'::jsonb)) || (p_extra - 'terms') $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_array(jsonb_build_object('product_id',t.id(p),'quantity',q)) $$;
-- An installment sale, then the commit-time checks run now (as they would at COMMIT).
CREATE FUNCTION t.sell(p_body jsonb,p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_installment_sale(p_body,p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
CREATE FUNCTION t.q(p_body jsonb,p_key text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT t.sell(%L,%L)',p_body,COALESCE(p_key,'n02-'||md5(random()::text))) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (retail_pro), b (retail), c (starter)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('N02 '||s,'n02-'||s,p,'Owner',s||'n02@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('n',64)),('b','retail',repeat('o',64)),('c','starter',repeat('p',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0770000-0000-0000-8000-000000000001','an02@example.com'),('a0770000-0000-0000-8000-000000000002','bn02@example.com'),
  ('a0770000-0000-0000-8000-000000000003','n02cashier@example.com'),('a0770000-0000-0000-8000-000000000004','n02warehouse@example.com'),
  ('a0770000-0000-0000-8000-000000000005','cn02@example.com'),('a0770000-0000-0000-8000-000000000006','n02cashier2@example.com');
SELECT public.accept_invite(repeat('n',64),'a0770000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('o',64),'a0770000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('p',64),'a0770000-0000-0000-8000-000000000005');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main-c',id FROM public.branches WHERE organization_id=t.org('c') AND is_main;
INSERT INTO t.ids SELECT 'owner',id FROM public.employees WHERE organization_id=t.org('a') AND role='OWNER';
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,discount_caps='{"CASHIER":5,"BRANCH_MANAGER":15}' WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'),t.org('c'));
SELECT t.as_user('a0770000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','N2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"N2-TV","cash_price":"12000"}'));
INSERT INTO t.ids VALUES('sofa',public.create_product('{"name_ar":"كنبة","name_en":"Sofa","sku":"N2-SF","cash_price":"25000"}'));
INSERT INTO t.ids VALUES('kitchen',public.create_product('{"name_ar":"مطبخ","name_en":"Kitchen","sku":"N2-KT","cash_price":"40000"}'));
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"N2-CH","cash_price":"1000"}'));
INSERT INTO t.ids VALUES('lamp',public.create_product('{"name_ar":"مصباح","name_en":"Lamp","sku":"N2-LP","cash_price":"100"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(
  jsonb_build_object('product_id',t.id('tv'),'quantity',30),jsonb_build_object('product_id',t.id('sofa'),'quantity',5),
  jsonb_build_object('product_id',t.id('kitchen'),'quantity',5),jsonb_build_object('product_id',t.id('chair'),'quantity',50)),'n02-found');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0770000-0000-0000-8000-000000000003','N02 Cashier','CASHIER');
SELECT t.emp('wh','a0770000-0000-0000-8000-000000000004','N02 Warehouse','WAREHOUSE');
SELECT t.emp('cashier2','a0770000-0000-0000-8000-000000000006','N02 Cashier Two','CASHIER','second');
-- Customers (made as the database owner: the limit is set here, R03 tests set_customer_credit_limit).
CREATE FUNCTION t.cust(p_tag text,p_name text,p_limit numeric,p_nid text,p_status text DEFAULT 'active',p_org text DEFAULT 'a') RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
    VALUES(t.org(p_org),p_name,ARRAY['0100000'||lpad((random()*9999)::int::text,4,'0')],p_limit,p_status::public.customer_status,p_nid) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('ok','Good Customer',200000,'29001010100101');
SELECT t.cust('poor','No Limit Customer',0,'29001010100102');
SELECT t.cust('blocked','Blocked Customer',100000,'29001010100103','blocked');
SELECT t.cust('noid','No ID Customer',100000,NULL);
SELECT t.cust('blankid','Blank ID Customer',100000,'   ');
SELECT t.cust('pay','Payer Customer',100000,'29001010100104');
SELECT t.cust('cust-b','Shop B Customer',100000,'29001010100105','active','b');
-- Store credit of 2000.00 for the payer (nothing creates it before S05: seeded in the ledger).
INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date)
  VALUES(t.org('a'),t.id('pay'),2000.00,'sales_return',gen_random_uuid(),t.id('main'),app.org_today(t.org('a')));
-- The policy: 10 % up to 6 months, 20 % up to 24; all frequencies; step 1; 10 % minimum down
-- payment; a guarantor above 20 000 financed, a survey above 30 000.
CREATE FUNCTION t.publish(p_min numeric) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
      rounding_step,guarantor_required_above,guarantors_required_count,survey_required_above)
    SELECT t.org('a'),COALESCE(max(version),0)+1,p_min,24,'[{"pct":10,"up_to_months":6},{"pct":20,"up_to_months":24}]','{monthly,weekly,daily}',
      1,20000,1,30000 FROM public.installment_policies WHERE organization_id=t.org('a') $$;
SELECT t.publish(10);

-- The cashier opens a shift in the main branch.
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','n02-shift-1');
RESET ROLE;
INSERT INTO t.ids SELECT 'drawer',(t.doc('shift')->>'drawer_account_id')::uuid;
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=(t.doc('shift')->>'id')::uuid AND t.id('drawer') IS NULL;

-- ================================================================ the slice's checks
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
CREATE TEMP TABLE before_cash AS SELECT t.cash('drawer') v;
INSERT INTO t.docs SELECT 'first',t.sell(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12),'n02-first');
RESET ROLE;
INSERT INTO t.ids SELECT 'c1',(t.doc('first')->'contract'->>'id')::uuid;
INSERT INTO t.ids SELECT 's1',(t.doc('first')->'sale'->>'id')::uuid;
SELECT t.expect('slice: contract total = cash price - down payment + markup (12 000 - 2 000 + 2 000 at the 20 % tier)',
  (SELECT cash_price=12000 AND down_payment=2000 AND financed_amount=10000 AND markup_pct=20 AND markup_amount=2000
     AND total_payable=12000 AND total_payable=cash_price-down_payment+markup_amount
   FROM public.contracts WHERE id=t.id('c1')));
SELECT t.expect('slice: 12 monthly lines of 1000.00 that add up to the total, principal and profit',
  (SELECT count(*)=12 AND sum(amount)=12000 AND sum(principal)=10000 AND sum(profit)=2000 AND min(amount)=1000 AND max(amount)=1000
   FROM public.schedule_lines WHERE contract_id=t.id('c1') AND version=1));
SELECT t.expect('slice: the lines are the engine''s for the contract''s policy and the shop date',
  (SELECT jsonb_agg(jsonb_build_object('seq',l.seq,'due_date',l.due_date::text,'principal',l.principal::text,'profit',l.profit::text,'amount',l.amount::text) ORDER BY l.seq)
     = app.installment_terms((SELECT p FROM public.installment_policies p WHERE p.id=c.policy_id),
         jsonb_build_object('cash_price','12000.00','down_payment','2000.00','installments_count',12,'frequency','monthly'),app.org_today(t.org('a')))->'lines'
   FROM public.contracts c JOIN public.schedule_lines l ON l.contract_id=c.id WHERE c.id=t.id('c1') GROUP BY c.policy_id));
SELECT t.expect('slice: the down payment is in the shift''s drawer (one cash movement of 2000.00)',
  t.cash('drawer')=(SELECT v FROM before_cash)+2000
  AND (SELECT count(*)=1 AND sum(amount)=2000 FROM public.cash_movements WHERE source_id=t.id('s1') AND cash_account_id=t.id('drawer')));
SELECT t.expect('slice: the sale is settled (paid 2000 + financed 10 000 = total, unpaid 0)',
  (SELECT paid=2000 AND financed=10000 AND unpaid=0 FROM public.v_sale_balances WHERE sale_id=t.id('s1')));
SELECT t.expect('slice: the customer account shows the contract with its total and open balance',
  (SELECT app.customer_open_balance(t.org('a'),t.id('ok'))->>'open_balance'='12000.00'));
SELECT t.as_user('a0770000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('slice: R02 account lists the contract; the statement closes at the installment price',
  (SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(public.get_customer_account(t.id('ok'))->'contracts') c
                  WHERE c->>'id'=t.id('c1')::text AND c->>'total_payable'='12000.00')
     AND (public.customer_statement(t.id('ok'))->>'closing_balance')::numeric=12000));
RESET ROLE;
SELECT t.expect('contract: number CT, active, sale linked, in_house creditor, the request key, created by the cashier',
  (SELECT number LIKE '%CT%' AND status='active' AND sale_id=t.id('s1') AND order_id IS NULL AND creditor='in_house'
     AND idempotency_key='n02-first' AND created_by=t.id('cashier') AND current_version=1 AND NOT is_migrated
   FROM public.contracts WHERE id=t.id('c1')));
SELECT t.expect('contract: on the shop''s current policy version',
  (SELECT c.policy_id=(app.current_installment_policy(t.org('a'))).id FROM public.contracts c WHERE c.id=t.id('c1')));
SELECT t.expect('answer: sale and contract, the contract with 12 lines and its balance',
  (SELECT x->'sale'->>'total'='12000.00' AND x->'contract'->>'number'=(SELECT number FROM public.contracts WHERE id=t.id('c1'))
     AND jsonb_array_length(x->'contract'->'lines')=12 AND x->'contract'->'balance'->>'remaining'='12000.00'
     AND x->'contract'->>'total_payable'='12000.00' AND x->'contract'->>'markup_pct'='20'
     AND x->'contract'->>'policy_version'=t.pv()::text
   FROM (SELECT t.doc('first') x) y));
SELECT t.expect('audit: sale.created (payments = the down payment) and contract.created (info)',
  (SELECT count(*)=1 FROM public.audit_log WHERE action='sale.created' AND entity_id=t.id('s1')
     AND after->'payments'->0->>'amount'='2000.00')
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='contract.created' AND entity_id=t.id('c1') AND severity='info'
     AND after->>'total_payable'='12000.00' AND after->>'down_payment'='2000.00' AND branch_id=t.id('main')));

-- ================================================================ idempotency
CREATE TEMP TABLE fp AS SELECT t.footprint() v;
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('repeat: the same key returns the same sale and contract and writes nothing',
  (t.sell(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12),'n02-first')->'contract'->>'id')=t.id('c1')::text);
SELECT public.post_sale(t.items('chair',1),'1000.00','n02-cash-key');
SELECT t.error('repeat: a key a cash sale used -> IDEMPOTENCY_CONFLICT',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12),'n02-cash-key'),'IDEMPOTENCY_CONFLICT');
RESET ROLE;
UPDATE fp SET v=t.footprint();

-- ================================================================ refusals (nothing written, no number taken)
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('refused: no customer -> VALIDATION_FAILED',t.q(t.body(t.items('tv',1),'12000.00',NULL,'2000.00',12)),'VALIDATION_FAILED');
SELECT t.error('refused: an unknown customer -> CUSTOMER_NOT_FOUND',t.q(t.body(t.items('tv',1),'12000.00',gen_random_uuid(),'2000.00',12)),'CUSTOMER_NOT_FOUND');
SELECT t.error('refused: shop B''s customer -> CUSTOMER_NOT_FOUND',t.q(t.body(t.items('tv',1),'12000.00',t.id('cust-b'),'2000.00',12)),'CUSTOMER_NOT_FOUND');
SELECT t.error('refused: a blocked customer -> CUSTOMER_BLOCKED',t.q(t.body(t.items('tv',1),'12000.00',t.id('blocked'),'2000.00',12)),'CUSTOMER_BLOCKED');
SELECT t.error('refused: no national ID -> CUSTOMER_NATIONAL_ID_REQUIRED',t.q(t.body(t.items('tv',1),'12000.00',t.id('noid'),'2000.00',12)),'CUSTOMER_NATIONAL_ID_REQUIRED');
SELECT t.error('refused: a blank national ID -> CUSTOMER_NATIONAL_ID_REQUIRED',t.q(t.body(t.items('tv',1),'12000.00',t.id('blankid'),'2000.00',12)),'CUSTOMER_NATIONAL_ID_REQUIRED');
SELECT t.error('refused: over the credit limit -> CREDIT_LIMIT_EXCEEDED',t.q(t.body(t.items('tv',1),'12000.00',t.id('poor'),'2000.00',12)),'CREDIT_LIMIT_EXCEEDED');
SELECT t.error('refused: an unknown credit approval -> CREDIT_APPROVAL_INVALID',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('poor'),'2000.00',12,'monthly',jsonb_build_object('credit_approval_id',gen_random_uuid()))),'CREDIT_APPROVAL_INVALID');
SELECT t.error_detail('refused: above 20 000 financed without a guarantor -> GUARANTOR_REQUIRED',
  t.q(t.body(t.items('sofa',1),'25000.00',t.id('ok'),'2500.00',12)),'GUARANTOR_REQUIRED','{"required":1,"given":0}');
SELECT t.error_detail('refused: a rule broken -> INSTALLMENT_TERMS_INVALID with the list',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'100.00',12)),'INSTALLMENT_TERMS_INVALID','{"violations":[{"rule":"down_payment_too_low"}]}');
SELECT t.error_detail('refused: the preview''s policy version is old -> POLICY_CHANGED',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12,'monthly',jsonb_build_object('terms',jsonb_build_object('policy_version',t.pv()-0+99)))),
  'POLICY_CHANGED',jsonb_build_object('current_version',t.pv()));
SELECT t.error('refused: the price the cashier saw changed -> PRICE_CHANGED',t.q(t.body(t.items('tv',1),'11990.00',t.id('ok'),'2000.00',12)),'PRICE_CHANGED');
SELECT t.error_detail('refused: payment lines that don''t add up to the down payment -> PAYMENT_TOTAL_MISMATCH',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12,'monthly',jsonb_build_object('payments',jsonb_build_array(jsonb_build_object('method','cash','amount','1500.00'))))),
  'PAYMENT_TOTAL_MISMATCH','{"total":"2000.00","paid":"1500.00"}');
SELECT t.error('refused: an unknown key in the body -> VALIDATION_FAILED',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12,'monthly',jsonb_build_object('organization_id',t.org('b')))),'VALIDATION_FAILED');
SELECT t.error('refused: a missing policy version -> VALIDATION_FAILED',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12) #- '{terms,policy_version}'),'VALIDATION_FAILED');
SELECT t.error('refused: the same guarantor twice -> VALIDATION_FAILED',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12,'monthly',jsonb_build_object('guarantor_ids',jsonb_build_array(t.id('ok'),t.id('ok'))))),'VALIDATION_FAILED');
SELECT t.error('refused: an unknown guarantor -> GUARANTOR_NOT_FOUND',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12,'monthly',jsonb_build_object('guarantor_ids',jsonb_build_array(gen_random_uuid())))),'GUARANTOR_NOT_FOUND');
SELECT t.error('refused: out of stock -> OUT_OF_STOCK',t.q(t.body(t.items('lamp',1),'100.00',t.id('ok'),'10.00',2)),'OUT_OF_STOCK');
RESET ROLE;
SELECT t.expect('refused: nothing written by any refusal, no number taken',t.footprint()=(SELECT v FROM fp),t.footprint()||' vs '||(SELECT v FROM fp));

-- Shop-level refusals.
UPDATE public.organizations SET installments_enabled=false WHERE id=t.org('a');
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('refused: installments switched off -> INSTALLMENTS_DISABLED',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12)),'INSTALLMENTS_DISABLED');
RESET ROLE;
UPDATE public.organizations SET installments_enabled=true WHERE id=t.org('a');
UPDATE public.org_settings SET installment_markup_vat='taxed' WHERE organization_id=t.org('a');
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('refused: VAT on the profit (taxed) -> MARKUP_VAT_NOT_SUPPORTED',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12)),'MARKUP_VAT_NOT_SUPPORTED');
RESET ROLE;
UPDATE public.org_settings SET installment_markup_vat='not_taxed' WHERE organization_id=t.org('a');
SELECT t.as_user('a0770000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: a warehouse user (no installment.create) -> PERMISSION_DENIED',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12)),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0770000-0000-0000-8000-0000000000ff',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: not an employee -> NOT_AN_EMPLOYEE',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12)),'NOT_AN_EMPLOYEE');
RESET ROLE;
SELECT t.as_user('a0770000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: the owner without an open shift -> SHIFT_REQUIRED',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12)),'SHIFT_REQUIRED');
RESET ROLE;
SELECT t.as_user('a0770000-0000-0000-8000-000000000005',t.org('c'));
SET ROLE authenticated;
SELECT t.error('who: a plan without installments -> MODULE_NOT_IN_PLAN',t.q(t.body('[]','1000.00',t.id('ok'),'100.00',2)),'MODULE_NOT_IN_PLAN');
RESET ROLE;
UPDATE public.organizations SET subscription_start=NULL, subscription_end=app.org_today(id)-1 WHERE id=t.org('a');
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: an expired (read-only) shop can''t sell -> SUBSCRIPTION_EXPIRED',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12)),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=now()+interval '30 days' WHERE id=t.org('a');
-- A revoked device: the shift's device can't write.
UPDATE public.devices SET token_hash=NULL WHERE id=(SELECT device_id FROM public.shifts WHERE id=(t.doc('shift')->>'id')::uuid);
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: the shift''s device was revoked -> DEVICE_REVOKED',t.q(t.body(t.items('tv',1),'12000.00',t.id('ok'),'2000.00',12)),'DEVICE_REVOKED');
RESET ROLE;
UPDATE public.devices SET token_hash=encode(sha256(convert_to(id::text,'UTF8')),'hex') WHERE id=(SELECT device_id FROM public.shifts WHERE id=(t.doc('shift')->>'id')::uuid);
SELECT t.expect('refused: the shop-level refusals wrote nothing either',t.footprint()=(SELECT v FROM fp));

-- ================================================================ credit exception, guarantors, survey
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'ex',(public.request_credit_exception(t.id('poor'),'10000.00','Pays cash elsewhere')->>'id')::uuid;
RESET ROLE;
SELECT t.as_user('a0770000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.decide_credit_exception(t.id('ex'),true,'Known family');
INSERT INTO t.ids SELECT 'g1',(public.create_guarantor('{"full_name":"First Guarantor","phone":"01000000201","national_id":"29001010100201"}')->>'id')::uuid;
SELECT public.link_customer_guarantor(t.id('ok'),t.id('g1'),'brother');
RESET ROLE;
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'ex-sale',t.sell(t.body(t.items('tv',1),'12000.00',t.id('poor'),'2000.00',12,'monthly',
  jsonb_build_object('credit_approval_id',t.id('ex'))),'n02-exception');
SELECT t.error('exception: used once; a second sale with it -> CREDIT_APPROVAL_INVALID',
  t.q(t.body(t.items('tv',1),'12000.00',t.id('poor'),'2000.00',12,'monthly',jsonb_build_object('credit_approval_id',t.id('ex')))),'CREDIT_APPROVAL_INVALID');
INSERT INTO t.docs SELECT 'g-sale',t.sell(t.body(t.items('sofa',1),'25000.00',t.id('ok'),'2500.00',12,'monthly',
  jsonb_build_object('guarantor_ids',jsonb_build_array(t.id('g1')))),'n02-guarantor');
RESET ROLE;
SELECT t.expect('exception: over the limit with an approved exception passes; the exception points at the contract',
  (SELECT c.credit_approval_id=t.id('ex') AND a.entity_id=c.id FROM public.contracts c JOIN public.approvals a ON a.id=t.id('ex')
   WHERE c.id=(t.doc('ex-sale')->'contract'->>'id')::uuid));
SELECT t.expect('exception: its contract.created audit row is a warning',
  (SELECT severity='warning' FROM public.audit_log WHERE action='contract.created' AND entity_id=(t.doc('ex-sale')->'contract'->>'id')::uuid));
SELECT t.expect('guarantors: the linked guarantor is attached to the contract and in the answer',
  (SELECT count(*)=1 FROM public.contract_guarantors WHERE contract_id=(t.doc('g-sale')->'contract'->>'id')::uuid AND guarantor_id=t.id('g1'))
  AND t.doc('g-sale')->'contract'->'guarantors'->0->>'relation'='brother');
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('survey: above 30 000 financed without an approved survey -> SURVEY_REQUIRED',
  t.q(t.body(t.items('kitchen',1),'40000.00',t.id('ok'),'4000.00',12,'monthly',jsonb_build_object('guarantor_ids',jsonb_build_array(t.id('g1'))))),'SURVEY_REQUIRED');
RESET ROLE;
-- An approved survey (made as the database owner, as R05's test does).
WITH x AS (INSERT INTO public.field_surveys(organization_id,customer_id,assigned_to) VALUES(t.org('a'),t.id('ok'),t.id('owner')) RETURNING id)
INSERT INTO t.ids SELECT 'survey',id FROM x;
UPDATE public.field_surveys SET status='submitted',survey_score=80,submitted_at=now() WHERE id=t.id('survey');
UPDATE public.field_surveys SET status='approved',decided_by=t.id('owner'),decided_at=now() WHERE id=t.id('survey');
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'survey-sale',t.sell(t.body(t.items('kitchen',1),'40000.00',t.id('ok'),'4000.00',12,'monthly',
  jsonb_build_object('guarantor_ids',jsonb_build_array(t.id('g1')))),'n02-survey');
RESET ROLE;
SELECT t.expect('survey: above 30 000 with an approved survey and the guarantor passes',
  (t.doc('survey-sale')->'contract'->>'financed_amount')='36000.00');

-- ================================================================ variants
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'bank',t.sell(t.body(t.items('chair',1),'1000.00',t.id('pay'),'300.00',3,'monthly',
  jsonb_build_object('payments',jsonb_build_array(jsonb_build_object('method','bank_transfer','amount','300.00','cash_account_id',t.id('bank'),'reference','TRX-1')))),'n02-bank');
INSERT INTO t.docs SELECT 'credit',t.sell(t.body(t.items('chair',1),'1000.00',t.id('pay'),'200.00',4,'weekly',
  jsonb_build_object('payments',jsonb_build_array(jsonb_build_object('method','store_credit','amount','200.00')))),'n02-credit');
INSERT INTO t.docs SELECT 'daily',t.sell(t.body(t.items('chair',1),'1000.00',t.id('pay'),'100.00',45,'daily'),'n02-daily');
INSERT INTO t.docs SELECT 'disc',t.sell(t.body(t.items('tv',1),'11400.00',t.id('pay'),'1140.00',6,'monthly',
  jsonb_build_object('sale_discount',jsonb_build_object('type','percent','value','5'),'discount_reason','Loyal customer')),'n02-disc');
INSERT INTO t.docs SELECT 'monthend',t.sell(t.body(t.items('chair',1),'1000.00',t.id('pay'),'100.00',3,'monthly',
  jsonb_build_object('terms',jsonb_build_object('first_due_date',(date_trunc('month',t.today())+interval '2 month'-interval '1 day')::date::text))),'n02-monthend');
RESET ROLE;
SELECT t.expect('variant: a bank transfer down payment goes to the bank, not the drawer',
  (SELECT count(*)=1 FROM public.cash_movements WHERE source_id=(t.doc('bank')->'sale'->>'id')::uuid AND cash_account_id=t.id('bank') AND amount=300));
SELECT t.expect('variant: a store credit down payment lowers the customer''s balance',
  (SELECT balance=1800 FROM public.store_credit_balances WHERE customer_id=t.id('pay')));
SELECT t.expect('variant: weekly x 4 and daily x 45 contracts are written with their engine lines',
  (SELECT count(*)=4 FROM public.schedule_lines WHERE contract_id=(t.doc('credit')->'contract'->>'id')::uuid)
  AND (SELECT count(*)=45 AND sum(amount)=(SELECT total_payable FROM public.contracts WHERE id=(t.doc('daily')->'contract'->>'id')::uuid)
       FROM public.schedule_lines WHERE contract_id=(t.doc('daily')->'contract'->>'id')::uuid));
SELECT t.expect('variant: a discounted cart: the cash price is the discounted total',
  (SELECT c.cash_price=11400 AND s.discount_total=600 AND s.total=11400 FROM public.contracts c JOIN public.sales s ON s.id=c.sale_id
   WHERE c.id=(t.doc('disc')->'contract'->>'id')::uuid));
SELECT t.expect('variant: a month-end first due date; the next ones are counted from it',
  (SELECT array_agg(due_date ORDER BY seq)=ARRAY[c.first_due_date,(c.first_due_date+interval '1 month')::date,(c.first_due_date+interval '2 month')::date]
   FROM public.contracts c JOIN public.schedule_lines l ON l.contract_id=c.id
   WHERE c.id=(t.doc('monthend')->'contract'->>'id')::uuid GROUP BY c.first_due_date));

-- Zero down payment needs a policy that allows it (published after the first contract).
CREATE TEMP TABLE c1_before AS SELECT c.markup_amount,c.total_payable,c.policy_id,(SELECT jsonb_agg(l ORDER BY l.seq) FROM public.schedule_lines l WHERE l.contract_id=c.id) lines
  FROM public.contracts c WHERE c.id=t.id('c1');
SELECT t.publish(0);
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('zero down: payment lines with no down payment -> VALIDATION_FAILED',
  t.q(t.body(t.items('chair',1),'1000.00',t.id('pay'),'0.00',2,'monthly',jsonb_build_object('payments',jsonb_build_array(jsonb_build_object('method','cash','amount','0.01'))))),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'zero',t.sell(t.body(t.items('chair',1),'1000.00',t.id('pay'),'0.00',2),'n02-zero');
RESET ROLE;
SELECT t.expect('zero down: no payment row, the sale is settled by the contract alone',
  (SELECT count(*)=0 FROM public.payment_allocations WHERE sale_id=(t.doc('zero')->'sale'->>'id')::uuid)
  AND (SELECT paid=0 AND financed=1000 AND unpaid=0 FROM public.v_sale_balances WHERE sale_id=(t.doc('zero')->'sale'->>'id')::uuid));
SELECT t.expect('policy: a policy published after a contract leaves it and its lines unchanged',
  (SELECT b.markup_amount=c.markup_amount AND b.total_payable=c.total_payable AND b.policy_id=c.policy_id
     AND b.lines=(SELECT jsonb_agg(l ORDER BY l.seq) FROM public.schedule_lines l WHERE l.contract_id=c.id)
   FROM c1_before b, public.contracts c WHERE c.id=t.id('c1')));
SELECT t.expect('policy: the next contract uses the new version',
  (SELECT c.policy_id=(app.current_installment_policy(t.org('a'))).id FROM public.contracts c WHERE c.id=(t.doc('zero')->'contract'->>'id')::uuid));

-- ================================================================ never edited
DO $$ BEGIN
  BEGIN UPDATE public.contracts SET total_payable=total_payable+1, markup_amount=markup_amount+1 WHERE id=t.id('c1');
        PERFORM t.expect('never edited: a term of a contract can''t be updated',false,'the update went through');
  EXCEPTION WHEN others THEN PERFORM t.expect('never edited: a term of a contract can''t be updated',true,SQLERRM); END;
  BEGIN UPDATE public.schedule_lines SET principal=principal+1 WHERE contract_id=t.id('c1') AND seq=1;
        PERFORM t.expect('never edited: a schedule line can''t be updated',false,'the update went through');
  EXCEPTION WHEN others THEN PERFORM t.expect('never edited: a schedule line can''t be updated',true,SQLERRM); END;
END $$;
SELECT t.expect('ledgers: every contract''s lines add up; every sale is settled; cash balances equal their ledgers',
  NOT EXISTS (SELECT 1 FROM public.contracts c WHERE c.organization_id=t.org('a')
              AND c.total_payable<>(SELECT sum(amount) FROM public.schedule_lines l WHERE l.contract_id=c.id AND l.version=1))
  AND NOT EXISTS (SELECT 1 FROM public.v_sale_balances b WHERE b.organization_id=t.org('a') AND b.unpaid<>0)
  AND NOT EXISTS (SELECT 1 FROM public.cash_accounts a LEFT JOIN public.cash_balances b ON b.cash_account_id=a.id
                  WHERE a.organization_id=t.org('a') AND COALESCE(b.balance,0)<>COALESCE((SELECT sum(amount) FROM public.cash_movements m WHERE m.cash_account_id=a.id),0)));

-- ================================================================ read
SELECT t.as_user('a0770000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('read: the cashier (a customer read key, the branch) reads the contract',
  (SELECT x->>'id'=t.id('c1')::text AND jsonb_array_length(x->'lines')=12 AND x->'lines'->0->>'status' IS NOT NULL
     AND x->'customer'->>'name'='Good Customer' AND x->>'sale_number' IS NOT NULL FROM public.get_contract(t.id('c1')) x));
SELECT t.error('read: an unknown id -> CONTRACT_NOT_FOUND',format('SELECT public.get_contract(%L)',gen_random_uuid()),'CONTRACT_NOT_FOUND');
RESET ROLE;
-- N03 (D78): the collection keys see every branch's contracts, so this cashier loses collection.create.
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),t.id('cashier2'),'collection.create',false);
SELECT t.as_user('a0770000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.error('read: a cashier of another branch (no collection key) -> CONTRACT_NOT_FOUND',format('SELECT public.get_contract(%L)',t.id('c1')),'CONTRACT_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0770000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('read: a warehouse user (no customer read key) -> PERMISSION_DENIED',format('SELECT public.get_contract(%L)',t.id('c1')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0770000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('read: shop B asking for shop A''s contract -> CONTRACT_NOT_FOUND',format('SELECT public.get_contract(%L)',t.id('c1')),'CONTRACT_NOT_FOUND');
RESET ROLE;
UPDATE public.organizations SET subscription_start=NULL, subscription_end=app.org_today(id)-1 WHERE id=t.org('a');
SELECT t.as_user('a0770000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('read: an expired shop can still read a contract',(public.get_contract(t.id('c1'))->>'id')=t.id('c1')::text);
RESET ROLE;

-- ================================================================ grants
SELECT t.expect('grants: the helpers are not executable by authenticated; the two public functions are',
  NOT has_function_privilege('authenticated','app.post_sale_core(uuid,uuid,public.shifts,jsonb,uuid,numeric,text,jsonb,jsonb,text,uuid,numeric)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.installment_sale_input(jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.contract_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.installment_sale_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_installment_sale(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.post_installment_sale(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_contract(uuid)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
