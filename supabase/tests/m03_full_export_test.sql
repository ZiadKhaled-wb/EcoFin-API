-- M03 full export (EC-102, D86).
-- Run by: node scripts/db-smoke.mjs supabase/tests/m03_full_export_test.sql (inside BEGIN ... ROLLBACK).
-- Every tenant table is exported or excluded with a reason; no secret column leaks; masked vs full
-- national IDs; keyset paging returns every row once in key order (also for composite keys); another
-- shop's job or table is refused; one running export per shop; too soon; permissions (an expired shop
-- can export, a suspended one can't); complete / fail / cancel / cleanup; the audit trail; the totals.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE TABLE t.docs(tag text,j jsonb);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,COALESCE(b,false),d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE jsonb_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.detail_of(q text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RETURN NULL; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL; RETURN d::jsonb; END; END $$;
CREATE FUNCTION t.queued(p_job text,p_org uuid) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.jobs WHERE job_type='export.full' AND payload->>'export_job_id'=p_job AND organization_id=p_org AND dedupe_key=p_job $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT SELECT,INSERT ON t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;

-- ================================================================ 1. which tables and columns (catalog)
SELECT t.expect('every tenant table (organization_id) is exported or excluded, and the plan is not empty',
  NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p')
    AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attname='organization_id' AND NOT a.attisdropped)
    AND NOT (c.relname::text = ANY(app.export_tables()))
    AND c.relname::text NOT IN (SELECT table_name FROM app.export_excluded_tables())),
  (SELECT string_agg(c.relname,', ') FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p')
    AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attname='organization_id' AND NOT a.attisdropped)
    AND NOT (c.relname::text = ANY(app.export_tables())) AND c.relname::text NOT IN (SELECT table_name FROM app.export_excluded_tables())));
SELECT t.expect('every excluded table exists and has a reason; the exported ones include the shop row and the audit log',
  (SELECT bool_and(to_regclass('public.'||quote_ident(table_name)) IS NOT NULL AND length(reason)>10) FROM app.export_excluded_tables())
  AND 'organizations'=ANY(app.export_tables()) AND 'branches'=ANY(app.export_tables()) AND 'audit_log'=ANY(app.export_tables())
  AND NOT ('jobs'=ANY(app.export_tables())) AND NOT ('password_resets'=ANY(app.export_tables()))
  AND NOT ('day_checks'=ANY(app.export_tables())) AND NOT ('document_counters'=ANY(app.export_tables())));
-- Tables without organization_id are global (plans, permissions...) or pre-session: a new one must be reviewed here.
SELECT t.expect('the only public tables without organization_id are the known global ones',
  (SELECT COALESCE(string_agg(c.relname,', '),'') FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p')
    AND NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attname='organization_id' AND NOT a.attisdropped)
    AND c.relname::text NOT IN ('organizations','permissions','plans','role_permissions','super_admins','login_attempts','device_pairing_attempts'))='',
  (SELECT string_agg(c.relname,', ') FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p')
    AND NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attname='organization_id' AND NOT a.attisdropped)
    AND c.relname::text NOT IN ('organizations','permissions','plans','role_permissions','super_admins','login_attempts','device_pairing_attempts')));
SELECT t.expect('every exported table has a primary key (the keyset paging needs one)',
  NOT EXISTS (SELECT 1 FROM unnest(app.export_tables()) x WHERE app.export_key_columns(x) IS NULL));
-- Secret-looking columns: excluded, or allowed here with a reason. A new one fails until it is decided.
CREATE TABLE t.secret_ok(col text PRIMARY KEY,reason text NOT NULL);
INSERT INTO t.secret_ok VALUES
 ('idempotency_key','the caller''s own retry key, not a credential'),
 ('permission_key','a permission name'),('feature_key','a feature name'),('plan_key','a plan name'),
 ('must_change_password','a flag, not a password'),('pairing_expires_at','a timestamp, not the code');
SELECT t.expect('no secret-looking column leaves the database (excluded, or allowed with a reason)',
  NOT EXISTS (SELECT 1 FROM unnest(app.export_tables()) x, unnest(app.export_columns(x)) c
              WHERE c ~* 'token|secret|password|hash|key|pairing' AND c NOT IN (SELECT col FROM t.secret_ok)),
  (SELECT string_agg(x||'.'||c,', ') FROM unnest(app.export_tables()) x, unnest(app.export_columns(x)) c
   WHERE c ~* 'token|secret|password|hash|key|pairing' AND c NOT IN (SELECT col FROM t.secret_ok)));
