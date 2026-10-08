\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.detail(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL; RETURN d; END; RETURN NULL; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.units WHERE serial=s AND organization_id=t.org('a') $$;
-- A ledger movement (superuser) from the opening import job, in time order (this file is one
-- transaction, so now() is the same for every document; clock_timestamp() orders these rows).
CREATE FUNCTION t.move(p text,b text,q integer,ty public.stock_movement_type,st public.stock_state DEFAULT 'sellable',d date DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,stock_state,source_type,source_id,business_date,created_at)
  VALUES(t.org('a'),t.id(p),t.id(b),q,ty,st,'import',t.id('job'),d,clock_timestamp()) $$;
-- Does the source document of a movement exist in this shop?
CREATE FUNCTION t.doc_exists(ty text,id uuid) RETURNS boolean LANGUAGE sql AS $$
  SELECT CASE ty
    WHEN 'import' THEN EXISTS(SELECT 1 FROM public.import_jobs WHERE id=$2 AND organization_id=t.org('a'))
    WHEN 'stock_adjustment' THEN EXISTS(SELECT 1 FROM public.stock_adjustments WHERE id=$2 AND organization_id=t.org('a'))
    WHEN 'transfer' THEN EXISTS(SELECT 1 FROM public.stock_transfers WHERE id=$2 AND organization_id=t.org('a'))
    ELSE false END $$;
-- quantity/balance/state of each item, in answer order.
CREATE FUNCTION t.steps(j jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg((r->>'quantity')||'/'||(r->>'balance_after')||'/'||(r->>'stock_state') ORDER BY o),ARRAY[]::text[])
  FROM jsonb_array_elements(j->'items') WITH ORDINALITY x(r,o) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (retail_pro: serials, 2 branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('I05 '||s,'i05-'||s,p,'Owner',s||'i05@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a','retail_pro',repeat('v',64)),('b','retail',repeat('w',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a5000000-0000-0000-8000-000000000001','ai05@example.com'),('a5000000-0000-0000-8000-000000000002','bi05@example.com'),
  ('a5000000-0000-0000-8000-000000000003','i05cashier@example.com'),('a5000000-0000-0000-8000-000000000004','i05accountant@example.com'),
  ('a5000000-0000-0000-8000-000000000005','i05collector@example.com');
SELECT public.accept_invite(repeat('v',64),'a5000000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('w',64),'a5000000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','I5',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"أ تلفزيون","name_en":"TV","sku":"I05-TV","cash_price":"100"}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"ب كابل","sku":"I05-CB","cash_price":"5"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"ج موبايل","sku":"I05-PH","cash_price":"9000","is_serialized":true}'));
INSERT INTO t.ids VALUES('bulk',public.create_product('{"name_ar":"د كثير","sku":"I05-BK","cash_price":"1"}'));
RESET ROLE;
SELECT t.as_user('a5000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('tv_b',public.create_product('{"name_ar":"تلفزيون ب","sku":"I05-TV","cash_price":"100"}'));
RESET ROLE;
-- Cashier: stock.view in main only. Accountant: stock.view + export.data in both branches.
-- Collector: no stock.view, but export.data granted (export needs both).
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5000000-0000-0000-8000-000000000003','I05 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5000000-0000-0000-8000-000000000004','I05 Accountant','ACCOUNTANT',t.id('main')) RETURNING id AS accountant_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'accountant_id',t.id('main')),(t.org('a'),:'accountant_id',t.id('second'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a5000000-0000-0000-8000-000000000005','I05 Collector','COLLECTOR') RETURNING id AS collector_id \gset
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),:'collector_id','export.data',true);
INSERT INTO public.import_jobs(organization_id,kind,status) VALUES(t.org('a'),'opening_stock','completed') RETURNING id AS job_id \gset
INSERT INTO t.ids VALUES('job',:'job_id');

-- ---------------------------------------------------------------- ledger
-- tv: purchases, a sale and a damaged return, in time order (purchase dated 5 days ago).
SELECT t.move('tv','main',10,'purchase_in',d=>current_date-5);
SELECT t.move('tv','second',4,'purchase_in');
SELECT t.move('tv','main',-2,'sale_out');
SELECT t.move('tv','main',1,'sale_return_in','damaged');
-- Real documents: two serials registered (I04), one sent to second (I03), the other written off
-- (I02); cable found by an adjustment.
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.register_units(t.id('phone'),t.id('main'),'7000',' ["imei-a","IMEI-B"] ','Shelf','i05-register') AS reg \gset
SELECT public.create_stock_transfer(t.id('main'),t.id('second'),NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.unit('IMEI-A'),'quantity',1)),'i05-transfer') AS tr \gset
SELECT public.send_stock_transfer((:'tr'::jsonb->>'id')::uuid), public.receive_stock_transfer((:'tr'::jsonb->>'id')::uuid,'[]');
SELECT public.post_stock_adjustment(t.id('main'),'damage','Broken',
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.unit('IMEI-B'),'quantity',-1)),'i05-adjust-1') AS adj \gset
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('cable'),'quantity',3)),'i05-adjust-2') AS adj2 \gset
RESET ROLE;
-- bulk: 10 001 movements, one more than an export may hold.
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id)
SELECT t.org('a'),t.id('bulk'),t.id('main'),1,'opening','import',t.id('job') FROM generate_series(1,10001);

