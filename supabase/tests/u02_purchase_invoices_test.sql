\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- The DETAIL of the error a call raises ('' when it works).
CREATE FUNCTION t.detail(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN EXECUTE q; RETURN ''; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL; RETURN d; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.level(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0) $$;
CREATE FUNCTION t.moves(i text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.stock_movements WHERE source_id=t.id(i) $$;
CREATE FUNCTION t.audits(a text,i text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(i) $$;
CREATE FUNCTION t.avg(p text) RETURNS text LANGUAGE sql AS $$ SELECT avg_cost::text FROM public.products WHERE id=t.id(p) $$;
CREATE FUNCTION t.bal(s text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT balance FROM public.v_supplier_balances WHERE supplier_id=t.id(s)),0) $$;
CREATE FUNCTION t.status(i text) RETURNS text LANGUAGE sql AS $$ SELECT status::text FROM public.purchase_invoices WHERE id=t.id(i) $$;
CREATE FUNCTION t.l(p text,q integer,c text,extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('product_id',t.id(p),'quantity',q,'unit_cost',c) || extra $$;
CREATE FUNCTION t.line(j jsonb,p text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT r FROM jsonb_array_elements(j->'lines') r WHERE r->>'product_id'=t.id(p)::text LIMIT 1 $$;
-- Creates a draft as the current user and remembers its id under the tag.
CREATE FUNCTION t.pi(tag text,s text,b text,lines jsonb,no text DEFAULT NULL,d date DEFAULT current_date) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN
  j := public.create_purchase_invoice(t.id(s),t.id(b),no,d,lines,'u02-'||tag||'-key');
  INSERT INTO t.ids VALUES(tag,(j->>'id')::uuid); RETURN j; END $$;
-- A create call (fresh key) as SQL text, for t.error.
CREATE FUNCTION t.mk(s text,b text,lines jsonb,d date DEFAULT current_date) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.create_purchase_invoice(%L,%L,NULL,%L,%L,%L)',t.id(s),t.id(b),d,lines,'u02-'||md5(random()::text)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (retail_pro: serials), shop b (retail)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('U02 '||s,'u02-'||s,p,'Owner',s||'u02@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('m',64)),('b','retail',repeat('n',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a2020000-0000-0000-8000-000000000001','au02@example.com'),('a2020000-0000-0000-8000-000000000002','bu02@example.com'),
  ('a2020000-0000-0000-8000-000000000003','u02warehouse@example.com'),('a2020000-0000-0000-8000-000000000004','u02manager@example.com'),
  ('a2020000-0000-0000-8000-000000000005','u02cashier@example.com');
SELECT public.accept_invite(repeat('m',64),'a2020000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('n',64),'a2020000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'exempt',id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='exempt';
INSERT INTO t.ids SELECT 'std_b',id FROM public.tax_classes WHERE organization_id=t.org('b') AND kind='standard';
INSERT INTO public.tax_classes(organization_id,name,kind,rate,eta_tax_type,eta_subtype) VALUES(t.org('a'),'U02 ten','standard',10,'T1','V009') RETURNING id AS ten_id \gset
INSERT INTO t.ids VALUES('ten',:'ten_id');
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','U2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"أ تلفزيون","sku":"U02-TV","cash_price":"200"}'));
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"ب كرسي","sku":"U02-CH","cash_price":"80"}'));
INSERT INTO t.ids VALUES('lamp',public.create_product('{"name_ar":"ج لمبة","sku":"U02-LA","cash_price":"20"}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"د كابل","sku":"U02-CB","cash_price":"5"}'));
INSERT INTO t.ids VALUES('mouse',public.create_product('{"name_ar":"ه ماوس","sku":"U02-MS","cash_price":"300"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"و موبايل","sku":"U02-PH","cash_price":"1200","is_serialized":true}'));
INSERT INTO t.ids VALUES('tablet',public.create_product('{"name_ar":"ز تابلت","sku":"U02-TB","cash_price":"1500","is_serialized":true}'));
INSERT INTO t.ids VALUES('old',public.create_product('{"name_ar":"ح قديم","sku":"U02-OLD","cash_price":"1"}'));
SELECT public.set_product_archived(t.id('old'),true);
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'delta',(public.create_supplier('{"name":"Delta Supply"}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'gone',(public.create_supplier('{"name":"Gone Co"}')->>'id')::uuid;
SELECT public.set_supplier_archived(t.id('gone'),true);
RESET ROLE;
SELECT t.as_user('a2020000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('cable_b',public.create_product('{"name_ar":"كابل ب","sku":"U02-CB","cash_price":"5"}'));
INSERT INTO t.ids VALUES('phone_b',public.create_product('{"name_ar":"موبايل ب","sku":"U02-PH","cash_price":"1200","is_serialized":true}'));
INSERT INTO t.ids SELECT 'nile_b',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
RESET ROLE;
-- Warehouse (create, not approve) and a branch manager (create + approve) in main only; a cashier.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a2020000-0000-0000-8000-000000000003','U02 Warehouse','WAREHOUSE',t.id('main')) RETURNING id AS wh_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'wh_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a2020000-0000-0000-8000-000000000004','U02 Manager','BRANCH_MANAGER',t.id('main')) RETURNING id AS mgr_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'mgr_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a2020000-0000-0000-8000-000000000005','U02 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
-- Opening stock (superuser): tv 10 at avg 100 (6 in main, 4 in second, one of them damaged); lamp 3 at 10.
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,stock_state,source_type,source_id)
VALUES(t.org('a'),t.id('tv'),t.id('main'),6,'opening','sellable','import',gen_random_uuid()),
      (t.org('a'),t.id('tv'),t.id('second'),3,'opening','sellable','import',gen_random_uuid()),
      (t.org('a'),t.id('tv'),t.id('second'),1,'opening','damaged','import',gen_random_uuid()),
      (t.org('a'),t.id('lamp'),t.id('main'),3,'opening','sellable','import',gen_random_uuid());
UPDATE public.products SET avg_cost=100 WHERE id=t.id('tv');
UPDATE public.products SET avg_cost=10 WHERE id=t.id('lamp');

-- ---------------------------------------------------------------- create a draft: tax, serials, totals
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.pi('inv1','nile','main',jsonb_build_array(
  t.l('tv',10,'130.00'),
  t.l('chair',4,'55.50',jsonb_build_object('tax_class_id',t.id('exempt'))),
  t.l('phone',2,'900',jsonb_build_object('serials',jsonb_build_array('sn-1 ',' SN-2')))),'S-100');
SELECT t.expect('draft: numbered PI, status draft, totals (14% + exempt + 14%)',
  j->>'number' LIKE '%PI%' AND j->>'status'='draft' AND j->>'subtotal'='3322.00' AND j->>'tax_total'='434.00'
  AND j->>'total'='3756.00' AND j->'outstanding'='null'::jsonb AND j->>'supplier_name'='Nile Traders', j::text)
FROM (SELECT public.get_purchase_invoice(t.id('inv1')) j) x;
SELECT t.expect('draft lines: net, tax, rate, serials upper-cased and trimmed, no units yet',
  t.line(j,'tv')->>'net'='1300.00' AND t.line(j,'tv')->>'tax_amount'='182.00' AND t.line(j,'tv')->>'tax_rate'='14.00'
  AND t.line(j,'tv')->>'line_total'='1482.00'
  AND t.line(j,'chair')->>'tax_amount'='0.00' AND t.line(j,'chair')->>'line_total'='222.00'
  AND t.line(j,'phone')->'serials'='["SN-1","SN-2"]'::jsonb AND t.line(j,'phone')->'unit_ids'='[]'::jsonb, j::text)
FROM (SELECT public.get_purchase_invoice(t.id('inv1')) j) x;
SELECT t.expect('draft: no stock, no cost change, no balance yet',
  t.moves('inv1')=0 AND t.level('tv','main')=6 AND t.avg('tv')='100.0000' AND t.bal('nile')=0);
SELECT t.expect('create: one audit row',t.audits('purchase_invoice.created','inv1')=1);

-- Idempotency
SELECT t.expect('the same create key returns the same invoice, nothing new',
  (public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,jsonb_build_array(t.l('cable',1,'1')),'u02-inv1-key')->>'id')=t.id('inv1')::text
  AND (SELECT count(*) FROM public.purchase_invoices WHERE organization_id=t.org('a') AND idempotency_key='u02-inv1-key')=1
  AND t.audits('purchase_invoice.created','inv1')=1);
SELECT t.error('a system: key is refused',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('cable',1,'1')),'system:u02-x'),'VALIDATION_FAILED');

-- ---------------------------------------------------------------- tax: 1 000 at 14%; a rate changed after the draft
SELECT t.pi('inv_t','delta','main',jsonb_build_array(t.l('cable',10,'100'),t.l('mouse',1,'200.00',jsonb_build_object('tax_class_id',t.id('ten')))));
SELECT t.expect('net 1 000.00 at 14% -> tax 140.00; 200 at 10% -> 20.00',
  t.line(j,'cable')->>'tax_amount'='140.00' AND t.line(j,'mouse')->>'tax_amount'='20.00' AND j->>'total'='1360.00', j::text)
FROM (SELECT public.get_purchase_invoice(t.id('inv_t')) j) x;
RESET ROLE;
UPDATE public.tax_classes SET rate=5 WHERE id=t.id('ten');
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('approval recomputes with the current rate (10% -> 5%)',
  t.line(j,'mouse')->>'tax_amount'='10.00' AND t.line(j,'mouse')->>'tax_rate'='5.00' AND j->>'total'='1350.00'
  AND j->>'status'='approved', j::text)
FROM (SELECT public.approve_purchase_invoice(t.id('inv_t')) j) x;
SELECT t.expect('...and the supplier balance rises by that total including VAT',t.bal('delta')=1350.00,t.bal('delta')::text);

-- ---------------------------------------------------------------- Done when: approve the 3-line invoice
SELECT public.approve_purchase_invoice(t.id('inv1'));
SELECT t.expect('Done when (quantities): each line in stock exactly once',
  t.level('tv','main')=16 AND t.level('chair','main')=4 AND t.level('phone','main')=2,
  concat_ws(' ',t.level('tv','main'),t.level('chair','main'),t.level('phone','main')));
SELECT t.expect('one purchase_in row per normal line and one per serial, at the net unit cost',
  t.moves('inv1')=4
  AND (SELECT count(*) FROM public.stock_movements WHERE source_id=t.id('inv1') AND type='purchase_in' AND source_type='purchase_invoice')=4
  AND (SELECT unit_cost FROM public.stock_movements WHERE source_id=t.id('inv1') AND product_id=t.id('tv'))=130
  AND (SELECT count(*) FROM public.stock_movements WHERE source_id=t.id('inv1') AND product_id=t.id('phone') AND quantity=1 AND unit_id IS NOT NULL)=2);
SELECT t.expect('Done when (cost): 10 at 100 + 10 at 130 -> 115.0000 (VAT not included)',t.avg('tv')='115.0000',t.avg('tv'));
SELECT t.expect('Done when (cost): no stock, buy at 55.50 -> 55.5000',t.avg('chair')='55.5000',t.avg('chair'));
SELECT t.expect('Done when (balance): the supplier balance rises by the total incl. VAT',t.bal('nile')=3756.00,t.bal('nile')::text);
SELECT t.expect('U01''s statement shows the approved invoice',
  EXISTS(SELECT 1 FROM jsonb_array_elements(public.supplier_statement(t.id('nile'))->'rows') r
         WHERE r->>'document_id'=t.id('inv1')::text AND r->>'kind'='invoice' AND r->>'debit'='3756.00' AND r->>'reference'='S-100'));
SELECT t.expect('approved: outstanding = total, approver named, units listed on the serialized line',
  j->>'outstanding'='3756.00' AND j->>'approved_by_name'='Owner' AND j->>'approved_at' IS NOT NULL
  AND jsonb_array_length(t.line(j,'phone')->'unit_ids')=2, j::text)
FROM (SELECT public.get_purchase_invoice(t.id('inv1')) j) x;
SELECT public.approve_purchase_invoice(t.id('inv1'));
SELECT t.expect('approve again: nothing changes (ledger, stock, cost, audit)',
  t.moves('inv1')=4 AND t.level('tv','main')=16 AND t.avg('tv')='115.0000'
  AND t.audits('purchase_invoice.approved','inv1')=1 AND t.bal('nile')=3756.00);
SELECT t.expect('the approval audit carries the costs before and after',
  EXISTS(SELECT 1 FROM public.audit_log a, jsonb_array_elements(a.after->'avg_cost') c
         WHERE a.action='purchase_invoice.approved' AND a.entity_id=t.id('inv1') AND a.after->>'total'='3756.00'
           AND c->>'product_id'=t.id('tv')::text AND c->>'before'='100.0000' AND c->>'after'='115.0000'));

-- 3 at 10.00, buy 1 at 11.00 -> 10.2500
SELECT t.pi('inv_lamp','nile','main',jsonb_build_array(t.l('lamp',1,'11.00')));
SELECT public.approve_purchase_invoice(t.id('inv_lamp'));
SELECT t.expect('Done when (cost): 3 at 10.00 + 1 at 11.00 -> 10.2500',t.avg('lamp')='10.2500',t.avg('lamp'));

-- ---------------------------------------------------------------- serials: the units and their history
SELECT t.expect('units: in stock in main, at the unit cost, linked to the invoice line',
  (SELECT count(*) FROM public.units u JOIN public.purchase_invoice_lines l ON l.id=u.purchase_invoice_line_id
   WHERE l.invoice_id=t.id('inv1') AND u.status='in_stock' AND u.branch_id=t.id('main') AND u.cost=900 AND u.serial IN ('SN-1','SN-2'))=2);
SELECT t.expect('the unit history shows the invoice number and the supplier',
  u->>'purchase_invoice_number'=(SELECT number FROM public.purchase_invoices WHERE id=t.id('inv1'))
  AND u->>'supplier_name'='Nile Traders' AND u->'history'->0->>'party_name'='Nile Traders'
  AND u->'history'->0->>'type'='purchase_in', u::text)
FROM (SELECT public.find_unit('sn-1') u) x;
SELECT t.expect('movement history (I05) shows the PI number and the supplier',
  EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_stock_movements(t.id('tv'),t.id('main'))->'items') m
         WHERE m->>'source_type'='purchase_invoice' AND m->>'party'='Nile Traders'
           AND m->>'source_number'=(SELECT number FROM public.purchase_invoices WHERE id=t.id('inv1'))));
SELECT t.error('a serial already in the shop is refused on a draft',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('phone',1,'900',jsonb_build_object('serials',jsonb_build_array('SN-1')))),'u02-dupserial-key'),'SERIAL_TAKEN');
SELECT t.error('the same serial on two lines',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('phone',1,'900',jsonb_build_object('serials',jsonb_build_array('SN-9'))),t.l('tablet',1,'900',jsonb_build_object('serials',jsonb_build_array('SN-9')))),'u02-twoline-key'),'SERIAL_TAKEN');
SELECT t.error('serials not matching the quantity',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('phone',2,'900',jsonb_build_object('serials',jsonb_build_array('SN-7')))),'u02-count-key'),'VALIDATION_FAILED');
SELECT t.error('serials on a non-serialized product',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('cable',1,'1',jsonb_build_object('serials',jsonb_build_array('X1')))),'u02-notser-key'),'UNIT_NOT_ALLOWED');
SELECT t.error('a bad serial',format('SELECT public.create_purchase_invoice(%L,%L,NULL,current_date,%L,%L)',t.id('nile'),t.id('main'),jsonb_build_array(t.l('phone',1,'900',jsonb_build_object('serials',jsonb_build_array('!bad')))),'u02-badser-key'),'SERIAL_INVALID');