SELECT t.expect('the known secret columns are excluded: token hashes, vault ids, pairing codes',
  NOT ('token_hash'=ANY(app.export_columns('devices'))) AND NOT ('pairing_code_hash'=ANY(app.export_columns('devices')))
  AND NOT ('eta_preshared_key_vault_id'=ANY(app.export_columns('devices'))) AND NOT ('token_hash'=ANY(app.export_columns('invites')))
  AND NOT ('client_secret_vault_id'=ANY(app.export_columns('eta_settings')))
  AND 'name'=ANY(app.export_columns('devices')) AND 'deleted_at'=ANY(app.export_columns('files')));
SELECT t.error('a table outside the export plan is refused (deny list, unknown, injection)',$q$SELECT app.export_columns('jobs')$q$,'EXPORT_TABLE_NOT_ALLOWED');
SELECT t.error('an unknown table name is refused',$q$SELECT app.export_columns('customers; drop table x')$q$,'EXPORT_TABLE_NOT_ALLOWED');
SELECT t.expect('the plain-text test of the masking: ten stars and the last four digits',app.export_mask_json('{"national_id":"29101010100501","x":1}')='{"x": 1, "national_id": "**********0501"}'::jsonb
  AND app.export_mask_json('[1]')='[1]'::jsonb AND app.export_mask_json('null')='null'::jsonb);
SELECT t.expect('the grants: the owner-facing functions to authenticated, the job and the helpers to nobody',
  has_function_privilege('authenticated','public.start_full_export(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_exports()','EXECUTE')
  AND has_function_privilege('authenticated','public.get_export(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.cancel_export(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.record_export_download(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.jobs_export_page(uuid,text,text[],integer)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.jobs_export_prepare(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.jobs_export_complete(uuid,uuid,text,text,bigint,text,bigint,jsonb,bigint)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.jobs_export_cleanup_done(uuid,uuid[])','EXECUTE')
  AND has_function_privilege('service_role','public.jobs_export_page(uuid,text,text[],integer)','EXECUTE')
  AND has_function_privilege('service_role','public.jobs_export_prepare(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.start_full_export(jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.export_tables()','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.export_totals(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.export_columns(text)','EXECUTE'));

-- ================================================================ setup: shops a and b
RESET ROLE;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('M03 '||s,'m03-key-'||s,p,'Owner',s||'m03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('d',64)),('b','retail_pro',repeat('e',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0300000-0000-0000-8000-000000000001','am03@example.com'),('a0300000-0000-0000-8000-000000000002','bm03@example.com'),
  ('a0300000-0000-0000-8000-000000000003','m03cashier@example.com'),('a0300000-0000-0000-8000-000000000004','m03acct@example.com'),
  ('a0300000-0000-0000-8000-000000000005','m03pii@example.com');
SELECT public.accept_invite(repeat('d',64),'a0300000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('e',64),'a0300000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main_a',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main_a')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main_a'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0300000-0000-0000-8000-000000000003','M03 Cashier','CASHIER');
SELECT t.emp('acct','a0300000-0000-0000-8000-000000000004','M03 Accountant','ACCOUNTANT');
SELECT t.emp('pii','a0300000-0000-0000-8000-000000000005','M03 Pii','ACCOUNTANT');
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted)
  VALUES(t.org('a'),t.id('pii'),'customer.view_pii',true);
-- Data: customers with national IDs (PII), a guarantor, a device with a token hash, an audit row with a national_id key.
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,national_id)
  SELECT t.org('a'),'M03 Customer '||g,ARRAY['0105000000'||g],500,'2910101010050'||g FROM generate_series(1,5) g;
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,national_id)
  VALUES(t.org('b'),'M03 Other Shop Customer',ARRAY['01060000001'],500,'29101010100599');
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit)
  VALUES(t.org('a'),'=1+1',ARRAY['01070000001'],0);
INSERT INTO public.guarantors(organization_id,full_name,phone,national_id) VALUES(t.org('a'),'M03 Guarantor','01044440001','28805050100022');
INSERT INTO public.devices(organization_id,branch_id,name,token_hash,paired_at) VALUES(t.org('a'),t.id('main_a'),'M03 POS',encode(sha256('secret'::bytea),'hex'),now());
INSERT INTO public.audit_log(organization_id,action,entity_type,severity,after) VALUES(t.org('a'),'m03.test','customer','info','{"national_id":"29101010100501","name":"x"}'::jsonb);

