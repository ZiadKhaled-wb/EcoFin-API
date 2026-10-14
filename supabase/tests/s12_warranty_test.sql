-- S12 real sale, split-payment reversal, search, permissions and replay.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request. t.open_shift pairs a free device of the
-- branch (or the one named) and puts it in the request headers the way the API does once it has
-- resolved a device token: x-device-id with the hash of that token (x-device-token-hash). Then it
-- calls public.open_shift unchanged.
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
  -- Paired, as the pairing screens leave it: the device holds the hash of a token.
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
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text, p_vault uuid DEFAULT NULL, p_device uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(p_branch, p_device);
  RETURN public.open_shift(p_branch, p_float, p_key, p_vault, p_device);
END $$;
GRANT EXECUTE ON FUNCTION t.pos(uuid, uuid), t.open_shift(uuid, text, text, uuid, uuid) TO authenticated;
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
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb = detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
-- (SECURITY DEFINER: the sellers of this test don't read the ledgers, the caches or app.* directly.)
CREATE FUNCTION t.level(p text,b text DEFAULT 'main') RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0)::integer $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.units WHERE serial=s AND organization_id IN (t.org('a'),t.org('b')) $$;
CREATE FUNCTION t.unit_status(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT status::text FROM public.units WHERE id=t.unit(s) $$;
CREATE FUNCTION t.expected(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT app.shift_json(t.org('a'),t.id(s),false)->>'expected_cash' $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
CREATE FUNCTION t.audits(a text,i uuid) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=i $$;
-- Everything a sale writes, counted for shop a: a refused or repeated call must leave it unchanged.
CREATE FUNCTION t.footprint() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',
    (SELECT count(*) FROM public.sales WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.sale_lines WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.stock_movements WHERE organization_id=t.org('a') AND type='sale_out'),
    (SELECT count(*) FROM public.payments WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.payment_allocations WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.cash_movements WHERE organization_id=t.org('a') AND type='sale'),
    (SELECT COALESCE(sum(next_value),0) FROM public.document_counters WHERE organization_id=t.org('a') AND doc_type IN ('sale','payment')),
    (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='sale.created')) $$;
CREATE FUNCTION t.bad_stock() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws('/',p.sku,k.on_hand,k.ledger),', ')
  FROM (SELECT COALESCE(l.product_id,m.product_id) product_id,COALESCE(l.on_hand,0) on_hand,COALESCE(m.ledger,0) ledger
        FROM (SELECT product_id,branch_id,on_hand FROM public.stock_levels WHERE organization_id=t.org('a') AND stock_state='sellable') l
        FULL JOIN (SELECT product_id,branch_id,sum(quantity) ledger FROM public.stock_movements
                   WHERE organization_id=t.org('a') AND stock_state='sellable' GROUP BY 1,2) m
          ON m.product_id=l.product_id AND m.branch_id=l.branch_id) k
  JOIN public.products p ON p.id=k.product_id WHERE k.on_hand<>k.ledger OR k.on_hand<0 $$;
CREATE FUNCTION t.bad_cash() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws('/',a.name,COALESCE(b.balance,0),COALESCE(m.ledger,0)),', ')
  FROM public.cash_accounts a LEFT JOIN public.cash_balances b ON b.cash_account_id=a.id
  LEFT JOIN (SELECT cash_account_id,sum(amount) ledger FROM public.cash_movements WHERE organization_id=t.org('a') GROUP BY 1) m ON m.cash_account_id=a.id
  WHERE a.organization_id=t.org('a') AND (COALESCE(b.balance,0)<>COALESCE(m.ledger,0) OR COALESCE(b.balance,0)<0) $$;
