\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- Like t.error, and also the error detail (PO_OVER_RECEIPT's remaining).
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.audits(a text,i text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(i) $$;
CREATE FUNCTION t.stock(p text) RETURNS bigint LANGUAGE sql AS $$ SELECT COALESCE(sum(on_hand),0) FROM public.stock_levels WHERE product_id=t.id(p) $$;
CREATE FUNCTION t.status(o text) RETURNS text LANGUAGE sql AS $$ SELECT status::text FROM public.purchase_orders WHERE id=t.id(o) $$;
CREATE FUNCTION t.l(p text,q integer,c text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q,'expected_unit_cost',c) $$;
-- An order line id, what is still to come on it, and a receive line for it.
CREATE FUNCTION t.pol(o text,p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.purchase_order_lines WHERE po_id=t.id(o) AND product_id=t.id(p) $$;
CREATE FUNCTION t.rem(o text,p text) RETURNS integer LANGUAGE sql AS $$ SELECT remaining FROM public.v_po_line_received WHERE po_line_id=t.pol(o,p) $$;
CREATE FUNCTION t.rl(o text,p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('po_line_id',t.pol(o,p),'quantity',q) $$;
-- An order of Nile in main, as the current user; sent when asked.
CREATE FUNCTION t.po(tag text,lines jsonb,send boolean DEFAULT true) RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN
  j := public.create_purchase_order(t.id('nile'),t.id('main'),lines,'u05-po-'||tag);
  INSERT INTO t.ids VALUES(tag,(j->>'id')::uuid);
  IF send THEN PERFORM public.send_purchase_order(t.id(tag)); END IF; END $$;
-- A draft invoice from an order, as the current user.
CREATE FUNCTION t.recv(tag text,o text,lines jsonb DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO t.ids VALUES(tag,(public.create_invoice_from_po(t.id(o),'u05-inv-'||tag,lines)->>'id')::uuid); END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a, shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('U05 '||s,'u05-'||s,'retail','Owner',s||'u05@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('p',64)),('b',repeat('q',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a5050000-0000-0000-8000-000000000001','au05@example.com'),('a5050000-0000-0000-8000-000000000002','bu05@example.com'),
  ('a5050000-0000-0000-8000-000000000003','u05warehouse@example.com'),('a5050000-0000-0000-8000-000000000004','u05manager@example.com'),
  ('a5050000-0000-0000-8000-000000000005','u05cashier@example.com');
SELECT public.accept_invite(repeat('p',64),'a5050000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a5050000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a5050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','U5',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"أ تلفزيون","sku":"U05-TV","cash_price":"200"}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"ب كابل","sku":"U05-CB","cash_price":"20"}'));
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"ج كرسي","sku":"U05-CH","cash_price":"300"}'));
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'delta',(public.create_supplier('{"name":"Delta Supplies"}')->>'id')::uuid;
RESET ROLE;
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5050000-0000-0000-8000-000000000003','U05 Warehouse','WAREHOUSE',t.id('main')) RETURNING id AS warehouse_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'warehouse_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5050000-0000-0000-8000-000000000004','U05 Manager','BRANCH_MANAGER',t.id('second')) RETURNING id AS manager_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'manager_id',t.id('second'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5050000-0000-0000-8000-000000000005','U05 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
-- A customer's open order with a special (to_order) chair line and a from-stock TV line (S10 comes later).
INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('a'),'U05 Customer') RETURNING id AS customer_id \gset
WITH o AS (INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,total,idempotency_key)
           VALUES(t.org('a'),'MAIN-SO-26-000001',:'customer_id',t.id('main'),true,500,500,'u05-so-1') RETURNING id)
INSERT INTO t.ids SELECT 'so',id FROM o;
WITH x AS (INSERT INTO public.sales_order_lines(organization_id,order_id,line_no,product_id,quantity,unit_price,tax_class_id,tax_rate,line_total,fulfilment)
           SELECT t.org('a'),t.id('so'),v.n,p.id,1,v.price,p.tax_class_id,14,v.price,v.f::public.fulfilment_mode
           FROM (VALUES(1,'chair',300,'to_order'),(2,'tv',200,'from_stock'),(3,'cable',20,'to_order'))v(n,p,price,f)
           JOIN public.products p ON p.id=t.id(v.p) RETURNING id,line_no)
INSERT INTO t.ids SELECT 'sol'||line_no,id FROM x;

-- ---------------------------------------------------------------- draft: create, repeat, edit, send
SELECT t.as_user('a5050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.po('po1',jsonb_build_array(t.l('tv',9,'100.00'),t.l('cable',5,'10.00')),false);
SELECT t.expect('create: a draft numbered PO with its lines, audited once',
  o->>'number' LIKE '%-PO-%' AND o->>'status'='draft' AND jsonb_array_length(o->'lines')=2
  AND o->'invoices'='[]'::jsonb AND o->>'supplier_name'='Nile Traders'
  AND t.audits('purchase_order.created','po1')=1, o::text)
FROM (SELECT public.get_purchase_order(t.id('po1')) o) x;
SELECT current_user AS test4_role \gset
RESET ROLE;
\ir helpers/test4_snapshot.sql
SET ROLE :"test4_role";
SELECT t.snapshot(t.org('a'))::text AS test4_snapshot \gset
SELECT t.expect('create: the same key again -> the same order, one row, one audit',
  (public.create_purchase_order(t.id('nile'),t.id('main'),jsonb_build_array(t.l('tv',1,'1.00')),'u05-po-po1')->>'id')::uuid=t.id('po1')
  AND (SELECT count(*) FROM public.purchase_orders)=1 AND t.audits('purchase_order.created','po1')=1);
SELECT t.expect('TEST4 replay snapshot 1',t.snapshot(t.org('a'))=:'test4_snapshot'::jsonb);
SELECT t.error('states: invoicing a draft order',format('SELECT public.create_invoice_from_po(%L,%L)',t.id('po1'),'u05-draft-inv'),'PO_NOT_SENT');
SELECT t.expect('edit: a draft takes a date, notes and new lines; audited once',
  o->>'expected_date'=(current_date+7)::text AND o->>'notes'='Call before delivery'
  AND (SELECT (x->>'quantity')::int FROM jsonb_array_elements(o->'lines') x WHERE x->>'sku'='U05-TV')=10
  AND (SELECT x->>'expected_unit_cost' FROM jsonb_array_elements(o->'lines') x WHERE x->>'sku'='U05-CB')='10.00'
  AND t.audits('purchase_order.updated','po1')=1, o::text)
FROM (SELECT public.update_purchase_order(t.id('po1'),jsonb_build_object('expected_date',current_date+7,'notes','  Call before delivery ',
  'lines',jsonb_build_array(t.l('tv',10,'100.00'),t.l('cable',5,'10.00')))) o) x;
SELECT public.update_purchase_order(t.id('po1'),'{"notes":"Call before delivery"}');
SELECT t.expect('edit: no change, no audit row',t.audits('purchase_order.updated','po1')=1);
SELECT t.error('edit: an unknown key',format('SELECT public.update_purchase_order(%L,%L)',t.id('po1'),'{"status":"sent"}'),'VALIDATION_FAILED');
SELECT t.error('edit: the same product twice',format('SELECT public.update_purchase_order(%L,%L)',t.id('po1'),jsonb_build_object('lines',jsonb_build_array(t.l('tv',1,'1.00'),t.l('tv',2,'1.00')))),'VALIDATION_FAILED');
SELECT t.error('edit: quantity 0',format('SELECT public.update_purchase_order(%L,%L)',t.id('po1'),jsonb_build_object('lines',jsonb_build_array(t.l('tv',0,'1.00')))),'VALIDATION_FAILED');
SELECT t.error('edit: a cost with three decimals',format('SELECT public.update_purchase_order(%L,%L)',t.id('po1'),jsonb_build_object('lines',jsonb_build_array(t.l('tv',1,'1.234')))),'VALIDATION_FAILED');
SELECT t.error('create: no lines',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),'[]','u05-no-lines'),'VALIDATION_FAILED');
SELECT t.error('create: an unknown product',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(jsonb_build_object('product_id',gen_random_uuid(),'quantity',1)),'u05-bad-product'),'PRODUCT_NOT_FOUND');
SELECT t.expect('send: draft -> sent, audited',public.send_purchase_order(t.id('po1'))->>'status'='sent' AND t.audits('purchase_order.sent','po1')=1);
SELECT t.expect('send: twice -> unchanged, no second audit',public.send_purchase_order(t.id('po1'))->>'status'='sent' AND t.audits('purchase_order.sent','po1')=1);
SELECT t.error('states: editing a sent order',format('SELECT public.update_purchase_order(%L,%L)',t.id('po1'),'{"notes":"late"}'),'PURCHASE_ORDER_NOT_EDITABLE');

