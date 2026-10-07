\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
-- A call that should fail but doesn't is rolled back as well (T_NO_ERROR), so it never changes
-- what later checks see.
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- Same, but the DETAIL of the error must be the given jsonb (CATEGORY_IN_USE counts).
CREATE FUNCTION t.error_detail(n text,q text,c text,d jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_detail text;
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR';
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c AND v_detail IS NOT NULL AND v_detail::jsonb=d,SQLERRM||' | detail='||coalesce(v_detail,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: two shops, a cashier in a
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('C01 '||s,'c01-'||s,'retail','Owner',s||'c01@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('g',64)),('b',repeat('h',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a0600000-0000-0000-8000-000000000001','ac01@example.com'),('a0600000-0000-0000-8000-000000000002','bc01@example.com'),('a0600000-0000-0000-8000-000000000003','c01cashier@example.com');
SELECT public.accept_invite(repeat('g',64),'a0600000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('h',64),'a0600000-0000-0000-8000-000000000002');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a0600000-0000-0000-8000-000000000003','C01 Cashier','CASHIER');
-- Shop B's category (created the real way, so shop B has exactly one audit row).
SELECT t.as_user('a0600000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('b_parent',public.create_category('C01 B Cat',NULL));
RESET ROLE;

-- ---------------------------------------------------------------- create, rename, nest
SELECT t.as_user('a0600000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('parent',public.create_category('C01 Parent',NULL));
INSERT INTO t.ids VALUES('child',public.create_category('C01 Child',t.id('parent')));
INSERT INTO t.ids VALUES('child2',public.create_category('C01 Child 2',t.id('parent')));
INSERT INTO t.ids VALUES('other',public.create_category('C01 Other',NULL));
INSERT INTO t.ids VALUES('legacy',public.create_category('C01 Legacy',NULL));
INSERT INTO t.ids VALUES('legacysub',public.create_category('C01 Legacy Sub',t.id('legacy')));
INSERT INTO t.ids VALUES('discontinued',public.create_category('C01 Discontinued',NULL));
SELECT t.expect('seven categories created',(SELECT count(*)=7 FROM public.categories WHERE organization_id=t.org('a')));
SELECT t.error('blank name',$q$SELECT public.create_category('   ',NULL)$q$,'NAME_REQUIRED');
SELECT t.error('too-long name',format('SELECT public.create_category(%L,NULL)',repeat('x',61)),'NAME_REQUIRED');
SELECT t.error('name taken',$q$SELECT public.create_category('C01 Parent',NULL)$q$,'CATEGORY_NAME_TAKEN');
SELECT t.error('unknown parent',$q$SELECT public.create_category('C01 Orphan','00000000-0000-0000-0000-0000000000de')$q$,'CATEGORY_NOT_FOUND');
SELECT t.error('another shop parent id',format('SELECT public.create_category(%L,%L)','C01 Cross',t.id('b_parent')),'CATEGORY_NOT_FOUND');
SELECT t.error('a child as a parent (create)',format('SELECT public.create_category(%L,%L)','C01 Grandchild',t.id('child')),'CATEGORY_DEPTH');

-- rename, nest under a top-level parent, make top-level again, nest again
SELECT public.update_category(t.id('parent'),'{"name":"C01 Renamed"}');
SELECT t.expect('renamed',(SELECT name='C01 Renamed' FROM public.categories WHERE id=t.id('parent')));
SELECT public.update_category(t.id('child'),'{"parent_id":null}');
SELECT t.expect('made top-level',(SELECT parent_id IS NULL FROM public.categories WHERE id=t.id('child')));
SELECT public.update_category(t.id('child'),jsonb_build_object('parent_id',t.id('parent')));
SELECT t.expect('nested again',(SELECT parent_id=t.id('parent') FROM public.categories WHERE id=t.id('child')));

-- update refusals
SELECT t.error('unknown key',format('SELECT public.update_category(%L,%L)',t.id('child'),'{"bogus":1}'),'VALIDATION_FAILED');
SELECT t.error('body is not an object',format('SELECT public.update_category(%L,%L)',t.id('child'),'"text"'),'VALIDATION_FAILED');
SELECT t.error('blank name on update',format('SELECT public.update_category(%L,%L)',t.id('child'),'{"name":"  "}'),'NAME_REQUIRED');
SELECT t.error('too-long name on update',format('SELECT public.update_category(%L,%L)',t.id('child'),jsonb_build_object('name',repeat('x',61))),'NAME_REQUIRED');
SELECT t.error('name taken on update',format('SELECT public.update_category(%L,%L)',t.id('child'),'{"name":"C01 Other"}'),'CATEGORY_NAME_TAKEN');
SELECT t.error('itself as its own parent',format('SELECT public.update_category(%L,%L)',t.id('parent'),jsonb_build_object('parent_id',t.id('parent'))),'CATEGORY_DEPTH');
SELECT t.error('a child as a parent (update)',format('SELECT public.update_category(%L,%L)',t.id('child2'),jsonb_build_object('parent_id',t.id('child'))),'CATEGORY_DEPTH');
SELECT t.error('a category with children becomes a child',format('SELECT public.update_category(%L,%L)',t.id('parent'),jsonb_build_object('parent_id',t.id('legacy'))),'CATEGORY_DEPTH');
SELECT t.error('missing id',$q$SELECT public.update_category('00000000-0000-0000-0000-0000000000dd','{"name":"Nope"}')$q$,'CATEGORY_NOT_FOUND');
RESET ROLE;

-- ---------------------------------------------------------------- products (superuser inserts)
INSERT INTO t.ids VALUES
  ('prod1','f1010000-0000-0000-0000-000000000001'),
  ('prod2','f1020000-0000-0000-0000-000000000002'),
  ('prod3','f1030000-0000-0000-0000-000000000003'),
  ('prod4','f1040000-0000-0000-0000-000000000004'),
  ('prod5','f1050000-0000-0000-0000-000000000005');
INSERT INTO public.products(id,organization_id,name_ar,sku,cash_price,tax_class_id,is_serialized,category_id)
SELECT t.id('prod1'),t.org('a'),'C01 Product 1','C01-P1',100,(SELECT id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='standard' LIMIT 1),false,t.id('child');
INSERT INTO public.products(id,organization_id,name_ar,sku,cash_price,tax_class_id,is_serialized,category_id)
SELECT t.id('prod2'),t.org('a'),'C01 Product 2','C01-P2',100,(SELECT id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='standard' LIMIT 1),false,t.id('other');
INSERT INTO public.products(id,organization_id,name_ar,sku,cash_price,tax_class_id,is_serialized,category_id)
SELECT t.id('prod5'),t.org('a'),'C01 Product 5','C01-P5',100,(SELECT id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='standard' LIMIT 1),false,t.id('other');
-- archived products never block anything
INSERT INTO public.products(id,organization_id,name_ar,sku,cash_price,tax_class_id,is_serialized,category_id,archived_at,is_active)
SELECT t.id('prod3'),t.org('a'),'C01 Product 3','C01-P3',100,(SELECT id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='standard' LIMIT 1),false,t.id('other'),now(),false;
INSERT INTO public.products(id,organization_id,name_ar,sku,cash_price,tax_class_id,is_serialized,category_id,archived_at,is_active)
SELECT t.id('prod4'),t.org('a'),'C01 Product 4','C01-P4',100,(SELECT id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='standard' LIMIT 1),false,t.id('discontinued'),now(),false;

-- ---------------------------------------------------------------- reads: order, counts, helper
SELECT t.as_user('a0600000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('list: active first, parents in name order, each followed by its children',
  (SELECT array_agg(l->>'name' ORDER BY ord)=ARRAY['C01 Discontinued','C01 Legacy','C01 Legacy Sub','C01 Other','C01 Renamed','C01 Child','C01 Child 2']
   FROM jsonb_array_elements(public.list_categories()) WITH ORDINALITY AS x(l,ord)),
  (SELECT public.list_categories()::text));
SELECT t.expect('active_product_count counts the active products of that category only',
  (SELECT (l->>'active_product_count')::int=2 FROM jsonb_array_elements(public.list_categories()) l WHERE l->>'name'='C01 Other')
  AND (SELECT (l->>'active_product_count')::int=1 FROM jsonb_array_elements(public.list_categories()) l WHERE l->>'name'='C01 Child')
  AND (SELECT (l->>'active_product_count')::int=0 FROM jsonb_array_elements(public.list_categories()) l WHERE l->>'name'='C01 Renamed'));
SELECT t.as_user('a0600000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee cannot list',$q$SELECT public.list_categories()$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;
-- The filter helper is deliberately not granted (later slices call it from inside
-- their own SECURITY DEFINER functions), so these checks run as the database owner.
SELECT t.expect('category_with_children returns the parent and its children only',
  app.category_with_children(t.org('a'),t.id('parent'))=ARRAY[t.id('parent'),t.id('child'),t.id('child2')]::uuid[]);
SELECT t.expect('category_with_children: an unknown id is an empty array',app.category_with_children(t.org('a'),'00000000-0000-0000-0000-0000000000cc')=ARRAY[]::uuid[]);
SELECT t.expect('category_with_children: another shop is an empty array',
  app.category_with_children(t.org('b'),t.id('parent'))=ARRAY[]::uuid[]
  AND app.category_with_children(t.org('a'),t.id('b_parent'))=ARRAY[]::uuid[]);
SELECT t.expect('Done when: a product filter on the helper returns the right products',
  (SELECT array_agg(p.id ORDER BY p.id)=ARRAY[t.id('prod1')]::uuid[]
   FROM public.products p
   WHERE p.organization_id=t.org('a')
     AND p.category_id=ANY(app.category_with_children(t.org('a'),t.id('parent')))
     AND p.archived_at IS NULL)
  AND (SELECT array_agg(p.id ORDER BY p.id)=ARRAY[t.id('prod2'),t.id('prod5')]::uuid[]
       FROM public.products p
       WHERE p.organization_id=t.org('a')
         AND p.category_id=ANY(app.category_with_children(t.org('a'),t.id('other')))
         AND p.archived_at IS NULL),
  (SELECT string_agg(p.id::text,',') FROM public.products p WHERE p.organization_id=t.org('a')));
RESET ROLE;

-- ---------------------------------------------------------------- archive rules
SELECT t.as_user('a0600000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
-- refused: active children (a move target does not change that), with the right DETAIL
SELECT t.error_detail('archive refused with active children',
  format('SELECT public.set_category_archived(%L,true,%L)',t.id('parent'),t.id('other')),'CATEGORY_IN_USE',
  '{"active_products": 0, "active_children": 2}'::jsonb);
-- archived products never block an archive
SELECT public.set_category_archived(t.id('discontinued'),true);
SELECT t.expect('archived products do not block an archive',(SELECT archived_at IS NOT NULL FROM public.categories WHERE id=t.id('discontinued')));
-- refused: active products and no move target
SELECT t.error_detail('archive refused with active products',
  format('SELECT public.set_category_archived(%L,true)',t.id('other')),'CATEGORY_IN_USE',
  '{"active_products": 2, "active_children": 0}'::jsonb);
-- a refused move changes nothing: the product update rolls back with the error (one transaction)
SELECT t.error('archived move target',format('SELECT public.set_category_archived(%L,true,%L)',t.id('other'),t.id('discontinued')),'CATEGORY_PARENT_ARCHIVED');
SELECT t.expect('a refused move leaves the products alone',(SELECT count(*)=2 FROM public.products WHERE organization_id=t.org('a') AND category_id=t.id('other') AND archived_at IS NULL));
SELECT t.error('move target in another shop',format('SELECT public.set_category_archived(%L,true,%L)',t.id('other'),t.id('b_parent')),'CATEGORY_NOT_FOUND');
SELECT t.error('move target is itself',format('SELECT public.set_category_archived(%L,true,%L)',t.id('other'),t.id('other')),'CATEGORY_NOT_FOUND');
-- archive with the move: every ACTIVE product moves, in the same transaction as the archive
SELECT public.set_category_archived(t.id('other'),true,t.id('child'));
SELECT t.expect('archive with move archived the category',(SELECT archived_at IS NOT NULL FROM public.categories WHERE id=t.id('other')));
SELECT t.expect('archive with move moved every active product',
  (SELECT count(*)=3 FROM public.products WHERE organization_id=t.org('a') AND category_id=t.id('child') AND archived_at IS NULL)
  AND NOT EXISTS(SELECT 1 FROM public.products WHERE organization_id=t.org('a') AND category_id=t.id('other') AND archived_at IS NULL));
SELECT t.expect('archive with move left the archived product behind',
  (SELECT category_id=t.id('other') FROM public.products WHERE id=t.id('prod3')));
SELECT t.expect('archive with move audited moved_products and moved_to',
  EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.archived' AND entity_id=t.id('other')
         AND (after->>'moved_products')::int=2 AND after->>'moved_to'=t.id('child')::text AND severity='warning'));
-- restore refused under an archived parent
SELECT public.set_category_archived(t.id('legacysub'),true);
SELECT public.set_category_archived(t.id('legacy'),true);
SELECT t.error('restore refused under an archived parent',format('SELECT public.set_category_archived(%L,false)',t.id('legacysub')),'CATEGORY_PARENT_ARCHIVED');
SELECT t.expect('the refused restore changed nothing',(SELECT archived_at IS NOT NULL FROM public.categories WHERE id=t.id('legacysub')));
SELECT public.set_category_archived(t.id('legacy'),false);
SELECT t.expect('restore brought it back',(SELECT archived_at IS NULL FROM public.categories WHERE id=t.id('legacy')));
-- same state: nothing, no audit row (the counts stay what they were)
SELECT public.set_category_archived(t.id('legacy'),false);
SELECT t.expect('same-state restore writes no audit',(SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.restored'));
SELECT public.set_category_archived(t.id('discontinued'),true);
SELECT t.expect('same-state archive writes no audit',(SELECT count(*)=4 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.archived'));
-- no change at all: no update, no audit row
SELECT public.update_category(t.id('parent'),'{"name":"C01 Renamed"}');
SELECT t.expect('a no-change update writes no audit',(SELECT count(*)=3 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.updated'));
-- an archived category: not editable, not a parent, its name stays taken
SELECT t.error('an archived category cannot be edited',format('SELECT public.update_category(%L,%L)',t.id('other'),'{"name":"C01 Renamed 2"}'),'CATEGORY_NOT_FOUND');
SELECT t.error('cannot nest under an archived parent',format('SELECT public.create_category(%L,%L)','C01 Under Archived',t.id('other')),'CATEGORY_PARENT_ARCHIVED');
SELECT t.error('cannot move under an archived parent',format('SELECT public.update_category(%L,%L)',t.id('child'),jsonb_build_object('parent_id',t.id('other'))),'CATEGORY_PARENT_ARCHIVED');
SELECT t.error('the name of an archived category is still taken',format('SELECT public.create_category(%L,NULL)','C01 Other'),'CATEGORY_NAME_TAKEN');
SELECT t.expect('archived categories come last, in name order with their children',
  (SELECT array_agg(l->>'archived_at' IS NOT NULL ORDER BY ord)=ARRAY[false,false,false,false,true,true,true]
   FROM jsonb_array_elements(public.list_categories()) WITH ORDINALITY AS x(l,ord))
  AND (SELECT array_agg(l->>'name' ORDER BY ord)=ARRAY['C01 Legacy','C01 Renamed','C01 Child','C01 Child 2','C01 Discontinued','C01 Legacy Sub','C01 Other']
       FROM jsonb_array_elements(public.list_categories()) WITH ORDINALITY AS x(l,ord)));
RESET ROLE;

-- ---------------------------------------------------------------- another shop's ids
SELECT t.as_user('a0600000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('another shop id: update',format('SELECT public.update_category(%L,%L)',t.id('b_parent'),'{"name":"Taken Over"}'),'CATEGORY_NOT_FOUND');
SELECT t.error('another shop id: archive',format('SELECT public.set_category_archived(%L,true)',t.id('b_parent')),'CATEGORY_NOT_FOUND');
SELECT t.error('another shop id: restore',format('SELECT public.set_category_archived(%L,false)',t.id('b_parent')),'CATEGORY_NOT_FOUND');
RESET ROLE;
SELECT t.expect('shop B is unchanged',
  (SELECT count(*)=1 FROM public.categories WHERE organization_id=t.org('b'))
  AND (SELECT name='C01 B Cat' AND archived_at IS NULL FROM public.categories WHERE id=t.id('b_parent'))
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('b') AND entity_type='category'));

-- ---------------------------------------------------------------- cashier: reads, never writes
SELECT t.as_user('a0600000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier can list',(SELECT jsonb_array_length(public.list_categories())=7));
SELECT t.error('cashier cannot create',$q$SELECT public.create_category('Cashier cat',NULL)$q$,'PERMISSION_DENIED');
SELECT t.error('cashier cannot update',format('SELECT public.update_category(%L,%L)',t.id('child'),'{"name":"Cashier rename"}'),'PERMISSION_DENIED');
SELECT t.error('cashier cannot archive',format('SELECT public.set_category_archived(%L,true)',t.id('child')),'PERMISSION_DENIED');
SELECT t.error('cashier cannot restore',format('SELECT public.set_category_archived(%L,false)',t.id('other')),'PERMISSION_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- audit: exactly one row per write
SELECT t.expect('one audit row per created category',(SELECT count(*)=7 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.created'));
SELECT t.expect('one audit row per changed update (the no-change update wrote none)',
  (SELECT count(*)=3 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.updated'));
SELECT t.expect('one audit row per state change (the same-state calls wrote none)',
  (SELECT count(*)=4 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.archived')
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.restored'));
SELECT t.expect('every category write audited exactly once',
  (SELECT count(*)=15 FROM public.audit_log WHERE organization_id=t.org('a') AND entity_type='category')
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND entity_type='category' AND after IS NULL AND action<>'category.created'));
SELECT t.expect('the update audit carries before and after',
  EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='category.updated'
         AND before->>'name'='C01 Parent' AND after->>'name'='C01 Renamed'));

-- ---------------------------------------------------------------- grants
SELECT t.expect('no anon grants on the new functions',
  NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace
             AND proname IN('list_categories','create_category','update_category','set_category_archived')
             AND has_function_privilege('anon',oid,'EXECUTE')));
SELECT t.expect('app.* helpers are not granted',
  NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='app'::regnamespace
             AND proname IN('category_with_children','category_json')
             AND (has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('anon',oid,'EXECUTE'))));
SELECT t.expect('authenticated executes exactly the four new public functions',
  (SELECT count(*)=4 FROM pg_proc WHERE pronamespace='public'::regnamespace
   AND proname IN('list_categories','create_category','update_category','set_category_archived')
   AND has_function_privilege('authenticated',oid,'EXECUTE')));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
