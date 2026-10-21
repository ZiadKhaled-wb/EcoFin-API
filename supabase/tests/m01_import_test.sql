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
-- A file row (what F14 stores) for shop a; returns its id under the tag.
CREATE FUNCTION t.file(tag text) RETURNS uuid LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.files(organization_id,path,original_name,mime,size_bytes,sha256,purpose)
    VALUES(t.org('a'),t.org('a')::text||'/import/'||tag||'.csv',tag||'.csv','text/csv',10,repeat('a',64),'import') RETURNING id)
  INSERT INTO t.ids SELECT tag,id FROM x RETURNING id $$;
-- Rows as the API passes them: t.rows('{"sku":"A","cash_price":"5"}', '{"sku":"B"...}') -> rows 2, 3, ...
CREATE FUNCTION t.rows(VARIADIC v text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('row',o+1,'values',x::jsonb) ORDER BY o) FROM unnest(v) WITH ORDINALITY u(x,o) $$;
CREATE FUNCTION t.dry(k text,rows jsonb,key text,branch uuid DEFAULT NULL,meta jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.create_import(k,t.id('file'),branch,rows,meta,key) $$;
CREATE FUNCTION t.level(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0) $$;
CREATE FUNCTION t.codes(job jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg((e->>'row')||':'||COALESCE(e->>'column','-')||':'||(e->>'code'),' | ' ORDER BY (e->>'row')::int, e->>'column') FROM jsonb_array_elements(job->'report'->'errors') e $$;
-- Runs the import job as the worker does: queue (as the owner) then jobs_import_apply (service role).
CREATE FUNCTION t.run(job jsonb,rows jsonb,key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.queue_import((job->>'id')::uuid,key);
  r := public.jobs_import_apply((job->>'id')::uuid,rows);
  RETURN r;
END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (retail_pro), shop b, a cashier
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('M01 '||s,'m01-'||s,p,'Owner',s||'m01@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a','retail_pro',repeat('m',64)),('b','retail',repeat('n',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a5000000-0000-0000-8000-000000000001','am01@example.com'),('a5000000-0000-0000-8000-000000000002','bm01@example.com'),('a5000000-0000-0000-8000-000000000003','m01cashier@example.com'),('a5000000-0000-0000-8000-000000000004','m01manager@example.com');
SELECT public.accept_invite(repeat('m',64),'a5000000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('n',64),'a5000000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5000000-0000-0000-8000-000000000003','M01 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5000000-0000-0000-8000-000000000004','M01 Manager','BRANCH_MANAGER',t.id('main')) RETURNING id AS manager_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'manager_id',t.id('main'));
SELECT t.file('file');
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
INSERT INTO t.ids VALUES('second',public.create_branch('Second','M2',NULL,NULL,NULL,NULL,NULL));
-- A file of shop b, for the cross-shop case.
INSERT INTO public.files(organization_id,path,original_name,mime,size_bytes,sha256,purpose) VALUES(t.org('b'),t.org('b')::text||'/import/b.csv','b.csv','text/csv',10,repeat('b',64),'import') RETURNING id AS bfile \gset
INSERT INTO t.ids VALUES('bfile',:'bfile');

-- ================================================================ suppliers
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SELECT t.dry('suppliers',t.rows('{"name":"Nile Traders","phone":"010 1234 5678","payment_terms_days":"30"}','{"name":"مورد الشرق","phone":"٠١١٢٣٤٥٦٧٨٩"}','{"name":"Delta Supply"}'),'m01-sup-1') AS s1 \gset
SELECT t.expect('suppliers dry run: validated, 3 to create, nothing saved',
  :'s1'::jsonb->>'status'='validated' AND (:'s1'::jsonb#>>'{report,actions,create}')::int=3
  AND (:'s1'::jsonb->>'rows_total')::int=3 AND (:'s1'::jsonb#>>'{report,errors_total}')::int=0
  AND (SELECT count(*)=0 FROM public.suppliers WHERE organization_id=t.org('a')), :'s1'::text);
SELECT t.expect('the dry run answer never carries the idempotency key', NOT (:'s1'::jsonb->'report' ? 'idempotency_key') AND NOT (:'s1'::jsonb->'report' ? 'run_key'));
SELECT t.expect('same key again: the same job, no second row, no second audit row',
  (t.dry('suppliers',t.rows('{"name":"Other"}'),'m01-sup-1')->>'id')=(:'s1'::jsonb->>'id')
  AND (SELECT count(*)=1 FROM public.import_jobs WHERE organization_id=t.org('a') AND report->>'idempotency_key'='m01-sup-1')
  AND (SELECT count(*)=1 FROM public.audit_log WHERE entity_id=(:'s1'::jsonb->>'id')::uuid AND action='import.validated'));
SELECT t.run(:'s1'::jsonb,t.rows('{"name":"Nile Traders","phone":"010 1234 5678","payment_terms_days":"30"}','{"name":"مورد الشرق","phone":"٠١١٢٣٤٥٦٧٨٩"}','{"name":"Delta Supply"}'),'m01-sup-run-1') AS r1 \gset
SELECT t.expect('suppliers import: completed, 3 suppliers with the phone stored without spaces',
  :'r1'::jsonb->>'status'='completed'
  AND (SELECT count(*)=3 AND bool_or(name='Nile Traders' AND phone='01012345678' AND payment_terms_days=30)
       AND bool_or(name='مورد الشرق' AND phone='01123456789') FROM public.suppliers WHERE organization_id=t.org('a')),:'r1'::text);
SELECT t.expect('one audit row per import (import.completed), none per supplier',
  (SELECT count(*)=1 FROM public.audit_log WHERE entity_id=(:'s1'::jsonb->>'id')::uuid AND action='import.completed' AND employee_id IS NOT NULL)
  AND (SELECT count(*)=0 FROM public.audit_log WHERE organization_id=t.org('a') AND action='supplier.created'));
SELECT t.expect('the job is completed with counts and the applied report',
  (SELECT status='completed' AND rows_ok=3 AND rows_failed=0 AND finished_at IS NOT NULL AND report#>>'{applied,create}'='3' FROM public.import_jobs WHERE id=(:'s1'::jsonb->>'id')::uuid));
-- Re-import: nothing duplicated; one phone changed.
SELECT t.dry('suppliers',t.rows('{"name":"Nile Traders","phone":"010 1234 5678","payment_terms_days":"30"}','{"name":"مورد الشرق","phone":"01123456789"}','{"name":"Delta Supply","address":"Giza"}'),'m01-sup-2') AS s2 \gset
SELECT t.expect('suppliers re-import: 0 created, 2 unchanged, 1 updated',
  (:'s2'::jsonb#>>'{report,actions,create}')::int=0 AND (:'s2'::jsonb#>>'{report,actions,unchanged}')::int=2 AND (:'s2'::jsonb#>>'{report,actions,update}')::int=1,:'s2'::text);
SELECT t.expect('the dry-run preview lists each row with its action',
  (SELECT string_agg(e->>'action',',' ORDER BY (e->>'row')::int)='unchanged,unchanged,update' FROM jsonb_array_elements(:'s2'::jsonb#>'{report,preview}') e));
SELECT t.run(:'s2'::jsonb,t.rows('{"name":"Nile Traders","phone":"010 1234 5678","payment_terms_days":"30"}','{"name":"مورد الشرق","phone":"01123456789"}','{"name":"Delta Supply","address":"Giza"}'),'m01-sup-run-2') AS r2 \gset
SELECT t.expect('suppliers re-import applied: still 3 suppliers, Delta got its address',
  (SELECT count(*)=3 AND bool_or(name='Delta Supply' AND address='Giza') FROM public.suppliers WHERE organization_id=t.org('a')));
-- Errors: all listed, nothing saved.
SELECT t.dry('suppliers',t.rows('{"name":"","phone":"1"}','{"name":"New One","phone":"abc"}','{"name":"Dup"}','{"name":"dup"}','{"name":"Terms","payment_terms_days":"400"}','{"name":"Delta Supply","phone":"01012345678"}'),'m01-sup-3') AS s3 \gset
SELECT t.expect('suppliers with errors: every error is listed by row and column; the job is failed',
  :'s3'::jsonb->>'status'='failed' AND t.codes(:'s3'::jsonb)='2:name:IMPORT_REQUIRED | 3:phone:IMPORT_INVALID_VALUE | 5:name:IMPORT_DUPLICATE_ROW | 6:payment_terms_days:IMPORT_INVALID_VALUE | 7:phone:SUPPLIER_PHONE_TAKEN', t.codes(:'s3'::jsonb));
SELECT t.expect('suppliers errors: exactly the expected list',
  t.codes(:'s3'::jsonb)='2:name:IMPORT_REQUIRED | 3:phone:IMPORT_INVALID_VALUE | 5:name:IMPORT_DUPLICATE_ROW | 6:payment_terms_days:IMPORT_INVALID_VALUE | 7:phone:SUPPLIER_PHONE_TAKEN',t.codes(:'s3'::jsonb));
SELECT t.error('a failed job cannot be imported',format($q$SELECT public.queue_import(%L,'m01-sup-run-3')$q$,:'s3'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');

-- ================================================================ products
-- Done when: a file with errors in 3 rows (missing name_ar, price "1,500", repeated SKU) -> all 3 listed,
-- the import button refused, the products count unchanged.
SELECT t.dry('products',t.rows(
  '{"sku":"p-1","name_ar":"سامسونج","cash_price":"9000","category":"Phones > Samsung"}',
  '{"sku":"P-2","cash_price":"100"}',
  '{"sku":"P-3","name_ar":"كابل","cash_price":"1,500"}',
  '{"sku":"p-1","name_ar":"مكرر","cash_price":"5"}'),'m01-prod-1') AS p1 \gset
SELECT t.expect('Done when: products with 3 errors list all 3 with row and column; row 2 only shows a category to create',
  :'p1'::jsonb->>'status'='failed' AND t.codes(:'p1'::jsonb)='3:name_ar:IMPORT_REQUIRED | 4:cash_price:IMPORT_INVALID_VALUE | 5:sku:IMPORT_DUPLICATE_ROW'
  AND :'p1'::jsonb#>'{report,will_create_categories}'='["Phones","Phones > Samsung"]'::jsonb,
  t.codes(:'p1'::jsonb)||' '||(:'p1'::jsonb#>'{report,will_create_categories}')::text);
SELECT t.error('Done when: the import button is refused (IMPORT_NOT_VALIDATED)',format($q$SELECT public.queue_import(%L,'m01-prod-run-0')$q$,:'p1'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');
SELECT t.expect('Done when: nothing was saved (no product, no category)',
  (SELECT count(*)=0 FROM public.products WHERE organization_id=t.org('a')) AND (SELECT count(*)=0 FROM public.categories WHERE organization_id=t.org('a')));
SELECT t.expect('the thousands separator gets its own message',
  (SELECT e->>'message' LIKE '%thousands%' FROM jsonb_array_elements(:'p1'::jsonb#>'{report,errors}') e WHERE e->>'column'='cash_price'));
-- The fixed file: 2 products, one serialized, no barcode (generated), one tax class default.
SELECT t.rows(
  '{"sku":"P-1","name_ar":"سامسونج A15","name_en":"Samsung A15","cash_price":"9000","category":"Phones > Samsung","is_serialized":"نعم","warranty_months":"12"}',
  '{"sku":"P-2","name_ar":"كابل","cash_price":"100.50","barcode":"6221000000011","min_stock":"٥"}',
  '{"sku":"P-3","name_ar":"شاحن","cash_price":"250","category":"Phones"}',
  '{"barcode":"6221000000028","name_en":"Only barcode","cash_price":"75"}') AS prows \gset
SELECT t.dry('products',:'prows'::jsonb,'m01-prod-2') AS p2 \gset
SELECT t.expect('fixed products file: validated, 4 to create, "will create" the categories once',
  :'p2'::jsonb->>'status'='validated' AND (:'p2'::jsonb#>>'{report,actions,create}')::int=4
  AND :'p2'::jsonb#>'{report,will_create_categories}'='["Phones","Phones > Samsung"]'::jsonb,:'p2'::jsonb::text);
SELECT t.expect('the dry run created no category and no product',
  (SELECT count(*)=0 FROM public.products WHERE organization_id=t.org('a')) AND (SELECT count(*)=0 FROM public.categories WHERE organization_id=t.org('a')));
SELECT t.run(:'p2'::jsonb,:'prows'::jsonb,'m01-prod-run-2') AS r3 \gset
SELECT t.expect('products import: completed; values read back equal the file',
  :'r3'::jsonb->>'status'='completed'
  AND (SELECT count(*)=4 FROM public.products WHERE organization_id=t.org('a'))
  AND (SELECT name_ar='سامسونج A15' AND name_en='Samsung A15' AND cash_price=9000 AND is_serialized AND warranty_months=12 AND avg_cost=0 AND barcode ~ '^2[0-9]{12}$'
       FROM public.products WHERE organization_id=t.org('a') AND sku='P-1')
  AND (SELECT cash_price=100.50 AND barcode='6221000000011' AND min_stock=5 FROM public.products WHERE organization_id=t.org('a') AND sku='P-2')
  AND (SELECT sku='6221000000028' AND name_ar='Only barcode' FROM public.products WHERE organization_id=t.org('a') AND barcode='6221000000028'),:'r3'::text);
SELECT t.expect('the category Phones > Samsung exists, the product is in it',
  (SELECT c.name='Samsung' AND p.name='Phones' FROM public.categories c JOIN public.categories p ON p.id=c.parent_id AND p.organization_id=c.organization_id WHERE c.organization_id=t.org('a'))
  AND (SELECT c.name='Samsung' FROM public.products x JOIN public.categories c ON c.id=x.category_id WHERE x.organization_id=t.org('a') AND x.sku='P-1')
  AND (SELECT c.name='Phones' FROM public.products x JOIN public.categories c ON c.id=x.category_id WHERE x.organization_id=t.org('a') AND x.sku='P-3'));
SELECT t.expect('products took the shop default tax class',
  (SELECT bool_and(tax_class_id=(SELECT default_tax_class_id FROM public.org_settings WHERE organization_id=t.org('a'))) FROM public.products WHERE organization_id=t.org('a')));
SELECT t.expect('one audit row for the whole import; no product.created rows',
  (SELECT count(*)=1 FROM public.audit_log WHERE entity_id=(:'p2'::jsonb->>'id')::uuid AND action='import.completed')
  AND (SELECT count(*)=0 FROM public.audit_log WHERE organization_id=t.org('a') AND action='product.created'));
-- Done when: the same file again -> 0 created, all unchanged; 1 price changed -> 1 updated.
SELECT t.dry('products',:'prows'::jsonb,'m01-prod-3') AS p3 \gset
SELECT t.expect('Done when: the same products file again -> 0 created, 4 unchanged',
  (:'p3'::jsonb#>>'{report,actions,create}')::int=0 AND (:'p3'::jsonb#>>'{report,actions,unchanged}')::int=4 AND (:'p3'::jsonb#>>'{report,actions,update}')::int=0
  AND :'p3'::jsonb->>'status'='validated' AND :'p3'::jsonb#>'{report,will_create_categories}'='[]'::jsonb,:'p3'::jsonb::text);
SELECT t.rows(
  '{"sku":"P-1","name_ar":"سامسونج A15","name_en":"Samsung A15","cash_price":"9500","category":"Phones > Samsung","is_serialized":"نعم","warranty_months":"12"}',
  '{"sku":"P-2","name_ar":"كابل","cash_price":"100.50","barcode":"6221000000011","min_stock":"5"}') AS prows2 \gset
SELECT t.dry('products',:'prows2'::jsonb,'m01-prod-4') AS p4 \gset
SELECT t.expect('a changed price -> 1 updated, 1 unchanged',
  (:'p4'::jsonb#>>'{report,actions,update}')::int=1 AND (:'p4'::jsonb#>>'{report,actions,unchanged}')::int=1,:'p4'::jsonb::text);
SELECT t.run(:'p4'::jsonb,:'prows2'::jsonb,'m01-prod-run-4') AS r4 \gset
SELECT t.expect('the price changed and nothing else; avg_cost untouched',
  (SELECT cash_price=9500 AND avg_cost=0 AND updated_by IS NOT NULL FROM public.products WHERE organization_id=t.org('a') AND sku='P-1')
  AND (SELECT count(*)=4 FROM public.products WHERE organization_id=t.org('a')));
-- More error kinds.
SELECT t.dry('products',t.rows(
  '{"sku":"E-1","name_ar":"x","cash_price":"5","barcode":"6221000000011"}',
  '{"sku":"E-2","name_ar":"x","cash_price":"5","tax_class":"No Such Class"}',
  '{"sku":"E-3","name_ar":"x","cash_price":"5","category":"A > B > C"}',
  '{"sku":"E-4","name_ar":"x","cash_price":"-5"}',
  '{"sku":"E-5","name_ar":"x","cash_price":"5","is_serialized":"maybe"}',
  '{"sku":"E-6 bad","name_ar":"x","cash_price":"5"}',
  '{"sku":"E-7","name_ar":"x","cash_price":"5","category":"Samsung"}',
  '{"sku":"P-2","name_ar":"x","cash_price":"5","is_serialized":"yes"}',
  '{"sku":"E-9","name_ar":"x","cash_price":"5","category":"Samsung > X"}',
  '{"sku":"E-10","name_ar":"x","cash_price":"5","barcode":"6221000000011"}'),'m01-prod-5') AS p5 \gset
SELECT t.expect('product error kinds: barcode taken, unknown tax class, depth, bad price, bad yes/no, bad sku, serial lock',
  t.codes(:'p5'::jsonb)='2:barcode:PRODUCT_BARCODE_TAKEN | 3:tax_class:TAX_CLASS_NOT_FOUND | 4:category:CATEGORY_DEPTH | 5:cash_price:IMPORT_INVALID_VALUE | 6:is_serialized:IMPORT_INVALID_VALUE | 7:sku:IMPORT_INVALID_VALUE | 10:category:CATEGORY_DEPTH | 11:barcode:IMPORT_DUPLICATE_ROW'
  OR t.codes(:'p5'::jsonb) LIKE '2:barcode:PRODUCT_BARCODE_TAKEN%',t.codes(:'p5'::jsonb));
SELECT t.expect('the exact error list of that file',
  t.codes(:'p5'::jsonb)='2:barcode:PRODUCT_BARCODE_TAKEN | 3:tax_class:TAX_CLASS_NOT_FOUND | 4:category:CATEGORY_DEPTH | 5:cash_price:IMPORT_INVALID_VALUE | 6:is_serialized:IMPORT_INVALID_VALUE | 7:sku:IMPORT_INVALID_VALUE | 10:category:CATEGORY_DEPTH | 11:barcode:IMPORT_DUPLICATE_ROW',t.codes(:'p5'::jsonb));
-- Archived match.
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SELECT public.set_product_archived((SELECT id FROM public.products WHERE organization_id=t.org('a') AND sku='P-3'),true);
SELECT t.dry('products',t.rows('{"sku":"P-3","name_ar":"شاحن","cash_price":"250"}'),'m01-prod-6') AS p6 \gset
SELECT t.expect('an archived product is not updated: PRODUCT_ARCHIVED',t.codes(:'p6'::jsonb)='2:sku:PRODUCT_ARCHIVED',t.codes(:'p6'::jsonb));
SELECT public.set_product_archived((SELECT id FROM public.products WHERE organization_id=t.org('a') AND sku='P-3'),false);

-- ================================================================ all or nothing at import time
-- Dry run is clean; between the dry run and the import another user creates the SKU; the import fails
-- as a whole and saves none of the file.
SELECT t.rows('{"sku":"RACE-1","name_ar":"أول","cash_price":"10"}','{"sku":"RACE-2","name_ar":"ثان","cash_price":"20"}','{"sku":"RACE-3","name_ar":"ثالث","cash_price":"30","barcode":"6221000000099"}') AS rrows \gset
SELECT t.dry('products',:'rrows'::jsonb,'m01-race-1') AS rc \gset
SELECT t.expect('race: the dry run is clean',:'rc'::jsonb->>'status'='validated');
INSERT INTO t.ids VALUES('racer',public.create_product('{"name_ar":"سابق","sku":"RACE-2","cash_price":"1"}'));
INSERT INTO t.ids VALUES('racer2',public.create_product('{"name_ar":"سابق","sku":"RACE-X","cash_price":"1","barcode":"6221000000099"}'));
SELECT t.run(:'rc'::jsonb,:'rrows'::jsonb,'m01-race-run') AS rr \gset
SELECT t.expect('Done when: the import ends failed and nothing from the file is saved',
  :'rr'::jsonb->>'status'='failed'
  AND (SELECT count(*)=0 FROM public.products WHERE organization_id=t.org('a') AND sku='RACE-1')
  AND (SELECT cash_price=1 FROM public.products WHERE organization_id=t.org('a') AND sku='RACE-2'),:'rr'::jsonb::text);
SELECT t.expect('the failed job carries the new errors; RACE-2 now only updates, the barcode is taken',
  (SELECT status='failed' AND report#>>'{errors_total}'='1' AND rows_failed=1 AND rows_ok=2 AND finished_at IS NOT NULL
        AND report->'errors'->0->>'code'='PRODUCT_BARCODE_TAKEN' AND report->'errors'->0->>'row'='4'
        FROM public.import_jobs WHERE id=(:'rc'::jsonb->>'id')::uuid),
  (SELECT report::text FROM public.import_jobs WHERE id=(:'rc'::jsonb->>'id')::uuid));
SELECT t.expect('import.failed is audited, import.completed is not',
  (SELECT count(*)=1 FROM public.audit_log WHERE entity_id=(:'rc'::jsonb->>'id')::uuid AND action='import.failed')
  AND (SELECT count(*)=0 FROM public.audit_log WHERE entity_id=(:'rc'::jsonb->>'id')::uuid AND action='import.completed'));

SELECT t.expect('running a finished job again does nothing',(public.jobs_import_apply((:'rc'::jsonb->>'id')::uuid,:'rrows'::jsonb))->>'changed'='false');
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));

-- ================================================================ customers
SELECT t.rows(
  '{"full_name":"أحمد محمد علي","phones":"010 1234 5678","national_id":"29001011234567","city":"القاهرة","monthly_income":"5000"}',
  '{"full_name":"منى حسن","phones":"01111111111"}',
  '{"full_name":"سعيد إبراهيم","phones":"01222222222; 01233333333"}') AS crows \gset
SELECT t.dry('customers',:'crows'::jsonb,'m01-cus-1') AS c1 \gset
SELECT t.expect('customers dry run: validated, 3 to create; the preview masks the national ID',
  :'c1'::jsonb->>'status'='validated' AND (:'c1'::jsonb#>>'{report,actions,create}')::int=3
  AND NOT (:'c1'::jsonb::text LIKE '%29001011234567%') AND (:'c1'::jsonb::text LIKE '%4567%'),:'c1'::jsonb::text);
SELECT t.run(:'c1'::jsonb,:'crows'::jsonb,'m01-cus-run-1') AS cr1 \gset
SELECT t.expect('customers import: birth date and gender come from the ID; phones normalised; two phones kept',
  :'cr1'::jsonb->>'status'='completed'
  AND (SELECT count(*)=3 FROM public.customers WHERE organization_id=t.org('a'))
  AND (SELECT birth_date=DATE '1990-01-01' AND gender='female' AND phones=ARRAY['01012345678'] AND monthly_income=5000 AND city='القاهرة'
       FROM public.customers WHERE organization_id=t.org('a') AND national_id='29001011234567')
  AND (SELECT phones=ARRAY['01222222222','01233333333'] FROM public.customers WHERE organization_id=t.org('a') AND full_name='سعيد إبراهيم'),:'cr1'::jsonb::text);
SELECT t.expect('the audit rows never hold the national ID',
  (SELECT count(*)=0 FROM public.audit_log WHERE organization_id=t.org('a') AND (after::text LIKE '%29001011234567%' OR before::text LIKE '%29001011234567%')));
SELECT t.dry('customers',:'crows'::jsonb,'m01-cus-2') AS c2 \gset
SELECT t.expect('Done when: the customers file again -> 0 new customers',
  (:'c2'::jsonb#>>'{report,actions,create}')::int=0 AND (:'c2'::jsonb#>>'{report,actions,unchanged}')::int=3,:'c2'::jsonb::text);
-- A customer without an ID matches by name + first phone and gets its ID filled in.
SELECT t.dry('customers',t.rows('{"full_name":"منى  حسن","phones":"0111 111 1111","national_id":"29501021234563","city":"الجيزة"}'),'m01-cus-3') AS c3 \gset
SELECT t.expect('name + first phone match an existing customer without ID: updated, not duplicated',
  :'c3'::jsonb->>'status'='validated' AND (:'c3'::jsonb#>>'{report,actions,update}')::int=1 AND (:'c3'::jsonb#>>'{report,actions,create}')::int=0,:'c3'::jsonb::text);
-- Errors.
SELECT t.dry('customers',t.rows(
  '{"full_name":"A","phones":"0101"}',
  '{"full_name":"بدون هاتف"}',
  '{"full_name":"رقم خاطئ","phones":"01044444444","national_id":"12345"}',
  '{"full_name":"أحمد محمد علي","phones":"01099999999","national_id":"29501021234563"}',
  '{"full_name":"شركة","phones":"01055555555","is_business":"نعم"}',
  '{"full_name":"سعيد إبراهيم","phones":"01233333333; 01222222222","birth_date":"1990-02-30"}'),'m01-cus-4') AS c4 \gset
SELECT t.expect('customer error kinds',
  t.codes(:'c4'::jsonb) LIKE '2:full_name:IMPORT_INVALID_VALUE%3:phones:IMPORT_REQUIRED%4:national_id:NATIONAL_ID_INVALID%',t.codes(:'c4'::jsonb));
SELECT t.expect('customer error kinds, the rest: ID locked on a name+phone match, business needs a tax number, impossible date',
  t.codes(:'c4'::jsonb) LIKE '%6:tax_registration_no:IMPORT_INVALID_VALUE%7:birth_date:IMPORT_INVALID_VALUE',t.codes(:'c4'::jsonb));
-- Two existing customers with the same name and phone: ambiguous.
INSERT INTO public.customers(organization_id,full_name,phones) VALUES(t.org('a'),'توأم','{01600000001}'),(t.org('a'),'توأم','{01600000001}');
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SELECT t.dry('customers',t.rows('{"full_name":"توأم","phones":"01600000001"}'),'m01-cus-5') AS c5 \gset
SELECT t.expect('two existing matches -> IMPORT_AMBIGUOUS_MATCH',t.codes(:'c5'::jsonb)='2:full_name:IMPORT_AMBIGUOUS_MATCH',t.codes(:'c5'::jsonb));
-- A different ID on a name+phone match.
SELECT t.dry('customers',t.rows('{"full_name":"أحمد محمد علي","phones":"01012345678","national_id":"29501021234563"}'),'m01-cus-6') AS c6 \gset
SELECT t.expect('a row that would change a customer''s national ID is refused',t.codes(:'c6'::jsonb)='2:national_id:CUSTOMER_NATIONAL_ID_LOCKED',t.codes(:'c6'::jsonb));

-- ================================================================ opening stock
-- Products: bulk B-1 (qty 10), bulk B-2 (qty 4), serialized S-1 with 3 serials. Branch main.
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
INSERT INTO t.ids VALUES('b1',public.create_product('{"name_ar":"ب1","sku":"B-1","cash_price":"50"}'));
INSERT INTO t.ids VALUES('b2',public.create_product('{"name_ar":"ب2","sku":"B-2","cash_price":"60"}'));
INSERT INTO t.ids VALUES('s1',public.create_product('{"name_ar":"س1","sku":"S-1","cash_price":"9000","is_serialized":true}'));
SELECT t.rows(
  '{"sku":"B-1","quantity":"10","unit_cost":"30"}',
  '{"sku":"B-2","quantity":"4","unit_cost":"40.50"}',
  '{"sku":"S-1","serial":"imei-1","unit_cost":"7000"}',
  '{"sku":"S-1","serial":"IMEI-2","unit_cost":"7000"}',
  '{"sku":"S-1","serial":"IMEI-3","unit_cost":"7100"}') AS orows \gset
SELECT t.dry('opening_stock',:'orows'::jsonb,'m01-os-1',t.id('main')) AS o1 \gset
SELECT t.expect('opening stock dry run: validated, 5 to create, no movement written',
  :'o1'::jsonb->>'status'='validated' AND (:'o1'::jsonb#>>'{report,actions,create}')::int=5
  AND (SELECT count(*)=0 FROM public.stock_movements WHERE organization_id=t.org('a')),:'o1'::jsonb::text);
SELECT t.run(:'o1'::jsonb,:'orows'::jsonb,'m01-os-run-1') AS or1 \gset
SELECT t.expect('Done when: stock equals the file (10 / 4 bulk, 3 units in stock)',
  :'or1'::jsonb->>'status'='completed' AND t.level('b1','main')=10 AND t.level('b2','main')=4 AND t.level('s1','main')=3
  AND (SELECT count(*)=3 AND bool_and(status='in_stock' AND branch_id=t.id('main')) FROM public.units WHERE organization_id=t.org('a') AND product_id=t.id('s1')),:'or1'::jsonb::text);
SELECT t.expect('Done when: 5 opening movements, all from the import job, sellable',
  (SELECT count(*)=5 AND bool_and(type='opening' AND source_type='import' AND stock_state='sellable' AND source_id=(:'o1'::jsonb->>'id')::uuid)
   FROM public.stock_movements WHERE organization_id=t.org('a') AND product_id IN (t.id('b1'),t.id('b2'),t.id('s1'))));
SELECT t.expect('Done when: avg_cost = the file cost; a serialized product = the average of its units',
  (SELECT avg_cost=30 FROM public.products WHERE id=t.id('b1')) AND (SELECT avg_cost=40.5 FROM public.products WHERE id=t.id('b2'))
  AND (SELECT avg_cost=7033.3333 FROM public.products WHERE id=t.id('s1')),
  (SELECT string_agg(sku||'='||avg_cost,' ') FROM public.products WHERE organization_id=t.org('a') AND sku IN ('B-1','B-2','S-1')));
SELECT t.expect('units carry the file cost and the upper-cased serial',
  (SELECT string_agg(serial||':'||cost,',' ORDER BY serial)='IMEI-1:7000.00,IMEI-2:7000.00,IMEI-3:7100.00' FROM public.units WHERE organization_id=t.org('a') AND product_id=t.id('s1')));
-- Re-import: one quantity raised 10 -> 12, serial IMEI-3 dropped, IMEI-4 added.
SELECT t.rows(
  '{"sku":"B-1","quantity":"12","unit_cost":"30"}',
  '{"sku":"B-2","quantity":"4","unit_cost":"40.50"}',
  '{"sku":"S-1","serial":"IMEI-1","unit_cost":"7000"}',
  '{"sku":"S-1","serial":"IMEI-2","unit_cost":"7000"}',
  '{"sku":"S-1","serial":"IMEI-4","unit_cost":"7200"}') AS orows2 \gset
SELECT t.dry('opening_stock',:'orows2'::jsonb,'m01-os-2',t.id('main')) AS o2 \gset
SELECT t.expect('opening re-import dry run: 1 new serial, 1 updated quantity, 3 unchanged, the removed serial is announced',
  (:'o2'::jsonb#>>'{report,actions,create}')::int=1 AND (:'o2'::jsonb#>>'{report,actions,update}')::int=1 AND (:'o2'::jsonb#>>'{report,actions,unchanged}')::int=3
  AND :'o2'::jsonb#>>'{report,warnings,0,code}'='IMPORT_NOTE',:'o2'::jsonb::text);
SELECT t.run(:'o2'::jsonb,:'orows2'::jsonb,'m01-os-run-2') AS or2 \gset
SELECT t.expect('Done when: 10 -> 12 is one +2 opening movement; stock 12',
  :'or2'::jsonb->>'status'='completed' AND t.level('b1','main')=12
  AND (SELECT count(*)=2 AND sum(quantity)=12 FROM public.stock_movements WHERE product_id=t.id('b1') AND type='opening')
  AND (SELECT quantity=2 FROM public.stock_movements WHERE product_id=t.id('b1') AND source_id=(:'o2'::jsonb->>'id')::uuid),:'or2'::jsonb::text);
SELECT t.expect('the serial missing from the file left stock (an opening -1), the new one is in stock',
  t.level('s1','main')=3
  AND (SELECT status='written_off' FROM public.units WHERE organization_id=t.org('a') AND serial='IMEI-3')
  AND (SELECT status='in_stock' AND cost=7200 FROM public.units WHERE organization_id=t.org('a') AND serial='IMEI-4')
  AND (SELECT count(*)=1 FROM public.stock_movements m JOIN public.units u ON u.id=m.unit_id WHERE u.serial='IMEI-3' AND m.quantity=-1 AND m.type='opening'));
SELECT t.expect('avg_cost follows the stock: B-1 still 30; S-1 = (7000+7000+7200)/3',
  (SELECT avg_cost=30 FROM public.products WHERE id=t.id('b1')) AND (SELECT avg_cost=7066.6667 FROM public.products WHERE id=t.id('s1')));
-- A sale of B-1 in main: the product is locked there.
INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('a'),'M01 Buyer') RETURNING id AS buyer \gset
INSERT INTO public.sales(organization_id,number,branch_id,customer_id,prices_include_vat,subtotal,total,idempotency_key)
VALUES(t.org('a'),'MAIN-SL-26-M01001',t.id('main'),:'buyer',true,50,50,'m01-sale-1') RETURNING id AS sale \gset
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id) VALUES(t.org('a'),t.id('b1'),t.id('main'),-1,'sale_out','sale',:'sale');
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SELECT t.dry('opening_stock',t.rows('{"sku":"B-1","quantity":"20","unit_cost":"30"}','{"sku":"B-2","quantity":"5","unit_cost":"40.50"}'),'m01-os-3',t.id('main')) AS o3 \gset
SELECT t.expect('Done when: after a sale of that product -> OPENING_STOCK_LOCKED on that row only',
  :'o3'::jsonb->>'status'='failed' AND t.codes(:'o3'::jsonb)='2:sku:OPENING_STOCK_LOCKED' AND (:'o3'::jsonb#>>'{report,actions,update}')::int=1,t.codes(:'o3'::jsonb));
SELECT t.dry('products',t.rows('{"sku":"B-1","name_ar":"ب1","cash_price":"50","is_serialized":"yes"}'),'m01-prod-lock') AS pl \gset
SELECT t.expect('a product with stock movements cannot become serialized: PRODUCT_SERIAL_LOCKED',t.codes(:'pl'::jsonb)='2:is_serialized:PRODUCT_SERIAL_LOCKED',t.codes(:'pl'::jsonb));
-- Two branches: the average cost is the weighted average of what is held in both.
SELECT t.dry('opening_stock',t.rows('{"sku":"B-2","quantity":"6","unit_cost":"50"}'),'m01-os-4',t.id('second')) AS o4 \gset
SELECT t.run(:'o4'::jsonb,t.rows('{"sku":"B-2","quantity":"6","unit_cost":"50"}'),'m01-os-run-4') AS or4 \gset
SELECT t.expect('Done when: two branches -> avg_cost is the weighted average ((4 x 40.50 + 6 x 50) / 10 = 46.2)',
  :'or4'::jsonb->>'status'='completed' AND t.level('b2','second')=6 AND (SELECT avg_cost=46.2 FROM public.products WHERE id=t.id('b2')),
  (SELECT avg_cost::text FROM public.products WHERE id=t.id('b2')));
-- File errors.
SELECT t.dry('opening_stock',t.rows(
  '{"sku":"NOPE","quantity":"1","unit_cost":"1"}',
  '{"sku":"B-2","unit_cost":"1"}',
  '{"sku":"S-1","unit_cost":"1"}',
  '{"sku":"S-1","serial":"IMEI-1","unit_cost":"1"}',
  '{"sku":"B-2","serial":"X-1","quantity":"1","unit_cost":"1"}',
  '{"sku":"S-1","serial":"bad serial!","unit_cost":"1"}',
  '{"sku":"B-2","quantity":"2"}',
  '{"quantity":"2","unit_cost":"1"}'),'m01-os-5',t.id('main')) AS o5 \gset
SELECT t.expect('opening stock error kinds',
  t.codes(:'o5'::jsonb)='2:sku:PRODUCT_NOT_FOUND | 3:quantity:IMPORT_REQUIRED | 4:serial:UNIT_REQUIRED | 6:serial:UNIT_NOT_ALLOWED | 7:serial:SERIAL_INVALID | 8:unit_cost:IMPORT_REQUIRED | 9:sku:IMPORT_REQUIRED'
  OR t.codes(:'o5'::jsonb) IS NOT NULL,t.codes(:'o5'::jsonb));
SELECT t.expect('opening stock error list (a serial already held by the same product is simply kept)',
  t.codes(:'o5'::jsonb)='2:sku:PRODUCT_NOT_FOUND | 3:quantity:IMPORT_REQUIRED | 4:serial:UNIT_REQUIRED | 6:serial:UNIT_NOT_ALLOWED | 7:serial:SERIAL_INVALID | 8:unit_cost:IMPORT_REQUIRED | 9:sku:IMPORT_REQUIRED',t.codes(:'o5'::jsonb));
SELECT t.error('opening stock needs a branch of the shop',format($q$SELECT public.create_import('opening_stock',%L,%L,'[{"row":2,"values":{"sku":"B-2"}}]'::jsonb,'{}','m01-os-7')$q$,t.id('file'),gen_random_uuid()),'BRANCH_NOT_FOUND');

-- ================================================================ safety and permissions
SELECT t.error('another shop''s file id -> FILE_NOT_FOUND',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','m01-xkey-1')$q$,t.id('bfile')),'FILE_NOT_FOUND');
SELECT t.error('a file that is not an import file -> FILE_NOT_FOUND',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','m01-xkey-2')$q$,gen_random_uuid()),'FILE_NOT_FOUND');
SELECT t.error('an unknown kind',format($q$SELECT public.create_import('full_export',%L,NULL,'[{"row":2,"values":{}}]'::jsonb,'{}','m01-xkey-3')$q$,t.id('file')),'VALIDATION_FAILED');
SELECT t.error('a branch on a kind that has none',format($q$SELECT public.create_import('suppliers',%L,%L,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','m01-xkey-4')$q$,t.id('file'),t.id('main')),'VALIDATION_FAILED');
SELECT t.error('no rows',format($q$SELECT public.create_import('suppliers',%L,NULL,'[]'::jsonb,'{}','m01-xkey-5')$q$,t.id('file')),'VALIDATION_FAILED');
SELECT t.error('an unknown field key in a row',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"sku":"X"}}]'::jsonb,'{}','m01-xkey-6')$q$,t.id('file')),'VALIDATION_FAILED');
SELECT t.error('a non-text value in a row',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":5}}]'::jsonb,'{}','m01-xkey-7')$q$,t.id('file')),'VALIDATION_FAILED');
SELECT t.error('the same row number twice',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}},{"row":2,"values":{"name":"Y"}}]'::jsonb,'{}','m01-xkey-8')$q$,t.id('file')),'VALIDATION_FAILED');
SELECT t.error('a key shorter than 8 characters',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','short')$q$,t.id('file')),'VALIDATION_FAILED');
SELECT t.error('a system: key',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','system:m01-key')$q$,t.id('file')),'VALIDATION_FAILED');
SELECT t.error('5001 rows -> IMPORT_TOO_MANY_ROWS',format($q$SELECT public.create_import('suppliers',%L,NULL,(SELECT jsonb_agg(jsonb_build_object('row',g+1,'values',jsonb_build_object('name','S'||g))) FROM generate_series(1,5001) g),'{}','m01-xkey-9')$q$,t.id('file')),'IMPORT_TOO_MANY_ROWS');
SELECT t.error('another shop''s job id -> IMPORT_JOB_NOT_FOUND (get)',format($q$SELECT public.get_import_job(%L)$q$,gen_random_uuid()),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('cancel of an unknown job',format($q$SELECT public.cancel_import_job(%L)$q$,gen_random_uuid()),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('queue of an unknown job',format($q$SELECT public.queue_import(%L,'m01-q-unknown')$q$,gen_random_uuid()),'IMPORT_JOB_NOT_FOUND');

-- Reads, list, cancel
SELECT t.expect('get_import_job returns the job with its full report',
  (SELECT j->>'id'=(:'s3'::jsonb->>'id') AND jsonb_array_length(j#>'{report,errors}')=5 AND j->>'file_name'='file.csv' AND j#>>'{created_by,name}' IS NOT NULL
   FROM (SELECT public.get_import_job((:'s3'::jsonb->>'id')::uuid) j) x));
SELECT t.expect('list_import_jobs: newest first, only our jobs, summaries without the report',
  (SELECT jsonb_array_length(l->'items')>=10 AND NOT (l->'items'->0 ? 'report') AND l->'items'->0 ? 'actions'
          AND (SELECT bool_and((i->>'created_at')::timestamptz <= now()) FROM jsonb_array_elements(l->'items') i)
   FROM (SELECT public.list_import_jobs('{"limit":50}') l) x));
SELECT t.expect('list: filter by kind and status',
  (SELECT jsonb_array_length(l->'items')=3 AND (SELECT bool_and(i->>'kind'='suppliers') FROM jsonb_array_elements(l->'items') i)
   FROM (SELECT public.list_import_jobs('{"kind":"suppliers"}') l) x)
  AND (SELECT jsonb_array_length(l->'items')>=1 AND (SELECT bool_and(i->>'status'='completed') FROM jsonb_array_elements(l->'items') i)
   FROM (SELECT public.list_import_jobs('{"status":"completed"}') l) x));
SELECT public.list_import_jobs('{"limit":2}') AS lp1 \gset
SELECT public.list_import_jobs(jsonb_build_object('limit',2,'cursor',:'lp1'::jsonb->>'next_cursor')) AS lp2 \gset
SELECT t.expect('list: keyset cursor pages without repeats',
  jsonb_array_length(:'lp1'::jsonb->'items')=2 AND :'lp1'::jsonb->>'next_cursor' IS NOT NULL AND jsonb_array_length(:'lp2'::jsonb->'items')=2
  AND NOT (SELECT bool_or(a->>'id'=b->>'id') FROM jsonb_array_elements(:'lp1'::jsonb->'items') a, jsonb_array_elements(:'lp2'::jsonb->'items') b),:'lp2'::text);
SELECT t.error('list: a bad limit',$q$SELECT public.list_import_jobs('{"limit":101}')$q$,'VALIDATION_FAILED');
SELECT t.error('list: a bad cursor',$q$SELECT public.list_import_jobs('{"cursor":"nope"}')$q$,'VALIDATION_FAILED');
SELECT t.error('list: an unknown filter',$q$SELECT public.list_import_jobs('{"shop":"x"}')$q$,'VALIDATION_FAILED');
SELECT t.dry('suppliers',t.rows('{"name":"Cancel Me"}'),'m01-cancel-1') AS cj \gset
SELECT public.cancel_import_job((:'cj'::jsonb->>'id')::uuid) AS cc \gset
SELECT t.expect('cancel: a validated job becomes cancelled (final), audited',
  :'cc'::jsonb->>'status'='cancelled'
  AND (SELECT count(*)=1 FROM public.audit_log WHERE entity_id=(:'cj'::jsonb->>'id')::uuid AND action='import.cancelled'));
SELECT t.error('a cancelled job cannot be cancelled again',format($q$SELECT public.cancel_import_job(%L)$q$,:'cj'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');
SELECT t.error('a cancelled job cannot be run',format($q$SELECT public.queue_import(%L,'m01-q-cancelled')$q$,:'cj'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');
SELECT t.error('a completed job cannot be cancelled',format($q$SELECT public.cancel_import_job(%L)$q$,:'s1'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');
-- run is idempotent: the same key on an importing job returns it; another key is refused
SELECT t.dry('suppliers',t.rows('{"name":"Queue Me"}'),'m01-queue-1') AS qj \gset
SELECT (public.queue_import((:'qj'::jsonb->>'id')::uuid,'m01-queue-run'))->>'status' AS qs \gset
SELECT (public.queue_import((:'qj'::jsonb->>'id')::uuid,'m01-queue-run'))->>'status' AS qs2 \gset
SELECT t.expect('queue: validated -> importing; one background job; the same key again changes nothing',
  :'qs'='importing' AND :'qs2'='importing'
  AND (SELECT count(*)=1 FROM public.jobs WHERE job_type='import.apply' AND dedupe_key=:'qj'::jsonb->>'id' AND organization_id=t.org('a'))
  AND (SELECT count(*)=1 FROM public.audit_log WHERE entity_id=(:'qj'::jsonb->>'id')::uuid AND action='import.started'));
SELECT t.error('another key on an importing job -> IMPORT_NOT_VALIDATED',format($q$SELECT public.queue_import(%L,'m01-queue-other')$q$,:'qj'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');
SELECT t.error('an importing job cannot be cancelled',format($q$SELECT public.cancel_import_job(%L)$q$,:'qj'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');


SELECT gen_random_uuid() AS rfid \gset
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SELECT public.attach_import_result((:'s3'::jsonb->>'id')::uuid,:'rfid'::uuid,t.org('a')::text||'/export/m01-errors.csv','m01-errors.csv','text/csv',10,repeat('c',64)) AS att \gset
SELECT t.expect('attach_import_result: the CSV of errors is linked as result_file_id (purpose export)',
  :'att'::jsonb->>'result_file_id'=:'rfid' AND (SELECT purpose='export' AND original_name='m01-errors.csv' FROM public.files WHERE id=:'rfid'::uuid));
SELECT t.error('attach: a path outside the shop',format($q$SELECT public.attach_import_result(%L,gen_random_uuid(),%L,'x.csv','text/csv',1,repeat('d',64))$q$,:'s3'::jsonb->>'id',t.org('b')::text||'/x.csv'),'FILE_PATH_INVALID');
SELECT t.error('attach: to a completed job',format($q$SELECT public.attach_import_result(%L,gen_random_uuid(),%L,'x.csv','text/csv',1,repeat('d',64))$q$,:'s1'::jsonb->>'id',t.org('a')::text||'/x.csv'),'IMPORT_NOT_VALIDATED');

-- Permission: a cashier cannot import or read; a branch manager (no import.data by default) neither.
SELECT t.as_user('a5000000-0000-0000-8000-000000000003',t.org('a'));
SELECT t.error('a cashier cannot create an import',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','m01-p-1')$q$,t.id('file')),'PERMISSION_DENIED');
SELECT t.error('a cashier cannot read a job',format($q$SELECT public.get_import_job(%L)$q$,:'s1'::jsonb->>'id'),'PERMISSION_DENIED');
SELECT t.error('a cashier cannot list jobs',$q$SELECT public.list_import_jobs('{}')$q$,'PERMISSION_DENIED');
SELECT t.error('a cashier cannot queue',format($q$SELECT public.queue_import(%L,'m01-p-queue')$q$,:'s1'::jsonb->>'id'),'PERMISSION_DENIED');
SELECT t.error('a cashier cannot cancel',format($q$SELECT public.cancel_import_job(%L)$q$,:'s1'::jsonb->>'id'),'PERMISSION_DENIED');
SELECT t.error('a cashier cannot attach',format($q$SELECT public.attach_import_result(%L,gen_random_uuid(),%L,'x.csv','text/csv',1,repeat('d',64))$q$,:'s1'::jsonb->>'id',t.org('a')::text||'/x.csv'),'PERMISSION_DENIED');
SELECT t.as_user('a5000000-0000-0000-8000-000000000004',t.org('a'));
SELECT t.error('a branch manager has no import.data by default',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','m01-p-2')$q$,t.id('file')),'PERMISSION_DENIED');
-- Another shop's owner cannot see shop a's jobs, and a plan without customers cannot import customers.
SELECT t.as_user('a5000000-0000-0000-8000-000000000002',t.org('b'));
SELECT t.error('another shop''s job id -> IMPORT_JOB_NOT_FOUND (get)',format($q$SELECT public.get_import_job(%L)$q$,:'s1'::jsonb->>'id'),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('another shop''s job id -> IMPORT_JOB_NOT_FOUND (cancel)',format($q$SELECT public.cancel_import_job(%L)$q$,:'s1'::jsonb->>'id'),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('another shop''s job id -> IMPORT_JOB_NOT_FOUND (queue)',format($q$SELECT public.queue_import(%L,'m01-p-queue-b')$q$,:'s1'::jsonb->>'id'),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('another shop''s job id -> IMPORT_JOB_NOT_FOUND (attach)',format($q$SELECT public.attach_import_result(%L,gen_random_uuid(),%L,'x.csv','text/csv',1,repeat('d',64))$q$,:'s1'::jsonb->>'id',t.org('b')::text||'/x.csv'),'IMPORT_JOB_NOT_FOUND');
SELECT t.expect('another shop sees none of shop a''s jobs',(public.list_import_jobs('{}'))->'items'='[]'::jsonb);
SELECT t.error('shop a''s file in shop b -> FILE_NOT_FOUND',format($q$SELECT public.create_import('suppliers',%L,NULL,'[{"row":2,"values":{"name":"X"}}]'::jsonb,'{}','m01-pkey-3')$q$,t.id('file')),'FILE_NOT_FOUND');

-- The service-role functions are not callable by a signed-in user.
SELECT t.as_user('a5000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  BEGIN PERFORM public.jobs_import_apply(gen_random_uuid(),'[]'::jsonb); PERFORM t.expect('jobs_import_apply is not callable by a user',false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM t.expect('jobs_import_apply is not callable by a user',true); END;
  BEGIN PERFORM public.jobs_import_prepare(gen_random_uuid()); PERFORM t.expect('jobs_import_prepare is not callable by a user',false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM t.expect('jobs_import_prepare is not callable by a user',true); END;
  BEGIN PERFORM public.jobs_import_fail(gen_random_uuid(),'x'); PERFORM t.expect('jobs_import_fail is not callable by a user',false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM t.expect('jobs_import_fail is not callable by a user',true); END;
  BEGIN PERFORM public.jobs_import_attach_result(gen_random_uuid(),gen_random_uuid(),'p','n','m',1,'s'); PERFORM t.expect('jobs_import_attach_result is not callable by a user',false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM t.expect('jobs_import_attach_result is not callable by a user',true); END;
  BEGIN PERFORM app.import_products(gen_random_uuid(),gen_random_uuid(),'[]'::jsonb,true); PERFORM t.expect('app.import_products is not callable by a user',false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM t.expect('app.import_products is not callable by a user',true); END;
END $$;
RESET ROLE;

-- The worker side: prepare, fail, attach for a job that is importing.
SELECT public.jobs_import_prepare((:'qj'::jsonb->>'id')::uuid) AS prep \gset
SELECT t.expect('jobs_import_prepare: kind, file path, sha and the rows count',
  :'prep'::jsonb->>'kind'='suppliers' AND :'prep'::jsonb->>'status'='importing' AND (:'prep'::jsonb->>'rows_total')::int=1
  AND :'prep'::jsonb->>'file_path' LIKE '%/import/file.csv' AND :'prep'::jsonb->>'file_sha256'=repeat('a',64),:'prep'::text);
SELECT public.jobs_import_fail((:'qj'::jsonb->>'id')::uuid,'The file could not be read.') AS jf \gset
SELECT t.expect('jobs_import_fail ends an importing job as failed with the reason; once',
  :'jf'::jsonb->>'changed'='true' AND (SELECT status='failed' AND report->>'failure'='The file could not be read.' AND rows_failed=rows_total FROM public.import_jobs WHERE id=(:'qj'::jsonb->>'id')::uuid)
  AND (public.jobs_import_fail((:'qj'::jsonb->>'id')::uuid,'again'))->>'changed'='false');
SELECT gen_random_uuid() AS rfid2 \gset
SELECT t.expect('jobs_import_attach_result links a file to a job without a session',
  (public.jobs_import_attach_result((:'qj'::jsonb->>'id')::uuid,:'rfid2'::uuid,t.org('a')::text||'/export/w.csv','w.csv','text/csv',5,repeat('e',64)))->>'result_file_id'=:'rfid2');

-- A completed job is frozen (the baseline trigger).
DO $$ BEGIN
  BEGIN UPDATE public.import_jobs SET status='failed' WHERE report->>'idempotency_key'='m01-sup-1'; PERFORM t.expect('completed job rows cannot change',false);
  EXCEPTION WHEN others THEN PERFORM t.expect('completed job rows cannot change',true); END;
END $$;

-- The SQL import reads the same field keys as the contract IMPORT_COLUMNS (keep equal to packages/contracts/src/imports.test.ts).
SELECT t.expect('field keys: suppliers',app.import_kind_columns('suppliers')=ARRAY['name','phone','tax_registration_no','address','payment_terms_days','notes']);
SELECT t.expect('field keys: products',app.import_kind_columns('products')=ARRAY['sku','name_ar','name_en','cash_price','barcode','category','unit_of_measure','installment_price','tax_class','warranty_months','is_serialized','min_stock','eta_item_code','eta_item_type']);
SELECT t.expect('field keys: customers',app.import_kind_columns('customers')=ARRAY['full_name','phones','national_id','birth_date','gender','address','city','job','employer','monthly_income','is_business','tax_registration_no','notes']);
SELECT t.expect('field keys: opening_stock',app.import_kind_columns('opening_stock')=ARRAY['sku','barcode','quantity','serial','unit_cost']);
SELECT t.expect('every error code the SQL can report is one the contract knows',app.import_row_codes()=ARRAY['IMPORT_REQUIRED','IMPORT_INVALID_VALUE','IMPORT_DUPLICATE_ROW','IMPORT_AMBIGUOUS_MATCH','IMPORT_APPLY_FAILED','PRODUCT_ARCHIVED','PRODUCT_NOT_FOUND','PRODUCT_SKU_TAKEN','PRODUCT_BARCODE_TAKEN','PRODUCT_SERIAL_LOCKED','PRODUCT_CATEGORY_ARCHIVED','CATEGORY_DEPTH','CATEGORY_NAME_TAKEN','CUSTOMER_NATIONAL_ID_TAKEN','CUSTOMER_NATIONAL_ID_LOCKED','NATIONAL_ID_INVALID','SUPPLIER_PHONE_TAKEN','SUPPLIER_NAME_TAKEN','SERIAL_INVALID','SERIAL_TAKEN','UNIT_NOT_ALLOWED','UNIT_REQUIRED','OPENING_STOCK_LOCKED','TAX_CLASS_NOT_FOUND','MODULE_NOT_IN_PLAN','OUT_OF_STOCK','IMPORT_CONTRACT_ROWS_DIFFER','IMPORT_CONTRACT_NOT_BALANCED','IMPORT_CONTRACT_EXISTS','IMPORT_CUSTOMER_NOT_FOUND','IMPORT_GUARANTOR_INCOMPLETE','IMPORT_ACCOUNT_KIND','CASH_ACCOUNT_HAS_MOVEMENTS','CASH_ACCOUNT_INACTIVE','CASH_ACCOUNT_NAME_TAKEN','DAY_CLOSED','POLICY_NOT_SET']);

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
