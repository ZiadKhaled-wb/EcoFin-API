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
CREATE FUNCTION t.audits(a text,s text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action=a AND entity_id=t.id(s) $$;
-- "birth_date gender governorate" of a national ID, or 'invalid'.
CREATE FUNCTION t.parsed(i text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(p.birth_date::text||' '||p.gender||' '||p.governorate_code,'invalid') FROM app.parse_national_id(i) p $$;
-- Names of a list result, in order.
CREATE FUNCTION t.names(l jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(i->>'full_name',',' ORDER BY o),'') FROM jsonb_array_elements(l->'items') WITH ORDINALITY x(i,o) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- pure helpers (the same vectors as nationalId.test.ts)
SELECT t.expect('parse: 1990-01-01, male, Cairo',t.parsed('29001010100015')='1990-01-01 male 01',t.parsed('29001010100015'));
SELECT t.expect('parse: 1985-06-15, female, Giza',t.parsed('28506152100023')='1985-06-15 female 21',t.parsed('28506152100023'));
SELECT t.expect('parse: century 3 and a leap day',t.parsed('30002290200344')='2000-02-29 female 02',t.parsed('30002290200344'));
SELECT t.expect('parse: born outside Egypt (88)',t.parsed('29912318800011')='1999-12-31 male 88',t.parsed('29912318800011'));
SELECT t.expect('parse: refuses centuries other than 2 and 3',t.parsed('49001010100015')='invalid' AND t.parsed('19001010100015')='invalid');
SELECT t.expect('parse: refuses month 13, month 00 and day 00',
  t.parsed('29013010100015')='invalid' AND t.parsed('29000010100015')='invalid' AND t.parsed('29001000100015')='invalid');
SELECT t.expect('parse: refuses 30 February and 29 February of a common year',
  t.parsed('29002300100015')='invalid' AND t.parsed('20102290100015')='invalid');
SELECT t.expect('parse: refuses an unknown governorate',t.parsed('29001019900015')='invalid' AND t.parsed('29001010500015')='invalid');
SELECT t.expect('parse: refuses 13 or 15 digits, letters and null',
  t.parsed('2900101010001')='invalid' AND t.parsed('290010101000155')='invalid' AND t.parsed('2900101010001a')='invalid' AND t.parsed(NULL)='invalid');
SELECT t.expect('mask: ten stars and the last four digits',app.mask_national_id('29001010100015')='**********0015' AND app.mask_national_id(NULL) IS NULL);
SELECT t.expect('phone: an Egyptian mobile is stored as 01XXXXXXXXX however it is written',
  app.normalize_customer_phone(' +20 100 123 4567 ')='01001234567' AND app.normalize_customer_phone('0020-100-1234567')='01001234567'
  AND app.normalize_customer_phone('201001234567')='01001234567' AND app.normalize_customer_phone('1001234567')='01001234567'
  AND app.normalize_customer_phone('0100.123.4567')='01001234567');
SELECT t.expect('phone: landlines and foreign numbers keep their digits',
  app.normalize_customer_phone('(02) 2345-6789')='0223456789' AND app.normalize_customer_phone('+966 50 123 4567')='+966501234567');
SELECT t.expect('digits: Arabic-Indic and Persian digits become 0-9',
  app.ascii_digits(U&'\0660\0661\0662\0663\0664\0665\0666\0667\0668\0669')='0123456789'
  AND app.ascii_digits(U&'\06F0\06F1\06F9')='019'
  AND app.normalize_customer_phone(U&'\0660\0661\0660\0660\0661\0662\0663\0664\0665\0666\0667')='01001234567');

-- ---------------------------------------------------------------- setup: shops a, b (retail), c (starter: no customers module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('R01 '||s,'r01-'||s,p,'Owner',s||'r01@example.com',NULL,'Main',h,now()+interval '1 day')
FROM (VALUES('a','retail',repeat('x',64)),('b','retail',repeat('y',64)),('c','starter',repeat('z',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0630000-0000-0000-8000-000000000001','ar01@example.com'),('a0630000-0000-0000-8000-000000000002','br01@example.com'),
  ('a0630000-0000-0000-8000-000000000003','r01cashier@example.com'),('a0630000-0000-0000-8000-000000000004','r01manager@example.com'),
  ('a0630000-0000-0000-8000-000000000005','r01collector@example.com'),('a0630000-0000-0000-8000-000000000006','r01warehouse@example.com'),
  ('a0630000-0000-0000-8000-000000000007','r01editor@example.com'),('a0630000-0000-0000-8000-000000000008','cr01@example.com');
SELECT public.accept_invite(repeat('x',64),'a0630000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a0630000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('z',64),'a0630000-0000-0000-8000-000000000008');
-- Cashier: customer.create only. Manager: create, edit, view_pii. Collector: reads only. Warehouse: no read key.
-- Editor: a manager whose customer.view_pii was taken away (edits, never sees an ID).
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES
  (t.org('a'),'a0630000-0000-0000-8000-000000000003','R01 Cashier','CASHIER'),
  (t.org('a'),'a0630000-0000-0000-8000-000000000004','R01 Manager','BRANCH_MANAGER'),
  (t.org('a'),'a0630000-0000-0000-8000-000000000005','R01 Collector','COLLECTOR'),
  (t.org('a'),'a0630000-0000-0000-8000-000000000006','R01 Warehouse','WAREHOUSE');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a0630000-0000-0000-8000-000000000007','R01 Editor','BRANCH_MANAGER') RETURNING id AS editor_id \gset
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),:'editor_id','customer.view_pii',false);

-- ---------------------------------------------------------------- create (owner: sees PII)
SELECT t.as_user('a0630000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'ahmed',(public.create_customer('{"full_name":"  Ahmed   Ali  Hassan ","phones":[" +20 100 123 4567 ","02-2345 6789"],"national_id":" 2900101-0100015 ","address":" 12 Tahrir St ","city":" Cairo ","job":" Engineer ","employer":" Nile Co ","monthly_income":"8500.5","notes":" vip "}')->>'id')::uuid;
SELECT t.expect('create: trims, joins spaces, normalises the phones and the ID; birth date and gender come from the ID',
  c->>'full_name'='Ahmed Ali Hassan' AND c->'phones'='["01001234567","0223456789"]'::jsonb
  AND c->>'national_id'='29001010100015' AND c->>'national_id_masked'='**********0015'
  AND c->>'birth_date'='1990-01-01' AND c->>'gender'='male' AND c->>'address'='12 Tahrir St' AND c->>'city'='Cairo'
  AND c->>'job'='Engineer' AND c->>'employer'='Nile Co' AND c->>'monthly_income'='8500.50' AND c->>'notes'='vip'
  AND c->>'status'='active' AND c->'is_business'='false'::jsonb AND (c->>'id_photos_count')::int=0, c::text)
FROM (SELECT public.get_customer(t.id('ahmed')) c) x;
INSERT INTO t.ids SELECT 'mona',(public.create_customer('{"full_name":"Mona Said","phones":["01112223334"]}')->>'id')::uuid;
SELECT t.expect('create: defaults (no ID, optional fields null, active)',
  c->'national_id'='null'::jsonb AND c->'national_id_masked'='null'::jsonb AND c->'birth_date'='null'::jsonb AND c->'gender'='null'::jsonb
  AND c->'monthly_income'='null'::jsonb AND c->'tax_registration_no'='null'::jsonb AND c->>'status'='active', c::text)
FROM (SELECT public.get_customer(t.id('mona')) c) x;
SELECT t.expect('create: without an ID the birth date and gender may be typed',
  c->>'birth_date'='1988-03-04' AND c->>'gender'='female' AND c->'phones'='["+966501234567"]'::jsonb, c::text)
FROM (SELECT public.create_customer('{"full_name":"Tourist One","phones":["+966 50 123 4567"],"birth_date":"1988-03-04","gender":"female"}') c) x;
INSERT INTO t.ids SELECT 'arabic',(public.create_customer('{"full_name":"أحمد فاطمة","phones":["٠١٢٢٣٣٣٤٤٤٥"],"national_id":"٢٨٥٠٦١٥٢١٠٠٠٢٣"}')->>'id')::uuid;
SELECT t.expect('create: Arabic-Indic digits are stored as 0-9',
  c->'phones'='["01223334445"]'::jsonb AND c->>'national_id'='28506152100023' AND c->>'birth_date'='1985-06-15' AND c->>'gender'='female', c::text)
FROM (SELECT public.get_customer(t.id('arabic')) c) x;
SELECT t.expect('create: a business customer with a tax number',
  c->'is_business'='true'::jsonb AND c->>'tax_registration_no'='123-456-789', c::text)
FROM (SELECT public.create_customer('{"full_name":"Delta Trading LLC","phones":["0235556667"],"is_business":true,"tax_registration_no":" 123-456-789 "}') c) x;
INSERT INTO t.ids SELECT 'leap',(public.create_customer('{"full_name":"Leap Day","phones":["01000000009"],"national_id":"30002290200344","birth_date":"2000-02-29","gender":"female"}')->>'id')::uuid;
SELECT t.expect('create: a birth date and gender that agree with the ID are accepted',t.id('leap') IS NOT NULL);
SELECT t.error('create: an unknown key (credit_limit)',$q$SELECT public.create_customer('{"full_name":"X1","phones":["01000000001"],"credit_limit":"5000"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: status in the body',$q$SELECT public.create_customer('{"full_name":"X2","phones":["01000000001"],"status":"blocked"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: organization_id in the body',format('SELECT public.create_customer(%L)',jsonb_build_object('full_name','X3','phones',jsonb_build_array('01000000001'),'organization_id',t.org('b'))),'VALIDATION_FAILED');
SELECT t.error('create: no name',$q$SELECT public.create_customer('{"phones":["01000000001"]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: no phones',$q$SELECT public.create_customer('{"full_name":"X4"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an empty phone list',$q$SELECT public.create_customer('{"full_name":"X5","phones":[]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: six phones',$q$SELECT public.create_customer('{"full_name":"X6","phones":["01000000001","01000000002","01000000003","01000000004","01000000005","01000000006"]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: the same phone twice (written differently)',$q$SELECT public.create_customer('{"full_name":"X7","phones":["01000000001","+20 100 000 0001"]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a phone with letters',$q$SELECT public.create_customer('{"full_name":"X8","phones":["0100ab00001"]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a short phone',$q$SELECT public.create_customer('{"full_name":"X9","phones":["123456"]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: phones as text',$q$SELECT public.create_customer('{"full_name":"X10","phones":"01000000001"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a phone as a number',$q$SELECT public.create_customer('{"full_name":"X11","phones":[1000000001]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a one-letter name',$q$SELECT public.create_customer('{"full_name":" A ","phones":["01000000001"]}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a name over 150',format('SELECT public.create_customer(%L)',jsonb_build_object('full_name',repeat('n',151),'phones',jsonb_build_array('01000000001'))),'VALIDATION_FAILED');
SELECT t.error('create: an ID with century 4',$q$SELECT public.create_customer('{"full_name":"N1","phones":["01000000001"],"national_id":"49001010100015"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an ID born on 30 February',$q$SELECT public.create_customer('{"full_name":"N2","phones":["01000000001"],"national_id":"29002300100015"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an ID with an unknown governorate',$q$SELECT public.create_customer('{"full_name":"N3","phones":["01000000001"],"national_id":"29001019900015"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an ID of 13 digits',$q$SELECT public.create_customer('{"full_name":"N4","phones":["01000000001"],"national_id":"2900101010001"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an ID born in the future',$q$SELECT public.create_customer('{"full_name":"N5","phones":["01000000001"],"national_id":"39901010100015"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a birth date that contradicts the ID',$q$SELECT public.create_customer('{"full_name":"N6","phones":["01000000001"],"national_id":"27508201200057","birth_date":"1975-08-21"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a gender that contradicts the ID',$q$SELECT public.create_customer('{"full_name":"N7","phones":["01000000001"],"national_id":"27508201200057","gender":"female"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a typed birth date in the future',format('SELECT public.create_customer(%L)',jsonb_build_object('full_name','B1','phones',jsonb_build_array('01000000001'),'birth_date',(current_date+30)::text)),'VALIDATION_FAILED');
SELECT t.error('create: a typed birth date that is not a real day',$q$SELECT public.create_customer('{"full_name":"B2","phones":["01000000001"],"birth_date":"1990-02-30"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a birth date in another format',$q$SELECT public.create_customer('{"full_name":"B3","phones":["01000000001"],"birth_date":"01/02/1990"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an unknown gender',$q$SELECT public.create_customer('{"full_name":"B4","phones":["01000000001"],"gender":"other"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a negative income',$q$SELECT public.create_customer('{"full_name":"M1","phones":["01000000001"],"monthly_income":"-5"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an income with three decimals',$q$SELECT public.create_customer('{"full_name":"M2","phones":["01000000001"],"monthly_income":"100.125"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: an income as a number',$q$SELECT public.create_customer('{"full_name":"M3","phones":["01000000001"],"monthly_income":8500}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a business without a tax number',$q$SELECT public.create_customer('{"full_name":"T1","phones":["01000000001"],"is_business":true}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a bad tax number',$q$SELECT public.create_customer('{"full_name":"T2","phones":["01000000001"],"tax_registration_no":"12-34"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: is_business as text',$q$SELECT public.create_customer('{"full_name":"T3","phones":["01000000001"],"is_business":"true"}')$q$,'VALIDATION_FAILED');
-- Done when: duplicate national IDs are rejected.
SELECT t.error('create: a national ID another customer has (written with dashes)',$q$SELECT public.create_customer('{"full_name":"Twin","phones":["01000000002"],"national_id":"2-900101-01-00015"}')$q$,'CUSTOMER_NATIONAL_ID_TAKEN');
SELECT t.expect('create: the duplicate error names the customer who has the ID',
  d::jsonb=jsonb_build_object('customer_id',t.id('ahmed'),'full_name','Ahmed Ali Hassan'), d)
FROM (SELECT t.detail($q$SELECT public.create_customer('{"full_name":"Twin","phones":["01000000002"],"national_id":"29001010100015"}')$q$) d) x;
SELECT t.expect('create: the same phone may belong to another customer',
  public.create_customer('{"full_name":"Ahmed Brother","phones":["01001234567"]}')->>'id' IS NOT NULL);
SELECT t.expect('create: one customer.created row; the ID is never in the audit log, only its mask',
  t.audits('customer.created','ahmed')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.created' AND entity_id=t.id('ahmed')
    AND entity_type='customer' AND after->>'full_name'='Ahmed Ali Hassan' AND after->>'national_id_masked'='**********0015' AND NOT after ? 'national_id')
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND (COALESCE(before::text,'')||COALESCE(after::text,'')) LIKE '%29001010100015%'));
RESET ROLE;
SELECT t.expect('create: refused calls wrote no row',(SELECT count(*) FROM public.customers WHERE organization_id=t.org('a'))=7,
  (SELECT count(*)::text FROM public.customers WHERE organization_id=t.org('a')));
SELECT t.expect('create: created_by and updated_by are the caller',
  (SELECT c.created_by=e.id AND c.updated_by=e.id FROM public.customers c JOIN public.employees e ON e.auth_user_id='a0630000-0000-0000-8000-000000000001' WHERE c.id=t.id('ahmed')));

-- ---------------------------------------------------------------- update (owner)
SELECT t.as_user('a0630000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.update_customer(t.id('ahmed'),'{"address":"Giza","full_name":"Ahmed Ali Hassan","job":"Engineer"}');
SELECT t.expect('update: only the changed keys in before and after',
  t.audits('customer.updated','ahmed')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.updated' AND entity_id=t.id('ahmed')
    AND before='{"address":"12 Tahrir St"}'::jsonb AND after='{"address":"Giza"}'::jsonb AND severity='info'),
  (SELECT before::text||' '||after::text FROM public.audit_log WHERE action='customer.updated' AND entity_id=t.id('ahmed')));
SELECT public.update_customer(t.id('ahmed'),'{"address":" Giza ","phones":["0100 123 4567","(02) 2345-6789"],"national_id":"29001010100015"}');
SELECT t.expect('update: no actual change, no audit row',t.audits('customer.updated','ahmed')=1);
SELECT t.expect('update: optional fields emptied to null',
  c->'notes'='null'::jsonb AND c->'job'='null'::jsonb, c::text)
FROM (SELECT public.update_customer(t.id('ahmed'),'{"notes":"","job":null}') c) x;
SELECT t.expect('update: a new national ID replaces the birth date and gender',
  c->>'national_id'='29912318800011' AND c->>'national_id_masked'='**********0011' AND c->>'birth_date'='1999-12-31' AND c->>'gender'='male', c::text)
FROM (SELECT public.update_customer(t.id('ahmed'),'{"national_id":"29912318800011"}') c) x;
SELECT t.expect('update: replacing an ID is a warning; the audit row holds the masks, never a number',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.updated' AND entity_id=t.id('ahmed') AND severity='warning'
    AND before->>'national_id_masked'='**********0015' AND after->>'national_id_masked'='**********0011'
    AND after->'national_id_changed'='true'::jsonb AND before->>'birth_date'='1990-01-01' AND after->>'birth_date'='1999-12-31')
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND (COALESCE(before::text,'')||COALESCE(after::text,'')) ~ '2900101010|2991231880'));
SELECT public.update_customer(t.id('ahmed'),'{"national_id":"29001010100015"}');
SELECT t.expect('update: filling an empty ID sets the birth date and gender',
  c->>'national_id'='27508201200057' AND c->>'birth_date'='1975-08-20' AND c->>'gender'='male', c::text)
FROM (SELECT public.update_customer(t.id('mona'),'{"national_id":"27508201200057"}') c) x;
SELECT t.expect('update: filling an empty ID is audited as info with national_id_changed',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.updated' AND entity_id=t.id('mona') AND severity='info'
    AND before->'national_id_masked'='null'::jsonb AND after->>'national_id_masked'='**********0057' AND after->'national_id_changed'='true'::jsonb));
SELECT t.error('update: to another customer''s national ID',format('SELECT public.update_customer(%L,%L)',t.id('mona'),'{"national_id":"29001010100015"}'),'CUSTOMER_NATIONAL_ID_TAKEN');
SELECT t.error('update: a birth date on a customer with an ID',format('SELECT public.update_customer(%L,%L)',t.id('mona'),'{"birth_date":"1975-08-21"}'),'VALIDATION_FAILED');
SELECT t.expect('update: removing the ID keeps the birth date and gender, which can then be typed',
  c1->'national_id'='null'::jsonb AND c1->'national_id_masked'='null'::jsonb AND c1->>'birth_date'='2000-02-29' AND c1->>'gender'='female'
  AND c2->>'birth_date'='2000-03-01', c1::text)
FROM (SELECT public.update_customer(t.id('leap'),'{"national_id":null}') c1) x,
     LATERAL (SELECT public.update_customer(t.id('leap'),'{"birth_date":"2000-03-01"}') c2) y;
SELECT t.expect('update: a business flag needs the tax number in the same or an earlier change',
  public.update_customer(t.id('mona'),'{"is_business":true,"tax_registration_no":"987654321"}')->'is_business'='true'::jsonb);
SELECT t.error('update: clearing the tax number of a business',format('SELECT public.update_customer(%L,%L)',t.id('mona'),'{"tax_registration_no":null}'),'VALIDATION_FAILED');
SELECT public.update_customer(t.id('mona'),'{"is_business":false,"tax_registration_no":null}');
SELECT t.error('update: an unknown key',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"status":"blocked"}'),'VALIDATION_FAILED');
SELECT t.error('update: a bad phone',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"phones":["abc"]}'),'VALIDATION_FAILED');
SELECT t.error('update: an empty body',format('SELECT public.update_customer(%L,NULL)',t.id('ahmed')),'VALIDATION_FAILED');
SELECT t.error('update: an unknown id',format('SELECT public.update_customer(%L,%L)',gen_random_uuid(),'{"address":"x"}'),'CUSTOMER_NOT_FOUND');

-- ---------------------------------------------------------------- status (owner)
SELECT t.error('status: blocking without a reason',format('SELECT public.set_customer_status(%L,%L)',t.id('ahmed'),'blocked'),'VALIDATION_FAILED');
SELECT t.error('status: a two-letter reason',format('SELECT public.set_customer_status(%L,%L,%L)',t.id('ahmed'),'blocked','no'),'VALIDATION_FAILED');
SELECT t.error('status: a reason over 300',format('SELECT public.set_customer_status(%L,%L,%L)',t.id('ahmed'),'blocked',repeat('r',301)),'VALIDATION_FAILED');
SELECT t.error('status: watch can not be set by hand',format('SELECT public.set_customer_status(%L,%L,%L)',t.id('ahmed'),'watch','late twice'),'VALIDATION_FAILED');
SELECT t.error('status: an unknown status',format('SELECT public.set_customer_status(%L,%L,%L)',t.id('ahmed'),'deleted','x y z'),'VALIDATION_FAILED');
SELECT t.error('status: null',format('SELECT public.set_customer_status(%L,NULL)',t.id('ahmed')),'VALIDATION_FAILED');
SELECT t.expect('status: blocked with a reason',public.set_customer_status(t.id('ahmed'),'blocked','  bounced three cheques ')->>'status'='blocked');
SELECT t.expect('status: blocking is audited as a warning with the reason',
  t.audits('customer.status_set','ahmed')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.status_set' AND entity_id=t.id('ahmed')
    AND severity='warning' AND reason='bounced three cheques' AND before='{"status":"active"}'::jsonb AND after='{"status":"blocked"}'::jsonb));
SELECT public.set_customer_status(t.id('ahmed'),'blocked','again');
SELECT t.expect('status: the same status again changes nothing, no audit row',t.audits('customer.status_set','ahmed')=1);
SELECT t.expect('status: a blocked customer can still be edited',public.update_customer(t.id('ahmed'),'{"notes":"watch the cheques"}')->>'notes'='watch the cheques');
SELECT t.expect('list: the blocked filter',t.names(public.list_customers(NULL,'blocked'))='Ahmed Ali Hassan' AND (public.list_customers(NULL,'active')->>'total')::int=6);
SELECT t.expect('status: unblocked without a reason',public.set_customer_status(t.id('ahmed'),'active')->>'status'='active');
SELECT t.expect('status: unblocking is audited as info',
  t.audits('customer.status_set','ahmed')=2 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.status_set' AND entity_id=t.id('ahmed')
    AND severity='info' AND before='{"status":"blocked"}'::jsonb AND after='{"status":"active"}'::jsonb));
SELECT t.error('status: an unknown id',format('SELECT public.set_customer_status(%L,%L,%L)',gen_random_uuid(),'blocked','x y z'),'CUSTOMER_NOT_FOUND');
RESET ROLE;
-- watch is the system's status (collections); it shows, filters and can be cleared by hand.
UPDATE public.customers SET status='watch' WHERE id=t.id('mona');
-- Two ID photos, as F14's register_file stores them.
INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose,entity_type,entity_id)
SELECT t.org('a'),t.org('a')::text||'/customer_id/r01-'||n||'.jpg','image/jpeg',1000,'customer_id','customer',t.id('ahmed') FROM generate_series(1,2) n;
INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose,entity_type,entity_id)
VALUES(t.org('a'),t.org('a')::text||'/other/r01-x.jpg','image/jpeg',1000,'other','customer',t.id('ahmed'));
SELECT t.as_user('a0630000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('status: watch shows and filters',t.names(public.list_customers(NULL,'watch'))='Mona Said' AND public.get_customer(t.id('mona'))->>'status'='watch');
SELECT t.expect('status: watch can be cleared by hand',public.set_customer_status(t.id('mona'),'active')->>'status'='active');
SELECT t.expect('status: clearing watch is audited',t.audits('customer.status_set','mona')=1);
SELECT t.expect('photos: id_photos_count counts the customer_id files only',(public.get_customer(t.id('ahmed'))->>'id_photos_count')::int=2);

-- ---------------------------------------------------------------- list and search (owner: customer.view_pii)
SELECT t.expect('list: everyone, ordered by name',
  t.names(l)=U&'Ahmed Ali Hassan,Ahmed Brother,Delta Trading LLC,Leap Day,Mona Said,Tourist One,\0623\062D\0645\062F \0641\0627\0637\0645\0629' AND (l->>'total')::int=7, t.names(l))
FROM (SELECT public.list_customers() l) x;
SELECT t.expect('list: a name search ignores letter case',t.names(public.list_customers(' AHMED '))='Ahmed Ali Hassan,Ahmed Brother');
SELECT t.expect('list: an Arabic name is found with a plain alef and with haa for taa marbuta',
  (public.list_customers(U&'\0627\062D\0645\062F')->'items'->0->>'id')=t.id('arabic')::text
  AND (public.list_customers(U&'\0641\0627\0637\0645\0647')->>'total')::int=1);
SELECT t.expect('list: a phone, in part or in full, however it is written',
  t.names(public.list_customers('0100123'))='Ahmed Ali Hassan,Ahmed Brother' AND t.names(public.list_customers('+20 100 123 4567'))='Ahmed Ali Hassan,Ahmed Brother'
  AND t.names(public.list_customers('2345-6789'))='Ahmed Ali Hassan' AND t.names(public.list_customers(U&'\0660\0661\0662\0662\0663\0663\0663'))=U&'\0623\062D\0645\062F \0641\0627\0637\0645\0629');
SELECT t.expect('list: two digits are not a phone search',(public.list_customers('01')->>'total')::int=0);
SELECT t.expect('list: the whole national ID, with spaces or dashes',
  t.names(public.list_customers('29001010100015'))='Ahmed Ali Hassan' AND t.names(public.list_customers(' 2900101-0100015 '))='Ahmed Ali Hassan');
SELECT t.expect('list: with customer.view_pii a prefix of the ID finds its customers',
  t.names(public.list_customers('2900'))='Ahmed Ali Hassan' AND (public.list_customers('2')->>'total')::int=0);
SELECT t.expect('list: wildcards are literal',(public.list_customers('%')->>'total')::int=0 AND (public.list_customers('_')->>'total')::int=0);
SELECT t.expect('list: paging',
  jsonb_array_length(public.list_customers(NULL,'all',2,2)->'items')=2 AND (public.list_customers(NULL,'all',2,2)->>'total')::int=7
  AND public.list_customers(NULL,'all',2,2)->'items'->0->>'full_name'='Delta Trading LLC');
SELECT t.error('list: limit 0',$q$SELECT public.list_customers(NULL,'all',0,0)$q$,'VALIDATION_FAILED');
SELECT t.error('list: limit 101',$q$SELECT public.list_customers(NULL,'all',101,0)$q$,'VALIDATION_FAILED');
SELECT t.error('list: an unknown status',$q$SELECT public.list_customers(NULL,'archived')$q$,'VALIDATION_FAILED');
SELECT t.error('list: a search over 100',format('SELECT public.list_customers(%L)',repeat('s',101)),'VALIDATION_FAILED');
SELECT t.error('get: an unknown id',format('SELECT public.get_customer(%L)',gen_random_uuid()),'CUSTOMER_NOT_FOUND');
RESET ROLE;

-- ---------------------------------------------------------------- Done when: without customer.view_pii the IDs are masked
-- Cashier: customer.create only.
SELECT t.as_user('a0630000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier: creates a customer with an ID and gets it back masked',
  c->'national_id'='null'::jsonb AND c->>'national_id_masked'='**********0079' AND c->>'birth_date'='1992-11-05' AND c->>'gender'='male', c::text)
FROM (SELECT public.create_customer('{"full_name":"Cashier Customer","phones":["01500000001"],"national_id":"29211051300079"}') c) x;
SELECT t.expect('cashier: reads a customer with the ID masked',
  c->'national_id'='null'::jsonb AND c->>'national_id_masked'='**********0015' AND c->>'full_name'='Ahmed Ali Hassan', c::text)
FROM (SELECT public.get_customer(t.id('ahmed')) c) x;
SELECT t.expect('cashier: no full ID anywhere in the list',
  (l->>'total')::int=8 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(l->'items') i WHERE i->'national_id'<>'null'::jsonb)
  AND l::text !~ '[0-9]{14}', l::text)
FROM (SELECT public.list_customers() l) x;
SELECT t.expect('cashier: the whole ID still finds its customer (the card is in the customer''s hand), masked',
  t.names(l)='Ahmed Ali Hassan' AND l->'items'->0->'national_id'='null'::jsonb, l::text)
FROM (SELECT public.list_customers('29001010100015') l) x;
SELECT t.expect('cashier: a prefix of an ID finds nothing',(public.list_customers('2900')->>'total')::int=0 AND (public.list_customers('2900101010001')->>'total')::int=0);
SELECT t.error('cashier: a duplicate national ID is rejected',$q$SELECT public.create_customer('{"full_name":"Twin","phones":["01500000002"],"national_id":"29001010100015"}')$q$,'CUSTOMER_NATIONAL_ID_TAKEN');
SELECT t.error('cashier: no update',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"address":"C"}'),'PERMISSION_DENIED');
SELECT t.error('cashier: no block',format('SELECT public.set_customer_status(%L,%L,%L)',t.id('ahmed'),'blocked','x y z'),'PERMISSION_DENIED');
SELECT t.error('cashier: the national_id column is not readable from the table',$q$SELECT national_id FROM public.customers$q$,'permission denied for table customers');
SELECT t.error('cashier: no direct writes',format('INSERT INTO public.customers(organization_id,full_name) VALUES(%L,%L)',t.org('a'),'Direct'),'permission denied for table customers');
RESET ROLE;
-- Editor: customer.edit without customer.view_pii.
SELECT t.as_user('a0630000-0000-0000-8000-000000000007',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('editor without view_pii: edits other fields and gets the ID masked',
  c->>'city'='Alexandria' AND c->'national_id'='null'::jsonb AND c->>'national_id_masked'='**********0015', c::text)
FROM (SELECT public.update_customer(t.id('ahmed'),'{"city":"Alexandria"}') c) x;
SELECT t.error('editor without view_pii: can not replace an ID',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"national_id":"29912318800011"}'),'PERMISSION_DENIED');
SELECT t.error('editor without view_pii: can not remove an ID',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"national_id":null}'),'PERMISSION_DENIED');
SELECT t.error('editor without view_pii: the same ID is refused too (no guessing)',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"national_id":"29001010100015"}'),'PERMISSION_DENIED');
SELECT t.expect('editor without view_pii: may fill an empty ID, and gets it back masked',
  c->'national_id'='null'::jsonb AND c->>'national_id_masked'='**********0344' AND c->>'birth_date'='2000-02-29', c::text)
FROM (SELECT public.update_customer(t.id('leap'),'{"national_id":"30002290200344"}') c) x;
SELECT t.expect('editor without view_pii: blocks and unblocks',
  public.set_customer_status(t.id('leap'),'blocked','wrong papers')->>'status'='blocked' AND public.set_customer_status(t.id('leap'),'active')->>'status'='active');
RESET ROLE;
SELECT t.expect('the refused ID changes left the ID as it was',(SELECT national_id FROM public.customers WHERE id=t.id('ahmed'))='29001010100015');
-- Manager: create, edit and view_pii by role.
SELECT t.as_user('a0630000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('manager (customer.view_pii): sees the ID and may replace it',
  public.get_customer(t.id('ahmed'))->>'national_id'='29001010100015'
  AND public.update_customer(t.id('leap'),'{"national_id":"30103152700018"}')->>'national_id'='30103152700018');
RESET ROLE;
-- Collector: a read key (collection.create), no writes, no PII.
SELECT t.as_user('a0630000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('collector: reads, masked',
  (public.list_customers()->>'total')::int=8 AND public.get_customer(t.id('ahmed'))->'national_id'='null'::jsonb
  AND public.get_customer(t.id('ahmed'))->>'national_id_masked'='**********0015');
SELECT t.error('collector: no create',$q$SELECT public.create_customer('{"full_name":"C1","phones":["01500000003"]}')$q$,'PERMISSION_DENIED');
SELECT t.error('collector: no update',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"address":"C"}'),'PERMISSION_DENIED');
RESET ROLE;
-- Warehouse: none of the read keys.
SELECT t.as_user('a0630000-0000-0000-8000-000000000006',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('warehouse: no list',$q$SELECT public.list_customers()$q$,'PERMISSION_DENIED');
SELECT t.error('warehouse: no get',format('SELECT public.get_customer(%L)',t.id('ahmed')),'PERMISSION_DENIED');
SELECT t.error('warehouse: no create',$q$SELECT public.create_customer('{"full_name":"W1","phones":["01500000004"]}')$q$,'PERMISSION_DENIED');
SELECT t.as_user('a0630000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee: list',$q$SELECT public.list_customers()$q$,'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee: get',format('SELECT public.get_customer(%L)',t.id('ahmed')),'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee: create',$q$SELECT public.create_customer('{"full_name":"N1","phones":["01500000005"]}')$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;
-- A plan without the customers module.
SELECT t.as_user('a0630000-0000-0000-8000-000000000008',t.org('c'));
SET LOCAL ROLE authenticated;
SELECT t.error('starter plan: no list',$q$SELECT public.list_customers()$q$,'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no get',format('SELECT public.get_customer(%L)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no create',$q$SELECT public.create_customer('{"full_name":"S1","phones":["01500000006"]}')$q$,'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no update',format('SELECT public.update_customer(%L,%L)',gen_random_uuid(),'{"address":"x"}'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no status',format('SELECT public.set_customer_status(%L,%L)',gen_random_uuid(),'active'),'MODULE_NOT_IN_PLAN');
RESET ROLE;
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a0630000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the list and a customer still read',
  (public.list_customers()->>'total')::int=8 AND public.get_customer(t.id('ahmed'))->>'national_id'='29001010100015');
SELECT t.error('expired shop: no create',$q$SELECT public.create_customer('{"full_name":"E1","phones":["01500000007"]}')$q$,'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no update',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"address":"E"}'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no block',format('SELECT public.set_customer_status(%L,%L,%L)',t.id('ahmed'),'blocked','x y z'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ---------------------------------------------------------------- tenancy
SELECT t.as_user('a0630000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.error('shop b: get a''s customer',format('SELECT public.get_customer(%L)',t.id('ahmed')),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop b: update a''s customer',format('SELECT public.update_customer(%L,%L)',t.id('ahmed'),'{"address":"B"}'),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop b: block a''s customer',format('SELECT public.set_customer_status(%L,%L,%L)',t.id('ahmed'),'blocked','x y z'),'CUSTOMER_NOT_FOUND');
SELECT t.expect('shop b: lists none of a''s customers, not even by the whole ID; RLS hides them too',
  (public.list_customers()->>'total')::int=0 AND (public.list_customers('29001010100015')->>'total')::int=0 AND NOT EXISTS(SELECT 1 FROM public.customers));
SELECT t.expect('shop b: may register the same national ID (unique per shop)',
  public.create_customer('{"full_name":"Ahmed Ali Hassan","phones":["01001234567"],"national_id":"29001010100015"}')->>'national_id'='29001010100015');
RESET ROLE;
SELECT t.expect('shop b''s refused calls left a''s rows and audit as they were',
  (SELECT address='Giza' AND status='active' FROM public.customers WHERE id=t.id('ahmed'))
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('b') AND entity_id=t.id('ahmed')));

-- ---------------------------------------------------------------- grants
SELECT t.expect('no anon grants',
  NOT has_function_privilege('anon','public.list_customers(text,text,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_customer(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.create_customer(jsonb)','EXECUTE')
  AND NOT has_function_privilege('anon','public.update_customer(uuid,jsonb)','EXECUTE')
  AND NOT has_function_privilege('anon','public.set_customer_status(uuid,text,text)','EXECUTE'));
SELECT t.expect('authenticated runs the five functions, not the helpers',
  has_function_privilege('authenticated','public.list_customers(text,text,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_customer(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.create_customer(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.update_customer(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_customer_status(uuid,text,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.parse_national_id(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.mask_national_id(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.normalize_customer_phone(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.ascii_digits(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.search_text(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.can_read_customers()','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.customer_read_guard()','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.customer_json(uuid,uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.customer_fields_json(public.customers)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.customer_apply(public.customers,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.customer_national_id_taken(uuid,text)','EXECUTE'));
SELECT t.expect('authenticated has no column grant on customers.national_id',
  NOT has_column_privilege('authenticated','public.customers','national_id','SELECT')
  AND has_column_privilege('authenticated','public.customers','full_name','SELECT'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
