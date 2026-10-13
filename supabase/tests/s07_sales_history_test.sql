-- S07 real sale, split-payment reversal, search, permissions and replay.
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
  SELECT format('SELECT public.post_sale(%L,%L,%L,%L)',lines,expected,'s07-'||md5(random()::text),t.id(customer)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (serials, two branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S07 '||s,'s07-'||s,'retail_pro','Owner',s||'s07@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('s',64)),('b',repeat('t',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a7070000-0000-0000-8000-000000000001','as07@example.com'),('a7070000-0000-0000-8000-000000000002','bs07@example.com'),
  ('a7070000-0000-0000-8000-000000000003','s07cashier@example.com'),('a7070000-0000-0000-8000-000000000004','s07cashier2@example.com'),
  ('a7070000-0000-0000-8000-000000000005','s07accountant@example.com'),('a7070000-0000-0000-8000-000000000006','s07warehouse@example.com'),
  ('a7070000-0000-0000-8000-000000000007','s07manager@example.com');
SELECT public.accept_invite(repeat('s',64),'a7070000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('t',64),'a7070000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id=t.org('a');
SELECT t.as_user('a7070000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"S7-CH","cash_price":"250"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"هاتف","sku":"S7-PH","cash_price":"5000","is_serialized":true,"warranty_months":12}'));
INSERT INTO t.ids VALUES('tablet',public.create_product('{"name_ar":"لوحي","sku":"S7-TB","cash_price":"3000","is_serialized":true}'));
INSERT INTO t.ids VALUES('gift',public.create_product('{"name_ar":"هدية","sku":"S7-GF","cash_price":"0"}'));
INSERT INTO t.ids VALUES('old',public.create_product('{"name_ar":"قديم","sku":"S7-OLD","cash_price":"10"}'));
-- Stock through a real purchase: 10 chairs at 100 and 3 phones at 3 000 (costs before VAT).
INSERT INTO t.ids SELECT 'pi',(public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,t.lines(
  jsonb_build_object('product_id',t.id('chair'),'quantity',10,'unit_cost','100.00'),
  jsonb_build_object('product_id',t.id('phone'),'quantity',3,'unit_cost','3000.00','serials',jsonb_build_array('S7-IMEI-1','S7-IMEI-2','S7-IMEI-3'))),
  's07-invoice')->>'id')::uuid;
SELECT public.approve_purchase_invoice(t.id('pi'));
SELECT public.register_units(t.id('tablet'),t.id('main'),'2000.00','["S7-TAB-1"]',NULL,'s07-tablet');
SELECT public.register_units(t.id('phone'),t.id('second'),'2900.00','["S7-IMEI-9"]',NULL,'s07-phone-second');
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',5),
  jsonb_build_object('product_id',t.id('old'),'quantity',5)),'s07-found');
SELECT public.set_product_archived(t.id('old'),true);
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a7070000-0000-0000-8000-000000000003','S07 Cashier','CASHIER');
SELECT t.emp('cashier2','a7070000-0000-0000-8000-000000000004','S07 Cashier Two','CASHIER');
SELECT t.emp('acc','a7070000-0000-0000-8000-000000000005','S07 Accountant','ACCOUNTANT');
SELECT t.emp('wh','a7070000-0000-0000-8000-000000000006','S07 Warehouse','WAREHOUSE');
SELECT t.emp('mgr','a7070000-0000-0000-8000-000000000007','S07 Manager','BRANCH_MANAGER');
INSERT INTO public.customers(id,organization_id,full_name) VALUES
  ('a7070000-0000-0000-8000-0000000000c1',t.org('a'),'Mona Buyer'),('a7070000-0000-0000-8000-0000000000c2',t.org('a'),'Gone Buyer'),
  ('a7070000-0000-0000-8000-0000000000c3',t.org('b'),'Shop B Buyer');
