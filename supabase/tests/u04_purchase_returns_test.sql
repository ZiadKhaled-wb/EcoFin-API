\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- Like t.error, and also the error detail (RETURN_QTY_EXCEEDED's returnable).
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.audits(a text,i text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(i) $$;
CREATE FUNCTION t.avg(p text) RETURNS text LANGUAGE sql AS $$ SELECT avg_cost::text FROM public.products WHERE id=t.id(p) $$;
CREATE FUNCTION t.bal(s text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT balance FROM public.v_supplier_balances WHERE supplier_id=t.id(s)),0) $$;
CREATE FUNCTION t.stock(p text) RETURNS bigint LANGUAGE sql AS $$ SELECT COALESCE(sum(on_hand),0) FROM public.stock_levels WHERE product_id=t.id(p) $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.l(p text,q integer,c text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q,'unit_cost',c) $$;
-- An invoice line id, and the units an invoice line created (by serial).
CREATE FUNCTION t.ln(i text,p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.purchase_invoice_lines WHERE invoice_id=t.id(i) AND product_id=t.id(p) $$;
CREATE FUNCTION t.unit(i text,p text,n integer) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.units WHERE purchase_invoice_line_id=t.ln(i,p) ORDER BY serial OFFSET n-1 LIMIT 1 $$;
CREATE FUNCTION t.q(i text,p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('invoice_line_id',t.ln(i,p),'quantity',q) $$;
CREATE FUNCTION t.u(i text,p text,units uuid[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('invoice_line_id',t.ln(i,p),'unit_ids',to_jsonb(units)) $$;
-- An approved invoice of Nile in main, as the current user.
CREATE FUNCTION t.pi(tag text,lines jsonb,approve boolean DEFAULT true) RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN
  j := public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,lines,'u04-pi-'||tag);
  INSERT INTO t.ids VALUES(tag,(j->>'id')::uuid);
  IF approve THEN PERFORM public.approve_purchase_invoice(t.id(tag)); END IF; END $$;
-- A return call as SQL text, for t.error.
CREATE FUNCTION t.call(i text,mode text,lines jsonb,acc uuid DEFAULT NULL,reason text DEFAULT 'Damaged on arrival') RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_purchase_return(%L,%L,%L,%L,%L,%L)',t.id(i),mode,reason,lines,'u04-'||md5(random()::text),acc) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (retail_pro: serials), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('U04 '||s,'u04-'||s,p,'Owner',s||'u04@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('p',64)),('b','retail',repeat('q',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a4040000-0000-0000-8000-000000000001','au04@example.com'),('a4040000-0000-0000-8000-000000000002','bu04@example.com'),
  ('a4040000-0000-0000-8000-000000000003','u04warehouse@example.com'),('a4040000-0000-0000-8000-000000000004','u04manager@example.com'),
  ('a4040000-0000-0000-8000-000000000005','u04accountant@example.com');
SELECT public.accept_invite(repeat('p',64),'a4040000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a4040000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe_b',default_cash_account_id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a4040000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','U4',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"أ تلفزيون","sku":"U04-TV","cash_price":"200"}'));
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"ب كرسي","sku":"U04-CH","cash_price":"200"}'));
INSERT INTO t.ids VALUES('lamp',public.create_product('{"name_ar":"ج لمبة","sku":"U04-LA","cash_price":"80"}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"د كابل","sku":"U04-CB","cash_price":"20"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"و موبايل","sku":"U04-PH","cash_price":"6000","is_serialized":true}'));
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
SELECT t.pi('inv1',jsonb_build_array(t.l('tv',10,'100.00'),t.l('phone',3,'5000.00')||'{"serials":["U04-SN-1","U04-SN-2","U04-SN-3"]}'));
SELECT t.pi('inv_other',jsonb_build_array(t.l('phone',1,'5000.00')||'{"serials":["U04-SN-9"]}'));
SELECT t.pi('draft',jsonb_build_array(t.l('tv',1,'100.00')),false);
SELECT t.pi('rej',jsonb_build_array(t.l('tv',1,'100.00')),false);
SELECT public.reject_purchase_invoice(t.id('rej'),'Wrong supplier');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
INSERT INTO t.ids SELECT 'spare',(public.create_cash_account('Spare','safe',t.id('main'))->>'id')::uuid;
SELECT public.set_cash_account_active(t.id('spare'),false);
RESET ROLE;
WITH x AS (INSERT INTO public.cash_accounts(organization_id,branch_id,name,kind) VALUES(t.org('a'),t.id('main'),'Drawer 1','drawer') RETURNING id) INSERT INTO t.ids SELECT 'drawer',id FROM x;
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a4040000-0000-0000-8000-000000000003','U04 Warehouse','WAREHOUSE',t.id('main')) RETURNING id AS warehouse_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'warehouse_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a4040000-0000-0000-8000-000000000004','U04 Manager','BRANCH_MANAGER',t.id('second')) RETURNING id AS manager_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'manager_id',t.id('second'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a4040000-0000-0000-8000-000000000005','U04 Accountant','ACCOUNTANT',t.id('main')) RETURNING id AS accountant_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'accountant_id',t.id('main'));
SELECT t.expect('setup: 10 TVs and 3 phones in stock, Nile owes 1 140 + 17 100 + 5 700',
  t.stock('tv')=10 AND t.stock('phone')=4 AND t.bal('nile')=23940, t.bal('nile')::text);

-- ---------------------------------------------------------------- Done when (once)
SELECT t.as_user('a4040000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'r1',(public.post_purchase_return(t.id('inv1'),'supplier_credit','Damaged on arrival',
  jsonb_build_array(t.q('inv1','tv',4),t.u('inv1','phone',ARRAY[t.unit('inv1','phone',1)])),'u04-r1-key')->>'id')::uuid;
