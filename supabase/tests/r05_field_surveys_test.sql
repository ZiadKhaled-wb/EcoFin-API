\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.errlike(n text,q text,p text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND SQLERRM LIKE p,SQLERRM); END; END $$;
CREATE FUNCTION t.detail(q text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d=PG_EXCEPTION_DETAIL; END; RETURN NULLIF(d,'')::jsonb; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.audits(a text,s text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action=a AND entity_id=t.id(s) $$;
-- The after of the first audit row of an action on the entity tagged s.
CREATE FUNCTION t.audit_after(a text,s text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT after FROM public.audit_log WHERE organization_id=t.org('a') AND action=a AND entity_id=t.id(s) ORDER BY created_at,id LIMIT 1 $$;
-- A customer of shop a made as the database owner.
CREATE FUNCTION t.cust(p_tag text,p_name text,p_status text DEFAULT 'active',p_archived boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,address,city,status,archived_at)
    VALUES(t.org('a'),p_name,ARRAY['01000000099'],'12 Nile St','Cairo',p_status::public.customer_status,CASE WHEN p_archived THEN now() END) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
-- A survey of shop a made as the database owner, in a given state (submitted / approved / rejected with
-- a score), decided p_days_ago days ago.
CREATE FUNCTION t.survey(p_tag text,p_customer text,p_assignee text,p_status text,p_score integer DEFAULT NULL,p_days_ago integer DEFAULT 0) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.field_surveys(organization_id,customer_id,assigned_to) VALUES(t.org('a'),t.id(p_customer),t.id(p_assignee)) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES(p_tag,v_id);
  IF p_status<>'assigned' THEN
    UPDATE public.field_surveys SET status='submitted',survey_score=p_score,submitted_at=now() WHERE id=v_id;
  END IF;
  IF p_status IN ('approved','rejected','cancelled') THEN
    UPDATE public.field_surveys SET status=p_status::public.survey_status,decided_by=t.id('owner'),
      decided_at=now()-make_interval(days=>p_days_ago) WHERE id=v_id;
  END IF;
END $$;
-- A photo of a survey, registered as the given user.
CREATE FUNCTION t.photo(p_survey text) RETURNS uuid LANGUAGE sql AS $$
  SELECT public.register_file(gen_random_uuid(),t.org('a')::text||'/surveys/'||gen_random_uuid()||'.png','visit.png','image/png',100,NULL,
                              'survey_photo','field_survey',t.id(p_survey)) $$;
-- A contract of shop a whose survey check runs now ("commit time"). A failure raises.
CREATE FUNCTION t.trg(p_tag text,p_customer text,p_financed numeric,p_migrated boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_order uuid;
BEGIN
  SET CONSTRAINTS trg_contracts_survey_check DEFERRED;
  INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,total,idempotency_key)
    VALUES(t.org('a'),'R05-SO-'||p_tag,t.id(p_customer),t.id('main'),false,p_financed+1000,p_financed+1000,'r05-so-'||p_tag) RETURNING id INTO v_order;
  INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,order_id,policy_id,creditor,cash_price,down_payment,financed_amount,
      markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,is_migrated,idempotency_key)
    VALUES(t.org('a'),'R05-C-'||p_tag,t.id(p_customer),t.id('main'),v_order,t.id('policy'),'in_house',p_financed+1000,1000,p_financed,
      0,0,p_financed,6,'monthly',current_date+30,p_migrated,'r05-c-'||p_tag);
  SET CONSTRAINTS trg_contracts_survey_check IMMEDIATE;
  SET CONSTRAINTS trg_contracts_survey_check DEFERRED;
END $$;
CREATE FUNCTION t.json(q text) RETURNS jsonb LANGUAGE plpgsql AS $$ DECLARE r jsonb; BEGIN EXECUTE q INTO r; RETURN r; END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a, b (retail), c (starter: no customers module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('R05 '||s,'r05-'||s,p,'Owner',s||'r05@example.com',NULL,'Main',h,now()+interval '1 day')
FROM (VALUES('a','retail',repeat('x',64)),('b','retail',repeat('y',64)),('c','starter',repeat('z',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0750000-0000-0000-8000-000000000001','ar05@example.com'),('a0750000-0000-0000-8000-000000000002','br05@example.com'),
  ('a0750000-0000-0000-8000-000000000003','r05cashier@example.com'),('a0750000-0000-0000-8000-000000000004','r05manager@example.com'),
  ('a0750000-0000-0000-8000-000000000005','r05collector1@example.com'),('a0750000-0000-0000-8000-000000000006','r05warehouse@example.com'),
  ('a0750000-0000-0000-8000-000000000007','r05collector2@example.com'),('a0750000-0000-0000-8000-000000000008','cr05@example.com'),
  ('a0750000-0000-0000-8000-000000000009','r05inactive@example.com');
SELECT public.accept_invite(repeat('x',64),'a0750000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a0750000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('z',64),'a0750000-0000-0000-8000-000000000008');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,is_active) VALUES
  (t.org('a'),'a0750000-0000-0000-8000-000000000003','R05 Cashier','CASHIER',true),
  (t.org('a'),'a0750000-0000-0000-8000-000000000004','R05 Manager','BRANCH_MANAGER',true),
  (t.org('a'),'a0750000-0000-0000-8000-000000000005','R05 Collector One','COLLECTOR',true),
  (t.org('a'),'a0750000-0000-0000-8000-000000000006','R05 Warehouse','WAREHOUSE',true),
  (t.org('a'),'a0750000-0000-0000-8000-000000000007','R05 Collector Two','COLLECTOR',true),
  (t.org('a'),'a0750000-0000-0000-8000-000000000009','R05 Inactive Collector','COLLECTOR',false);
INSERT INTO t.ids SELECT CASE auth_user_id
    WHEN 'a0750000-0000-0000-8000-000000000001' THEN 'owner' WHEN 'a0750000-0000-0000-8000-000000000003' THEN 'cashier'
    WHEN 'a0750000-0000-0000-8000-000000000004' THEN 'manager' WHEN 'a0750000-0000-0000-8000-000000000005' THEN 'col1'
    WHEN 'a0750000-0000-0000-8000-000000000006' THEN 'warehouse' WHEN 'a0750000-0000-0000-8000-000000000007' THEN 'col2'
    WHEN 'a0750000-0000-0000-8000-000000000009' THEN 'inactive' END, id
  FROM public.employees WHERE organization_id=t.org('a');
INSERT INTO t.ids SELECT 'owner-b',id FROM public.employees WHERE organization_id=t.org('b');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1;
WITH x AS (INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('b'),'Shop B Customer') RETURNING id) INSERT INTO t.ids SELECT 'cust-b',id FROM x;
SELECT t.cust('c1','Survey Customer One');
SELECT t.cust('c2','Survey Customer Two');
SELECT t.cust('cwatch','Watch Customer','watch');
SELECT t.cust('cblocked','Blocked Customer','blocked');
SELECT t.cust('carchived','Archived Customer','active',true);
SELECT t.cust('cmgr','Manager Survey Customer');
SELECT t.cust('cown','Owner Survey Customer');
SELECT t.cust('cnone','No Survey Customer');
SELECT t.cust('crej','Rejected Survey Customer');
SELECT t.cust('cold','Old Survey Customer');
SELECT t.cust('csub','Submitted Survey Customer');
SELECT t.survey('s-rej','crej','col1','rejected',40,3);
SELECT t.survey('s-old','cold','col1','approved',90,181);
SELECT t.survey('s-sub','csub','col1','submitted',60);
-- The policy the contracts use: a survey above 20 000 financed (version after any bootstrap one).
WITH x AS (INSERT INTO public.installment_policies(organization_id,version,max_months,markup_tiers,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,12,'[{"pct":0,"up_to_months":12}]',20000 FROM public.installment_policies WHERE organization_id=t.org('a') RETURNING id)
INSERT INTO t.ids SELECT 'policy',id FROM x;
WITH x AS (INSERT INTO public.installment_policies(organization_id,version,max_months,markup_tiers,survey_required_above,effective_from)
  SELECT t.org('a'),COALESCE(max(version),0)+1,12,'[{"pct":0,"up_to_months":12}]',NULL,now()+interval '1 year' FROM public.installment_policies WHERE organization_id=t.org('a') RETURNING id)
INSERT INTO t.ids SELECT 'policy-null',id FROM x;

-- ================================================================ schema and helpers (as the database owner)
SELECT t.expect('schema: the seven columns exist with their checks',
  (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='field_surveys'
     AND column_name IN ('visit_type','checklist','due_date','instructions','survey_score','decision_note','client_captured_at'))=7);
SELECT t.errlike('schema: a visit type outside home / work is refused',format($q$UPDATE public.field_surveys SET visit_type='car' WHERE id=%L$q$,t.id('s-sub')),'%check%');
SELECT t.errlike('schema: a score above 100 is refused',format($q$UPDATE public.field_surveys SET survey_score=101 WHERE id=%L$q$,t.id('s-sub')),'%check%');
SELECT t.errlike('schema: surveys are never deleted',format('DELETE FROM public.field_surveys WHERE id=%L',t.id('s-sub')),'%');
SELECT t.expect('helpers: validity is 180 days',app.survey_valid_days()=180);
SELECT t.expect('employee_can: a collector has survey.submit, a cashier not, an inactive one not, another shop''s not',
  app.employee_can(t.org('a'),t.id('col1'),'survey.submit') AND NOT app.employee_can(t.org('a'),t.id('cashier'),'survey.submit')
  AND NOT app.employee_can(t.org('a'),t.id('inactive'),'survey.submit') AND NOT app.employee_can(t.org('a'),t.id('owner-b'),'survey.submit')
  AND app.employee_can(t.org('a'),t.id('owner'),'survey.submit'));

-- ================================================================ assign (owner)
SELECT t.as_user('a0750000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 's1',(s->>'id')::uuid FROM (SELECT public.assign_field_survey(jsonb_build_object(
  'customer_id',t.id('c1'),'assigned_to',t.id('col1'),'visit_type','work','due_date',(current_date+3)::text,'instructions','  Ask for the electricity bill  ')) s) x;
SELECT t.expect('assign: assigned to the collector, with the visit type, due date and trimmed instructions',
  s->>'status'='assigned' AND s->>'visit_type'='work' AND s->'assigned_to'->>'id'=t.id('col1')::text AND s->>'instructions'='Ask for the electricity bill'
  AND s->'customer'->>'full_name'='Survey Customer One' AND s->'customer'->>'city'='Cairo' AND s->'scores'='{}'::jsonb AND s->'gps'='null'::jsonb
  AND (s->>'photos_count')::int=0 AND s->'created_by'->>'id'=t.id('owner')::text AND s->'valid_until'='null'::jsonb,s::text)
FROM (SELECT public.get_field_survey(t.id('s1')) s) x;
SELECT t.error('photos: another purpose on a survey (the owner, who may upload ID photos)',format($q$SELECT public.register_file(gen_random_uuid(),%L,'p.png','image/png',10,NULL,'customer_id','field_survey',%L)$q$,t.org('a')::text||'/x/'||gen_random_uuid()||'.png',t.id('s1')),'VALIDATION_FAILED');
SELECT t.error('assign: a second open survey for the customer',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c1'),'assigned_to',t.id('col2'))),'SURVEY_ALREADY_OPEN');
SELECT t.expect('assign: the open survey is named in the details',
  t.detail(format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c1'),'assigned_to',t.id('col2'))))
  =jsonb_build_object('survey_id',t.id('s1'),'status','assigned'));
SELECT t.error('assign: a submitted survey is open too',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('csub'),'assigned_to',t.id('col2'))),'SURVEY_ALREADY_OPEN');
SELECT t.error('assign: a cashier can''t be the assignee',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('cashier'))),'SURVEY_ASSIGNEE_INVALID');
SELECT t.expect('assign: the refused assignee is in the details',
  t.detail(format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('cashier'))))=jsonb_build_object('employee_id',t.id('cashier')));
SELECT t.error('assign: an inactive employee',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('inactive'))),'SURVEY_ASSIGNEE_INVALID');
SELECT t.error('assign: shop B''s employee',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('owner-b'))),'SURVEY_ASSIGNEE_INVALID');
SELECT t.error('assign: a blocked customer',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cblocked'),'assigned_to',t.id('col1'))),'CUSTOMER_BLOCKED');
SELECT t.error('assign: an archived customer',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('carchived'),'assigned_to',t.id('col1'))),'CUSTOMER_BLOCKED');
SELECT t.error('assign: shop B''s customer',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cust-b'),'assigned_to',t.id('col1'))),'CUSTOMER_NOT_FOUND');
SELECT t.error('assign: an unknown customer',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',gen_random_uuid(),'assigned_to',t.id('col1'))),'CUSTOMER_NOT_FOUND');
SELECT t.error('assign: a due date in the past',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('col1'),'due_date',(current_date-5)::text)),'VALIDATION_FAILED');
SELECT t.error('assign: an unknown key',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('col1'),'organization_id',t.org('b'))),'VALIDATION_FAILED');
SELECT t.error('assign: a bad visit type',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('col1'),'visit_type','car')),'VALIDATION_FAILED');
SELECT t.error('assign: instructions over 500',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('col1'),'instructions',repeat('i',501))),'VALIDATION_FAILED');
SELECT t.error('assign: no assignee',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('c2'))),'VALIDATION_FAILED');
INSERT INTO t.ids SELECT 's2',(public.assign_field_survey(jsonb_build_object('customer_id',t.id('c2'),'assigned_to',t.id('col2')))->>'id')::uuid;
INSERT INTO t.ids SELECT 'swatch',(public.assign_field_survey(jsonb_build_object('customer_id',t.id('cwatch'),'assigned_to',t.id('col1')))->>'id')::uuid;
INSERT INTO t.ids SELECT 'smgr',(public.assign_field_survey(jsonb_build_object('customer_id',t.id('cmgr'),'assigned_to',t.id('manager')))->>'id')::uuid;
INSERT INTO t.ids SELECT 'sown',(public.assign_field_survey(jsonb_build_object('customer_id',t.id('cown'),'assigned_to',t.id('owner')))->>'id')::uuid;
SELECT t.expect('assign: a watch customer can be surveyed; the visit type defaults to home',
  (SELECT s->>'visit_type'='home' AND s->>'status'='assigned' FROM (SELECT public.get_field_survey(t.id('swatch')) s) x));
