-- S10 sales orders, part 1 (O1-O8, O13, O14).
-- Run by: node scripts/db-smoke.mjs supabase/tests/s10_sales_orders_test.sql (inside BEGIN ... ROLLBACK).
-- A cashier creates orders (direct and from an accepted quote) that hold stock at once, links
-- to-order lines to purchase order lines, reserves them when stock arrives, and a reserved unit or
-- quantity can't be sold at the till or moved by a direct stock insert (decision 5).
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE FUNCTION t.pos(p_branch uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_org uuid := app.current_org_id(); v_id uuid; v_hash text;
BEGIN
  INSERT INTO public.devices (organization_id, branch_id, name) VALUES (v_org, p_branch, 'Test POS ' || gen_random_uuid()) RETURNING id INTO v_id;
  UPDATE public.devices d SET token_hash = encode(sha256(convert_to(d.id::text, 'UTF8')), 'hex'), paired_at = now()
   WHERE d.id = v_id RETURNING d.token_hash INTO v_hash;
  PERFORM set_config('request.headers', (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb
       || jsonb_build_object('x-device-id', v_id, 'x-device-token-hash', v_hash))::text, false);
  RETURN v_id;
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
CREATE FUNCTION t.oid(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j->>'id')::uuid FROM t.docs WHERE tag=s $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.units WHERE serial=s $$;
CREATE FUNCTION t.unit_status(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT status::text FROM public.units WHERE serial=s $$;
CREATE FUNCTION t.line(o text,n integer) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.sales_order_lines WHERE order_id=t.oid(o) AND line_no=n $$;
CREATE FUNCTION t.reserved(p text,b text DEFAULT 'main') RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT reserved FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0)::integer $$;
CREATE FUNCTION t.on_hand(p text,b text DEFAULT 'main') RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0)::integer $$;
CREATE FUNCTION t.res(o text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('line_no',l.line_no,'quantity',r.quantity,'unit',u.serial) ORDER BY l.line_no,u.serial),'[]')
  FROM public.stock_reservations r JOIN public.sales_order_lines l ON l.id=r.order_line_id LEFT JOIN public.units u ON u.id=r.unit_id
  WHERE l.order_id=t.oid(o) AND r.status='active' $$;
