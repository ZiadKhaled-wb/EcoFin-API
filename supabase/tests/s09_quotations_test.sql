\set ON_ERROR_STOP 1
CREATE SCHEMA s09test;
CREATE TABLE s09test.results(name text,ok boolean);
CREATE TABLE s09test.docs(tag text PRIMARY KEY,id uuid);
CREATE SCHEMA t;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT 'd1000000-0000-0000-0000-000000000001'::uuid $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM s09test.err(n,q,c); END $$;
CREATE FUNCTION t.expect(n text,b boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM s09test.check_it(n,b); END $$;
\ir helpers/test4_snapshot.sql
CREATE FUNCTION s09test.check_it(n text,b boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
  IF b IS DISTINCT FROM true THEN RAISE EXCEPTION 'S09 failed: %',n; END IF;
  INSERT INTO s09test.results VALUES(n,b);
END $$;
CREATE FUNCTION s09test.err(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
  BEGIN EXECUTE q; RAISE EXCEPTION 'EXPECTED_ERROR'; EXCEPTION WHEN others THEN
    IF split_part(SQLERRM,':',1)<>c THEN RAISE EXCEPTION 'S09 %: expected %, got %',n,c,SQLERRM; END IF;
  END; INSERT INTO s09test.results VALUES(n,true);
END $$;
CREATE FUNCTION s09test.org() RETURNS uuid LANGUAGE sql AS $$ SELECT 'd1000000-0000-0000-0000-000000000001'::uuid $$;
CREATE FUNCTION s09test.branch() RETURNS uuid LANGUAGE sql AS $$ SELECT 'd2000000-0000-0000-0000-000000000011'::uuid $$;
CREATE FUNCTION s09test.id(t text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM s09test.docs WHERE tag=t $$;
CREATE FUNCTION s09test.lines() RETURNS jsonb LANGUAGE sql AS $$ SELECT '[{"description":"Made to order","custom_notes":"Fabric A","quantity":2,"unit_price":"114.00","discount_amount":"0"}]'::jsonb $$;
CREATE FUNCTION s09test.make(t text) RETURNS uuid LANGUAGE plpgsql AS $$ DECLARE j jsonb; BEGIN
  j:=public.create_quotation(s09test.branch(),s09test.id('customer'),NULL,'Test',s09test.lines(),'s09-test-'||t);
  INSERT INTO s09test.docs VALUES(t,(j->>'id')::uuid); RETURN (j->>'id')::uuid;
END $$;
GRANT USAGE ON SCHEMA s09test TO authenticated,service_role;
GRANT ALL ON ALL TABLES IN SCHEMA s09test TO authenticated,service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA s09test TO authenticated,service_role;
INSERT INTO public.customers(organization_id,full_name,phones) VALUES(s09test.org(),'S09 customer',ARRAY['01012345678']) RETURNING id \gset customer_
INSERT INTO s09test.docs VALUES('customer',:'customer_id');
INSERT INTO public.products(organization_id,name_ar,sku,cash_price,tax_class_id)
 SELECT s09test.org(),'S09 product','S09-TEST',114,default_tax_class_id FROM public.org_settings WHERE organization_id=s09test.org() RETURNING id \gset product_
INSERT INTO s09test.docs VALUES('product',:'product_id');
CREATE TABLE s09test.footprint AS SELECT
  (SELECT count(*) FROM public.stock_movements) stock,
  (SELECT count(*) FROM public.stock_levels) levels,
  (SELECT count(*) FROM public.cash_movements) cash,
  (SELECT sum(balance) FROM public.cash_balances) balance;
CREATE TABLE s09test.money_before AS SELECT jsonb_object_agg(key,value) snapshot FROM jsonb_each(t.snapshot(s09test.org())) WHERE key IN('stock_movements','stock_levels','cash_movements','cash_balances','store_credit_movements','store_credit_balances','payments','payment_allocations','units');
SELECT set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000011',true),set_config('request.headers','{"x-org-id":"d1000000-0000-0000-0000-000000000001"}',true);
SET LOCAL ROLE authenticated;
SELECT s09test.make('main');
SELECT s09test.check_it('Q6 positive integer quantity range',public.create_quotation(s09test.branch(),NULL,NULL,NULL,'[{"description":"Integer range","quantity":2147483647,"unit_price":"0"}]','s09-integer-range')->>'id' IS NOT NULL);
SELECT public.create_quotation(s09test.branch(),s09test.id('customer'),NULL,NULL,s09test.lines()||jsonb_build_array(jsonb_build_object('product_id',s09test.id('product'),'quantity',1,'unit_price','114')),'s09-two-kinds') \gset pair_
SELECT s09test.check_it('Q1 product and custom numbered lines',(SELECT jsonb_array_length(q->'lines')=2 AND q->'lines'->1->>'line_no'='2' AND q->>'subtotal'='342.00' AND q->'lines'->1->>'description'='S09 product' FROM (SELECT public.get_quotation((:'pair_create_quotation'::jsonb->>'id')::uuid) q) x));
SELECT s09test.check_it('Q1 draft, numbering, snapshots, totals',
  (SELECT q->>'status'='draft' AND q->>'number' LIKE '%-QT-%' AND q->>'prices_include_vat' IS NOT NULL
    AND (q->>'total')::numeric=(q->>'subtotal')::numeric-(q->>'discount_total')::numeric+CASE WHEN (q->>'prices_include_vat')::boolean THEN 0 ELSE (q->>'tax_total')::numeric END
    AND (q->'lines'->0->>'line_no')::integer=1 FROM (SELECT public.get_quotation(s09test.id('main')) q) x));
SELECT s09test.check_it('Q3 replay',public.create_quotation(s09test.branch(),NULL,NULL,NULL,s09test.lines(),'s09-test-main')->>'id'=s09test.id('main')::text);
SELECT s09test.err('Q6 zero lines','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,''[]'',''s09-zero-lines'')','QUOTATION_LINES_INVALID');
SELECT s09test.err('Q6 custom description','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,''[{"quantity":1,"unit_price":"1"}]'',''s09-no-description'')','QUOTATION_LINES_INVALID');
SELECT s09test.err('Q6 description must be text','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,''[{"description":{},"quantity":1,"unit_price":"1"}]'',''s09-object-description'')','QUOTATION_LINES_INVALID');
SELECT s09test.err('Q6 notes must be text','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,''[{"description":"Custom","custom_notes":[],"quantity":1,"unit_price":"1"}]'',''s09-object-notes'')','QUOTATION_LINES_INVALID');
SELECT s09test.err('Q6 201 lines',format('SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,%L,''s09-many-lines'')',(SELECT jsonb_agg(s09test.lines()->0) FROM generate_series(1,201))),'QUOTATION_LINES_INVALID');
SELECT s09test.err('Q7 past validity','SELECT public.create_quotation(s09test.branch(),NULL,current_date-1,NULL,s09test.lines(),''s09-past-validity'')','QUOTATION_VALIDITY_INVALID');
SELECT s09test.err('Q7 181 days','SELECT public.create_quotation(s09test.branch(),NULL,current_date+181,NULL,s09test.lines(),''s09-long-validity'')','QUOTATION_VALIDITY_INVALID');
SELECT s09test.err('Q8 stale','SELECT public.update_quotation_draft(s09test.id(''main''),NULL,NULL,NULL,s09test.lines(),''2000-01-01'')','QUOTATION_STALE');
SELECT public.update_quotation_draft(s09test.id('main'),s09test.id('customer'),NULL,'Updated',s09test.lines(),(public.get_quotation(s09test.id('main'))->>'updated_at')::timestamptz);
SELECT s09test.check_it('Q8 replaces lines',jsonb_array_length(public.get_quotation(s09test.id('main'))->'lines')=1);
SELECT s09test.err('Q9 draft accept','SELECT public.accept_quotation(s09test.id(''main''))','QUOTATION_BAD_TRANSITION');
SELECT public.send_quotation(s09test.id('main'));
SELECT s09test.err('Q14 second send serialized','SELECT public.send_quotation(s09test.id(''main''))','QUOTATION_BAD_TRANSITION');
SELECT s09test.err('Q8 sent edit','SELECT public.update_quotation_draft(s09test.id(''main''),NULL,NULL,NULL,s09test.lines(),now())','QUOTATION_NOT_DRAFT');
SELECT public.accept_quotation(s09test.id('main'));
SELECT s09test.err('Q9 accepted send','SELECT public.send_quotation(s09test.id(''main''))','QUOTATION_BAD_TRANSITION');
SELECT s09test.make('reject'); SELECT public.send_quotation(s09test.id('reject'));
SELECT s09test.err('Q10 reject reason','SELECT public.reject_quotation(s09test.id(''reject''),NULL)','REASON_REQUIRED');
SELECT public.reject_quotation(s09test.id('reject'),'Customer declined');
SELECT s09test.err('Q9 rejected accept','SELECT public.accept_quotation(s09test.id(''reject''))','QUOTATION_BAD_TRANSITION');
SELECT s09test.make('cancel'); SELECT public.cancel_quotation(s09test.id('cancel'),'No longer needed');
SELECT s09test.make('sent-cancel'); SELECT public.send_quotation(s09test.id('sent-cancel')); SELECT public.cancel_quotation(s09test.id('sent-cancel'),'No longer needed');
SELECT s09test.make('no-customer');
SELECT public.update_quotation_draft(s09test.id('no-customer'),NULL,NULL,NULL,s09test.lines(),(public.get_quotation(s09test.id('no-customer'))->>'updated_at')::timestamptz);
SELECT s09test.err('Q10 customer required','SELECT public.send_quotation(s09test.id(''no-customer''))','QUOTATION_CUSTOMER_REQUIRED');
SELECT s09test.make('expired'); SELECT public.send_quotation(s09test.id('expired'));
SELECT s09test.err('Q11 expiry service only','SELECT public.expire_quotations()','permission denied for function expire_quotations');
SELECT s09test.err('Q13 no direct writes','UPDATE public.quotations SET notes=''attack''','permission denied for table quotations');
SELECT s09test.err('Q13 no direct header insert','INSERT INTO public.quotations DEFAULT VALUES','permission denied for table quotations');
SELECT s09test.err('Q13 no direct header delete','DELETE FROM public.quotations','permission denied for table quotations');
SELECT s09test.err('Q13 no direct line insert','INSERT INTO public.quotation_lines DEFAULT VALUES','permission denied for table quotation_lines');
SELECT s09test.err('Q13 no direct line update','UPDATE public.quotation_lines SET quantity=3','permission denied for table quotation_lines');
SELECT s09test.err('Q13 no direct line delete','DELETE FROM public.quotation_lines','permission denied for table quotation_lines');
SELECT s09test.err('Q13 branch denied','SELECT public.create_quotation(''d2000000-0000-0000-0000-000000000021'',NULL,NULL,NULL,s09test.lines(),''s09-foreign-branch'')','BRANCH_DENIED');
RESET ROLE;
UPDATE public.quotations SET valid_until=current_date-1 WHERE id=s09test.id('expired');
SET LOCAL ROLE authenticated;
SELECT s09test.check_it('Q11 get expiry',public.get_quotation(s09test.id('expired'))->>'effective_status'='expired');
SELECT s09test.check_it('Q11 list expiry',EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_quotations('expired')->'items') q WHERE q->>'id'=s09test.id('expired')::text));
SELECT s09test.err('Q11 no acceptance','SELECT public.accept_quotation(s09test.id(''expired''))','QUOTATION_EXPIRED');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT public.expire_quotations();
SELECT s09test.check_it('Q11 stored expiry',(SELECT status='expired' FROM public.quotations WHERE id=s09test.id('expired')));
DO $$ DECLARE s text; BEGIN FOREACH s IN ARRAY ARRAY['main','reject','cancel','expired'] LOOP
  PERFORM s09test.err('Q12 frozen header '||s,format('UPDATE public.quotations SET notes=''changed'' WHERE id=%L',s09test.id(s)),'DOCUMENT_FINAL');
  PERFORM s09test.err('Q12 frozen update '||s,format('UPDATE public.quotation_lines SET quantity=3 WHERE quotation_id=%L',s09test.id(s)),'DOCUMENT_FINAL');
  PERFORM s09test.err('Q12 frozen delete '||s,format('DELETE FROM public.quotation_lines WHERE quotation_id=%L',s09test.id(s)),'DOCUMENT_FINAL');
  PERFORM s09test.err('Q12 frozen insert '||s,format('INSERT INTO public.quotation_lines(organization_id,quotation_id,line_no,description,quantity,unit_price,tax_class_id,tax_rate,line_total) SELECT organization_id,quotation_id,2,''Extra'',1,0,tax_class_id,tax_rate,0 FROM public.quotation_lines WHERE quotation_id=%L',s09test.id(s)),'DOCUMENT_FINAL');
END LOOP; END $$;
RESET ROLE;
SELECT s09test.check_it('Q15 audits',(SELECT count(DISTINCT action)=7 FROM public.audit_log WHERE entity_id IN(SELECT id FROM s09test.docs) AND action IN('quotation.created','quotation.updated','quotation.sent','quotation.accepted','quotation.rejected','quotation.cancelled','quotation.expired')));
SELECT s09test.check_it('Q16 no stock/cash effects',(SELECT stock=(SELECT count(*) FROM public.stock_movements) AND levels=(SELECT count(*) FROM public.stock_levels) AND cash=(SELECT count(*) FROM public.cash_movements) AND balance IS NOT DISTINCT FROM (SELECT sum(balance) FROM public.cash_balances) FROM s09test.footprint));
SELECT s09test.check_it('Q16 TEST4 full balance/unit snapshot',(SELECT snapshot FROM s09test.money_before)=(SELECT jsonb_object_agg(key,value) FROM jsonb_each(t.snapshot(s09test.org())) WHERE key IN('stock_movements','stock_levels','cash_movements','cash_balances','store_credit_movements','store_credit_balances','payments','payment_allocations','units')));
SELECT name,ok FROM s09test.results ORDER BY name;
-- Inclusive/exclusive and zero/exempt variants, checked against the same T01 engine.
UPDATE public.branches SET is_active=false WHERE id=s09test.branch();
SET LOCAL ROLE authenticated;
SELECT s09test.check_it('Q13 historical reads use branch access like S07',public.get_quotation(s09test.id('main'))->>'status'='accepted' AND jsonb_array_length(public.list_quotations(NULL,s09test.branch())->'items')>0);
SELECT s09test.err('Q13 inactive branch refuses creation','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,s09test.lines(),''s09-inactive-branch'')','BRANCH_INACTIVE');
RESET ROLE;
UPDATE public.branches SET is_active=true WHERE id=s09test.branch();
DO $$ DECLARE k text; inc boolean; tax uuid; j jsonb; expected jsonb; BEGIN
  FOREACH k IN ARRAY ARRAY['standard','zero','exempt'] LOOP
    INSERT INTO public.tax_classes(organization_id,name,kind,rate) VALUES(s09test.org(),'S09 '||k,k::public.tax_kind,CASE WHEN k='standard' THEN 14 ELSE 0 END) RETURNING id INTO tax;
    FOREACH inc IN ARRAY ARRAY[true,false] LOOP
      UPDATE public.org_settings SET prices_include_vat=inc,default_tax_class_id=tax WHERE organization_id=s09test.org();
      j:=public.create_quotation(s09test.branch(),NULL,NULL,NULL,s09test.lines(),'s09-tax-'||k||inc::text);
      j:=public.get_quotation((j->>'id')::uuid);
      expected:=app.compute_document_tax(jsonb_build_object('prices_include_vat',inc,'document_discount','0','lines',jsonb_build_array(jsonb_build_object('unit_price','114','quantity',2,'line_discount','0','tax_rate',CASE WHEN k='standard' THEN '14' ELSE '0' END))));
      PERFORM s09test.check_it('Q2 '||k||' inclusive='||inc::text,j->>'total'=expected->>'total' AND j->>'tax_total'=expected->>'tax_total');
    END LOOP;
  END LOOP;
END $$;
-- Direct-database pricing and access checks under the cashier's JWT.
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted)
 VALUES(s09test.org(),'d3000000-0000-0000-0000-000000000012','price.override',false),
 (s09test.org(),'d3000000-0000-0000-0000-000000000012','discount.above_cap',false)
 ON CONFLICT(employee_id,permission_key) DO UPDATE SET granted=excluded.granted;
UPDATE public.org_settings SET discount_caps='{"CASHIER":5}' WHERE organization_id=s09test.org();
SELECT set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000012',true);
SET LOCAL ROLE authenticated;
SELECT s09test.err('Q4 override required',format('SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,%L,''s09-price-denied'')',jsonb_build_array(jsonb_build_object('product_id',s09test.id('product'),'quantity',1,'unit_price','100'))),'PRICE_OVERRIDE_REQUIRED');
SELECT s09test.err('Q5 above cap','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,''[{"description":"Custom","quantity":1,"unit_price":"100","discount_amount":"6"}]'',''s09-cap-denied'')','DISCOUNT_ABOVE_CAP');
SELECT s09test.err('Q5 discount too large','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,''[{"description":"Custom","quantity":1,"unit_price":"100","discount_amount":"101"}]'',''s09-discount-invalid'')','QUOTATION_LINES_INVALID');
RESET ROLE;
UPDATE public.employee_permission_overrides SET granted=true WHERE employee_id='d3000000-0000-0000-0000-000000000012' AND permission_key IN('price.override','discount.above_cap');
SET LOCAL ROLE authenticated;
SELECT s09test.check_it('Q4 override allowed',public.create_quotation(s09test.branch(),NULL,NULL,NULL,jsonb_build_array(jsonb_build_object('product_id',s09test.id('product'),'quantity',1,'unit_price','100')),'s09-price-allowed')->>'id' IS NOT NULL);
SELECT s09test.check_it('Q5 above cap permission',public.create_quotation(s09test.branch(),NULL,NULL,NULL,'[{"description":"Custom","quantity":1,"unit_price":"100","discount_amount":"6"}]','s09-cap-allowed')->>'id' IS NOT NULL);
SELECT s09test.check_it('Q4 custom free price',public.create_quotation(s09test.branch(),NULL,NULL,NULL,'[{"description":"Free","quantity":1,"unit_price":"0"}]','s09-free-custom')->>'id' IS NOT NULL);
RESET ROLE;
UPDATE public.products SET archived_at=now() WHERE id=s09test.id('product');
SET LOCAL ROLE authenticated;
SELECT s09test.err('Q6 archived product',format('SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,%L,''s09-archived'')',jsonb_build_array(jsonb_build_object('product_id',s09test.id('product'),'quantity',1,'unit_price','114'))),'PRODUCT_NOT_FOUND');
RESET ROLE;
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(s09test.org(),'d3000000-0000-0000-0000-000000000012','quotation.manage',false) ON CONFLICT(employee_id,permission_key) DO UPDATE SET granted=false;
SET LOCAL ROLE authenticated;
SELECT s09test.err('Q13 create permission','SELECT public.create_quotation(s09test.branch(),NULL,NULL,NULL,s09test.lines(),''s09-no-permission'')','PERMISSION_DENIED');
SELECT s09test.err('Q13 list permission','SELECT public.list_quotations()','PERMISSION_DENIED');
SELECT s09test.err('Q13 get permission','SELECT public.get_quotation(s09test.id(''main''))','PERMISSION_DENIED');
SELECT s09test.err('Q13 update permission','SELECT public.update_quotation_draft(s09test.id(''main''),NULL,NULL,NULL,s09test.lines(),now())','PERMISSION_DENIED');
SELECT s09test.err('Q13 send permission','SELECT public.send_quotation(s09test.id(''main''))','PERMISSION_DENIED');
SELECT s09test.err('Q13 accept permission','SELECT public.accept_quotation(s09test.id(''main''))','PERMISSION_DENIED');
SELECT s09test.err('Q13 reject permission','SELECT public.reject_quotation(s09test.id(''main''),''Reason'')','PERMISSION_DENIED');
SELECT s09test.err('Q13 cancel permission','SELECT public.cancel_quotation(s09test.id(''main''),''Reason'')','PERMISSION_DENIED');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000021',true),set_config('request.headers','{"x-org-id":"d1000000-0000-0000-0000-000000000002"}',true);
SET LOCAL ROLE authenticated;
SELECT s09test.err('Q13 other shop quote','SELECT public.get_quotation(s09test.id(''main''))','QUOTATION_NOT_FOUND');
SELECT s09test.err('Q13 other shop customer','SELECT public.create_quotation(''d2000000-0000-0000-0000-000000000021'',s09test.id(''customer''),NULL,NULL,s09test.lines(),''s09-foreign-customer'')','CUSTOMER_NOT_FOUND');
SELECT s09test.err('Q13 other shop product',format('SELECT public.create_quotation(''d2000000-0000-0000-0000-000000000021'',NULL,NULL,NULL,%L,''s09-foreign-product'')',jsonb_build_array(jsonb_build_object('product_id',s09test.id('product'),'quantity',1,'unit_price','114'))),'PRODUCT_NOT_FOUND');
SELECT s09test.check_it('Q13 other shop list',NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_quotations()->'items') q WHERE q->>'id'=s09test.id('main')::text));
RESET ROLE;
SELECT count(*) FILTER(WHERE ok) AS passed,count(*) FILTER(WHERE NOT ok) AS failed FROM s09test.results;