SELECT t.expect('reads: the owner sees every survey; the review queue (submitted) comes first',
  (l->>'total')::int>=6 AND l->'items'->0->>'status'='submitted',l::text) FROM (SELECT public.list_field_surveys() l) x;
SELECT t.expect('reads: filters by status, customer and assignee; mine = the caller''s own',
  (public.list_field_surveys('assigned',t.id('c1'))->>'total')::int=1
  AND (public.list_field_surveys(NULL,NULL,t.id('col2'))->>'total')::int=1
  AND (public.list_field_surveys(NULL,NULL,NULL,true)->>'total')::int=1);
SELECT t.error('reads: a bad status filter',$$SELECT public.list_field_surveys('done')$$,'VALIDATION_FAILED');
SELECT t.error('reads: a page over 100',$$SELECT public.list_field_surveys(NULL,NULL,NULL,false,101,0)$$,'VALIDATION_FAILED');
RESET ROLE;

-- ================================================================ reassign and cancel (manager)
SELECT t.as_user('a0750000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('reassign: to the same assignee is no change and writes nothing',
  (public.reassign_field_survey(t.id('s2'),t.id('col2'))->'assigned_to'->>'id')=t.id('col2')::text AND t.audits('survey.reassigned','s2')=0);
SELECT t.error('reassign: to a cashier',format('SELECT public.reassign_field_survey(%L,%L)',t.id('s2'),t.id('cashier')),'SURVEY_ASSIGNEE_INVALID');
SELECT t.error('reassign: a submitted survey',format('SELECT public.reassign_field_survey(%L,%L)',t.id('s-sub'),t.id('col2')),'SURVEY_WRONG_STATUS');
SELECT t.error('cancel: a reason is required',format('SELECT public.cancel_field_survey(%L,%L)',t.id('swatch'),'  '),'VALIDATION_FAILED');
SELECT t.error('cancel: a reason over 300',format('SELECT public.cancel_field_survey(%L,%L)',t.id('swatch'),repeat('r',301)),'VALIDATION_FAILED');
SELECT t.expect('cancel: an assigned survey is cancelled with the reason in decision_note',
  s->>'status'='cancelled' AND s->>'decision_note'='Customer moved',s::text) FROM (SELECT public.cancel_field_survey(t.id('swatch'),' Customer moved ') s) x;