CREATE FUNCTION t.audits(o text,a text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT count(*) FROM public.audit_log WHERE entity_id=t.oid(o) AND action=a $$;
CREATE FUNCTION t.ln(p text,q integer,price text,f text DEFAULT NULL,units text[] DEFAULT NULL,po text DEFAULT NULL,disc text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('product_id',t.id(p),'quantity',q,'unit_price',price,'fulfilment',f,'discount_amount',disc,'po_line_id',t.id(po),
    'unit_ids',(SELECT jsonb_agg(t.unit(s) ORDER BY s) FROM unnest(units) s))) $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.mk(key text,lines jsonb,branch text DEFAULT 'main',customer text DEFAULT 'mona') RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.create_sales_order(%L,%L,%L,NULL,%L,%L)',t.id(branch),t.id(customer),'12 Nile St',lines,key) $$;
CREATE FUNCTION t.order(tag text,key text,lines jsonb,branch text DEFAULT 'main',customer text DEFAULT 'mona') RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN EXECUTE t.mk(key,lines,branch,customer) INTO j; INSERT INTO t.docs VALUES(tag,j); END $$;
CREATE FUNCTION t.sell(lines jsonb,expected text) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_sale(%L,%L,%L)',lines,expected,'s10-'||md5(random()::text)) $$;
\ir helpers/test4_snapshot.sql
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (two branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S10 '||s,'s10-'||s,'retail_pro','Owner',s||'s10@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('w',64)),('b',repeat('x',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a7100000-0000-0000-8000-000000000001','as10@example.com'),('a7100000-0000-0000-8000-000000000002','bs10@example.com'),
  ('a7100000-0000-0000-8000-000000000003','s10cashier@example.com');
SELECT public.accept_invite(repeat('w',64),'a7100000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('x',64),'a7100000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,discount_caps='{"CASHIER":5}' WHERE organization_id=t.org('a');
SELECT t.as_user('a7100000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"S10-CH","cash_price":"100"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"هاتف","name_en":"Phone","sku":"S10-PH","cash_price":"5000","is_serialized":true}'));
INSERT INTO t.ids VALUES('sofa',public.create_product('{"name_ar":"كنبة","name_en":"Sofa","sku":"S10-SF","cash_price":"380"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',10)),'s10-found-chairs');
SELECT public.register_units(t.id('phone'),t.id('main'),'3000.00','["S10-IMEI-1","S10-IMEI-2","S10-IMEI-3"]',NULL,'s10-phones');
RESET ROLE;
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id)
  VALUES(t.org('a'),'a7100000-0000-0000-8000-000000000003','S10 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
INSERT INTO t.ids VALUES('cashier',:'cashier_id');
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted)
  VALUES(t.org('a'),t.id('cashier'),'price.override',false),(t.org('a'),t.id('cashier'),'discount.above_cap',false)
  ON CONFLICT(employee_id,permission_key) DO UPDATE SET granted=excluded.granted;
INSERT INTO public.customers(id,organization_id,full_name,phones,national_id) VALUES
  ('a7100000-0000-0000-8000-0000000000c1',t.org('a'),'Mona Buyer',ARRAY['01012345678'],'29001010101010'),
  ('a7100000-0000-0000-8000-0000000000c2',t.org('b'),'Shop B Buyer',ARRAY['01112345678'],NULL);
INSERT INTO t.ids VALUES('mona','a7100000-0000-0000-8000-0000000000c1'),('buyer_b','a7100000-0000-0000-8000-0000000000c2');
-- Purchase orders (U05 tables, written directly): open sofa x2, chair x5, cancelled sofa x5, open sofa x1; shop b's.
INSERT INTO public.suppliers(organization_id,name) VALUES(t.org('a'),'S10 Supplier') RETURNING id AS sup_a \gset
DO $$ DECLARE v_po uuid; v_pol uuid; r record; BEGIN
  FOR r IN SELECT * FROM (VALUES('pol_open','sofa',2,'sent'),('pol_chair','chair',5,'sent'),('pol_cancel','sofa',5,'cancelled'),('pol_new','sofa',1,'draft')) v(tag,p,q,st) LOOP
    INSERT INTO public.purchase_orders(organization_id,number,supplier_id,branch_id,status,idempotency_key)
      VALUES(t.org('a'),'S10-PO-'||r.tag,(SELECT id FROM public.suppliers WHERE organization_id=t.org('a') AND name='S10 Supplier'),t.id('main'),
             CASE WHEN r.st='draft' THEN 'draft' ELSE 'sent' END::public.po_status,'s10-po-'||r.tag) RETURNING id INTO v_po;
    INSERT INTO public.purchase_order_lines(organization_id,po_id,product_id,quantity) VALUES(t.org('a'),v_po,t.id(r.p),r.q) RETURNING id INTO v_pol;
    INSERT INTO t.ids VALUES(r.tag,v_pol);
    IF r.st='cancelled' THEN UPDATE public.purchase_orders SET status='cancelled' WHERE id=v_po; END IF;
  END LOOP;
END $$;
-- Shop b: a serialized product, a sofa, and a PO line of its own.
SELECT t.as_user('a7100000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('phone_b',public.create_product('{"name_ar":"هاتف ب","sku":"S10B-PH","cash_price":"5000","is_serialized":true}'));
INSERT INTO t.ids VALUES('sofa_b',public.create_product('{"name_ar":"كنبة ب","sku":"S10B-SF","cash_price":"380"}'));
RESET ROLE;
INSERT INTO public.suppliers(organization_id,name) VALUES(t.org('b'),'S10 B Supplier') RETURNING id AS sup_b \gset
INSERT INTO public.purchase_orders(organization_id,number,supplier_id,branch_id,status,idempotency_key)
  VALUES(t.org('b'),'S10B-PO-1',:'sup_b',t.id('main_b'),'sent','s10b-po-1') RETURNING id AS po_b \gset
WITH x AS (INSERT INTO public.purchase_order_lines(organization_id,po_id,product_id,quantity) VALUES(t.org('b'),:'po_b',t.id('sofa_b'),9) RETURNING id) INSERT INTO t.ids SELECT 'pol_b',id FROM x;
SELECT t.expect('setup: 10 chairs, 3 phones in main, nothing reserved',t.on_hand('chair')=10 AND t.on_hand('phone')=3 AND t.reserved('chair')=0,
  concat_ws(' ',t.on_hand('chair'),t.on_hand('phone'),t.reserved('chair')));

-- ---------------------------------------------------------------- O1 create: reserve at once
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.order('o1','s10-order-0001',t.lines(t.ln('chair',3,'100'),t.ln('phone',2,'5000',NULL,ARRAY['S10-IMEI-1','S10-IMEI-2']),t.ln('sofa',1,'380','to_order')));
SELECT t.expect('O1 number SO, open, 3 lines, customer name and phone only',
  j->>'number' LIKE 'MAIN-SO-%' AND j->>'status'='open' AND jsonb_array_length(j->'lines')=3
  AND j->'customer'='{"id":"a7100000-0000-0000-8000-0000000000c1","name":"Mona Buyer","phone":"01012345678"}'::jsonb
  AND position('29001010101010' IN j::text)=0 AND NOT (j ? 'organization_id') AND NOT (j ? 'idempotency_key'),j::text) FROM t.docs WHERE tag='o1';
SELECT t.expect('O1 lines carry fulfilment numbers, reserved serials, money as text',
  j->'lines'->0->>'reserved'='3' AND j->'lines'->1->>'reserved'='2' AND j->'lines'->2->>'reserved'='0' AND j->'lines'->2->>'fulfilment'='to_order'
  AND j->'lines'->1->'reserved_units'->0->>'serial'='S10-IMEI-1' AND jsonb_array_length(j->'lines'->1->'reserved_units')=2
  AND j->'lines'->0->>'unit_price'='100.00' AND j->'lines'->2->'purchase_order'='null'::jsonb AND j->'payments'='[]'::jsonb
  AND j->'balances'->>'deposits_paid'='0.00' AND j->'balances'->>'unpaid'=j->>'total',j::text) FROM t.docs WHERE tag='o1';
SELECT t.expect('O1 replay of the key returns the same order',(t.doc('o1')->>'id')=(public.create_sales_order(t.id('main'),t.id('mona'),NULL,NULL,'[]','s10-order-0001')->>'id'));
RESET ROLE;
SELECT t.expect('O1 totals per T01',
  (SELECT j->>'total'=x->>'total' AND j->>'tax_total'=x->>'tax_total' AND j->>'subtotal'='10680.00'
     AND j->'lines'->1->>'tax_amount'=x->'lines'->1->>'tax' AND j->'lines'->1->>'line_total'=x->'lines'->1->>'gross'
   FROM t.docs, LATERAL (SELECT app.compute_document_tax(jsonb_build_object('prices_include_vat',true,'document_discount','0','lines',jsonb_build_array(
     jsonb_build_object('unit_price','100','quantity',3,'line_discount','0','tax_rate',j->'lines'->0->>'tax_rate'),
     jsonb_build_object('unit_price','5000','quantity',2,'line_discount','0','tax_rate',j->'lines'->1->>'tax_rate'),
     jsonb_build_object('unit_price','380','quantity',1,'line_discount','0','tax_rate',j->'lines'->2->>'tax_rate')))) x) c WHERE tag='o1'));
SELECT t.expect('O1 three reservations (1 + 2 units), levels up, units reserved, to_order line unreserved, one audit',
  t.res('o1')='[{"line_no":1,"unit":null,"quantity":3},{"line_no":2,"unit":"S10-IMEI-1","quantity":1},{"line_no":2,"unit":"S10-IMEI-2","quantity":1}]'::jsonb
  AND t.reserved('chair')=3 AND t.reserved('phone')=2 AND t.unit_status('S10-IMEI-1')='reserved' AND t.unit_status('S10-IMEI-2')='reserved'
  AND t.unit_status('S10-IMEI-3')='in_stock' AND t.reserved('sofa')=0 AND t.audits('o1','sales_order.created')=1,t.res('o1')::text);

-- ---------------------------------------------------------------- O2 refusals roll back everything
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('O2 not enough stock (second line) rolls back the first',t.mk('s10-o2-short',t.lines(t.ln('chair',2,'100'),t.ln('chair',6,'100'))),'NOT_ENOUGH_STOCK_TO_RESERVE');
SELECT t.unchanged('O2 serialized line with the wrong unit count',t.mk('s10-o2-units',t.lines(t.ln('chair',1,'100'),t.ln('phone',2,'5000',NULL,ARRAY['S10-IMEI-3']))),'UNITS_REQUIRED');
SELECT t.unchanged('O2 serialized line without units',t.mk('s10-o2-nounits',t.lines(t.ln('phone',1,'5000'))),'UNITS_REQUIRED');
SELECT t.unchanged('O2 a reserved unit can''t be reserved again',t.mk('s10-o2-taken',t.lines(t.ln('phone',1,'5000',NULL,ARRAY['S10-IMEI-1']))),'UNIT_NOT_AVAILABLE_TO_RESERVE');
SELECT t.error('O2 zero lines',t.mk('s10-o2-zero','[]'),'ORDER_LINES_INVALID');
SELECT t.error('O2 201 lines',t.mk('s10-o2-many',(SELECT jsonb_agg(t.ln('sofa',1,'380','to_order')) FROM generate_series(1,201))),'ORDER_LINES_INVALID');
SELECT t.error('O2 units on a to_order line',t.mk('s10-o2-mixed',t.lines(t.ln('phone',1,'5000','to_order',ARRAY['S10-IMEI-3']))),'ORDER_LINES_INVALID');
SELECT t.error('O2 bad fulfilment',t.mk('s10-o2-badf',t.lines(t.ln('sofa',1,'380','later'))),'ORDER_LINES_INVALID');
SELECT t.error('O2 customer required',format('SELECT public.create_sales_order(%L,NULL,NULL,NULL,%L,''s10-o2-nocust'')',t.id('main'),t.lines(t.ln('sofa',1,'380','to_order'))),'CUSTOMER_NOT_FOUND');

-- ---------------------------------------------------------------- O3 price and discount rules (as S09 Q4/Q5)
SELECT t.error('O3 override required',t.mk('s10-o3-price',t.lines(t.ln('sofa',1,'300','to_order'))),'PRICE_OVERRIDE_REQUIRED');
SELECT t.error('O3 above cap',t.mk('s10-o3-cap',t.lines(t.ln('sofa',1,'380','to_order',NULL,NULL,'20'))),'DISCOUNT_ABOVE_CAP');
SELECT t.order('o3cap','s10-o3-capok',t.lines(t.ln('sofa',1,'380','to_order',NULL,NULL,'19')));
SELECT t.expect('O3 within cap: discount kept, total = 380 - 19',t.doc('o3cap')->>'discount_total'='19.00' AND t.doc('o3cap')->>'total'='361.00',t.doc('o3cap')::text);
RESET ROLE;
UPDATE public.employee_permission_overrides SET granted=true WHERE employee_id=t.id('cashier') AND permission_key IN('price.override','discount.above_cap');
SET ROLE authenticated;
SELECT t.order('o3ovr','s10-o3-override',t.lines(t.ln('sofa',1,'300','to_order',NULL,NULL,'100')));
SELECT t.expect('O3 price.override and discount.above_cap allow it',t.doc('o3ovr')->'lines'->0->>'unit_price'='300.00' AND t.doc('o3ovr')->>'total'='200.00',t.doc('o3ovr')::text);
RESET ROLE;
UPDATE public.employee_permission_overrides SET granted=false WHERE employee_id=t.id('cashier') AND permission_key IN('price.override','discount.above_cap');

-- ---------------------------------------------------------------- O4 from an accepted quote
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'q',(public.create_quotation(t.id('main'),t.id('mona'),NULL,'Q',t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',1,'unit_price','100','discount_amount','5'),
  jsonb_build_object('description','Made to order','custom_notes','Fabric A','quantity',1,'unit_price','500')),'s10-quote-1')->>'id')::uuid;
SELECT t.error('O4 draft quote',format('SELECT public.create_order_from_quotation(%L,NULL,NULL,''s10-o4-draft'')',t.id('q')),'QUOTATION_NOT_ACCEPTED');
SELECT public.send_quotation(t.id('q'));
SELECT t.error('O4 sent quote',format('SELECT public.create_order_from_quotation(%L,NULL,NULL,''s10-o4-sent'')',t.id('q')),'QUOTATION_NOT_ACCEPTED');
SELECT public.accept_quotation(t.id('q'));
SELECT t.error('O4 custom line without a product',format('SELECT public.create_order_from_quotation(%L,NULL,NULL,''s10-o4-nomap'')',t.id('q')),'QUOTE_LINE_NEEDS_PRODUCT');
SELECT t.error('O4 options for a line that does not exist',format('SELECT public.create_order_from_quotation(%L,NULL,%L,''s10-o4-badkey'')',t.id('q'),
  jsonb_build_object('2',jsonb_build_object('product_id',t.id('sofa'),'fulfilment','to_order'),'9','{}'::jsonb)),'ORDER_LINES_INVALID');
INSERT INTO t.docs SELECT 'o4',public.create_order_from_quotation(t.id('q'),'Giza',jsonb_build_object('2',jsonb_build_object('product_id',t.id('sofa'),'fulfilment','to_order')),'s10-o4-ok');
SELECT t.error('O4 second order for the quote',format('SELECT public.create_order_from_quotation(%L,NULL,%L,''s10-o4-again'')',t.id('q'),
  jsonb_build_object('2',jsonb_build_object('product_id',t.id('sofa'),'fulfilment','to_order'))),'QUOTATION_ALREADY_ORDERED');
SELECT t.expect('O4 replay returns the same order',public.create_order_from_quotation(t.id('q'),NULL,NULL,'s10-o4-ok')->>'id'=t.doc('o4')->>'id');
RESET ROLE;
SELECT t.expect('O4 header copied exactly',
  (SELECT o.customer_id=q.customer_id AND o.branch_id=q.branch_id AND o.prices_include_vat=q.prices_include_vat AND o.subtotal=q.subtotal
     AND o.discount_total=q.discount_total AND o.tax_total=q.tax_total AND o.total=q.total AND o.quotation_id=q.id AND o.delivery_address='Giza'
   FROM public.sales_orders o JOIN public.quotations q ON q.id=t.id('q') WHERE o.id=t.oid('o4')));
SELECT t.expect('O4 lines copied exactly (quantity, prices, discount, tax class, rate, tax, total)',
  (SELECT count(*)=2 AND bool_and(l.quantity=ql.quantity AND l.unit_price=ql.unit_price AND l.discount_amount=ql.discount_amount AND l.tax_class_id=ql.tax_class_id
     AND l.tax_rate=ql.tax_rate AND l.tax_amount=ql.tax_amount AND l.line_total=ql.line_total)
   FROM public.sales_order_lines l JOIN public.quotation_lines ql ON ql.quotation_id=t.id('q') AND ql.line_no=l.line_no WHERE l.order_id=t.oid('o4')));
SELECT t.expect('O4 mapped custom line: product, notes "description — notes", to_order; product line reserved from stock',
  (SELECT l.product_id=t.id('sofa') AND l.custom_notes='Made to order — Fabric A' AND l.fulfilment='to_order' FROM public.sales_order_lines l WHERE l.order_id=t.oid('o4') AND l.line_no=2)
  AND t.res('o4')='[{"line_no":1,"unit":null,"quantity":1}]'::jsonb AND t.reserved('chair')=4 AND t.doc('o4')->'quotation'->>'id'=t.id('q')::text,t.res('o4')::text);
SELECT t.error('O4 the unique index holds on the direct path',format('INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,quotation_id,prices_include_vat,subtotal,total,idempotency_key) VALUES(%L,''X-SO-1'',%L,%L,%L,true,0,0,''s10-direct-dup'')',
  t.org('a'),t.id('mona'),t.id('main'),t.id('q')),'duplicate key value violates unique constraint "sales_orders_quotation_key"');

-- ---------------------------------------------------------------- O5 / O6 the till and the stock ledger
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.pos(t.id('main'));
SELECT public.open_shift(t.id('main'),'0','s10-shift-cashier',NULL,NULL);
INSERT INTO t.docs SELECT 'sale6',public.post_sale(t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',6)),'600.00','s10-sale-0001');
SELECT t.expect('O5 the last non-reserved quantity sells (10 on hand, 4 reserved)',t.doc('sale6')->>'id' IS NOT NULL);
SELECT t.error('O5 one more is out of stock',t.sell(t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',1)),'100.00'),'OUT_OF_STOCK');
SELECT t.error('O5 a reserved serial is refused at the till',t.sell(t.lines(jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',t.unit('S10-IMEI-1'))),'5000.00'),'UNIT_NOT_AVAILABLE');
RESET ROLE;
SELECT t.error('O5 decision 5: a direct sale_out of a reserved unit is refused by the stock trigger',
  format('INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,source_type,source_id,business_date) VALUES(%L,%L,%L,%L,-1,''sale_out'',''sale'',gen_random_uuid(),current_date)',
    t.org('a'),t.id('phone'),t.id('main'),t.unit('S10-IMEI-2')),'UNIT_NOT_AVAILABLE');
SELECT t.expect('O5 reserved units and levels untouched',t.unit_status('S10-IMEI-2')='reserved' AND t.on_hand('phone')=3 AND t.reserved('chair')=4 AND t.on_hand('chair')=4);
UPDATE public.stock_reservations SET status='released',released_at=now(),updated_at=now() WHERE unit_id=t.unit('S10-IMEI-2') AND status='active';
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'sale_imei2',public.post_sale(t.lines(jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',t.unit('S10-IMEI-2'))),'5000.00','s10-sale-0002');
RESET ROLE;
SELECT t.expect('O6 released first, then the same unit sells',t.doc('sale_imei2')->>'id' IS NOT NULL AND t.unit_status('S10-IMEI-2')='sold' AND t.reserved('phone')=1);

-- ---------------------------------------------------------------- O7 link to a purchase order line
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.order('x','s10-order-x',t.lines(t.ln('sofa',1,'380','to_order'),t.ln('sofa',2,'380','to_order')));
INSERT INTO t.docs SELECT 'link1',public.link_order_line_to_po(t.line('o1',3),t.id('pol_open'));
SELECT t.expect('O7 linked: the line shows its PO number and status',
  (SELECT l->>'po_line_id'=t.id('pol_open')::text AND l->'purchase_order'->>'number'='S10-PO-pol_open' AND l->'purchase_order'->>'status'='sent'
   FROM jsonb_array_elements(t.doc('link1')->'lines') l WHERE l->>'line_no'='3'),t.doc('link1')::text);
SELECT t.error('O7 another product',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('x',1),t.id('pol_chair')),'PO_LINE_PRODUCT_MISMATCH');
SELECT t.error('O7 a cancelled PO',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('x',1),t.id('pol_cancel')),'PO_NOT_OPEN');
SELECT t.error('O7 over the PO line quantity (1 linked + 2 > 2)',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('x',2),t.id('pol_open')),'PO_LINE_OVERCOMMITTED');
SELECT public.link_order_line_to_po(t.line('x',1),t.id('pol_open'));
SELECT t.error('O7 another shop''s PO line',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('x',2),t.id('pol_b')),'PO_NOT_FOUND');
SELECT t.error('O7 a from_stock line',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('o1',1),t.id('pol_chair')),'LINE_NOT_TO_ORDER');
SELECT t.order('y','s10-order-y',t.lines(t.ln('sofa',1,'380','to_order',NULL,'pol_new')));
SELECT t.error('O7 a PO line on a from_stock line at creation',t.mk('s10-o7-fs',t.lines(t.ln('sofa',1,'380','from_stock',NULL,'pol_new'))),'ORDER_LINES_INVALID');
SELECT t.error('O7 creation runs the same checks',t.mk('s10-o7-over',t.lines(t.ln('sofa',1,'380','to_order',NULL,'pol_new'))),'PO_LINE_OVERCOMMITTED');
RESET ROLE;
SELECT t.expect('O7 two links in place and audited, created link stored',
  (SELECT count(*)=2 FROM public.sales_order_lines WHERE po_line_id=t.id('pol_open')) AND t.audits('o1','sales_order.line_linked')=1 AND t.audits('x','sales_order.line_linked')=1
  AND (SELECT po_line_id=t.id('pol_new') FROM public.sales_order_lines WHERE id=t.line('y',1)));
UPDATE public.sales_orders SET status='cancelled',cancelled_reason='S10 test' WHERE id=t.oid('y');
SET ROLE authenticated;
SELECT t.error('O7 order not open',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('y',1),t.id('pol_open')),'ORDER_NOT_OPEN');
SELECT t.error('O8 order not open',format('SELECT public.reserve_order_line(%L)',t.line('y',1)),'ORDER_NOT_OPEN');

-- ---------------------------------------------------------------- O8 reserve a to_order line when stock arrives
SELECT t.error('O8 before stock arrives',format('SELECT public.reserve_order_line(%L)',t.line('x',1)),'NOT_ENOUGH_STOCK_TO_RESERVE');
RESET ROLE;
SELECT t.as_user('a7100000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('sofa'),'quantity',2)),'s10-found-sofas');
RESET ROLE;
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'o8',public.reserve_order_line(t.line('x',1));
SELECT t.error('O8 reserving it again',format('SELECT public.reserve_order_line(%L)',t.line('x',1)),'LINE_NOT_TO_ORDER');
SELECT t.error('O8 units on a non-serialized line',format('SELECT public.reserve_order_line(%L,%L)',t.line('x',2),ARRAY[t.unit('S10-IMEI-3')]),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('O8 one reservation, the line is from_stock, audited',
  t.res('x')='[{"line_no":1,"unit":null,"quantity":1}]'::jsonb AND (SELECT fulfilment='from_stock' FROM public.sales_order_lines WHERE id=t.line('x',1))
  AND t.reserved('sofa')=1 AND t.audits('x','sales_order.line_reserved')=1 AND (SELECT l->>'fulfilment' FROM jsonb_array_elements(t.doc('o8')->'lines') l WHERE l->>'line_no'='1')='from_stock',t.res('x')::text);

-- ---------------------------------------------------------------- O13 two orders for the last quantity / unit
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.order('p','s10-order-p',t.lines(t.ln('sofa',1,'380')));
SELECT t.error('O13 the second order for the last sofa',t.mk('s10-order-q',t.lines(t.ln('sofa',1,'380'))),'NOT_ENOUGH_STOCK_TO_RESERVE');
SELECT t.order('r','s10-order-r',t.lines(t.ln('phone',1,'5000',NULL,ARRAY['S10-IMEI-3'])));
SELECT t.error('O13 the second order for the last unit',t.mk('s10-order-s',t.lines(t.ln('phone',1,'5000',NULL,ARRAY['S10-IMEI-3']))),'UNIT_NOT_AVAILABLE_TO_RESERVE');
RESET ROLE;
SELECT t.expect('O13 one winner each: reserved = on hand, never above',t.reserved('sofa')=2 AND t.on_hand('sofa')=2 AND t.reserved('phone')=2 AND t.on_hand('phone')=2
  AND t.res('p')<>'[]'::jsonb AND t.res('r')<>'[]'::jsonb,concat_ws(' ',t.reserved('sofa'),t.on_hand('sofa'),t.reserved('phone'),t.on_hand('phone')));

-- ---------------------------------------------------------------- O14 direct-database security
SELECT t.as_user('a7100000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.order('sec','s10-order-sec',t.lines(t.ln('sofa',1,'380','to_order')),'second');
SELECT t.expect('O14 the owner reads the other branch''s order directly',(SELECT count(*)=1 FROM public.sales_orders WHERE id=t.oid('sec')));
RESET ROLE;
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('O14 create on a branch without access',t.mk('s10-o14-branch',t.lines(t.ln('sofa',1,'380','to_order')),'second'),'BRANCH_DENIED');
SELECT t.error('O14 get on a branch without access',format('SELECT public.get_sales_order(%L)',t.oid('sec')),'ORDER_NOT_FOUND');
SELECT t.error('O14 list on a branch without access',format('SELECT public.list_sales_orders(NULL,%L)',t.id('second')),'BRANCH_DENIED');
SELECT t.error('O14 link on a branch without access',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('sec',1),t.id('pol_open')),'BRANCH_DENIED');
SELECT t.error('O14 reserve on a branch without access',format('SELECT public.reserve_order_line(%L)',t.line('sec',1)),'BRANCH_DENIED');
SELECT t.expect('O14 RLS: no direct read of the other branch''s order, lines or reservations',
  (SELECT count(*)=0 FROM public.sales_orders WHERE id=t.oid('sec')) AND (SELECT count(*)=0 FROM public.sales_order_lines WHERE order_id=t.oid('sec'))
  AND (SELECT count(*)>0 FROM public.sales_orders WHERE id=t.oid('o1')) AND (SELECT count(*)>0 FROM public.stock_reservations));
SELECT t.expect('O14 list: own branch only, filters and search',
  (SELECT (l->>'total')::int>=6 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(l->'items') i WHERE i->>'id'=t.oid('sec')::text) FROM (SELECT public.list_sales_orders(p_limit=>100) l) x)
  AND (public.list_sales_orders('cancelled')->>'total')='1' AND (public.list_sales_orders(p_search=>'0101234')->>'total')::int>=6
  AND (public.list_sales_orders(p_search=>t.doc('o1')->>'number')->>'total')='1');
DO $$ DECLARE tb text; BEGIN FOREACH tb IN ARRAY ARRAY['sales_orders','sales_order_lines','stock_reservations','payments','payment_allocations'] LOOP
  PERFORM t.error('O14 no direct insert '||tb,format('INSERT INTO public.%I DEFAULT VALUES',tb),'permission denied for table '||tb);
  PERFORM t.error('O14 no direct update '||tb,format('UPDATE public.%I SET organization_id=organization_id',tb),'permission denied for table '||tb);
  PERFORM t.error('O14 no direct delete '||tb,format('DELETE FROM public.%I',tb),'permission denied for table '||tb);
END LOOP; END $$;
RESET ROLE;
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),t.id('cashier'),'order.manage',false)
  ON CONFLICT(employee_id,permission_key) DO UPDATE SET granted=false;
SET ROLE authenticated;
SELECT t.error('O14 permission: create',t.mk('s10-o14-perm',t.lines(t.ln('sofa',1,'380','to_order'))),'PERMISSION_DENIED');
SELECT t.error('O14 permission: from quote',format('SELECT public.create_order_from_quotation(%L,NULL,NULL,''s10-o14-permq'')',t.id('q')),'PERMISSION_DENIED');
SELECT t.error('O14 permission: link',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('x',2),t.id('pol_open')),'PERMISSION_DENIED');
SELECT t.error('O14 permission: reserve',format('SELECT public.reserve_order_line(%L)',t.line('x',2)),'PERMISSION_DENIED');
SELECT t.error('O14 permission: get',format('SELECT public.get_sales_order(%L)',t.oid('o1')),'PERMISSION_DENIED');
SELECT t.error('O14 permission: list','SELECT public.list_sales_orders()','PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a7100000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('O14 other shop: order',format('SELECT public.get_sales_order(%L)',t.oid('o1')),'ORDER_NOT_FOUND');
SELECT t.error('O14 other shop: customer',t.mk('s10-o14-cust',t.lines(t.ln('sofa_b',1,'380','to_order')),'main_b','mona'),'CUSTOMER_NOT_FOUND');
SELECT t.error('O14 other shop: product',t.mk('s10-o14-prod',t.lines(t.ln('sofa',1,'380','to_order')),'main_b','buyer_b'),'PRODUCT_NOT_FOUND');
SELECT t.error('O14 other shop: unit',t.mk('s10-o14-unit',t.lines(t.ln('phone_b',1,'5000',NULL,ARRAY['S10-IMEI-3'])),'main_b','buyer_b'),'UNIT_NOT_FOUND');
SELECT t.error('O14 other shop: link a line',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('x',2),t.id('pol_b')),'ORDER_NOT_FOUND');
SELECT t.error('O14 other shop: reserve a line',format('SELECT public.reserve_order_line(%L)',t.line('x',2)),'ORDER_NOT_FOUND');
SELECT t.error('O14 other shop: quote',format('SELECT public.create_order_from_quotation(%L,NULL,NULL,''s10-o14-quote'')',t.id('q')),'QUOTATION_NOT_FOUND');
SELECT t.order('b1','s10-order-b1',t.lines(t.ln('sofa_b',1,'380','to_order')),'main_b','buyer_b');
SELECT t.error('O14 other shop: PO line',format('SELECT public.link_order_line_to_po(%L,%L)',t.line('b1',1),t.id('pol_open')),'PO_NOT_FOUND');
SELECT t.expect('O14 other shop: list and direct reads show none of shop a',(public.list_sales_orders()->>'total')='1'
  AND (SELECT count(*)=0 FROM public.sales_orders WHERE organization_id=t.org('a')) AND (SELECT count(*)=0 FROM public.stock_reservations WHERE organization_id=t.org('a')));
RESET ROLE;
SELECT t.expect('O14 grants: public functions for authenticated only; helpers for nobody',
  has_function_privilege('authenticated','public.create_sales_order(uuid,uuid,text,text,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.create_sales_order(uuid,uuid,text,text,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_sales_order(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.s10_price(jsonb,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.s10_reserve_line(uuid,uuid,public.sales_order_lines,uuid,uuid[])','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.s10_link(uuid,public.sales_order_lines,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.s10_fulfil(uuid,uuid,public.sales_orders,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.s10_line_options(jsonb)','EXECUTE'));
SELECT t.expect('reconciliation: app.ledger_mismatches finds nothing in shop a',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));

