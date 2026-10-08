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
-- Sellable on hand straight from the ledger.
CREATE FUNCTION t.ledger(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE(sum(quantity),0)::integer FROM public.stock_movements WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable' $$;
CREATE FUNCTION t.level(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0) $$;
-- A ledger movement (superuser): opening stock, a sale... are other slices.
CREATE FUNCTION t.move(p text,b text,q integer,ty public.stock_movement_type,u text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,source_type,source_id)
  VALUES(t.org('a'),t.id(p),t.id(b),t.id(u),q,ty,'import',gen_random_uuid()) $$;
CREATE FUNCTION t.lines(j jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT j $$;
-- One line of a get_stock_count answer, by product (and serial).
CREATE FUNCTION t.cline(j jsonb,p text,s text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT r FROM jsonb_array_elements(j->'lines'->'items') r WHERE r->>'product_id'=t.id(p)::text AND r->>'serial' IS NOT DISTINCT FROM s $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (2 branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('I02 '||s,'i02-'||s,'retail','Owner',s||'i02@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('p',64)),('b',repeat('q',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a2000000-0000-0000-8000-000000000001','ai02@example.com'),('a2000000-0000-0000-8000-000000000002','bi02@example.com'),('a2000000-0000-0000-8000-000000000003','i02cashier@example.com'),('a2000000-0000-0000-8000-000000000004','i02warehouse@example.com');
SELECT public.accept_invite(repeat('p',64),'a2000000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a2000000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
-- The cashier has stock.view only; the warehouse keeper has stock.count (not stock.adjust), main branch only.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a2000000-0000-0000-8000-000000000003','I02 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a2000000-0000-0000-8000-000000000004','I02 Keeper','WAREHOUSE',t.id('main')) RETURNING id AS keeper_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'keeper_id',t.id('main'));

SELECT t.as_user('a2000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','I2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('screens',public.create_category('I02 Screens',NULL));
INSERT INTO t.ids VALUES('tvs',public.create_category('I02 TVs',t.id('screens')));
INSERT INTO t.ids VALUES('cables',public.create_category('I02 Cables',NULL));
INSERT INTO t.ids VALUES('tv',public.create_product(jsonb_build_object('name_ar','أ تلفزيون','sku','I02-TV','cash_price','100','category_id',t.id('tvs'))));
INSERT INTO t.ids VALUES('cable',public.create_product(jsonb_build_object('name_ar','ب كابل','sku','I02-CB','barcode','2000000000022','cash_price','5','category_id',t.id('cables'))));
INSERT INTO t.ids VALUES('phone',public.create_product(jsonb_build_object('name_ar','ج موبايل','sku','I02-PH','cash_price','900','is_serialized',true,'category_id',t.id('screens'))));
INSERT INTO t.ids VALUES('empty',public.create_product(jsonb_build_object('name_ar','د فارغ','sku','I02-EM','cash_price','1','category_id',t.id('screens'))));
RESET ROLE;
SELECT t.as_user('a2000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('cable_b',public.create_product('{"name_ar":"كابل ب","sku":"I02-CB","cash_price":"5"}'));
RESET ROLE;
-- Opening stock (superuser; purchases are U02): tv 10 in main, 3 phones (serials) in main, 1 in second.
UPDATE public.products SET avg_cost=40 WHERE id=t.id('tv');
INSERT INTO public.units(organization_id,product_id,serial,branch_id,cost)
SELECT t.org('a'),t.id('phone'),s,t.id(b),700 FROM (VALUES('I02-SN-1','main'),('I02-SN-2','main'),('I02-SN-3','main'),('I02-SN-4','second'),('I02-SN-5','second')) v(s,b);
INSERT INTO t.ids SELECT 'sn'||right(serial,1),id FROM public.units WHERE organization_id=t.org('a') AND product_id=t.id('phone');
SELECT t.move('tv','main',10,'opening');
SELECT t.move('phone','main',1,'opening','sn1'),t.move('phone','main',1,'opening','sn2'),t.move('phone','main',1,'opening','sn3'),t.move('phone','second',1,'opening','sn4'),t.move('phone','second',1,'opening','sn5');

-- ---------------------------------------------------------------- adjustments
SELECT t.as_user('a2000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.post_stock_adjustment(t.id('main'),'found','Found in the back room',
  jsonb_build_array(jsonb_build_object('product_id',t.id('cable'),'quantity',12)),'i02-adj-found-1') AS adj1 \gset
SELECT t.expect('found +12 cable: stock 12, numbered SA, reason and note kept',
  t.level('cable','main')=12 AND t.ledger('cable','main')=12
  AND :'adj1'::jsonb->>'number' ~ '^MAIN-SA-\d{2}-000001$' AND :'adj1'::jsonb->>'reason'='found'
  AND :'adj1'::jsonb->>'note'='Found in the back room' AND (:'adj1'::jsonb->>'quantity_in')::int=12
  AND jsonb_array_length(:'adj1'::jsonb->'lines')=1, :'adj1'::text);
SELECT t.expect('the ledger row: type adjustment, source = the adjustment and its line, cost = average cost',
  (SELECT count(*)=1 AND bool_and(m.type='adjustment' AND m.source_type='stock_adjustment' AND m.source_line_id=l.id AND m.unit_cost=0)
   FROM public.stock_movements m JOIN public.stock_adjustment_lines l ON l.adjustment_id=m.source_id
   WHERE m.source_id=(:'adj1'::jsonb->>'id')::uuid));
SELECT t.expect('same idempotency key again: the same document, nothing posted twice',
  (public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('cable'),'quantity',99)),'i02-adj-found-1')->>'id')=(:'adj1'::jsonb->>'id')
  AND t.level('cable','main')=12);
SELECT public.post_stock_adjustment(t.id('main'),'damage',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',-2),jsonb_build_object('product_id',t.id('cable'),'quantity',-1)),'i02-adj-damage-1') AS adj2 \gset
SELECT t.expect('damage -2 tv, -1 cable: two lines, cost of the tv = its average cost',
  t.level('tv','main')=8 AND t.level('cable','main')=11 AND (:'adj2'::jsonb->>'quantity_out')::int=3
  AND (SELECT unit_cost=40 FROM public.stock_movements WHERE source_id=(:'adj2'::jsonb->>'id')::uuid AND product_id=t.id('tv')));
SELECT t.error('damage can''t add stock',format($q$SELECT public.post_stock_adjustment(%L,'damage',NULL,'[{"product_id":"%s","quantity":1}]','i02-adj-bad-1')$q$,t.id('main'),t.id('tv')),'ADJUSTMENT_SIGN_INVALID');
SELECT t.error('loss can''t add stock',format($q$SELECT public.post_stock_adjustment(%L,'loss',NULL,'[{"product_id":"%s","quantity":1}]','i02-adj-bad-2')$q$,t.id('main'),t.id('tv')),'ADJUSTMENT_SIGN_INVALID');
SELECT t.error('found can''t remove stock',format($q$SELECT public.post_stock_adjustment(%L,'found',NULL,'[{"product_id":"%s","quantity":-1}]','i02-adj-bad-3')$q$,t.id('main'),t.id('tv')),'ADJUSTMENT_SIGN_INVALID');
SELECT t.error('other needs a note',format($q$SELECT public.post_stock_adjustment(%L,'other','  ','[{"product_id":"%s","quantity":-1}]','i02-adj-bad-4')$q$,t.id('main'),t.id('tv')),'VALIDATION_FAILED');
SELECT t.error('count is only for posted counts',format($q$SELECT public.post_stock_adjustment(%L,'count',NULL,'[{"product_id":"%s","quantity":-1}]','i02-adj-bad-5')$q$,t.id('main'),t.id('tv')),'VALIDATION_FAILED');
SELECT t.error('quantity zero',format($q$SELECT public.post_stock_adjustment(%L,'correction',NULL,'[{"product_id":"%s","quantity":0}]','i02-adj-bad-6')$q$,t.id('main'),t.id('tv')),'VALIDATION_FAILED');
SELECT t.error('a product twice',format($q$SELECT public.post_stock_adjustment(%L,'correction',NULL,'[{"product_id":"%s","quantity":1},{"product_id":"%s","quantity":2}]','i02-adj-bad-7')$q$,t.id('main'),t.id('tv'),t.id('tv')),'VALIDATION_FAILED');
SELECT t.error('malformed lines',format($q$SELECT public.post_stock_adjustment(%L,'correction',NULL,'[{"product_id":"nope","quantity":1}]','i02-adj-bad-8')$q$,t.id('main')),'VALIDATION_FAILED');
SELECT t.error('an unknown key in a line',format($q$SELECT public.post_stock_adjustment(%L,'correction',NULL,'[{"product_id":"%s","quantity":1,"organization_id":"%s"}]','i02-adj-bad-9')$q$,t.id('main'),t.id('tv'),t.org('b')),'VALIDATION_FAILED');
SELECT t.error('no lines',format($q$SELECT public.post_stock_adjustment(%L,'correction',NULL,'[]','i02-adj-bad-10')$q$,t.id('main')),'VALIDATION_FAILED');
SELECT t.error('short idempotency key',format($q$SELECT public.post_stock_adjustment(%L,'correction',NULL,'[{"product_id":"%s","quantity":1}]','short')$q$,t.id('main'),t.id('tv')),'VALIDATION_FAILED');
SELECT t.error('more than on hand -> OUT_OF_STOCK, nothing posted',format($q$SELECT public.post_stock_adjustment(%L,'loss',NULL,'[{"product_id":"%s","quantity":-9}]','i02-adj-bad-11')$q$,t.id('main'),t.id('tv')),'OUT_OF_STOCK');
SELECT t.expect('the failed loss left the stock and the numbering alone',
  t.level('tv','main')=8 AND NOT EXISTS(SELECT 1 FROM public.stock_adjustments WHERE idempotency_key='i02-adj-bad-11'));
SELECT t.error('serialized without a unit',format($q$SELECT public.post_stock_adjustment(%L,'loss',NULL,'[{"product_id":"%s","quantity":-1}]','i02-adj-bad-12')$q$,t.id('main'),t.id('phone')),'UNIT_REQUIRED');
SELECT t.error('a unit on a non-serialized product',format($q$SELECT public.post_stock_adjustment(%L,'loss',NULL,'[{"product_id":"%s","unit_id":"%s","quantity":-1}]','i02-adj-bad-13')$q$,t.id('main'),t.id('tv'),t.id('sn1')),'UNIT_NOT_ALLOWED');
SELECT t.error('a unit moves one at a time',format($q$SELECT public.post_stock_adjustment(%L,'correction',NULL,'[{"product_id":"%s","unit_id":"%s","quantity":-2}]','i02-adj-bad-14')$q$,t.id('main'),t.id('phone'),t.id('sn1')),'VALIDATION_FAILED');
SELECT t.error('a unit of another branch can''t leave this one',format($q$SELECT public.post_stock_adjustment(%L,'loss',NULL,'[{"product_id":"%s","unit_id":"%s","quantity":-1}]','i02-adj-bad-15')$q$,t.id('main'),t.id('phone'),t.id('sn4')),'UNIT_NOT_AVAILABLE');
SELECT public.post_stock_adjustment(t.id('main'),'loss','Stolen',
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.id('sn3'),'quantity',-1)),'i02-adj-loss-unit') AS adj3 \gset
SELECT t.expect('loss of a serial: the unit is written off, cost = the unit''s cost',
  (SELECT status='written_off' FROM public.units WHERE id=t.id('sn3')) AND t.level('phone','main')=2
  AND (SELECT unit_cost=700 FROM public.stock_movements WHERE source_id=(:'adj3'::jsonb->>'id')::uuid)
  AND :'adj3'::jsonb->'lines'->0->>'serial'='I02-SN-3');
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.id('sn3'),'quantity',1)),'i02-adj-found-unit') AS adj4 \gset
SELECT t.expect('found again: back in stock',(SELECT status='in_stock' AND branch_id=t.id('main') FROM public.units WHERE id=t.id('sn3')) AND t.level('phone','main')=3);
-- sn4 is sold (superuser: sales are S01); it can't be "found" again.
RESET ROLE;
SELECT t.move('phone','second',-1,'sale_out','sn4');
SET LOCAL ROLE authenticated;
SELECT t.error('a sold serial can''t be found again',format($q$SELECT public.post_stock_adjustment(%L,'found',NULL,'[{"product_id":"%s","unit_id":"%s","quantity":1}]','i02-adj-bad-sold')$q$,t.id('main'),t.id('phone'),t.id('sn4')),'UNIT_NOT_AVAILABLE');
SELECT t.error('another shop''s product',format($q$SELECT public.post_stock_adjustment(%L,'found',NULL,'[{"product_id":"%s","quantity":1}]','i02-adj-bad-16')$q$,t.id('main'),t.id('cable_b')),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s branch',format($q$SELECT public.post_stock_adjustment(%L,'found',NULL,'[{"product_id":"%s","quantity":1}]','i02-adj-bad-17')$q$,t.id('main_b'),t.id('cable')),'BRANCH_NOT_FOUND');
SELECT t.expect('audit: one stock_adjustment.posted row per adjustment, with the lines',
  (SELECT count(*)=4 FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_adjustment.posted')
  AND (SELECT after->'lines'->0->>'quantity'='12' AND reason='Found in the back room' FROM public.audit_log WHERE entity_id=(:'adj1'::jsonb->>'id')::uuid));
SELECT t.expect('list: every adjustment (no lines in the list), reason filter, paging total',
  (SELECT (j->>'total')::int=4 AND NOT (j->'items'->0 ? 'lines') FROM (SELECT public.list_stock_adjustments() j) x)
  AND (public.list_stock_adjustments(p_reason=>'damage')->>'total')::int=1
  AND jsonb_array_length(public.list_stock_adjustments(p_limit=>1)->'items')=1);
SELECT t.expect('get: header and lines',(public.get_stock_adjustment((:'adj2'::jsonb->>'id')::uuid)->'lines'->0->>'sku')='I02-TV');
RESET ROLE;
-- Movements show the adjustment's number and reason (I01 drill-down).
SELECT t.as_user('a2000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('movement drill-down: adjustment number and reason on the ledger row',
  (SELECT r->>'source_number'=(:'adj2'::jsonb->>'number') AND r->>'reason'='damage'
   FROM jsonb_array_elements(public.list_stock_movements(t.id('tv'),t.id('main'))->'items') r WHERE r->>'quantity'='-2')
  AND (SELECT r->>'source_number' IS NULL AND r->>'reason' IS NULL
       FROM jsonb_array_elements(public.list_stock_movements(t.id('tv'),t.id('main'))->'items') r WHERE r->>'type'='opening'));
RESET ROLE;
-- Permissions and branch scope.
SELECT t.as_user('a2000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('cashier: no stock.adjust',format($q$SELECT public.post_stock_adjustment(%L,'found',NULL,'[{"product_id":"%s","quantity":1}]','i02-adj-cashier')$q$,t.id('main'),t.id('cable')),'PERMISSION_DENIED');
SELECT t.expect('cashier (stock.view): reads adjustments of their branch',(public.list_stock_adjustments()->>'total')::int=4);
SELECT t.error('cashier: no stock.count',$q$SELECT public.list_stock_counts()$q$,'PERMISSION_DENIED');
RESET ROLE;
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),:'keeper_id','stock.adjust',true);
SELECT t.as_user('a2000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('keeper: a branch they don''t work in',format($q$SELECT public.post_stock_adjustment(%L,'found',NULL,'[{"product_id":"%s","quantity":1}]','i02-adj-keeper')$q$,t.id('second'),t.id('cable')),'BRANCH_DENIED');
RESET ROLE;
DELETE FROM public.employee_permission_overrides WHERE employee_id=:'keeper_id';

-- ---------------------------------------------------------------- counts
-- Stock now: main tv 8, cable 11, phones sn1 sn2 sn3; second phone sn4.
SELECT t.as_user('a2000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.create_stock_count(t.id('main'),NULL,'i02-count-main-1') AS c1 \gset
SELECT t.expect('whole-branch count: SC number, open, a line per product and per unit in the branch',
  :'c1'::jsonb->>'number' ~ '^MAIN-SC-\d{2}-000001$' AND :'c1'::jsonb->>'status'='open'
  AND (:'c1'::jsonb->>'lines_total')::int=6 AND (:'c1'::jsonb->>'lines_counted')::int=0, :'c1'::text);
SELECT t.expect('same key again: the same count',(public.create_stock_count(t.id('main'),NULL,'i02-count-main-1')->>'id')=(:'c1'::jsonb->>'id'));
SELECT t.error('a second open count over the same products',format($q$SELECT public.create_stock_count(%L,%L,'i02-count-main-2')$q$,t.id('main'),t.id('cables')),'STOCK_COUNT_OPEN');
SELECT t.error('keeper: another branch',format($q$SELECT public.create_stock_count(%L,NULL,'i02-count-second-x')$q$,t.id('second')),'BRANCH_DENIED');
SELECT public.get_stock_count((:'c1'::jsonb->>'id')::uuid,p_limit=>100) AS g1 \gset
SELECT t.expect('the sheet: expected = stock now; serials listed; nothing counted yet',
  (t.cline(:'g1'::jsonb,'tv')->>'expected_qty')::int=8 AND (t.cline(:'g1'::jsonb,'cable')->>'expected_qty')::int=11
  AND (t.cline(:'g1'::jsonb,'empty')->>'expected_qty')::int=0 AND t.cline(:'g1'::jsonb,'phone','I02-SN-1') IS NOT NULL
  AND t.cline(:'g1'::jsonb,'phone','I02-SN-4') IS NULL AND t.cline(:'g1'::jsonb,'cable')->>'counted_qty' IS NULL, :'g1'::text);
-- Count: tv 6 (2 missing), cable by scanning its barcode 3 times then typed 13, phones sn1 + sn2 scanned (sn3 missing).
SELECT public.save_stock_count_lines((:'c1'::jsonb->>'id')::uuid,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'counted_qty',6))) AS s1 \gset
SELECT t.expect('saved: one line counted, its difference shown',(:'s1'::jsonb->>'lines_counted')::int=1 AND (:'s1'::jsonb->>'quantity_out')::int=2);
SELECT public.scan_stock_count((:'c1'::jsonb->>'id')::uuid,'2000000000022'),public.scan_stock_count((:'c1'::jsonb->>'id')::uuid,'2000000000022');
SELECT t.expect('scanning a product barcode adds one each time',(public.scan_stock_count((:'c1'::jsonb->>'id')::uuid,' i02-cb ')->>'counted_qty')::int=3);
SELECT public.save_stock_count_lines((:'c1'::jsonb->>'id')::uuid,jsonb_build_array(jsonb_build_object('product_id',t.id('cable'),'counted_qty',13))) AS s2 \gset
SELECT t.expect('scanning a serial counts that unit',
  (public.scan_stock_count((:'c1'::jsonb->>'id')::uuid,'I02-SN-1')->>'counted_qty')::int=1
  AND (public.scan_stock_count((:'c1'::jsonb->>'id')::uuid,'I02-SN-2')->>'counted_qty')::int=1
  AND (public.scan_stock_count((:'c1'::jsonb->>'id')::uuid,'I02-SN-2')->>'counted_qty')::int=1);
SELECT t.error('a serialized product''s barcode: scan the serial',format($q$SELECT public.scan_stock_count(%L,'I02-PH')$q$,:'c1'::jsonb->>'id'),'UNIT_REQUIRED');
SELECT t.error('a serial in stock in another branch',format($q$SELECT public.scan_stock_count(%L,'I02-SN-5')$q$,:'c1'::jsonb->>'id'),'UNIT_ALREADY_IN_STOCK');
SELECT t.error('a sold serial can''t be counted back',format($q$SELECT public.scan_stock_count(%L,'I02-SN-4')$q$,:'c1'::jsonb->>'id'),'UNIT_NOT_AVAILABLE');
SELECT t.error('an unknown code',format($q$SELECT public.scan_stock_count(%L,'NOPE-123')$q$,:'c1'::jsonb->>'id'),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop''s product on the sheet',format($q$SELECT public.save_stock_count_lines(%L,'[{"product_id":"%s","counted_qty":1}]')$q$,:'c1'::jsonb->>'id',t.id('cable_b')),'PRODUCT_NOT_FOUND');
SELECT t.error('a unit counted as 2',format($q$SELECT public.save_stock_count_lines(%L,'[{"product_id":"%s","unit_id":"%s","counted_qty":2}]')$q$,:'c1'::jsonb->>'id',t.id('phone'),t.id('sn1')),'VALIDATION_FAILED');
SELECT t.error('a negative count',format($q$SELECT public.save_stock_count_lines(%L,'[{"product_id":"%s","counted_qty":-1}]')$q$,:'c1'::jsonb->>'id',t.id('tv')),'VALIDATION_FAILED');
SELECT t.expect('filters: uncounted (empty, sn3) and different (tv, cable)',
  (SELECT (j->'lines'->>'total')::int=2 FROM (SELECT public.get_stock_count((:'c1'::jsonb->>'id')::uuid,'uncounted') j) x)
  AND (SELECT (j->'lines'->>'total')::int=2 FROM (SELECT public.get_stock_count((:'c1'::jsonb->>'id')::uuid,'different') j) x)
  AND (SELECT (j->'lines'->>'total')::int=1 FROM (SELECT public.get_stock_count((:'c1'::jsonb->>'id')::uuid,'all','I02-SN-1') j) x));
SELECT t.error('post with uncounted lines',format($q$SELECT public.post_stock_count(%L,false,'i02-post-1')$q$,:'c1'::jsonb->>'id'),'STOCK_COUNT_INCOMPLETE');
RESET ROLE;
-- A sale after the tv shelf was counted (superuser): expected follows the live stock, so posting still lands on the counted 6.
SELECT t.move('tv','main',-1,'sale_out');
SELECT t.as_user('a2000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('while open, expected is the live stock (7 after the sale)',
  (t.cline(public.get_stock_count((:'c1'::jsonb->>'id')::uuid,p_limit=>100),'tv')->>'expected_qty')::int=7);
SELECT public.post_stock_count((:'c1'::jsonb->>'id')::uuid,true,'i02-post-1') AS p1 \gset
SELECT t.expect('posted: status, one adjustment linked to the count',
  :'p1'::jsonb->>'status'='posted' AND :'p1'::jsonb->>'adjustment_number' ~ '^MAIN-SA-' AND :'p1'::jsonb->>'posted_by_name'='I02 Keeper', :'p1'::text);
RESET ROLE;
SELECT t.expect('Done when: the stock equals the counted numbers (tv 6, cable 13, empty 0, phones sn1+sn2 = 2) in the levels and the ledger',
  t.level('tv','main')=6 AND t.ledger('tv','main')=6 AND t.level('cable','main')=13 AND t.ledger('cable','main')=13
  AND t.level('empty','main')=0 AND t.level('phone','main')=2 AND t.ledger('phone','main')=2
  AND (SELECT status='written_off' FROM public.units WHERE id=t.id('sn3'))
  AND (SELECT status='in_stock' FROM public.units WHERE id=t.id('sn1')));
SELECT t.expect('Done when: the ledger entries carry the reason (count) and point at the count',
  (SELECT count(*)=3 AND bool_and(m.type='adjustment' AND a.reason='count' AND a.count_id=(:'p1'::jsonb->>'id')::uuid)
   FROM public.stock_movements m JOIN public.stock_adjustments a ON a.id=m.source_id
   WHERE a.id=(:'p1'::jsonb->>'adjustment_id')::uuid)
  AND (SELECT string_agg(l.quantity::text,',' ORDER BY l.quantity) FROM public.stock_adjustment_lines l WHERE l.adjustment_id=(:'p1'::jsonb->>'adjustment_id')::uuid)='-1,-1,2');
SELECT t.expect('the sheet keeps what was expected at posting time, uncounted lines became 0',
  (SELECT expected_qty=7 AND counted_qty=6 FROM public.stock_count_lines WHERE count_id=(:'p1'::jsonb->>'id')::uuid AND product_id=t.id('tv'))
  AND (SELECT counted_qty=0 FROM public.stock_count_lines WHERE count_id=(:'p1'::jsonb->>'id')::uuid AND unit_id=t.id('sn3')));
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
SELECT t.as_user('a2000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('replaying the post key: the same adjustment, nothing posted twice',
  (public.post_stock_count((:'c1'::jsonb->>'id')::uuid,true,'i02-post-1')->>'adjustment_id')=(:'p1'::jsonb->>'adjustment_id')
  AND (SELECT count(*)=1 FROM public.stock_adjustments WHERE count_id=(:'p1'::jsonb->>'id')::uuid) AND t.level('tv','main')=6);
SELECT t.expect('posting again: the same result, nothing posted twice',
  (public.post_stock_count((:'c1'::jsonb->>'id')::uuid,true,'i02-post-1b')->>'adjustment_id')=(:'p1'::jsonb->>'adjustment_id') AND t.level('tv','main')=6);
SELECT t.error('a posted count can''t change',format($q$SELECT public.save_stock_count_lines(%L,'[{"product_id":"%s","counted_qty":1}]')$q$,:'c1'::jsonb->>'id',t.id('tv')),'DOCUMENT_FINAL');
SELECT t.error('a posted count can''t be cancelled',format($q$SELECT public.cancel_stock_count(%L)$q$,:'c1'::jsonb->>'id'),'DOCUMENT_FINAL');
SELECT t.error('the post key reused for another count',format($q$SELECT public.post_stock_count(%L,true,'i02-post-1')$q$,gen_random_uuid()),'IDEMPOTENCY_CONFLICT');
-- A category count: scope, adding an out-of-sheet product, no differences, cancel.
SELECT public.create_stock_count(t.id('main'),t.id('screens'),'i02-count-screens') AS c2 \gset
SELECT t.expect('category count (with subcategories): tv, empty, phones sn1 sn2',(:'c2'::jsonb->>'lines_total')::int=4 AND :'c2'::jsonb->>'category_name'='I02 Screens');
SELECT t.error('a product outside the count''s categories',format($q$SELECT public.scan_stock_count(%L,'I02-CB')$q$,:'c2'::jsonb->>'id'),'STOCK_COUNT_PRODUCT_OUT_OF_SCOPE');
SELECT t.error('an overlapping category count',format($q$SELECT public.create_stock_count(%L,%L,'i02-count-tvs')$q$,t.id('main'),t.id('tvs')),'STOCK_COUNT_OPEN');
SELECT t.expect('a count of other categories can run at the same time',(public.create_stock_count(t.id('main'),t.id('cables'),'i02-count-cables')->>'status')='open');
SELECT t.expect('a written-off serial found during the count is added to the sheet',
  (SELECT r->>'counted_qty'='1' AND r->>'expected_qty'='0' AND r->>'difference'='1' FROM (SELECT public.scan_stock_count((:'c2'::jsonb->>'id')::uuid,'I02-SN-3') r) x));
SELECT public.cancel_stock_count((:'c2'::jsonb->>'id')::uuid) AS x2 \gset
SELECT t.expect('cancelled: no stock change, and cancelling again answers the same',
  :'x2'::jsonb->>'status'='cancelled' AND t.level('phone','main')=2
  AND (public.cancel_stock_count((:'c2'::jsonb->>'id')::uuid)->>'status')='cancelled');
SELECT t.error('a cancelled count can''t be posted',format($q$SELECT public.post_stock_count(%L,true,'i02-post-2')$q$,:'c2'::jsonb->>'id'),'DOCUMENT_FINAL');
SELECT public.create_stock_count(t.id('main'),t.id('tvs'),'i02-count-tvs-2') AS c3 \gset
SELECT public.save_stock_count_lines((:'c3'::jsonb->>'id')::uuid,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'counted_qty',6))) AS s3 \gset
SELECT public.post_stock_count((:'c3'::jsonb->>'id')::uuid,false,'i02-post-3') AS p3 \gset
SELECT t.expect('a count with no differences posts without an adjustment',
  :'p3'::jsonb->>'status'='posted' AND :'p3'::jsonb->>'adjustment_id' IS NULL AND t.level('tv','main')=6);
