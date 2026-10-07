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
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- Valid in-store EAN-13: 13 digits, starts with 2, last digit = check digit of the first 12.
CREATE FUNCTION t.valid_store_ean(b text) RETURNS boolean LANGUAGE sql AS $$ SELECT b ~ '^2[0-9]{12}$' AND right(b,1)=app.ean13_check_digit(left(b,12)) $$;
CREATE FUNCTION t.audits(a text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action=a $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON FUNCTION t.expect(text,boolean,text),t.error(text,text,text),t.as_user(text,uuid),t.org(text),t.id(text) TO authenticated;

-- ---------------------------------------------------------------- setup: two shops, cashier and branch manager in a
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('C02 '||s,'c02-'||s,'retail','Owner',s||'c02@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('i',64)),('b',repeat('j',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('c0200000-0000-0000-8000-000000000001','ac02@example.com'),('c0200000-0000-0000-8000-000000000002','bc02@example.com'),('c0200000-0000-0000-8000-000000000003','c02cashier@example.com'),('c0200000-0000-0000-8000-000000000004','c02manager@example.com');
SELECT public.accept_invite(repeat('i',64),'c0200000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('j',64),'c0200000-0000-0000-8000-000000000002');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'c0200000-0000-0000-8000-000000000003','C02 Cashier','CASHIER');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'c0200000-0000-0000-8000-000000000004','C02 Manager','BRANCH_MANAGER') RETURNING id AS manager_id \gset
-- The manager may manage the catalog but NOT change prices (an override with granted=false).
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),:'manager_id','catalog.price_change',false);
-- Files: a product image in a and b, and a logo (wrong purpose) in a.
WITH x AS (INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose) VALUES(t.org('a'),t.org('a')||'/products/a.png','image/png',10,'product_image') RETURNING id) INSERT INTO t.ids SELECT 'img_a',id FROM x;
WITH x AS (INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose) VALUES(t.org('b'),t.org('b')||'/products/b.png','image/png',10,'product_image') RETURNING id) INSERT INTO t.ids SELECT 'img_b',id FROM x;
WITH x AS (INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose) VALUES(t.org('a'),t.org('a')||'/logo/a.png','image/png',10,'logo') RETURNING id) INSERT INTO t.ids SELECT 'logo_a',id FROM x;
INSERT INTO t.ids SELECT 'std_a',default_tax_class_id FROM public.org_settings WHERE organization_id=t.org('a');
INSERT INTO t.ids SELECT 'zero_a',id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='zero';
INSERT INTO t.ids SELECT 'std_b',default_tax_class_id FROM public.org_settings WHERE organization_id=t.org('b');
INSERT INTO t.ids SELECT 'main_a',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;

-- Shop B: a category and a product, created the real way (shop B has exactly two audit rows).
SELECT t.as_user('c0200000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('cat_b',public.create_category('C02 B Cat',NULL));
INSERT INTO t.ids VALUES('prod_b',public.create_product('{"name_ar":"منتج ب","sku":"B-1","cash_price":"10.00","barcode":"9990001"}'));
RESET ROLE;

-- Shop A: categories (parent + child + an archived one) and an archived tax class.
SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('cat_parent',public.create_category('C02 Electronics',NULL));
INSERT INTO t.ids VALUES('cat_child',public.create_category('C02 TVs',t.id('cat_parent')));
INSERT INTO t.ids VALUES('cat_old',public.create_category('C02 Old',NULL));
SELECT public.set_category_archived(t.id('cat_old'),true);
INSERT INTO t.ids VALUES('tax_old',public.create_tax_class('C02 Old rate','standard',10,'T1','V009'));
SELECT public.set_tax_class_archived(t.id('tax_old'),true);

-- ---------------------------------------------------------------- create
INSERT INTO t.ids VALUES('tv',public.create_product(jsonb_build_object('name_ar','تلفزيون سامسونج','name_en','Samsung TV','sku',' tv-55 ','cash_price','15000.00','category_id',t.id('cat_child'))));
INSERT INTO t.ids VALUES('fridge',public.create_product(jsonb_build_object('name_ar','ثلاجة','name_en','Fridge','sku','FRIDGE-1','barcode','6223000000017','cash_price','18000','installment_price','21000.50','tax_class_id',t.id('zero_a'),'category_id',t.id('cat_parent'),'unit_of_measure','set','warranty_months',24,'min_stock',3,'image_file_id',t.id('img_a'),'eta_item_code','EG-123','eta_item_type','EGS')));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"موبايل","sku":"PH-1","cash_price":"9000","is_serialized":true}'));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"كابل","sku":"CB-1","cash_price":"50","barcode":""}'));
SELECT t.expect('create: SKU trimmed and upper-cased, defaults applied',
  (SELECT sku='TV-55' AND unit_of_measure='piece' AND warranty_months=0 AND NOT is_serialized AND min_stock=0
          AND is_active AND archived_at IS NULL AND avg_cost=0 AND installment_price IS NULL
   FROM public.products WHERE id=t.id('tv')));