SELECT t.expect('Done when: 4 TVs + 1 phone go out once, the unit is returned',
  t.stock('tv')=6 AND t.stock('phone')=3
  AND (SELECT status FROM public.units WHERE id=t.unit('inv1','phone',1))='returned'
  AND (SELECT count(*) FROM public.stock_movements WHERE source_type='purchase_return' AND source_id=t.id('r1'))=2);
SELECT t.expect('Done when: the return is numbered PR, totals with VAT, the supplier balance down by the total',
  r->>'number' LIKE '%-PR-%' AND r->>'subtotal'='5400.00' AND r->>'tax_total'='756.00' AND r->>'total'='6156.00'
  AND t.bal('nile')=23940-6156 AND jsonb_array_length(r->'lines')=2 AND r->>'refund_mode'='supplier_credit'
  AND t.audits('purchase_return.posted','r1')=1, r::text)
FROM (SELECT public.get_purchase_return(t.id('r1')) r) x;
SELECT t.expect('Done when: the same key again -> the same return, nothing moves',
  (public.post_purchase_return(t.id('inv1'),'supplier_credit','Damaged on arrival',
     jsonb_build_array(t.q('inv1','tv',4)),'u04-r1-key')->>'id')::uuid=t.id('r1')
  AND t.stock('tv')=6 AND t.bal('nile')=17784 AND (SELECT count(*) FROM public.purchase_returns)=1);
SELECT t.expect('statement: the return is on the U01 statement and closes at the balance',
  EXISTS(SELECT 1 FROM jsonb_array_elements(s->'rows') r WHERE r->>'kind'='return' AND r->>'credit'='6156.00')
  AND (s->>'closing_balance')::numeric=t.bal('nile'), s::text)
FROM (SELECT public.supplier_statement(t.id('nile')) s) x;

-- ---------------------------------------------------------------- Done when (cap) and tax
SELECT t.error_detail('cap: 7 more TVs (6 left) -> RETURN_QTY_EXCEEDED with 6',
  t.call('inv1','supplier_credit',jsonb_build_array(t.q('inv1','tv',7))),'RETURN_QTY_EXCEEDED',
  jsonb_build_object('invoice_line_id',t.ln('inv1','tv'),'returnable',6));
SELECT t.expect('cap: the refused return posted nothing',t.stock('tv')=6 AND (SELECT count(*) FROM public.purchase_returns)=1);
INSERT INTO t.ids SELECT 'r2',(public.post_purchase_return(t.id('inv1'),'supplier_credit','Wrong model',
  jsonb_build_array(t.q('inv1','tv',6)),'u04-r2-key')->>'id')::uuid;
SELECT t.expect('cap: 6 -> OK',t.stock('tv')=0);
SELECT t.error_detail('cap: 1 more -> RETURN_QTY_EXCEEDED with 0',
  t.call('inv1','supplier_credit',jsonb_build_array(t.q('inv1','tv',1))),'RETURN_QTY_EXCEEDED',
  jsonb_build_object('returnable',0));
SELECT t.expect('tax: the returns of a line add back exactly to its tax and gross',
  (SELECT sum(tax_amount)=l.tax_amount AND sum(line_total)=l.line_total FROM public.purchase_return_lines WHERE invoice_line_id=l.id))