-- ---------------------------------------------------------------- Done when: every movement links to its document
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.list_stock_movements(p_limit=>100,p_types=>ARRAY['purchase_in','sale_out','sale_return_in','transfer_out','transfer_in','adjustment']::public.stock_movement_type[]) AS docs \gset
SELECT public.list_stock_movements(p_serial=>'IMEI-A') AS opening \gset
SELECT t.expect('Done when: every movement names a source document that exists in the shop',
  (:'docs'::jsonb->>'total')::int=8
  AND (SELECT bool_and(t.doc_exists(r->>'source_type',(r->>'source_id')::uuid)) FROM jsonb_array_elements(:'docs'::jsonb->'items') r)
  AND (SELECT bool_and(t.doc_exists(r->>'source_type',(r->>'source_id')::uuid)) FROM jsonb_array_elements(:'opening'::jsonb->'items') r),
  :'docs'::text);
SELECT t.expect('numbered documents carry their number: transfers with "from → to", adjustments with the reason',
  (SELECT bool_and(r->>'source_number'=(:'tr'::jsonb->>'number') AND r->>'party'='Main → Second')
   FROM jsonb_array_elements(:'docs'::jsonb->'items') r WHERE r->>'source_type'='transfer')
  AND (SELECT count(*)=2 FROM jsonb_array_elements(:'docs'::jsonb->'items') r WHERE r->>'source_type'='transfer')
  AND (SELECT r->>'source_number'=(:'adj'::jsonb->>'number') AND r->>'reason'='damage' AND r->>'serial'='IMEI-B'
       FROM jsonb_array_elements(:'docs'::jsonb->'items') r WHERE r->>'source_id'=(:'adj'::jsonb->>'id'))
  AND (SELECT r->>'source_number'=(:'adj2'::jsonb->>'number') AND r->>'reason'='found' AND r->>'quantity'='3'
       FROM jsonb_array_elements(:'docs'::jsonb->'items') r WHERE r->>'source_id'=(:'adj2'::jsonb->>'id')));
SELECT t.expect('each movement names the product, branch and who posted it',
  (SELECT bool_and(r->>'sku' LIKE 'I05-%' AND r->>'product_name_ar' IS NOT NULL AND r->>'branch_id' IS NOT NULL)
   FROM jsonb_array_elements(:'docs'::jsonb->'items') r)
  AND (SELECT bool_and(r->>'created_by_name'='Owner') FROM jsonb_array_elements(:'docs'::jsonb->'items') r WHERE r->>'source_type'<>'import'));

-- ---------------------------------------------------------------- running balance, filters
SELECT t.expect('product + branch: newest first, balance per branch and stock state',
  t.steps(public.list_stock_movements(t.id('tv'),t.id('main')))=ARRAY['1/1/damaged','-2/8/sellable','10/10/sellable'],
  array_to_string(t.steps(public.list_stock_movements(t.id('tv'),t.id('main'))),' '));