-- ---------------------------------------------------------------- Done when (partial receipt)
SELECT t.recv('inv1','po1',jsonb_build_array(t.rl('po1','tv',6),t.rl('po1','cable',5)));
SELECT t.expect('receive: a draft invoice of the order, at the expected costs, lines linked, audited with the order',
  i->>'status'='draft' AND (i->>'po_id')::uuid=t.id('po1') AND i->>'po_number' LIKE '%-PO-%'
  AND (i->>'supplier_id')::uuid=t.id('nile') AND i->>'subtotal'='650.00'
  AND (SELECT bool_and((x->>'po_line_id') IS NOT NULL) FROM jsonb_array_elements(i->'lines') x)
  AND (SELECT (after->>'po_id')::uuid FROM public.audit_log WHERE action='purchase_invoice.created' AND entity_id=t.id('inv1'))=t.id('po1'), i::text)
FROM (SELECT public.get_purchase_invoice(t.id('inv1')) i) x;
SELECT t.snapshot(t.org('a'))::text AS test4_snapshot \gset
SELECT t.expect('receive: the same key again -> the same invoice',
  (public.create_invoice_from_po(t.id('po1'),'u05-inv-inv1')->>'id')::uuid=t.id('inv1')
  AND (SELECT count(*) FROM public.purchase_invoices WHERE po_id=t.id('po1'))=1);