SELECT t.error('cancel: a cancelled survey can''t be cancelled again',format('SELECT public.cancel_field_survey(%L,%L)',t.id('swatch'),'Again'),'SURVEY_WRONG_STATUS');
SELECT t.error('cancel: an approved survey',format('SELECT public.cancel_field_survey(%L,%L)',t.id('s-old'),'Too old'),'SURVEY_WRONG_STATUS');
SELECT t.error('save: the manager (survey.submit) is not the assignee of s1',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"notes":"x"}'),'SURVEY_NOT_ASSIGNEE');
RESET ROLE;

-- ================================================================ fill (collector one)
SELECT t.as_user('a0750000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('reads: a collector sees only their own surveys',
  (SELECT bool_and(i->'assigned_to'->>'id'=t.id('col1')::text) FROM jsonb_array_elements(public.list_field_surveys(NULL,NULL,NULL,false,100,0)->'items') i)
  AND (public.list_field_surveys(NULL,NULL,t.id('col2'))->>'total')::int=0);
SELECT t.error('reads: another collector''s survey is not found',format('SELECT public.get_field_survey(%L)',t.id('s2')),'SURVEY_NOT_FOUND');
SELECT t.expect('reads: the customer''s list holds only the collector''s own surveys',
  jsonb_array_length(public.list_customer_surveys(t.id('c2')))=0 AND jsonb_array_length(public.list_customer_surveys(t.id('c1')))=1);
