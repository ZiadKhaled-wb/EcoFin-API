\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- The error's DETAIL (SERIAL_TAKEN lists the serials there).
CREATE FUNCTION t.detail(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL; RETURN d; END; RETURN NULL; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.units WHERE serial=s AND organization_id=t.org('a') $$;
CREATE FUNCTION t.level(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0) $$;
CREATE FUNCTION t.reg(serials jsonb,k text,c text DEFAULT '7000.50') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.register_units(t.id('phone'),t.id('main'),c,serials,'Shelf stock',k) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (retail_pro: serials), shop b (retail: none)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('I04 '||s,'i04-'||s,p,'Owner',s||'i04@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a','retail_pro',repeat('t',64)),('b','retail',repeat('u',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a4000000-0000-0000-8000-000000000001','ai04@example.com'),('a4000000-0000-0000-8000-000000000002','bi04@example.com'),('a4000000-0000-0000-8000-000000000003','i04cashier@example.com'),('a4000000-0000-0000-8000-000000000004','i04keeper@example.com');
SELECT public.accept_invite(repeat('t',64),'a4000000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('u',64),'a4000000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a4000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','I4',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"أ موبايل","name_en":"Phone","sku":"I04-PH","cash_price":"9000","is_serialized":true}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"ب كابل","sku":"I04-CB","cash_price":"5"}'));
INSERT INTO t.ids VALUES('old',public.create_product('{"name_ar":"ج قديم","sku":"I04-OLD","cash_price":"5","is_serialized":true}'));
SELECT public.set_product_archived(t.id('old'),true);
RESET ROLE;
SELECT t.as_user('a4000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('phone_b',public.create_product('{"name_ar":"موبايل ب","sku":"I04-PH","cash_price":"9000","is_serialized":true}'));
RESET ROLE;
-- The cashier (stock.view) works in main; the keeper (WAREHOUSE + stock.adjust) in main only.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a4000000-0000-0000-8000-000000000003','I04 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a4000000-0000-0000-8000-000000000004','I04 Keeper','WAREHOUSE',t.id('main')) RETURNING id AS keeper_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'keeper_id',t.id('main'));
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),:'keeper_id','stock.adjust',true);

-- ---------------------------------------------------------------- register
SELECT t.as_user('a4000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.reg('[" imei-001 ","IMEI-002","imei-003"]','i04-register-1') AS r1 \gset
SELECT t.expect('three serials registered: trimmed, upper-cased, in stock in main at their cost',
  (:'r1'::jsonb->>'count')::int=3 AND :'r1'::jsonb->>'import_job_id' IS NOT NULL AND NOT (:'r1'::jsonb ? 'idempotency_key')
  AND (SELECT array_agg(serial ORDER BY serial)=ARRAY['IMEI-001','IMEI-002','IMEI-003']
       AND bool_and(status='in_stock' AND branch_id=t.id('main') AND cost=7000.50)
       FROM public.units WHERE organization_id=t.org('a') AND product_id=t.id('phone'))
  AND t.level('phone','main')=3, :'r1'::text);
SELECT t.expect('one opening movement per unit, from the import job, at the unit cost',
  (SELECT count(*)=3 AND bool_and(type='opening' AND source_type='import' AND quantity=1 AND unit_cost=7000.50)
   FROM public.stock_movements WHERE source_id=(:'r1'::jsonb->>'import_job_id')::uuid)
  AND (SELECT kind='opening_stock' AND status='completed' AND rows_ok=3 FROM public.import_jobs WHERE id=(:'r1'::jsonb->>'import_job_id')::uuid));
SELECT t.expect('same key again: the same batch, nothing created twice',
  (t.reg('["OTHER-9"]','i04-register-1')->>'import_job_id')=(:'r1'::jsonb->>'import_job_id') AND t.level('phone','main')=3);
SELECT t.error('Done when: a serial already in the shop is rejected (any letter case)',$q$SELECT t.reg('["imei-001","IMEI-004"]','i04-register-2')$q$,'SERIAL_TAKEN');
SELECT t.expect('the rejection names the serial, and nothing of the batch was created',
  t.detail($q$SELECT t.reg('["imei-001","IMEI-004"]','i04-register-2b')$q$)::jsonb->'serials'='["IMEI-001"]'::jsonb
  AND t.unit('IMEI-004') IS NULL);
SELECT t.error('Done when: a serial twice in one batch is rejected',$q$SELECT t.reg('["IMEI-005","imei-005"]','i04-register-3')$q$,'SERIAL_TAKEN');
SELECT t.error('an unusable serial',$q$SELECT t.reg('["bad serial!"]','i04-register-4')$q$,'SERIAL_INVALID');
SELECT t.error('no serials',$q$SELECT t.reg('[]','i04-register-5')$q$,'VALIDATION_FAILED');
SELECT t.error('a cost that is not money',$q$SELECT t.reg('["IMEI-006"]','i04-register-6','12.345')$q$,'VALIDATION_FAILED');
SELECT t.error('a product without serials',format($q$SELECT public.register_units(%L,%L,'1','["X-1"]',NULL,'i04-register-7')$q$,t.id('cable'),t.id('main')),'UNIT_NOT_ALLOWED');
SELECT t.error('an archived product',format($q$SELECT public.register_units(%L,%L,'1','["X-2"]',NULL,'i04-register-8')$q$,t.id('old'),t.id('main')),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s product',format($q$SELECT public.register_units(%L,%L,'1','["X-3"]',NULL,'i04-register-9')$q$,t.id('phone_b'),t.id('main')),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s branch',format($q$SELECT public.register_units(%L,%L,'1','["X-4"]',NULL,'i04-register-10')$q$,t.id('phone'),t.id('main_b')),'BRANCH_NOT_FOUND');
SELECT t.error('a system: key',$q$SELECT t.reg('["X-5"]','system:units/1')$q$,'VALIDATION_FAILED');
SELECT public.register_units(t.id('phone'),t.id('second'),'6500','["IMEI-010"]',NULL,'i04-register-11') AS r2 \gset
RESET ROLE;
SELECT t.expect('audit: one units.registered row per batch, with the serials',
  (SELECT count(*)=2 FROM public.audit_log WHERE organization_id=t.org('a') AND action='units.registered')
  AND (SELECT after->'serials'='["IMEI-001","IMEI-002","IMEI-003"]'::jsonb AND reason='Shelf stock' FROM public.audit_log
       WHERE entity_id=(:'r1'::jsonb->>'import_job_id')::uuid));
SELECT t.as_user('a4000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('the keeper: a branch they don''t work in',format($q$SELECT public.register_units(%L,%L,'1','["X-6"]',NULL,'i04-register-12')$q$,t.id('phone'),t.id('second')),'BRANCH_DENIED');
SELECT t.as_user('a4000000-0000-0000-8000-000000000003',t.org('a'));
SELECT t.error('a cashier (no stock.adjust)',$q$SELECT t.reg('["X-7"]','i04-register-13')$q$,'PERMISSION_DENIED');
SELECT t.as_user('a4000000-0000-0000-8000-000000000002',t.org('b'));
SELECT t.error('a plan without the serials module',format($q$SELECT public.register_units(%L,%L,'1','["X-8"]',NULL,'i04-register-14')$q$,t.id('phone_b'),t.id('main_b')),'MODULE_NOT_IN_PLAN');
RESET ROLE;

-- ---------------------------------------------------------------- Done when: no sale of a unit that is not here
-- Sales are S01; the ledger trigger is what refuses (superuser inserts, as the sale function will).
INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('a'),'I04 Buyer') RETURNING id AS buyer \gset
INSERT INTO public.sales(organization_id,number,branch_id,customer_id,prices_include_vat,subtotal,total,idempotency_key)
VALUES(t.org('a'),'MAIN-SL-26-000001',t.id('main'),:'buyer',true,9000,9000,'i04-sale-1') RETURNING id AS sale \gset
SELECT t.error('Done when: selling IMEI-010 in main while it is in second',
  format($q$INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,source_type,source_id) VALUES(%L,%L,%L,%L,-1,'sale_out','sale',%L)$q$,
         t.org('a'),t.id('phone'),t.id('main'),t.unit('IMEI-010'),:'sale'),'UNIT_NOT_AVAILABLE');
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,source_type,source_id)
VALUES(t.org('a'),t.id('phone'),t.id('main'),t.unit('IMEI-001'),-1,'sale_out','sale',:'sale');
SELECT t.error('Done when: selling IMEI-001 again',
  format($q$INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,source_type,source_id) VALUES(%L,%L,%L,%L,-1,'sale_out','sale',%L)$q$,
         t.org('a'),t.id('phone'),t.id('main'),t.unit('IMEI-001'),:'sale'),'UNIT_NOT_AVAILABLE');
