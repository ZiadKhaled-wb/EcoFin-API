-- T02 ETA e-receipts (EC-90, D67).
-- Run by: node scripts/db-smoke.mjs supabase/tests/t02_eta_test.sql (inside BEGIN ... ROLLBACK).
-- Every consumer sale of a shop with ETA on gets one fiscal record and one eta.prepare job in the
-- sale's own transaction; a prepared receipt moves the POS chain by compare-and-set; secrets live
-- in Vault and never in a column `authenticated` can read; the worker functions are the service
-- role's only; an accepted receipt is frozen; the environment can't change under a receipt.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
-- The statement must fail with an error whose message starts with the code c.
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- The statement must fail with SQLSTATE s.
CREATE FUNCTION t.state(n text,q text,s text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND SQLSTATE=s,SQLSTATE||' '||SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q) $$;
-- A sha-256 shaped UUID made of one hex digit.
CREATE FUNCTION t.u(c text) RETURNS text LANGUAGE sql AS $$ SELECT repeat(c,64) $$;
-- What the worker sees of a fiscal row, a POS and the queue (the test acts as `authenticated` at times).
CREATE FUNCTION t.fiscal(sale text) RETURNS public.fiscal_submissions LANGUAGE sql SECURITY DEFINER AS $$
  SELECT f FROM public.fiscal_submissions f WHERE f.sale_id=t.id(sale) $$;