SELECT t.expect('product in every branch: second keeps its own balance',
  t.steps(public.list_stock_movements(t.id('tv')))=ARRAY['1/1/damaged','-2/8/sellable','4/4/sellable','10/10/sellable']);
SELECT t.expect('the newest balance equals the stock level',
  (public.list_stock_movements(t.id('tv'),t.id('main'))->'items'->1->>'balance_after')::int
  =(SELECT on_hand FROM public.stock_levels WHERE product_id=t.id('tv') AND branch_id=t.id('main') AND stock_state='sellable'));
SELECT t.expect('type filter: only sales, and the balance is still the real one (8, not -2)',
  t.steps(public.list_stock_movements(t.id('tv'),p_types=>ARRAY['sale_out']::public.stock_movement_type[]))=ARRAY['-2/8/sellable']);
SELECT t.expect('an empty type list means every type',
  (public.list_stock_movements(t.id('tv'),p_types=>ARRAY[]::public.stock_movement_type[])->>'total')::int=4);
SELECT t.expect('date filter (business date): the old purchase drops out, balances stay',
  t.steps(public.list_stock_movements(t.id('tv'),t.id('main'),p_from=>current_date-1))=ARRAY['1/1/damaged','-2/8/sellable']
  AND t.steps(public.list_stock_movements(t.id('tv'),t.id('main'),p_to=>current_date-5))=ARRAY['10/10/sellable']);
SELECT t.expect('no product: the whole shop (every product, every branch)',
  (public.list_stock_movements()->>'total')::int=(SELECT count(*) FROM public.stock_movements WHERE organization_id=t.org('a'))
  AND (public.list_stock_movements(p_branch_id=>t.id('second'))->>'total')::int=2);
SELECT t.expect('serial (any case, trimmed): only that unit, registered -> sent -> received',
  (SELECT array_agg(r->>'type' ORDER BY r->>'type')=ARRAY['opening','transfer_in','transfer_out']
          AND bool_and(r->>'serial'='IMEI-A' AND r->>'unit_id'=t.unit('IMEI-A')::text)
   FROM jsonb_array_elements(public.list_stock_movements(p_serial=>' imei-a ')->'items') r));
SELECT t.expect('an unknown serial, or a serial of another product, finds nothing',
  (public.list_stock_movements(p_serial=>'NOPE-1')->>'total')::int=0
  AND (public.list_stock_movements(t.id('tv'),p_serial=>'IMEI-A')->>'total')::int=0);
SELECT t.expect('paging keeps the total',
  (SELECT jsonb_array_length(j->'items')=1 AND (j->>'total')::int=3 AND j->'items'->0->>'quantity'='-2'
   FROM (SELECT public.list_stock_movements(t.id('tv'),t.id('main'),1,1) j) x));
SELECT t.error('dates the wrong way round',$q$SELECT public.list_stock_movements(p_from=>current_date,p_to=>current_date-1)$q$,'VALIDATION_FAILED');
SELECT t.error('a serial longer than 64',format('SELECT public.list_stock_movements(p_serial=>%L)',repeat('A',65)),'VALIDATION_FAILED');
SELECT t.error('a blank serial',$q$SELECT public.list_stock_movements(p_serial=>'  ')$q$,'VALIDATION_FAILED');
SELECT t.error('page size above 100',$q$SELECT public.list_stock_movements(p_limit=>101)$q$,'VALIDATION_FAILED');
SELECT t.error('another shop''s product',format('SELECT public.list_stock_movements(%L)',t.id('tv_b')),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s branch',format('SELECT public.list_stock_movements(p_branch_id=>%L)',t.id('main_b')),'BRANCH_NOT_FOUND');
SELECT t.expect('the I01 calls (product, branch, limit, offset) still work',
  (public.list_stock_movements(t.id('tv'),t.id('main'),50,0)->>'total')::int=3);
RESET ROLE;

-- ---------------------------------------------------------------- branch scope and permission
SELECT t.as_user('a5000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier: only the branches they work in',
  NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_stock_movements(p_limit=>100)->'items') r WHERE r->>'branch_id'=t.id('second')::text)
  AND (public.list_stock_movements(t.id('tv'))->>'total')::int=3);