SELECT t.expect('TEST4 replay snapshot 2',t.snapshot(t.org('a'))=:'test4_snapshot'::jsonb);
SELECT t.expect('receive: a draft does not count as received; the order shows it on draft invoices',
  t.rem('po1','tv')=10 AND t.status('po1')='sent'
  AND (SELECT (x->>'on_draft_invoices')::int FROM jsonb_array_elements(public.get_purchase_order(t.id('po1'))->'lines') x WHERE x->>'sku'='U05-TV')=6);
SELECT public.approve_purchase_invoice(t.id('inv1'));
SELECT t.expect('Done when: 6 TVs + 5 cables approved -> partially_received, TV 4 and cable 0 still to come',
  t.status('po1')='partially_received' AND t.rem('po1','tv')=4 AND t.rem('po1','cable')=0
  AND t.stock('tv')=6 AND t.stock('cable')=5);
SELECT t.expect('Done when: the order''s detail shows received, remaining and its invoice',
  (SELECT bool_and(CASE WHEN x->>'sku'='U05-TV' THEN (x->>'received')::int=6 AND (x->>'remaining')::int=4 AND (x->>'on_draft_invoices')::int=0
                        ELSE (x->>'received')::int=5 AND (x->>'remaining')::int=0 END) FROM jsonb_array_elements(o->'lines') x)
  AND jsonb_array_length(o->'invoices')=1 AND o->'invoices'->0->>'status'='approved', o::text)
FROM (SELECT public.get_purchase_order(t.id('po1')) o) x;
SELECT t.recv('inv2','po1');
SELECT t.expect('the rest: with no lines given the invoice takes what is still to come (4 TVs)',
  jsonb_array_length(i->'lines')=1 AND (i->'lines'->0->>'quantity')::int=4, i::text)