-- A raw job row (what start_full_export inserts) for the service-side tests.
CREATE FUNCTION t.job(p_org uuid,p_pii text,p_status public.import_status DEFAULT 'importing') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.import_jobs(organization_id,kind,status,dry_run,report,created_by)
  VALUES(p_org,'full_export',p_status,false,jsonb_build_object('pii',p_pii,'idempotency_key','t-'||gen_random_uuid()),
         (SELECT id FROM public.employees WHERE organization_id=p_org AND role='OWNER' LIMIT 1)) RETURNING id INTO v;
  RETURN v; END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ================================================================ 2. paging and masking (service side)
SELECT t.job(t.org('a'),'masked') AS ja \gset
SELECT t.job(t.org('a'),'full') AS jf \gset
SELECT t.job(t.org('b'),'masked') AS jb \gset
CREATE FUNCTION t.pages(p_job uuid,p_table text,p_size integer) RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_after text[] := NULL; v_all text[] := '{}'; v_page record; v_n integer; v_last text[]; v_pages integer := 0;
BEGIN
  LOOP
    v_n := 0;
    FOR v_page IN SELECT * FROM public.jobs_export_page(p_job,p_table,v_after,p_size) LOOP
      v_n := v_n+1; v_last := v_page.key_vals; v_all := v_all || array_to_string(v_page.key_vals,'|');
    END LOOP;
    EXIT WHEN v_n=0;
    v_pages := v_pages+1;
    v_after := v_last;
    EXIT WHEN v_n<p_size;
  END LOOP;
  RETURN v_all;
END $$;
SELECT t.expect('paging by 2: every customer of shop a once, in id order, none of shop b',
  t.pages(:'ja','customers',2)=(SELECT array_agg(id::text ORDER BY id) FROM public.customers WHERE organization_id=t.org('a'))
  AND cardinality(t.pages(:'ja','customers',2))=6,
  array_to_string(t.pages(:'ja','customers',2),','));
SELECT t.expect('paging in one big page gives the same rows',t.pages(:'ja','customers',100)=t.pages(:'ja','customers',2));
SELECT t.expect('paging with a composite key (employee_branches): every row once, in key order',
  t.pages(:'ja','employee_branches',1)=(SELECT array_agg(employee_id::text||'|'||branch_id::text ORDER BY employee_id,branch_id) FROM public.employee_branches WHERE organization_id=t.org('a'))
  AND cardinality(t.pages(:'ja','employee_branches',1))>=3);
SELECT t.expect('paging with a four-column key (stock_levels) and an identity key (audit_log) give every row',
  cardinality(t.pages(:'ja','stock_levels',1))=(SELECT count(*) FROM public.stock_levels WHERE organization_id=t.org('a'))
  AND t.pages(:'ja','audit_log',3)=(SELECT array_agg(id::text ORDER BY id) FROM public.audit_log WHERE organization_id=t.org('a')));
SELECT t.expect('the shop row is exported through its own id (organizations)',
  t.pages(:'ja','organizations',10)=ARRAY[t.org('a')::text] AND t.pages(:'jb','organizations',10)=ARRAY[t.org('b')::text]);
SELECT t.expect('another shop''s job sees only its own rows, never a row of shop a',
  NOT EXISTS (SELECT 1 FROM public.jobs_export_page(:'jb','customers',NULL,100) p WHERE p.row_json::jsonb->>'organization_id'<>t.org('b')::text)
  AND (SELECT count(*) FROM public.jobs_export_page(:'jb','customers',NULL,100))=1);
SELECT t.error('the page function refuses a table of the deny list',format($q$SELECT * FROM public.jobs_export_page(%L,'jobs',NULL,10)$q$,:'ja'),'EXPORT_TABLE_NOT_ALLOWED');
SELECT t.error('the page function refuses an unknown job',$q$SELECT * FROM public.jobs_export_page(gen_random_uuid(),'customers',NULL,10)$q$,'EXPORT_NOT_FOUND');
SELECT t.error('the page function refuses a bad limit',format($q$SELECT * FROM public.jobs_export_page(%L,'customers',NULL,0)$q$,:'ja'),'VALIDATION_FAILED');
SELECT t.error('the page function refuses an after value of the wrong length',format($q$SELECT * FROM public.jobs_export_page(%L,'stock_levels',ARRAY['x'],10)$q$,:'ja'),'VALIDATION_FAILED');
-- Masked vs full national IDs.
SELECT t.expect('masked: customers'' national IDs are ten stars and the last four digits, in the JSON and in the cells',
  NOT EXISTS (SELECT 1 FROM public.jobs_export_page(:'ja','customers',NULL,100) p WHERE p.row_json LIKE '%29101010100501%' OR p.row_json LIKE '%2910101010050_"%')
  AND EXISTS (SELECT 1 FROM public.jobs_export_page(:'ja','customers',NULL,100) p WHERE p.row_json::jsonb->>'national_id'='**********0501')
  AND EXISTS (SELECT 1 FROM public.jobs_export_page(:'ja','customers',NULL,100) p WHERE '**********0501'=ANY(p.cells)));
