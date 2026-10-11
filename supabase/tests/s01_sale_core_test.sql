-- S01 sale core (EC-68, D62).
-- Run by: node scripts/db-smoke.mjs supabase/tests/s01_sale_core_test.sql (inside BEGIN ... ROLLBACK).
-- A cashier with an open shift sells chairs and IMEI phones for cash. Covers the Done when:
-- the four ledger/reconciliation checks, a double submit makes one sale, the last unit can't be
-- sold twice; and prices from the server, overrides, PRICE_CHANGED, the tax snapshot in both VAT
-- modes, every refusal leaving nothing behind, who may sell and read, tenancy and grants.
-- (Many requests at the same moment: scripts/db-stock-cash-proof.mjs.)
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
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
  SELECT format('SELECT public.post_sale(%L,%L,%L,%L)',lines,expected,'s01-'||md5(random()::text),t.id(customer)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (serials, two branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S01 '||s,'s01-'||s,'retail_pro','Owner',s||'s01@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('s',64)),('b',repeat('t',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a7040000-0000-0000-8000-000000000001','as01@example.com'),('a7040000-0000-0000-8000-000000000002','bs01@example.com'),
  ('a7040000-0000-0000-8000-000000000003','s01cashier@example.com'),('a7040000-0000-0000-8000-000000000004','s01cashier2@example.com'),
  ('a7040000-0000-0000-8000-000000000005','s01accountant@example.com'),('a7040000-0000-0000-8000-000000000006','s01warehouse@example.com'),
  ('a7040000-0000-0000-8000-000000000007','s01manager@example.com');
SELECT public.accept_invite(repeat('s',64),'a7040000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('t',64),'a7040000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id=t.org('a');
SELECT t.as_user('a7040000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"S1-CH","cash_price":"250"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"هاتف","sku":"S1-PH","cash_price":"5000","is_serialized":true,"warranty_months":12}'));
INSERT INTO t.ids VALUES('tablet',public.create_product('{"name_ar":"لوحي","sku":"S1-TB","cash_price":"3000","is_serialized":true}'));
INSERT INTO t.ids VALUES('gift',public.create_product('{"name_ar":"هدية","sku":"S1-GF","cash_price":"0"}'));
INSERT INTO t.ids VALUES('old',public.create_product('{"name_ar":"قديم","sku":"S1-OLD","cash_price":"10"}'));
-- Stock through a real purchase: 10 chairs at 100 and 3 phones at 3 000 (costs before VAT).
INSERT INTO t.ids SELECT 'pi',(public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,t.lines(
  jsonb_build_object('product_id',t.id('chair'),'quantity',10,'unit_cost','100.00'),
  jsonb_build_object('product_id',t.id('phone'),'quantity',3,'unit_cost','3000.00','serials',jsonb_build_array('S1-IMEI-1','S1-IMEI-2','S1-IMEI-3'))),
  's01-invoice')->>'id')::uuid;
SELECT public.approve_purchase_invoice(t.id('pi'));
SELECT public.register_units(t.id('tablet'),t.id('main'),'2000.00','["S1-TAB-1"]',NULL,'s01-tablet');
SELECT public.register_units(t.id('phone'),t.id('second'),'2900.00','["S1-IMEI-9"]',NULL,'s01-phone-second');
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',5),
  jsonb_build_object('product_id',t.id('old'),'quantity',5)),'s01-found');
SELECT public.set_product_archived(t.id('old'),true);
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a7040000-0000-0000-8000-000000000003','S01 Cashier','CASHIER');
SELECT t.emp('cashier2','a7040000-0000-0000-8000-000000000004','S01 Cashier Two','CASHIER');
SELECT t.emp('acc','a7040000-0000-0000-8000-000000000005','S01 Accountant','ACCOUNTANT');
SELECT t.emp('wh','a7040000-0000-0000-8000-000000000006','S01 Warehouse','WAREHOUSE');
SELECT t.emp('mgr','a7040000-0000-0000-8000-000000000007','S01 Manager','BRANCH_MANAGER');
INSERT INTO public.customers(id,organization_id,full_name) VALUES
  ('a7040000-0000-0000-8000-0000000000c1',t.org('a'),'Mona Buyer'),('a7040000-0000-0000-8000-0000000000c2',t.org('a'),'Gone Buyer'),
  ('a7040000-0000-0000-8000-0000000000c3',t.org('b'),'Shop B Buyer');
