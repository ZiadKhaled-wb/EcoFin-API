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
-- A sellable ledger movement (superuser).
CREATE FUNCTION t.move(p text,b text,q integer) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id)
  VALUES(t.org('a'),t.id(p),t.id(b),q,'opening','import',gen_random_uuid()) $$;
-- One product/branch row of list_stock (every row, low or not).
CREATE FUNCTION t.stock(p text,b text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT r FROM jsonb_array_elements(public.list_stock(p_limit=>100)->'items') r
  WHERE r->>'product_id'=t.id(p)::text AND r->>'branch_id'=t.id(b)::text $$;
-- "level/source/low" of a product in a branch.
CREATE FUNCTION t.lvl(p text,b text) RETURNS text LANGUAGE sql AS $$
  SELECT (r->>'min_level')||'/'||(r->>'min_source')||'/'||(r->>'low') FROM (SELECT t.stock(p,b) r) x $$;
CREATE FUNCTION t.is_low_listed(p text,b text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_stock(p_low_only=>true,p_limit=>100)->'items') r
                WHERE r->>'product_id'=t.id(p)::text AND r->>'branch_id'=t.id(b)::text) $$;
CREATE FUNCTION t.on_dashboard(p text,b text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS(SELECT 1 FROM jsonb_array_elements(public.low_stock_summary(20)->'items') r
                WHERE r->>'product_id'=t.id(p)::text AND r->>'branch_id'=t.id(b)::text) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (2 branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('I06 '||s,'i06-'||s,'retail','Owner',s||'i06@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('x',64)),('b',repeat('y',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a6000000-0000-0000-8000-000000000001','ai06@example.com'),('a6000000-0000-0000-8000-000000000002','bi06@example.com'),
  ('a6000000-0000-0000-8000-000000000003','i06cashier@example.com'),('a6000000-0000-0000-8000-000000000004','i06manager@example.com'),
  ('a6000000-0000-0000-8000-000000000005','i06collector@example.com');
SELECT public.accept_invite(repeat('x',64),'a6000000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a6000000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a6000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','I6',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('closed',public.create_branch('Closed','I6C',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"أ تلفزيون","name_en":"TV","sku":"I06-TV","cash_price":"100"}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"ب كابل","sku":"I06-CB","cash_price":"5","min_stock":10}'));
INSERT INTO t.ids VALUES('old',public.create_product('{"name_ar":"ج قديم","sku":"I06-OLD","cash_price":"5","min_stock":10}'));
RESET ROLE;
SELECT t.as_user('a6000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('tv_b',public.create_product('{"name_ar":"تلفزيون ب","sku":"I06-TV","cash_price":"100"}'));
RESET ROLE;
-- Cashier: stock.view in main. Manager: BRANCH_MANAGER (catalog.manage) in main only. Collector: no stock.view.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a6000000-0000-0000-8000-000000000003','I06 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a6000000-0000-0000-8000-000000000004','I06 Manager','BRANCH_MANAGER',t.id('main')) RETURNING id AS manager_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'manager_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a6000000-0000-0000-8000-000000000005','I06 Collector','COLLECTOR');
-- Stock: tv main 5, second 1; cable main 5, second 20; old (archived below) main 1.
SELECT t.move('tv','main',5), t.move('tv','second',1), t.move('cable','main',5), t.move('cable','second',20), t.move('old','main',1);
UPDATE public.branches SET is_active=false WHERE id=t.id('closed');
SELECT t.as_user('a6000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.set_product_archived(t.id('old'),true);
RESET ROLE;

-- ---------------------------------------------------------------- default levels: product, else shop (3)
SELECT t.as_user('a6000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('no override: the shop''s 3 for tv, the product''s 10 for cable',
  t.lvl('tv','main')='3/shop/false' AND t.lvl('tv','second')='3/shop/true'
  AND t.lvl('cable','main')='10/product/true' AND t.lvl('cable','second')='10/product/false',
  concat_ws(' ',t.lvl('tv','main'),t.lvl('tv','second'),t.lvl('cable','main'),t.lvl('cable','second')));
SELECT t.expect('a deactivated branch never alerts and is not on the dashboard',
  t.lvl('tv','closed')='3/shop/false' AND NOT t.is_low_listed('tv','closed')
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.low_stock_summary()->'branches') r WHERE r->>'branch_id'=t.id('closed')::text));
SELECT t.expect('an archived product is never low (it still shows while it holds stock)',
  t.lvl('old','main')='10/product/false' AND NOT t.is_low_listed('old','main') AND NOT t.on_dashboard('old','main'));

-- ---------------------------------------------------------------- per-branch overrides (user decision)
SELECT public.set_branch_min_level(t.id('tv'),t.id('main'),8) AS set1 \gset
SELECT t.expect('an override wins in its branch only; the reply lists every branch',
  t.lvl('tv','main')='8/branch/true' AND t.lvl('tv','second')='3/shop/true'
  AND (SELECT r->>'min_stock'='8' AND r->>'min_level'='8' AND r->>'min_source'='branch'
       FROM jsonb_array_elements(:'set1'::jsonb->'branches') r WHERE r->>'branch_id'=t.id('main')::text)
  AND (SELECT r->>'min_stock' IS NULL AND r->>'min_level'='3' AND r->>'min_source'='shop'
       FROM jsonb_array_elements(:'set1'::jsonb->'branches') r WHERE r->>'branch_id'=t.id('second')::text)
  AND :'set1'::jsonb->>'product_min_stock'='0' AND :'set1'::jsonb->>'shop_min_stock'='3', :'set1'::text);
SELECT public.set_branch_min_level(t.id('cable'),t.id('main'),0);
SELECT public.set_branch_min_level(t.id('cable'),t.id('second'),25);
SELECT t.expect('0 in a branch = never low there; above the stock = low there',
  t.lvl('cable','main')='0/branch/false' AND t.lvl('cable','second')='25/branch/true');
SELECT public.set_branch_min_level(t.id('cable'),t.id('second'),30);
SELECT t.expect('setting again updates the one row',
  (SELECT count(*)=1 AND bool_and(min_stock=30) FROM public.product_branch_min_stock WHERE product_id=t.id('cable') AND branch_id=t.id('second')));
SELECT public.set_branch_min_level(t.id('cable'),t.id('main'),NULL);
SELECT t.expect('NULL removes the override: back to the product''s level',
  t.lvl('cable','main')='10/product/true'
  AND NOT EXISTS(SELECT 1 FROM public.product_branch_min_stock WHERE product_id=t.id('cable') AND branch_id=t.id('main')));
SELECT t.expect('list_branch_min_levels: the product''s level in each branch and its source',
  (SELECT array_agg((r->>'min_level')||'/'||(r->>'min_source') ORDER BY o)
   FROM jsonb_array_elements(public.list_branch_min_levels(t.id('cable'))->'branches') WITH ORDINALITY x(r,o))
  =ARRAY['10/product','30/branch','10/product']);

-- ---------------------------------------------------------------- Done when: in the list and on the dashboard
SELECT public.low_stock_summary() AS dash \gset
SELECT t.expect('Done when: every product below its min level is in the low list and on the dashboard',
  t.is_low_listed('tv','main') AND t.on_dashboard('tv','main')
  AND t.is_low_listed('tv','second') AND t.on_dashboard('tv','second')
  AND t.is_low_listed('cable','main') AND t.on_dashboard('cable','main')
  AND t.is_low_listed('cable','second') AND t.on_dashboard('cable','second'));
SELECT t.expect('the dashboard and the low list agree on every row',
  (public.low_stock_summary(20)->>'total')::int=(public.list_stock(p_low_only=>true)->>'total')::int
  AND (public.low_stock_summary(20)->>'total')::int=4, :'dash'::text);
SELECT t.expect('dashboard: count per branch (main first) and the biggest shortages first',
  (SELECT array_agg(r->>'low' ORDER BY o) FROM jsonb_array_elements(:'dash'::jsonb->'branches') WITH ORDINALITY x(r,o))=ARRAY['2','2']
  AND (SELECT array_agg((r->>'sku')||':'||(r->>'shortage') ORDER BY o) FROM jsonb_array_elements(:'dash'::jsonb->'items') WITH ORDINALITY x(r,o))
     =ARRAY['I06-CB:10','I06-CB:5','I06-TV:3','I06-TV:2'],
  :'dash'::text);
SELECT t.expect('dashboard limit',jsonb_array_length(public.low_stock_summary(1)->'items')=1 AND (public.low_stock_summary(1)->>'total')::int=4);
SELECT t.expect('a product back above its level leaves both',
  (SELECT public.set_branch_min_level(t.id('tv'),t.id('main'),5)) IS NOT NULL
  AND NOT t.is_low_listed('tv','main') AND NOT t.on_dashboard('tv','main'));

-- ---------------------------------------------------------------- refusals
SELECT t.error('min below 0',format('SELECT public.set_branch_min_level(%L,%L,-1)',t.id('tv'),t.id('main')),'VALIDATION_FAILED');
SELECT t.error('min above 1 000 000',format('SELECT public.set_branch_min_level(%L,%L,1000001)',t.id('tv'),t.id('main')),'VALIDATION_FAILED');
SELECT t.error('another shop''s product',format('SELECT public.set_branch_min_level(%L,%L,1)',t.id('tv_b'),t.id('main')),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s branch',format('SELECT public.set_branch_min_level(%L,%L,1)',t.id('tv'),t.id('main_b')),'BRANCH_NOT_FOUND');
SELECT t.error('an inactive branch',format('SELECT public.set_branch_min_level(%L,%L,1)',t.id('tv'),t.id('closed')),'BRANCH_INACTIVE');
SELECT t.error('levels of another shop''s product',format('SELECT public.list_branch_min_levels(%L)',t.id('tv_b')),'PRODUCT_NOT_FOUND');
SELECT t.error('dashboard limit above 20',$q$SELECT public.low_stock_summary(21)$q$,'VALIDATION_FAILED');
RESET ROLE;
SELECT t.as_user('a6000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('branch manager: sets a level in the branch they run',
  (public.set_branch_min_level(t.id('tv'),t.id('main'),6)->'branches'->0->>'min_level')='6');
SELECT t.error('branch manager: another branch',format('SELECT public.set_branch_min_level(%L,%L,1)',t.id('tv'),t.id('second')),'BRANCH_DENIED');
SELECT t.as_user('a6000000-0000-0000-8000-000000000003',t.org('a'));
SELECT t.error('cashier (no catalog.manage)',format('SELECT public.set_branch_min_level(%L,%L,1)',t.id('tv'),t.id('main')),'PERMISSION_DENIED');
SELECT t.expect('cashier: dashboard and levels for their branch only',
  (SELECT array_agg(r->>'branch_id') FROM jsonb_array_elements(public.low_stock_summary()->'branches') r)=ARRAY[t.id('main')::text]
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.low_stock_summary(20)->'items') r WHERE r->>'branch_id'<>t.id('main')::text)
  AND (SELECT array_agg(r->>'branch_id') FROM jsonb_array_elements(public.list_branch_min_levels(t.id('cable'))->'branches') r)=ARRAY[t.id('main')::text]);
SELECT t.as_user('a6000000-0000-0000-8000-000000000005',t.org('a'));
SELECT t.error('no stock.view: dashboard',$q$SELECT public.low_stock_summary()$q$,'PERMISSION_DENIED');
SELECT t.error('no stock.view: levels',format('SELECT public.list_branch_min_levels(%L)',t.id('tv')),'PERMISSION_DENIED');
SELECT t.as_user('a6000000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee',$q$SELECT public.low_stock_summary()$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;

-- ---------------------------------------------------------------- audit, tenancy, expired shop
SELECT t.expect('every change is audited with the branch, before and after',
  (SELECT count(*)=7 FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock.min_level_set')
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock.min_level_set'
             AND entity_type='product' AND entity_id=t.id('cable') AND branch_id=t.id('second')
             AND before->>'min_stock'='25' AND after->>'min_stock'='30')
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock.min_level_set'
             AND entity_id=t.id('cable') AND before->>'min_stock'='0' AND after->'min_stock'='null'::jsonb));
SELECT t.as_user('a6000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.expect('shop b sees none of shop a''s overrides (RLS)',NOT EXISTS(SELECT 1 FROM public.product_branch_min_stock));
SELECT t.error('no direct writes',format('INSERT INTO public.product_branch_min_stock(organization_id,product_id,branch_id,min_stock) VALUES(%L,%L,%L,1)',t.org('b'),t.id('tv_b'),t.id('main_b')),'permission denied for table product_branch_min_stock');
RESET ROLE;
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a6000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the dashboard and the levels still read',
  (public.low_stock_summary()->>'total')::int>0 AND jsonb_array_length(public.list_branch_min_levels(t.id('tv'))->'branches')=3);
SELECT t.error('expired shop: no level changes',format('SELECT public.set_branch_min_level(%L,%L,1)',t.id('tv'),t.id('main')),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ---------------------------------------------------------------- grants
SELECT t.expect('no anon grants',
  NOT has_function_privilege('anon','public.low_stock_summary(integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.set_branch_min_level(uuid,uuid,integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.list_branch_min_levels(uuid)','EXECUTE')
  AND NOT has_table_privilege('anon','public.product_branch_min_stock','SELECT'));
SELECT t.expect('authenticated runs the three functions, not the helpers',
  has_function_privilege('authenticated','public.low_stock_summary(integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_branch_min_level(uuid,uuid,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_branch_min_levels(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.branch_min_levels_json(uuid,uuid,uuid[])','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