FROM (SELECT public.get_purchase_invoice(t.id('inv2')) i) x;
SELECT public.approve_purchase_invoice(t.id('inv2'));
SELECT t.expect('the rest: approved -> received, stock rose by 10 and 5 in all',t.status('po1')='received' AND t.stock('tv')=10 AND t.stock('cable')=5);
SELECT t.error('the rest: a third invoice',format('SELECT public.create_invoice_from_po(%L,%L)',t.id('po1'),'u05-third'),'PO_CLOSED');
SELECT t.error('states: cancelling a received order',format('SELECT public.cancel_purchase_order(%L,%L)',t.id('po1'),'Too late'),'PURCHASE_ORDER_NOT_EDITABLE');

-- ---------------------------------------------------------------- over-receipt
SELECT t.po('po2',jsonb_build_array(t.l('tv',10,'100.00')));
SELECT t.recv('o1','po2',jsonb_build_array(t.rl('po2','tv',6)));
SELECT public.approve_purchase_invoice(t.id('o1'));
SELECT t.error_detail('over-receipt: 5 when 4 are still to come',format('SELECT public.create_invoice_from_po(%L,%L,%L)',t.id('po2'),'u05-over',jsonb_build_array(t.rl('po2','tv',5))),
  'PO_OVER_RECEIPT',jsonb_build_object('po_line_id',t.pol('po2','tv'),'remaining',4));
SELECT t.recv('d1','po2',jsonb_build_array(t.rl('po2','tv',4)));
SELECT t.recv('d2','po2',jsonb_build_array(t.rl('po2','tv',4)));
SELECT t.error_detail('over-receipt: editing a draft above what is still to come',
  format('SELECT public.update_purchase_invoice(%L,%L)',t.id('d2'),jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',5,'unit_cost','100.00','po_line_id',t.pol('po2','tv'))))),
  'PO_OVER_RECEIPT',jsonb_build_object('remaining',4));
SELECT public.approve_purchase_invoice(t.id('d1'));
SELECT t.error_detail('over-receipt: two drafts of 4 each, the second approval is refused',format('SELECT public.approve_purchase_invoice(%L)',t.id('d2')),
  'PO_OVER_RECEIPT',jsonb_build_object('po_line_id',t.pol('po2','tv'),'remaining',0));
SELECT t.expect('over-receipt: nothing was posted by the refused approval',
  t.stock('tv')=20 AND (SELECT status FROM public.purchase_invoices WHERE id=t.id('d2'))='draft' AND t.status('po2')='received');

-- ---------------------------------------------------------------- mismatch (U02's create with an order)
SELECT t.po('po3',jsonb_build_array(t.l('chair',3,'150.00'),t.l('cable',2,NULL)));
SELECT t.error('mismatch: a linked line of another product',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1,'unit_cost','1.00','po_line_id',t.pol('po3','chair'))),'u05-mm-1',t.id('po3')),'PO_LINE_MISMATCH');
SELECT t.error('mismatch: an invoice with another supplier',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L,%L)',t.id('delta'),t.id('main'),
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',1,'unit_cost','1.00','po_line_id',t.pol('po3','chair'))),'u05-mm-2',t.id('po3')),'PO_LINE_MISMATCH');
SELECT t.error('mismatch: an invoice in another branch',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L,%L)',t.id('nile'),t.id('second'),
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',1,'unit_cost','1.00','po_line_id',t.pol('po3','chair'))),'u05-mm-3',t.id('po3')),'PO_LINE_MISMATCH');
SELECT t.error('mismatch: an order line without the order',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',1,'unit_cost','1.00','po_line_id',t.pol('po3','chair'))),'u05-mm-4'),'PO_LINE_MISMATCH');
SELECT t.error('mismatch: a line of another order',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1,'unit_cost','1.00','po_line_id',t.pol('po2','tv'))),'u05-mm-5',t.id('po3')),'PO_LINE_MISMATCH');
SELECT t.error('mismatch: receiving a line of another order',format('SELECT public.create_invoice_from_po(%L,%L,%L)',t.id('po3'),'u05-mm-6',jsonb_build_array(t.rl('po2','tv',1))),'PO_LINE_MISMATCH');
SELECT t.error('mismatch: an unknown order',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',1,'unit_cost','1.00')),'u05-mm-7',gen_random_uuid()),'PURCHASE_ORDER_NOT_FOUND');
INSERT INTO t.ids SELECT 'mixed',(public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',1,'unit_cost','150.00','po_line_id',t.pol('po3','chair')),
                    jsonb_build_object('product_id',t.id('tv'),'quantity',2,'unit_cost','100.00')),'u05-mixed',t.id('po3'))->>'id')::uuid;