SELECT t.expect('the sold unit is sold, main has 2 left',(SELECT status='sold' FROM public.units WHERE id=t.unit('IMEI-001')) AND t.level('phone','main')=2);

-- IMEI-002 travels to second (I03), then is written off there (I02): its history must show it all.
SELECT t.as_user('a4000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.create_stock_transfer(t.id('main'),t.id('second'),NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.unit('IMEI-002'),'quantity',1)),'i04-transfer-1') AS tr \gset
SELECT public.send_stock_transfer((:'tr'::jsonb->>'id')::uuid), public.receive_stock_transfer((:'tr'::jsonb->>'id')::uuid,'[]');
SELECT public.post_stock_adjustment(t.id('second'),'damage','Screen broken',
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.unit('IMEI-002'),'quantity',-1)),'i04-adjust-1') AS adj \gset

-- ---------------------------------------------------------------- Done when: the history shows every step
SELECT public.find_unit(' imei-002 ') AS h2 \gset
-- (This file is one transaction, so every row has the same created_at: compare the steps as a set;
-- in use each step is its own request and the history is in time order.)
SELECT t.expect('Done when: received -> transferred out and in -> written off, with documents and branches',
  (SELECT array_agg(x ORDER BY x) FROM (SELECT r->>'type'||'@'||(r->>'branch_name')||'#'||COALESCE(r->>'source_number','-') AS x
   FROM jsonb_array_elements(:'h2'::jsonb->'history') r) h)
  =(SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY['opening@Main#-','transfer_out@Main#'||(:'tr'::jsonb->>'number'),
         'transfer_in@Second#'||(:'tr'::jsonb->>'number'),'adjustment@Second#'||(:'adj'::jsonb->>'number')]) x)
  AND :'h2'::jsonb->>'status'='written_off' AND :'h2'::jsonb->>'branch_name'='Second'
  AND (SELECT r->>'party_name'='Main → Second' FROM jsonb_array_elements(:'h2'::jsonb->'history') r WHERE r->>'type'='transfer_out')
  AND (SELECT r->>'reason'='damage' FROM jsonb_array_elements(:'h2'::jsonb->'history') r WHERE r->>'type'='adjustment')
  AND :'h2'::jsonb->>'cost'='7000.50' AND :'h2'::jsonb->>'serial'='IMEI-002',
  (SELECT string_agg(r->>'type'||'@'||(r->>'branch_name')||'#'||COALESCE(r->>'source_number','-')||' party='||COALESCE(r->>'party_name','-'),' | ')
   FROM jsonb_array_elements(:'h2'::jsonb->'history') r));