-- Approve without serials: SERIALS_REQUIRED with the line id, nothing posted.
SELECT t.pi('inv_ns','nile','main',jsonb_build_array(t.l('cable',2,'1.00'),t.l('phone',1,'900')));
SELECT t.error('approve without serials -> SERIALS_REQUIRED',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_ns')),'SERIALS_REQUIRED');
SELECT t.expect('...its detail names the serialized line',
  t.detail(format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_ns')))::jsonb
  = jsonb_build_object('line_ids',jsonb_build_array((SELECT id FROM public.purchase_invoice_lines WHERE invoice_id=t.id('inv_ns') AND product_id=t.id('phone')))));
SELECT t.expect('...and nothing was posted',t.moves('inv_ns')=0 AND t.status('inv_ns')='draft' AND t.level('cable','main')=10);

-- A serial taken between the draft and the approval: SERIAL_TAKEN, nothing posted, still a draft.
SELECT t.pi('inv_taken','nile','main',jsonb_build_array(t.l('tv',1,'500.00'),t.l('phone',1,'950',jsonb_build_object('serials',jsonb_build_array('SN-X')))));
SELECT public.register_units(t.id('phone'),t.id('second'),'900','["SN-X"]',NULL,'u02-register-1');
SELECT t.error('a serial taken since the draft -> SERIAL_TAKEN',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_taken')),'SERIAL_TAKEN');
SELECT t.expect('...no stock, no cost change, still a draft',
  t.moves('inv_taken')=0 AND t.status('inv_taken')='draft' AND t.avg('tv')='115.0000' AND t.level('tv','main')=16);

-- ---------------------------------------------------------------- update (drafts only)
SELECT public.update_purchase_invoice(t.id('inv_ns'),'{"supplier_invoice_no":" T-1 "}');
SELECT t.expect('update: one audit row with what changed',
  t.audits('purchase_invoice.updated','inv_ns')=1
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='purchase_invoice.updated' AND entity_id=t.id('inv_ns')
             AND before->'supplier_invoice_no'='null'::jsonb AND after->>'supplier_invoice_no'='T-1'));
SELECT public.update_purchase_invoice(t.id('inv_ns'),'{"supplier_invoice_no":"T-1"}');
SELECT t.expect('update: no change, no audit row',t.audits('purchase_invoice.updated','inv_ns')=1);
SELECT t.expect('update: lines replaced, totals recomputed',
  jsonb_array_length(j->'lines')=1 AND j->>'total'='5.70' AND t.audits('purchase_invoice.updated','inv_ns')=2, j::text)
FROM (SELECT public.update_purchase_invoice(t.id('inv_ns'),jsonb_build_object('lines',jsonb_build_array(t.l('cable',5,'1.00')))) j) x;
SELECT t.error('update: a future date',format('SELECT public.update_purchase_invoice(%L,%L)',t.id('inv_ns'),jsonb_build_object('invoice_date',current_date+2)),'VALIDATION_FAILED');
SELECT t.error('update: an unknown key (the supplier is fixed)',format('SELECT public.update_purchase_invoice(%L,%L)',t.id('inv_ns'),jsonb_build_object('supplier_id',t.id('delta'))),'VALIDATION_FAILED');
SELECT t.error('update: an approved invoice',format('SELECT public.update_purchase_invoice(%L,%L)',t.id('inv1'),'{"supplier_invoice_no":"X"}'),'PURCHASE_INVOICE_NOT_EDITABLE');

-- ---------------------------------------------------------------- reject; supplier invoice numbers
SELECT t.pi('inv_rej','delta','main',jsonb_build_array(t.l('cable',1,'5')),'S-500');
SELECT t.error('the same supplier invoice no on a live invoice',format('SELECT public.create_purchase_invoice(%L,%L,%L,current_date,%L,%L)',t.id('delta'),t.id('main'),'S-500',jsonb_build_array(t.l('cable',1,'5')),'u02-dupno-key'),'SUPPLIER_INVOICE_NO_TAKEN');
SELECT t.error('reject: a too short reason',format('SELECT public.reject_purchase_invoice(%L,%L)',t.id('inv_rej'),' ab '),'VALIDATION_FAILED');
SELECT t.expect('reject with a reason',
  j->>'status'='rejected' AND j->>'rejected_reason'='Wrong prices on the invoice', j::text)
FROM (SELECT public.reject_purchase_invoice(t.id('inv_rej'),'  Wrong prices on the invoice ') j) x;
SELECT t.expect('...audited as a warning with the reason, nothing posted',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='purchase_invoice.rejected' AND entity_id=t.id('inv_rej')
         AND severity='warning' AND reason='Wrong prices on the invoice') AND t.moves('inv_rej')=0);
SELECT t.error('edit a rejected invoice',format('SELECT public.update_purchase_invoice(%L,%L)',t.id('inv_rej'),'{"supplier_invoice_no":"X"}'),'PURCHASE_INVOICE_NOT_EDITABLE');
SELECT t.error('approve a rejected invoice',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_rej')),'PURCHASE_INVOICE_NOT_EDITABLE');
SELECT t.error('reject a rejected invoice',format('SELECT public.reject_purchase_invoice(%L,%L)',t.id('inv_rej'),'Again please'),'PURCHASE_INVOICE_NOT_EDITABLE');
SELECT t.error('reject an approved invoice',format('SELECT public.reject_purchase_invoice(%L,%L)',t.id('inv1'),'Too late now'),'PURCHASE_INVOICE_NOT_EDITABLE');
SELECT t.expect('a rejected invoice frees its supplier invoice no',
  (public.create_purchase_invoice(t.id('delta'),t.id('main'),'S-500',current_date,jsonb_build_array(t.l('cable',1,'5')),'u02-reuse-key')->>'status')='draft');
RESET ROLE;
SELECT t.error('a rejected row is frozen (trigger)',format('UPDATE public.purchase_invoices SET rejected_reason=%L WHERE id=%L','x',t.id('inv_rej')),'DOCUMENT_FINAL');

-- ---------------------------------------------------------------- refusals
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('an archived supplier',t.mk('gone','main',jsonb_build_array(t.l('cable',1,'1'))),'SUPPLIER_ARCHIVED');
SELECT t.error('another shop''s supplier',t.mk('nile_b','main',jsonb_build_array(t.l('cable',1,'1'))),'SUPPLIER_NOT_FOUND');
SELECT t.error('another shop''s branch',t.mk('nile','main_b',jsonb_build_array(t.l('cable',1,'1'))),'BRANCH_NOT_FOUND');
SELECT t.error('another shop''s product',t.mk('nile','main',jsonb_build_array(t.l('cable_b',1,'1'))),'PRODUCT_NOT_FOUND');
SELECT t.error('an archived product',t.mk('nile','main',jsonb_build_array(t.l('old',1,'1'))),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s tax class',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'1',jsonb_build_object('tax_class_id',t.id('std_b'))))),'TAX_CLASS_NOT_FOUND');
SELECT t.error('a future date',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'1')),current_date+2),'VALIDATION_FAILED');
SELECT t.error('the same product twice',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'1'),t.l('cable',2,'1'))),'VALIDATION_FAILED');
SELECT t.error('quantity 0',t.mk('nile','main',jsonb_build_array(t.l('cable',0,'1'))),'VALIDATION_FAILED');
SELECT t.error('a cost with 3 decimals',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'1.234'))),'VALIDATION_FAILED');
SELECT t.error('a negative cost',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'-1'))),'VALIDATION_FAILED');
SELECT t.error('no lines',t.mk('nile','main','[]'::jsonb),'VALIDATION_FAILED');
SELECT t.error('an unknown line key',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'1','{"discount":"1"}'))),'VALIDATION_FAILED');
SELECT t.error('a supplier invoice no over 40',format('SELECT public.create_purchase_invoice(%L,%L,%L,current_date,%L,%L)',t.id('nile'),t.id('main'),repeat('x',41),jsonb_build_array(t.l('cable',1,'1')),'u02-longno-key'),'VALIDATION_FAILED');
-- A supplier archived after the draft (superuser; archive itself is blocked by the open draft, D53).
SELECT t.pi('inv_arch','delta','main',jsonb_build_array(t.l('cable',1,'1')));
SELECT t.error('the supplier can''t be archived (balance from inv_t, open draft)',format('SELECT public.set_supplier_archived(%L,true)',t.id('delta')),'SUPPLIER_HAS_BALANCE');
RESET ROLE;
UPDATE public.suppliers SET archived_at=now() WHERE id=t.id('delta');
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('approve with an archived supplier',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_arch')),'SUPPLIER_ARCHIVED');
RESET ROLE;
UPDATE public.suppliers SET archived_at=NULL WHERE id=t.id('delta');
-- Shop b (retail, no serials module): a serialized line is refused.
SELECT t.as_user('a2020000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.error('a serialized line needs the serials module',t.mk('nile_b','main_b',jsonb_build_array(t.l('phone_b',1,'900'))),'MODULE_NOT_IN_PLAN');
-- Tenancy: shop b can't reach shop a's invoice.
SELECT t.error('shop b: get',format('SELECT public.get_purchase_invoice(%L)',t.id('inv1')),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.error('shop b: update',format('SELECT public.update_purchase_invoice(%L,%L)',t.id('inv_ns'),'{"supplier_invoice_no":"B"}'),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.error('shop b: approve',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_ns')),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.error('shop b: reject',format('SELECT public.reject_purchase_invoice(%L,%L)',t.id('inv_ns'),'Not mine'),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.expect('shop b: lists none of shop a''s invoices (and RLS hides them)',
  (public.list_purchase_invoices()->>'total')::int=0 AND NOT EXISTS(SELECT 1 FROM public.purchase_invoices));
SELECT t.error('shop b: list by shop a''s supplier',format('SELECT public.list_purchase_invoices(%L)',t.id('nile')),'SUPPLIER_NOT_FOUND');
RESET ROLE;

-- ---------------------------------------------------------------- roles
SELECT t.as_user('a2020000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.pi('inv_wh','nile','main',jsonb_build_array(t.l('chair',2,'60.00')));
SELECT t.expect('warehouse: creates and edits a draft',
  (public.update_purchase_invoice(t.id('inv_wh'),'{"supplier_invoice_no":"W-1"}')->>'supplier_invoice_no')='W-1');
SELECT t.error('warehouse: no approve',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_wh')),'PERMISSION_DENIED');
SELECT t.error('warehouse: no reject',format('SELECT public.reject_purchase_invoice(%L,%L)',t.id('inv_wh'),'Nope nope'),'PERMISSION_DENIED');
SELECT t.expect('warehouse: reads the list',(public.list_purchase_invoices()->>'total')::int>0);
RESET ROLE;
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.pi('inv_second','nile','second',jsonb_build_array(t.l('cable',1,'2.00')));
RESET ROLE;
SELECT t.as_user('a2020000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('manager (main): approves a main invoice; 2 at 60 on 4 at 55.50 -> 57.0000',
  (public.approve_purchase_invoice(t.id('inv_wh'))->>'status')='approved' AND t.avg('chair')='57.0000', t.avg('chair'));
SELECT t.error('manager (main): can''t approve in second',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_second')),'BRANCH_DENIED');
SELECT t.error('manager (main): can''t create in second',t.mk('nile','second',jsonb_build_array(t.l('cable',1,'1'))),'BRANCH_DENIED');
SELECT t.error('manager (main): second''s invoice is not found',format('SELECT public.get_purchase_invoice(%L)',t.id('inv_second')),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.expect('manager (main): the list hides second''s invoices',
  NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_purchase_invoices(p_limit=>100)->'items') i WHERE i->>'id'=t.id('inv_second')::text));
SELECT t.error('manager (main): filtering by second',format('SELECT public.list_purchase_invoices(NULL,%L)',t.id('second')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.as_user('a2020000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('cashier: can''t read',$q$SELECT public.list_purchase_invoices()$q$,'PERMISSION_DENIED');
SELECT t.error('cashier: can''t create',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'1'))),'PERMISSION_DENIED');
SELECT t.as_user('a2020000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee',$q$SELECT public.list_purchase_invoices()$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;

-- ---------------------------------------------------------------- list filters
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('list: status, supplier, branch and search filters; summaries carry lines_count',
  (SELECT count(*) FROM jsonb_array_elements(public.list_purchase_invoices(p_status=>'approved',p_limit=>100)->'items') i
   WHERE i->>'status'<>'approved')=0
  AND (public.list_purchase_invoices(p_supplier_id=>t.id('delta'),p_status=>'rejected')->>'total')::int=1
  AND (public.list_purchase_invoices(p_branch_id=>t.id('second'))->>'total')::int=1
  AND (public.list_purchase_invoices(p_search=>'s-10')->'items'->0->>'id')=t.id('inv1')::text
  AND (public.list_purchase_invoices(p_search=>'s-10')->'items'->0->>'lines_count')::int=3
  AND NOT (public.list_purchase_invoices(p_search=>'s-10')->'items'->0 ? 'lines'));
SELECT t.error('list: from after to',$q$SELECT public.list_purchase_invoices(p_from=>'2026-09-02',p_to=>'2026-09-01')$q$,'VALIDATION_FAILED');
SELECT t.error('list: an unknown status',$q$SELECT public.list_purchase_invoices(p_status=>'paid')$q$,'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- expired shop, ledger, grants
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a2020000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: reads',(public.get_purchase_invoice(t.id('inv1'))->>'status')='approved');
SELECT t.error('expired shop: no create',t.mk('nile','main',jsonb_build_array(t.l('cable',1,'1'))),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no approve',format('SELECT public.approve_purchase_invoice(%L)',t.id('inv_ns')),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('ledger caches match the ledger',
  NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))),
  (SELECT string_agg(ledger||' '||subject_id,'; ') FROM app.ledger_mismatches(t.org('a'))));
SELECT t.expect('no anon grants',
  NOT has_function_privilege('anon','public.create_purchase_invoice(uuid,uuid,text,date,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.update_purchase_invoice(uuid,jsonb)','EXECUTE')
  AND NOT has_function_privilege('anon','public.approve_purchase_invoice(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.reject_purchase_invoice(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.list_purchase_invoices(uuid,uuid,text,date,date,text,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_purchase_invoice(uuid)','EXECUTE'));
SELECT t.expect('authenticated runs the six functions, not the helpers',
  has_function_privilege('authenticated','public.create_purchase_invoice(uuid,uuid,text,date,jsonb,text,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.approve_purchase_invoice(uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_purchase_invoice(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.purchase_invoice_json(uuid,uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.purchase_invoice_compute(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.set_purchase_invoice_lines(uuid,uuid,public.purchase_invoices,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.purchase_invoice_lines_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.purchase_invoice_for_write(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.require_active_supplier(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_invoice_no(text)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