SELECT t.expect('extra goods: an invoice of the order may carry a line without the order link',
  (SELECT count(*) FILTER (WHERE po_line_id IS NOT NULL)=1 AND count(*)=2 FROM public.purchase_invoice_lines WHERE invoice_id=t.id('mixed')));
SELECT t.expect('U02 unchanged: an invoice without an order has no po_id and null po fields',
  i->>'po_id' IS NULL AND i ? 'po_number' AND (i->'lines'->0) ? 'po_line_id' AND i->'lines'->0->>'po_line_id' IS NULL, i::text)
FROM (SELECT public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1,'unit_cost','1.00')),'u05-plain') i) x;

-- ---------------------------------------------------------------- states: cancel
SELECT public.approve_purchase_invoice(t.id('mixed'));
SELECT t.expect('states: 1 of 3 chairs approved -> partially_received (the extra TVs do not count)',
  t.status('po3')='partially_received' AND t.rem('po3','chair')=2 AND t.rem('po3','cable')=2);
SELECT t.recv('late','po3',jsonb_build_array(t.rl('po3','chair',1)));
SELECT t.error('cancel: a reason is required',format('SELECT public.cancel_purchase_order(%L,%L)',t.id('po3'),' '),'VALIDATION_FAILED');
SELECT t.expect('cancel: a partly received order closes with a reason',
  public.cancel_purchase_order(t.id('po3'),'  Supplier stopped the model ')->>'status'='cancelled');
RESET ROLE;
SELECT t.expect('cancel: audited once as a warning with the trimmed reason',
  (SELECT count(*)=1 AND bool_and(severity='warning' AND reason='Supplier stopped the model') FROM public.audit_log
   WHERE action='purchase_order.cancelled' AND entity_id=t.id('po3')));
SET ROLE authenticated;
SELECT t.error('cancel: further invoicing',format('SELECT public.create_invoice_from_po(%L,%L)',t.id('po3'),'u05-after-cancel'),'PO_CLOSED');
SELECT t.error('cancel: a draft made before the cancel can''t be approved',format('SELECT public.approve_purchase_invoice(%L)',t.id('late')),'PO_CLOSED');
SELECT t.error('cancel: twice',format('SELECT public.cancel_purchase_order(%L,%L)',t.id('po3'),'Again'),'PURCHASE_ORDER_NOT_EDITABLE');
SELECT t.error('cancel: sending a cancelled order',format('SELECT public.send_purchase_order(%L)',t.id('po3')),'PURCHASE_ORDER_NOT_EDITABLE');
SELECT t.po('po_draft',jsonb_build_array(t.l('cable',1,'10.00')),false);
SELECT t.expect('cancel: a draft can be cancelled too',public.cancel_purchase_order(t.id('po_draft'),'Not needed')->>'status'='cancelled');

-- ---------------------------------------------------------------- Done when (special order)
SELECT t.po('po4',jsonb_build_array(t.l('chair',2,'150.00')||jsonb_build_object('sales_order_line_id',t.id('sol1'))),false);
RESET ROLE;
SELECT t.expect('special order: the customer''s line now points to the order line',
  (SELECT po_line_id FROM public.sales_order_lines WHERE id=t.id('sol1'))=t.pol('po4','chair'));
SELECT t.expect('special order: the status helper shows the order (draft)',
  s->>'status'='draft' AND s->>'number' LIKE '%-PO-%' AND (s->>'po_id')::uuid=t.id('po4')
  AND (s->>'ordered')::int=2 AND (s->>'received')::int=0 AND (s->>'remaining')::int=2, s::text)