SELECT t.expect('list counts: status filter',
  (public.list_stock_counts()->>'total')::int=4 AND (public.list_stock_counts(p_status=>'posted')->>'total')::int=2
  AND jsonb_array_length(public.list_stock_counts(p_limit=>3)->'items')=3);
RESET ROLE;
SELECT t.expect('audit: created, posted and cancelled rows (line saves and scans are draft data)',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_count.created')=4
  AND (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_count.posted')=2
  AND (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_count.cancelled')=1);
-- Another shop can't see or touch shop a's counts.
SELECT t.as_user('a2000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.error('shop b: get shop a''s count',format('SELECT public.get_stock_count(%L)',:'c1'::jsonb->>'id'),'STOCK_COUNT_NOT_FOUND');
SELECT t.error('shop b: scan into shop a''s count',format($q$SELECT public.scan_stock_count(%L,'I02-CB')$q$,:'c3'::jsonb->>'id'),'STOCK_COUNT_NOT_FOUND');
SELECT t.error('shop b: cancel shop a''s count',format('SELECT public.cancel_stock_count(%L)',:'c3'::jsonb->>'id'),'STOCK_COUNT_NOT_FOUND');
SELECT t.error('shop b: get shop a''s adjustment',format('SELECT public.get_stock_adjustment(%L)',:'adj1'::jsonb->>'id'),'STOCK_ADJUSTMENT_NOT_FOUND');
SELECT t.expect('shop b: lists are empty',(public.list_stock_adjustments()->>'total')::int=0 AND (public.list_stock_counts()->>'total')::int=0);
RESET ROLE;
-- An expired shop reads but doesn't write.
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a2000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: adjustments and counts still read',
  (public.list_stock_adjustments()->>'total')::int=5 AND (public.list_stock_counts()->>'total')::int=4);
SELECT t.error('expired shop: no adjustment',format($q$SELECT public.post_stock_adjustment(%L,'found',NULL,'[{"product_id":"%s","quantity":1}]','i02-adj-expired')$q$,t.id('main'),t.id('cable')),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ---------------------------------------------------------------- grants
SELECT t.expect('no anon grants; authenticated may execute the public functions',
  NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
              AND p.proname IN ('post_stock_adjustment','list_stock_adjustments','get_stock_adjustment','create_stock_count',
                                'save_stock_count_lines','scan_stock_count','post_stock_count','cancel_stock_count',
                                'list_stock_counts','get_stock_count')
              AND (has_function_privilege('anon',p.oid,'EXECUTE') OR NOT has_function_privilege('authenticated',p.oid,'EXECUTE')))
  AND NOT has_function_privilege('authenticated','app.post_adjustment_lines(uuid,uuid,uuid,uuid,jsonb)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