CREATE FUNCTION t.fid(sale text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT f.id FROM public.fiscal_submissions f WHERE f.sale_id=t.id(sale) $$;
CREATE FUNCTION t.tail(device text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT d.eta_last_uuid FROM public.devices d WHERE d.id=t.id(device) $$;
CREATE FUNCTION t.jobs(shop text,kind text,st text DEFAULT 'queued') RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.jobs j WHERE j.organization_id=t.org(shop) AND j.job_type=kind AND j.status::text=st $$;
CREATE FUNCTION t.fiscals(shop text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.fiscal_submissions f WHERE f.organization_id=t.org(shop) $$;
-- A sale of the caller's open shift: one unit of a product at 1 140.00.
CREATE FUNCTION t.sell(tag text,product text DEFAULT 'tv') RETURNS void LANGUAGE sql AS $$
  INSERT INTO t.ids SELECT tag,(public.post_sale(t.lines(t.items(product,1)),'1140.00','t02-sale-'||tag)->>'id')::uuid $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (ETA), shop b, shop c (no eta module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO public.plans(key,name,description,price_monthly,max_branches,max_users,max_devices,modules,display_order)
  VALUES('t02_noeta','No ETA','T02 test plan without the eta module',1,2,5,5,'{pos,inventory,purchasing,cash}',99);
INSERT INTO t.shops SELECT s,public.admin_provision_organization('T02 '||s,'t02-'||s,p,'Owner',s||'t02@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('u',64)),('b','retail_pro',repeat('v',64)),('c','t02_noeta',repeat('w',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a9020000-0000-0000-8000-000000000001','at02@example.com'),('a9020000-0000-0000-8000-000000000002','bt02@example.com'),
  ('a9020000-0000-0000-8000-000000000003','t02cashier@example.com');
SELECT public.accept_invite(repeat('u',64),'a9020000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('v',64),'a9020000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'bmain',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'cmain',id FROM public.branches WHERE organization_id=t.org('c') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id IN (t.org('a'),t.org('b'));
UPDATE public.organizations SET tax_registration_no='674859545',legal_name='T02 Shop A LLC' WHERE id=t.org('a');
-- POS devices: no slice creates them yet, so the test inserts them as the database owner.
WITH d AS (INSERT INTO public.devices(organization_id,branch_id,name) VALUES
    (t.org('a'),t.id('main'),'POS 1'),(t.org('a'),t.id('main'),'POS 2'),(t.org('b'),t.id('bmain'),'B POS')
  RETURNING id,name)
INSERT INTO t.ids SELECT CASE name WHEN 'POS 1' THEN 'pos1' WHEN 'POS 2' THEN 'pos2' ELSE 'bpos' END,id FROM d;
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id)
  VALUES(t.org('a'),'a9020000-0000-0000-8000-000000000003','T02 Cashier','CASHIER',t.id('main'));
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id)
  SELECT t.org('a'),e.id,t.id('main') FROM public.employees e WHERE e.auth_user_id='a9020000-0000-0000-8000-000000000003';

SELECT t.as_user('a9020000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"T2-TV","cash_price":"1140","eta_item_code":"EG-674859545-TV","eta_item_type":"EGS"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('tv'),'quantity',40)),'t02-found');
SELECT public.open_shift(t.id('main'),'0','t02-shift-owner',NULL,t.id('pos1'));
RESET ROLE;

-- ---------------------------------------------------------------- the branch building number (O01 functions)
SET ROLE authenticated;
SELECT public.update_branch(t.id('main'),'Main','16 Abbas El Akkad','Nasr City','Cairo',NULL,'0',
  (SELECT default_cash_account_id FROM public.branches WHERE id=t.id('main')),' 14 ');
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('third',public.create_branch('Third','S3','1 St',NULL,NULL,NULL,NULL,'7B'));
SELECT t.error('branch: a building number over 100 characters',format('SELECT public.update_branch(%L,''Main'',NULL,NULL,NULL,NULL,NULL,NULL,%L)',t.id('main'),repeat('x',101)),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('branch: update_branch stores the building number (trimmed); create_branch takes it and still works without it',
  (SELECT building_number='14' AND eta_branch_code='0' AND governorate='Cairo' FROM public.branches WHERE id=t.id('main'))
  AND (SELECT building_number IS NULL FROM public.branches WHERE id=t.id('second'))
  AND (SELECT building_number='7B' FROM public.branches WHERE id=t.id('third')));
SELECT t.expect('branch: authenticated can read the building number',has_column_privilege('authenticated','public.branches','building_number','SELECT'));

-- ---------------------------------------------------------------- 1. the trigger
SET ROLE authenticated;
SELECT t.sell('s0');
RESET ROLE;
SELECT t.expect('trigger: ETA off (the default) -> a sale gets no fiscal row and no job',
  t.fiscals('a')=0 AND t.jobs('a','eta.prepare')=0 AND (SELECT NOT is_enabled FROM public.eta_settings WHERE organization_id=t.org('a')));

SET ROLE authenticated;
SELECT t.error('settings: turning ETA on without a secret','SELECT public.set_eta_settings(''preprod'',''client-a'',NULL,''4753'',true)','VALIDATION_FAILED');
SELECT t.error('settings: turning ETA on without an activity code','SELECT public.set_eta_settings(''preprod'',''client-a'',''secret-a-1'',NULL,true)','VALIDATION_FAILED');
SELECT t.error('settings: an activity code with a space','SELECT public.set_eta_settings(''preprod'',''client-a'',''secret-a-1'',''47 53'',false)','VALIDATION_FAILED');
SELECT t.error('settings: a secret over 100 characters',format('SELECT public.set_eta_settings(''preprod'',''client-a'',%L,''4753'',false)',repeat('s',101)),'VALIDATION_FAILED');
SELECT t.expect('settings: saved; the answer says a secret is stored and carries none',
  (SELECT j->>'environment'='preprod' AND j->>'client_id'='client-a' AND (j->>'has_client_secret')::boolean AND j->>'activity_code'='4753'
     AND (j->>'is_enabled')::boolean AND j::text NOT LIKE '%secret-a-1%' AND NOT (j ? 'client_secret') AND NOT (j ? 'client_secret_vault_id')
   FROM (SELECT public.set_eta_settings('preprod',' client-a ','secret-a-1','4753',true) j) x));
SELECT t.expect('settings: get_eta_settings answers the same, without a secret',
  (SELECT j->>'client_id'='client-a' AND (j->>'has_client_secret')::boolean AND j::text NOT LIKE '%secret-a-1%' FROM (SELECT public.get_eta_settings() j) x));
SELECT t.sell('s1');
RESET ROLE;
SELECT t.expect('trigger: ETA on -> the sale has one pending fiscal row for its POS, branch, number and environment',
  t.fiscals('a')=1 AND (SELECT f.status='pending' AND f.doc_type='b2c_receipt' AND f.device_id=t.id('pos1') AND f.branch_id=t.id('main')
     AND f.environment='preprod' AND f.internal_id=(SELECT number FROM public.sales WHERE id=t.id('s1')) AND f.eta_uuid IS NULL
     AND f.attempts=0 AND f.next_retry_at IS NULL AND f.payload IS NULL FROM t.fiscal('s1') f),
  (SELECT row_to_json(f)::text FROM t.fiscal('s1') f));
SELECT t.expect('trigger: and one queued eta.prepare job, keyed by the POS',
  t.jobs('a','eta.prepare')=1 AND (SELECT j.dedupe_key='eta.prepare:'||t.id('pos1')::text AND j.payload->>'device_id'=t.id('pos1')::text
     AND j.payload->>'branch_id'=t.id('main')::text FROM public.jobs j WHERE j.organization_id=t.org('a') AND j.job_type='eta.prepare'));
SET ROLE authenticated;
SELECT t.sell('s2');
SELECT t.sell('s3');
RESET ROLE;
SELECT t.expect('trigger: two more sales -> three fiscal rows, still one queued job for the POS',t.fiscals('a')=3 AND t.jobs('a','eta.prepare')=1);
SELECT t.state('trigger: a second fiscal row for the same sale is a unique violation',
  format('INSERT INTO public.fiscal_submissions(organization_id,branch_id,doc_type,sale_id,environment,internal_id) VALUES(%L,%L,''b2c_receipt'',%L,''preprod'',''dup'')',t.org('a'),t.id('main'),t.id('s1')),'23505');

-- A B2B sale and a shop without the eta module: rows written as the database owner (no slice makes them yet).
INSERT INTO public.customers(id,organization_id,full_name,is_business,tax_registration_no) VALUES('a9020000-0000-0000-8000-0000000000c1',t.org('a'),'Delta Trading',true,'313717919');
INSERT INTO public.sales(id,organization_id,number,branch_id,device_id,customer_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key)
  VALUES('a9020000-0000-0000-8000-0000000000b2',t.org('a'),'T02-B2B-1',t.id('main'),t.id('pos1'),'a9020000-0000-0000-8000-0000000000c1','pos',true,true,100,100,current_date,'t02-b2b-sale-1');
SELECT t.expect('trigger: a B2B sale gets no fiscal row',t.fiscals('a')=3 AND NOT EXISTS(SELECT 1 FROM public.fiscal_submissions WHERE sale_id='a9020000-0000-0000-8000-0000000000b2'));
UPDATE public.eta_settings SET is_enabled=true,client_id='c',activity_code='1' WHERE organization_id=t.org('c');
INSERT INTO public.sales(organization_id,number,branch_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key)
  VALUES(t.org('c'),'T02-C-1',t.id('cmain'),'pos',false,true,100,100,current_date,'t02-noeta-sale-1');
SELECT t.expect('trigger: a shop whose plan has no eta module gets no fiscal row, even with the setting on',t.fiscals('c')=0 AND t.jobs('c','eta.prepare')=0);
INSERT INTO public.sales(id,organization_id,number,branch_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key)
  VALUES('a9020000-0000-0000-8000-0000000000d0',t.org('a'),'T02-NODEV-1',t.id('second'),'pos',false,true,100,100,current_date,'t02-nodevice-sale-1');
INSERT INTO t.ids VALUES('nodev','a9020000-0000-0000-8000-0000000000d0');
SELECT t.expect('trigger: a sale without a POS gets its fiscal row and a job keyed by its branch',
  (SELECT f.device_id IS NULL AND f.branch_id=t.id('second') AND f.status='pending' FROM t.fiscal('nodev') f)
  AND EXISTS(SELECT 1 FROM public.jobs j WHERE j.job_type='eta.prepare' AND j.dedupe_key='eta.prepare:'||t.id('second')::text AND j.status='queued'));

-- ---------------------------------------------------------------- the devices: registration and secrets
SET ROLE authenticated;
SELECT t.error('device: active without a key',format('SELECT public.set_device_eta(%L,''POS-A1'',''android 14'',''1'',NULL,''active'')',t.id('pos1')),'VALIDATION_FAILED');
SELECT t.error('device: a model framework over 10 characters',format('SELECT public.set_device_eta(%L,''POS-A1'',''os'',%L,''k'',''pending'')',t.id('pos1'),repeat('m',11)),'VALIDATION_FAILED');
SELECT t.expect('device: registered; the answer says a key is stored and carries none',
  (SELECT j->>'eta_serial'='POS-A1' AND j->>'eta_os_version'='android 14' AND j->>'eta_model_framework'='1' AND j->>'eta_status'='active'
     AND (j->>'has_preshared_key')::boolean AND j->>'branch_name'='Main' AND j::text NOT LIKE '%key-a1-xyz%' AND j::text NOT LIKE '%vault%'
   FROM (SELECT public.set_device_eta(t.id('pos1'),' POS-A1 ','android 14','1','key-a1-xyz','active') j) x));
SELECT t.error('device: a serial another device of the shop has',format('SELECT public.set_device_eta(%L,''POS-A1'',''os'',''1'',''key-2'',''pending'')',t.id('pos2')),'DEVICE_SERIAL_TAKEN');
SELECT t.error('permissions: set_device_eta on shop B''s device is refused',format('SELECT public.set_device_eta(%L,''POS-X'',''os'',''1'',''k'',''pending'')',t.id('bpos')),'DEVICE_NOT_FOUND');
SELECT t.expect('devices: the list is the caller shop''s own, with has_preshared_key and no key',
  (SELECT jsonb_array_length(j)=2 AND j::text NOT LIKE '%key-a1-xyz%' AND j::text NOT LIKE '%'||t.id('bpos')::text||'%'
     AND (j->0->>'name')='POS 1' AND (j->0->>'has_preshared_key')::boolean AND NOT (j->1->>'has_preshared_key')::boolean
   FROM (SELECT public.list_devices() j) x));
RESET ROLE;
SELECT t.expect('secrets: authenticated can''t read client_secret_vault_id, eta_preshared_key_vault_id or fiscal_submissions.payload',
  NOT has_column_privilege('authenticated','public.eta_settings','client_secret_vault_id','SELECT')
  AND NOT has_column_privilege('authenticated','public.devices','eta_preshared_key_vault_id','SELECT')
  AND NOT has_column_privilege('authenticated','public.fiscal_submissions','payload','SELECT')
  AND NOT has_table_privilege('authenticated','public.devices','SELECT'));
SELECT t.expect('secrets: every other column of devices and the new fiscal columns stay readable',
  (SELECT bool_and(has_column_privilege('authenticated','public.devices',a.attname,'SELECT'))
   FROM pg_attribute a WHERE a.attrelid='public.devices'::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname<>'eta_preshared_key_vault_id')
  AND has_column_privilege('authenticated','public.fiscal_submissions','eta_submission_uuid','SELECT')
  AND has_column_privilege('authenticated','public.fiscal_submissions','previous_uuid','SELECT')
  AND has_column_privilege('authenticated','public.fiscal_submissions','qr_payload','SELECT'));
SET ROLE authenticated;
SELECT t.state('secrets: reading the vault id of the client secret as a user is refused','SELECT client_secret_vault_id FROM public.eta_settings','42501');
SELECT t.state('secrets: reading the vault id of a POS key as a user is refused','SELECT eta_preshared_key_vault_id FROM public.devices','42501');
SELECT t.state('secrets: SELECT * on devices as a user is refused (it would show the vault id)','SELECT * FROM public.devices','42501');
SELECT t.state('secrets: reading a receipt payload as a user is refused','SELECT payload FROM public.fiscal_submissions','42501');
SELECT t.state('secrets: the Vault itself is closed to a user','SELECT decrypted_secret FROM vault.decrypted_secrets','42501');
SELECT t.state('secrets: eta_credentials is not executable by authenticated',format('SELECT public.eta_credentials(%L,%L)',t.org('a'),t.id('pos1')),'42501');
RESET ROLE;
SELECT t.expect('secrets: every worker function is the service role''s only (not authenticated, not anon)',
  (SELECT bool_and(has_function_privilege('service_role',p.oid,'EXECUTE') AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
                   AND NOT has_function_privilege('anon',p.oid,'EXECUTE')) AND count(*)=10
   FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('eta_enqueue','eta_load_pending_for_device','eta_credentials',
     'eta_store_prepared','eta_block','eta_claim_for_submit','eta_mark','eta_load_submitted','eta_claim_deadline_alerts','eta_sale_status')),
  (SELECT string_agg(p.proname,',') FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE 'eta\_%'));
SELECT t.expect('secrets: the shop functions are executable by authenticated, none by anon; the app helpers by neither',
  (SELECT bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE')) AND count(*)=5
   FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('get_eta_settings','set_eta_settings','list_devices','set_device_eta','retry_fiscal_submission'))
  AND (SELECT bool_and(NOT has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE')) AND count(*)=5
   FROM pg_proc p WHERE p.pronamespace='app'::regnamespace AND p.proname IN ('eta_enqueue','sales_eta_fiscal','eta_put_secret','eta_settings_json','eta_device_json')));
SELECT t.expect('secrets: the worker reads the client secret and the POS key from Vault',
  (SELECT j->>'environment'='preprod' AND j->>'client_id'='client-a' AND j->>'client_secret'='secret-a-1' AND j->>'pos_serial'='POS-A1'
     AND j->>'pos_os_version'='android 14' AND j->>'pos_model_framework'='1' AND j->>'preshared_key'='key-a1-xyz'
     AND j->>'device_status'='active' AND (j->>'device_active')::boolean
   FROM (SELECT public.eta_credentials(t.org('a'),t.id('pos1')) j) x));
SELECT t.expect('secrets: no credentials for a POS of another shop',
  public.eta_credentials(t.org('a'),t.id('bpos')) IS NULL AND public.eta_credentials(t.org('b'),t.id('pos1')) IS NULL);
SELECT t.expect('secrets: neither secret is in any column of the tables, only its vault id',
  (SELECT row_to_json(s)::text NOT LIKE '%secret-a-1%' AND s.client_secret_vault_id IS NOT NULL FROM public.eta_settings s WHERE s.organization_id=t.org('a'))
  AND (SELECT row_to_json(d)::text NOT LIKE '%key-a1-xyz%' AND d.eta_preshared_key_vault_id IS NOT NULL FROM public.devices d WHERE d.id=t.id('pos1'))
  AND (SELECT count(*)=2 FROM vault.secrets v WHERE v.id IN ((SELECT client_secret_vault_id FROM public.eta_settings WHERE organization_id=t.org('a')),
                                                          (SELECT eta_preshared_key_vault_id FROM public.devices WHERE id=t.id('pos1')))));
SELECT t.expect('secrets: the audit rows of the settings and of the device carry neither secret',
  (SELECT count(*)=1 AND bool_and(a.after::text NOT LIKE '%secret-a-1%' AND (a.after->>'client_secret_changed')::boolean AND a.entity_id=t.org('a'))
   FROM public.audit_log a WHERE a.organization_id=t.org('a') AND a.action='eta.settings_updated')
  AND (SELECT count(*)=1 AND bool_and(a.after::text NOT LIKE '%key-a1-xyz%' AND a.after::text NOT LIKE '%vault%' AND (a.after->>'preshared_key_changed')::boolean
                                      AND a.entity_id=t.id('pos1') AND a.branch_id=t.id('main'))
   FROM public.audit_log a WHERE a.organization_id=t.org('a') AND a.action='device.eta_updated'));
-- A new secret replaces the stored one in place; none sent keeps it.
INSERT INTO t.ids SELECT 'vault_secret',client_secret_vault_id FROM public.eta_settings WHERE organization_id=t.org('a');
SET ROLE authenticated;
SELECT public.set_eta_settings('preprod','client-a',NULL,'4753',true);
RESET ROLE;
SELECT t.expect('secrets: saving without a secret keeps the stored one',public.eta_credentials(t.org('a'),t.id('pos1'))->>'client_secret'='secret-a-1');
SET ROLE authenticated;
SELECT public.set_eta_settings('preprod','client-a','secret-a-2','4753',true);
SELECT public.set_device_eta(t.id('pos1'),'POS-A1','android 14','1',NULL,'active');
RESET ROLE;
SELECT t.expect('secrets: a new secret replaces the old one under the same vault id; a device saved without a key keeps its key',
  (SELECT j->>'client_secret'='secret-a-2' AND j->>'preshared_key'='key-a1-xyz' FROM (SELECT public.eta_credentials(t.org('a'),t.id('pos1')) j) x)
  AND (SELECT client_secret_vault_id=t.id('vault_secret') FROM public.eta_settings WHERE organization_id=t.org('a'))
  AND NOT EXISTS(SELECT 1 FROM vault.decrypted_secrets v WHERE v.decrypted_secret='secret-a-1'));

-- ---------------------------------------------------------------- 4. permissions
SELECT t.as_user('a9020000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('permissions: set_eta_settings without org.settings_manage','SELECT public.set_eta_settings(''preprod'',''x'',NULL,NULL,false)','PERMISSION_DENIED');
SELECT t.error('permissions: get_eta_settings without org.settings_manage','SELECT public.get_eta_settings()','PERMISSION_DENIED');
SELECT t.error('permissions: set_device_eta without device.manage',format('SELECT public.set_device_eta(%L,''S'',''os'',''1'',NULL,''pending'')',t.id('pos1')),'PERMISSION_DENIED');
SELECT t.error('permissions: list_devices with neither device.manage nor org.settings_manage','SELECT public.list_devices()','PERMISSION_DENIED');
SELECT t.error('permissions: retry_fiscal_submission without fiscal.retry',format('SELECT public.retry_fiscal_submission(%L)',t.fid('s1')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a9020000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('permissions: shop B''s owner can''t retry shop A''s receipt',format('SELECT public.retry_fiscal_submission(%L)',t.fid('s1')),'FISCAL_NOT_FOUND');
SELECT t.error('permissions: shop B''s owner can''t register shop A''s device',format('SELECT public.set_device_eta(%L,''S'',''os'',''1'',NULL,''pending'')',t.id('pos1')),'DEVICE_NOT_FOUND');
SELECT t.expect('permissions: shop B''s owner sees only shop B''s device and no fiscal row of shop A (RLS)',
  (SELECT jsonb_array_length(public.list_devices())=1) AND (SELECT count(*)=0 FROM public.fiscal_submissions));
RESET ROLE;
SELECT t.as_user('a9020000-0000-0000-8000-000000000001',t.org('a'));

-- ---------------------------------------------------------------- the worker's view of what is pending
SELECT t.expect('load: the pending receipts of the POS, oldest first, with the chain tail and everything a receipt needs',
  (SELECT j->>'last_uuid' IS NULL AND jsonb_array_length(j->'rows')=3
     AND j->'rows'->0->>'fiscal_id'=t.fid('s1')::text AND j->'rows'->1->>'fiscal_id'=t.fid('s2')::text AND j->'rows'->2->>'fiscal_id'=t.fid('s3')::text
     AND j->'rows'->0->'sale'->>'issued_at' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' AND j->'rows'->0->'sale'->>'total'='1140.00'
     AND (j->'rows'->0->'sale'->>'prices_include_vat')::boolean AND j->'rows'->0->>'environment'='preprod'
     AND j->'rows'->0->'lines'->0->>'sku'='T2-TV' AND j->'rows'->0->'lines'->0->>'eta_item_code'='EG-674859545-TV'
     AND j->'rows'->0->'lines'->0->>'eta_item_type'='EGS' AND j->'rows'->0->'lines'->0->>'eta_tax_type'='T1'
     AND j->'rows'->0->'lines'->0->>'eta_subtype'='V009' AND j->'rows'->0->'lines'->0->>'tax_rate'='14.00'
     AND j->'rows'->0->'lines'->0->>'tax_amount'='140.00' AND j->'rows'->0->'lines'->0->>'line_total'='1140.00'
     AND j->'rows'->0->'payments'->0->>'method'='cash' AND j->'rows'->0->'payments'->0->>'amount'='1140.00'
     AND j->'rows'->0->'customer'='null'::jsonb
     AND j->'rows'->0->'seller'=jsonb_build_object('rin','674859545','name','T02 Shop A LLC','activity_code','4753','branch_code','0',
           'governorate','Cairo','city','Nasr City','street','16 Abbas El Akkad','building_number','14')
     AND j->'rows'->0->'device'=jsonb_build_object('id',t.id('pos1'),'serial','POS-A1','status','active','is_active',true)
   FROM (SELECT public.eta_load_pending_for_device(t.id('pos1')) j) x),
  public.eta_load_pending_for_device(t.id('pos1'))::text);
SELECT t.expect('load: another POS has nothing; the POS-less sales of a branch are loaded by branch',
  (SELECT jsonb_array_length(public.eta_load_pending_for_device(t.id('pos2'))->'rows')=0)
  AND (SELECT jsonb_array_length(j->'rows')=1 AND j->'rows'->0->'device'='null'::jsonb AND j->>'last_uuid' IS NULL
       FROM (SELECT public.eta_load_pending_for_device(NULL,t.id('second')) j) x)
  AND (SELECT jsonb_array_length(public.eta_load_pending_for_device(NULL,NULL)->'rows')=0)
  AND (SELECT jsonb_array_length(public.eta_load_pending_for_device(t.id('pos1'),NULL,2)->'rows')=2));

-- ---------------------------------------------------------------- 2. compare-and-set on the POS chain
SELECT t.error('chain: a UUID that is not 64 lower-case hex',format('SELECT public.eta_store_prepared(%L,''ABC'','''',''{"receipt_json":"{}"}'',''qr'')',t.fid('s1')),'VALIDATION_FAILED');
SELECT t.error('chain: a receipt can''t be its own previous',format('SELECT public.eta_store_prepared(%L,%L,%L,''{"receipt_json":"{}"}'',''qr'')',t.fid('s1'),t.u('1'),t.u('1')),'VALIDATION_FAILED');
SELECT public.eta_store_prepared(t.fid('s1'),t.u('1'),'','{"receipt_json":"{\"n\":1}"}','qr-1');
SELECT t.expect('chain: the first receipt of a POS is stored with previous "" and becomes the tail',
  t.tail('pos1')=t.u('1') AND (SELECT f.eta_uuid=t.u('1') AND f.previous_uuid='' AND f.qr_payload='qr-1' AND f.status='pending'
     AND f.payload->>'receipt_json'='{"n":1}' AND f.next_retry_at IS NULL FROM t.fiscal('s1') f));
SELECT t.error('chain: a second receipt hashed with the same previous UUID raises CHAIN_MOVED',
  format('SELECT public.eta_store_prepared(%L,%L,'''',''{"receipt_json":"{}"}'',''qr-2'')',t.fid('s2'),t.u('2')),'CHAIN_MOVED');
SELECT t.expect('chain: and changes nothing',t.tail('pos1')=t.u('1') AND (SELECT f.eta_uuid IS NULL AND f.payload IS NULL FROM t.fiscal('s2') f));
SELECT public.eta_store_prepared(t.fid('s2'),t.u('2'),t.u('1'),'{"receipt_json":"{\"n\":2}"}','qr-2');
SELECT public.eta_store_prepared(t.fid('s3'),t.u('3'),t.u('2'),'{"receipt_json":"{\"n\":3}"}','qr-3');
SELECT t.expect('chain: built again on the new tail it is stored; the tail advances in order (1 -> 2 -> 3)',
  t.tail('pos1')=t.u('3') AND (SELECT f.previous_uuid=t.u('1') FROM t.fiscal('s2') f) AND (SELECT f.previous_uuid=t.u('2') FROM t.fiscal('s3') f));
SELECT t.error('chain: a prepared receipt never changes (ALREADY_PREPARED)',
  format('SELECT public.eta_store_prepared(%L,%L,%L,''{"receipt_json":"{}"}'',''qr-x'')',t.fid('s1'),t.u('9'),t.u('3')),'ALREADY_PREPARED');
SELECT t.expect('chain: the unique index refuses a UUID twice in one shop',
  (SELECT count(*)=1 FROM pg_indexes WHERE schemaname='public' AND indexname='fiscal_submissions_org_eta_uuid_idx' AND indexdef LIKE '%UNIQUE%(organization_id, eta_uuid)%'));
SELECT t.expect('chain: storing a receipt queues the POS''s eta.submit job once',
  t.jobs('a','eta.submit')=1 AND (SELECT j.dedupe_key='eta.submit:'||t.id('pos1')::text AND j.payload->>'device_id'=t.id('pos1')::text
     FROM public.jobs j WHERE j.organization_id=t.org('a') AND j.job_type='eta.submit'));
SELECT t.expect('load: nothing is left to build for the POS, and the tail is returned with it',
  (SELECT jsonb_array_length(j->'rows')=0 AND j->>'last_uuid'=t.u('3') FROM (SELECT public.eta_load_pending_for_device(t.id('pos1')) j) x));

-- ---------------------------------------------------------------- blocked receipts
SELECT t.error('block: a code that is not BLOCKED:...',format('SELECT public.eta_block(%L,''NO_DEVICE'',''x'')',t.fid('nodev')),'VALIDATION_FAILED');
SELECT t.expect('block: the first call blocks the receipt, the second finds nothing to block',
  public.eta_block(t.fid('nodev'),'BLOCKED:NO_DEVICE','the sale was made without a POS') AND NOT public.eta_block(t.fid('nodev'),'BLOCKED:NO_DEVICE','again'));
SELECT t.expect('block: failed, the reason starts with its code, no automatic retry',
  (SELECT f.status='failed' AND f.last_error='BLOCKED:NO_DEVICE: the sale was made without a POS' AND f.next_retry_at IS NULL AND f.eta_uuid IS NULL AND f.attempts=1
   FROM t.fiscal('nodev') f));
SELECT t.expect('block: a prepared receipt can''t be blocked',NOT public.eta_block(t.fid('s1'),'BLOCKED:ITEM_CODE','x') AND (SELECT f.status='pending' FROM t.fiscal('s1') f));
SELECT t.expect('sale status: what the sale answer shows of a blocked and of a prepared receipt',
  public.eta_sale_status(t.org('a'),t.id('nodev'))=jsonb_build_object('status','failed','uuid',NULL,'qr_payload',NULL,'last_error_code','BLOCKED:NO_DEVICE',
    'device_id',NULL,'branch_id',t.id('second'))
  AND public.eta_sale_status(t.org('a'),t.id('s1'))=jsonb_build_object('status','pending','uuid',t.u('1'),'qr_payload','qr-1','last_error_code',NULL,
    'device_id',t.id('pos1'),'branch_id',t.id('main'))
  AND public.eta_sale_status(t.org('a'),t.id('s0')) IS NULL AND public.eta_sale_status(t.org('b'),t.id('s1')) IS NULL);

-- ---------------------------------------------------------------- claiming, marking, retrying
SELECT t.expect('claim: the prepared receipts that are due, oldest first, with their exact text; none was sent before',
  (SELECT jsonb_array_length(j)=2 AND j->0->>'fiscal_id'=t.fid('s1')::text AND j->1->>'fiscal_id'=t.fid('s2')::text
     AND j->0->>'receipt_json'='{"n":1}' AND j->0->>'uuid'=t.u('1') AND NOT (j->0->>'was_sent')::boolean AND (j->0->>'attempts')::int=0
     AND j->0->>'environment'='preprod' AND j->0->>'internal_id'=(SELECT number FROM public.sales WHERE id=t.id('s1'))
   FROM (SELECT public.eta_claim_for_submit(t.id('pos1'),2) j) x));
SELECT t.expect('claim: a claimed receipt is leased: a second worker gets only what is left',
  (SELECT jsonb_array_length(j)=1 AND j->0->>'fiscal_id'=t.fid('s3')::text FROM (SELECT public.eta_claim_for_submit(t.id('pos1'),50) j) x)
  AND (SELECT jsonb_array_length(public.eta_claim_for_submit(t.id('pos1'),50))=0)
  AND (SELECT f.next_retry_at>now()+interval '4 minutes' AND (f.payload->>'sent')::boolean AND f.payload->>'receipt_json'='{"n":1}' FROM t.fiscal('s1') f));
SELECT t.error('mark: accepted straight from pending is not a transition',format('SELECT public.eta_mark(%L,''accepted'')',t.fid('s1')),'FISCAL_BAD_TRANSITION');
SELECT t.error('mark: a receipt that was never prepared can''t be marked',format('SELECT public.eta_mark(%L,''submitted'')',t.fid('nodev')),'FISCAL_BAD_TRANSITION');
SELECT t.error('mark: a retry time that is not a number',format('SELECT public.eta_mark(%L,''pending'',''{"retry_in_seconds":"soon"}'')',t.fid('s1')),'VALIDATION_FAILED');
-- s1: a send that failed (unknown outcome), then found at the ETA, then Valid.
SELECT t.expect('mark: a failed send keeps the receipt pending, counts the attempt and sets the next try',
  public.eta_mark(t.fid('s1'),'pending','{"last_error":"ETA_UNREACHABLE: timeout","retry_in_seconds":60}')='pending'
  AND (SELECT f.status='pending' AND f.attempts=1 AND f.last_error='ETA_UNREACHABLE: timeout'
     AND f.next_retry_at BETWEEN now()+interval '50 seconds' AND now()+interval '70 seconds' FROM t.fiscal('s1') f));
SELECT t.expect('mark: and queues the POS''s eta.submit job for then (the one already queued is kept, not doubled)',t.jobs('a','eta.submit')=1);
SELECT t.expect('claim: not due yet -> not claimed',(SELECT jsonb_array_length(public.eta_claim_for_submit(t.id('pos1'),50))=0));
UPDATE public.fiscal_submissions SET next_retry_at=now()-interval '1 second' WHERE id=t.fid('s1');
SELECT t.expect('claim: due again -> claimed, and flagged as sent before (the worker looks it up first)',
  (SELECT jsonb_array_length(j)=1 AND j->0->>'fiscal_id'=t.fid('s1')::text AND (j->0->>'was_sent')::boolean AND (j->0->>'attempts')::int=1
   FROM (SELECT public.eta_claim_for_submit(t.id('pos1'),50) j) x));
SELECT t.expect('mark: submitted stores the long id, the submission and the time, and clears the error',
  public.eta_mark(t.fid('s1'),'submitted','{"eta_long_id":"LONG1","eta_submission_uuid":"SUB1","poll_in_seconds":30}')='submitted'
  AND (SELECT f.status='submitted' AND f.eta_long_id='LONG1' AND f.eta_submission_uuid='SUB1' AND f.submitted_at IS NOT NULL AND f.last_error IS NULL
     AND f.next_retry_at IS NULL AND f.accepted_at IS NULL AND f.attempts=1 FROM t.fiscal('s1') f));
SELECT t.expect('mark: and queues one eta.poll job for the submission, 30 s from now',
  (SELECT count(*)=1 AND bool_and(j.dedupe_key='eta.poll:SUB1:0' AND j.payload=jsonb_build_object('submission_uuid','SUB1','device_id',t.id('pos1'),'n',0)
     AND j.run_at BETWEEN now()+interval '20 seconds' AND now()+interval '40 seconds')
   FROM public.jobs j WHERE j.organization_id=t.org('a') AND j.job_type='eta.poll'));
SELECT public.eta_mark(t.fid('s2'),'submitted','{"eta_long_id":"LONG2","eta_submission_uuid":"SUB1"}');
SELECT t.expect('poll: the receipts of a submission that still wait for an answer',
  (SELECT jsonb_array_length(j)=2 AND j->0->>'uuid' IN (t.u('1'),t.u('2')) FROM (SELECT public.eta_load_submitted(t.org('a'),'SUB1') j) x)
  AND (SELECT jsonb_array_length(public.eta_load_submitted(t.org('b'),'SUB1'))=0)
  AND (SELECT count(*)=1 FROM public.jobs j WHERE j.organization_id=t.org('a') AND j.job_type='eta.poll'));
SELECT t.expect('mark: Valid -> accepted with accepted_at',
  public.eta_mark(t.fid('s1'),'accepted','{"eta_long_id":"LONG1"}')='accepted'
  AND (SELECT f.status='accepted' AND f.accepted_at IS NOT NULL AND f.eta_uuid=t.u('1') FROM t.fiscal('s1') f));
SELECT t.expect('mark: Invalid -> rejected with the reason, counted as an attempt',
  public.eta_mark(t.fid('s2'),'rejected','{"last_error":"ETA_INVALID: CV307 bad item code"}')='rejected'
  AND (SELECT f.status='rejected' AND f.last_error='ETA_INVALID: CV307 bad item code' AND f.attempts=1 AND f.accepted_at IS NULL FROM t.fiscal('s2') f),
  (SELECT concat_ws(' / ',f.status,f.attempts,f.last_error,f.accepted_at) FROM t.fiscal('s2') f));
-- A statement of its own: a STABLE read in the statement that writes would still see the old rows.
SELECT t.expect('poll: with both answered, nothing of the submission is left to poll',
  (SELECT jsonb_array_length(public.eta_load_submitted(t.org('a'),'SUB1'))=0));

-- ---------------------------------------------------------------- 5. freeze, and the environment
SELECT t.error('freeze: an accepted row can''t be changed',format('UPDATE public.fiscal_submissions SET last_error=''x'' WHERE id=%L',t.fid('s1')),'DOCUMENT_FINAL');
SELECT t.state('freeze: accepted without accepted_at is refused by the CHECK',
  format('UPDATE public.fiscal_submissions SET status=''accepted'' WHERE id=%L',t.fid('s3')),'23514');
SELECT t.expect('freeze: a repeated poll of an accepted or rejected receipt changes nothing and raises nothing',
  public.eta_mark(t.fid('s1'),'accepted')='accepted' AND public.eta_mark(t.fid('s1'),'rejected','{"last_error":"late"}')='accepted'
  AND public.eta_mark(t.fid('s2'),'rejected','{"last_error":"again"}')='rejected'
  AND (SELECT f.last_error IS NULL FROM t.fiscal('s1') f) AND (SELECT f.attempts=1 AND f.last_error LIKE 'ETA_INVALID%' FROM t.fiscal('s2') f));
SET ROLE authenticated;
SELECT t.error('environment: can''t switch while a receipt is pending','SELECT public.set_eta_settings(''prod'',''client-a'',NULL,''4753'',true)','ETA_ENV_BUSY');
RESET ROLE;
SELECT public.eta_mark(t.fid('s3'),'submitted','{"eta_submission_uuid":"SUB2"}');
SET ROLE authenticated;
SELECT t.error('environment: nor while one is submitted','SELECT public.set_eta_settings(''prod'',''client-a'',NULL,''4753'',true)','ETA_ENV_BUSY');
SELECT t.expect('environment: the other settings can still change while receipts are on their way',
  (SELECT j->>'activity_code'='4754' AND j->>'environment'='preprod' FROM (SELECT public.set_eta_settings('preprod','client-a',NULL,'4754',true) j) x));

-- ---------------------------------------------------------------- the manual retry
SELECT t.error('retry: a receipt that is submitted is not retryable',format('SELECT public.retry_fiscal_submission(%L)',t.fid('s3')),'FISCAL_NOT_RETRYABLE');
SELECT t.error('retry: nor an accepted one',format('SELECT public.retry_fiscal_submission(%L)',t.fid('s1')),'FISCAL_NOT_RETRYABLE');
SELECT t.error('retry: an unknown id','SELECT public.retry_fiscal_submission(''00000000-0000-4000-8000-000000000000'')','FISCAL_NOT_FOUND');
SELECT t.expect('retry: a blocked receipt goes back to pending',public.retry_fiscal_submission(t.fid('nodev'))=jsonb_build_object('id',t.fid('nodev'),'status','pending'));
SELECT t.expect('retry: a rejected receipt goes back to pending with its UUID',public.retry_fiscal_submission(t.fid('s2'))->>'status'='pending');
RESET ROLE;
SELECT t.expect('retry: no UUID -> eta.prepare is queued again (by branch); with a UUID -> eta.submit; both due now',
  (SELECT f.status='pending' AND f.eta_uuid IS NULL AND f.next_retry_at<=now() FROM t.fiscal('nodev') f)
  AND (SELECT f.status='pending' AND f.eta_uuid=t.u('2') AND f.next_retry_at<=now() AND f.attempts=1 FROM t.fiscal('s2') f)
  AND EXISTS(SELECT 1 FROM public.jobs j WHERE j.job_type='eta.prepare' AND j.dedupe_key='eta.prepare:'||t.id('second')::text AND j.status='queued')
  AND EXISTS(SELECT 1 FROM public.jobs j WHERE j.job_type='eta.submit' AND j.dedupe_key='eta.submit:'||t.id('pos1')::text AND j.status='queued' AND j.run_at<=now()));
SELECT t.expect('retry: one audit row each, with the status it left',
  (SELECT count(*)=2 AND bool_and(a.after->>'status'='pending' AND a.before->>'status' IN ('failed','rejected') AND a.entity_type='fiscal_submission')
   FROM public.audit_log a WHERE a.organization_id=t.org('a') AND a.action='fiscal.retry_requested'));
SELECT t.expect('claim: the retried receipt is sent as it is (same UUID, same text), flagged as sent before',
  (SELECT jsonb_array_length(j)=1 AND j->0->>'uuid'=t.u('2') AND j->0->>'receipt_json'='{"n":2}' AND (j->0->>'was_sent')::boolean
   FROM (SELECT public.eta_claim_for_submit(t.id('pos1'),50) j) x));

-- ---------------------------------------------------------------- the 20-hour alert, once
SELECT t.expect('deadline: nothing is late now',(SELECT jsonb_array_length(public.eta_claim_deadline_alerts(t.id('pos1'),20,now()))=0));
SELECT t.expect('deadline: 21 hours on, the pending receipt is returned, the final and submitted ones are not',
  (SELECT jsonb_array_length(j)=1 AND j->0->>'fiscal_id'=t.fid('s2')::text AND j->0->>'internal_id' IS NOT NULL
   FROM (SELECT public.eta_claim_deadline_alerts(t.id('pos1'),20,now()+interval '21 hours') j) x));
SELECT t.expect('deadline: and exactly once',
  (SELECT jsonb_array_length(public.eta_claim_deadline_alerts(t.id('pos1'),20,now()+interval '22 hours'))=0)
  AND (SELECT f.payload ? 'deadline_alerted_at' AND f.payload->>'receipt_json'='{"n":2}' FROM t.fiscal('s2') f));

-- ---------------------------------------------------------------- the queue helper
SELECT t.error('enqueue: only the three ETA job types',format('SELECT public.eta_enqueue(%L,''ledger.reconcile'',''k'',''{}'')',t.org('a')),'VALIDATION_FAILED');
SELECT public.eta_enqueue(t.org('a'),'eta.poll','eta.poll:SUBX:1','{"n":1}',600);
SELECT public.eta_enqueue(t.org('a'),'eta.poll','eta.poll:SUBX:1','{"n":1}',0);
SELECT t.expect('enqueue: the same key again keeps one job and pulls it earlier',
  (SELECT count(*)=1 AND bool_and(j.run_at<=now()) FROM public.jobs j WHERE j.job_type='eta.poll' AND j.dedupe_key='eta.poll:SUBX:1'));
UPDATE public.jobs SET status='running',locked_at=now(),locked_by='w' WHERE job_type='eta.poll' AND dedupe_key='eta.poll:SUBX:1';
SELECT public.eta_enqueue(t.org('a'),'eta.poll','eta.poll:SUBX:1','{"n":1}',0);
SELECT public.eta_enqueue(t.org('a'),'eta.poll','eta.poll:SUBX:1','{"n":1}',0);
SELECT t.expect('enqueue: behind a running job with the key, exactly one follow-up is queued',
  (SELECT count(*)=1 FROM public.jobs j WHERE j.job_type='eta.poll' AND j.dedupe_key='eta.poll:SUBX:1#next' AND j.status='queued')
  AND (SELECT count(*)=2 FROM public.jobs j WHERE j.job_type='eta.poll' AND j.dedupe_key LIKE 'eta.poll:SUBX:1%'));

-- ---------------------------------------------------------------- the environment switch and the chains
SELECT public.eta_mark(t.fid('s2'),'rejected','{"last_error":"ETA_INVALID: still"}');
SELECT public.eta_mark(t.fid('s3'),'accepted');
SELECT public.eta_block(t.fid('nodev'),'BLOCKED:NO_DEVICE','no POS');
SET ROLE authenticated;
SELECT t.expect('environment: with nothing pending or submitted the switch to prod is allowed',
  (SELECT j->>'environment'='prod' FROM (SELECT public.set_eta_settings('prod','client-a',NULL,'4754',true) j) x));
RESET ROLE;
SELECT t.expect('environment: each POS starts a new chain in prod (no prod receipt yet)',t.tail('pos1') IS NULL);
SET ROLE authenticated;
SELECT t.error('retry: a receipt made for preprod is never sent to prod',format('SELECT public.retry_fiscal_submission(%L)',t.fid('s2')),'ETA_ENV_MISMATCH');
SELECT t.sell('s4');
RESET ROLE;
SELECT t.expect('environment: a sale made now belongs to prod',(SELECT f.environment='prod' AND f.status='pending' FROM t.fiscal('s4') f));
SELECT public.eta_store_prepared(t.fid('s4'),t.u('4'),'','{"receipt_json":"{\"n\":4}"}','qr-4');
SELECT public.eta_mark(t.fid('s4'),'rejected','{"last_error":"ETA_REJECTED: test"}');
SET ROLE authenticated;
SELECT public.set_eta_settings('preprod','client-a',NULL,'4754',true);
RESET ROLE;
SELECT t.expect('environment: back in preprod each POS goes on from its last preprod receipt',t.tail('pos1')=t.u('3'));
SELECT t.expect('environment: the audit log has every change of the settings; turning ETA on and the two switches are warnings',
  (SELECT count(*)=6 AND count(*) FILTER(WHERE a.severity='warning')=3 FROM public.audit_log a WHERE a.organization_id=t.org('a') AND a.action='eta.settings_updated'),
  (SELECT string_agg(a.severity::text,',' ORDER BY a.id) FROM public.audit_log a WHERE a.organization_id=t.org('a') AND a.action='eta.settings_updated'));

-- ---------------------------------------------------------------- a new serial is a new POS
SET ROLE authenticated;
SELECT public.set_device_eta(t.id('pos1'),'POS-A1-NEW','android 14','1',NULL,'active');
RESET ROLE;
SELECT t.expect('device: a new serial starts the POS chain again and keeps the key',
  t.tail('pos1') IS NULL AND public.eta_credentials(t.org('a'),t.id('pos1'))->>'pos_serial'='POS-A1-NEW'
  AND public.eta_credentials(t.org('a'),t.id('pos1'))->>'preshared_key'='key-a1-xyz');

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