SELECT t.expect('masked: guarantors and the audit log''s after are masked too; a customer without a national ID stays NULL',
  (SELECT row_json::jsonb->>'national_id' FROM public.jobs_export_page(:'ja','guarantors',NULL,10))='**********0022'
  AND (SELECT row_json::jsonb#>>'{after,national_id}' FROM public.jobs_export_page(:'ja','audit_log',NULL,1000) WHERE row_json::jsonb->>'action'='m03.test')='**********0501'
  AND EXISTS (SELECT 1 FROM public.jobs_export_page(:'ja','customers',NULL,100) p WHERE p.row_json::jsonb->>'full_name'='=1+1' AND p.row_json::jsonb->'national_id'='null'::jsonb));
SELECT t.expect('full: the national IDs are as they are stored',
  EXISTS (SELECT 1 FROM public.jobs_export_page(:'jf','customers',NULL,100) p WHERE p.row_json::jsonb->>'national_id'='29101010100501')
  AND (SELECT row_json::jsonb->>'national_id' FROM public.jobs_export_page(:'jf','guarantors',NULL,10))='28805050100022');
SELECT t.expect('no secret column in a row: the device row has its name and no token hash',
  (SELECT row_json::jsonb ? 'name' AND NOT row_json::jsonb ? 'token_hash' AND NOT row_json::jsonb ? 'pairing_code_hash' AND row_json NOT LIKE '%'||encode(sha256('secret'::bytea),'hex')||'%'
   FROM public.jobs_export_page(:'ja','devices',NULL,10) WHERE row_json::jsonb->>'name'='M03 POS'));
SELECT t.expect('cells follow the column plan: the same order and length, NULL stays NULL, money is the database text',
  (SELECT bool_and(cardinality(cells)=cardinality(app.export_columns('customers'))) FROM public.jobs_export_page(:'ja','customers',NULL,100))
  AND (SELECT cells[array_position(app.export_columns('customers'),'credit_limit')] FROM public.jobs_export_page(:'ja','customers',NULL,100) WHERE cells[3]='M03 Customer 1')='500.00'
  AND (SELECT cells[array_position(app.export_columns('customers'),'address')] IS NULL FROM public.jobs_export_page(:'ja','customers',NULL,100) WHERE cells[3]='M03 Customer 1'));
-- Counts and totals equal the database.
SELECT t.expect('counts equal count(*) for every exported table',
  (SELECT bool_and((public.jobs_export_counts(:'ja')->>x)::bigint=
     (SELECT (xpath('/row/n/text()',query_to_xml(format('SELECT count(*) AS n FROM public.%I t WHERE %s',x,replace(app.export_org_filter(x),'$1',quote_literal(t.org('a')))),false,true,'')))[1]::text::bigint))
   FROM unnest(app.export_tables()) x));
SELECT t.expect('totals: the eight numbers equal what the tables say',
  (public.jobs_export_totals(:'ja'))=jsonb_build_object(
     'cash_balance_total',(SELECT COALESCE(sum(balance),0)::numeric(18,2)::text FROM public.cash_balances WHERE organization_id=t.org('a')),
     'stock_on_hand_total',(SELECT COALESCE(sum(on_hand),0)::text FROM public.stock_levels WHERE organization_id=t.org('a')),
     'store_credit_total',(SELECT COALESCE(sum(balance),0)::numeric(18,2)::text FROM public.store_credit_balances WHERE organization_id=t.org('a')),
     'open_contracts_remaining','0.00','sales_total','0.00','payments_in_total','0.00','payments_out_total','0.00',
     'audit_rows',(SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a'))));

-- ================================================================ 3. start, running, too soon
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
-- The two raw jobs above are still 'importing' in shop a: a new export is refused until they are done.
SELECT t.error_detail('one running export per shop: EXPORT_RUNNING with the running job''s id',
  $q$SELECT public.start_full_export('{}','m03-key-0001')$q$,'EXPORT_RUNNING',jsonb_build_object('job_id',(SELECT id FROM public.import_jobs WHERE organization_id=t.org('a') AND kind='full_export' AND status='importing' ORDER BY created_at DESC,id DESC LIMIT 1)));
RESET ROLE;
UPDATE public.import_jobs SET status='cancelled',finished_at=now() WHERE id IN (:'ja',:'jf');
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'start',public.start_full_export('{}','m03-key-0001');
SELECT t.expect('start: queued, masked, requested by the owner, no file, a queue job and an audit row',
  (SELECT j->>'status'='queued' AND j->>'pii'='masked' AND j->>'file_id' IS NULL AND (j->'requested_by'->>'name')='Owner' AND (j->>'rows')::int=0 FROM t.docs WHERE tag='start')
  AND t.queued((SELECT j->>'id' FROM t.docs WHERE tag='start'),t.org('a'))=1
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='export.requested' AND entity_id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start') AND severity='info'));
SELECT t.expect('the same idempotency key answers the same job and changes nothing',
  (public.start_full_export('{}','m03-key-0001'))->>'id'=(SELECT j->>'id' FROM t.docs WHERE tag='start')
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='export.requested' AND organization_id=t.org('a') AND entity_id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')));
SELECT t.error_detail('a second key while one is queued: EXPORT_RUNNING',$q$SELECT public.start_full_export('{}','m03-key-0002')$q$,'EXPORT_RUNNING',jsonb_build_object('job_id',(SELECT j->>'id' FROM t.docs WHERE tag='start')));
SELECT t.error('an unknown option is refused',$q$SELECT public.start_full_export('{"pii":"masked","organization_id":"x"}','m03-key-0003')$q$,'VALIDATION_FAILED');
SELECT t.error('a bad pii mode is refused',$q$SELECT public.start_full_export('{"pii":"raw"}','m03-key-0004')$q$,'VALIDATION_FAILED');
SELECT t.error('a short idempotency key is refused',$q$SELECT public.start_full_export('{}','x')$q$,'VALIDATION_FAILED');
SELECT t.expect('list and get see the job; its state is queued',
  EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_exports()->'items') i WHERE i->>'id'=(SELECT j->>'id' FROM t.docs WHERE tag='start'))
  AND (public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start'))->>'status')='queued');
SELECT t.error('another shop''s export is not found (get)',format($q$SELECT public.get_export(%L)$q$,:'jb'),'EXPORT_NOT_FOUND');
SELECT t.error('another shop''s export is not found (cancel)',format($q$SELECT public.cancel_export(%L)$q$,:'jb'),'EXPORT_NOT_FOUND');
SELECT t.error('an unknown export is not found',$q$SELECT public.get_export(gen_random_uuid())$q$,'EXPORT_NOT_FOUND');
-- M01's reads never see an export job.
SELECT t.expect('M01''s import list and read do not show export jobs',
  NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_import_jobs('{}')->'items') i WHERE i->>'kind'='full_export'));
SELECT t.error('M01''s get_import_job does not find an export job',format($q$SELECT public.get_import_job(%L)$q$,(SELECT j->>'id' FROM t.docs WHERE tag='start')),'IMPORT_JOB_NOT_FOUND');

-- ================================================================ 4. the job: prepare, complete, state
RESET ROLE;
SELECT public.jobs_export_prepare((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')) AS prep \gset
SELECT t.expect('prepare: the plan (tables, columns, keys, json columns), the shop, the requester, the latest migration',
  :'prep'::jsonb->>'status'='importing' AND :'prep'::jsonb->>'pii'='masked'
  AND jsonb_array_length(:'prep'::jsonb->'tables')=cardinality(app.export_tables())
  AND (:'prep'::jsonb#>>'{shop,id}')::uuid=t.org('a') AND :'prep'::jsonb#>>'{requested_by,name}'='Owner'
  AND :'prep'::jsonb#>'{columns,customers}'=to_jsonb(app.export_columns('customers'))
  AND :'prep'::jsonb#>'{keys,stock_levels}'='["organization_id","product_id","branch_id","stock_state"]'::jsonb
  AND :'prep'::jsonb#>'{json_columns,customers}'='["phones"]'::jsonb
  AND :'prep'::jsonb->>'migration'<>'unknown',left(:'prep',300));
SELECT t.expect('prepare marks the job running',
  (SELECT public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')) IS NOT NULL) IS NOT NULL
  AND (SELECT app.export_job_json(j)->>'status'='running' FROM public.import_jobs j WHERE id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')));
SELECT t.expect('the state function answers importing while it runs',public.jobs_export_state((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start'))='importing');
-- Complete.
SELECT gen_random_uuid() AS fid \gset
SELECT public.jobs_export_complete((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start'),:'fid',t.org('a')::text||'/export/2026/10/'||:'fid'||'.zip','ecofin-export-m03-20261027-0900.zip',
   2048,repeat('a',64),1234,'{"format_version":1}'::jsonb,5000) AS comp \gset
SELECT t.expect('complete: the job is completed with the file, the row count and the manifest',
  :'comp'::jsonb->>'status'='completed'
  AND (SELECT status='completed' AND result_file_id=:'fid' AND rows_total=1234 AND finished_at IS NOT NULL AND report->'manifest'='{"format_version":1}'::jsonb AND (report->>'size_bytes')::int=2048 FROM public.import_jobs WHERE id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start'))
  AND (SELECT purpose='export' AND mime='application/zip' AND size_bytes=2048 AND deleted_at IS NULL FROM public.files WHERE id=:'fid'));
SELECT t.expect('complete: audited as export.completed (info for a masked export)',
  (SELECT count(*)=1 AND bool_and(severity='info') FROM public.audit_log WHERE action='export.completed' AND entity_id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')));
SELECT t.expect('a second complete (a retry) changes nothing',
  public.jobs_export_complete((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start'),gen_random_uuid(),t.org('a')::text||'/export/x.zip','x.zip',1,repeat('b',64),1,'{}',1)->>'changed'='false'
  AND (SELECT count(*)=1 FROM public.files WHERE organization_id=t.org('a') AND purpose='export'));
SELECT t.error('a path outside the shop is refused',format($q$SELECT public.jobs_export_complete(%L,gen_random_uuid(),%L,'x.zip',1,repeat('b',64),1,'{}',1)$q$,:'jb',t.org('a')::text||'/export/x.zip'),'FILE_PATH_INVALID');
-- Too soon, then the owner sees the file and records the download.
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('too soon: a new export within the hour of a completed one is refused',
  $q$SELECT public.start_full_export('{}','m03-key-0005')$q$,'EXPORT_TOO_SOON');
SELECT t.expect('too soon: retry_after is a number of seconds between 1 and 3600',
  (t.detail_of($q$SELECT public.start_full_export('{}','m03-key-0005')$q$)->>'retry_after')::int BETWEEN 1 AND 3600);
SELECT t.expect('the completed export shows its file and zip name',
  (public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')))->>'file_id'=:'fid'
  AND (public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')))->>'file_name'='ecofin-export-m03-20261027-0900.zip'
  AND ((public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='start')))->>'size_bytes')::int=2048);
SELECT public.record_export_download(:'fid');
SELECT t.expect('the download is audited as export.downloaded (info, with the file id)',
  (SELECT count(*)=1 AND bool_and(severity='info' AND after->>'file_id'=:'fid' AND entity_type='export_job') FROM public.audit_log WHERE action='export.downloaded' AND organization_id=t.org('a')));
SELECT public.record_export_download(gen_random_uuid());
SELECT t.expect('a file that is not an export zip changes nothing',
  (SELECT count(*)=1 FROM public.audit_log WHERE action='export.downloaded' AND organization_id=t.org('a')));
-- Cleanup: the zip leaves storage after seven days; the files row stays with deleted_at.
RESET ROLE;
SELECT t.expect('cleanup lists nothing while the zip is fresh',(SELECT count(*)=0 FROM public.jobs_export_cleanup_list(t.org('a'),7)));
UPDATE public.files SET created_at=now()-interval '8 days' WHERE id=:'fid';
SELECT t.expect('cleanup lists the zip once it is older than seven days, with its path',
  (SELECT count(*)=1 AND bool_and(file_id=:'fid'::uuid AND path LIKE t.org('a')::text||'/export/%') FROM public.jobs_export_cleanup_list(t.org('a'),7))
  AND (SELECT count(*)=0 FROM public.jobs_export_cleanup_list(t.org('b'),7)));
SELECT public.jobs_export_cleanup_done(t.org('a'),ARRAY[:'fid']::uuid[]) AS cleaned \gset
SELECT public.jobs_export_cleanup_done(t.org('a'),ARRAY[:'fid']::uuid[]) AS cleaned2 \gset
SELECT t.expect('cleanup marks the row deleted: the job shows no file but when it was removed; the row stays; a repeat removes nothing',
  :cleaned=1 AND :cleaned2=0
  AND (SELECT deleted_at IS NOT NULL FROM public.files WHERE id=:'fid')
  AND (SELECT app.export_job_json(x)->'file_id'='null'::jsonb AND (app.export_job_json(x)->>'file_removed_at') IS NOT NULL FROM public.import_jobs x WHERE x.id=(SELECT (d.j->>'id')::uuid FROM t.docs d WHERE d.tag='start'))
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='export.file_removed' AND organization_id=t.org('a')));
SELECT public.jobs_export_cleanup_done(t.org('b'),ARRAY[:'fid']::uuid[]) AS cleaned3 \gset
SELECT t.expect('cleanup never touches another shop''s file',:cleaned3=0);

-- ================================================================ 5. cancel, fail, permission lost
-- The completed job is frozen: for the next start, pretend it finished two hours ago.
ALTER TABLE public.import_jobs DISABLE TRIGGER trg_import_jobs_final;
UPDATE public.import_jobs SET finished_at=now()-interval '2 hours' WHERE organization_id=t.org('a') AND kind='full_export' AND status='completed';
ALTER TABLE public.import_jobs ENABLE TRIGGER trg_import_jobs_final;
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'second',public.start_full_export('{}','m03-key-0006');
SELECT t.expect('after the hour a new export starts',(SELECT j->>'status'='queued' FROM t.docs WHERE tag='second'));
INSERT INTO t.docs SELECT 'cancelled',public.cancel_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='second'));
SELECT t.expect('cancel: a queued export ends cancelled, audited; cancelling again changes nothing',
  (SELECT j->>'status'='cancelled' AND j->>'finished_at' IS NOT NULL FROM t.docs WHERE tag='cancelled')
  AND public.cancel_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='second'))->>'status'='cancelled'
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='export.cancelled' AND entity_id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='second')));
RESET ROLE;
SELECT t.expect('a cancelled job: state cancelled, prepare does nothing, complete and fail change nothing',
  public.jobs_export_state((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='second'))='cancelled'
  AND public.jobs_export_prepare((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='second'))->>'changed'='false'
  AND public.jobs_export_complete((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='second'),gen_random_uuid(),t.org('a')::text||'/export/y.zip','y.zip',1,repeat('b',64),1,'{}',1)->>'changed'='false'
  AND public.jobs_export_fail((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='second'),'EXPORT_FAILED','{}')->>'changed'='false');
-- A cancelled export does not block the next one (and does not count as "completed" for the hour).
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'third',public.start_full_export('{"pii":"masked"}','m03-key-0007');
RESET ROLE;
SELECT public.jobs_export_fail((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='third'),'EXPORT_TOO_LARGE','{"total_rows":3000000,"limit_rows":2000000}') AS failed \gset
SELECT t.expect('fail: the job is failed with the code and the numbers, audited at warning; a failed export does not slow the next one',
  :'failed'::jsonb->>'status'='failed'
  AND (SELECT app.export_job_json(j)->>'status'='failed' AND app.export_job_json(j)->>'error_code'='EXPORT_TOO_LARGE' AND report#>>'{error_detail,total_rows}'='3000000' FROM public.import_jobs j WHERE id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='third'))
  AND (SELECT count(*)=1 AND bool_and(severity='warning' AND after->>'error_code'='EXPORT_TOO_LARGE') FROM public.audit_log WHERE action='export.failed' AND entity_id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='third')));
SELECT t.expect('fail with an unknown code is stored as EXPORT_FAILED',
  (SELECT public.jobs_export_fail(t.job(t.org('a'),'masked'),'MADE_UP','{}')->>'status')='failed');
-- Full PII: needs customer.view_pii on top of export.data; audited at warning.
SELECT t.as_user('a0300000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('full PII without customer.view_pii is refused (accountant)',$q$SELECT public.start_full_export('{"pii":"full"}','m03-key-0008')$q$,'PERMISSION_DENIED');
INSERT INTO t.docs SELECT 'acct',public.start_full_export('{}','m03-key-0009');
SELECT t.expect('the accountant (export.data) can export masked data',(SELECT j->>'status'='queued' FROM t.docs WHERE tag='acct'));
RESET ROLE;
-- The accountant loses export.data before the worker starts: the job fails, nothing is built.
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),t.id('acct'),'export.data',false);
SELECT public.jobs_export_prepare((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='acct')) AS lost \gset
SELECT t.expect('permission lost meanwhile: prepare ends the job failed with EXPORT_PERMISSION_LOST',
  :'lost'::jsonb->>'status'='failed'
  AND (SELECT app.export_job_json(j)->>'error_code'='EXPORT_PERMISSION_LOST' FROM public.import_jobs j WHERE id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='acct')));
SELECT t.as_user('a0300000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('the accountant without export.data is refused now',$q$SELECT public.list_exports()$q$,'PERMISSION_DENIED');
SELECT t.as_user('a0300000-0000-0000-8000-000000000005',t.org('a'));
INSERT INTO t.docs SELECT 'full',public.start_full_export('{"pii":"full"}','m03-key-0010');
SELECT t.expect('full PII with customer.view_pii: queued, and audited at warning',
  (SELECT j->>'pii'='full' FROM t.docs WHERE tag='full')
  AND (SELECT count(*)=1 AND bool_and(severity='warning') FROM public.audit_log WHERE action='export.requested' AND entity_id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full')));
RESET ROLE;
SELECT public.jobs_export_prepare((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full')) AS prepf \gset
SELECT t.expect('a full export that is still allowed is prepared with pii full',:'prepf'::jsonb->>'pii'='full' AND :'prepf'::jsonb->>'status'='importing');
SELECT public.jobs_export_complete((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full'),gen_random_uuid(),t.org('a')::text||'/export/z.zip','z.zip',10,repeat('c',64),10,'{}',10)->>'status' AS fullc \gset
SELECT t.expect('completing a full export is audited at warning',:'fullc'='completed'
  AND (SELECT severity='warning' FROM public.audit_log WHERE action='export.completed' AND entity_id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full')));

-- The zip of a full-PII export is hidden from, and refused to, a caller without customer.view_pii.
SELECT t.as_user('a0300000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('full export: the requester with customer.view_pii sees its file',
  (public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full'))->>'file_id') IS NOT NULL);
SELECT public.record_export_download((SELECT (public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full'))->>'file_id')::uuid));
RESET ROLE;
UPDATE public.employee_permission_overrides SET granted=true WHERE employee_id=t.id('acct') AND permission_key='export.data';
SELECT t.as_user('a0300000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('full export: a caller with export.data but no customer.view_pii sees no file',
  (public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full'))->>'file_id') IS NULL
  AND (public.get_export((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full'))->>'file_name') IS NULL);
SELECT t.error('full export: the download of its zip is refused without customer.view_pii',
  format($q$SELECT public.record_export_download(%L)$q$,(SELECT result_file_id FROM public.import_jobs WHERE id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='full'))),'PERMISSION_DENIED');
RESET ROLE;

-- ================================================================ 6. permissions, expired and suspended shops, other shop
SELECT t.as_user('a0300000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('a cashier (no export.data) cannot start',$q$SELECT public.start_full_export('{}','m03-key-0011')$q$,'PERMISSION_DENIED');
SELECT t.error('a cashier cannot list',$q$SELECT public.list_exports()$q$,'PERMISSION_DENIED');
SELECT t.error('a cashier cannot cancel',format($q$SELECT public.cancel_export(%L)$q$,:'jb'),'PERMISSION_DENIED');
SELECT t.error('a cashier cannot record a download',$q$SELECT public.record_export_download(gen_random_uuid())$q$,'PERMISSION_DENIED');
RESET ROLE;
-- Expired subscription: export.data still works (P05).
UPDATE public.import_jobs SET status='cancelled',finished_at=now() WHERE id=:'jb';
UPDATE public.organizations SET subscription_start=current_date-40,subscription_end=current_date-10 WHERE id=t.org('b');
SELECT t.as_user('a0300000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'expired',public.start_full_export('{}','m03-key-0012');
SELECT t.expect('an expired shop can still export (the way out of the system)',(SELECT j->>'status'='queued' FROM t.docs WHERE tag='expired')
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_exports()->'items') i WHERE i->>'id'=(SELECT j->>'id' FROM t.docs WHERE tag='expired')));
SELECT t.expect('shop b sees only its own exports',
  NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_exports()->'items') i WHERE i->>'id'=(SELECT j->>'id' FROM t.docs WHERE tag='start')));
RESET ROLE;
-- Suspended: refused.
UPDATE public.organizations SET status='suspended' WHERE id=t.org('b');
SELECT t.as_user('a0300000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('a suspended shop cannot start an export',$q$SELECT public.start_full_export('{}','m03-key-0013')$q$,'ORG_NOT_ACTIVE');
SELECT t.error('a suspended shop cannot list its exports',$q$SELECT public.list_exports()$q$,'ORG_NOT_ACTIVE');
RESET ROLE;
SELECT public.jobs_export_prepare((SELECT (j->>'id')::uuid FROM t.docs WHERE tag='expired'))->>'status' AS susp \gset
SELECT t.expect('a job whose shop was suspended meanwhile ends failed (EXPORT_SHOP_NOT_ACTIVE)',
  :'susp'='failed'
  AND (SELECT app.export_job_json(j)->>'error_code'='EXPORT_SHOP_NOT_ACTIVE' FROM public.import_jobs j WHERE id=(SELECT (j->>'id')::uuid FROM t.docs WHERE tag='expired')));
-- Row level security: an employee reads export jobs only of their own shop and only with the right key.
SELECT t.as_user('a0300000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('RLS: the owner of shop a sees no import_jobs row of shop b',
  NOT EXISTS (SELECT 1 FROM public.import_jobs WHERE organization_id=t.org('b')));
RESET ROLE;

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