-- ================================================================ part 2 (O9-O12, O14, O15): deposits and cancelling
-- The cashier takes deposits in the shift opened above; a branch manager (main only) runs a shift
-- of its own and cancels; the owner (no shift) cancels where no cash goes back.
CREATE FUNCTION t.dep(o text,pay jsonb,key text) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.record_order_deposit(%L,%L,%L)',t.oid(o),pay,key) $$;
CREATE FUNCTION t.cancel(o text,reason text,refund jsonb,key text) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.cancel_sales_order(%L,%L,%L,%L)',t.oid(o),reason,refund,key) $$;
CREATE FUNCTION t.run(tag text,q text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN EXECUTE q INTO j; INSERT INTO t.docs VALUES(tag,j); END $$;
CREATE FUNCTION t.pay(m text,a text,x jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method',m,'amount',a)||x $$;
CREATE FUNCTION t.bal(a uuid) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=a),0) $$;
CREATE FUNCTION t.credit(c text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.store_credit_balances WHERE customer_id=t.id(c)),0) $$;
CREATE FUNCTION t.drawer(e text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT drawer_account_id FROM public.shifts WHERE employee_id=t.id(e) AND status='open' $$;
CREATE FUNCTION t.shift(e text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.shifts WHERE employee_id=t.id(e) AND status='open' $$;
-- Payments of an order, one direction.
CREATE FUNCTION t.pays(o text,dir text) RETURNS TABLE(id uuid,method text,amount numeric,alloc numeric,shift_id uuid,cash_account_id uuid,branch_id uuid,
                                                      idempotency_key text,reference text) LANGUAGE sql SECURITY DEFINER AS $$
  SELECT p.id,p.method::text,p.amount,a.amount,p.shift_id,p.cash_account_id,p.branch_id,p.idempotency_key,p.reference
  FROM public.payments p JOIN public.payment_allocations a ON a.payment_id=p.id
  WHERE a.order_id=t.oid(o) AND p.direction::text=dir $$;
CREATE FUNCTION t.npays(o text,dir text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM t.pays(o,dir) $$;
-- Ledger rows written for an order's payments.
CREATE FUNCTION t.cash_rows(o text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('method',p.method,'amount',m.amount::text,'type',m.type,'source',m.source_type,'account',m.cash_account_id,
    'shift',m.shift_id,'branch',m.branch_id) ORDER BY m.created_at,m.id),'[]')
  FROM (SELECT * FROM t.pays(o,'in') UNION ALL SELECT * FROM t.pays(o,'out')) p
  JOIN public.cash_movements m ON m.source_id=p.id AND m.source_type='payment' $$;
CREATE FUNCTION t.credit_rows(o text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('amount',m.amount::text,'source',m.source_type) ORDER BY m.created_at,m.id),'[]')
  FROM (SELECT * FROM t.pays(o,'in') UNION ALL SELECT * FROM t.pays(o,'out')) p
  JOIN public.store_credit_movements m ON m.source_id=p.id AND m.source_type='payment' $$;
CREATE FUNCTION t.balances(o text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object('deposits_paid',deposits_paid::text,'unpaid',unpaid::text,'total',total::text) FROM public.v_order_balances WHERE order_id=t.oid(o) $$;
-- No sale, no tax lines, no fiscal row (O9).
CREATE FUNCTION t.no_sale() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_array((SELECT count(*) FROM public.sales WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.sale_lines WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.fiscal_submissions WHERE organization_id=t.org('a'))) $$;
-- What public.unpair_device does to the request's device, for one statement (t.error rolls it back).
CREATE FUNCTION t.revoke_device() RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  UPDATE public.devices SET token_hash=NULL,paired_at=NULL,paired_by=NULL WHERE id=(current_setting('request.headers')::jsonb->>'x-device-id')::uuid $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: manager, bank, store credit
DELETE FROM public.employee_permission_overrides WHERE employee_id=t.id('cashier') AND permission_key='order.manage';
INSERT INTO auth.users(id,email) VALUES('a7100000-0000-0000-8000-000000000004','s10manager@example.com');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id)
  VALUES(t.org('a'),'a7100000-0000-0000-8000-000000000004','S10 Manager','BRANCH_MANAGER',t.id('main')) RETURNING id AS manager_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'manager_id',t.id('main'));
