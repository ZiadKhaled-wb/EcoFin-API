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
-- The serials of a list_product_units answer, in order.
CREATE FUNCTION t.serials(j jsonb) RETURNS text[] LANGUAGE sql AS $$ SELECT COALESCE(array_agg(x->>'serial' ORDER BY o),ARRAY[]::text[]) FROM jsonb_array_elements(j) WITH ORDINALITY a(x,o) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: two shops; shop a has two branches
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('C03 '||s,'c03-'||s,'retail','Owner',s||'c03@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('k',64)),('b',repeat('l',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('c0300000-0000-0000-8000-000000000001','ac03@example.com'),('c0300000-0000-0000-8000-000000000002','bc03@example.com'),('c0300000-0000-0000-8000-000000000003','c03cashier@example.com');
SELECT public.accept_invite(repeat('k',64),'c0300000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('l',64),'c0300000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main_a',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
-- The cashier works in shop a's main branch only.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'c0300000-0000-0000-8000-000000000003','C03 Cashier','CASHIER',t.id('main_a')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main_a'));

SELECT t.as_user('c0300000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second_a',public.create_branch('Second','C3',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"موبايل","sku":"C03-PH","cash_price":"9000","is_serialized":true}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"كابل","sku":"C03-CB","cash_price":"50"}'));
RESET ROLE;
SELECT t.as_user('c0300000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('phone_b',public.create_product('{"name_ar":"موبايل ب","sku":"C03-PH","cash_price":"9000","is_serialized":true}'));
RESET ROLE;

-- Units (written directly here: purchases and opening stock come in later slices).
INSERT INTO public.units(organization_id,product_id,serial,branch_id,cost,status) VALUES
  (t.org('a'),t.id('phone'),'IMEI-B',t.id('main_a'),100,'in_stock'),
  (t.org('a'),t.id('phone'),'IMEI-A',t.id('main_a'),100,'in_stock'),
  (t.org('a'),t.id('phone'),'IMEI-C',t.id('main_a'),100,'sold'),
  (t.org('a'),t.id('phone'),'IMEI-D',t.id('second_a'),100,'in_stock'),
  (t.org('b'),t.id('phone_b'),'IMEI-X',t.id('main_b'),100,'in_stock');

-- ---------------------------------------------------------------- owner: every branch
SELECT t.as_user('c0300000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('owner: in-stock units of every branch, in serial order (default status)',
  t.serials(public.list_product_units(t.id('phone')))=ARRAY['IMEI-A','IMEI-B','IMEI-D'],
  public.list_product_units(t.id('phone'))::text);
SELECT t.expect('each unit carries id, serial, branch and status',
  (SELECT u ? 'id' AND u->>'branch_id'=t.id('second_a')::text AND u->>'status'='in_stock'
   FROM jsonb_array_elements(public.list_product_units(t.id('phone'))) u WHERE u->>'serial'='IMEI-D'));
SELECT t.expect('status sold',t.serials(public.list_product_units(t.id('phone'),'sold'))=ARRAY['IMEI-C']);
SELECT t.expect('status all',t.serials(public.list_product_units(t.id('phone'),'all'))=ARRAY['IMEI-A','IMEI-B','IMEI-C','IMEI-D']);
SELECT t.expect('a product without units answers an empty list',public.list_product_units(t.id('cable'))='[]'::jsonb);
SELECT t.error('unknown status',format('SELECT public.list_product_units(%L,%L)',t.id('phone'),'lost'),'VALIDATION_FAILED');
SELECT t.error('another shop product',format('SELECT public.list_product_units(%L)',t.id('phone_b')),'PRODUCT_NOT_FOUND');
SELECT t.error('missing product',$q$SELECT public.list_product_units('00000000-0000-0000-0000-0000000000dd')$q$,'PRODUCT_NOT_FOUND');
RESET ROLE;

-- ---------------------------------------------------------------- cashier: own branch only
SELECT t.as_user('c0300000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier: only units in branches they can access',
  t.serials(public.list_product_units(t.id('phone'),'all'))=ARRAY['IMEI-A','IMEI-B','IMEI-C']);
SELECT t.as_user('c0300000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee',format('SELECT public.list_product_units(%L)',t.id('phone')),'NOT_AN_EMPLOYEE');
RESET ROLE;

-- ---------------------------------------------------------------- shop b sees its own unit only
SELECT t.as_user('c0300000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.expect('shop b: its own unit',t.serials(public.list_product_units(t.id('phone_b')))=ARRAY['IMEI-X']);
SELECT t.error('shop b: shop a product',format('SELECT public.list_product_units(%L)',t.id('phone')),'PRODUCT_NOT_FOUND');
RESET ROLE;

-- ---------------------------------------------------------------- read only, grants
SELECT t.expect('no audit row from the reads',
  NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id IN (t.org('a'),t.org('b')) AND entity_type='unit'));
SELECT t.expect('no anon grant',
  NOT has_function_privilege('anon','public.list_product_units(uuid,text)','EXECUTE'));
SELECT t.expect('authenticated may execute',
  has_function_privilege('authenticated','public.list_product_units(uuid,text)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