FROM (SELECT app.sales_order_line_po_status(t.org('a'),t.id('sol1')) s) x;
SELECT t.expect('special order: a line with no order has no status',app.sales_order_line_po_status(t.org('a'),t.id('sol2')) IS NULL);
SET ROLE authenticated;
SELECT t.expect('special order: the order''s detail names the customer order',
  public.get_purchase_order(t.id('po4'))->'lines'->0->'customer_order'->>'number'='MAIN-SO-26-000001'
  AND (public.get_purchase_order(t.id('po4'))->'lines'->0->'customer_order'->>'line_id')::uuid=t.id('sol1'));
SELECT t.error('special order: a from-stock line',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(t.l('tv',1,'100.00')||jsonb_build_object('sales_order_line_id',t.id('sol2'))),'u05-so-stock'),'SALES_ORDER_LINE_INVALID');
SELECT t.error('special order: a line that is already linked',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(t.l('chair',1,'150.00')||jsonb_build_object('sales_order_line_id',t.id('sol1'))),'u05-so-linked'),'SALES_ORDER_LINE_INVALID');
SELECT t.error('special order: another product',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(t.l('tv',1,'100.00')||jsonb_build_object('sales_order_line_id',t.id('sol3'))),'u05-so-product'),'SALES_ORDER_LINE_INVALID');
SELECT t.error('special order: an unknown line',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),
  jsonb_build_array(t.l('chair',1,'150.00')||jsonb_build_object('sales_order_line_id',gen_random_uuid())),'u05-so-unknown'),'SALES_ORDER_LINE_INVALID');
SELECT t.expect('special order: replacing a draft''s lines keeps the link on the new line',
  public.update_purchase_order(t.id('po4'),jsonb_build_object('lines',jsonb_build_array(t.l('chair',3,'150.00')||jsonb_build_object('sales_order_line_id',t.id('sol1')))))->'lines'->0->'customer_order'->>'number'='MAIN-SO-26-000001');
SELECT public.send_purchase_order(t.id('po4'));
SELECT t.recv('so_inv','po4',jsonb_build_array(t.rl('po4','chair',1)));
SELECT public.approve_purchase_invoice(t.id('so_inv'));
RESET ROLE;
SELECT t.expect('Done when: the customer order line shows the purchase order as partially received',
  s->>'status'='partially_received' AND (s->>'received')::int=1 AND (s->>'remaining')::int=2, s::text)
FROM (SELECT app.sales_order_line_po_status(t.org('a'),t.id('sol1')) s) x;