INSERT INTO t.ids VALUES('manager',:'manager_id');
WITH x AS (INSERT INTO public.cash_accounts(organization_id,branch_id,name,kind) VALUES(t.org('a'),NULL,'S10 Bank','bank') RETURNING id) INSERT INTO t.ids SELECT 'bank',id FROM x;
INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date)
  VALUES(t.org('a'),t.id('mona'),100,'sales_return',gen_random_uuid(),t.id('main'),app.org_today(t.org('a')));
SELECT t.as_user('a7100000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.pos(t.id('main'));
SELECT public.open_shift(t.id('main'),'0','s10-shift-manager',NULL,NULL);
RESET ROLE;
SELECT t.expect('setup part 2: two open shifts, mona has 100 credit, drawers known',t.drawer('cashier') IS NOT NULL AND t.drawer('manager') IS NOT NULL
  AND t.drawer('cashier')<>t.drawer('manager') AND t.credit('mona')=100 AND t.bal(t.drawer('manager'))=0,
  concat_ws(' ',t.drawer('cashier'),t.drawer('manager'),t.credit('mona')));
CREATE TABLE t.before AS SELECT t.no_sale() counts,t.bal(t.drawer('cashier')) drawer;

-- ---------------------------------------------------------------- O9 a deposit is a payment, not a sale
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.run('d1',t.dep('o1',t.lines(t.pay('cash','1000.00','{"tendered":"1000.00"}')),'s10-dep-0001'));
SELECT t.run('d1again',t.dep('o1',t.lines(t.pay('cash','1000.00','{"tendered":"1000.00"}')),'s10-dep-0001'));
SELECT t.run('d2',t.dep('o4',t.lines(t.pay('bank_transfer','50.00',jsonb_build_object('cash_account_id',t.id('bank'),'reference','TRX-S10-1')),
  t.pay('store_credit','30.00')),'s10-dep-0002'));
RESET ROLE;
SELECT t.expect('O9 cash deposit: one in payment of 1000 in the cashier''s shift drawer, allocated 1000 to the order',
  (SELECT count(*)=1 AND bool_and(method='cash' AND amount=1000 AND alloc=1000 AND shift_id=t.shift('cashier') AND cash_account_id=t.drawer('cashier')
     AND branch_id=t.id('main') AND idempotency_key='s10-dep-0001') FROM t.pays('o1','in')) AND t.npays('o1','out')=0);
SELECT t.expect('O9 one deposit cash movement (+1000, source payment) and the drawer is 1000 higher',
  t.cash_rows('o1')=jsonb_build_array(jsonb_build_object('method','cash','amount','1000.00','type','deposit','source','payment','account',t.drawer('cashier'),
    'shift',t.shift('cashier'),'branch',t.id('main')))
  AND t.bal(t.drawer('cashier'))=(SELECT drawer FROM t.before)+1000,t.cash_rows('o1')::text);
SELECT t.expect('O9 balances: deposits_paid 1000, unpaid = total - 1000 (view and response)',
  t.balances('o1')->>'deposits_paid'='1000.00' AND (t.balances('o1')->>'unpaid')::numeric=(t.balances('o1')->>'total')::numeric-1000
  AND t.doc('d1')->'balances'->>'deposits_paid'='1000.00' AND t.doc('d1')->'balances'->>'unpaid'=t.balances('o1')->>'unpaid',t.balances('o1')::text);
SELECT t.expect('O9 the response lists the payment (direction, method, number, amount, reference)',
  jsonb_array_length(t.doc('d1')->'payments')=1 AND t.doc('d1')->'payments'->0->>'direction'='in' AND t.doc('d1')->'payments'->0->>'method'='cash'
  AND t.doc('d1')->'payments'->0->>'amount'='1000.00' AND t.doc('d1')->'payments'->0->>'number' LIKE 'MAIN-%' AND t.doc('d1')->'payments'->0 ? 'reference',
  (t.doc('d1')->'payments')::text);
SELECT t.expect('O9 replay of the key: same order, still one payment, one audit',
  t.doc('d1again')->'payments'=t.doc('d1')->'payments' AND t.npays('o1','in')=1 AND t.audits('o1','sales_order.deposit')=1
  AND (SELECT after->>'amount'='1000.00' AND jsonb_array_length(after->'payments')=1 FROM public.audit_log WHERE entity_id=t.oid('o1') AND action='sales_order.deposit'));
SELECT t.expect('O9 split deposit: bank (no shift, +50 deposit on the bank) and store credit (-30); line 2 keyed system:order:md5(<key>):2',
  (SELECT count(*)=2 AND bool_and(alloc=amount) AND bool_and(CASE method WHEN 'bank_transfer' THEN cash_account_id=t.id('bank') AND shift_id=t.shift('cashier')
       AND reference='TRX-S10-1' AND idempotency_key='s10-dep-0002' ELSE cash_account_id IS NULL AND idempotency_key='system:order:'||md5('s10-dep-0002')||':2' END) FROM t.pays('o4','in'))
  AND t.cash_rows('o4')=jsonb_build_array(jsonb_build_object('method','bank_transfer','amount','50.00','type','deposit','source','payment','account',t.id('bank'),
    'shift',NULL,'branch',t.id('main')))
  AND t.credit_rows('o4')='[{"amount":"-30.00","source":"payment"}]'::jsonb AND t.credit('mona')=70 AND t.bal(t.id('bank'))=50
  AND t.balances('o4')->>'deposits_paid'='80.00',concat_ws(' ',t.cash_rows('o4'),t.credit_rows('o4'),t.credit('mona')));
SELECT t.expect('O9 no sale, no tax lines, no fiscal row: sales / sale_lines / fiscal_submissions counts unchanged',
  t.no_sale()=(SELECT counts FROM t.before),concat_ws(' ',t.no_sale(),(SELECT counts FROM t.before)));

-- ---------------------------------------------------------------- O10 deposit rules
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('O10 over the balance (1000 paid + 9681 > 10680)',t.dep('o1',t.lines(t.pay('cash','9681.00')),'s10-dep-over'),'DEPOSIT_EXCEEDS_BALANCE');
SELECT t.unchanged('O10 a bank transfer without a reference',t.dep('o1',t.lines(t.pay('bank_transfer','10.00',jsonb_build_object('cash_account_id',t.id('bank')))),'s10-dep-noref'),'VALIDATION_FAILED');
SELECT t.unchanged('O10 store credit beyond the customer''s balance (70)',t.dep('o1',t.lines(t.pay('store_credit','70.01')),'s10-dep-credit'),'INSUFFICIENT_STORE_CREDIT');
-- The longest allowed key (128) on a two-line deposit: line 2's key must stay within the limit too. Rolled back.
DO $$ BEGIN
  BEGIN
    EXECUTE t.dep('o1',t.lines(t.pay('cash','1.00'),t.pay('store_credit','1.00')),repeat('k',128));
    RAISE EXCEPTION 'S10_LONG_KEY_OK';
  EXCEPTION WHEN OTHERS THEN
    PERFORM t.expect('O10 a 128-character key on a two-line deposit',SQLERRM='S10_LONG_KEY_OK',SQLERRM);
  END;
END $$;
SELECT t.unchanged('O10 a revoked device',format('SELECT x FROM t.revoke_device() r, LATERAL (%s) x',t.dep('o1',t.lines(t.pay('cash','10.00')),'s10-dep-revoked')),'DEVICE_REVOKED');
SELECT t.unchanged('O10 a cancelled order',t.dep('y',t.lines(t.pay('cash','10.00')),'s10-dep-closed'),'ORDER_NOT_OPEN');
RESET ROLE;
SELECT t.as_user('a7100000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('O10 no open shift (the owner)',t.dep('o1',t.lines(t.pay('cash','10.00')),'s10-dep-noshift'),'SHIFT_REQUIRED');
RESET ROLE;

-- ---------------------------------------------------------------- O11 cancel: release, refund in full, close
SELECT t.as_user('a7100000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.run('d3',t.dep('o1',t.lines(t.pay('cash','400.00')),'s10-dep-0003'));
RESET ROLE;
SELECT t.expect('O11 before: o1 holds 3 chairs and IMEI-1, deposits 1400, manager drawer 400',
  t.res('o1')='[{"line_no":1,"unit":null,"quantity":3},{"line_no":2,"unit":"S10-IMEI-1","quantity":1}]'::jsonb AND t.reserved('chair')=4 AND t.reserved('phone')=2
  AND t.balances('o1')->>'deposits_paid'='1400.00' AND t.bal(t.drawer('manager'))=400,concat_ws(' ',t.res('o1'),t.reserved('chair'),t.reserved('phone'),t.balances('o1')));
SELECT t.as_user('a7100000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.run('c1',t.cancel('o1','Customer changed mind',t.lines(t.pay('cash','400.00'),t.pay('store_credit','1000.00')),'s10-cancel-0001'));
RESET ROLE;
SELECT t.expect('O11 reservations released, reserved back down, the unit in_stock',
  t.res('o1')='[]'::jsonb AND t.reserved('chair')=1 AND t.reserved('phone')=1 AND t.unit_status('S10-IMEI-1')='in_stock'
  AND (SELECT count(*)=3 AND bool_and(r.status='released' AND r.released_at IS NOT NULL) FROM public.stock_reservations r JOIN public.sales_order_lines l ON l.id=r.order_line_id
       WHERE l.order_id=t.oid('o1')),concat_ws(' ',t.res('o1'),t.reserved('chair'),t.reserved('phone'),t.unit_status('S10-IMEI-1')));
SELECT t.expect('O11 two out payments allocated to the order (cash 400 from the manager''s shift, store credit 1000), deposits_paid 0',
  (SELECT count(*)=2 AND sum(alloc)=1400 AND bool_and(alloc=amount)
     AND bool_and(CASE method WHEN 'cash' THEN amount=400 AND shift_id=t.shift('manager') AND cash_account_id=t.drawer('manager') AND idempotency_key='s10-cancel-0001'
                  ELSE method='store_credit' AND amount=1000 AND cash_account_id IS NULL AND idempotency_key='system:order:'||md5('s10-cancel-0001')||':2' END) FROM t.pays('o1','out'))
  AND t.balances('o1')->>'deposits_paid'='0.00' AND t.doc('c1')->'balances'->>'deposits_paid'='0.00'
  AND (SELECT count(*)=2 FROM jsonb_array_elements(t.doc('c1')->'payments') p WHERE p->>'direction'='out'),(t.doc('c1')->'payments')::text);
SELECT t.expect('O11 the manager''s drawer is 400 lower (refund -400, source payment); the store credit is 1000 higher',
  t.bal(t.drawer('manager'))=0 AND t.cash_rows('o1')->-1=jsonb_build_object('method','cash','amount','-400.00','type','refund','source','payment',
    'account',t.drawer('manager'),'shift',t.shift('manager'),'branch',t.id('main'))
  AND t.credit('mona')=1070 AND t.credit_rows('o1')='[{"amount":"1000.00","source":"payment"}]'::jsonb,concat_ws(' ',t.cash_rows('o1'),t.credit('mona')));
SELECT t.expect('O11 cancelled with its reason, one audit with the refund total',
  t.doc('c1')->>'status'='cancelled' AND t.doc('c1')->>'cancelled_reason'='Customer changed mind' AND t.audits('o1','sales_order.cancelled')=1
  AND (SELECT after->>'refund_total'='1400.00' AND after->>'status'='cancelled' AND before->>'status'='open' FROM public.audit_log WHERE entity_id=t.oid('o1') AND action='sales_order.cancelled'),
  t.doc('c1')::text);
-- No cash back: bank + store credit, and a cancel with no deposits, need no shift (the owner has none).
SELECT t.as_user('a7100000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.run('c4',t.cancel('o4','Quote expired',t.lines(t.pay('bank_transfer','50.00',jsonb_build_object('cash_account_id',t.id('bank'),'reference','TRX-S10-R1')),
  t.pay('store_credit','30.00')),'s10-cancel-0004'));
SELECT t.run('c5',t.cancel('o3ovr','No longer needed','[]','s10-cancel-0005'));
RESET ROLE;
SELECT t.expect('O11 no cash line, no shift: bank -50 (refund, reference kept) and store credit +30; the chair released',
  t.doc('c4')->>'status'='cancelled' AND t.bal(t.id('bank'))=0 AND t.credit('mona')=1100 AND t.balances('o4')->>'deposits_paid'='0.00'
  AND (SELECT count(*)=2 AND bool_and(shift_id IS NULL) AND bool_or(reference='TRX-S10-R1') FROM t.pays('o4','out'))
  AND t.cash_rows('o4')->-1->>'amount'='-50.00' AND t.cash_rows('o4')->-1->>'type'='refund' AND t.res('o4')='[]'::jsonb AND t.reserved('chair')=0,
  concat_ws(' ',t.doc('c4')->>'status',t.bal(t.id('bank')),t.credit('mona'),t.cash_rows('o4')));
SELECT t.expect('O11 no deposits: an empty refund cancels, no payments',t.doc('c5')->>'status'='cancelled' AND t.doc('c5')->'payments'='[]'::jsonb
  AND (SELECT after->>'refund_total' FROM public.audit_log WHERE entity_id=t.oid('o3ovr') AND action='sales_order.cancelled')='0.00',t.doc('c5')::text);
-- The drawer can't go below zero: a cash refund bigger than the manager's drawer.
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.run('d5',t.dep('r',t.lines(t.pay('cash','500.00')),'s10-dep-0005'));
RESET ROLE;
SELECT t.as_user('a7100000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('O11 a cash refund beyond the drawer (0) is refused',t.cancel('r','Customer changed mind',t.lines(t.pay('cash','500.00')),'s10-cancel-funds'),'INSUFFICIENT_FUNDS');
RESET ROLE;

-- ---------------------------------------------------------------- O12 cancel exactly once
SELECT t.as_user('a7100000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.run('d4',t.dep('o3cap',t.lines(t.pay('cash','100.00')),'s10-dep-0004'));
SELECT t.unchanged('O12 refund lines that don''t sum to the deposits (99 of 100)',t.cancel('o3cap','Customer changed mind',t.lines(t.pay('cash','99.00')),'s10-cancel-short'),'REFUND_MUST_EQUAL_DEPOSITS');
SELECT t.unchanged('O12 an empty refund with deposits',t.cancel('o3cap','Customer changed mind','[]','s10-cancel-empty'),'REFUND_MUST_EQUAL_DEPOSITS');
SELECT t.unchanged('O12 a refund with no deposits',t.cancel('p','Customer changed mind',t.lines(t.pay('cash','1.00')),'s10-cancel-nodep'),'REFUND_MUST_EQUAL_DEPOSITS');
SELECT t.unchanged('O12 a reason of 2 characters',t.cancel('o3cap','  ab ',t.lines(t.pay('cash','100.00')),'s10-cancel-reason'),'REASON_REQUIRED');
SELECT t.run('c3',t.cancel('o3cap','Customer changed mind',t.lines(t.pay('cash','100.00')),'s10-cancel-0003'));
CREATE TEMP TABLE s10_after_cancel AS SELECT t.bal(t.drawer('manager')) drawer,t.cash_rows('o3cap') cash;
SELECT t.run('c3again',t.cancel('o3cap','Another reason',t.lines(t.pay('cash','100.00')),'s10-cancel-0003'));
SELECT t.unchanged('O12 a second cancel with a new key',t.cancel('o3cap','Customer changed mind',t.lines(t.pay('cash','100.00')),'s10-cancel-again'),'ORDER_NOT_OPEN');
RESET ROLE;
SELECT t.expect('O12 same key: the same result, one refund payment, no second cash movement, one audit',
  t.doc('c3again')=t.doc('c3') AND t.npays('o3cap','out')=1 AND t.cash_rows('o3cap')=(SELECT cash FROM s10_after_cancel)
  AND jsonb_array_length(t.cash_rows('o3cap'))=2 AND t.bal(t.drawer('manager'))=(SELECT drawer FROM s10_after_cancel)
  AND t.audits('o3cap','sales_order.cancelled')=1 AND t.doc('c3')->>'cancelled_reason'='Customer changed mind',
  concat_ws(' ',t.npays('o3cap','out'),t.cash_rows('o3cap')));
SELECT t.as_user('a7100000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('O12 a cashier can''t cancel',t.cancel('p','Customer changed mind','[]','s10-cancel-cashier'),'PERMISSION_DENIED');
RESET ROLE;
-- A partly delivered order (S11 sets this state; here directly, then back to open).
UPDATE public.sales_orders SET status='partially_delivered' WHERE id=t.oid('p');
SELECT t.as_user('a7100000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('O12 a partly delivered order can''t be cancelled',t.cancel('p','Customer changed mind','[]','s10-cancel-partial'),'ORDER_HAS_DELIVERIES');
RESET ROLE;
UPDATE public.sales_orders SET status='open' WHERE id=t.oid('p');

-- ---------------------------------------------------------------- O14 deposits and cancels: direct-database security
SELECT t.as_user('a7100000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('O14 deposit on a branch without access',t.dep('sec',t.lines(t.pay('cash','10.00')),'s10-o14-depbr'),'BRANCH_DENIED');
SELECT t.unchanged('O14 cancel on a branch without access',t.cancel('sec','Customer changed mind','[]','s10-o14-canbr'),'BRANCH_DENIED');
RESET ROLE;
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted)
  VALUES(t.org('a'),t.id('manager'),'order.manage',false),(t.org('a'),t.id('manager'),'order.cancel',false);
SET ROLE authenticated;
SELECT t.unchanged('O14 permission: deposit',t.dep('p',t.lines(t.pay('cash','10.00')),'s10-o14-depperm'),'PERMISSION_DENIED');
SELECT t.unchanged('O14 permission: cancel',t.cancel('p','Customer changed mind','[]','s10-o14-canperm'),'PERMISSION_DENIED');
RESET ROLE;
DELETE FROM public.employee_permission_overrides WHERE employee_id=t.id('manager');
SELECT t.as_user('a7100000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.unchanged('O14 other shop: deposit',t.dep('p',t.lines(t.pay('cash','10.00')),'s10-o14-depshop'),'ORDER_NOT_FOUND');
SELECT t.unchanged('O14 other shop: cancel',t.cancel('p','Customer changed mind','[]','s10-o14-canshop'),'ORDER_NOT_FOUND');
DO $$ DECLARE tb text; BEGIN FOREACH tb IN ARRAY ARRAY['cash_movements','store_credit_movements'] LOOP
  PERFORM t.error('O14 no direct insert '||tb,format('INSERT INTO public.%I DEFAULT VALUES',tb),'permission denied for table '||tb);
END LOOP; END $$;
RESET ROLE;
SELECT t.expect('O14 grants: deposit and cancel for authenticated only; their helpers for nobody',
  has_function_privilege('authenticated','public.record_order_deposit(uuid,jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.cancel_sales_order(uuid,text,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.record_order_deposit(uuid,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.cancel_sales_order(uuid,text,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.s10_post_order_payments(uuid,uuid,public.sales_orders,public.shifts,jsonb,text,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.s10_shift(uuid,uuid,text)','EXECUTE'));

-- ---------------------------------------------------------------- O15 the ledgers reconcile after the full flow
SELECT t.expect('O15 flow ran: deposits and refunds posted in shop a',
  (SELECT count(*) FROM public.payment_allocations a JOIN public.payments p ON p.id=a.payment_id WHERE a.organization_id=t.org('a') AND a.order_id IS NOT NULL AND p.direction='out')=5);
SELECT t.expect('O15 stock levels = stock ledger sums (product, branch, state), none below zero',NOT EXISTS(
  SELECT 1 FROM (SELECT product_id,branch_id,stock_state,on_hand FROM public.stock_levels WHERE organization_id=t.org('a')) l
  FULL JOIN (SELECT product_id,branch_id,stock_state,sum(quantity) ledger FROM public.stock_movements WHERE organization_id=t.org('a') GROUP BY 1,2,3) m
    ON m.product_id=l.product_id AND m.branch_id=l.branch_id AND m.stock_state=l.stock_state
  WHERE COALESCE(l.on_hand,0)<>COALESCE(m.ledger,0) OR l.on_hand<0));
SELECT t.expect('O15 reserved = active reservations, per product and branch',NOT EXISTS(
  SELECT 1 FROM (SELECT product_id,branch_id,sum(reserved) reserved FROM public.stock_levels WHERE organization_id=t.org('a') GROUP BY 1,2) l
  FULL JOIN (SELECT product_id,branch_id,sum(quantity) active FROM public.stock_reservations WHERE organization_id=t.org('a') AND status='active' GROUP BY 1,2) r
    ON r.product_id=l.product_id AND r.branch_id=l.branch_id
  WHERE COALESCE(l.reserved,0)<>COALESCE(r.active,0)));
SELECT t.expect('O15 cash balances = cash movement sums (drawers, bank, safes), none below zero',NOT EXISTS(
  SELECT 1 FROM public.cash_accounts a LEFT JOIN public.cash_balances b ON b.cash_account_id=a.id
  LEFT JOIN (SELECT cash_account_id,sum(amount) ledger FROM public.cash_movements WHERE organization_id=t.org('a') GROUP BY 1) m ON m.cash_account_id=a.id
  WHERE a.organization_id=t.org('a') AND (COALESCE(b.balance,0)<>COALESCE(m.ledger,0) OR COALESCE(b.balance,0)<0)));
SELECT t.expect('O15 store-credit balances = store-credit movement sums',NOT EXISTS(
  SELECT 1 FROM (SELECT customer_id,balance FROM public.store_credit_balances WHERE organization_id=t.org('a')) b
  FULL JOIN (SELECT customer_id,sum(amount) ledger FROM public.store_credit_movements WHERE organization_id=t.org('a') GROUP BY 1) m ON m.customer_id=b.customer_id
  WHERE COALESCE(b.balance,0)<>COALESCE(m.ledger,0)) AND t.credit('mona')=1100);
SELECT t.expect('O15 every order payment has exactly one allocation and one ledger row',NOT EXISTS(
  SELECT 1 FROM public.payments p WHERE p.organization_id=t.org('a') AND EXISTS(SELECT 1 FROM public.payment_allocations a WHERE a.payment_id=p.id AND a.order_id IS NOT NULL)
    AND ((SELECT count(*) FROM public.payment_allocations a WHERE a.payment_id=p.id)<>1
      OR (SELECT count(*) FROM public.cash_movements m WHERE m.source_id=p.id AND m.source_type='payment')
        +(SELECT count(*) FROM public.store_credit_movements m WHERE m.source_id=p.id AND m.source_type='payment')<>1)));
SELECT t.expect('O15 app.ledger_mismatches finds nothing in shop a',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT name FROM t.results WHERE ok ORDER BY name;
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