FROM public.purchase_invoice_lines l WHERE l.id=t.ln('inv1','tv');
SELECT t.expect('returnable: TVs 0 left, phones 2 in stock',
  (SELECT bool_and(CASE WHEN x->>'sku'='U04-TV' THEN (x->>'returnable')::int=0
                        ELSE (x->>'returnable')::int=2 AND jsonb_array_length(x->'units_in_stock')=2 END)
   FROM jsonb_array_elements(public.get_returnable_invoice(t.id('inv1'))->'lines') x));

-- ---------------------------------------------------------------- average cost
SELECT t.pi('inv3',jsonb_build_array(t.l('chair',10,'100.00')));
SELECT t.pi('inv4',jsonb_build_array(t.l('chair',10,'130.00')));
RESET ROLE;
-- 10 chairs leave (as a sale would): 10 on hand at 115.0000.
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,stock_state,unit_cost,source_type,source_id)
VALUES(t.org('a'),t.id('chair'),t.id('main'),-10,'adjustment','sellable',115,'stock_adjustment',gen_random_uuid());
SET ROLE authenticated;
SELECT public.post_purchase_return(t.id('inv4'),'supplier_credit','Scratched',jsonb_build_array(t.q('inv4','chair',2)),'u04-avg-1');
SELECT t.expect('average: 10 at 115.0000, 2 back at 130.00 -> 111.2500',t.avg('chair')='111.2500',t.avg('chair'));
SELECT t.pi('inv5',jsonb_build_array(t.l('lamp',5,'50.00')));
SELECT public.post_purchase_return(t.id('inv5'),'supplier_credit','All faulty',jsonb_build_array(t.q('inv5','lamp',5)),'u04-avg-2');
SELECT t.expect('average: returning everything keeps the last average',t.avg('lamp')='50.0000' AND t.stock('lamp')=0,t.avg('lamp'));
SELECT t.pi('inv6',jsonb_build_array(t.l('cable',2,'10.00')));
RESET ROLE;
UPDATE public.products SET avg_cost=1 WHERE id=t.id('cable');
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'r_clamp',(public.post_purchase_return(t.id('inv6'),'supplier_credit','Too many',
  jsonb_build_array(t.q('inv6','cable',1)),'u04-avg-3')->>'id')::uuid;
SELECT t.expect('average: 2 at 1.0000, 1 back at 10.00 -> clamped at 0, noted in the audit',
  t.avg('cable')='0.0000' AND EXISTS(SELECT 1 FROM public.audit_log WHERE entity_id=t.id('r_clamp')
    AND (after->'avg_cost'->0->>'clamped')::boolean),t.avg('cable'));

-- ---------------------------------------------------------------- cash refund
SELECT t.expect('setup: the main safe is empty',t.cash('safe')=0);
INSERT INTO t.ids SELECT 'r_cash',(public.post_purchase_return(t.id('inv1'),'cash','Refunded in cash',
  jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',2)])),'u04-cash-1',t.id('safe'))->>'id')::uuid;
SELECT t.expect('cash: the safe up by the total, one supplier_refund movement, the supplier balance unchanged',
  t.cash('safe')=5700 AND t.bal('nile')=(SELECT t.bal('nile'))
  AND (SELECT count(*) FROM public.cash_movements WHERE source_type='purchase_return' AND source_id=t.id('r_cash') AND type='supplier_refund' AND amount=5700)=1
  AND (SELECT cash_account_id FROM public.purchase_returns WHERE id=t.id('r_cash'))=t.id('safe'));
SELECT t.expect('cash: the supplier balance does not move with a cash return',
  t.bal('nile')=(SELECT sum(total) FROM public.purchase_invoices WHERE supplier_id=t.id('nile') AND status='approved')
    -(SELECT sum(total) FROM public.purchase_returns WHERE supplier_id=t.id('nile') AND refund_mode='supplier_credit'));
SELECT t.error('cash: without an account',t.call('inv1','cash',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)]))),'VALIDATION_FAILED');
SELECT t.error('cash: an account with credit mode',t.call('inv1','supplier_credit',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)])),t.id('safe')),'VALIDATION_FAILED');
SELECT t.error('cash: an inactive safe',t.call('inv1','cash',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)])),t.id('spare')),'CASH_ACCOUNT_INACTIVE');
SELECT t.error('cash: another branch''s safe',t.call('inv1','cash',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)])),t.id('safe2')),'VAULT_INVALID');
SELECT t.error('cash: a drawer',t.call('inv1','cash',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)])),t.id('drawer')),'VAULT_INVALID');
SELECT t.error('cash: another shop''s safe',t.call('inv1','cash',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)])),t.id('safe_b')),'VAULT_INVALID');
SELECT t.expect('cash: a shop-wide bank is allowed',
  public.post_purchase_return(t.id('inv6'),'cash','Bank refund',jsonb_build_array(t.q('inv6','cable',1)),'u04-cash-2',t.id('bank'))->>'cash_account_name'='NBE'
  AND t.cash('bank')=11.40);