SELECT t.expect('save: partial scores and checklist are kept',
  s->'scores'='{"housing_quality":8}'::jsonb AND s->'checklist'='{"met_customer":true}'::jsonb,s::text)
FROM (SELECT public.save_field_survey(t.id('s1'),'{"scores":{"housing_quality":8},"checklist":{"met_customer":true}}') s) x;
SELECT t.expect('save: one audit row with the changed keys',t.audits('survey.saved','s1')=1
  AND t.audit_after('survey.saved','s1') ? 'scores' AND t.audit_after('survey.saved','s1') ? 'checklist'
  AND NOT t.audit_after('survey.saved','s1') ? 'notes');
SELECT public.save_field_survey(t.id('s1'),'{"scores":{"housing_quality":8}}');
SELECT t.expect('save: the same values again write no audit row',t.audits('survey.saved','s1')=1);
SELECT t.expect('save: answers merge; null removes a key',
  s->'scores'='{"neighbourhood":7}'::jsonb AND s->>'notes'='Clean flat',s::text)
FROM (SELECT public.save_field_survey(t.id('s1'),'{"scores":{"housing_quality":null,"neighbourhood":7},"notes":"  Clean flat "}') s) x;
SELECT t.error('save: a score of 0',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"scores":{"job_status":0}}'),'VALIDATION_FAILED');
SELECT t.error('save: a score of 11',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"scores":{"job_status":11}}'),'VALIDATION_FAILED');
SELECT t.error('save: a score of 7.5',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"scores":{"job_status":7.5}}'),'VALIDATION_FAILED');
SELECT t.error('save: a score as text',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"scores":{"job_status":"7"}}'),'VALIDATION_FAILED');
SELECT t.error('save: an unknown criterion',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"scores":{"car":5}}'),'VALIDATION_FAILED');
SELECT t.error('save: an unknown checklist item',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"checklist":{"dog":true}}'),'VALIDATION_FAILED');
SELECT t.error('save: a checklist answer that is not yes/no',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"checklist":{"met_customer":"yes"}}'),'VALIDATION_FAILED');
SELECT t.error('save: half a GPS fix',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"gps":{"lat":30.04,"lng":31.23}}'),'VALIDATION_FAILED');
SELECT t.error('save: a latitude of 91',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),jsonb_build_object('gps',jsonb_build_object('lat',91,'lng',31,'gps_accuracy_m',5,'client_captured_at',now()))),'VALIDATION_FAILED');
SELECT t.error('save: a capture time an hour in the future',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),jsonb_build_object('gps',jsonb_build_object('lat',30,'lng',31,'gps_accuracy_m',5,'client_captured_at',now()+interval '1 hour'))),'VALIDATION_FAILED');
SELECT t.error('save: a capture time before the survey',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),jsonb_build_object('gps',jsonb_build_object('lat',30,'lng',31,'gps_accuracy_m',5,'client_captured_at',now()-interval '1 day'))),'VALIDATION_FAILED');
SELECT t.error('save: notes over 2000',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),jsonb_build_object('notes',repeat('n',2001))),'VALIDATION_FAILED');
SELECT t.error('save: an unknown key',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"status":"approved"}'),'VALIDATION_FAILED');
SELECT t.error('save: an empty body',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{}'),'VALIDATION_FAILED');
SELECT t.error('submit: missing criteria',format('SELECT public.submit_field_survey(%L,%L)',t.id('s1'),'{}'),'VALIDATION_FAILED');
SELECT t.error('submit: complete answers but no photo',format('SELECT public.submit_field_survey(%L,%L)',t.id('s1'),
  jsonb_build_object('scores',jsonb_build_object('housing_quality',8,'neighbourhood',7,'income_stability',6,'job_status',9,'property_ownership',5,'overall_impression',7),
    'checklist',jsonb_build_object('met_customer',true,'address_matches',true,'id_original_seen',true,'neighbours_confirm',false,'utility_bill_seen',true,'workplace_confirmed',true),
    'gps',jsonb_build_object('lat',30.0444196,'lng',31.2357116,'gps_accuracy_m',150,'client_captured_at',now()))),'SURVEY_PHOTO_REQUIRED');
INSERT INTO t.ids SELECT 'photo1',t.photo('s1');
SELECT t.error('photos: survey_photo without its survey',format($q$SELECT public.register_file(gen_random_uuid(),%L,'p.png','image/png',10,NULL,'survey_photo','customer',%L)$q$,t.org('a')::text||'/x/'||gen_random_uuid()||'.png',t.id('c1')),'VALIDATION_FAILED');
SELECT t.error('photos: another assignee''s survey',format('SELECT t.photo(%L)','s2'),'SURVEY_NOT_ASSIGNEE');
SELECT t.photo('s1') FROM generate_series(1,9);
SELECT t.error('photos: an eleventh photo',format('SELECT t.photo(%L)','s1'),'VALIDATION_FAILED');
SELECT t.expect('submit: the score is the average x 10 (8,7,6,9,5,7 = 70); low accuracy flagged; 10 photos',
  s->>'status'='submitted' AND (s->>'survey_score')::int=70 AND (s->>'gps_low_accuracy')::boolean AND (s->>'photos_count')::int=10
  AND s->'gps'->>'gps_accuracy_m'='150.00' AND s->>'notes'='Clean flat' AND s->>'submitted_at' IS NOT NULL,s::text)
FROM (SELECT public.submit_field_survey(t.id('s1'),
  jsonb_build_object('scores',jsonb_build_object('housing_quality',8,'neighbourhood',7,'income_stability',6,'job_status',9,'property_ownership',5,'overall_impression',7),
    'checklist',jsonb_build_object('met_customer',true,'address_matches',true,'id_original_seen',true,'neighbours_confirm',false,'utility_bill_seen',true,'workplace_confirmed',true),
    'gps',jsonb_build_object('lat',30.0444196,'lng',31.2357116,'gps_accuracy_m',150,'client_captured_at',now()))) s) x;
SELECT t.error('submit: again',format('SELECT public.submit_field_survey(%L,%L)',t.id('s1'),'{}'),'SURVEY_WRONG_STATUS');
SELECT t.error('save: after submit',format('SELECT public.save_field_survey(%L,%L)',t.id('s1'),'{"notes":"late"}'),'SURVEY_WRONG_STATUS');
SELECT t.error('photos: after submit',format('SELECT t.photo(%L)','s1'),'SURVEY_WRONG_STATUS');
SELECT t.error('decide: a collector has no survey.decide',format('SELECT public.decide_field_survey(%L,%L)',t.id('s1'),'approve'),'PERMISSION_DENIED');
SELECT t.error('assign: a collector has no survey.assign',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cnone'),'assigned_to',t.id('col1'))),'PERMISSION_DENIED');
SELECT t.errlike('grants: no direct writes on field_surveys',format($q$UPDATE public.field_surveys SET status='approved' WHERE id=%L$q$,t.id('s1')),'permission denied%');
SELECT t.errlike('grants: no direct inserts on field_surveys',format($q$INSERT INTO public.field_surveys(organization_id,customer_id,assigned_to) VALUES(%L,%L,%L)$q$,t.org('a'),t.id('c1'),t.id('col1')),'permission denied%');
RESET ROLE;
SELECT t.expect('photos: the assignee''s upload sits in the private bucket',
  (SELECT bucket='tenant-files' AND purpose='survey_photo' AND entity_type='field_survey' AND created_by=t.id('col1') FROM public.files WHERE id=t.id('photo1')));
SELECT t.as_user('a0750000-0000-0000-8000-000000000007',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('save: another collector gets not found (they can''t see it)',format('SELECT public.save_field_survey(%L,%L)',t.id('swatch'),'{"notes":"x"}'),'SURVEY_NOT_FOUND');
RESET ROLE;

-- ================================================================ decide (manager) and the credit score
SELECT t.expect('credit: before approval the residence part is 0',
  (SELECT (c->>'value')::numeric=0 FROM jsonb_array_elements(app.customer_credit_score(t.org('a'),t.id('c1'))->'components') c WHERE c->>'key'='residence'));
SELECT t.as_user('a0750000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('decide: a rejection needs a note',format('SELECT public.decide_field_survey(%L,%L,%L)',t.id('s1'),'reject','no'),'VALIDATION_FAILED');
SELECT t.error('decide: an unknown decision',format('SELECT public.decide_field_survey(%L,%L)',t.id('s1'),'maybe'),'VALIDATION_FAILED');
SELECT t.error('decide: an assigned survey',format('SELECT public.decide_field_survey(%L,%L)',t.id('s2'),'approve'),'SURVEY_WRONG_STATUS');
SELECT t.expect('decide: the manager approves; valid for 180 days',
  s->>'status'='approved' AND s->'decided_by'->>'id'=t.id('manager')::text AND s->>'decision_note'='Looks fine'
  AND (s->>'valid_until')::date BETWEEN current_date+179 AND current_date+181,s::text)
FROM (SELECT public.decide_field_survey(t.id('s1'),'approve','Looks fine') s) x;
SELECT t.error('decide: twice',format('SELECT public.decide_field_survey(%L,%L,%L)',t.id('s1'),'reject','Changed my mind'),'SURVEY_WRONG_STATUS');
SELECT t.expect('credit: the profile names the latest survey',
  p->'latest_survey'->>'id'=t.id('s1')::text AND p->'latest_survey'->>'status'='approved' AND (p->'latest_survey'->>'survey_score')::int=70,p::text)
FROM (SELECT public.get_customer_credit_profile(t.id('c1')) p) x;
RESET ROLE;
UPDATE public.field_surveys SET status='submitted',survey_score=50,submitted_at=now() WHERE id IN (t.id('smgr'),t.id('sown'));
SELECT t.as_user('a0750000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('decide: the manager can''t decide their own survey',format('SELECT public.decide_field_survey(%L,%L)',t.id('smgr'),'approve'),'SURVEY_SELF_DECISION');
SELECT t.expect('decide: a rejection with a note',(public.decide_field_survey(t.id('sown'),'reject','Address is a shop')->>'status')='rejected');
RESET ROLE;
SELECT t.as_user('a0750000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('decide: the owner may decide a survey assigned to the manager',(public.decide_field_survey(t.id('smgr'),'approve')->>'status')='approved');
RESET ROLE;
SELECT t.error('freeze: a decided survey can''t change, even as the database owner',format($q$UPDATE public.field_surveys SET notes='x' WHERE id=%L$q$,t.id('s1')),'DOCUMENT_FINAL');
SELECT t.expect('credit: residence = 0.70 x weight 20 = 14 points',
  (SELECT (c->>'value')::numeric=0.70 AND (c->>'points')::numeric=14 FROM jsonb_array_elements(app.customer_credit_score(t.org('a'),t.id('c1'))->'components') c WHERE c->>'key'='residence'));
SELECT t.expect('credit: a survey approved 181 days ago counts 0',
  (SELECT (c->>'value')::numeric=0 FROM jsonb_array_elements(app.customer_credit_score(t.org('a'),t.id('cold'))->'components') c WHERE c->>'key'='residence'));
SELECT t.expect('credit: a rejected survey counts 0',
  (SELECT (c->>'value')::numeric=0 FROM jsonb_array_elements(app.customer_credit_score(t.org('a'),t.id('crej'))->'components') c WHERE c->>'key'='residence'));

-- ================================================================ contract rule (as the database owner)
SELECT t.expect('required: financed 20 000.00 is not above the amount',NOT app.survey_required(t.org('a'),t.id('policy'),20000.00));
SELECT t.expect('required: 20 000.01 is',app.survey_required(t.org('a'),t.id('policy'),20000.01));
SELECT t.expect('required: a policy without the amount never',NOT app.survey_required(t.org('a'),t.id('policy-null'),999999));
SELECT t.expect('required: another shop''s policy id never',NOT app.survey_required(t.org('b'),t.id('policy'),999999));
SELECT t.expect('check: not required gives null',app.check_contract_survey(t.org('a'),t.id('cnone'),t.id('policy'),15000) IS NULL);
SELECT t.error('check: no survey at all',format('SELECT app.check_contract_survey(%L,%L,%L,25000)',t.org('a'),t.id('cnone'),t.id('policy')),'SURVEY_REQUIRED');
SELECT t.expect('check: the details for no survey',
  t.detail(format('SELECT app.check_contract_survey(%L,%L,%L,25000)',t.org('a'),t.id('cnone'),t.id('policy')))
  =jsonb_build_object('required_above','20000.00','financed_amount','25000.00','open_survey_id',NULL,'open_status',NULL,'last_decided_status',NULL));
SELECT t.expect('check: a submitted survey is named as the open one',
  (d->>'open_survey_id')=t.id('s-sub')::text AND d->>'open_status'='submitted',d::text)
FROM (SELECT t.detail(format('SELECT app.check_contract_survey(%L,%L,%L,25000)',t.org('a'),t.id('csub'),t.id('policy'))) d) x;
SELECT t.expect('check: a rejected one is the last decision',d->>'last_decided_status'='rejected',d::text)
FROM (SELECT t.detail(format('SELECT app.check_contract_survey(%L,%L,%L,25000)',t.org('a'),t.id('crej'),t.id('policy'))) d) x;
SELECT t.error('check: an approval older than 180 days',format('SELECT app.check_contract_survey(%L,%L,%L,25000)',t.org('a'),t.id('cold'),t.id('policy')),'SURVEY_REQUIRED');
SELECT t.expect('check: a valid approved survey is returned',app.check_contract_survey(t.org('a'),t.id('c1'),t.id('policy'),25000)=t.id('s1'));
SELECT t.error('check: another customer''s approved survey doesn''t count',format('SELECT app.check_contract_survey(%L,%L,%L,25000)',t.org('a'),t.id('c2'),t.id('policy')),'SURVEY_REQUIRED');
SELECT t.error('trigger: 25 000 financed without an approved survey fails at commit',$$SELECT t.trg('t1','cnone',25000,false)$$,'SURVEY_REQUIRED');
SELECT t.expect('trigger: the refused contract is gone',NOT EXISTS(SELECT 1 FROM public.contracts WHERE number='R05-C-t1'));
SELECT t.trg('t2','c1',25000,false);
SELECT t.expect('trigger: with a valid approved survey it commits',EXISTS(SELECT 1 FROM public.contracts WHERE number='R05-C-t2'));
SELECT t.trg('t3','cnone',15000,false);
SELECT t.expect('trigger: 15 000 needs no survey',EXISTS(SELECT 1 FROM public.contracts WHERE number='R05-C-t3'));
SELECT t.trg('t4','cnone',25000,true);
SELECT t.expect('trigger: a migrated contract is exempt',EXISTS(SELECT 1 FROM public.contracts WHERE number='R05-C-t4'));

-- ================================================================ requirement read
SELECT t.as_user('a0750000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('requirement: c1 at 25 000 is required and met by s1',
  r->>'required'='true' AND r->>'met'='true' AND r->'valid_survey'->>'id'=t.id('s1')::text AND r->>'required_above'='20000.00'
  AND r->>'policy_id'=t.id('policy')::text AND r->'open_survey'='null'::jsonb,r::text)
FROM (SELECT public.get_survey_requirement(t.id('c1'),'25000.00') r) x;
SELECT t.expect('requirement: a submitted survey is open but not met',
  r->>'required'='true' AND r->>'met'='false' AND r->'open_survey'->>'status'='submitted',r::text)
FROM (SELECT public.get_survey_requirement(t.id('csub'),'25000') r) x;
SELECT t.expect('requirement: below the amount it is met without a survey',
  (public.get_survey_requirement(t.id('cnone'),'100.00')->>'met')='true' AND (public.get_survey_requirement(t.id('cnone'),'100.00')->>'required')='false');
SELECT t.error('requirement: a bad amount',format('SELECT public.get_survey_requirement(%L,%L)',t.id('c1'),'-1'),'VALIDATION_FAILED');
SELECT t.error('requirement: shop B''s customer',format('SELECT public.get_survey_requirement(%L,%L)',t.id('cust-b'),'1.00'),'CUSTOMER_NOT_FOUND');
-- who: the cashier reads (customer.create) but can't assign, fill or decide
SELECT t.expect('who: a cashier reads every survey',(public.list_field_surveys()->>'total')::int>=6);
SELECT t.error('who: a cashier can''t assign',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cnone'),'assigned_to',t.id('col1'))),'PERMISSION_DENIED');
SELECT t.error('who: a cashier can''t save',format('SELECT public.save_field_survey(%L,%L)',t.id('s2'),'{"notes":"x"}'),'PERMISSION_DENIED');
SELECT t.error('who: a cashier can''t decide',format('SELECT public.decide_field_survey(%L,%L)',t.id('s-sub'),'approve'),'PERMISSION_DENIED');
SELECT t.error('who: a cashier can''t cancel',format('SELECT public.cancel_field_survey(%L,%L)',t.id('s2'),'No way'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0750000-0000-0000-8000-000000000006',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('who: a warehouse user can''t read',$$SELECT public.list_field_surveys()$$,'PERMISSION_DENIED');
SELECT t.error('who: a warehouse user can''t get one',format('SELECT public.get_field_survey(%L)',t.id('s1')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0750000-0000-0000-8000-0000000000ff',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('who: not an employee',$$SELECT public.list_field_surveys()$$,'NOT_AN_EMPLOYEE');
SELECT t.error('who: not an employee can''t assign',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cnone'),'assigned_to',t.id('col1'))),'NOT_AN_EMPLOYEE');
RESET ROLE;

-- ================================================================ tenancy: shop B's owner
SELECT t.as_user('a0750000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.expect('tenancy: shop B lists none of shop A''s surveys',(public.list_field_surveys()->>'total')::int=0);
SELECT t.error('tenancy: get',format('SELECT public.get_field_survey(%L)',t.id('s1')),'SURVEY_NOT_FOUND');
SELECT t.error('tenancy: customer list',format('SELECT public.list_customer_surveys(%L)',t.id('c1')),'CUSTOMER_NOT_FOUND');
SELECT t.error('tenancy: reassign',format('SELECT public.reassign_field_survey(%L,%L)',t.id('s2'),t.id('owner-b')),'SURVEY_NOT_FOUND');
SELECT t.error('tenancy: cancel',format('SELECT public.cancel_field_survey(%L,%L)',t.id('s2'),'Foreign'),'SURVEY_NOT_FOUND');
SELECT t.error('tenancy: save',format('SELECT public.save_field_survey(%L,%L)',t.id('s2'),'{"notes":"x"}'),'SURVEY_NOT_FOUND');
SELECT t.error('tenancy: submit',format('SELECT public.submit_field_survey(%L,%L)',t.id('s2'),'{}'),'SURVEY_NOT_FOUND');
SELECT t.error('tenancy: decide',format('SELECT public.decide_field_survey(%L,%L)',t.id('s-sub'),'approve'),'SURVEY_NOT_FOUND');
SELECT t.error('tenancy: assign shop A''s customer',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cnone'),'assigned_to',t.id('owner-b'))),'CUSTOMER_NOT_FOUND');
SELECT t.error('tenancy: assign to shop A''s collector',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cust-b'),'assigned_to',t.id('col1'))),'SURVEY_ASSIGNEE_INVALID');
SELECT t.error('tenancy: a photo on shop A''s survey',format($q$SELECT public.register_file(gen_random_uuid(),%L,'p.png','image/png',10,NULL,'survey_photo','field_survey',%L)$q$,t.org('b')::text||'/x/'||gen_random_uuid()||'.png',t.id('s2')),'NOT_FOUND');
SELECT t.expect('tenancy: the table shows shop B nothing of shop A',(SELECT count(*) FROM public.field_surveys WHERE organization_id=t.org('a'))=0);
RESET ROLE;

-- ================================================================ plan and expired shop
SELECT t.as_user('a0750000-0000-0000-8000-000000000008',t.org('c'));
SET LOCAL ROLE authenticated;
SELECT t.error('starter plan: no list',$$SELECT public.list_field_surveys()$$,'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no assign',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',gen_random_uuid(),'assigned_to',gen_random_uuid())),'MODULE_NOT_IN_PLAN');
RESET ROLE;
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a0750000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: still reads',(public.get_field_survey(t.id('s1'))->>'status')='approved' AND (public.list_field_surveys()->>'total')::int>=6);
SELECT t.error('expired shop: no assign',format('SELECT public.assign_field_survey(%L)',jsonb_build_object('customer_id',t.id('cnone'),'assigned_to',t.id('col1'))),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no cancel',format('SELECT public.cancel_field_survey(%L,%L)',t.id('s2'),'Expired'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ================================================================ grants and audit
SELECT t.expect('grants: exactly the ten public functions are executable by authenticated and none by anon',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
     AND p.proname IN ('list_field_surveys','get_field_survey','list_customer_surveys','get_survey_requirement','assign_field_survey',
                       'reassign_field_survey','cancel_field_survey','save_field_survey','submit_field_survey','decide_field_survey')
     AND has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE'))=10);
SELECT t.expect('grants: no app function of R05 is executable by authenticated or anon',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='app'
     AND p.proname IN ('survey_valid_days','survey_criteria','survey_checklist_items','employee_can','survey_sees_all','survey_valid_until',
                       'field_survey_json','survey_merge_scores','survey_merge_checklist','survey_apply_answers','survey_answers_json',
                       'survey_for_caller','survey_check_assignee','survey_required','latest_valid_survey','check_contract_survey','contracts_survey_check')
     AND (has_function_privilege('authenticated',p.oid,'EXECUTE') OR has_function_privilege('anon',p.oid,'EXECUTE')))=0);
SELECT t.expect('audit: one row per action, entity type field_survey',
  t.audits('survey.assigned','s1')=1 AND t.audits('survey.submitted','s1')=1 AND t.audits('survey.approved','s1')=1
  AND t.audits('survey.saved','s1')=2 AND t.audits('survey.cancelled','swatch')=1 AND t.audits('survey.rejected','sown')=1
  AND (SELECT bool_and(entity_type='field_survey') FROM public.audit_log WHERE organization_id=t.org('a') AND action LIKE 'survey.%'));
SELECT t.expect('audit: the cancel is a warning with its reason; the submit holds the score',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='survey.cancelled' AND entity_id=t.id('swatch') AND severity='warning' AND reason='Customer moved')
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='survey.submitted' AND entity_id=t.id('s1') AND (after->>'survey_score')::int=70));
SELECT t.expect('audit: no survey audit row holds the GPS point',
  NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND action LIKE 'survey.%'
    AND (COALESCE(before::text,'')||COALESCE(after::text,'')) LIKE '%30.04%'));
SELECT t.expect('audit: the refused calls wrote nothing (s2 has only its assignment)',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND entity_id=t.id('s2'))=1);

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
