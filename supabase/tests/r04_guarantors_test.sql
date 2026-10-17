\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- The DETAIL of the error a statement raises (NULL when it raises none).
CREATE FUNCTION t.detail(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d=PG_EXCEPTION_DETAIL; END; RETURN d; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- Audit rows of an action whose entity is the one tagged s.
CREATE FUNCTION t.audits(a text,s text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action=a AND entity_id=t.id(s) $$;
-- A valid national ID that is new on every n (century 2, 1990-01-01, Cairo).
CREATE FUNCTION t.nid(n integer) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT '290010101'||lpad(n::text,5,'0') $$;
-- Guarantors of one customer, as "name:relation" sorted by name.
CREATE FUNCTION t.links(c text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(g.full_name||':'||cg.relation,',' ORDER BY g.full_name),'')
  FROM public.customer_guarantors cg JOIN public.guarantors g ON g.id=cg.guarantor_id WHERE cg.customer_id=t.id(c) $$;
-- Seeds a contract of shop a for a customer as the database owner (nothing creates contracts yet: N02),
-- attaches the guarantors, then makes the deferred check run now ("commit time"). A failure raises.
CREATE FUNCTION t.seed_contract(p_tag text,p_customer text,p_financed numeric,p_status text,p_migrated boolean,p_guarantors text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_order uuid; v_contract uuid; v_policy uuid; g text;
BEGIN
  SELECT id INTO v_policy FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1;
  INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,total,idempotency_key)
    VALUES(t.org('a'),'R04-SO-'||p_tag,t.id(p_customer),t.id('main'),false,p_financed,p_financed,'r04-so-'||p_tag) RETURNING id INTO v_order;
  INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,order_id,policy_id,creditor,cash_price,down_payment,financed_amount,markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,status,closed_at,is_migrated,idempotency_key)
    VALUES(t.org('a'),'R04-C-'||p_tag,t.id(p_customer),t.id('main'),v_order,v_policy,'in_house',p_financed,0,p_financed,0,0,p_financed,6,'monthly',current_date+30,
           p_status::public.contract_status,CASE WHEN p_status='active' THEN NULL ELSE now() END,p_migrated,'r04-c-'||p_tag) RETURNING id INTO v_contract;
  FOREACH g IN ARRAY COALESCE(p_guarantors,ARRAY[]::text[]) LOOP
    INSERT INTO public.contract_guarantors(organization_id,contract_id,guarantor_id) VALUES(t.org('a'),v_contract,t.id(g));
  END LOOP;
  INSERT INTO t.ids VALUES('contract-'||p_tag,v_contract);
  SET CONSTRAINTS trg_contracts_guarantors_check IMMEDIATE;
  SET CONSTRAINTS trg_contracts_guarantors_check DEFERRED;
END $$;
-- Reads of guarantors.national_id and customer_id as the database owner (authenticated has no grant on the first).
CREATE FUNCTION t.gnid(p text) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT national_id FROM public.guarantors WHERE id=(SELECT id FROM t.ids WHERE tag=p) $$;
CREATE FUNCTION t.gcust(p text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT customer_id FROM public.guarantors WHERE id=(SELECT id FROM t.ids WHERE tag=p) $$;
CREATE FUNCTION t.nid_exists(p text) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT EXISTS(SELECT 1 FROM public.guarantors WHERE national_id=p) $$;
CREATE FUNCTION t.passes(n text,q text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; PERFORM t.expect(n,true); EXCEPTION WHEN others THEN PERFORM t.expect(n,false,SQLERRM); END; END $$;
-- Attaches guarantors to a seeded contract through the helper N02 will call.
CREATE FUNCTION t.attach(p_contract text,p_guarantors text[]) RETURNS void LANGUAGE sql AS $$
  SELECT app.attach_contract_guarantors(t.org('a'),t.id(p_contract),ARRAY(SELECT t.id(x) FROM unnest(p_guarantors) x)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a, b (retail), c (starter: no customers module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('R04 '||s,'r04-'||s,p,'Owner',s||'r04@example.com',NULL,'Main',h,now()+interval '1 day')
FROM (VALUES('a','retail',repeat('x',64)),('b','retail',repeat('y',64)),('c','starter',repeat('z',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0710000-0000-0000-8000-000000000001','ar04@example.com'),('a0710000-0000-0000-8000-000000000002','br04@example.com'),
  ('a0710000-0000-0000-8000-000000000003','r04cashier@example.com'),('a0710000-0000-0000-8000-000000000004','r04manager@example.com'),
  ('a0710000-0000-0000-8000-000000000005','r04collector@example.com'),('a0710000-0000-0000-8000-000000000006','r04warehouse@example.com'),
  ('a0710000-0000-0000-8000-000000000007','r04editor@example.com'),('a0710000-0000-0000-8000-000000000008','cr04@example.com');
SELECT public.accept_invite(repeat('x',64),'a0710000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a0710000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('z',64),'a0710000-0000-0000-8000-000000000008');
-- Cashier: customer.create (and sale keys), no guarantor.manage. Manager: everything but owner keys.
-- Collector: a read key only. Warehouse: no read key. Editor: a manager whose customer.view_pii was taken away.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES
  (t.org('a'),'a0710000-0000-0000-8000-000000000003','R04 Cashier','CASHIER'),
  (t.org('a'),'a0710000-0000-0000-8000-000000000004','R04 Manager','BRANCH_MANAGER'),
  (t.org('a'),'a0710000-0000-0000-8000-000000000005','R04 Collector','COLLECTOR'),
  (t.org('a'),'a0710000-0000-0000-8000-000000000006','R04 Warehouse','WAREHOUSE');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a0710000-0000-0000-8000-000000000007','R04 Editor','BRANCH_MANAGER') RETURNING id AS editor_id \gset
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),:'editor_id','customer.view_pii',false);
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1;
WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones) VALUES(t.org('b'),'Shop B Early',ARRAY['01200000009']) RETURNING id) INSERT INTO t.ids SELECT 'b-early',id FROM x;

-- ---------------------------------------------------------------- pure helpers
SELECT t.expect('relations: the thirteen of D71',cardinality(app.guarantor_relations())=13 AND 'colleague'=ANY(app.guarantor_relations()) AND 'father'=ANY(app.guarantor_relations()));

-- ---------------------------------------------------------------- create (owner: sees PII)
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'cust-a',(public.create_customer('{"full_name":"Customer A","phones":["01100000001"]}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'cust-b',(public.create_customer('{"full_name":"Customer B","phones":["01100000002"]}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'cust-same',(public.create_customer('{"full_name":"Same Person","phones":["01100000003"],"national_id":"28506152100023"}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'mahmoud',(public.create_guarantor('{"full_name":"  Mahmoud   Hassan ","phone":" +20 100 123 4567 ","national_id":" 2900101-0100015 ","address":" 5 Nile St ","job":" Teacher ","monthly_income":"6000.5"}')->>'id')::uuid;
SELECT t.expect('create: trims, joins spaces, normalises the phone and the ID; birth date and gender come from the ID',
  g->>'full_name'='Mahmoud Hassan' AND g->>'phone'='01001234567' AND g->>'national_id'='29001010100015'
  AND g->>'national_id_masked'='**********0015' AND g->>'birth_date'='1990-01-01' AND g->>'gender'='male'
  AND g->>'address'='5 Nile St' AND g->>'job'='Teacher' AND g->>'monthly_income'='6000.50'
  AND g->'also_customer'='null'::jsonb AND g->'archived_at'='null'::jsonb AND (g->>'id_photos_count')::int=0, g::text)
FROM (SELECT public.get_guarantor(t.id('mahmoud')) g) x;
INSERT INTO t.ids SELECT 'arabic',(public.create_guarantor('{"full_name":"أحمد فاطمة","phone":"٠١٢٢٣٣٣٤٤٤٥","national_id":"٢٨٥٠٦١٥٢١٠٠٠٢٣"}')->>'id')::uuid;
SELECT t.expect('create: Arabic digits are stored as 0-9; a customer with the same ID shows as "also a customer"',
  g->>'phone'='01223334445' AND g->>'national_id'='28506152100023' AND g->>'birth_date'='1985-06-15' AND g->>'gender'='female'
  AND g->'also_customer'=jsonb_build_object('id',t.id('cust-same'),'full_name','Same Person')
  AND t.gcust('arabic')=t.id('cust-same'), g::text)
FROM (SELECT public.get_guarantor(t.id('arabic')) g) x;
SELECT t.expect('create: optional fields default to null',g->'address'='null'::jsonb AND g->'job'='null'::jsonb AND g->'monthly_income'='null'::jsonb,g::text)
FROM (SELECT public.create_guarantor(format('{"full_name":"Bare Minimum","phone":"01000000001","national_id":"%s"}',t.nid(1))::jsonb) g) x;
SELECT t.error('create: no phone',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X1","national_id":"%s"}',t.nid(2))),'VALIDATION_FAILED');
SELECT t.error('create: no national ID','SELECT public.create_guarantor(''{"full_name":"X2","phone":"01000000001"}'')','VALIDATION_FAILED');
SELECT t.error('create: no name',format('SELECT public.create_guarantor(%L)',format('{"phone":"01000000001","national_id":"%s"}',t.nid(3))),'VALIDATION_FAILED');
SELECT t.error('create: a null national ID',format('SELECT public.create_guarantor(%L)','{"full_name":"X3","phone":"01000000001","national_id":null}'),'VALIDATION_FAILED');
SELECT t.error('create: an empty national ID',format('SELECT public.create_guarantor(%L)','{"full_name":"X4","phone":"01000000001","national_id":"  "}'),'VALIDATION_FAILED');
SELECT t.error('create: an ID with century 4','SELECT public.create_guarantor(''{"full_name":"X5","phone":"01000000001","national_id":"49001010100015"}'')','VALIDATION_FAILED');
SELECT t.error('create: an ID born on 30 February','SELECT public.create_guarantor(''{"full_name":"X6","phone":"01000000001","national_id":"29002300100015"}'')','VALIDATION_FAILED');
SELECT t.error('create: an ID of 13 digits','SELECT public.create_guarantor(''{"full_name":"X7","phone":"01000000001","national_id":"2900101010001"}'')','VALIDATION_FAILED');
SELECT t.error('create: an ID born in the future','SELECT public.create_guarantor(''{"full_name":"X8","phone":"01000000001","national_id":"39901010100015"}'')','VALIDATION_FAILED');
SELECT t.error('create: a bad phone',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X9","phone":"12345","national_id":"%s"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: a phone with letters',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X10","phone":"0100ab00001","national_id":"%s"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: phones as a list (one number only)',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X11","phone":["01000000001"],"national_id":"%s"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: a one-letter name',format('SELECT public.create_guarantor(%L)',format('{"full_name":" A ","phone":"01000000001","national_id":"%s"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: a name over 150',format('SELECT public.create_guarantor(%L)',jsonb_build_object('full_name',repeat('n',151),'phone','01000000001','national_id',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: an address over 300',format('SELECT public.create_guarantor(%L)',jsonb_build_object('full_name','X12','phone','01000000001','national_id',t.nid(4),'address',repeat('a',301))),'VALIDATION_FAILED');
SELECT t.error('create: a job over 100',format('SELECT public.create_guarantor(%L)',jsonb_build_object('full_name','X13','phone','01000000001','national_id',t.nid(4),'job',repeat('j',101))),'VALIDATION_FAILED');
SELECT t.error('create: a negative income',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X14","phone":"01000000001","national_id":"%s","monthly_income":"-5"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: an income with three decimals',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X15","phone":"01000000001","national_id":"%s","monthly_income":"100.125"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: an income as a number',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X16","phone":"01000000001","national_id":"%s","monthly_income":8500}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: organization_id in the body',format('SELECT public.create_guarantor(%L)',jsonb_build_object('full_name','X17','phone','01000000001','national_id',t.nid(4),'organization_id',t.org('b'))),'VALIDATION_FAILED');
SELECT t.error('create: customer_id in the body (the link is the way)',format('SELECT public.create_guarantor(%L)',jsonb_build_object('full_name','X18','phone','01000000001','national_id',t.nid(4),'customer_id',t.id('cust-a'))),'VALIDATION_FAILED');
SELECT t.error('create: archived_at in the body',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X19","phone":"01000000001","national_id":"%s","archived_at":"2026-01-01"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: a birth date is not an input',format('SELECT public.create_guarantor(%L)',format('{"full_name":"X20","phone":"01000000001","national_id":"%s","birth_date":"1990-01-01"}',t.nid(4))),'VALIDATION_FAILED');
SELECT t.error('create: a body that is not an object','SELECT public.create_guarantor(''[]'')','VALIDATION_FAILED');
-- Done when: a duplicate national ID is rejected and names the guarantor who has it.
SELECT t.error('create: a national ID another guarantor has (written with dashes and Arabic digits)',
  $q$SELECT public.create_guarantor('{"full_name":"Twin","phone":"01000000002","national_id":"٢-٩٠٠١٠١-٠١-٠٠٠١٥"}')$q$,'GUARANTOR_NATIONAL_ID_TAKEN');
SELECT t.expect('create: the duplicate error names the guarantor who has the ID',
  d::jsonb=jsonb_build_object('guarantor_id',t.id('mahmoud'),'full_name','Mahmoud Hassan'),d)
FROM (SELECT t.detail($q$SELECT public.create_guarantor('{"full_name":"Twin","phone":"01000000002","national_id":"29001010100015"}')$q$) d) x;
SELECT t.expect('create: the same phone may belong to another guarantor',
  public.create_guarantor(format('{"full_name":"Same Phone","phone":"01001234567","national_id":"%s"}',t.nid(5))::jsonb)->>'id' IS NOT NULL);
SELECT t.expect('create: one guarantor.created row; the ID is never in the audit log, only its mask',
  t.audits('guarantor.created','mahmoud')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='guarantor.created' AND entity_id=t.id('mahmoud')
    AND entity_type='guarantor' AND after->>'full_name'='Mahmoud Hassan' AND after->>'national_id_masked'='**********0015' AND NOT after ? 'national_id')
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND (COALESCE(before::text,'')||COALESCE(after::text,'')) LIKE '%29001010100015%'));
RESET ROLE;
SELECT t.expect('create: refused calls wrote no row',(SELECT count(*) FROM public.guarantors WHERE organization_id=t.org('a'))=4,
  (SELECT count(*)::text FROM public.guarantors WHERE organization_id=t.org('a')));
SELECT t.expect('create: created_by and updated_by are the caller',
  (SELECT g.created_by=e.id AND g.updated_by=e.id FROM public.guarantors g JOIN public.employees e ON e.auth_user_id='a0710000-0000-0000-8000-000000000001' WHERE g.id=t.id('mahmoud')));

-- ---------------------------------------------------------------- create with a link (one transaction)
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'linked',(public.create_guarantor(format('{"full_name":"Linked Guarantor","phone":"01000000010","national_id":"%s","link":{"customer_id":"%s","relation":"father"}}',t.nid(10),t.id('cust-a'))::jsonb)->>'id')::uuid;
SELECT t.expect('create with link: the guarantor and the link are written, with two audit rows',
  t.links('cust-a')='Linked Guarantor:father'
  AND t.audits('guarantor.created','linked')=1
  AND (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.guarantor_linked' AND entity_id=t.id('cust-a')
         AND after=jsonb_build_object('guarantor_id',t.id('linked'),'relation','father'))=1);
SELECT t.error('create with link: a customer that does not exist',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Rolled Back","phone":"01000000011","national_id":"%s","link":{"customer_id":"%s","relation":"father"}}',t.nid(11),gen_random_uuid())),'CUSTOMER_NOT_FOUND');
SELECT t.expect('create with link: a bad link rolled the guarantor back too',
  NOT t.nid_exists(t.nid(11)) AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE after->>'full_name'='Rolled Back'));
SELECT t.error('create with link: another shop''s customer is not found',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Rolled Back","phone":"01000000011","national_id":"%s","link":{"customer_id":"%s","relation":"father"}}',t.nid(11),t.id('b-early'))),'CUSTOMER_NOT_FOUND');
SELECT t.error('create with link: a bad relation',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Rolled Back","phone":"01000000011","national_id":"%s","link":{"customer_id":"%s","relation":"boss"}}',t.nid(11),t.id('cust-a'))),'VALIDATION_FAILED');
SELECT t.error('create with link: a link without a relation',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Rolled Back","phone":"01000000011","national_id":"%s","link":{"customer_id":"%s"}}',t.nid(11),t.id('cust-a'))),'VALIDATION_FAILED');
SELECT t.error('create with link: a link with an extra key',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Rolled Back","phone":"01000000011","national_id":"%s","link":{"customer_id":"%s","relation":"father","extra":1}}',t.nid(11),t.id('cust-a'))),'VALIDATION_FAILED');
SELECT t.error('create with link: a link that is not an object',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Rolled Back","phone":"01000000011","national_id":"%s","link":"x"}',t.nid(11))),'VALIDATION_FAILED');
SELECT t.error('create with link: a customer id that is not a uuid',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Rolled Back","phone":"01000000011","national_id":"%s","link":{"customer_id":"nope","relation":"father"}}',t.nid(11))),'VALIDATION_FAILED');
SELECT t.expect('create with link: no guarantor was left behind by any refused call',NOT t.nid_exists(t.nid(11)));
SELECT t.error('create with link: the customer as their own guarantor',format('SELECT public.create_guarantor(%L)',format('{"full_name":"Same Person","phone":"01000000012","national_id":"28506152100023","link":{"customer_id":"%s","relation":"other"}}',t.id('cust-same'))),'GUARANTOR_NATIONAL_ID_TAKEN');
RESET ROLE;

-- ---------------------------------------------------------------- edit (owner, manager, editor)
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.update_guarantor(t.id('mahmoud'),'{"job":"Headmaster","address":"6 Nile St"}');
SELECT t.expect('update: only the changed keys in before and after',
  t.audits('guarantor.updated','mahmoud')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='guarantor.updated' AND entity_id=t.id('mahmoud')
    AND before='{"job":"Teacher","address":"5 Nile St"}'::jsonb AND after='{"job":"Headmaster","address":"6 Nile St"}'::jsonb AND severity='info'),
  (SELECT before::text||' '||after::text FROM public.audit_log WHERE action='guarantor.updated' AND entity_id=t.id('mahmoud')));
SELECT public.update_guarantor(t.id('mahmoud'),'{"job":" Headmaster ","phone":"0100 123 4567","national_id":"29001010100015","full_name":"Mahmoud  Hassan"}');
SELECT t.expect('update: the same values again (written differently), no audit row',t.audits('guarantor.updated','mahmoud')=1);
SELECT t.expect('update: an empty string clears an optional field',
  r->'address'='null'::jsonb AND r->'monthly_income'='null'::jsonb AND r->>'job'='Headmaster',r::text)
FROM (SELECT public.update_guarantor(t.id('mahmoud'),'{"address":"  ","monthly_income":null}') r) x;
SELECT t.expect('update: ... and that change is audited once more',t.audits('guarantor.updated','mahmoud')=2);
SELECT t.error('update: the phone can not be cleared',format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),'{"phone":""}'),'VALIDATION_FAILED');
SELECT t.error('update: the national ID can not be cleared',format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),'{"national_id":null}'),'VALIDATION_FAILED');
SELECT t.error('update: the name can not be cleared',format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),'{"full_name":""}'),'VALIDATION_FAILED');
SELECT t.error('update: an unknown key',format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),'{"customer_id":null}'),'VALIDATION_FAILED');
SELECT t.error('update: a bad ID',format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),'{"national_id":"49001010100015"}'),'VALIDATION_FAILED');
SELECT t.error('update: an ID another guarantor has',format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),'{"national_id":"28506152100023"}'),'GUARANTOR_NATIONAL_ID_TAKEN');
SELECT t.expect('update: the duplicate error names the other guarantor',
  d::jsonb=jsonb_build_object('guarantor_id',t.id('arabic'),'full_name','أحمد فاطمة'),d)
FROM (SELECT t.detail(format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),'{"national_id":"28506152100023"}')) d) x;
SELECT t.error('update: another shop''s guarantor id',format('SELECT public.update_guarantor(%L,%L)',gen_random_uuid(),'{"job":"x"}'),'GUARANTOR_NOT_FOUND');
INSERT INTO t.ids SELECT 'cust-m',(public.create_customer(format('{"full_name":"Mahmoud As Customer","phones":["01100000007"],"national_id":"%s"}',t.nid(20))::jsonb)->>'id')::uuid;
SELECT public.update_guarantor(t.id('mahmoud'),format('{"national_id":"%s"}',t.nid(20))::jsonb);
SELECT t.expect('update: a changed ID is audited as warning with the masks only, never the number',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='guarantor.updated' AND entity_id=t.id('mahmoud') AND severity='warning'
    AND before->>'national_id_masked'='**********0015' AND after->>'national_id_masked'='**********0020' AND (after->>'national_id_changed')='true'
    AND NOT before ? 'national_id' AND NOT after ? 'national_id')
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND (COALESCE(before::text,'')||COALESCE(after::text,'')) LIKE '%'||t.nid(20)||'%'));
SELECT t.expect('update: the changed ID moves the "also a customer" link with it',
  t.gcust('mahmoud')=t.id('cust-m')
  AND public.get_guarantor(t.id('mahmoud'))->'also_customer'=jsonb_build_object('id',t.id('cust-m'),'full_name','Mahmoud As Customer'));
RESET ROLE;
-- Editor: a manager without customer.view_pii.
SELECT t.as_user('a0710000-0000-0000-8000-000000000007',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('update: without customer.view_pii the national ID can not be sent, whatever the value',
  format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),format('{"national_id":"%s"}',t.nid(20))),'PERMISSION_DENIED');
SELECT t.error('update: ... not even a different one',format('SELECT public.update_guarantor(%L,%L)',t.id('mahmoud'),format('{"national_id":"%s"}',t.nid(21))),'PERMISSION_DENIED');
SELECT t.expect('update: ... but the other fields are fine, and the answer is masked',
  public.update_guarantor(t.id('mahmoud'),'{"job":"Editor"}')->>'job'='Editor' AND public.get_guarantor(t.id('mahmoud'))->'national_id'='null'::jsonb);
SELECT t.expect('update: the refused ID changes left the ID as it was',t.gnid('mahmoud')=t.nid(20));
RESET ROLE;
-- Manager: sees and may replace the ID.
SELECT t.as_user('a0710000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('manager (customer.view_pii): sees the ID and may replace it',
  public.get_guarantor(t.id('mahmoud'))->>'national_id'=t.nid(20)
  AND public.update_guarantor(t.id('mahmoud'),'{"national_id":"29001010100015"}')->>'national_id'='29001010100015');
SELECT t.expect('manager: the "also a customer" link went away with the old ID',
  t.gcust('mahmoud') IS NULL AND public.get_guarantor(t.id('mahmoud'))->'also_customer'='null'::jsonb);
RESET ROLE;

-- ---------------------------------------------------------------- masking
SELECT t.as_user('a0710000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'by-cashier',(public.create_guarantor(format('{"full_name":"Cashier Guarantor","phone":"01000000020","national_id":"%s"}',t.nid(30))::jsonb)->>'id')::uuid;
SELECT t.expect('masking: a cashier gets no national ID, no birth date and no gender back, only the mask',
  g->'national_id'='null'::jsonb AND g->>'national_id_masked'='**********0030' AND g->'birth_date'='null'::jsonb AND g->'gender'='null'::jsonb, g::text)
FROM (SELECT public.get_guarantor(t.id('by-cashier')) g) x;
SELECT t.expect('masking: ... in the list too',
  (SELECT bool_and(i->'national_id'='null'::jsonb AND i->'birth_date'='null'::jsonb AND i->'gender'='null'::jsonb) FROM jsonb_array_elements(public.list_guarantors()->'items') i));
SELECT t.expect('masking: a search by the whole ID finds it; a prefix (a digit-by-digit guess) does not',
  (public.list_guarantors(t.nid(30))->>'total')::int=1 AND (public.list_guarantors('2900101')->>'total')::int=0);
RESET ROLE;
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('masking: the owner gets the full ID, the birth date and the gender; a prefix search works',
  g->>'national_id'=t.nid(30) AND g->>'birth_date'='1990-01-01' AND g->>'gender'='male' AND (public.list_guarantors('2900101')->>'total')::int>=2, g::text)
FROM (SELECT public.get_guarantor(t.id('by-cashier')) g) x;
SELECT t.expect('search: by name (letter case and Arabic letter forms ignored) and by phone however it is written',
  (public.list_guarantors('mahmoud')->>'total')::int=1 AND (public.list_guarantors('MAHMOUD hassan')->>'total')::int=1
  AND (public.list_guarantors('+20 100 123 4567')->>'total')::int=2 AND (public.list_guarantors('احمد')->>'total')::int=1);
SELECT t.expect('search: the list is ordered by name and paged',
  (SELECT string_agg(i->>'full_name',',' ORDER BY o) FROM jsonb_array_elements(public.list_guarantors(NULL,'active',2,0)->'items') WITH ORDINALITY x(i,o))=
  (SELECT string_agg(full_name,',' ORDER BY full_name,id) FROM (SELECT full_name,id FROM public.guarantors WHERE organization_id=t.org('a') AND archived_at IS NULL ORDER BY full_name,id LIMIT 2) y));
SELECT t.error('list: a page size of 0',$q$SELECT public.list_guarantors(NULL,'active',0,0)$q$,'VALIDATION_FAILED');
SELECT t.error('list: an unknown status',$q$SELECT public.list_guarantors(NULL,'blocked',10,0)$q$,'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- links
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'g1',(public.create_guarantor(format('{"full_name":"G One","phone":"01000000031","national_id":"%s"}',t.nid(31))::jsonb)->>'id')::uuid;
INSERT INTO t.ids SELECT 'g2',(public.create_guarantor(format('{"full_name":"G Two","phone":"01000000032","national_id":"%s"}',t.nid(32))::jsonb)->>'id')::uuid;
INSERT INTO t.ids SELECT 'g3',(public.create_guarantor(format('{"full_name":"G Three","phone":"01000000033","national_id":"%s"}',t.nid(33))::jsonb)->>'id')::uuid;
INSERT INTO t.ids SELECT 'g4',(public.create_guarantor(format('{"full_name":"G Four","phone":"01000000034","national_id":"%s"}',t.nid(34))::jsonb)->>'id')::uuid;
INSERT INTO t.ids SELECT 'g5',(public.create_guarantor(format('{"full_name":"G Five","phone":"01000000035","national_id":"%s"}',t.nid(35))::jsonb)->>'id')::uuid;
INSERT INTO t.ids SELECT 'g6',(public.create_guarantor(format('{"full_name":"G Six","phone":"01000000036","national_id":"%s"}',t.nid(36))::jsonb)->>'id')::uuid;
SELECT t.expect('link: the answer is the customer''s whole list, with the relation and the active-contract flag',
  (SELECT string_agg(i->>'full_name'||':'||(i->>'relation')||':'||(i->>'on_active_contract'),',' ORDER BY o) FROM jsonb_array_elements(
     public.link_customer_guarantor(t.id('cust-b'),t.id('g1'),'brother')) WITH ORDINALITY x(i,o))='G One:brother:false');
SELECT t.expect('link: one customer.guarantor_linked row naming the guarantor and the relation',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.guarantor_linked' AND entity_type='customer'
     AND entity_id=t.id('cust-b') AND after=jsonb_build_object('guarantor_id',t.id('g1'),'relation','brother'))=1);
SELECT t.error('link: the same pair again',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-b'),t.id('g1'),'friend'),'GUARANTOR_ALREADY_LINKED');
SELECT t.error('link: a bad relation',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-b'),t.id('g2'),'boss'),'VALIDATION_FAILED');
SELECT t.error('link: no relation',format('SELECT public.link_customer_guarantor(%L,%L,NULL)',t.id('cust-b'),t.id('g2')),'VALIDATION_FAILED');
SELECT t.error('link: a customer that does not exist',format('SELECT public.link_customer_guarantor(%L,%L,%L)',gen_random_uuid(),t.id('g2'),'friend'),'CUSTOMER_NOT_FOUND');
SELECT t.error('link: a guarantor that does not exist',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-b'),gen_random_uuid(),'friend'),'GUARANTOR_NOT_FOUND');
SELECT public.link_customer_guarantor(t.id('cust-b'),t.id('g2'),'friend');
SELECT public.link_customer_guarantor(t.id('cust-b'),t.id('g3'),'friend');
SELECT public.link_customer_guarantor(t.id('cust-b'),t.id('g4'),'friend');
SELECT public.link_customer_guarantor(t.id('cust-b'),t.id('g5'),'friend');
SELECT t.error('link: a sixth guarantor',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-b'),t.id('g6'),'friend'),'GUARANTOR_LIMIT_REACHED');
SELECT t.expect('link: five is the limit, and the sixth wrote nothing',(SELECT count(*) FROM public.customer_guarantors WHERE customer_id=t.id('cust-b'))=5);
-- A guarantor can't guarantee themselves: the same national ID (also when the customer came after the guarantor).
INSERT INTO t.ids SELECT 'cust-g6',(public.create_customer(format('{"full_name":"Customer Six","phones":["01100000009"],"national_id":"%s"}',t.nid(36))::jsonb)->>'id')::uuid;
SELECT t.error('link: the guarantor is the customer (same national ID, the customer was made later)',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-g6'),t.id('g6'),'other'),'GUARANTOR_IS_CUSTOMER');
SELECT t.error('link: the guarantor is the customer (linked by customer_id)',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-same'),t.id('arabic'),'other'),'GUARANTOR_IS_CUSTOMER');
SELECT t.error('create with link: an ID another guarantor has is refused even with a link',
  format('SELECT public.create_guarantor(%L)',format('{"full_name":"Self","phone":"01000000040","national_id":"%s","link":{"customer_id":"%s","relation":"other"}}',t.nid(36)||'',t.id('cust-g6'))),'GUARANTOR_NATIONAL_ID_TAKEN');
-- Relation change.
SELECT t.expect('relation: changed',
  (public.set_customer_guarantor_relation(t.id('cust-b'),t.id('g2'),'colleague') IS NOT NULL)
  AND t.links('cust-b') LIKE '%G Two:colleague%');
SELECT t.expect('relation: ... audited with the old and the new one',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.guarantor_relation_set' AND entity_id=t.id('cust-b')
        AND before=jsonb_build_object('guarantor_id',t.id('g2'),'relation','friend') AND after=jsonb_build_object('guarantor_id',t.id('g2'),'relation','colleague'))=1);
SELECT public.set_customer_guarantor_relation(t.id('cust-b'),t.id('g2'),'colleague');
SELECT t.expect('relation: the same relation again writes no audit row',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.guarantor_relation_set' AND entity_id=t.id('cust-b'))=1);
SELECT t.error('relation: a bad relation',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',t.id('cust-b'),t.id('g2'),'boss'),'VALIDATION_FAILED');
SELECT t.error('relation: a guarantor that is not linked',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',t.id('cust-b'),t.id('g6'),'friend'),'GUARANTOR_NOT_LINKED');
SELECT t.error('relation: a guarantor of another shop',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',t.id('cust-b'),gen_random_uuid(),'friend'),'GUARANTOR_NOT_FOUND');
-- Unlink.
SELECT t.expect('unlink: removes the link and answers the rest of the list',
  (SELECT count(*) FROM jsonb_array_elements(public.unlink_customer_guarantor(t.id('cust-b'),t.id('g5'))))=4 AND t.links('cust-b') NOT LIKE '%G Five%');
SELECT t.expect('unlink: audited as a warning with who and the relation',
  EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.guarantor_unlinked' AND entity_id=t.id('cust-b')
    AND severity='warning' AND before=jsonb_build_object('guarantor_id',t.id('g5'),'relation','friend') AND employee_id IS NOT NULL));
SELECT t.error('unlink: the same guarantor again',format('SELECT public.unlink_customer_guarantor(%L,%L)',t.id('cust-b'),t.id('g5')),'GUARANTOR_NOT_LINKED');
SELECT t.expect('unlink: the guarantor record itself stays',EXISTS(SELECT 1 FROM public.guarantors WHERE id=t.id('g5')));
SELECT t.expect('link: after an unlink there is room for another, and the sixth now fits',
  (SELECT count(*) FROM jsonb_array_elements(public.link_customer_guarantor(t.id('cust-b'),t.id('g6'),'neighbour')))=5);
RESET ROLE;

-- ---------------------------------------------------------------- Done when: editing a customer never deletes their guarantors
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('before the customer edits: cust-b has five guarantors',t.links('cust-b')='G Four:friend,G One:brother,G Six:neighbour,G Three:friend,G Two:colleague',t.links('cust-b'));
SELECT public.update_customer(t.id('cust-b'),'{"full_name":"Customer B Renamed","phones":["01100000099","01100000098"],"address":"New address","notes":"edited"}');
SELECT public.update_customer(t.id('cust-b'),format('{"national_id":"%s"}',t.nid(77))::jsonb);
SELECT public.set_customer_status(t.id('cust-b'),'blocked','Testing the links');
SELECT public.set_customer_status(t.id('cust-b'),'active');
SELECT t.expect('Done when: a customer edited (name, phones, ID fill) and blocked/unblocked still has exactly the same five links and relations',
  t.links('cust-b')='G Four:friend,G One:brother,G Six:neighbour,G Three:friend,G Two:colleague',t.links('cust-b'));
RESET ROLE;
SELECT t.expect('Done when: no customer_guarantors row was deleted by those edits',
  (SELECT count(*) FROM public.customer_guarantors WHERE customer_id=t.id('cust-b'))=5);

-- ---------------------------------------------------------------- blocked customer, archived guarantor
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.set_customer_status(t.id('cust-a'),'blocked','Blocked for the link test');
SELECT t.error('link: a blocked customer gets no new link',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-a'),t.id('g1'),'friend'),'CUSTOMER_BLOCKED');
SELECT public.set_customer_status(t.id('cust-a'),'active');
SELECT t.expect('archive: a guarantor with no contract can be archived; the answer carries the date',
  public.set_guarantor_archived(t.id('g6'),true)->'archived_at'<>'null'::jsonb);
SELECT t.expect('archive: ... audited once, as a warning',
  t.audits('guarantor.archived','g6')=1
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='guarantor.archived' AND entity_id=t.id('g6') AND severity='warning'));
SELECT t.expect('archive: the same state again changes nothing',public.set_guarantor_archived(t.id('g6'),true)->'archived_at'<>'null'::jsonb);
SELECT t.expect('archive: ... and writes no audit row',t.audits('guarantor.archived','g6')=1);
SELECT t.expect('archive: an archived guarantor stays readable, keeps its links, and is listed under archived only',
  public.get_guarantor(t.id('g6'))->>'full_name'='G Six' AND t.links('cust-b') LIKE '%G Six:neighbour%'
  AND (public.list_guarantors('G Six')->>'total')::int=0 AND (public.list_guarantors('G Six','archived')->>'total')::int=1
  AND (public.list_guarantors('G Six','all')->>'total')::int=1);
SELECT t.error('archive: an archived guarantor can not be linked anew',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-a'),t.id('g6'),'friend'),'GUARANTOR_ARCHIVED');
SELECT t.expect('restore: back to active',public.set_guarantor_archived(t.id('g6'),false)->'archived_at'='null'::jsonb);
SELECT t.expect('restore: ... audited',t.audits('guarantor.restored','g6')=1);
SELECT t.expect('restore: the same state again changes nothing',public.set_guarantor_archived(t.id('g6'),false)->'archived_at'='null'::jsonb);
SELECT t.expect('restore: ... and writes no audit row',t.audits('guarantor.restored','g6')=1);
SELECT t.error('archive: another shop''s guarantor',format('SELECT public.set_guarantor_archived(%L,true)',gen_random_uuid()),'GUARANTOR_NOT_FOUND');
SELECT t.error('archive: a missing flag',format('SELECT public.set_guarantor_archived(%L,NULL)',t.id('g6')),'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- settings: guarantors_required_count
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('settings: versions that existed before this migration read 1',
  (SELECT bool_and((p->>'guarantors_required_count')::int=1) FROM jsonb_array_elements(public.list_installment_policies()) p));
SELECT public.publish_installment_policy('{"guarantor_required_above":"10000.00","guarantors_required_count":2}');
SELECT t.expect('settings: publishing accepts 2; the current policy answers it',
  (public.get_shop_settings()->'installment_policy'->>'guarantors_required_count')='2'
  AND (public.get_shop_settings()->'installment_policy'->>'guarantor_required_above')='10000.00');
SELECT t.error('settings: 0 is refused',$q$SELECT public.publish_installment_policy('{"guarantors_required_count":0}')$q$,'POLICY_INVALID');
SELECT t.error('settings: 4 is refused',$q$SELECT public.publish_installment_policy('{"guarantors_required_count":4}')$q$,'POLICY_INVALID');
SELECT t.error('settings: text is refused',$q$SELECT public.publish_installment_policy('{"guarantors_required_count":"many"}')$q$,'POLICY_INVALID');
SELECT t.error('settings: 1.5 is refused',$q$SELECT public.publish_installment_policy('{"guarantors_required_count":1.5}')$q$,'POLICY_INVALID');
SELECT t.error('settings: null is refused',$q$SELECT public.publish_installment_policy('{"guarantors_required_count":null}')$q$,'POLICY_INVALID');
SELECT public.publish_installment_policy('{"grace_days":4}');
SELECT t.expect('settings: a new version keeps the previous count when the key is not sent',
  (public.get_shop_settings()->'installment_policy'->>'guarantors_required_count')='2');
INSERT INTO t.ids SELECT 'policy-now',(public.get_shop_settings()->'installment_policy'->>'id')::uuid;
SELECT t.expect('settings: the same terms again publish no new version',
  public.publish_installment_policy('{"guarantors_required_count":2}')=t.id('policy-now')
  AND (public.get_shop_settings()->'installment_policy'->>'id')::uuid=t.id('policy-now'));
RESET ROLE;
SELECT t.expect('settings: the column is a smallint, not nullable, with a 1-3 check',
  (SELECT is_nullable='NO' AND data_type='smallint' FROM information_schema.columns WHERE table_schema='public' AND table_name='installment_policies' AND column_name='guarantors_required_count')
  AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.installment_policies'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%guarantors_required_count >= 1%' AND pg_get_constraintdef(oid) LIKE '%guarantors_required_count <= 3%'));

-- ---------------------------------------------------------------- Done when: contracts (policy: above 10 000.00 needs 2)
SELECT t.expect('policy: the shop''s current version needs 2 above 10000.00',
  (SELECT p.guarantors_required_count=2 AND p.guarantor_required_above=10000.00 FROM public.installment_policies p WHERE p.organization_id=t.org('a') ORDER BY p.version DESC LIMIT 1));
SELECT t.expect('app.guarantors_required: 10000.00 -> 0, 10000.01 -> 2, 15000 -> 2',
  app.guarantors_required(t.org('a'),(SELECT id FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1),10000.00)=0
  AND app.guarantors_required(t.org('a'),(SELECT id FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1),10000.01)=2
  AND app.guarantors_required(t.org('a'),(SELECT id FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1),15000)=2);
SELECT t.expect('app.guarantors_required: another shop''s policy or an unknown one -> 0',
  app.guarantors_required(t.org('b'),(SELECT id FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1),99999)=0
  AND app.guarantors_required(t.org('a'),gen_random_uuid(),99999)=0);
-- A policy without a guarantor amount never needs one (shop b keeps its first version).
SELECT t.expect('app.guarantors_required: a policy amount of NULL -> 0 whatever the financed amount',
  app.guarantors_required(t.org('b'),(SELECT id FROM public.installment_policies WHERE organization_id=t.org('b') ORDER BY version DESC LIMIT 1),99999999)=0
  AND (SELECT guarantor_required_above IS NULL FROM public.installment_policies WHERE organization_id=t.org('b') ORDER BY version DESC LIMIT 1));

CREATE FUNCTION t.check_contract(p_customer text,p_financed numeric,p_guarantors text[]) RETURNS void LANGUAGE sql AS $$
  SELECT app.check_contract_guarantors(t.org('a'),t.id(p_customer),
    (SELECT id FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1),p_financed,
    ARRAY(SELECT t.id(x) FROM unnest(p_guarantors) x)) $$;
-- cust-b is linked to g1, g2, g3, g4, g6; cust-a to "linked". g5 belongs to nobody now; shop b has its own.
SELECT t.as_user('a0710000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'b-guarantor',(public.create_guarantor(format('{"full_name":"Shop B Guarantor","phone":"01000000050","national_id":"%s"}',t.nid(50))::jsonb)->>'id')::uuid;
INSERT INTO t.ids SELECT 'b-customer',(public.create_customer('{"full_name":"Shop B Customer","phones":["01200000001"]}')->>'id')::uuid;
SELECT public.link_customer_guarantor(t.id('b-customer'),t.id('b-guarantor'),'father');
RESET ROLE;
SELECT t.passes('check: two linked, active guarantors for a financed amount above the limit pass',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1','g2'])$q$);
SELECT t.passes('check: three pass too (the maximum)',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1','g2','g3'])$q$);
SELECT t.passes('check: none pass when nothing is required (10000.00 is not above the limit)',$q$SELECT t.check_contract('cust-b',10000.00,ARRAY[]::text[])$q$);
SELECT t.error('check: one guarantor is too few',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1'])$q$,'GUARANTOR_REQUIRED');
SELECT t.expect('check: GUARANTOR_REQUIRED says how many were needed and given',
  d::jsonb='{"required":2,"given":1}'::jsonb,d) FROM (SELECT t.detail($q$SELECT t.check_contract('cust-b',15000,ARRAY['g1'])$q$) d) x;
SELECT t.error('check: none at all',$q$SELECT t.check_contract('cust-b',15000.00,ARRAY[]::text[])$q$,'GUARANTOR_REQUIRED');
SELECT t.error('check: a guarantor of another customer',$q$SELECT t.check_contract('cust-a',15000,ARRAY['g1','g2'])$q$,'GUARANTOR_NOT_LINKED');
SELECT t.error('check: a guarantor that is not linked to anyone',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1','g5'])$q$,'GUARANTOR_NOT_LINKED');
SELECT t.error('check: another shop''s guarantor',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1','b-guarantor'])$q$,'GUARANTOR_NOT_FOUND');
SELECT t.error('check: duplicates',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1','g1'])$q$,'VALIDATION_FAILED');
SELECT t.error('check: four ids',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1','g2','g3','g4'])$q$,'VALIDATION_FAILED');
UPDATE public.guarantors SET archived_at=now() WHERE id=t.id('g2');
SELECT t.error('check: an archived guarantor',$q$SELECT t.check_contract('cust-b',15000,ARRAY['g1','g2'])$q$,'GUARANTOR_ARCHIVED');
UPDATE public.guarantors SET archived_at=NULL WHERE id=t.id('g2');

-- The trigger: a contract that needs guarantors can't be committed without them.
SELECT t.error('trigger: financed 15000.00 and no guarantor fails at commit with GUARANTOR_REQUIRED',
  $q$SELECT t.seed_contract('t1','cust-b',15000.00,'active',false,ARRAY[]::text[])$q$,'GUARANTOR_REQUIRED');
SELECT t.expect('trigger: ... with the numbers in the detail',
  d::jsonb='{"required":2,"given":0}'::jsonb,d) FROM (SELECT t.detail($q$SELECT t.seed_contract('t1','cust-b',15000.00,'active',false,ARRAY[]::text[])$q$) d) x;
SELECT t.error('trigger: one guarantor of two',$q$SELECT t.seed_contract('t2','cust-b',15000.00,'active',false,ARRAY['g1'])$q$,'GUARANTOR_REQUIRED');
SELECT t.expect('trigger: nothing of the refused contracts was left behind',
  NOT EXISTS(SELECT 1 FROM public.contracts WHERE number IN ('R04-C-t1','R04-C-t2')) AND NOT EXISTS(SELECT 1 FROM public.sales_orders WHERE number IN ('R04-SO-t1','R04-SO-t2')));
SELECT t.seed_contract('t3','cust-b',15000.00,'active',false,ARRAY['g1','g2']);
SELECT t.expect('trigger: the same contract with two guarantors attached in the same transaction commits',
  (SELECT count(*) FROM public.contract_guarantors WHERE contract_id=t.id('contract-t3'))=2);
SELECT t.seed_contract('t4','cust-b',8000.00,'completed',false,ARRAY[]::text[]);
SELECT t.expect('trigger: financed 8000.00 with none commits (below the limit)',EXISTS(SELECT 1 FROM public.contracts WHERE number='R04-C-t4'));
SELECT t.seed_contract('t5','cust-b',10000.00,'completed',false,ARRAY[]::text[]);
SELECT t.expect('trigger: exactly the limit (10000.00) needs none',EXISTS(SELECT 1 FROM public.contracts WHERE number='R04-C-t5'));
SELECT t.seed_contract('t6','cust-b',50000.00,'completed',true,ARRAY[]::text[]);
SELECT t.expect('trigger: an is_migrated contract with none commits (M02 opening balances)',EXISTS(SELECT 1 FROM public.contracts WHERE number='R04-C-t6'));
SELECT t.expect('trigger: a deferred constraint trigger, not a plain row trigger',
  (SELECT tgdeferrable AND tginitdeferred FROM pg_trigger WHERE tgname='trg_contracts_guarantors_check' AND tgrelid='public.contracts'::regclass));
SELECT t.error('contract_guarantors: rows can not be updated (baseline)',
  format('UPDATE public.contract_guarantors SET guarantor_id=%L WHERE contract_id=%L',t.id('g4'),t.id('contract-t3')),'APPEND_ONLY');
SELECT t.error('contract_guarantors: rows can not be deleted (baseline)',
  format('DELETE FROM public.contract_guarantors WHERE contract_id=%L',t.id('contract-t3')),'APPEND_ONLY');
-- app.attach_contract_guarantors: what N02 calls inside the transaction that inserts the contract.
SELECT t.seed_contract('t9','cust-b',3000.00,'active',false,ARRAY[]::text[]);
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SELECT t.passes('attach: two guarantors are attached',$q$SELECT t.attach('contract-t9',ARRAY['g1','g2'])$q$);
SELECT t.expect('attach: the rows are there, in the shop of the contract',
  (SELECT count(*) FROM public.contract_guarantors WHERE contract_id=t.id('contract-t9') AND organization_id=t.org('a'))=2);
SELECT t.error('attach: the same guarantor twice',$q$SELECT t.attach('contract-t9',ARRAY['g3','g3'])$q$,'VALIDATION_FAILED');
SELECT t.error('attach: four guarantors',$q$SELECT t.attach('contract-t9',ARRAY['g3','g4','g5','g6'])$q$,'VALIDATION_FAILED');
SELECT t.error('attach: another shop''s guarantor',$q$SELECT t.attach('contract-t9',ARRAY['b-guarantor'])$q$,'GUARANTOR_NOT_FOUND');
UPDATE public.guarantors SET archived_at=now() WHERE id=t.id('g5');
SELECT t.error('attach: an archived guarantor',$q$SELECT t.attach('contract-t9',ARRAY['g5'])$q$,'GUARANTOR_ARCHIVED');
UPDATE public.guarantors SET archived_at=NULL WHERE id=t.id('g5');
SELECT t.error('attach: a guarantor already on the contract (the primary key)',$q$SELECT t.attach('contract-t9',ARRAY['g1'])$q$,'duplicate key value violates unique constraint "contract_guarantors_pkey"');
SELECT t.expect('attach: the rows carry the employee who attached them',(SELECT bool_and(created_by IS NOT NULL) FROM public.contract_guarantors WHERE contract_id=t.id('contract-t9')));
-- Contracts in two states for the unlink and archive rules (below the limit, so one guarantor is enough).
SELECT t.seed_contract('t7','cust-b',5000.00,'active',false,ARRAY['g3']);
SELECT t.seed_contract('t8','cust-b',5000.00,'completed',false,ARRAY['g4']);

SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('flags: the customer''s list tells which guarantor is on an active contract',
  (SELECT string_agg(i->>'full_name'||'='||(i->>'on_active_contract'),',' ORDER BY i->>'full_name') FROM jsonb_array_elements(public.list_customer_guarantors(t.id('cust-b'))) i)
  ='G Four=false,G One=true,G Six=false,G Three=true,G Two=true',
  (SELECT string_agg(i->>'full_name'||'='||(i->>'on_active_contract'),',' ORDER BY i->>'full_name') FROM jsonb_array_elements(public.list_customer_guarantors(t.id('cust-b'))) i));
SELECT t.error('unlink: refused while the guarantor is on an active contract of that customer',format('SELECT public.unlink_customer_guarantor(%L,%L)',t.id('cust-b'),t.id('g3')),'GUARANTOR_ON_ACTIVE_CONTRACT');
SELECT t.expect('unlink: a guarantor whose contract is completed can be unlinked',
  (SELECT count(*) FROM jsonb_array_elements(public.unlink_customer_guarantor(t.id('cust-b'),t.id('g4'))))=4);
SELECT t.error('archive: refused while the guarantor is on an active contract',format('SELECT public.set_guarantor_archived(%L,true)',t.id('g3')),'GUARANTOR_ON_ACTIVE_CONTRACT');
SELECT t.expect('archive: a guarantor on a completed contract only can be archived',
  public.set_guarantor_archived(t.id('g4'),true)->'archived_at'<>'null'::jsonb AND public.set_guarantor_archived(t.id('g4'),false)->'archived_at'='null'::jsonb);
SELECT t.expect('details: the guarantor answers the customers they back and the contracts they are on',
  (SELECT count(*) FROM jsonb_array_elements(g->'customers'))=1 AND g->'customers'->0->>'full_name'='Customer B Renamed'
  AND g->'customers'->0->>'relation'='friend' AND (SELECT count(*) FROM jsonb_array_elements(g->'contracts'))=1
  AND g->'contracts'->0->>'total_payable'='5000.00' AND g->'contracts'->0->>'customer_name'='Customer B Renamed'
  AND g->'contracts'->0->>'status'='active' AND g->'contracts'->0->>'number'='R04-C-t7', g::text)
FROM (SELECT public.get_guarantor(t.id('g3')) g) x;
SELECT t.expect('details: a guarantor with no contract has an empty list',
  jsonb_array_length(public.get_guarantor(t.id('g6'))->'contracts')=0);
RESET ROLE;

-- ---------------------------------------------------------------- the requirement read
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('requirement: above the limit needs 2; cust-b has 4 linked active guarantors -> met',
  r->>'required_count'='2' AND r->>'linked_active_count'='4' AND (r->>'met')='true' AND r->>'required_above'='10000.00' AND r->>'policy_version' IS NOT NULL, r::text)
FROM (SELECT public.get_guarantor_requirement(t.id('cust-b'),'15000.00') r) x;
SELECT t.expect('requirement: at the limit nothing is needed',
  r->>'required_count'='0' AND (r->>'met')='true', r::text) FROM (SELECT public.get_guarantor_requirement(t.id('cust-b'),'10000.00') r) x;
SELECT t.expect('requirement: cust-a has 1 linked guarantor -> not met',
  r->>'required_count'='2' AND r->>'linked_active_count'='1' AND (r->>'met')='false', r::text) FROM (SELECT public.get_guarantor_requirement(t.id('cust-a'),'15000.00') r) x;
SELECT t.expect('requirement: the policy id is the current version''s',
  (public.get_guarantor_requirement(t.id('cust-a'),'1.00')->>'policy_id')::uuid=(SELECT id FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1));
SELECT t.error('requirement: a bad amount',format('SELECT public.get_guarantor_requirement(%L,%L)',t.id('cust-a'),'abc'),'VALIDATION_FAILED');
SELECT t.error('requirement: a negative amount',format('SELECT public.get_guarantor_requirement(%L,%L)',t.id('cust-a'),'-5'),'VALIDATION_FAILED');
SELECT t.error('requirement: no amount',format('SELECT public.get_guarantor_requirement(%L,NULL)',t.id('cust-a')),'VALIDATION_FAILED');
SELECT t.error('requirement: another shop''s customer',format('SELECT public.get_guarantor_requirement(%L,%L)',t.id('b-customer'),'100.00'),'CUSTOMER_NOT_FOUND');
RESET ROLE;
-- An archived guarantor does not count towards "met".
UPDATE public.guarantors SET archived_at=now() WHERE id=t.id('linked');
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('requirement: an archived guarantor does not count',
  (public.get_guarantor_requirement(t.id('cust-a'),'15000.00')->>'linked_active_count')='0');
RESET ROLE;
UPDATE public.guarantors SET archived_at=NULL WHERE id=t.id('linked');

-- ---------------------------------------------------------------- who may
-- Cashier: customer.create, no guarantor.manage: creates and links, can't edit, relate, unlink or archive.
SELECT t.as_user('a0710000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier: creates a guarantor with a link',
  public.create_guarantor(format('{"full_name":"Cashier Linked","phone":"01000000060","national_id":"%s","link":{"customer_id":"%s","relation":"neighbour"}}',t.nid(60),t.id('cust-a'))::jsonb)->>'id' IS NOT NULL);
SELECT t.expect('cashier: links an existing guarantor',
  (SELECT count(*) FROM jsonb_array_elements(public.link_customer_guarantor(t.id('cust-a'),t.id('g5'),'friend')))=3);
SELECT t.expect('cashier: reads the list, the details and the requirement',
  (public.list_guarantors()->>'total')::int>=8 AND public.get_guarantor(t.id('g5'))->>'full_name'='G Five'
  AND public.get_guarantor_requirement(t.id('cust-a'),'15000.00') IS NOT NULL AND jsonb_array_length(public.list_customer_guarantors(t.id('cust-a')))=3);
SELECT t.error('cashier: no edit',format('SELECT public.update_guarantor(%L,%L)',t.id('g5'),'{"job":"No"}'),'PERMISSION_DENIED');
SELECT t.error('cashier: no relation change',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',t.id('cust-a'),t.id('g5'),'other'),'PERMISSION_DENIED');
SELECT t.error('cashier: no unlink',format('SELECT public.unlink_customer_guarantor(%L,%L)',t.id('cust-a'),t.id('g5')),'PERMISSION_DENIED');
SELECT t.error('cashier: no archive',format('SELECT public.set_guarantor_archived(%L,true)',t.id('g5')),'PERMISSION_DENIED');
SELECT t.error('cashier: no restore',format('SELECT public.set_guarantor_archived(%L,false)',t.id('g5')),'PERMISSION_DENIED');
RESET ROLE;
-- Collector: a read key (collection.create), no writes.
SELECT t.as_user('a0710000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('collector: reads, masked',
  (public.list_guarantors()->>'total')::int>=8 AND public.get_guarantor(t.id('g5'))->'national_id'='null'::jsonb
  AND public.get_guarantor(t.id('g5'))->>'national_id_masked'='**********0035');
SELECT t.error('collector: no create',format('SELECT public.create_guarantor(%L)',format('{"full_name":"C1","phone":"01000000061","national_id":"%s"}',t.nid(61))),'PERMISSION_DENIED');
SELECT t.error('collector: no link',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-a'),t.id('g6'),'friend'),'PERMISSION_DENIED');
SELECT t.error('collector: no edit',format('SELECT public.update_guarantor(%L,%L)',t.id('g5'),'{"job":"No"}'),'PERMISSION_DENIED');
RESET ROLE;
-- Warehouse: none of the read keys.
SELECT t.as_user('a0710000-0000-0000-8000-000000000006',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('warehouse: no list','SELECT public.list_guarantors()','PERMISSION_DENIED');
SELECT t.error('warehouse: no get',format('SELECT public.get_guarantor(%L)',t.id('g5')),'PERMISSION_DENIED');
SELECT t.error('warehouse: no customer list',format('SELECT public.list_customer_guarantors(%L)',t.id('cust-a')),'PERMISSION_DENIED');
SELECT t.error('warehouse: no requirement',format('SELECT public.get_guarantor_requirement(%L,%L)',t.id('cust-a'),'100.00'),'PERMISSION_DENIED');
SELECT t.error('warehouse: no create',format('SELECT public.create_guarantor(%L)',format('{"full_name":"W1","phone":"01000000062","national_id":"%s"}',t.nid(62))),'PERMISSION_DENIED');
SELECT t.error('warehouse: no link',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-a'),t.id('g6'),'friend'),'PERMISSION_DENIED');
SELECT t.as_user('a0710000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee: list','SELECT public.list_guarantors()','NOT_AN_EMPLOYEE');
SELECT t.error('not an employee: get',format('SELECT public.get_guarantor(%L)',t.id('g5')),'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee: create',format('SELECT public.create_guarantor(%L)',format('{"full_name":"N1","phone":"01000000063","national_id":"%s"}',t.nid(63))),'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee: link',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-a'),t.id('g6'),'friend'),'NOT_AN_EMPLOYEE');
RESET ROLE;
-- A plan without the customers module.
SELECT t.as_user('a0710000-0000-0000-8000-000000000008',t.org('c'));
SET LOCAL ROLE authenticated;
SELECT t.error('starter plan: no list','SELECT public.list_guarantors()','MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no get',format('SELECT public.get_guarantor(%L)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no customer list',format('SELECT public.list_customer_guarantors(%L)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no requirement',format('SELECT public.get_guarantor_requirement(%L,%L)',gen_random_uuid(),'100.00'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no create',format('SELECT public.create_guarantor(%L)',format('{"full_name":"S1","phone":"01000000064","national_id":"%s"}',t.nid(64))),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no update',format('SELECT public.update_guarantor(%L,%L)',gen_random_uuid(),'{"job":"x"}'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no archive',format('SELECT public.set_guarantor_archived(%L,true)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no link',format('SELECT public.link_customer_guarantor(%L,%L,%L)',gen_random_uuid(),gen_random_uuid(),'friend'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no relation',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',gen_random_uuid(),gen_random_uuid(),'friend'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no unlink',format('SELECT public.unlink_customer_guarantor(%L,%L)',gen_random_uuid(),gen_random_uuid()),'MODULE_NOT_IN_PLAN');
RESET ROLE;
-- An expired shop reads but can't write.
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the list, a guarantor, a customer''s list and the requirement still read',
  (public.list_guarantors()->>'total')::int>=8 AND public.get_guarantor(t.id('g5'))->>'full_name'='G Five'
  AND jsonb_array_length(public.list_customer_guarantors(t.id('cust-a')))=3
  AND public.get_guarantor_requirement(t.id('cust-a'),'15000.00') IS NOT NULL);
SELECT t.error('expired shop: no create',format('SELECT public.create_guarantor(%L)',format('{"full_name":"E1","phone":"01000000065","national_id":"%s"}',t.nid(65))),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no update',format('SELECT public.update_guarantor(%L,%L)',t.id('g5'),'{"job":"E"}'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no archive',format('SELECT public.set_guarantor_archived(%L,true)',t.id('g5')),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no link',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-a'),t.id('g6'),'friend'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no relation change',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',t.id('cust-a'),t.id('g5'),'other'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no unlink',format('SELECT public.unlink_customer_guarantor(%L,%L)',t.id('cust-a'),t.id('g5')),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ---------------------------------------------------------------- tenancy
SELECT t.as_user('a0710000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.expect('tenancy: shop b sees only its own guarantor',(public.list_guarantors(NULL,'all')->>'total')::int=1 AND public.get_guarantor(t.id('b-guarantor'))->>'full_name'='Shop B Guarantor');
SELECT t.error('tenancy: shop a''s guarantor is not found',format('SELECT public.get_guarantor(%L)',t.id('g1')),'GUARANTOR_NOT_FOUND');
SELECT t.error('tenancy: shop a''s guarantor can not be edited',format('SELECT public.update_guarantor(%L,%L)',t.id('g1'),'{"job":"B"}'),'GUARANTOR_NOT_FOUND');
SELECT t.error('tenancy: shop a''s guarantor can not be archived',format('SELECT public.set_guarantor_archived(%L,true)',t.id('g1')),'GUARANTOR_NOT_FOUND');
SELECT t.error('tenancy: shop a''s customer has no list for shop b',format('SELECT public.list_customer_guarantors(%L)',t.id('cust-b')),'CUSTOMER_NOT_FOUND');
SELECT t.error('tenancy: shop a''s guarantor can not be linked to shop b''s customer',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('b-customer'),t.id('g1'),'friend'),'GUARANTOR_NOT_FOUND');
SELECT t.error('tenancy: shop a''s customer can not get shop b''s guarantor',format('SELECT public.link_customer_guarantor(%L,%L,%L)',t.id('cust-b'),t.id('b-guarantor'),'friend'),'CUSTOMER_NOT_FOUND');
SELECT t.error('tenancy: shop a''s links can not be changed from shop b',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',t.id('cust-b'),t.id('g1'),'friend'),'CUSTOMER_NOT_FOUND');
SELECT t.error('tenancy: ... nor removed',format('SELECT public.unlink_customer_guarantor(%L,%L)',t.id('cust-b'),t.id('g1')),'CUSTOMER_NOT_FOUND');
SELECT t.error('tenancy: shop a''s guarantor as the guarantor of shop b''s customer on a relation change',format('SELECT public.set_customer_guarantor_relation(%L,%L,%L)',t.id('b-customer'),t.id('g1'),'friend'),'GUARANTOR_NOT_FOUND');
SELECT t.expect('tenancy: shop b''s ID is free in shop a''s list (a search finds nothing there)',(public.list_guarantors(t.nid(31))->>'total')::int=0);
SELECT t.expect('tenancy: the same national ID is free in shop b (unique per shop)',
  public.create_guarantor(format('{"full_name":"Same ID Other Shop","phone":"01000000070","national_id":"%s"}',t.nid(31))::jsonb)->>'id' IS NOT NULL);
RESET ROLE;
SELECT t.expect('tenancy: shop b''s calls wrote nothing into shop a',
  (SELECT count(*) FROM public.guarantors WHERE organization_id=t.org('a') AND full_name='Same ID Other Shop')=0
  AND (SELECT count(*) FROM public.customer_guarantors WHERE organization_id=t.org('b'))=1);

-- ---------------------------------------------------------------- tables and grants
SELECT t.as_user('a0710000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('grants: no direct insert into guarantors',format('INSERT INTO public.guarantors(organization_id,full_name) VALUES(%L,%L)',t.org('a'),'Direct'),'permission denied for table guarantors');
SELECT t.error('grants: no direct update of guarantors',format('UPDATE public.guarantors SET full_name=%L WHERE id=%L','Direct',t.id('g1')),'permission denied for table guarantors');
SELECT t.error('grants: no direct insert into customer_guarantors',format('INSERT INTO public.customer_guarantors(organization_id,customer_id,guarantor_id,relation) VALUES(%L,%L,%L,%L)',t.org('a'),t.id('cust-a'),t.id('g6'),'friend'),'permission denied for table customer_guarantors');
SELECT t.error('grants: no direct delete from customer_guarantors',format('DELETE FROM public.customer_guarantors WHERE customer_id=%L',t.id('cust-a')),'permission denied for table customer_guarantors');
SELECT t.error('grants: no direct insert into contract_guarantors',format('INSERT INTO public.contract_guarantors(organization_id,contract_id,guarantor_id) VALUES(%L,%L,%L)',t.org('a'),t.id('contract-t3'),t.id('g6')),'permission denied for table contract_guarantors');
RESET ROLE;
SELECT t.expect('grants: authenticated has no column grant on guarantors.national_id',
  NOT has_column_privilege('authenticated','public.guarantors','national_id','SELECT')
  AND has_column_privilege('authenticated','public.guarantors','full_name','SELECT'));
SELECT t.expect('grants: the ten public functions are granted to authenticated and to no one else',
  (SELECT count(*) FROM (VALUES
    ('public.list_guarantors(text,text,integer,integer)'),('public.get_guarantor(uuid)'),('public.list_customer_guarantors(uuid)'),
    ('public.get_guarantor_requirement(uuid,text)'),('public.create_guarantor(jsonb)'),('public.update_guarantor(uuid,jsonb)'),
    ('public.set_guarantor_archived(uuid,boolean)'),('public.link_customer_guarantor(uuid,uuid,text)'),
    ('public.set_customer_guarantor_relation(uuid,uuid,text)'),('public.unlink_customer_guarantor(uuid,uuid)')) f(sig)
   WHERE has_function_privilege('authenticated',f.sig,'EXECUTE') AND NOT has_function_privilege('anon',f.sig,'EXECUTE')
     AND NOT has_function_privilege('public',f.sig,'EXECUTE'))=10);
SELECT t.expect('grants: the helpers are not callable by authenticated',
  NOT has_function_privilege('authenticated','app.guarantor_relations()','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.guarantor_on_active_contract(uuid,uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.guarantor_json(uuid,uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.guarantor_fields_json(public.guarantors)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.customer_guarantors_json(uuid,uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.guarantor_apply(public.guarantors,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.guarantor_national_id_taken(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.link_guarantor(uuid,uuid,uuid,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.guarantors_required(uuid,uuid,numeric)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.check_contract_guarantors(uuid,uuid,uuid,numeric,uuid[])','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.attach_contract_guarantors(uuid,uuid,uuid[])','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.contracts_guarantors_check()','EXECUTE'));

-- ---------------------------------------------------------------- ID photos (F14): the entity type guarantor
SELECT t.as_user('a0710000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.register_file(gen_random_uuid(),t.org('a')::text||'/r04-front.png','id-front.png','image/png',100,repeat('a',64),'customer_id','guarantor',t.id('g5'));
SELECT t.expect('photos: a cashier (customer.create) registers a guarantor ID photo, and the count shows for everyone',
  (public.get_guarantor(t.id('g5'))->>'id_photos_count')='1');
SELECT t.error('photos: a file of another shop''s guarantor is not found',
  format('SELECT public.register_file(gen_random_uuid(),%L,%L,%L,100,%L,%L,%L,%L)',t.org('a')::text||'/r04-x.png','x.png','image/png',repeat('a',64),'customer_id','guarantor',t.id('b-guarantor')),'NOT_FOUND');
SELECT t.error('photos: a guarantor that does not exist',
  format('SELECT public.register_file(gen_random_uuid(),%L,%L,%L,100,%L,%L,%L,%L)',t.org('a')::text||'/r04-y.png','y.png','image/png',repeat('a',64),'customer_id','guarantor',gen_random_uuid()),'NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0710000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('photos: a collector (no customer.create) can not register one',
  format('SELECT public.register_file(gen_random_uuid(),%L,%L,%L,100,%L,%L,%L,%L)',t.org('a')::text||'/r04-z.png','z.png','image/png',repeat('a',64),'customer_id','guarantor',t.id('g5')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.expect('photos: the files row is typed guarantor / customer_id, and the photo count of a customer is not affected',
  (SELECT count(*) FROM public.files WHERE organization_id=t.org('a') AND entity_type='guarantor' AND entity_id=t.id('g5') AND purpose='customer_id')=1
  AND (SELECT count(*) FROM public.files WHERE organization_id=t.org('a') AND entity_type='customer' AND entity_id=t.id('cust-a'))=0);

-- ---------------------------------------------------------------- the audit log never holds a national ID
SELECT t.expect('audit: no R04 audit row holds a 14-digit national ID anywhere',
  NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id IN (t.org('a'),t.org('b'))
    AND action IN ('guarantor.created','guarantor.updated','guarantor.archived','guarantor.restored','customer.guarantor_linked','customer.guarantor_relation_set','customer.guarantor_unlinked')
    AND (COALESCE(before::text,'')||COALESCE(after::text,'')) ~ '[0-9]{14}'));
SELECT t.expect('audit: every R04 action wrote rows of its entity type',
  (SELECT bool_and(entity_type=CASE WHEN action LIKE 'guarantor.%' THEN 'guarantor' ELSE 'customer' END) FROM public.audit_log
   WHERE organization_id=t.org('a') AND action IN ('guarantor.created','guarantor.updated','guarantor.archived','guarantor.restored','customer.guarantor_linked','customer.guarantor_relation_set','customer.guarantor_unlinked')));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