-- ---------------------------------------------------------------- serial rules
SELECT t.error('serial: a unit of another invoice line',t.call('inv1','supplier_credit',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv_other','phone',1)]))),'UNIT_NOT_AVAILABLE');
SELECT t.error('serial: a unit already returned',t.call('inv1','supplier_credit',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',1)]))),'UNIT_NOT_AVAILABLE');
SELECT t.error('serial: an unknown unit',t.call('inv1','supplier_credit',jsonb_build_array(t.u('inv1','phone',ARRAY[gen_random_uuid()]))),'UNIT_NOT_FOUND');
SELECT t.error('serial: quantity on a serialized line',t.call('inv1','supplier_credit',jsonb_build_array(t.q('inv1','phone',1))),'VALIDATION_FAILED');
SELECT t.error('serial: unit_ids on a normal line',t.call('inv1','supplier_credit',jsonb_build_array(t.u('inv1','tv',ARRAY[t.unit('inv1','phone',3)]))),'VALIDATION_FAILED');
RESET ROLE;
UPDATE public.units SET status='reserved' WHERE id=t.unit('inv1','phone',3);
SET ROLE authenticated;
SELECT t.error('serial: a reserved unit',t.call('inv1','supplier_credit',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)]))),'UNIT_NOT_AVAILABLE');
RESET ROLE;
UPDATE public.units SET status='in_stock',branch_id=t.id('second') WHERE id=t.unit('inv1','phone',3);
SET ROLE authenticated;
SELECT t.error('serial: a unit moved to another branch',t.call('inv1','supplier_credit',jsonb_build_array(t.u('inv1','phone',ARRAY[t.unit('inv1','phone',3)]))),'UNIT_NOT_AVAILABLE');
RESET ROLE;
UPDATE public.units SET branch_id=t.id('main') WHERE id=t.unit('inv1','phone',3);
SET ROLE authenticated;
SELECT t.expect('serial: the refused returns posted nothing',t.stock('phone')=2 AND (SELECT status FROM public.units WHERE id=t.unit('inv1','phone',3))='in_stock');

