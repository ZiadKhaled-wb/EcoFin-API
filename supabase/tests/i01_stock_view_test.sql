\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- One stock row of a list_stock answer.
CREATE FUNCTION t.row(j jsonb,p text,b text) RETURNS jsonb LANGUAGE sql AS $$ SELECT r FROM jsonb_array_elements(j->'items') r WHERE r->>'product_id'=t.id(p)::text AND r->>'branch_id'=t.id(b)::text $$;
-- A ledger movement (superuser): purchases, sales, transfers... are later slices.
CREATE FUNCTION t.move(p text,b text,q integer,ty public.stock_movement_type,st public.stock_state DEFAULT 'sellable') RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,stock_state,source_type,source_id,created_at)
  VALUES(t.org('a'),t.id(p),t.id(b),q,ty,st,'stock_adjustment',gen_random_uuid(),clock_timestamp()) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (2 branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('I01 '||s,'i01-'||s,'retail','Owner',s||'i01@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('m',64)),('b',repeat('n',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a1000000-0000-0000-8000-000000000001','ai01@example.com'),('a1000000-0000-0000-8000-000000000002','bi01@example.com'),('a1000000-0000-0000-8000-000000000003','i01cashier@example.com'),('a1000000-0000-0000-8000-000000000004','i01collector@example.com');
SELECT public.accept_invite(repeat('m',64),'a1000000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('n',64),'a1000000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
-- The cashier works in the main branch only; the collector has no stock.view.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a1000000-0000-0000-8000-000000000003','I01 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a1000000-0000-0000-8000-000000000004','I01 Collector','COLLECTOR');

SELECT t.as_user('a1000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','I2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('screens',public.create_category('I01 Screens',NULL));
INSERT INTO t.ids VALUES('tvs',public.create_category('I01 TVs',t.id('screens')));
INSERT INTO t.ids VALUES('tv',public.create_product(jsonb_build_object('name_ar','أ تلفزيون','sku','I01-TV','cash_price','100','category_id',t.id('tvs'))));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"ب كابل","sku":"I01-CB","cash_price":"5","min_stock":10}'));
INSERT INTO t.ids VALUES('empty',public.create_product(jsonb_build_object('name_ar','ج فارغ','sku','I01-EM','cash_price','1','category_id',t.id('screens'))));
INSERT INTO t.ids VALUES('old',public.create_product('{"name_ar":"د قديم","sku":"I01-OLD","cash_price":"1"}'));
INSERT INTO t.ids VALUES('gone',public.create_product('{"name_ar":"ه منتهي","sku":"I01-GONE","cash_price":"1"}'));
RESET ROLE;
SELECT t.as_user('a1000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('tv_b',public.create_product('{"name_ar":"تلفزيون ب","sku":"I01-TV","cash_price":"100"}'));
RESET ROLE;

-- ---------------------------------------------------------------- ledger: movements, damage, reservation, transfer
SELECT t.move('tv','main',10,'purchase_in');
SELECT t.move('tv','main',-2,'sale_out');
SELECT t.move('tv','main',1,'sale_return_in','damaged');
SELECT t.move('tv','second',1,'purchase_in');
SELECT t.move('cable','main',5,'purchase_in');
SELECT t.move('old','main',2,'purchase_in');
-- tv: 3 sent from main to second, not yet received (the stock left main: transfer_out).
INSERT INTO public.stock_transfers(organization_id,number,from_branch_id,to_branch_id,status,sent_at,idempotency_key)
VALUES(t.org('a'),'I01-TR-1',t.id('main'),t.id('second'),'sent',now(),'i01-transfer-1') RETURNING id AS transfer_id \gset
INSERT INTO public.stock_transfer_lines(organization_id,transfer_id,product_id,qty_sent) VALUES(t.org('a'),:'transfer_id',t.id('tv'),3);
SELECT t.move('tv','main',-3,'transfer_out');
-- A received transfer is not in transit.
INSERT INTO public.stock_transfers(organization_id,number,from_branch_id,to_branch_id,status,sent_at,idempotency_key)
VALUES(t.org('a'),'I01-TR-2',t.id('main'),t.id('second'),'sent',now(),'i01-transfer-2') RETURNING id AS transfer2_id \gset
INSERT INTO public.stock_transfer_lines(organization_id,transfer_id,product_id,qty_sent,qty_received) VALUES(t.org('a'),:'transfer2_id',t.id('cable'),1,1);
UPDATE public.stock_transfers SET status='received',received_at=now() WHERE id=:'transfer2_id';
-- tv: 2 reserved in main by a sales order (S10); a released reservation doesn't count.
INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('a'),'I01 customer') RETURNING id AS customer_id \gset
INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,total,idempotency_key)
VALUES(t.org('a'),'I01-SO-1',:'customer_id',t.id('main'),true,200,200,'i01-order-1') RETURNING id AS order_id \gset
INSERT INTO public.sales_order_lines(organization_id,order_id,line_no,product_id,quantity,unit_price,tax_class_id,tax_rate,line_total)
VALUES(t.org('a'),:'order_id',1,t.id('tv'),3,100,(SELECT default_tax_class_id FROM public.org_settings WHERE organization_id=t.org('a')),14,300) RETURNING id AS line_id \gset
INSERT INTO public.stock_reservations(organization_id,product_id,branch_id,order_line_id,quantity) VALUES(t.org('a'),t.id('tv'),t.id('main'),:'line_id',2);
INSERT INTO public.stock_reservations(organization_id,product_id,branch_id,order_line_id,quantity,status,released_at) VALUES(t.org('a'),t.id('tv'),t.id('main'),:'line_id',1,'released',now());
-- old: archived while it still holds stock; gone: archived with nothing.
SELECT t.as_user('a1000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.set_product_archived(t.id('old'),true);
SELECT public.set_product_archived(t.id('gone'),true);
RESET ROLE;

-- ---------------------------------------------------------------- the numbers (owner: every branch)
SELECT t.as_user('a1000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.list_stock(p_limit=>100) AS all_rows \gset
SELECT t.expect('tv in main: on hand 10-2-3=5, reserved 2, available 3, damaged 1, nothing in transit to main',
  (SELECT r->>'on_hand'='5' AND r->>'reserved'='2' AND r->>'available'='3' AND r->>'damaged'='1' AND r->>'in_transit'='0'
   FROM (SELECT t.row(:'all_rows'::jsonb,'tv','main') r) x), t.row(:'all_rows'::jsonb,'tv','main')::text);
SELECT t.expect('tv in second: on hand 1, 3 in transit',
  (SELECT r->>'on_hand'='1' AND r->>'in_transit'='3' AND r->>'available'='1' FROM (SELECT t.row(:'all_rows'::jsonb,'tv','second') r) x));
SELECT t.expect('min level: the product''s own, else the shop''s (3); low = available below it',
  (SELECT r->>'min_level'='3' AND r->>'low'='false' FROM (SELECT t.row(:'all_rows'::jsonb,'tv','main') r) x)
  AND (SELECT r->>'min_level'='3' AND r->>'low'='true' FROM (SELECT t.row(:'all_rows'::jsonb,'tv','second') r) x)
  AND (SELECT r->>'min_level'='10' AND r->>'low'='true' AND r->>'on_hand'='5' FROM (SELECT t.row(:'all_rows'::jsonb,'cable','main') r) x));
SELECT t.expect('a product with no stock shows zeros (and is low)',
  (SELECT r->>'on_hand'='0' AND r->>'available'='0' AND r->>'low'='true' FROM (SELECT t.row(:'all_rows'::jsonb,'empty','second') r) x));
SELECT t.expect('archived: shown while it holds stock, hidden once empty',
  t.row(:'all_rows'::jsonb,'old','main') IS NOT NULL AND t.row(:'all_rows'::jsonb,'old','main')->>'archived_at' IS NOT NULL
  AND t.row(:'all_rows'::jsonb,'old','second') IS NULL AND t.row(:'all_rows'::jsonb,'gone','main') IS NULL);
SELECT t.expect('every active product in every branch: 3 products x 2 branches + old in main = 7 rows',
  (:'all_rows'::jsonb->>'total')::int=7 AND jsonb_array_length(:'all_rows'::jsonb->'items')=7);
SELECT t.expect('order: product name, then the main branch first',
  (SELECT array_agg(r->>'sku' ORDER BY o) FROM jsonb_array_elements(:'all_rows'::jsonb->'items') WITH ORDINALITY x(r,o))
  =ARRAY['I01-TV','I01-TV','I01-CB','I01-CB','I01-EM','I01-EM','I01-OLD']
  AND (SELECT r->>'branch_id'=t.id('main')::text FROM jsonb_array_elements(:'all_rows'::jsonb->'items') r LIMIT 1));
RESET ROLE;

-- ---------------------------------------------------------------- Done when: every number equals its ledger sum
SELECT t.expect('Done when: on hand, damaged, reserved and in transit equal the ledger sums for every product and branch',
  NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(:'all_rows'::jsonb->'items') r
    WHERE (r->>'on_hand')::int <> COALESCE((SELECT sum(m.quantity) FROM public.stock_movements m
             WHERE m.organization_id=t.org('a') AND m.product_id=(r->>'product_id')::uuid
               AND m.branch_id=(r->>'branch_id')::uuid AND m.stock_state='sellable'),0)
       OR (r->>'damaged')::int <> COALESCE((SELECT sum(m.quantity) FROM public.stock_movements m
             WHERE m.organization_id=t.org('a') AND m.product_id=(r->>'product_id')::uuid
               AND m.branch_id=(r->>'branch_id')::uuid AND m.stock_state='damaged'),0)
       OR (r->>'reserved')::int <> COALESCE((SELECT sum(s.quantity) FROM public.stock_reservations s
             WHERE s.organization_id=t.org('a') AND s.product_id=(r->>'product_id')::uuid
               AND s.branch_id=(r->>'branch_id')::uuid AND s.status='active'),0)
       OR (r->>'in_transit')::int <> COALESCE((SELECT sum(l.qty_sent) FROM public.stock_transfer_lines l
             JOIN public.stock_transfers x ON x.id=l.transfer_id
             WHERE l.organization_id=t.org('a') AND l.product_id=(r->>'product_id')::uuid
               AND x.to_branch_id=(r->>'branch_id')::uuid AND x.status='sent'),0)
       OR (r->>'available')::int <> (r->>'on_hand')::int - (r->>'reserved')::int)
  AND NOT EXISTS (SELECT 1 FROM app.ledger_mismatches() WHERE organization_id=t.org('a')));

-- ---------------------------------------------------------------- filters
SELECT t.as_user('a1000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('branch filter',(SELECT (j->>'total')::int=4 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(j->'items') r WHERE r->>'branch_id'<>t.id('main')::text) FROM (SELECT public.list_stock(t.id('main')) j) x));
SELECT t.expect('category with subcategories (C01 helper) and without',
  (SELECT (j->>'total')::int=4 FROM (SELECT public.list_stock(NULL,t.id('screens')) j) x)
  AND (SELECT (j->>'total')::int=2 AND j->'items'->0->>'sku'='I01-EM' FROM (SELECT public.list_stock(NULL,t.id('screens'),false) j) x));
SELECT t.expect('search by name, SKU prefix and exact barcode',
  (SELECT (j->>'total')::int=2 FROM (SELECT public.list_stock(p_search=>'تلفزيون') j) x)
  AND (SELECT (j->>'total')::int=2 FROM (SELECT public.list_stock(p_search=>'i01-cb') j) x)
  AND (SELECT (j->>'total')::int=2 FROM (SELECT public.list_stock(p_search=>(SELECT barcode FROM public.products WHERE id=t.id('cable')))j) x));
SELECT t.expect('low only: available below the min level',
  (SELECT array_agg(r->>'sku'||'@'||(CASE WHEN r->>'branch_id'=t.id('main')::text THEN 'main' ELSE 'second' END) ORDER BY o)
   =ARRAY['I01-TV@second','I01-CB@main','I01-CB@second','I01-EM@main','I01-EM@second','I01-OLD@main']
   FROM jsonb_array_elements(public.list_stock(p_low_only=>true)->'items') WITH ORDINALITY x(r,o)),
  (SELECT string_agg(r->>'sku'||':'||(r->>'available')||'<'||(r->>'min_level'),', ') FROM jsonb_array_elements(public.list_stock(p_low_only=>true,p_limit=>100)->'items') r));
SELECT t.expect('paging keeps the full total',
  (SELECT (j->>'total')::int=7 AND jsonb_array_length(j->'items')=1 FROM (SELECT public.list_stock(p_limit=>2,p_offset=>6) j) x));
SELECT t.error('page size above 100',$q$SELECT public.list_stock(p_limit=>101)$q$,'VALIDATION_FAILED');
SELECT t.error('another shop branch',format('SELECT public.list_stock(%L)',t.id('main_b')),'BRANCH_NOT_FOUND');
SELECT t.expect('another shop''s products never show',NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_stock(p_limit=>100)->'items') r WHERE r->>'product_id'=t.id('tv_b')::text));
RESET ROLE;

-- ---------------------------------------------------------------- branch scope and permission
SELECT t.as_user('a1000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier: only the branches they work in',
  (SELECT (j->>'total')::int=4 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(j->'items') r WHERE r->>'branch_id'=t.id('second')::text) FROM (SELECT public.list_stock() j) x));