UPDATE public.customers SET archived_at=now() WHERE id='a7070000-0000-0000-8000-0000000000c2';
INSERT INTO t.ids VALUES('mona','a7070000-0000-0000-8000-0000000000c1'),('gone','a7070000-0000-0000-8000-0000000000c2'),('buyer_b','a7070000-0000-0000-8000-0000000000c3');
-- Shop b: a product and a unit of its own.
SELECT t.as_user('a7070000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('chair_b',public.create_product('{"name_ar":"كرسي ب","sku":"S7B-CH","cash_price":"250"}'));
RESET ROLE;
SELECT t.expect('setup: 10 chairs and 3 phones in main, costs 100 and 3 000',
  t.level('chair')=10 AND t.level('phone')=3 AND (SELECT avg_cost FROM public.products WHERE id=t.id('chair'))=100,
  concat_ws(' ',t.level('chair'),t.level('phone')));


SELECT t.as_user('a7070000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('S07 Bank','bank',NULL)->>'id')::uuid;
RESET ROLE;
UPDATE public.customers SET phones=ARRAY['01012345678'] WHERE id=t.id('mona');
SELECT t.as_user('a7070000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'0','s07-shift')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=t.id('shift');
INSERT INTO t.docs SELECT 'sale',public.post_sale(t.lines(t.chairs(2),t.phone('S7-IMEI-1')),'5500.00','s07-main-sale',t.id('mona'),jsonb_build_array(jsonb_build_object('method','cash','amount','2750.00'),jsonb_build_object('method','bank_transfer','amount','2750.00','cash_account_id',t.id('bank'),'reference','S07 transfer')));
RESET ROLE;
INSERT INTO t.ids SELECT 'sale',(t.doc('sale')->>'id')::uuid;
CREATE TABLE t.original AS SELECT to_jsonb(s) j FROM public.sales s WHERE id=t.id('sale');
GRANT SELECT ON t.original TO authenticated;
SELECT t.expect('sale moved stock, serial and both accounts',t.level('chair')=8 AND t.level('phone')=2 AND t.cash('drawer')=2750 AND t.cash('bank')=2750);
SELECT t.as_user('a7070000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('number prefix',EXISTS(SELECT 1 FROM public.search_sales(left(t.doc('sale')->>'number',6),NULL,NULL,NULL,NULL,NULL,NULL,20,0) WHERE id=t.id('sale')));
SELECT t.expect('exact serial',EXISTS(SELECT 1 FROM public.search_sales('S7-IMEI-1',NULL,NULL,NULL,NULL,NULL,NULL,20,0) WHERE id=t.id('sale')));
SELECT t.expect('normalized customer phone',EXISTS(SELECT 1 FROM public.search_sales('+20 1012345678',NULL,NULL,NULL,NULL,NULL,NULL,20,0) WHERE id=t.id('sale')));
SELECT t.expect('date filter',NOT EXISTS(SELECT 1 FROM public.search_sales(NULL,NULL,NULL,NULL,current_date-2,current_date-1,NULL,20,0)));
SELECT t.expect('inaccessible branch excluded',NOT EXISTS(SELECT 1 FROM public.search_sales(NULL,t.id('second'),NULL,NULL,NULL,NULL,NULL,20,0)));
SELECT t.expect('detail retains sale fields and omits customer national ID',public.get_sale_details(t.id('sale'))->>'number'=t.doc('sale')->>'number' AND NOT (public.get_sale_details(t.id('sale'))->'customer' ? 'national_id'));
SELECT t.error('cashier cannot void',format('SELECT public.void_sale(%L,%L,%L)',t.id('sale'),'Duplicate','s07-cashier-void'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a7070000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.expect('other shop search excludes sale',NOT EXISTS(SELECT 1 FROM public.search_sales('S7-IMEI-1',NULL,NULL,NULL,NULL,NULL,NULL,20,0)));
SELECT t.error('other shop detail',format('SELECT public.get_sale_details(%L)',t.id('sale')),'SALE_NOT_FOUND');
SELECT t.error('other shop void',format('SELECT public.void_sale(%L,%L,%L)',t.id('sale'),'Duplicate','s07-foreign-void'),'SALE_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a7070000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('reason required',format('SELECT public.void_sale(%L,%L,%L)',t.id('sale'),' ','s07-empty-reason'),'REASON_REQUIRED');
INSERT INTO t.docs SELECT 'void',public.void_sale(t.id('sale'),'Duplicate receipt','s07-void-main');
SELECT t.expect('idempotent replay',public.void_sale(t.id('sale'),'Duplicate receipt','s07-void-main')=t.doc('void'));
SELECT t.error('second void',format('SELECT public.void_sale(%L,%L,%L)',t.id('sale'),'Duplicate','s07-second-void'),'ALREADY_VOIDED');
SELECT t.expect('status in search',EXISTS(SELECT 1 FROM public.search_sales('S7-IMEI-1',NULL,NULL,NULL,NULL,NULL,'voided',20,0) WHERE id=t.id('sale') AND status='voided'));
SELECT t.expect('status and history in detail',public.get_sale_details(t.id('sale'))->>'status'='voided' AND jsonb_array_length(public.get_sale_details(t.id('sale'))->'returns')=1 AND public.get_sale_details(t.id('sale'))->>'voidable'='false');
RESET ROLE;
SELECT t.expect('stock restored',t.level('chair')=10 AND t.level('phone')=3);
SELECT t.expect('serial restored',(SELECT status='in_stock' FROM public.units WHERE id=t.unit('S7-IMEI-1')));
SELECT t.expect('cash and bank restored',t.cash('drawer')=0 AND t.cash('bank')=0);
SELECT t.expect('tax reversed exactly',(SELECT tax_total=(t.doc('sale')->>'tax_total')::numeric FROM public.sales_returns WHERE id=(t.doc('void')->>'return_id')::uuid));
SELECT t.expect('sale header unchanged',(SELECT to_jsonb(s)=t.original.j FROM public.sales s,t.original WHERE s.id=t.id('sale')));
SELECT t.expect('one reversal per stock movement',(SELECT count(*)=2 FROM public.stock_movements WHERE source_id=(t.doc('void')->>'return_id')::uuid AND reverses_movement_id IS NOT NULL));
SELECT t.expect('one reversal per payment',(SELECT count(*)=2 FROM public.payments WHERE reverses_payment_id IN(SELECT payment_id FROM public.payment_allocations WHERE sale_id=t.id('sale'))));
SELECT t.expect('one reversal per cash movement',(SELECT count(*)=2 FROM public.cash_movements WHERE source_id=(t.doc('void')->>'return_id')::uuid AND reverses_movement_id IS NOT NULL));
SELECT t.expect('one return line per original line',(SELECT count(*)=2 FROM public.sales_return_lines WHERE return_id=(t.doc('void')->>'return_id')::uuid));
SELECT t.expect('audit once with reason and warning',(SELECT count(*)=1 FROM public.audit_log WHERE action='sale.voided' AND entity_id=t.id('sale') AND reason='Duplicate receipt' AND severity='warning'));
SELECT t.expect('ledgers reconcile',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));

-- Every negative case uses a distinct real sale and checks its eligibility hint too.
CREATE FUNCTION t.fresh(tag text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN j:=public.post_sale(t.lines(t.chairs(1)),'250.00','s07-rule-'||tag,t.id('mona')); INSERT INTO t.ids VALUES(tag,(j->>'id')::uuid); RETURN (j->>'id')::uuid; END $$;
GRANT EXECUTE ON FUNCTION t.fresh(text) TO authenticated;
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'owner-shift',(t.open_shift(t.id('main'),'0','s07-owner-shift')->>'id')::uuid;
SELECT t.fresh('yesterday'); SELECT t.fresh('return'); SELECT t.fresh('claim'); SELECT t.fresh('contract');
SELECT t.fresh('eta-pending'); SELECT t.fresh('eta-issued'); SELECT t.fresh('closed');
RESET ROLE;
ALTER TABLE public.sales DISABLE TRIGGER USER;
UPDATE public.sales SET business_date=app.org_today(t.org('a'))-1 WHERE id=t.id('yesterday');
ALTER TABLE public.sales ENABLE TRIGGER USER;
INSERT INTO public.sales_returns(organization_id,number,sale_id,branch_id,shift_id,kind,refund_method,subtotal,total,reason,business_date,idempotency_key)
VALUES(t.org('a'),'S07 prior return',t.id('return'),t.id('main'),t.id('owner-shift'),'return','cash',1,1,'Prior return',current_date,'s07-prior-return');
INSERT INTO public.warranty_claims(organization_id,number,branch_id,sale_line_id,customer_id,issue,idempotency_key)
SELECT t.org('a'),'S07 claim',t.id('main'),l.id,t.id('mona'),'Faulty item','s07-manual-claim' FROM public.sale_lines l WHERE sale_id=t.id('claim');
INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,sale_id,policy_id,creditor,cash_price,down_payment,financed_amount,markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,idempotency_key)
SELECT t.org('a'),'S07 contract',t.id('mona'),t.id('main'),t.id('contract'),p.id,'in_house',250,0,250,0,0,250,1,'monthly',current_date+30,'s07-manual-contract' FROM public.installment_policies p WHERE organization_id=t.org('a') LIMIT 1;
INSERT INTO public.fiscal_submissions(organization_id,branch_id,doc_type,sale_id,environment,internal_id,eta_uuid)
VALUES(t.org('a'),t.id('main'),'b2c_receipt',t.id('eta-pending'),'preprod','S07 pending',NULL),
(t.org('a'),t.id('main'),'b2c_receipt',t.id('eta-issued'),'preprod','S07 issued','eta-issued-uuid');
SET ROLE authenticated;
SELECT t.error('yesterday blocked',format('SELECT public.void_sale(%L,%L,%L)',t.id('yesterday'),'Duplicate','s07-void-yesterday'),'VOID_NOT_SAME_DAY');
SELECT t.expect('yesterday hint',public.get_sale_details(t.id('yesterday'))->>'void_block_reason'='VOID_NOT_SAME_DAY');
SELECT t.error('prior return blocked',format('SELECT public.void_sale(%L,%L,%L)',t.id('return'),'Duplicate','s07-void-return'),'VOID_HAS_RETURNS');
SELECT t.error('warranty claim blocked',format('SELECT public.void_sale(%L,%L,%L)',t.id('claim'),'Duplicate','s07-void-claim'),'VOID_HAS_CLAIMS');
SELECT t.error('installment contract blocked',format('SELECT public.void_sale(%L,%L,%L)',t.id('contract'),'Duplicate','s07-void-contract'),'VOID_HAS_CONTRACT');
SELECT t.error('issued fiscal receipt blocked',format('SELECT public.void_sale(%L,%L,%L)',t.id('eta-issued'),'Duplicate','s07-void-issued'),'VOID_FISCALIZED');
SELECT t.expect('fiscal refusal leaves no void',NOT EXISTS(SELECT 1 FROM public.sales_returns WHERE sale_id=t.id('eta-issued')));
SELECT public.void_sale(t.id('eta-pending'),'Duplicate','s07-void-pending');
SELECT t.expect('pending fiscal receipt cancelled',(SELECT status='cancelled' FROM public.fiscal_submissions WHERE sale_id=t.id('eta-pending')));
SELECT t.error('key cannot target a different sale',format('SELECT public.void_sale(%L,%L,%L)',t.id('closed'),'Duplicate','s07-void-main'),'IDEMPOTENCY_CONFLICT');
RESET ROLE;
SET ROLE authenticated;
SELECT public.close_shift(t.id('owner-shift'),'{}',p_difference_reason=>'S07 closing difference');
RESET ROLE;
SET ROLE authenticated;
SELECT t.error('closed shift blocked',format('SELECT public.void_sale(%L,%L,%L)',t.id('closed'),'Duplicate','s07-void-closed'),'VOID_SHIFT_CLOSED');
RESET ROLE;
SELECT t.expect('void serializes sale, shift and stock locks before checks',
 strpos(pg_get_functiondef('public.void_sale(uuid,text,text)'::regprocedure),'FOR UPDATE') < strpos(pg_get_functiondef('public.void_sale(uuid,text,text)'::regprocedure),'VOID_NOT_SAME_DAY')
 AND (SELECT count(*)=1 FROM public.sales_returns WHERE sale_id=t.id('sale') AND kind='void'));
SELECT t.expect('all final ledgers reconcile',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));


-- P05 compatibility: existing sale details remain readable after subscription expiry.
UPDATE public.organizations SET subscription_start=app.org_today(t.org('a'))-365,subscription_end=app.org_today(t.org('a'))-1 WHERE id=t.org('a');
SELECT t.as_user('a7070000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired owner can read history',EXISTS(SELECT 1 FROM public.search_sales('S7-IMEI-1',NULL,NULL,NULL,NULL,NULL,NULL,20,0) WHERE id=t.id('sale')));
SELECT t.expect('expired owner can read detail',public.get_sale_details(t.id('sale'))->>'status'='voided');
SELECT t.error('expired owner cannot void',format('SELECT public.void_sale(%L,%L,%L)',t.id('closed'),'Duplicate','s07-expired-void'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
SELECT t.as_user('a7070000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.error('expired shop does not bypass reader permission',$q$SELECT public.search_sales()$q$,'PERMISSION_DENIED');
RESET ROLE;

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) AS passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) AS failed FROM t.results;