SELECT t.expect('cashier: a serial shows only its steps in their branches',
  (SELECT array_agg(r->>'type' ORDER BY r->>'type')=ARRAY['opening','transfer_out']
   FROM jsonb_array_elements(public.list_stock_movements(p_serial=>'IMEI-A')->'items') r));
SELECT t.error('cashier: another branch',format('SELECT public.list_stock_movements(p_branch_id=>%L)',t.id('second')),'BRANCH_DENIED');
SELECT t.error('cashier: no export.data',$q$SELECT public.export_stock_movements()$q$,'PERMISSION_DENIED');
SELECT t.as_user('a5000000-0000-0000-8000-000000000005',t.org('a'));
SELECT t.error('no stock.view: history',$q$SELECT public.list_stock_movements()$q$,'PERMISSION_DENIED');
SELECT t.error('export.data without stock.view',$q$SELECT public.export_stock_movements()$q$,'PERMISSION_DENIED');
SELECT t.as_user('a5000000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee',$q$SELECT public.list_stock_movements()$q$,'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee (export)',$q$SELECT public.export_stock_movements()$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;
SELECT t.expect('the history reads wrote no audit rows',NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_movements.exported'));

-- ---------------------------------------------------------------- export
SELECT t.as_user('a5000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.export_stock_movements(t.id('tv'),NULL,NULL,ARRAY['sale_out','purchase_in']::public.stock_movement_type[]) AS ex \gset
SELECT t.expect('accountant: the export holds the same rows as the history, newest first',
  (:'ex'::jsonb->>'total')::int=3
  AND :'ex'::jsonb->'items'=(public.list_stock_movements(t.id('tv'),p_limit=>100,p_types=>ARRAY['sale_out','purchase_in']::public.stock_movement_type[])->'items'),
  :'ex'::text);
SELECT t.error('export too large: refused, nothing cut silently',format('SELECT public.export_stock_movements(%L)',t.id('bulk')),'EXPORT_TOO_LARGE');
SELECT t.expect('the refusal says how many rows and the limit',
  t.detail(format('SELECT public.export_stock_movements(%L)',t.id('bulk')))::jsonb='{"total":10001,"limit":10000}'::jsonb);
SELECT t.expect('the history itself still pages through them',(public.list_stock_movements(t.id('bulk'))->>'total')::int=10001);
SELECT t.error('export: another shop''s product',format('SELECT public.export_stock_movements(%L)',t.id('tv_b')),'PRODUCT_NOT_FOUND');
RESET ROLE;
SELECT t.expect('one audit row per export, with the filters and the row count',
  (SELECT count(*)=1 AND bool_and(a.entity_type='stock_movement' AND a.employee_id=:'accountant_id'
          AND a.after->>'product_id'=t.id('tv')::text AND a.after->'types'='["sale_out","purchase_in"]'::jsonb
          AND (a.after->>'rows')::int=3)
   FROM public.audit_log a WHERE a.organization_id=t.org('a') AND a.action='stock_movements.exported'));

-- An expired (read-only) shop still reads and exports its history.
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the history and the export still work',
  (public.list_stock_movements(t.id('tv'))->>'total')::int=4 AND (public.export_stock_movements(t.id('tv'))->>'total')::int=4);
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ---------------------------------------------------------------- ledger, grants
SELECT t.expect('ledger caches match',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches() WHERE organization_id=t.org('a')));
SELECT t.expect('no anon grants',
  NOT has_function_privilege('anon','public.list_stock_movements(uuid,uuid,integer,integer,text,public.stock_movement_type[],date,date)','EXECUTE')
  AND NOT has_function_privilege('anon','public.export_stock_movements(uuid,uuid,text,public.stock_movement_type[],date,date)','EXECUTE'));
SELECT t.expect('authenticated may execute both reads, not the helpers',
  has_function_privilege('authenticated','public.list_stock_movements(uuid,uuid,integer,integer,text,public.stock_movement_type[],date,date)','EXECUTE')
  AND has_function_privilege('authenticated','public.export_stock_movements(uuid,uuid,text,public.stock_movement_type[],date,date)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.stock_movement_history(uuid,uuid,uuid,text,public.stock_movement_type[],date,date)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.stock_movement_item(uuid,uuid,integer)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