SELECT t.expect('create: the shop default tax class is used when omitted',(SELECT tax_class_id=t.id('std_a') FROM public.products WHERE id=t.id('tv')));
SELECT t.expect('create: every given field is stored',
  (SELECT barcode='6223000000017' AND cash_price=18000 AND installment_price=21000.50 AND tax_class_id=t.id('zero_a')
          AND category_id=t.id('cat_parent') AND unit_of_measure='set' AND warranty_months=24 AND min_stock=3
          AND image_file_id=t.id('img_a') AND eta_item_code='EG-123' AND eta_item_type='EGS'
   FROM public.products WHERE id=t.id('fridge')));
SELECT t.expect('get_product: money and cost are decimal strings',
  (SELECT p->>'cash_price'='18000.00' AND p->>'installment_price'='21000.50' AND p->>'avg_cost'='0.0000'
          AND jsonb_typeof(p->'cash_price')='string' AND NOT p ? 'is_active' AND NOT p ? 'organization_id'
   FROM public.get_product(t.id('fridge')) p));
RESET ROLE;
SELECT t.expect('generated barcode: 13 digits, starts with 2, valid check digit (null and empty barcode)',
  (SELECT bool_and(t.valid_store_ean(barcode)) FROM public.products WHERE id IN (t.id('tv'),t.id('phone'),t.id('cable'))),
  (SELECT string_agg(barcode,',') FROM public.products WHERE id IN (t.id('tv'),t.id('phone'),t.id('cable'))));
SELECT t.expect('generated barcodes differ',(SELECT count(DISTINCT barcode)=3 FROM public.products WHERE id IN (t.id('tv'),t.id('phone'),t.id('cable'))));
SELECT t.expect('ean13_check_digit matches known codes',
  app.ean13_check_digit('400638133393')='1' AND app.ean13_check_digit('590123412345')='7'
  AND app.ean13_check_digit('622300000001')='4' AND app.ean13_check_digit('000000000000')='0');
SELECT t.error('ean13_check_digit refuses a non-12-digit input',$q$SELECT app.ean13_check_digit('12345')$q$,'VALIDATION_FAILED');

SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('SKU taken (any case)',$q$SELECT public.create_product('{"name_ar":"x","sku":"Tv-55","cash_price":"1"}')$q$,'PRODUCT_SKU_TAKEN');
SELECT t.error('barcode taken',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-1","cash_price":"1","barcode":"6223000000017"}')$q$,'PRODUCT_BARCODE_TAKEN');
SELECT t.error('archived tax class',format('SELECT public.create_product(%L)',jsonb_build_object('name_ar','x','sku','X-2','cash_price','1','tax_class_id',t.id('tax_old'))),'TAX_CLASS_NOT_FOUND');
SELECT t.error('another shop tax class',format('SELECT public.create_product(%L)',jsonb_build_object('name_ar','x','sku','X-3','cash_price','1','tax_class_id',t.id('std_b'))),'TAX_CLASS_NOT_FOUND');
SELECT t.error('null tax class',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-3B","cash_price":"1","tax_class_id":null}')$q$,'TAX_CLASS_NOT_FOUND');
SELECT t.error('archived category',format('SELECT public.create_product(%L)',jsonb_build_object('name_ar','x','sku','X-4','cash_price','1','category_id',t.id('cat_old'))),'PRODUCT_CATEGORY_ARCHIVED');
SELECT t.error('another shop category',format('SELECT public.create_product(%L)',jsonb_build_object('name_ar','x','sku','X-5','cash_price','1','category_id',t.id('cat_b'))),'CATEGORY_NOT_FOUND');
SELECT t.error('another shop image',format('SELECT public.create_product(%L)',jsonb_build_object('name_ar','x','sku','X-6','cash_price','1','image_file_id',t.id('img_b'))),'FILE_NOT_FOUND');
SELECT t.error('a file that is not a product image',format('SELECT public.create_product(%L)',jsonb_build_object('name_ar','x','sku','X-7','cash_price','1','image_file_id',t.id('logo_a'))),'FILE_NOT_FOUND');
SELECT t.error('ETA code without a type',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-8","cash_price":"1","eta_item_code":"EG-1"}')$q$,'VALIDATION_FAILED');
SELECT t.error('ETA type without a code',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-8B","cash_price":"1","eta_item_type":"GS1"}')$q$,'VALIDATION_FAILED');
SELECT t.error('unknown ETA type',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-8C","cash_price":"1","eta_item_code":"1","eta_item_type":"ABC"}')$q$,'VALIDATION_FAILED');
SELECT t.error('avg_cost in the body',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-9","cash_price":"1","avg_cost":"5"}')$q$,'VALIDATION_FAILED');
SELECT t.error('is_active in the body',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-10","cash_price":"1","is_active":false}')$q$,'VALIDATION_FAILED');
SELECT t.error('organization_id in the body',format('SELECT public.create_product(%L)',jsonb_build_object('name_ar','x','sku','X-11','cash_price','1','organization_id',t.org('b'))),'VALIDATION_FAILED');
SELECT t.error('blank Arabic name',$q$SELECT public.create_product('{"name_ar":"  ","sku":"X-12","cash_price":"1"}')$q$,'NAME_REQUIRED');
SELECT t.error('missing Arabic name',$q$SELECT public.create_product('{"sku":"X-13","cash_price":"1"}')$q$,'NAME_REQUIRED');
SELECT t.error('missing SKU',$q$SELECT public.create_product('{"name_ar":"x","cash_price":"1"}')$q$,'VALIDATION_FAILED');
SELECT t.error('missing cash price',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-14"}')$q$,'VALIDATION_FAILED');
SELECT t.error('SKU with a space',$q$SELECT public.create_product('{"name_ar":"x","sku":"X 15","cash_price":"1"}')$q$,'VALIDATION_FAILED');
SELECT t.error('negative price',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-16","cash_price":"-1"}')$q$,'VALIDATION_FAILED');
SELECT t.error('three decimals',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-17","cash_price":"1.005"}')$q$,'VALIDATION_FAILED');
SELECT t.error('price that is not a number',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-18","cash_price":"abc"}')$q$,'VALIDATION_FAILED');
SELECT t.error('barcode too short',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-19","cash_price":"1","barcode":"12"}')$q$,'VALIDATION_FAILED');
SELECT t.error('warranty above 120',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-20","cash_price":"1","warranty_months":121}')$q$,'VALIDATION_FAILED');
SELECT t.error('fractional min stock',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-21","cash_price":"1","min_stock":1.5}')$q$,'VALIDATION_FAILED');
SELECT t.error('serialized flag that is not a boolean',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-22","cash_price":"1","is_serialized":"yes"}')$q$,'VALIDATION_FAILED');
SELECT t.error('bad category uuid',$q$SELECT public.create_product('{"name_ar":"x","sku":"X-23","cash_price":"1","category_id":"nope"}')$q$,'VALIDATION_FAILED');
SELECT t.error('body that is not an object',$q$SELECT public.create_product('"text"')$q$,'VALIDATION_FAILED');
SELECT t.expect('refused creates left nothing behind',(SELECT count(*)=4 FROM public.products WHERE organization_id=t.org('a')));

-- ---------------------------------------------------------------- price changes and updates
-- The manager: catalog.manage yes, catalog.price_change no (override).
SELECT t.as_user('c0200000-0000-0000-8000-000000000004',t.org('a'));
SELECT public.update_product(t.id('tv'),'{"name_en":"Samsung TV 55"}');
SELECT t.expect('manager without price_change can rename',(SELECT name_en='Samsung TV 55' FROM public.products WHERE id=t.id('tv')));
SELECT t.error('manager without price_change cannot change the cash price',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"cash_price":"14000"}'),'PERMISSION_DENIED');
SELECT t.error('manager without price_change cannot set the installment price',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"installment_price":"17000"}'),'PERMISSION_DENIED');
-- The same price in another spelling is not a change.
SELECT public.update_product(t.id('tv'),'{"cash_price":"15000"}');
SELECT t.expect('the manager''s refused price change left the price alone',(SELECT cash_price=15000 AND installment_price IS NULL FROM public.products WHERE id=t.id('tv')));

SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SELECT public.update_product(t.id('tv'),'{"cash_price":"14500.00","name_en":"Samsung TV 55 inch"}');
SELECT t.expect('owner changes the price',(SELECT cash_price=14500 FROM public.products WHERE id=t.id('tv')));
RESET ROLE;
SELECT t.expect('a price change writes one product.price_changed row with before/after of every changed key',
  t.audits('product.price_changed')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='product.price_changed'
     AND entity_id=t.id('tv') AND before->>'cash_price'='15000.00' AND after->>'cash_price'='14500.00'
     AND before->>'name_en'='Samsung TV 55' AND after->>'name_en'='Samsung TV 55 inch'
     AND NOT before ? 'sku' AND NOT after ? 'updated_at'));
SET LOCAL ROLE authenticated;
SELECT public.update_product(t.id('tv'),'{"min_stock":2}');
RESET ROLE;
SELECT t.expect('a non-price edit writes product.updated (manager rename + this one)',t.audits('product.updated')=2
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='product.updated' AND entity_id=t.id('tv') AND before='{"min_stock":0}'::jsonb AND after='{"min_stock":2}'::jsonb));
SET LOCAL ROLE authenticated;
SELECT public.update_product(t.id('tv'),'{"min_stock":2,"sku":"tv-55","name_ar":" تلفزيون سامسونج "}');
RESET ROLE;
SELECT t.expect('no change writes no row',t.audits('product.updated')=2 AND t.audits('product.price_changed')=1);
SET LOCAL ROLE authenticated;
SELECT t.error('avg_cost on update',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"avg_cost":"1"}'),'VALIDATION_FAILED');
SELECT t.error('unknown key on update',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"bogus":1}'),'VALIDATION_FAILED');
SELECT t.error('archived_at on update',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"archived_at":null}'),'VALIDATION_FAILED');
SELECT t.error('SKU taken on update',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"sku":"fridge-1"}'),'PRODUCT_SKU_TAKEN');
SELECT t.error('barcode taken on update',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"barcode":"6223000000017"}'),'PRODUCT_BARCODE_TAKEN');
SELECT t.error('archived category on update',format('SELECT public.update_product(%L,%L)',t.id('tv'),jsonb_build_object('category_id',t.id('cat_old'))),'PRODUCT_CATEGORY_ARCHIVED');
SELECT t.error('removing the ETA type alone breaks the pair',format('SELECT public.update_product(%L,%L)',t.id('fridge'),'{"eta_item_type":null}'),'VALIDATION_FAILED');
SELECT t.error('missing id on update',$q$SELECT public.update_product('00000000-0000-0000-0000-0000000000dd','{"name_en":"x"}')$q$,'PRODUCT_NOT_FOUND');
-- Barcode null or empty on update generates a new one.
SELECT barcode AS tv_old_barcode FROM public.products WHERE id=t.id('tv') \gset
SELECT public.update_product(t.id('fridge'),'{"barcode":null,"eta_item_code":null,"eta_item_type":null,"category_id":null,"image_file_id":null}');
SELECT t.expect('update: barcode null generates a new one; ETA pair and links cleared',
  (SELECT barcode<>'6223000000017' AND barcode ~ '^2[0-9]{12}$' AND eta_item_code IS NULL AND eta_item_type IS NULL
          AND category_id IS NULL AND image_file_id IS NULL FROM public.products WHERE id=t.id('fridge')));
SELECT public.update_product(t.id('tv'),'{"barcode":""}');
SELECT t.expect('update: empty barcode generates a new one',
  (SELECT barcode<>:'tv_old_barcode' AND barcode ~ '^2[0-9]{12}$' FROM public.products WHERE id=t.id('tv')));
SELECT public.update_product(t.id('fridge'),'{"barcode":"6223000000017"}');
SELECT t.expect('a given barcode can be set back',(SELECT barcode='6223000000017' FROM public.products WHERE id=t.id('fridge')));

-- ---------------------------------------------------------------- serialized lock
SELECT public.update_product(t.id('cable'),'{"is_serialized":true}');
SELECT public.update_product(t.id('cable'),'{"is_serialized":false}');
SELECT t.expect('serialized flag changes freely before any unit or movement',(SELECT NOT is_serialized FROM public.products WHERE id=t.id('cable')));
RESET ROLE;
INSERT INTO public.units(organization_id,product_id,serial,branch_id,cost) VALUES(t.org('a'),t.id('phone'),'C02-IMEI-1',t.id('main_a'),100);
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id) VALUES(t.org('a'),t.id('cable'),t.id('main_a'),5,'purchase_in','purchase_invoice',gen_random_uuid());
SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('serialized lock after a units row',format('SELECT public.update_product(%L,%L)',t.id('phone'),'{"is_serialized":false}'),'PRODUCT_SERIAL_LOCKED');
SELECT t.error('serialized lock after a stock_movements row',format('SELECT public.update_product(%L,%L)',t.id('cable'),'{"is_serialized":true}'),'PRODUCT_SERIAL_LOCKED');
SELECT public.update_product(t.id('phone'),'{"is_serialized":true,"warranty_months":12}');
SELECT t.expect('other edits still work on a locked product',(SELECT is_serialized AND warranty_months=12 FROM public.products WHERE id=t.id('phone')));
RESET ROLE;

-- ---------------------------------------------------------------- old sales (the slice's Done when)
INSERT INTO public.sales(organization_id,number,branch_id,prices_include_vat,subtotal,tax_total,total,business_date,idempotency_key)
VALUES(t.org('a'),'C02-SL-1',t.id('main_a'),true,50,0,50,CURRENT_DATE,'c02-sale-0001') RETURNING id AS sale_id \gset
INSERT INTO public.sale_lines(organization_id,sale_id,line_no,product_id,quantity,unit_price,tax_class_id,tax_rate,tax_amount,line_total)
VALUES(t.org('a'),:'sale_id',1,t.id('cable'),1,50,t.id('std_a'),14,6.14,50);

-- ---------------------------------------------------------------- archive / restore
SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.set_product_archived(t.id('cable'),true);
SELECT public.set_product_archived(t.id('cable'),true);          -- same state: no second row
SELECT t.expect('archive sets archived_at and is_active=false together (with stock on hand)',
  (SELECT archived_at IS NOT NULL AND NOT is_active FROM public.products WHERE id=t.id('cable')));
SELECT t.error('archived products are not in lookup_product (barcode)',format('SELECT public.lookup_product(%L)',(SELECT barcode FROM public.products WHERE id=t.id('cable'))),'PRODUCT_NOT_FOUND');
SELECT t.error('archived products are not in lookup_product (SKU)',$q$SELECT public.lookup_product('cb-1')$q$,'PRODUCT_NOT_FOUND');
SELECT t.expect('archived products appear in get_product',(SELECT p->>'archived_at' IS NOT NULL FROM public.get_product(t.id('cable')) p));
SELECT t.expect('archived products appear in list_products(status archived) only',
  (SELECT (l->>'total')::int=1 AND l->'items'->0->>'sku'='CB-1' FROM public.list_products(NULL,NULL,true,'archived',50,0) l)
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements((public.list_products(NULL,NULL,true,'active',50,0))->'items') i WHERE i->>'sku'='CB-1')
  AND ((public.list_products(NULL,NULL,true,'all',50,0))->>'total')::int=4);
SELECT t.error('an archived product cannot be edited',format('SELECT public.update_product(%L,%L)',t.id('cable'),'{"name_en":"x"}'),'PRODUCT_NOT_FOUND');
RESET ROLE;
SELECT t.expect('Done when: the old sale line still joins to the archived product name and SKU',
  (SELECT p.name_ar='كابل' AND p.sku='CB-1' AND p.archived_at IS NOT NULL
   FROM public.sale_lines sl JOIN public.products p ON p.id=sl.product_id AND p.organization_id=sl.organization_id
   WHERE sl.sale_id=:'sale_id' AND sl.line_no=1));
SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.set_product_archived(t.id('cable'),false);
SELECT t.expect('restore clears archived_at and sets is_active',(SELECT archived_at IS NULL AND is_active FROM public.products WHERE id=t.id('cable')));
-- Restore refused under an archived category or with an archived tax class.
SELECT public.update_product(t.id('cable'),jsonb_build_object('category_id',t.id('cat_child')));
SELECT public.set_product_archived(t.id('cable'),true);
SELECT public.set_product_archived(t.id('tv'),true);
SELECT public.set_category_archived(t.id('cat_child'),true);
SELECT t.error('restore refused under an archived category',format('SELECT public.set_product_archived(%L,false)',t.id('cable')),'PRODUCT_CATEGORY_ARCHIVED');
SELECT public.set_category_archived(t.id('cat_child'),false);
SELECT public.set_product_archived(t.id('tv'),false);
SELECT public.update_product(t.id('phone'),jsonb_build_object('tax_class_id',t.id('zero_a')));
SELECT public.set_product_archived(t.id('phone'),true);
RESET ROLE;
UPDATE public.tax_classes SET archived_at=now() WHERE id=t.id('zero_a');   -- no active product uses it now
SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('restore refused with an archived tax class',format('SELECT public.set_product_archived(%L,false)',t.id('phone')),'TAX_CLASS_NOT_FOUND');
SELECT t.error('archive of a missing product',$q$SELECT public.set_product_archived('00000000-0000-0000-0000-0000000000dd',true)$q$,'PRODUCT_NOT_FOUND');
RESET ROLE;
UPDATE public.tax_classes SET archived_at=NULL WHERE id=t.id('zero_a');

-- ---------------------------------------------------------------- lookup
SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('lookup by exact barcode',(SELECT p->>'id'=t.id('fridge')::text FROM public.lookup_product(' 6223000000017 ') p));
SELECT t.expect('lookup by SKU in any case',(SELECT p->>'id'=t.id('tv')::text FROM public.lookup_product('tv-55') p));
SELECT t.error('lookup of an unknown code',$q$SELECT public.lookup_product('NOPE-404')$q$,'PRODUCT_NOT_FOUND');
SELECT t.error('lookup of a blank code',$q$SELECT public.lookup_product('  ')$q$,'VALIDATION_FAILED');
SELECT t.error('lookup of another shop barcode',$q$SELECT public.lookup_product('9990001')$q$,'PRODUCT_NOT_FOUND');
-- Barcode first: a product whose SKU equals another product's barcode loses to the barcode.
INSERT INTO t.ids VALUES('clash',public.create_product('{"name_ar":"تعارض","sku":"6223000000017","cash_price":"1"}'));
SELECT t.expect('lookup prefers the barcode over the SKU',(SELECT p->>'id'=t.id('fridge')::text FROM public.lookup_product('6223000000017') p));

-- ---------------------------------------------------------------- list
SELECT t.expect('list: search by Arabic name',(SELECT (l->>'total')::int=1 AND l->'items'->0->>'sku'='TV-55' FROM public.list_products('سامسونج',NULL,true,'active',50,0) l));
SELECT t.expect('list: search by English name (any case)',(SELECT (l->>'total')::int=1 AND l->'items'->0->>'sku'='FRIDGE-1' FROM public.list_products('fridge',NULL,true,'active',50,0) l));
SELECT t.expect('list: search by SKU prefix',(SELECT (l->>'total')::int=1 AND l->'items'->0->>'sku'='TV-55' FROM public.list_products('tv-',NULL,true,'active',50,0) l));
SELECT t.expect('list: search by exact barcode',(SELECT (l->>'total')::int=2 FROM public.list_products('6223000000017',NULL,true,'active',50,0) l));
SELECT t.expect('list: a partial barcode does not match',(SELECT (l->>'total')::int=0 FROM public.list_products('23000000017',NULL,true,'active',50,0) l));
SELECT t.expect('list: LIKE wildcards are literal',(SELECT (l->>'total')::int=0 FROM public.list_products('%',NULL,true,'active',50,0) l));
SELECT public.update_product(t.id('fridge'),jsonb_build_object('category_id',t.id('cat_parent')));
SELECT t.expect('list: a parent category includes its subcategories',
  (SELECT (l->>'total')::int=2 FROM public.list_products(NULL,t.id('cat_parent'),true,'active',50,0) l));
SELECT t.expect('list: without subcategories only the category itself',
  (SELECT (l->>'total')::int=1 AND l->'items'->0->>'sku'='FRIDGE-1' FROM public.list_products(NULL,t.id('cat_parent'),false,'active',50,0) l));
SELECT t.expect('list: another shop category matches nothing',(SELECT (l->>'total')::int=0 FROM public.list_products(NULL,t.id('cat_b'),true,'all',50,0) l));
SELECT t.expect('list: paging returns the page and the full total, in name order',
  (SELECT (l->>'total')::int=3 AND jsonb_array_length(l->'items')=2 FROM public.list_products(NULL,NULL,true,'active',2,0) l)
  AND (SELECT (l->>'total')::int=3 AND jsonb_array_length(l->'items')=1 FROM public.list_products(NULL,NULL,true,'active',2,2) l)
  AND (SELECT array_agg(i->>'name_ar' ORDER BY o)=ARRAY['تعارض','تلفزيون سامسونج','ثلاجة']
       FROM jsonb_array_elements((public.list_products(NULL,NULL,true,'active',50,0))->'items') WITH ORDINALITY x(i,o)));
SELECT t.error('list: unknown status',$q$SELECT public.list_products(NULL,NULL,true,'deleted',50,0)$q$,'VALIDATION_FAILED');
SELECT t.error('list: page size above 100',$q$SELECT public.list_products(NULL,NULL,true,'active',101,0)$q$,'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- another shop's ids
SELECT t.as_user('c0200000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('another shop id: get',format('SELECT public.get_product(%L)',t.id('prod_b')),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop id: update',format('SELECT public.update_product(%L,%L)',t.id('prod_b'),'{"name_ar":"Taken over"}'),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop id: price',format('SELECT public.update_product(%L,%L)',t.id('prod_b'),'{"cash_price":"1"}'),'PRODUCT_NOT_FOUND');
SELECT t.error('another shop id: archive',format('SELECT public.set_product_archived(%L,true)',t.id('prod_b')),'PRODUCT_NOT_FOUND');
SELECT t.expect('another shop products are not listed',NOT EXISTS(SELECT 1 FROM jsonb_array_elements((public.list_products(NULL,NULL,true,'all',100,0))->'items') i WHERE i->>'id'=t.id('prod_b')::text));
RESET ROLE;
SELECT t.expect('shop B is unchanged',
  (SELECT count(*)=1 FROM public.products WHERE organization_id=t.org('b'))
  AND (SELECT name_ar='منتج ب' AND cash_price=10 AND archived_at IS NULL FROM public.products WHERE id=t.id('prod_b'))
  AND (SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('b') AND entity_type='product'));

-- ---------------------------------------------------------------- cashier: reads, never writes
SELECT t.as_user('c0200000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier can list',(SELECT (l->>'total')::int=3 FROM public.list_products(NULL,NULL,true,'active',50,0) l));
SELECT t.expect('cashier can get',(SELECT p->>'sku'='TV-55' FROM public.get_product(t.id('tv')) p));
SELECT t.expect('cashier can lookup',(SELECT p->>'sku'='TV-55' FROM public.lookup_product('TV-55') p));
SELECT t.error('cashier cannot create',$q$SELECT public.create_product('{"name_ar":"x","sku":"CASH-1","cash_price":"1"}')$q$,'PERMISSION_DENIED');
SELECT t.error('cashier cannot update',format('SELECT public.update_product(%L,%L)',t.id('tv'),'{"name_en":"Cashier"}'),'PERMISSION_DENIED');
SELECT t.error('cashier cannot archive',format('SELECT public.set_product_archived(%L,true)',t.id('tv')),'PERMISSION_DENIED');
SELECT t.error('cashier cannot restore',format('SELECT public.set_product_archived(%L,false)',t.id('phone')),'PERMISSION_DENIED');
SELECT t.as_user('c0200000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee cannot list',$q$SELECT public.list_products(NULL,NULL,true,'active',50,0)$q$,'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee cannot lookup',$q$SELECT public.lookup_product('TV-55')$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;

-- ---------------------------------------------------------------- audit: exactly one row per write
SELECT t.expect('one product.created per created product (4 + the clash product)',t.audits('product.created')=5);
SELECT t.expect('archive and restore rows (same-state calls wrote none), archive is a warning',
  t.audits('product.archived')=4 AND t.audits('product.restored')=2
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='product.archived' AND severity<>'warning')
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='product.restored' AND severity<>'info'));
SELECT t.expect('the price_changed row stays the only one',t.audits('product.price_changed')=1);

-- ---------------------------------------------------------------- grants
SELECT t.expect('no anon grants on the new functions',
  NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace
             AND proname IN('list_products','get_product','lookup_product','create_product','update_product','set_product_archived')
             AND has_function_privilege('anon',oid,'EXECUTE')));
SELECT t.expect('app.* helpers are not granted',
  NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='app'::regnamespace
             AND proname IN('ean13_check_digit','generate_product_barcode','product_json','product_apply')
             AND (has_function_privilege('authenticated',oid,'EXECUTE') OR has_function_privilege('anon',oid,'EXECUTE'))));
SELECT t.expect('authenticated executes exactly the six new public functions',
  (SELECT count(*)=6 FROM pg_proc WHERE pronamespace='public'::regnamespace
   AND proname IN('list_products','get_product','lookup_product','create_product','update_product','set_product_archived')
   AND has_function_privilege('authenticated',oid,'EXECUTE')));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