-- Sales' totals, their payments and the drawers' sale movements of shop a: the three must agree.
CREATE FUNCTION t.money() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',
    (SELECT sum(total) FROM public.sales WHERE organization_id=t.org('a')),
    (SELECT sum(a.amount) FROM public.payment_allocations a WHERE a.organization_id=t.org('a') AND a.sale_id IS NOT NULL),
    (SELECT sum(m.amount) FROM public.cash_movements m WHERE m.organization_id=t.org('a') AND m.type='sale')) $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.chairs(q integer,price text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('product_id',t.id('chair'),'quantity',q,'unit_price',price)) $$;
CREATE FUNCTION t.phone(serial text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',t.unit(serial)) $$;
-- A post_sale call as SQL text, for t.error (a fresh key each time).
CREATE FUNCTION t.sell(lines jsonb,expected text,customer text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_sale(%L,%L,%L,%L)',lines,expected,'s12-'||md5(random()::text),t.id(customer)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

\ir helpers/test4_snapshot.sql
-- ---------------------------------------------------------------- setup: shop a (serials, two branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S12 '||s,'s12-'||s,'retail_pro','Owner',s||'s12@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('s',64)),('b',repeat('t',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a7120000-0000-0000-8000-000000000001','as12@example.com'),('a7120000-0000-0000-8000-000000000002','bs12@example.com'),
  ('a7120000-0000-0000-8000-000000000003','s12cashier@example.com'),('a7120000-0000-0000-8000-000000000004','s12cashier2@example.com'),
  ('a7120000-0000-0000-8000-000000000005','s12accountant@example.com'),('a7120000-0000-0000-8000-000000000006','s12warehouse@example.com'),
  ('a7120000-0000-0000-8000-000000000007','s12manager@example.com');
SELECT public.accept_invite(repeat('s',64),'a7120000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('t',64),'a7120000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id=t.org('a');
SELECT t.as_user('a7120000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"S12-CH","cash_price":"250"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"هاتف","sku":"S12-PH","cash_price":"5000","is_serialized":true,"warranty_months":12}'));
INSERT INTO t.ids VALUES('tablet',public.create_product('{"name_ar":"لوحي","sku":"S12-TB","cash_price":"3000","is_serialized":true}'));
INSERT INTO t.ids VALUES('gift',public.create_product('{"name_ar":"هدية","sku":"S12-GF","cash_price":"0"}'));
INSERT INTO t.ids VALUES('old',public.create_product('{"name_ar":"قديم","sku":"S12-OLD","cash_price":"10"}'));
-- Stock through a real purchase: 10 chairs at 100 and 3 phones at 3 000 (costs before VAT).
INSERT INTO t.ids SELECT 'pi',(public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,t.lines(
  jsonb_build_object('product_id',t.id('chair'),'quantity',10,'unit_cost','100.00'),
  jsonb_build_object('product_id',t.id('phone'),'quantity',3,'unit_cost','3000.00','serials',jsonb_build_array('S12-IMEI-1','S12-IMEI-2','S12-IMEI-3'))),
  's12-invoice')->>'id')::uuid;
SELECT public.approve_purchase_invoice(t.id('pi'));
SELECT public.register_units(t.id('tablet'),t.id('main'),'2000.00','["S12-TAB-1"]',NULL,'s12-tablet');
SELECT public.register_units(t.id('phone'),t.id('second'),'2900.00','["S12-IMEI-9"]',NULL,'s12-phone-second');
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',5),
  jsonb_build_object('product_id',t.id('old'),'quantity',5)),'s12-found');
SELECT public.set_product_archived(t.id('old'),true);
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a7120000-0000-0000-8000-000000000003','S12 Cashier','CASHIER');
SELECT t.emp('cashier2','a7120000-0000-0000-8000-000000000004','S12 Cashier Two','CASHIER');
SELECT t.emp('acc','a7120000-0000-0000-8000-000000000005','S12 Accountant','ACCOUNTANT');
SELECT t.emp('wh','a7120000-0000-0000-8000-000000000006','S12 Warehouse','WAREHOUSE');
SELECT t.emp('mgr','a7120000-0000-0000-8000-000000000007','S12 Manager','BRANCH_MANAGER');
INSERT INTO public.customers(id,organization_id,full_name) VALUES
  ('a7120000-0000-0000-8000-0000000000c1',t.org('a'),'Mona Buyer'),('a7120000-0000-0000-8000-0000000000c2',t.org('a'),'Gone Buyer'),
  ('a7120000-0000-0000-8000-0000000000c3',t.org('b'),'Shop B Buyer');
UPDATE public.customers SET archived_at=now() WHERE id='a7120000-0000-0000-8000-0000000000c2';
INSERT INTO t.ids VALUES('mona','a7120000-0000-0000-8000-0000000000c1'),('gone','a7120000-0000-0000-8000-0000000000c2'),('buyer_b','a7120000-0000-0000-8000-0000000000c3');
-- Shop b: a product and a unit of its own.
SELECT t.as_user('a7120000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('chair_b',public.create_product('{"name_ar":"كرسي ب","sku":"S12B-CH","cash_price":"250"}'));
RESET ROLE;
SELECT t.expect('setup: 10 chairs and 3 phones in main, costs 100 and 3 000',
  t.level('chair')=10 AND t.level('phone')=3 AND (SELECT avg_cost FROM public.products WHERE id=t.id('chair'))=100,
  concat_ws(' ',t.level('chair'),t.level('phone')));


SELECT t.as_user('a7120000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('S12 Bank','bank',NULL)->>'id')::uuid;
RESET ROLE;
UPDATE public.customers SET phones=ARRAY['01012345678'] WHERE id=t.id('mona');
SELECT t.as_user('a7120000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'0','s12-shift')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=t.id('shift');
INSERT INTO t.docs SELECT 'sale',public.post_sale(t.lines(t.chairs(2),t.phone('S12-IMEI-1')),'5500.00','s12-main-sale',t.id('mona'),jsonb_build_array(jsonb_build_object('method','cash','amount','2750.00'),jsonb_build_object('method','bank_transfer','amount','2750.00','cash_account_id',t.id('bank'),'reference','S12 transfer')));
RESET ROLE;
INSERT INTO t.ids SELECT 'sale',(t.doc('sale')->>'id')::uuid;
CREATE TABLE t.original AS SELECT to_jsonb(s) j FROM public.sales s WHERE id=t.id('sale');
GRANT SELECT ON t.original TO authenticated;

INSERT INTO t.ids SELECT 'line',id FROM public.sale_lines WHERE sale_id=t.id('sale') AND unit_id IS NOT NULL;
INSERT INTO t.ids SELECT 'chairline',id FROM public.sale_lines WHERE sale_id=t.id('sale') AND unit_id IS NULL;
SELECT t.expect('new sales normalize the non-NULL S03 date', (SELECT warranty_until FROM public.sale_lines WHERE id=t.id('line'))=(t.today()+interval '12 months'-interval '1 day')::date);
SELECT t.expect('zero month products have no warranty',(SELECT warranty_until IS NULL FROM public.sale_lines WHERE id=t.id('chairline')));
-- A real issued sale fixture dated 12 October, then a missing legacy warranty date.
ALTER TABLE public.sales DISABLE TRIGGER trg_sales_append_only;
UPDATE public.sales SET business_date='2026-10-12' WHERE id=t.id('sale');
ALTER TABLE public.sales ENABLE TRIGGER trg_sales_append_only;
ALTER TABLE public.sale_lines DISABLE TRIGGER trg_sale_lines_append_only;
UPDATE public.sale_lines SET warranty_until=NULL WHERE id=t.id('line');
ALTER TABLE public.sale_lines ENABLE TRIGGER trg_sale_lines_append_only;
SELECT app.backfill_sale_warranties();
SELECT t.expect('backfill: twelve months sold October 12 ends October 11',(SELECT warranty_until='2027-10-11' FROM public.sale_lines WHERE id=t.id('line')));
SELECT app.backfill_sale_warranties();
SELECT t.expect('backfill preserves populated dates',(SELECT warranty_until='2027-10-11' FROM public.sale_lines WHERE id=t.id('line')));
ALTER TABLE public.sale_lines DISABLE TRIGGER trg_sale_lines_append_only;
UPDATE public.sale_lines SET warranty_until='2027-10-12' WHERE id=t.id('line');
ALTER TABLE public.sale_lines ENABLE TRIGGER trg_sale_lines_append_only;
SELECT app.backfill_sale_warranties();
SELECT t.expect('populated legacy S03 warranty is preserved',(SELECT warranty_until='2027-10-12' FROM public.sale_lines WHERE id=t.id('line')));
ALTER TABLE public.sale_lines DISABLE TRIGGER trg_sale_lines_append_only;
UPDATE public.sale_lines SET warranty_until='2027-10-11' WHERE id=t.id('line');
ALTER TABLE public.sale_lines ENABLE TRIGGER trg_sale_lines_append_only;
CREATE TABLE t.sale_before AS SELECT to_jsonb(s) j FROM public.sales s WHERE id=t.id('sale');
SELECT t.as_user('a7120000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('lookup exactly one key','SELECT public.warranty_lookup()','LOOKUP_ONE_KEY');
SELECT t.error('lookup refuses multiple keys','SELECT public.warranty_lookup(''A'',''010'',NULL)','LOOKUP_ONE_KEY');
SELECT t.expect('lookup serial has original warranty',(public.warranty_lookup('S12-IMEI-1')->'items'->0->>'warranty_until')='2027-10-11');
SELECT t.expect('lookup receipt returns both sale lines',jsonb_array_length(public.warranty_lookup(NULL,NULL,t.doc('sale')->>'number')->'items')=2);
SELECT t.expect('lookup customer phone exact normalized',jsonb_array_length(public.warranty_lookup(NULL,'+20 1012345678',NULL)->'items')=2);
SELECT t.expect('unknown serial empty',public.warranty_lookup('UNKNOWN')->'items'='[]'::jsonb);
INSERT INTO t.docs SELECT 'claimA',public.open_warranty_claim(t.id('line'),t.unit('S12-IMEI-1'),'Screen failed','Scratched case','s12-claim-a');
SELECT t.expect('open claim in warranty',NOT (t.doc('claimA')->>'out_of_warranty')::boolean);
INSERT INTO t.docs SELECT 'test4-replay-before',t.snapshot(t.org('a'));
SELECT t.expect('open same key replay',public.open_warranty_claim(t.id('line'),t.unit('S12-IMEI-1'),'Screen failed','Scratched case','s12-claim-a')=t.doc('claimA'));
SELECT t.expect('TEST4 warranty replay leaves all rows, balances and counters unchanged',t.snapshot(t.org('a'))=t.doc('test4-replay-before'));
SELECT t.unchanged('key conflict',format('SELECT public.open_warranty_claim(%L,%L,%L,%L,%L)',t.id('line'),t.unit('S12-IMEI-1'),'Other issue','Scratched case','s12-claim-a'),'IDEMPOTENCY_CONFLICT');
SELECT t.error('second active claim',format('SELECT public.open_warranty_claim(%L,%L,%L,%L,%L)',t.id('line'),t.unit('S12-IMEI-1'),'Failed twice','Scratched','s12-claim-dup'),'CLAIM_ALREADY_OPEN');
SELECT t.error('wrong sold unit',format('SELECT public.open_warranty_claim(%L,%L,%L,%L,%L)',t.id('line'),t.unit('S12-TAB-1'),'Failed','Scratched','s12-claim-bad'),'CLAIM_UNIT_MISMATCH');
SELECT t.error('serialized unit required',format('SELECT public.open_warranty_claim(%L,NULL,%L,%L,%L)',t.id('line'),'Failed','Scratched','s12-claim-null'),'CLAIM_UNIT_MISMATCH');
SELECT t.error('bad issue',format('SELECT public.open_warranty_claim(%L,NULL,%L,%L,%L)',t.id('chairline'),'ab','Scratched','s12-issue-bad'),'VALIDATION_FAILED');
SELECT t.error('open cannot close',format('SELECT public.move_warranty_claim(%L,''closed'',NULL)',(t.doc('claimA')->>'claim_id')::uuid),'CLAIM_BAD_TRANSITION');
SELECT t.unchanged('replacement note required',format('SELECT public.move_warranty_claim(%L,''replaced'',NULL,%L)',(t.doc('claimA')->>'claim_id')::uuid,t.unit('S12-IMEI-2')),'VALIDATION_FAILED');
SELECT t.unchanged('replacement wrong product',format('SELECT public.move_warranty_claim(%L,''replaced'',''Swap unit'',%L)',(t.doc('claimA')->>'claim_id')::uuid,t.unit('S12-TAB-1')),'REPLACEMENT_UNIT_INVALID');
SELECT t.unchanged('replacement wrong branch',format('SELECT public.move_warranty_claim(%L,''replaced'',''Swap unit'',%L)',(t.doc('claimA')->>'claim_id')::uuid,t.unit('S12-IMEI-9')),'REPLACEMENT_UNIT_INVALID');
SELECT t.unchanged('replacement unavailable',format('SELECT public.move_warranty_claim(%L,''replaced'',''Swap unit'',%L)',(t.doc('claimA')->>'claim_id')::uuid,t.unit('S12-IMEI-1')),'REPLACEMENT_UNIT_INVALID');
SELECT t.error('refund waits for returns',format('SELECT public.request_claim_refund(%L)',(t.doc('claimA')->>'claim_id')::uuid),'CLAIM_REFUND_NEEDS_RETURN');
INSERT INTO t.docs SELECT 'repairA',public.move_warranty_claim((t.doc('claimA')->>'claim_id')::uuid,'in_repair','Sent to supplier');
SELECT t.expect('customer unit in repair',t.unit_status('S12-IMEI-1')='in_repair');
SELECT t.expect('repair does not move shop stock',t.level('phone')=2);
INSERT INTO t.docs SELECT 'replaceA',public.move_warranty_claim((t.doc('claimA')->>'claim_id')::uuid,'replaced','Supplier replacement',t.unit('S12-IMEI-2'));
SELECT t.expect('old unit returned and new unit sold',t.unit_status('S12-IMEI-1')='returned' AND t.unit_status('S12-IMEI-2')='sold');
SELECT t.expect('replacement took sellable stock',t.level('phone')=1);
SELECT t.expect('chain starts with original A',(public.warranty_lookup('S12-IMEI-1')->'items'->0->'chain'->0->>'serial')='S12-IMEI-1');
SELECT t.expect('A and B return the same chain',public.warranty_lookup('S12-IMEI-1')=public.warranty_lookup('S12-IMEI-2'));
SELECT t.expect('replacement preserves original warranty',(public.warranty_lookup('S12-IMEI-2')->'items'->0->'chain'->1->>'warranty_until')='2027-10-11');
SELECT t.expect('replacement retry returns claim without more ledger rows',public.move_warranty_claim((t.doc('claimA')->>'claim_id')::uuid,'replaced','Supplier replacement',t.unit('S12-IMEI-2'))->>'id'=t.doc('claimA')->>'claim_id' AND t.level('phone')=1);
SELECT public.move_warranty_claim((t.doc('claimA')->>'claim_id')::uuid,'closed','Collected by customer');
SELECT t.error('closed cannot move',format('SELECT public.move_warranty_claim(%L,''in_repair'',NULL)',(t.doc('claimA')->>'claim_id')::uuid),'CLAIM_BAD_TRANSITION');
INSERT INTO t.docs SELECT 'claimB',public.open_warranty_claim(t.id('line'),t.unit('S12-IMEI-2'),'Replacement failed','Clean case','s12-claim-b');
SELECT public.move_warranty_claim((t.doc('claimB')->>'claim_id')::uuid,'replaced','Second replacement',t.unit('S12-IMEI-3'));
SELECT t.expect('A B C all return the full same chain',public.warranty_lookup('S12-IMEI-1')=public.warranty_lookup('S12-IMEI-2') AND public.warranty_lookup('S12-IMEI-2')=public.warranty_lookup('S12-IMEI-3') AND jsonb_array_length(public.warranty_lookup('S12-IMEI-3')->'items'->0->'chain')=3);
SELECT t.expect('C sold and B returned',t.unit_status('S12-IMEI-3')='sold' AND t.unit_status('S12-IMEI-2')='returned');
SELECT public.move_warranty_claim((t.doc('claimB')->>'claim_id')::uuid,'closed','Collected');
INSERT INTO t.docs SELECT 'claimC',public.open_warranty_claim(t.id('line'),t.unit('S12-IMEI-3'),'Speaker failed','Clean case','s12-claim-c');
SELECT public.move_warranty_claim((t.doc('claimC')->>'claim_id')::uuid,'in_repair','Sent for repair');
SELECT public.move_warranty_claim((t.doc('claimC')->>'claim_id')::uuid,'repaired','Repair completed');
SELECT t.expect('repaired unit sold, no extra stock',t.unit_status('S12-IMEI-3')='sold' AND t.level('phone')=0);
SELECT t.error('repaired cannot re-enter repair',format('SELECT public.move_warranty_claim(%L,''in_repair'',NULL)',(t.doc('claimC')->>'claim_id')::uuid),'CLAIM_BAD_TRANSITION');
SELECT public.move_warranty_claim((t.doc('claimC')->>'claim_id')::uuid,'closed','Returned to customer');
SELECT t.expect('closed_at recorded',public.get_warranty_claim((t.doc('claimC')->>'claim_id')::uuid)->>'closed_at' IS NOT NULL);
SELECT public.register_file('a7120000-0000-4000-8000-0000000000f1',t.org('a')::text||'/other/photo.png','photo.png','image/png',4,NULL,'other','warranty_claim',(t.doc('claimA')->>'claim_id')::uuid);
SELECT t.expect('claim photo returned in detail',jsonb_array_length(public.get_warranty_claim((t.doc('claimA')->>'claim_id')::uuid)->'files')=1);
SELECT public.register_file('a7120000-0000-4000-8000-0000000000f3',t.org('a')::text||'/customer_id/id.png','id.png','image/png',4,NULL,'customer_id','customer',t.id('mona'));
SELECT t.expect('R01 cashier retains customer ID upload',EXISTS(SELECT 1 FROM public.files WHERE id='a7120000-0000-4000-8000-0000000000f3'));
INSERT INTO t.docs SELECT 'non1',public.open_warranty_claim(t.id('chairline'),NULL,'Broken chair','Used condition','s12-non-one');
INSERT INTO t.docs SELECT 'non2',public.open_warranty_claim(t.id('chairline'),NULL,'Second chair broken','Used condition','s12-non-two');
SELECT t.expect('no warranty is flagged',(t.doc('non1')->>'out_of_warranty')::boolean);
SELECT t.error('third exceeds sold quantity',format('SELECT public.open_warranty_claim(%L,NULL,%L,%L,%L)',t.id('chairline'),'Third chair','Used condition','s12-non-three'),'CLAIM_QTY_EXCEEDED');
SELECT t.error('nonserial unit mismatch',format('SELECT public.open_warranty_claim(%L,%L,%L,%L,%L)',t.id('chairline'),t.unit('S12-IMEI-3'),'Broken chair','Used condition','s12-non-unit'),'CLAIM_UNIT_MISMATCH');
SELECT t.error('cashier cannot move expired claim',format('SELECT public.move_warranty_claim(%L,''in_repair'',''Repair'')',(t.doc('non1')->>'claim_id')::uuid),'OUT_OF_WARRANTY_NEEDS_MANAGER');
SELECT public.move_warranty_claim((t.doc('non2')->>'claim_id')::uuid,'rejected','Not covered');
RESET ROLE;
SELECT t.as_user('a7120000-0000-0000-8000-000000000007',t.org('a'));
SET ROLE authenticated;
SELECT public.move_warranty_claim((t.doc('non1')->>'claim_id')::uuid,'replaced','Manager replacement');
SELECT t.expect('nonserial replacement reduces sellable',t.level('chair')=7);
SELECT public.move_warranty_claim((t.doc('non1')->>'claim_id')::uuid,'closed','Collected');
RESET ROLE;
-- Explicitly expired date and a new serialized claim.
ALTER TABLE public.sale_lines DISABLE TRIGGER trg_sale_lines_append_only;
UPDATE public.sale_lines SET warranty_until=t.today()-1 WHERE id=t.id('line');
ALTER TABLE public.sale_lines ENABLE TRIGGER trg_sale_lines_append_only;
SELECT t.as_user('a7120000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'expired',public.open_warranty_claim(t.id('line'),t.unit('S12-IMEI-3'),'Expired speaker','Clean case','s12-expired-claim');
SELECT t.expect('yesterday date flagged',(t.doc('expired')->>'out_of_warranty')::boolean);
SELECT t.error('expired cashier cannot progress',format('SELECT public.move_warranty_claim(%L,''in_repair'',''Repair'')',(t.doc('expired')->>'claim_id')::uuid),'OUT_OF_WARRANTY_NEEDS_MANAGER');
RESET ROLE;
SELECT t.as_user('a7120000-0000-0000-8000-000000000007',t.org('a'));
SET ROLE authenticated;
SELECT public.move_warranty_claim((t.doc('expired')->>'claim_id')::uuid,'in_repair','Manager approved');
RESET ROLE;
SELECT t.as_user('a7120000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT public.move_warranty_claim((t.doc('expired')->>'claim_id')::uuid,'rejected','Not repairable');
RESET ROLE;
SELECT t.as_user('a7120000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'secondshift',(t.open_shift(t.id('second'),'0','s12-second-shift')->>'id')::uuid;
INSERT INTO t.docs SELECT 'secondsale',public.post_sale(t.lines(t.phone('S12-IMEI-9')),'5000.00','s12-second-sale');
INSERT INTO t.docs SELECT 'secondclaim',public.open_warranty_claim((t.doc('secondsale')->'lines'->0->>'id')::uuid,t.unit('S12-IMEI-9'),'Screen failed','Scratched case','s12-second-claim');
RESET ROLE;
SELECT t.as_user('a7120000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('inaccessible branch serial lookup empty',public.warranty_lookup('S12-IMEI-9')->'items'='[]'::jsonb);
SELECT t.error('inaccessible claim detail not found',format('SELECT public.get_warranty_claim(%L)',(t.doc('secondclaim')->>'claim_id')::uuid),'NOT_FOUND');
SELECT t.error('inaccessible claim move not found',format('SELECT public.move_warranty_claim(%L,''rejected'',''Reason'')',(t.doc('secondclaim')->>'claim_id')::uuid),'NOT_FOUND');
SELECT t.error('inaccessible branch list refused',format('SELECT public.list_warranty_claims(NULL,%L)',t.id('second')),'BRANCH_DENIED');
SELECT t.error('inaccessible claim photo refused',format('SELECT public.register_file(%L,%L,%L,%L,4,NULL,''other'',''warranty_claim'',%L)',gen_random_uuid(),t.org('a')::text||'/other/branch.png','branch.png','image/png',(t.doc('secondclaim')->>'claim_id')::uuid),'BRANCH_DENIED');
RESET ROLE;
SELECT t.as_user('a7120000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT public.register_file(gen_random_uuid(),t.org('a')::text||'/other/photo-'||n||'.png','photo.png','image/png',4,NULL,'other','warranty_claim',(t.doc('claimA')->>'claim_id')::uuid) FROM generate_series(2,5) n;
SELECT t.expect('five claim photos are allowed',jsonb_array_length(public.get_warranty_claim((t.doc('claimA')->>'claim_id')::uuid)->'files')=5);
SELECT t.error('sixth photo refused',format('SELECT public.register_file(%L,%L,%L,%L,4,NULL,''other'',''warranty_claim'',%L)',gen_random_uuid(),t.org('a')::text||'/other/sixth.png','sixth.png','image/png',(t.doc('claimA')->>'claim_id')::uuid),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('stock ledger invariant',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
SELECT t.expect('old units in damaged stock',(SELECT on_hand=2 FROM public.stock_levels WHERE product_id=t.id('phone') AND branch_id=t.id('main') AND stock_state='damaged'));
SELECT t.expect('one pair per replacement',(SELECT count(*)=4 FROM public.stock_movements WHERE organization_id=t.org('a') AND source_type='warranty_claim' AND product_id=t.id('phone')));
SELECT t.expect('sales immutable across claims',(SELECT to_jsonb(s)=j FROM public.sales s CROSS JOIN t.sale_before WHERE s.id=t.id('sale')));
SELECT t.expect('resolution includes received condition and original end',(SELECT resolution LIKE 'Received: Scratched case%' AND resolution LIKE '%Warranty until: 2027-10-11%' FROM public.warranty_claims WHERE id=(t.doc('claimA')->>'claim_id')::uuid));
SELECT t.expect('all moves audited with notes',(SELECT count(*)=3 AND bool_and(after ? 'note') FROM public.audit_log WHERE entity_id=(t.doc('claimC')->>'claim_id')::uuid AND action='warranty_claim.moved'));
SELECT t.as_user('a7120000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.expect('other shop serial lookup empty',public.warranty_lookup('S12-IMEI-1')->'items'='[]'::jsonb);
SELECT t.expect('other shop claims empty',public.list_warranty_claims()->'items'='[]'::jsonb);
SELECT t.error('other shop sale line not found',format('SELECT public.open_warranty_claim(%L,%L,%L,%L,%L)',t.id('line'),t.unit('S12-IMEI-1'),'Broken','Scratched','s12-foreign-open'),'SALE_LINE_NOT_FOUND');
SELECT t.error('other shop claim detail not found',format('SELECT public.get_warranty_claim(%L)',(t.doc('claimA')->>'claim_id')::uuid),'NOT_FOUND');
SELECT t.error('other shop claim move not found',format('SELECT public.move_warranty_claim(%L,''in_repair'',NULL)',(t.doc('claimA')->>'claim_id')::uuid),'NOT_FOUND');
SELECT t.error('other shop photo refused',format('SELECT public.register_file(%L,%L,%L,%L,4,NULL,''other'',''warranty_claim'',%L)','a7120000-0000-4000-8000-0000000000f2',t.org('b')::text||'/other/foreign.png','foreign.png','image/png',(t.doc('claimA')->>'claim_id')::uuid),'NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a7120000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.error('warehouse lookup denied','SELECT public.warranty_lookup(''S12-IMEI-1'')','PERMISSION_DENIED');
SELECT t.error('warehouse open denied',format('SELECT public.open_warranty_claim(%L,NULL,%L,%L,%L)',t.id('chairline'),'Broken','Scratched','s12-denied-open'),'PERMISSION_DENIED');
SELECT t.error('warehouse move denied',format('SELECT public.move_warranty_claim(%L,''rejected'',''Reason'')',(t.doc('claimA')->>'claim_id')::uuid),'PERMISSION_DENIED');
SELECT t.error('warehouse refund denied',format('SELECT public.request_claim_refund(%L)',(t.doc('claimA')->>'claim_id')::uuid),'PERMISSION_DENIED');
RESET ROLE;
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END result,name,CASE WHEN ok THEN '' ELSE detail END detail FROM t.results ORDER BY ok,name;
SELECT count(*) FILTER (WHERE ok) passed,count(*) FILTER (WHERE NOT ok) failed FROM t.results;