-- ---------------------------------------------------------------- list
SELECT t.as_user('a5050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
-- (Every order of this test has the same created_at: one transaction. The order of rows isn't checked.)
SELECT t.expect('list: every order with its counts; filters by status, supplier and number; paging',
  (l->>'total')::int=5
  AND (SELECT x ? 'lines_count' AND (x->>'ordered')::int=3 AND (x->>'received')::int=1 AND NOT x ? 'lines'
       FROM jsonb_array_elements(l->'items') x WHERE (x->>'id')::uuid=t.id('po4'))
  AND (public.list_purchase_orders(NULL,NULL,'received')->>'total')::int=2
  AND (public.list_purchase_orders(t.id('delta'))->>'total')::int=0
  AND (public.list_purchase_orders(NULL,t.id('main'),NULL,(SELECT number FROM public.purchase_orders WHERE id=t.id('po2')))->>'total')::int=1
  AND jsonb_array_length(public.list_purchase_orders(NULL,NULL,NULL,NULL,2,1)->'items')=2, l::text)
FROM (SELECT public.list_purchase_orders() l) x;
SELECT t.error('list: an unknown status',$$SELECT public.list_purchase_orders(NULL,NULL,'open')$$,'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- roles
SELECT t.as_user('a5050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.po('po_wh',jsonb_build_array(t.l('cable',2,'10.00')));
SELECT t.recv('wh_inv','po_wh');
SELECT t.expect('who: a WAREHOUSE user creates and sends an order and receives it as a draft invoice',
  t.status('po_wh')='sent' AND (SELECT status FROM public.purchase_invoices WHERE id=t.id('wh_inv'))='draft');
SELECT t.error('who: a WAREHOUSE user can''t approve',format('SELECT public.approve_purchase_invoice(%L)',t.id('wh_inv')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a5050000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: a CASHIER can''t list orders',$$SELECT public.list_purchase_orders()$$,'PERMISSION_DENIED');
SELECT t.error('who: a CASHIER can''t read an order',format('SELECT public.get_purchase_order(%L)',t.id('po1')),'PERMISSION_DENIED');
SELECT t.error('who: a CASHIER can''t create an order',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('tv',1,'1.00')),'u05-cashier'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a5050000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: another branch''s manager can''t read main''s order',format('SELECT public.get_purchase_order(%L)',t.id('po1')),'PURCHASE_ORDER_NOT_FOUND');
SELECT t.error('who: another branch''s manager can''t send it',format('SELECT public.send_purchase_order(%L)',t.id('po_wh')),'PURCHASE_ORDER_NOT_FOUND');
SELECT t.error('who: another branch''s manager can''t receive it',format('SELECT public.create_invoice_from_po(%L,%L)',t.id('po_wh'),'u05-mgr-recv'),'PURCHASE_ORDER_NOT_FOUND');
SELECT t.error('who: another branch''s manager can''t order for main',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('tv',1,'1.00')),'u05-manager'),'BRANCH_DENIED');
SELECT t.expect('who: another branch''s manager lists none of main''s orders',(public.list_purchase_orders()->>'total')::int=0);
RESET ROLE;

-- ---------------------------------------------------------------- tenancy, ledger, expired shop, grants
SELECT t.as_user('a5050000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: a''s order',format('SELECT public.get_purchase_order(%L)',t.id('po1')),'PURCHASE_ORDER_NOT_FOUND');
SELECT t.error('shop b: receiving a''s order',format('SELECT public.create_invoice_from_po(%L,%L)',t.id('po_wh'),'u05-b-recv'),'PURCHASE_ORDER_NOT_FOUND');
SELECT t.error('shop b: cancelling a''s order',format('SELECT public.cancel_purchase_order(%L,%L)',t.id('po_wh'),'Not mine'),'PURCHASE_ORDER_NOT_FOUND');
SELECT t.error('shop b: an order for a''s supplier',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main_b'),jsonb_build_array(t.l('tv',1,'1.00')),'u05-b-sup'),'SUPPLIER_NOT_FOUND');
SELECT t.expect('shop b: lists no orders',(public.list_purchase_orders()->>'total')::int=0);
SELECT t.error('no direct writes',format('INSERT INTO public.purchase_orders(organization_id,number,supplier_id,branch_id,idempotency_key) VALUES(%L,%L,%L,%L,%L)',t.org('b'),'X',t.id('nile'),t.id('main_b'),'u05-direct'),'permission denied for table purchase_orders');
RESET ROLE;
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a5050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired shop: orders still read',(public.list_purchase_orders()->>'total')::int=6 AND public.get_purchase_order(t.id('po1')) ? 'lines');
SELECT t.error('expired shop: no new order',format('SELECT public.create_purchase_order(%L,%L,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('tv',1,'1.00')),'u05-expired'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no receiving',format('SELECT public.create_invoice_from_po(%L,%L)',t.id('po_wh'),'u05-expired-recv'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('grants: the eight functions for authenticated, helpers not',
  has_function_privilege('authenticated','public.create_purchase_order(uuid,uuid,jsonb,text,date,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.update_purchase_order(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.send_purchase_order(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.cancel_purchase_order(uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_purchase_orders(uuid,uuid,text,text,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_purchase_order(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.create_invoice_from_po(uuid,text,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.create_purchase_invoice(uuid,uuid,text,date,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.create_purchase_order(uuid,uuid,jsonb,text,date,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.create_purchase_invoice(uuid,uuid,text,date,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.sales_order_line_po_status(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.check_po_receipt(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.po_after_receipt(uuid,uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.set_purchase_order_lines(uuid,uuid,public.purchase_orders,jsonb)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