UPDATE public.customers SET archived_at=now() WHERE id='a7040000-0000-0000-8000-0000000000c2';
INSERT INTO t.ids VALUES('mona','a7040000-0000-0000-8000-0000000000c1'),('gone','a7040000-0000-0000-8000-0000000000c2'),('buyer_b','a7040000-0000-0000-8000-0000000000c3');
-- Shop b: a product and a unit of its own.
SELECT t.as_user('a7040000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('chair_b',public.create_product('{"name_ar":"كرسي ب","sku":"S1B-CH","cash_price":"250"}'));
RESET ROLE;
SELECT t.expect('setup: 10 chairs and 3 phones in main, costs 100 and 3 000',
  t.level('chair')=10 AND t.level('phone')=3 AND (SELECT avg_cost FROM public.products WHERE id=t.id('chair'))=100,
  concat_ws(' ',t.level('chair'),t.level('phone')));

-- ---------------------------------------------------------------- no shift, then a shift
SELECT t.as_user('a7040000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('no open shift: no sale',t.sell(t.lines(t.chairs(1)),'250.00'),'SHIFT_REQUIRED');
SELECT t.error('no open shift: no quote',format('SELECT public.quote_sale(%L)',t.lines(t.chairs(1))),'SHIFT_REQUIRED');
INSERT INTO t.ids SELECT 'shift',(public.open_shift(t.id('main'),'0','s01-shift-cashier')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',(SELECT drawer_account_id FROM public.shifts WHERE id=t.id('shift'));

-- ---------------------------------------------------------------- the quote
INSERT INTO t.docs SELECT 'quote',public.quote_sale(t.lines(t.chairs(2),t.phone('S1-IMEI-1')));
SELECT t.expect('quote: the server''s prices, VAT inside the price (14%), totals',
  j->>'prices_include_vat'='true' AND j->>'subtotal'='5500.00' AND j->>'tax_total'='675.44' AND j->>'total'='5500.00'
  AND j->'lines'->0->>'unit_price'='250.00' AND j->'lines'->0->>'list_price'='250.00' AND j->'lines'->0->>'tax_amount'='61.40'
  AND j->'lines'->0->>'line_total'='500.00' AND j->'lines'->0->>'available'='10' AND j->'lines'->0->>'overridden'='false'
  AND j->'lines'->1->>'serial'='S1-IMEI-1' AND j->'lines'->1->>'tax_amount'='614.04' AND j->'lines'->1->>'line_total'='5000.00'
  AND j->'lines'->1->>'available'='3' AND j->'lines'->0->>'name_en'='Chair',j::text) FROM t.docs WHERE tag='quote';
SELECT t.expect('quote: no cost, tax class or warranty fields leave the server',
  NOT (j->'lines'->0 ? 'unit_cost') AND NOT (j->'lines'->0 ? 'tax_class_id') AND NOT (j->'lines'->1 ? 'warranty_months')) FROM t.docs WHERE tag='quote';
SELECT t.expect('quote: more than is in stock is reported, not refused',
  (public.quote_sale(t.lines(t.chairs(50)))->'lines'->0->>'available')='10');
SELECT t.expect('quote: nothing was written',t.footprint()='0/0/0/0/0/0/0/0',t.footprint());

-- ---------------------------------------------------------------- a sale
INSERT INTO t.docs SELECT 's1',public.post_sale(t.lines(t.chairs(2),t.phone('S1-IMEI-1')),'5500.00','s01-sale-0001');
INSERT INTO t.ids SELECT 's1',(t.doc('s1')->>'id')::uuid;
SELECT t.expect('sale: numbered SL in the shift''s branch, totals and tax snapshot as quoted',
  j->>'number' LIKE 'MAIN-SL-%-000001' AND j->>'branch_id'=t.id('main')::text AND j->>'shift_id'=t.id('shift')::text
  AND j->>'subtotal'='5500.00' AND j->>'discount_total'='0.00' AND j->>'tax_total'='675.44' AND j->>'total'='5500.00'
  AND j->>'prices_include_vat'='true' AND j->>'customer_id' IS NULL AND j->>'created_by_name'='S01 Cashier'
  AND jsonb_array_length(j->'lines')=2 AND j->'lines'->0->>'tax_rate'='14.00' AND j->'lines'->0->>'tax_amount'='61.40'
  AND j->'lines'->0->>'line_total'='500.00' AND j->'lines'->0->>'quantity'='2' AND j->'lines'->1->>'serial'='S1-IMEI-1'
  AND j->'lines'->1->>'tax_amount'='614.04' AND j->'lines'->0->>'warranty_until' IS NULL,j::text) FROM t.docs WHERE tag='s1';
SELECT t.expect('sale: the phone carries its warranty date (12 months)',
  (j->'lines'->1->>'warranty_until')::date=(t.today()+interval '12 months')::date,j->'lines'->1->>'warranty_until') FROM t.docs WHERE tag='s1';
SELECT t.expect('sale: one cash payment of the total into the shift''s drawer',
  jsonb_array_length(j->'payments')=1 AND j->'payments'->0->>'method'='cash' AND j->'payments'->0->>'amount'='5500.00'
  AND j->'payments'->0->>'cash_account_id'=t.id('drawer')::text AND j->'payments'->0->>'number' LIKE 'MAIN-PY-%',(j->'payments')::text) FROM t.docs WHERE tag='s1';
RESET ROLE;
SELECT t.expect('sale: stock is down by 2 and 1, the unit is sold',
  t.level('chair')=8 AND t.level('phone')=2 AND t.unit_status('S1-IMEI-1')='sold',concat_ws(' ',t.level('chair'),t.level('phone'),t.unit_status('S1-IMEI-1')));
SELECT t.expect('sale: the drawer and the shift''s expected cash are up by the total',t.cash('drawer')=5500.00 AND t.expected('shift')='5500.00',concat_ws(' ',t.cash('drawer'),t.expected('shift')));
SELECT t.expect('sale: one sale_out row per line at its cost, linked to the line; cost snapshot 2 x 100 + 3 000',
  (SELECT count(*)=2 AND bool_and(m.source_line_id=l.id AND m.unit_cost=l.unit_cost AND m.quantity=-l.quantity AND m.unit_id IS NOT DISTINCT FROM l.unit_id)
   FROM public.stock_movements m JOIN public.sale_lines l ON l.id=m.source_line_id WHERE m.source_id=t.id('s1') AND m.type='sale_out')
  AND (SELECT cost_total FROM public.sales WHERE id=t.id('s1'))=3200.00
  AND (SELECT array_agg(unit_cost ORDER BY line_no) FROM public.sale_lines WHERE sale_id=t.id('s1'))=ARRAY[100.0000,3000.0000]::numeric[]);
SELECT t.expect('sale: the payment, its allocation and one drawer movement tagged with the shift',
  (SELECT count(*)=1 AND bool_and(p.idempotency_key='system:sale:'||t.id('s1')||':1' AND p.shift_id=t.id('shift') AND p.received_by=t.id('cashier') AND a.amount=5500.00)
   FROM public.payments p JOIN public.payment_allocations a ON a.payment_id=p.id WHERE a.sale_id=t.id('s1'))
  AND (SELECT count(*)=1 AND bool_and(m.amount=5500.00 AND m.shift_id=t.id('shift') AND m.cash_account_id=t.id('drawer') AND m.note LIKE 'MAIN-SL-%')
       FROM public.cash_movements m WHERE m.source_type='sale' AND m.source_id=t.id('s1')));
SELECT t.expect('sale: audited once, info, with the number and no overrides',
  t.audits('sale.created',t.id('s1'))=1 AND (SELECT severity='info' AND after->>'total'='5500.00' AND after->'price_overrides'='[]'::jsonb AND branch_id=t.id('main')
    FROM public.audit_log WHERE action='sale.created' AND entity_id=t.id('s1')));
SELECT t.expect('footprint after one sale',t.footprint()='1/2/2/1/1/1/4/1',t.footprint());

-- ---------------------------------------------------------------- Done when: a double submit makes one sale
SELECT t.as_user('a7040000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('Done when: the same key again answers the same sale',
  (public.post_sale(t.lines(t.chairs(2),t.phone('S1-IMEI-1')),'5500.00','s01-sale-0001')->>'id')=t.id('s1')::text);
SELECT t.expect('...even with another cart behind the same key',
  (public.post_sale(t.lines(t.chairs(1)),'250.00','s01-sale-0001')->>'number')=(t.doc('s1')->>'number'));
SELECT t.expect('Done when: nothing was written twice (documents, ledgers, numbers, audit)',t.footprint()='1/2/2/1/1/1/4/1',t.footprint());

-- ---------------------------------------------------------------- prices
SELECT t.error_detail('PRICE_CHANGED: the cashier saw another total',t.sell(t.lines(t.chairs(1)),'240.00'),'PRICE_CHANGED',
  '{"expected_total":"240.00","total":"250.00"}');
SELECT t.error('a price that differs from the list needs price.override',t.sell(t.lines(t.chairs(1,'200.00')),'200.00'),'PRICE_OVERRIDE_DENIED');
SELECT t.error('...also in a quote',format('SELECT public.quote_sale(%L)',t.lines(t.chairs(1,'200.00'))),'PRICE_OVERRIDE_DENIED');
INSERT INTO t.docs SELECT 's2',public.post_sale(t.lines(t.chairs(1,'250.00')),'250.00','s01-sale-0002');
SELECT t.expect('the list price sent back by the client is not an override',t.doc('s2')->'lines'->0->>'unit_price'='250.00');
RESET ROLE;
UPDATE public.products SET cash_price=260 WHERE id=t.id('chair');
SET ROLE authenticated;
SELECT t.error_detail('a price changed after the quote is caught the same way',t.sell(t.lines(t.chairs(1)),'250.00'),'PRICE_CHANGED',
  '{"expected_total":"250.00","total":"260.00"}');
RESET ROLE;
UPDATE public.products SET cash_price=250 WHERE id=t.id('chair');
-- A manager may override: sold at 200, listed in a warning audit row.
SELECT t.as_user('a7040000-0000-0000-8000-000000000007',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'shift_mgr',(public.open_shift(t.id('main'),'0','s01-shift-manager')->>'id')::uuid;
SELECT t.expect('the manager''s quote shows the override',
  (j->'lines'->0->>'overridden')='true' AND j->'lines'->0->>'list_price'='250.00' AND j->>'total'='200.00',j::text)
  FROM (SELECT public.quote_sale(t.lines(t.chairs(1,'200.00'))) j) x;
INSERT INTO t.docs SELECT 's3',public.post_sale(t.lines(t.chairs(1,'200.00')),'200.00','s01-sale-0003');
INSERT INTO t.ids SELECT 's3',(t.doc('s3')->>'id')::uuid;
RESET ROLE;
SELECT t.expect('override: sold at 200.00 with the tax of 200.00, audited as a warning with both prices',
  t.doc('s3')->'lines'->0->>'unit_price'='200.00' AND t.doc('s3')->>'tax_total'='24.56' AND t.doc('s3')->>'shift_id'=t.id('shift_mgr')::text
  AND (SELECT severity='warning' AND after->'price_overrides'->0->>'list_price'='250.00' AND after->'price_overrides'->0->>'unit_price'='200.00'
       FROM public.audit_log WHERE action='sale.created' AND entity_id=t.id('s3')),t.doc('s3')::text);

-- ---------------------------------------------------------------- VAT added on top of the price
UPDATE public.org_settings SET prices_include_vat=false WHERE organization_id=t.org('a');
SELECT t.as_user('a7040000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's4',public.post_sale(t.lines(t.chairs(1),t.phone('S1-IMEI-2')),'5985.00','s01-sale-0004','a7040000-0000-0000-8000-0000000000c1');
SELECT t.expect('VAT on top: subtotal 5 250.00 + tax 735.00 = 5 985.00, snapshot on the sale; the customer is named',
  j->>'prices_include_vat'='false' AND j->>'subtotal'='5250.00' AND j->>'tax_total'='735.00' AND j->>'total'='5985.00'
  AND j->'lines'->0->>'tax_amount'='35.00' AND j->'lines'->0->>'line_total'='285.00' AND j->'lines'->1->>'line_total'='5700.00'
  AND j->>'customer_name'='Mona Buyer' AND j->'payments'->0->>'amount'='5985.00',j::text) FROM t.docs WHERE tag='s4';
RESET ROLE;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id=t.org('a');
SELECT t.as_user('a7040000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('an old sale keeps its own VAT mode after the setting changes',
  (public.get_sale((t.doc('s4')->>'id')::uuid)->>'total')='5985.00' AND (public.get_sale((t.doc('s4')->>'id')::uuid)->>'prices_include_vat')='false');
CREATE TEMP TABLE before_refusals AS SELECT t.footprint() f,t.level('chair') chairs,t.level('phone') phones,t.cash('drawer') drawer;
GRANT SELECT ON before_refusals TO authenticated;

-- ---------------------------------------------------------------- Done when: the last unit can't be sold twice
SELECT t.error_detail('more than is left: 6 chairs when 5 remain',t.sell(t.lines(t.chairs(6)),'1500.00'),'OUT_OF_STOCK',
  jsonb_build_object('product_id',t.id('chair'),'requested',6,'available',5));
SELECT t.error('Done when: the sold IMEI can''t be sold again',t.sell(t.lines(t.phone('S1-IMEI-1')),'5000.00'),'UNIT_NOT_AVAILABLE');
INSERT INTO t.docs SELECT 's5',public.post_sale(t.lines(t.chairs(5)),'1250.00','s01-sale-0005');
SELECT t.error_detail('Done when: the last chair is gone, the next sale is refused',t.sell(t.lines(t.chairs(1)),'250.00'),'OUT_OF_STOCK',
  jsonb_build_object('product_id',t.id('chair'),'requested',1,'available',0));
RESET ROLE;
SELECT t.expect('...the chairs are at exactly 0 and the refused sales took no number',
  t.level('chair')=0 AND (SELECT max(right(number,6)::int) FROM public.sales WHERE organization_id=t.org('a'))=5
  AND (SELECT count(*) FROM public.sales WHERE organization_id=t.org('a'))=5);
UPDATE public.units SET status='reserved' WHERE id=t.unit('S1-IMEI-3');
SET ROLE authenticated;
SELECT t.error('a unit reserved for an order is not sold to a walk-in',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00'),'UNIT_NOT_AVAILABLE');
RESET ROLE;
UPDATE public.units SET status='in_stock' WHERE id=t.unit('S1-IMEI-3');
DROP TABLE before_refusals;
CREATE TEMP TABLE before_refusals AS SELECT t.footprint() f,t.level('chair') chairs,t.level('phone') phones,t.cash('drawer') drawer;
GRANT SELECT ON before_refusals TO authenticated;
SET ROLE authenticated;

-- ---------------------------------------------------------------- refused: the cart
SELECT t.error('cart: empty',t.sell('[]','0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: not a list',t.sell('{"product_id":"x"}','0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: quantity 0',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',0)),'0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: half a chair',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',1.5)),'0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: an unknown field (an organization id)',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',1,'organization_id',t.org('b'))),'0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: a product id that is not a uuid',t.sell(t.lines(jsonb_build_object('product_id','chair','quantity',1)),'0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: a price with three decimals',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',1,'unit_price','1.999')),'1.99'),'VALIDATION_FAILED');
SELECT t.error('cart: a negative price',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',1,'unit_price','-1')),'1.00'),'VALIDATION_FAILED');
SELECT t.error('cart: 101 lines',format('SELECT public.post_sale((SELECT jsonb_agg(%L::jsonb) FROM generate_series(1,101)),%L,%L)',t.phone('S1-IMEI-3'),'1.00','s01-many-lines'),'VALIDATION_FAILED');
SELECT t.error('cart: the same product on two lines',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',1),jsonb_build_object('product_id',t.id('gift'),'quantity',2)),'0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: the same unit on two lines',t.sell(t.lines(t.phone('S1-IMEI-3'),t.phone('S1-IMEI-3')),'10000.00'),'VALIDATION_FAILED');
SELECT t.error('cart: a unit with quantity 2',t.sell(t.lines(jsonb_build_object('product_id',t.id('phone'),'quantity',2,'unit_id',t.unit('S1-IMEI-3'))),'10000.00'),'VALIDATION_FAILED');
SELECT t.error('cart: a total of 0.00',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',1)),'0.00'),'VALIDATION_FAILED');
SELECT t.error('cart: expected_total that is not money',t.sell(t.lines(t.phone('S1-IMEI-3')),'five thousand'),'VALIDATION_FAILED');
SELECT t.error('cart: a system: key',format('SELECT public.post_sale(%L,%L,%L)',t.lines(t.phone('S1-IMEI-3')),'5000.00','system:sale:fake'),'VALIDATION_FAILED');
SELECT t.error('cart: a short key',format('SELECT public.post_sale(%L,%L,%L)',t.lines(t.phone('S1-IMEI-3')),'5000.00','short'),'VALIDATION_FAILED');
-- ---------------------------------------------------------------- refused: products, units, customers
SELECT t.error('an unknown product',t.sell(t.lines(jsonb_build_object('product_id',gen_random_uuid(),'quantity',1)),'1.00'),'PRODUCT_NOT_FOUND');
SELECT t.error('an archived product',t.sell(t.lines(jsonb_build_object('product_id',t.id('old'),'quantity',1)),'10.00'),'PRODUCT_ARCHIVED');
SELECT t.error('a serialized product without its unit',t.sell(t.lines(jsonb_build_object('product_id',t.id('phone'),'quantity',1)),'5000.00'),'UNIT_REQUIRED');
SELECT t.error('a unit on a product without serials',t.sell(t.lines(jsonb_build_object('product_id',t.id('gift'),'quantity',1,'unit_id',t.unit('S1-IMEI-3'))),'0.00'),'UNIT_NOT_ALLOWED');
SELECT t.error('a unit of another product',t.sell(t.lines(jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',t.unit('S1-TAB-1'))),'5000.00'),'UNIT_PRODUCT_MISMATCH');
SELECT t.error('an unknown unit',t.sell(t.lines(jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',gen_random_uuid())),'5000.00'),'UNIT_NOT_FOUND');
SELECT t.error('a unit that is in the other branch',t.sell(t.lines(t.phone('S1-IMEI-9')),'5000.00'),'UNIT_NOT_AVAILABLE');
SELECT t.error('another shop''s product',t.sell(t.lines(jsonb_build_object('product_id',t.id('chair_b'),'quantity',1)),'250.00'),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s customer',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00','buyer_b'),'CUSTOMER_NOT_FOUND');
SELECT t.error('an archived customer',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00','gone'),'CUSTOMER_NOT_FOUND');
SELECT t.error('...also in a quote',format('SELECT public.quote_sale(%L,%L)',t.lines(t.phone('S1-IMEI-3')),t.id('gone')),'CUSTOMER_NOT_FOUND');
-- ---------------------------------------------------------------- who
SELECT t.as_user('a7040000-0000-0000-8000-000000000004',t.org('a'));
SELECT t.error('who: a cashier without an open shift',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00'),'SHIFT_REQUIRED');
SELECT t.error('who: a cashier can''t read another cashier''s sale',format('SELECT public.get_sale(%L)',t.id('s1')),'SALE_NOT_FOUND');
SELECT t.as_user('a7040000-0000-0000-8000-000000000006',t.org('a'));
SELECT t.error('who: a WAREHOUSE user can''t sell',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00'),'PERMISSION_DENIED');
SELECT t.error('who: ...or quote',format('SELECT public.quote_sale(%L)',t.lines(t.phone('S1-IMEI-3'))),'PERMISSION_DENIED');
SELECT t.error('who: ...or read a sale',format('SELECT public.get_sale(%L)',t.id('s1')),'PERMISSION_DENIED');
SELECT t.as_user('a7040000-0000-0000-8000-000000000005',t.org('a'));
SELECT t.error('who: an ACCOUNTANT can''t sell',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00'),'PERMISSION_DENIED');
SELECT t.expect('who: an ACCOUNTANT reads the cashier''s and the manager''s sales',
  (public.get_sale(t.id('s1'))->>'total')='5500.00' AND (public.get_sale(t.id('s3'))->>'total')='200.00');
SELECT t.as_user('a7040000-0000-0000-8000-000000000003',t.org('a'));
SELECT t.expect('who: the cashier reads their own sale',(public.get_sale(t.id('s1'))->>'number')=(t.doc('s1')->>'number'));
SELECT t.error('who: ...and not the manager''s',format('SELECT public.get_sale(%L)',t.id('s3')),'SALE_NOT_FOUND');
SELECT t.error('an unknown sale',format('SELECT public.get_sale(%L)',gen_random_uuid()),'SALE_NOT_FOUND');
RESET ROLE;
SELECT t.expect('every refused call left nothing behind: no document, movement, payment, number or audit row',
  t.footprint()=f AND t.level('chair')=chairs AND t.level('phone')=phones AND t.cash('drawer')=drawer,concat_ws(' ',t.footprint(),f)) FROM before_refusals;

-- ---------------------------------------------------------------- tenancy, expired shop, closed shift, closed day
SELECT t.as_user('a7040000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: a''s sale is not found',format('SELECT public.get_sale(%L)',t.id('s1')),'SALE_NOT_FOUND');
SELECT t.error('no direct writes to sales',format('INSERT INTO public.sales(organization_id,number,branch_id,prices_include_vat,subtotal,total,business_date,idempotency_key) VALUES(%L,%L,%L,true,1,1,current_date,%L)',t.org('b'),'X',t.id('main_b'),'s01-direct-1'),'permission denied for table sales');
SELECT t.error('no direct writes to payments',format('INSERT INTO public.payments(organization_id,number,branch_id,direction,method,amount,business_date,idempotency_key) VALUES(%L,%L,%L,%L,%L,1,current_date,%L)',t.org('b'),'X',t.id('main_b'),'in','cash','s01-direct-2'),'permission denied for table payments');
RESET ROLE;
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a7040000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired shop: a quote and a sale still read',
  (public.quote_sale(t.lines(t.phone('S1-IMEI-3')))->>'total')='5000.00' AND (public.get_sale(t.id('s1'))->>'total')='5500.00');
SELECT t.error('expired shop: no new sale',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
-- The cashier closes the shift with what the drawer holds: no more sales on it.
SELECT t.as_user('a7040000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('the shift expects every sale of the cashier: 5 500 + 250 + 5 985 + 1 250',t.expected('shift')='12985.00',t.expected('shift'));
SELECT public.close_shift(t.id('shift'),'{"200":64,"100":1,"50":1,"20":1,"10":1,"5":1}',t.id('safe'));
SELECT t.error('closed shift: no open shift to sell in',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00'),'SHIFT_REQUIRED');
RESET ROLE;
-- A closed day refuses a sale (the manager's shift is still open).
INSERT INTO public.day_closes(organization_id,branch_id,business_date,closed_by)
SELECT t.org('a'),t.id('main'),app.org_today(t.org('a')),t.id('mgr');
SELECT t.as_user('a7040000-0000-0000-8000-000000000007',t.org('a'));
SET ROLE authenticated;
SELECT t.error('closed day: no sale',t.sell(t.lines(t.phone('S1-IMEI-3')),'5000.00'),'DAY_CLOSED');
RESET ROLE;

-- ---------------------------------------------------------------- Done when: the four ledger / reconciliation checks
SELECT t.expect('Done when 1: every stock level = the sum of its ledger, none below zero',t.bad_stock() IS NULL,t.bad_stock());
SELECT t.expect('Done when 2: every cash balance = the sum of its ledger, none below zero',t.bad_cash() IS NULL,t.bad_cash());
SELECT t.expect('Done when 3: app.ledger_mismatches finds nothing in the shop',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
SELECT t.expect('Done when 4: the sales'' totals = their payments = the drawers'' sale movements (13 185.00)',
  t.money()='13185.00/13185.00/13185.00',t.money());
SELECT t.expect('the safe received the closed shift''s cash',t.cash('safe')=12985.00 AND t.cash('drawer')=0,concat_ws(' ',t.cash('safe'),t.cash('drawer')));
SELECT t.expect('grants: the three functions for authenticated, not anon; helpers not granted',
  has_function_privilege('authenticated','public.post_sale(jsonb,text,text,uuid,jsonb,jsonb,text,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.quote_sale(jsonb,uuid,jsonb,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_sale(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_sale(jsonb,text,text,uuid,jsonb,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.post_sale_core(uuid,uuid,public.shifts,jsonb,uuid,numeric,text,jsonb,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.sale_cart(uuid,uuid,jsonb,boolean,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.sale_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.post_sale_payments(public.sales,public.shifts,uuid,jsonb,numeric)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