SELECT t.error('cashier: another branch of the shop',format('SELECT public.list_stock(%L)',t.id('second')),'BRANCH_DENIED');
SELECT t.error('cashier: movements of another branch',format('SELECT public.list_stock_movements(%L,%L)',t.id('tv'),t.id('second')),'BRANCH_DENIED');
SELECT t.as_user('a1000000-0000-0000-8000-000000000004',t.org('a'));
SELECT t.error('no stock.view: stock',$q$SELECT public.list_stock()$q$,'PERMISSION_DENIED');
SELECT t.error('no stock.view: movements',format('SELECT public.list_stock_movements(%L)',t.id('tv')),'PERMISSION_DENIED');
SELECT t.as_user('a1000000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee',$q$SELECT public.list_stock()$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;
-- A read works in an expired (read-only) shop.
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.expect('the shop is expired for this check',app.org_is_expired(t.org('a')));
SELECT t.as_user('a1000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the stock view and the movements still read',
  (public.list_stock()->>'total')::int=7 AND (public.list_stock_movements(t.id('tv'))->>'total')::int=5);
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
-- ---------------------------------------------------------------- drill-down: movements with running balance
SELECT t.as_user('a1000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.list_stock_movements(t.id('tv'),t.id('main')) AS mv \gset
SELECT t.expect('movements: newest first, running balance per branch and stock state',
  (:'mv'::jsonb->>'total')::int=4
  AND (SELECT array_agg((r->>'quantity')||'/'||(r->>'balance_after')||'/'||(r->>'stock_state') ORDER BY o)
       FROM jsonb_array_elements(:'mv'::jsonb->'items') WITH ORDINALITY x(r,o))
     =ARRAY['-3/5/sellable','1/1/damaged','-2/8/sellable','10/10/sellable'],
  :'mv'::text);
SELECT t.expect('the newest balance equals the stock view''s on hand',
  (:'mv'::jsonb->'items'->0->>'balance_after')=(t.row(:'all_rows'::jsonb,'tv','main')->>'on_hand'));
SELECT t.expect('each movement names its type and source document',
  (SELECT bool_and(r->>'type' IS NOT NULL AND r->>'source_type'='stock_adjustment' AND r->>'source_id' IS NOT NULL)
   FROM jsonb_array_elements(:'mv'::jsonb->'items') r));
SELECT t.expect('all branches in scope when no branch is given',(public.list_stock_movements(t.id('tv'))->>'total')::int=5);
SELECT t.expect('paging',(SELECT jsonb_array_length(j->'items')=1 AND (j->>'total')::int=4 AND j->'items'->0->>'quantity'='10' FROM (SELECT public.list_stock_movements(t.id('tv'),t.id('main'),1,3) j) x));
SELECT t.error('another shop product',format('SELECT public.list_stock_movements(%L)',t.id('tv_b')),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop branch (movements)',format('SELECT public.list_stock_movements(%L,%L)',t.id('tv'),t.id('main_b')),'BRANCH_NOT_FOUND');
RESET ROLE;

-- ---------------------------------------------------------------- read only, grants
SELECT t.expect('the reads wrote no audit rows',NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action LIKE 'stock%'));
SELECT t.expect('no anon grants',
  NOT has_function_privilege('anon','public.list_stock(uuid,uuid,boolean,text,boolean,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.list_stock_movements(uuid,uuid,integer,integer,text,public.stock_movement_type[],date,date)','EXECUTE'));
SELECT t.expect('authenticated may execute both',
  has_function_privilege('authenticated','public.list_stock(uuid,uuid,boolean,text,boolean,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_stock_movements(uuid,uuid,integer,integer,text,public.stock_movement_type[],date,date)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