SELECT t.expect('Done when: a sold unit shows to whom',
  (SELECT r->>'type'='sale_out' AND r->>'source_number'='MAIN-SL-26-000001' AND r->>'party_name'='I04 Buyer'
   FROM jsonb_array_elements(public.get_unit(t.unit('IMEI-001'))->'history') r WHERE r->>'quantity'='-1'));
SELECT t.error('an unknown serial',$q$SELECT public.find_unit('NOPE-1')$q$,'UNIT_NOT_FOUND');
SELECT t.expect('search: serial prefix in my branches, status filter, paging',
  (public.search_units('imei')->>'total')::int=4
  AND (public.search_units('imei',p_status=>'in_stock')->>'total')::int=2
  AND (public.search_units(p_branch_id=>t.id('second'))->>'total')::int=2
  AND jsonb_array_length(public.search_units('imei',p_limit=>1)->'items')=1
  AND public.search_units('imei-00')->'items'->0->>'serial'='IMEI-001');
SELECT t.expect('the I01 drill-down now names transfers too',
  (SELECT bool_and(r->>'source_number'=(:'tr'::jsonb->>'number'))
   FROM jsonb_array_elements(public.list_stock_movements(t.id('phone'))->'items') r WHERE r->>'source_type'='transfer'));
RESET ROLE;

-- ---------------------------------------------------------------- scope, permissions, tenant
SELECT t.as_user('a4000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('a cashier in main finds main''s units only',
  (public.search_units('imei')->>'total')::int=2 AND (public.get_unit(t.unit('IMEI-003'))->>'serial')='IMEI-003');
SELECT t.error('a cashier: a unit now in second',$q$SELECT public.find_unit('IMEI-010')$q$,'BRANCH_DENIED');
SELECT t.as_user('a4000000-0000-0000-8000-000000000002',t.org('b'));
SELECT t.error('shop b: shop a''s serial',$q$SELECT public.find_unit('IMEI-003')$q$,'UNIT_NOT_FOUND');
SELECT t.error('shop b: shop a''s unit id',format('SELECT public.get_unit(%L)',t.unit('IMEI-003')),'UNIT_NOT_FOUND');
SELECT t.expect('shop b: nothing found',(public.search_units('imei')->>'total')::int=0);
RESET ROLE;
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
-- An expired shop reads but doesn't register.
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a4000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: units still read',(public.search_units()->>'total')::int=4);
SELECT t.error('expired shop: no registering',$q$SELECT t.reg('["X-9"]','i04-register-15')$q$,'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('no anon grants; authenticated may execute the public functions; helpers stay private',
  NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
              AND p.proname IN ('register_units','get_unit','find_unit','search_units')
              AND (has_function_privilege('anon',p.oid,'EXECUTE') OR NOT has_function_privilege('authenticated',p.oid,'EXECUTE')))
  AND NOT has_function_privilege('authenticated','app.create_units(uuid,uuid,uuid,uuid,text[],numeric,public.stock_movement_type,public.doc_type,uuid,uuid)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
