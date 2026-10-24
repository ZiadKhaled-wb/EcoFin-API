-- K04 day close and reconciliation (EC-62, D84).
-- Run by: node scripts/db-smoke.mjs supabase/tests/k04_day_close_test.sql (inside BEGIN ... ROLLBACK).
-- The day-close numbers equal the sum of the day's documents (each total is computed again here,
-- straight from the tables); a broken cached balance and a document without its ledger row are
-- flagged; an open shift blocks the close; a closed day refuses new entries for its branch only;
-- the owner reopens with a reason and a second close stores a new snapshot; the nightly check
-- stores what it found and never changes a day.
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
  RETURN public.open_shift(p_branch, p_float, p_key,
    (SELECT b.default_cash_account_id FROM public.branches b WHERE b.id = p_branch), NULL);
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
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
CREATE FUNCTION t.pv() RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT (app.current_installment_policy(t.org('a'))).version $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q) $$;
CREATE FUNCTION t.pcash(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method','cash','amount',amount) $$;
CREATE FUNCTION t.pbank(amount text,acct text,ref text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('method','bank_transfer','amount',amount,'cash_account_id',t.id(acct),'reference',ref) $$;
CREATE FUNCTION t.bal(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
-- The preview / close as SQL text, for t.error.
CREATE FUNCTION t.q_preview(b text,d date) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.get_day_close_preview(%L,%L)',t.id(b),d) $$;
CREATE FUNCTION t.q_close(b text,d date,h text,note text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.close_day(%L,%L,%L,%L)',t.id(b),d,h,note) $$;
CREATE FUNCTION t.preview(b text) RETURNS jsonb LANGUAGE sql AS $$ SELECT public.get_day_close_preview(t.id(b),t.today()) $$;
-- An account's row in a preview or snapshot.
CREATE FUNCTION t.acc(j jsonb,a text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(j->'totals'->'cash'->'accounts') x WHERE x->'account'->>'id'=t.id(a)::text $$;
CREATE FUNCTION t.codes(j jsonb,sev text DEFAULT NULL) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(DISTINCT x->>'code' ORDER BY x->>'code'),'{}') FROM jsonb_array_elements(j->'issues') x
  WHERE sev IS NULL OR x->>'severity'=sev $$;
CREATE FUNCTION t.audits(a text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action=a $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (two branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('K04 '||s,'k04-key-'||s,'retail_pro','Owner',s||'k04@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('k',64)),('b',repeat('m',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a0400000-0000-0000-8000-000000000001','ak04@example.com'),('a0400000-0000-0000-8000-000000000002','bk04@example.com'),
  ('a0400000-0000-0000-8000-000000000003','k04manager@example.com'),('a0400000-0000-0000-8000-000000000004','k04accountant@example.com'),
  ('a0400000-0000-0000-8000-000000000005','k04cashier@example.com');
SELECT public.accept_invite(repeat('k',64),'a0400000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('m',64),'a0400000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main-b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0 WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id=t.org('a');
SELECT t.as_user('a0400000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids SELECT 'cib',(public.create_cash_account('CIB','bank',t.id('main'))->>'id')::uuid;
INSERT INTO t.ids SELECT 'nbe',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"K4-CH","cash_price":"100"}'));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"K4-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',50),jsonb_build_object('product_id',t.id('tv'),'quantity',5)),'k04-key-found');
INSERT INTO t.ids SELECT 'rent',(public.create_expense_category('Rent')->>'id')::uuid;
INSERT INTO t.ids SELECT 'transport',(public.create_expense_category('Transport')->>'id')::uuid;
RESET ROLE;
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('manager','a0400000-0000-0000-8000-000000000003','K04 Manager','BRANCH_MANAGER');
SELECT t.emp('accountant','a0400000-0000-0000-8000-000000000004','K04 Accountant','ACCOUNTANT');
SELECT t.emp('cashier','a0400000-0000-0000-8000-000000000005','K04 Cashier','CASHIER');
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id,city,address)
  VALUES(t.org('a'),'K04 Customer',ARRAY['01055550001'],500000,'active','29101010100501','Cairo','5 B Street');
INSERT INTO t.ids SELECT 'c1',id FROM public.customers WHERE organization_id=t.org('a') AND full_name='K04 Customer';
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'percent_of_future_profit',50,
         1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');
CREATE FUNCTION t.u(n text) RETURNS text LANGUAGE sql AS $$ SELECT CASE n
  WHEN 'owner' THEN 'a0400000-0000-0000-8000-000000000001' WHEN 'owner-b' THEN 'a0400000-0000-0000-8000-000000000002'
  WHEN 'manager' THEN 'a0400000-0000-0000-8000-000000000003' WHEN 'accountant' THEN 'a0400000-0000-0000-8000-000000000004'
  WHEN 'cashier' THEN 'a0400000-0000-0000-8000-000000000005' END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- the day in the main branch
-- Opening 10000 in the safe; a shift with a 500 float; three sales (cash, cash + bank, a shop-wide
-- bank); an installment sale (2000 down in cash); a 1000 collection; an expense from the safe and
-- one from the shift; the safe expense reversed; 1000 from the safe to the bank; the bank sale voided.
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT public.post_cash_opening(t.id('safe'),'10000.00','Opening','k04-key-opening');
SELECT public.post_cash_opening(t.id('safe2'),'800.00','Opening','k04-key-opening2');
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'500.00','k04-key-shift');
RESET ROLE;
INSERT INTO t.ids SELECT 'shift',(t.doc('shift')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=t.id('shift');
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's1',public.post_sale(t.lines(t.items('chair',3)),'300.00','k04-key-s1',NULL,t.lines(t.pcash('300.00')));
INSERT INTO t.docs SELECT 's2',public.post_sale(t.lines(t.items('chair',5)),'500.00','k04-key-s2',NULL,t.lines(t.pcash('200.00'),t.pbank('300.00','cib','TRX-1')));
INSERT INTO t.docs SELECT 's3',public.post_sale(t.lines(t.items('chair',1)),'100.00','k04-key-s3',NULL,t.lines(t.pbank('100.00','nbe','TRX-2')));
INSERT INTO t.docs SELECT 'inst',public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),
    'expected_total','12000.00','customer_id',t.id('c1'),
    'terms',jsonb_build_object('down_payment','2000.00','installments_count',12,'frequency','monthly','policy_version',t.pv())),'k04-key-inst');
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO t.docs SELECT 'col',public.post_collection(jsonb_build_object('customer_id',t.id('c1'),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',(t.doc('inst')->'contract'->>'id')::uuid,'amount','1000.00')),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','1000.00'))),'k04-key-col');
INSERT INTO t.docs SELECT 'e1',public.post_expense(t.id('rent'),'150.00','k04-key-e1',t.id('main'),t.id('safe'),false,'Rent',NULL);
INSERT INTO t.docs SELECT 'e2',public.post_expense(t.id('transport'),'50.00','k04-key-e2',t.id('main'),NULL,true,'Taxi',NULL);
INSERT INTO t.docs SELECT 'e1r',public.reverse_expense((t.doc('e1')->>'id')::uuid,'Paid twice by mistake','k04-key-e1r',NULL);
INSERT INTO t.docs SELECT 'tr',public.create_cash_transfer(t.id('safe'),t.id('cib'),'1000.00','To the bank','k04-key-tr');
INSERT INTO t.docs SELECT 'void',public.void_sale((t.doc('s3')->>'id')::uuid,'Customer changed mind','k04-key-void');
-- The second branch: a 70 expense from its own safe (never in the main branch's numbers).
SELECT public.post_expense(t.id('transport'),'70.00','k04-key-e3',t.id('second'),t.id('safe2'),false,'Taxi',NULL);
RESET ROLE;

-- ================================================================ an open shift blocks the close
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p-open',t.preview('main');
SELECT t.error_detail('close: an open shift is DAY_CLOSE_BLOCKED with the SHIFT_OPEN issue',
  t.q_close('main',t.today(),(t.doc('p-open')->>'hash'),'note'),'DAY_CLOSE_BLOCKED',
  jsonb_build_object('issues',jsonb_build_array(jsonb_build_object('code','SHIFT_OPEN','severity','blocking',
    'link',jsonb_build_object('kind','shift','id',t.id('shift'))))));
RESET ROLE;
SELECT t.expect('preview: an open day of today, with the open shift linked',
  t.doc('p-open')->>'status'='open' AND (t.doc('p-open')->>'is_today')::boolean
  AND 'SHIFT_OPEN'=ANY(t.codes(t.doc('p-open'),'blocking')) AND t.doc('p-open')->>'hash' ~ '^[0-9a-f]{32}$',
  t.doc('p-open')::text);

-- The cashier side: count 3940 against an expected 3950 (500 + 300 + 200 + 2000 + 1000 - 50).
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'closed-shift',public.close_shift(t.id('shift'),'{"1":3940}',t.id('safe'),'Ten pounds short');
RESET ROLE;

-- ================================================================ the numbers equal the documents
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p',t.preview('main');
RESET ROLE;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p2',t.preview('second');
RESET ROLE;
SELECT t.expect('totals: sales count, total, tax and discount = the day''s sales rows without the voided one (D94)',
  (t.doc('p')#>>'{totals,sales,count}')::int=(SELECT count(*) FROM public.sales x WHERE branch_id=t.id('main') AND business_date=t.today()
       AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=x.id AND r.kind='void'))
  AND (t.doc('p')#>>'{totals,sales,total}')::numeric=(SELECT sum(total) FROM public.sales x WHERE branch_id=t.id('main') AND business_date=t.today()
       AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=x.id AND r.kind='void'))
  AND (t.doc('p')#>>'{totals,sales,tax_total}')::numeric=(SELECT sum(tax_total) FROM public.sales x WHERE branch_id=t.id('main') AND business_date=t.today()
       AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=x.id AND r.kind='void'))
  AND (t.doc('p')#>>'{totals,sales,count}')::int=3 AND (t.doc('p')#>>'{totals,sales,total}')::numeric=12800,
  t.doc('p')#>>'{totals,sales}');
SELECT t.expect('totals: paid by method = the counted sales'' payments (cash 300 + 200 + 2000 down, bank 300; the voided 100 out)',
  (t.doc('p')#>>'{totals,sales,paid_by_method,cash}')::numeric=2500
  AND (t.doc('p')#>>'{totals,sales,paid_by_method,bank_transfer}')::numeric=300
  AND (t.doc('p')#>>'{totals,sales,paid_by_method,store_credit}')::numeric=0
  AND (t.doc('p')#>>'{totals,sales,on_contract}')::numeric=(SELECT financed_amount FROM public.contracts WHERE id=(t.doc('inst')->'contract'->>'id')::uuid)
  AND (t.doc('p')#>>'{totals,sales,voided,count}')::int=1 AND (t.doc('p')#>>'{totals,sales,voided,total}')::numeric=100,
  t.doc('p')#>>'{totals,sales}');
SELECT t.expect('totals: collections = the collection rows (principal + profit = total)',
  (t.doc('p')#>>'{totals,collections,count}')::int=1 AND (t.doc('p')#>>'{totals,collections,total}')::numeric=1000
  AND (t.doc('p')#>>'{totals,collections,principal}')::numeric+(t.doc('p')#>>'{totals,collections,profit}')::numeric=1000
  AND (t.doc('p')#>>'{totals,collections,by_method,cash}')::numeric=1000
  AND (t.doc('p')#>>'{totals,collections,in_field}')::numeric=0,
  t.doc('p')#>>'{totals,collections}');
SELECT t.expect('totals: expenses 150 + 50 by category, the reversal apart; the other branch''s 70 is not here',
  (t.doc('p')#>>'{totals,expenses,count}')::int=2 AND (t.doc('p')#>>'{totals,expenses,total}')::numeric=200
  AND (t.doc('p')#>>'{totals,expenses,reversed,count}')::int=1 AND (t.doc('p')#>>'{totals,expenses,reversed,total}')::numeric=150
  AND jsonb_array_length(t.doc('p')#>'{totals,expenses,by_category}')=2
  AND (t.doc('p2')#>>'{totals,expenses,total}')::numeric=70 AND (t.doc('p2')#>>'{totals,sales,count}')::int=0,
  t.doc('p')#>>'{totals,expenses}');
SELECT t.expect('cash: the safe 0 -> 12440 (in 10000 + 150 + 3940, out 500 + 150 + 1000) equals its cached balance',
  (t.acc(t.doc('p'),'safe')->>'opening')::numeric=0
  AND (t.acc(t.doc('p'),'safe')->>'in')::numeric=14090 AND (t.acc(t.doc('p'),'safe')->>'out')::numeric=1650
  AND (t.acc(t.doc('p'),'safe')->>'closing')::numeric=12440 AND t.bal('safe')=12440
  AND (t.acc(t.doc('p'),'drawer')->>'closing')::numeric=0 AND t.bal('drawer')=0
  AND (t.acc(t.doc('p'),'cib')->>'closing')::numeric=1300 AND t.bal('cib')=1300,
  t.doc('p')#>>'{totals,cash}');
SELECT t.expect('cash: every account''s closing - opening = in - out; total closing cash = safes + drawers',
  (SELECT bool_and(x->>'opening' IS NULL OR
         (x->>'closing')::numeric-(x->>'opening')::numeric=(x->>'in')::numeric-(x->>'out')::numeric)
   FROM jsonb_array_elements(t.doc('p')#>'{totals,cash,accounts}') x)
  AND (t.doc('p')#>>'{totals,cash,total_closing_cash}')::numeric=12440,
  t.doc('p')#>>'{totals,cash}');
SELECT t.expect('cash: a shop-wide bank shows only this branch''s movements, without opening or closing',
  (t.acc(t.doc('p'),'nbe')->>'in')::numeric=100 AND (t.acc(t.doc('p'),'nbe')->>'out')::numeric=100
  AND t.acc(t.doc('p'),'nbe')->'opening'='null'::jsonb AND t.acc(t.doc('p'),'nbe')->'closing'='null'::jsonb
  AND (t.acc(t.doc('p'),'nbe')->'account'->>'shop_wide')::boolean
  AND t.acc(t.doc('p2'),'nbe') IS NULL AND t.acc(t.doc('p2'),'safe') IS NULL
  AND (t.acc(t.doc('p2'),'safe2')->>'closing')::numeric=730,
  t.doc('p')#>>'{totals,cash}');
SELECT t.expect('cash: by type adds up the day''s movements of the safe',
  (SELECT sum(v::numeric) FROM jsonb_each_text(t.acc(t.doc('p'),'safe')->'by_type') e(k,v))=12440
  AND (t.acc(t.doc('p'),'safe')->'by_type'->>'opening')::numeric=10000,
  t.acc(t.doc('p'),'safe')::text);
SELECT t.expect('shifts: the closed shift with expected 3950, counted 3940, difference -10 and its reason',
  jsonb_array_length(t.doc('p')#>'{totals,shifts,items}')=1
  AND (t.doc('p')#>>'{totals,shifts,items,0,expected}')::numeric=3950
  AND (t.doc('p')#>>'{totals,shifts,items,0,counted}')::numeric=3940
  AND (t.doc('p')#>>'{totals,shifts,items,0,difference}')::numeric=-10
  AND t.doc('p')#>>'{totals,shifts,items,0,difference_reason}'='Ten pounds short'
  AND (t.doc('p')#>>'{totals,shifts,difference_total}')::numeric=-10
  AND (t.doc('p')#>>'{totals,shifts,items,0,payment_totals,cash}')::numeric=2500
  AND (t.doc('p')#>>'{totals,shifts,items,0,collections,cash}')::numeric=1000
  AND (t.doc('p')#>>'{totals,shifts,items,0,sales_total}')::numeric=12800
  AND (t.doc('p')#>>'{totals,shifts,items,0,sales_count}')::int=3,
  t.doc('p')#>>'{totals,shifts}');
SELECT t.expect('issues: a normal day has no ledger or document problem; the shift difference is info',
  NOT ('DOCUMENT_WITHOUT_LEDGER'=ANY(t.codes(t.doc('p')))) AND NOT ('LEDGER_MISMATCH'=ANY(t.codes(t.doc('p'))))
  AND NOT ('SHIFT_OPEN'=ANY(t.codes(t.doc('p'))))
  AND 'SHIFT_DIFFERENCE'=ANY(t.codes(t.doc('p'),'info'))
  AND (SELECT x->'link'->>'id'=t.id('shift')::text FROM jsonb_array_elements(t.doc('p')->'issues') x WHERE x->>'code'='SHIFT_DIFFERENCE'),
  (t.doc('p')->'issues')::text);
SELECT t.expect('eta: the shop has the eta module, so the day has an ETA summary',
  jsonb_typeof(t.doc('p')#>'{totals,eta}')='object', t.doc('p')#>>'{totals,eta}');

-- ================================================================ a broken balance and a missing ledger row are flagged
-- The frozen-balance trigger and the ledger triggers are bypassed on purpose, then put back.
SET session_replication_role = replica;
UPDATE public.cash_balances SET balance=balance+5 WHERE cash_account_id=t.id('cib');
INSERT INTO public.expenses(organization_id,number,branch_id,category_id,amount,cash_account_id,business_date,idempotency_key,created_by)
  VALUES(t.org('a'),'K04-FAKE-1',t.id('main'),t.id('rent'),33,t.id('safe'),t.today(),'k04-key-fake-expense',t.id('manager'));
SET session_replication_role = origin;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p-bad',t.preview('main');
SELECT t.error('close: warnings without a note are NOTE_REQUIRED',t.q_close('main',t.today(),t.doc('p-bad')->>'hash',NULL),'NOTE_REQUIRED');
SELECT t.error('close: a note of 2 characters is NOTE_REQUIRED',t.q_close('main',t.today(),t.doc('p-bad')->>'hash','ab'),'NOTE_REQUIRED');
RESET ROLE;
SELECT t.expect('issues: the broken bank balance is LEDGER_MISMATCH linked to the account',
  (SELECT bool_or(x->>'code'='LEDGER_MISMATCH' AND x->>'severity'='warning' AND x->'link'->>'kind'='cash_account'
                  AND x->'link'->>'id'=t.id('cib')::text AND (x->'params'->>'cached')::numeric-(x->'params'->>'from_ledger')::numeric=5)
   FROM jsonb_array_elements(t.doc('p-bad')->'issues') x),
  (t.doc('p-bad')->'issues')::text);
SELECT t.expect('issues: the expense without its cash movement is DOCUMENT_WITHOUT_LEDGER linked to it',
  (SELECT bool_or(x->>'code'='DOCUMENT_WITHOUT_LEDGER' AND x->'link'->>'kind'='expense' AND x->'params'->>'number'='K04-FAKE-1'
                  AND (x->'params'->>'document_amount')::numeric=-33 AND (x->'params'->>'ledger_amount')::numeric=0)
   FROM jsonb_array_elements(t.doc('p-bad')->'issues') x)
  AND t.doc('p-bad')->>'hash'<>t.doc('p')->>'hash',
  (t.doc('p-bad')->'issues')::text);
-- Put both back.
SET session_replication_role = replica;
UPDATE public.cash_balances SET balance=balance-5 WHERE cash_account_id=t.id('cib');
DELETE FROM public.expenses WHERE number='K04-FAKE-1' AND organization_id=t.org('a');
SET session_replication_role = origin;

-- ================================================================ the close
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('read: a cashier (no day.close, no cash.view) is PERMISSION_DENIED',t.q_preview('main',t.today()),'PERMISSION_DENIED');
SELECT t.error('close: a cashier is PERMISSION_DENIED',t.q_close('main',t.today(),t.doc('p')->>'hash','note'),'PERMISSION_DENIED');
SELECT t.error('list: a cashier is PERMISSION_DENIED','SELECT public.list_day_closes()','PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('read: a branch the manager doesn''t work in is BRANCH_DENIED',t.q_preview('second',t.today()),'BRANCH_DENIED');
SELECT t.error('read: tomorrow is FUTURE_BUSINESS_DATE',t.q_preview('main',t.today()+1),'FUTURE_BUSINESS_DATE');
SELECT t.error('read: another shop''s branch is BRANCH_NOT_FOUND',t.q_preview('main-b',t.today()),'BRANCH_NOT_FOUND');
SELECT t.error('close: a bad hash is VALIDATION_FAILED',t.q_close('main',t.today(),'not-a-hash','note'),'VALIDATION_FAILED');
SELECT t.error('close: a note over 500 characters is VALIDATION_FAILED',t.q_close('main',t.today(),t.doc('p')->>'hash',repeat('x',501)),'VALIDATION_FAILED');
-- Something posted after the preview: the hash no longer matches.
SELECT public.post_expense(t.id('rent'),'10.00','k04-key-e4',t.id('main'),t.id('safe'),false,'Water',NULL);
SELECT t.error('close: an expense posted after the preview is DAY_CHANGED',t.q_close('main',t.today(),t.doc('p')->>'hash','note'),'DAY_CHANGED');
INSERT INTO t.docs SELECT 'p-final',t.preview('main');
RESET ROLE;
-- The accountant closes (day.close by role, the main branch only).
SELECT t.as_user(t.u('accountant'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'close',public.close_day(t.id('main'),t.today(),t.doc('p-final')->>'hash',
  CASE WHEN cardinality(t.codes(t.doc('p-final'),'warning'))>0 THEN 'ETA receipts still waiting' END);
RESET ROLE;
SELECT t.expect('close: the snapshot is the preview''s numbers, closed by the accountant',
  t.doc('close')->>'status'='closed' AND t.doc('close')->'totals'=t.doc('p-final')->'totals'
  AND t.doc('close')->'issues'=t.doc('p-final')->'issues' AND t.doc('close')->'closed_by'->>'id'=t.id('accountant')::text
  AND NOT (t.doc('close')->>'drift')::boolean AND (t.doc('close')#>>'{totals,expenses,total}')::numeric=210
  AND (SELECT status='closed' FROM public.day_closes WHERE id=(t.doc('close')->>'id')::uuid),
  t.doc('close')::text);
SELECT t.expect('close: audited once as day.closed with the hash',
  t.audits('day.closed')=1
  AND (SELECT "after"->>'hash'=t.doc('p-final')->>'hash' FROM public.audit_log WHERE organization_id=t.org('a') AND action='day.closed'));
INSERT INTO t.ids SELECT 'dc',(t.doc('close')->>'id')::uuid;

-- ================================================================ a closed day refuses new entries (its branch only)
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('closed: an expense is DAY_CLOSED',
  format('SELECT public.post_expense(%L,%L,%L,%L,%L,false,NULL,NULL)',t.id('rent'),'5.00','k04-key-x1',t.id('main'),t.id('safe')),'DAY_CLOSED');
SELECT t.error('closed: a transfer is DAY_CLOSED',
  format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('safe'),t.id('cib'),'5.00','k04-key-x2'),'DAY_CLOSED');
SELECT t.error('closed: opening a shift (its float) is DAY_CLOSED',
  format('SELECT t.open_shift(%L,%L,%L)',t.id('main'),'100.00','k04-key-x3'),'DAY_CLOSED');
SELECT t.error('closed: a stock adjustment is DAY_CLOSED',
  format('SELECT public.post_stock_adjustment(%L,%L,NULL,%L,%L)',t.id('main'),'found',
    jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',1)),'k04-key-x4'),'DAY_CLOSED');
SELECT public.post_expense(t.id('rent'),'5.00','k04-key-x5',t.id('second'),t.id('safe2'),false,NULL,NULL);
RESET ROLE;
SELECT t.expect('closed: the other branch still posts',
  (SELECT count(*)=2 FROM public.expenses WHERE branch_id=t.id('second')));
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('closed: closing again is DAY_ALREADY_CLOSED with the id',
  t.q_close('main',t.today(),t.doc('p-final')->>'hash','note'),'DAY_ALREADY_CLOSED',jsonb_build_object('id',t.id('dc')));
SELECT t.error_detail('closed: the preview is DAY_ALREADY_CLOSED with the id',
  t.q_preview('main',t.today()),'DAY_ALREADY_CLOSED',jsonb_build_object('id',t.id('dc')));
INSERT INTO t.docs SELECT 'get',public.get_day_close(t.id('dc'));
INSERT INTO t.docs SELECT 'list',public.list_day_closes(NULL,t.today()-3,t.today(),NULL);
INSERT INTO t.docs SELECT 'list-closed',public.list_day_closes(t.id('main'),NULL,NULL,'closed');
INSERT INTO t.docs SELECT 'alerts',public.day_close_alerts();
SELECT t.error('list: more than 92 days is VALIDATION_FAILED',format('SELECT public.list_day_closes(NULL,%L,%L)',t.today()-100,t.today()),'VALIDATION_FAILED');
SELECT t.error('list: an unknown status is VALIDATION_FAILED',format('SELECT public.list_day_closes(NULL,NULL,NULL,%L)','done'),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('get: the stored close without drift',
  t.doc('get')->>'id'=t.id('dc')::text AND NOT (t.doc('get')->>'drift')::boolean AND t.doc('get')->'totals'=t.doc('close')->'totals',
  t.doc('get')::text);
SELECT t.expect('list: today''s main day is closed with its sales total; the manager sees only the main branch',
  (SELECT bool_and(x->>'branch_id'=t.id('main')::text) FROM jsonb_array_elements(t.doc('list')->'items') x)
  AND (SELECT count(*)=1 FROM jsonb_array_elements(t.doc('list')->'items') x
       WHERE x->>'status'='closed' AND x->>'id'=t.id('dc')::text
         AND x->>'sales_total'=t.doc('close')#>>'{totals,sales,total}' AND (x->>'sales_total')::numeric=12800)
  AND jsonb_array_length(t.doc('list-closed')->'items')=1,
  t.doc('list')::text);
SELECT t.expect('alerts: an answer with a branches list (today is never an unclosed day)',
  jsonb_typeof(t.doc('alerts')->'branches')='array', t.doc('alerts')::text);
-- Another shop.
SELECT t.as_user(t.u('owner-b'),t.org('b'));
SET ROLE authenticated;
SELECT t.error('read: another shop''s day close is NOT_FOUND',format('SELECT public.get_day_close(%L)',t.id('dc')),'NOT_FOUND');
SELECT t.error('reopen: another shop''s day close is NOT_FOUND',format('SELECT public.reopen_day(%L,%L)',t.id('dc'),'Wrong shop'),'NOT_FOUND');
SELECT t.error('close: another shop''s branch is BRANCH_NOT_FOUND',t.q_close('main',t.today(),t.doc('p')->>'hash','note'),'BRANCH_NOT_FOUND');
INSERT INTO t.docs SELECT 'list-b',public.list_day_closes();
RESET ROLE;
SELECT t.expect('list: another shop sees none of shop a''s days',
  NOT EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('list-b')->'items') x WHERE x->>'branch_id' IN (t.id('main')::text,t.id('second')::text)));

-- ================================================================ drift and the nightly check
SELECT t.as_user(NULL);
INSERT INTO t.docs SELECT 'job1',public.jobs_day_check(t.org('a'),t.today()+1);
SELECT t.expect('job: checks the closed day (as of tomorrow) and finds nothing above info; changes no day',
  (t.doc('job1')->>'drift')::int=0
  AND (SELECT NOT drift AND app.day_issue_count(issues)=0 FROM public.day_checks WHERE branch_id=t.id('main') AND business_date=t.today())
  AND (SELECT status='closed' AND totals=(SELECT totals FROM public.day_closes WHERE id=t.id('dc')) FROM public.day_closes WHERE id=t.id('dc'))
  AND t.audits('day.check_failed')=0,
  t.doc('job1')::text);
SET session_replication_role = replica;
UPDATE public.day_closes SET totals=jsonb_set(totals,'{sales,total}','"1.00"') WHERE id=t.id('dc');
SET session_replication_role = origin;
INSERT INTO t.docs SELECT 'job2',public.jobs_day_check(t.org('a'),t.today()+1);
INSERT INTO t.docs SELECT 'job3',public.jobs_day_check(t.org('a'),t.today()+1);
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'get-drift',public.get_day_close(t.id('dc'));
INSERT INTO t.docs SELECT 'alerts-drift',public.day_close_alerts();
RESET ROLE;
SELECT t.expect('drift: a changed snapshot is drift on the read and DAY_DRIFT in the nightly check',
  (t.doc('get-drift')->>'drift')::boolean AND (t.doc('job2')->>'drift')::int=1
  AND (SELECT drift AND issues @> '[{"code":"DAY_DRIFT"}]' FROM public.day_checks WHERE branch_id=t.id('main') AND business_date=t.today()),
  t.doc('job2')::text);
SELECT t.expect('drift: one critical day.check_failed audit, not repeated by a second run the same night',
  t.audits('day.check_failed')=1
  AND (SELECT severity='critical' FROM public.audit_log WHERE organization_id=t.org('a') AND action='day.check_failed')
  AND (t.doc('job3')->>'drift')::int=1);
SELECT t.expect('alerts: the main branch shows its last check with the drift',
  (SELECT (x->'last_check'->>'drift')::boolean AND (x->'last_check'->>'critical')::int>=1
   FROM jsonb_array_elements(t.doc('alerts-drift')->'branches') x WHERE x->>'branch_id'=t.id('main')::text),
  t.doc('alerts-drift')::text);
SET session_replication_role = replica;
UPDATE public.day_closes SET totals=t.doc('close')->'totals' || jsonb_build_object('note',totals->'note') WHERE id=t.id('dc');
SET session_replication_role = origin;
SELECT t.expect('job: a shop is required',
  (SELECT count(*)=0 FROM public.day_checks WHERE organization_id=t.org('b')));
SELECT t.error('job: no shop is VALIDATION_FAILED','SELECT public.jobs_day_check(NULL)','VALIDATION_FAILED');

-- ================================================================ reopen and close again
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('reopen: a manager (no day.reopen) is PERMISSION_DENIED',format('SELECT public.reopen_day(%L,%L)',t.id('dc'),'Late expense'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('reopen: a reason of 2 characters is REASON_REQUIRED',format('SELECT public.reopen_day(%L,%L)',t.id('dc'),'ab'),'REASON_REQUIRED');
INSERT INTO t.docs SELECT 'reopen',public.reopen_day(t.id('dc'),'A late expense receipt');
SELECT t.error('reopen: a reopened day is DAY_NOT_CLOSED',format('SELECT public.reopen_day(%L,%L)',t.id('dc'),'Again please'),'DAY_NOT_CLOSED');
SELECT public.post_expense(t.id('rent'),'20.00','k04-key-late',t.id('main'),t.id('safe'),false,'Late receipt',NULL);
INSERT INTO t.docs SELECT 'p-re',t.preview('main');
INSERT INTO t.docs SELECT 'close2',public.close_day(t.id('main'),t.today(),t.doc('p-re')->>'hash','Closed again after the late receipt');
RESET ROLE;
SELECT t.expect('reopen: reopened with the reason; the preview shows the last close beside the live numbers',
  t.doc('reopen')->>'status'='reopened' AND t.doc('reopen')->>'reopen_reason'='A late expense receipt'
  AND t.doc('p-re')->>'status'='reopened' AND t.doc('p-re')->'last_close'->>'id'=t.id('dc')::text
  AND (t.doc('p-re')#>>'{totals,expenses,total}')::numeric=230,
  t.doc('p-re')::text);
SELECT t.expect('close again: the same row, a new snapshot with the late expense, the reopen fields cleared',
  t.doc('close2')->>'id'=t.id('dc')::text AND t.doc('close2')->>'status'='closed'
  AND (t.doc('close2')#>>'{totals,expenses,total}')::numeric=230 AND t.doc('close2')->>'note'='Closed again after the late receipt'
  AND t.doc('close2')->'reopened_at'='null'::jsonb AND t.doc('close2')->'closed_by'->>'id'=(SELECT id::text FROM public.employees WHERE auth_user_id::text=t.u('owner')),
  t.doc('close2')::text);
SELECT t.expect('audit: day.closed, day.reopened (warning, with the reason), day.closed',
  (SELECT array_agg(action ORDER BY created_at,id)=ARRAY['day.closed','day.reopened','day.closed']
   FROM public.audit_log WHERE organization_id=t.org('a') AND action IN ('day.closed','day.reopened'))
  AND (SELECT severity='warning' AND reason='A late expense receipt' FROM public.audit_log
       WHERE organization_id=t.org('a') AND action='day.reopened'));

-- ================================================================ grants
SELECT t.expect('grants: the six reads and writes are executable by authenticated; the job and the helpers are not',
  has_function_privilege('authenticated','public.get_day_close_preview(uuid,date)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_day_close(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_day_closes(uuid,date,date,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.day_close_alerts()','EXECUTE')
  AND has_function_privilege('authenticated','public.close_day(uuid,date,text,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.reopen_day(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.jobs_day_check(uuid,date)','EXECUTE')
  AND NOT has_function_privilege('anon','public.close_day(uuid,date,text,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.day_close_compute(uuid,uuid,date)','EXECUTE')
  AND NOT has_table_privilege('authenticated','public.day_checks','SELECT')
  AND NOT has_table_privilege('authenticated','public.day_closes','INSERT')
  AND NOT has_table_privilege('authenticated','public.day_closes','UPDATE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