-- ---------------------------------------------------------------- states, input, roles
SELECT t.error('state: a draft invoice',t.call('draft','supplier_credit',jsonb_build_array(t.q('draft','tv',1))),'PURCHASE_INVOICE_NOT_APPROVED');
SELECT t.error('state: a rejected invoice',t.call('rej','supplier_credit',jsonb_build_array(t.q('rej','tv',1))),'PURCHASE_INVOICE_NOT_APPROVED');
SELECT t.error('input: no reason',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1)),NULL,'  '),'VALIDATION_FAILED');
SELECT t.error('input: an unknown refund mode',t.call('inv3','exchange',jsonb_build_array(t.q('inv3','chair',1))),'VALIDATION_FAILED');
SELECT t.error('input: no lines',t.call('inv3','supplier_credit','[]'),'VALIDATION_FAILED');
SELECT t.error('input: a line twice',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1),t.q('inv3','chair',1))),'VALIDATION_FAILED');
SELECT t.error('input: quantity 0',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',0))),'VALIDATION_FAILED');
SELECT t.error('input: quantity as text',t.call('inv3','supplier_credit',jsonb_build_array(jsonb_build_object('invoice_line_id',t.ln('inv3','chair'),'quantity','x'))),'VALIDATION_FAILED');
SELECT t.error('input: an unknown key',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1)||'{"unit_cost":"1"}')),'VALIDATION_FAILED');
SELECT t.error('input: a line of another invoice',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv4','chair',1))),'VALIDATION_FAILED');
SELECT t.error('input: a system key',format('SELECT public.post_purchase_return(%L,%L,%L,%L,%L)',t.id('inv3'),'supplier_credit','Reason',jsonb_build_array(t.q('inv3','chair',1)),'system:u04'),'VALIDATION_FAILED');
SELECT t.error('input: an unknown invoice',format('SELECT public.post_purchase_return(%L,%L,%L,%L,%L)',gen_random_uuid(),'supplier_credit','Reason',jsonb_build_array(t.q('inv3','chair',1)),'u04-unknown'),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.expect('accounts: the branch''s active safes and banks with balances (no inactive, drawer, other branch)',
  (SELECT array_agg(x->>'name' ORDER BY x->>'name') FROM jsonb_array_elements(l->'items') x)=ARRAY['NBE','الخزنة الرئيسية']
  AND (SELECT x->>'balance' FROM jsonb_array_elements(l->'items') x WHERE (x->>'id')::uuid=t.id('safe'))='5700.00', l::text)
FROM (SELECT public.list_payable_cash_accounts(t.id('main')) l) y;
RESET ROLE;
SELECT t.as_user('a4040000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: a WAREHOUSE user can''t return',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1))),'PERMISSION_DENIED');
SELECT t.error('who: a WAREHOUSE user can''t list accounts',format('SELECT public.list_payable_cash_accounts(%L)',t.id('main')),'PERMISSION_DENIED');
SELECT t.error('who: a WAREHOUSE user can''t see returnable lines',format('SELECT public.get_returnable_invoice(%L)',t.id('inv3')),'PERMISSION_DENIED');
SELECT t.expect('who: a WAREHOUSE user reads returns (purchasing read key)',(public.list_purchase_returns()->>'total')::int>=5);
RESET ROLE;
SELECT t.as_user('a4040000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: another branch''s manager',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1))),'BRANCH_DENIED');
SELECT t.error('who: another branch''s manager can''t read main''s return',format('SELECT public.get_purchase_return(%L)',t.id('r1')),'PURCHASE_RETURN_NOT_FOUND');
SELECT t.expect('who: another branch''s manager lists none of main''s returns',(public.list_purchase_returns()->>'total')::int=0);
RESET ROLE;
SELECT t.as_user('a4040000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('who: an accountant (supplier.payment_create) lists the payable accounts',
  jsonb_array_length(public.list_payable_cash_accounts(t.id('main'))->'items')=2);
SELECT t.error('who: an accountant can''t return goods',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1))),'PERMISSION_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- tenancy, ledger, expired shop, grants
SELECT t.as_user('a4040000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: a''s invoice',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1))),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.error('shop b: a''s return',format('SELECT public.get_purchase_return(%L)',t.id('r1')),'PURCHASE_RETURN_NOT_FOUND');
SELECT t.error('shop b: a''s returnable invoice',format('SELECT public.get_returnable_invoice(%L)',t.id('inv1')),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.error('shop b: a''s branch accounts',format('SELECT public.list_payable_cash_accounts(%L)',t.id('main')),'BRANCH_NOT_FOUND');
SELECT t.expect('shop b: lists no returns',(public.list_purchase_returns()->>'total')::int=0);
SELECT t.error('no direct writes',format('INSERT INTO public.purchase_returns(organization_id,number,purchase_invoice_id,supplier_id,branch_id,refund_mode,subtotal,total,reason,business_date,idempotency_key) VALUES(%L,%L,%L,%L,%L,%L,0,0,%L,current_date,%L)',t.org('b'),'X',t.id('inv1'),t.id('nile'),t.id('main'),'supplier_credit','x','u04-direct'),'permission denied for table purchase_returns');
RESET ROLE;
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
SELECT t.expect('movement history names the return and the supplier',
  app.stock_source_json(t.org('a'),'purchase_return',t.id('r1'))->>'party'='Nile Traders'
  AND app.stock_source_json(t.org('a'),'purchase_return',t.id('r1'))->>'number' LIKE '%-PR-%');
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a4040000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired shop: returns still read',(public.list_purchase_returns()->>'total')::int>=5);
SELECT t.error('expired shop: no new return',t.call('inv3','supplier_credit',jsonb_build_array(t.q('inv3','chair',1))),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('grants: the five functions for authenticated, helpers not',
  has_function_privilege('authenticated','public.post_purchase_return(uuid,text,text,jsonb,text,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_purchase_returns(uuid,uuid,uuid,date,date,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_purchase_return(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_returnable_invoice(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_payable_cash_accounts(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_purchase_return(uuid,text,text,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.purchase_return_json(uuid,uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.payable_cash_account(uuid,uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.returned_by_line(uuid,uuid)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
