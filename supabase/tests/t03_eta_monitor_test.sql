-- T03 ETA submission monitor and corrections (EC-91).
-- Run by: node scripts/db-smoke.mjs supabase/tests/t03_eta_monitor_test.sql (inside BEGIN ... ROLLBACK).
-- Every receipt is in one situation (waiting, accepted, cancelled, blocked, send_failed, rejected) with a
-- deadline; a rejected one is never retried as it is: a correction is requested (a job), stored by the
-- worker with a new UUID and referenceOldUUID, and moves the POS chain head only when it was the newest.
-- The event log is append-only and never holds the payload. Rows are built with T02's real worker
-- functions; a state is forced as the database owner only where no function makes it (send_failed,
-- cancelled).
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (see t02_eta_test.sql).
CREATE FUNCTION t.pos(p_branch uuid, p_device uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_org uuid := app.current_org_id(); v_id uuid := p_device; v_hash text;
BEGIN
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch AND b.organization_id = v_org) THEN
    RETURN NULL;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.devices (organization_id, branch_id, name) VALUES (v_org, p_branch, 'Test POS ' || gen_random_uuid())
    RETURNING id INTO v_id;
  END IF;
  UPDATE public.devices d
     SET token_hash = COALESCE(d.token_hash, encode(sha256(convert_to(d.id::text, 'UTF8')), 'hex')),
         paired_at = COALESCE(d.paired_at, now())
   WHERE d.id = v_id AND d.organization_id = v_org
  RETURNING d.token_hash INTO v_hash;
  PERFORM set_config('request.headers',
    (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb
       || jsonb_build_object('x-device-id', v_id, 'x-device-token-hash', v_hash))::text, false);
  RETURN v_id;
END $$;
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text, p_vault uuid DEFAULT NULL, p_device uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(p_branch, p_device);
  RETURN public.open_shift(p_branch, p_float, p_key, p_vault, p_device);
END $$;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
-- The statement must fail with an error whose message starts with the code c.
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.state(n text,q text,s text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND SQLSTATE=s,SQLSTATE||' '||SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q) $$;
-- A sha-256 shaped UUID made of one hex digit.
CREATE FUNCTION t.u(c text) RETURNS text LANGUAGE sql AS $$ SELECT left(repeat(c,64),64) $$;
CREATE FUNCTION t.fiscal(sale text) RETURNS public.fiscal_submissions LANGUAGE sql SECURITY DEFINER AS $$
  SELECT f FROM public.fiscal_submissions f WHERE f.sale_id=t.id(sale) $$;
CREATE FUNCTION t.fid(sale text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT f.id FROM public.fiscal_submissions f WHERE f.sale_id=t.id(sale) $$;
CREATE FUNCTION t.tail(device text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT d.eta_last_uuid FROM public.devices d WHERE d.id=t.id(device) $$;
CREATE FUNCTION t.jobs(shop text,kind text,st text DEFAULT 'queued') RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.jobs j WHERE j.organization_id=t.org(shop) AND j.job_type=kind AND j.status::text=st $$;
CREATE FUNCTION t.events(sale text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.fiscal_events e WHERE e.fiscal_id=t.fid(sale) $$;
CREATE FUNCTION t.audits(shop text,act text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.audit_log a WHERE a.organization_id=t.org(shop) AND a.action=act $$;
-- A sale of the caller's open shift: one unit of a product at 1 140.00.
CREATE FUNCTION t.sell(tag text,product text DEFAULT 'tv') RETURNS void LANGUAGE sql AS $$
  INSERT INTO t.ids SELECT tag,(public.post_sale(t.lines(t.items(product,1)),'1140.00','t03-sale-'||tag)->>'id')::uuid $$;
-- A consumer sale as the database owner (its fiscal row comes from T02's trigger): the shop, a tag,
-- branch, POS (or NULL), total, how long ago it was issued, its customer and business day.
CREATE FUNCTION t.mksale(shop text,tag text,branch text,dev text,total numeric,ago interval DEFAULT '0',
                         cust uuid DEFAULT NULL,bdate date DEFAULT current_date) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO public.sales(organization_id,number,branch_id,device_id,customer_id,kind,is_b2b,prices_include_vat,subtotal,total,
                           business_date,idempotency_key,issued_at)
  VALUES(t.org(shop),'T03-'||tag,t.id(branch),CASE WHEN dev IS NULL THEN NULL ELSE t.id(dev) END,cust,'pos',false,true,total,total,
         bdate,'t03-sale-'||tag,now()-ago) RETURNING id INTO v;
  INSERT INTO t.ids VALUES(tag,v);
  RETURN v;
END $$;
-- The worker's steps, as T02's functions: built (UUID char c on top of the previous char), rejected, blocked.
CREATE FUNCTION t.prep(tag text,c text,prev text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  SELECT public.eta_store_prepared(t.fid(tag),t.u(c),COALESCE(t.u(prev),''),
         jsonb_build_object('receipt_json','{"n":"'||c||'"}'),'qr-'||c) $$;
CREATE FUNCTION t.reject(tag text,msg text) RETURNS void LANGUAGE sql AS $$
  SELECT public.eta_mark(t.fid(tag),'rejected',jsonb_build_object('last_error',msg)) $$;
CREATE FUNCTION t.block(tag text,code text) RETURNS void LANGUAGE sql AS $$
  SELECT public.eta_block(t.fid(tag),code,'test') $$;
-- What a user sees of one receipt through the monitor.
CREATE FUNCTION t.sit(tag text) RETURNS text LANGUAGE sql AS $$ SELECT public.fiscal_details(t.fid(tag))->>'situation' $$;
CREATE FUNCTION t.dg(tag text) RETURNS jsonb LANGUAGE sql AS $$ SELECT public.fiscal_diagnose(t.fid(tag)) $$;
CREATE FUNCTION t.has(d jsonb,code text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT EXISTS(SELECT 1 FROM jsonb_array_elements(d->'problems') p WHERE p->>'code'=code) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a (monitor), b (other shop), c (summaries)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('T03 '||s,'t03-'||s,'retail_pro','Owner',s||'t03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('u',64)),('b',repeat('v',64)),('c',repeat('w',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a9031000-0000-0000-8000-000000000001','at03@example.com'),('a9031000-0000-0000-8000-000000000002','bt03@example.com'),
  ('a9031000-0000-0000-8000-000000000003','ct03@example.com'),('a9031000-0000-0000-8000-000000000004','t03cashier@example.com'),
  ('a9031000-0000-0000-8000-000000000005','t03acct@example.com'),('a9031000-0000-0000-8000-000000000006','t03acctc@example.com');
SELECT public.accept_invite(repeat('u',64),'a9031000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('v',64),'a9031000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('w',64),'a9031000-0000-0000-8000-000000000003');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'bmain',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'cmain',id FROM public.branches WHERE organization_id=t.org('c') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id IN (t.org('a'),t.org('b'),t.org('c'));
UPDATE public.organizations SET tax_registration_no='674859545',legal_name='T03 Shop A LLC' WHERE id=t.org('a');
UPDATE public.organizations SET tax_registration_no='313717919',legal_name='T03 Shop C LLC' WHERE id=t.org('c');
-- POS devices (O03 makes them through the API; the test inserts them as the database owner).
WITH d AS (INSERT INTO public.devices(organization_id,branch_id,name,is_active) VALUES
    (t.org('a'),t.id('main'),'POS 1',true),(t.org('a'),t.id('main'),'POS 2',true),(t.org('a'),t.id('main'),'POS 3',true),
    (t.org('a'),t.id('main'),'POS Off',false),(t.org('b'),t.id('bmain'),'B POS',true),(t.org('c'),t.id('cmain'),'C POS',true)
  RETURNING id,name)
INSERT INTO t.ids SELECT CASE name WHEN 'POS 1' THEN 'pos1' WHEN 'POS 2' THEN 'pos2' WHEN 'POS 3' THEN 'pos3'
  WHEN 'POS Off' THEN 'posoff' WHEN 'B POS' THEN 'bpos' ELSE 'cpos' END,id FROM d;
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES
  (t.org('a'),'a9031000-0000-0000-8000-000000000004','T03 Cashier','CASHIER',t.id('main')),
  (t.org('a'),'a9031000-0000-0000-8000-000000000005','T03 Accountant','ACCOUNTANT',t.id('main')),
  (t.org('c'),'a9031000-0000-0000-8000-000000000006','T03 Accountant C','ACCOUNTANT',t.id('cmain'));
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id)
  SELECT e.organization_id,e.id,e.default_branch_id FROM public.employees e
  WHERE e.auth_user_id IN ('a9031000-0000-0000-8000-000000000004','a9031000-0000-0000-8000-000000000005','a9031000-0000-0000-8000-000000000006');
CREATE FUNCTION t.owner_a() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9031000-0000-0000-8000-000000000001',t.org('a')) $$;
CREATE FUNCTION t.owner_b() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9031000-0000-0000-8000-000000000002',t.org('b')) $$;
CREATE FUNCTION t.owner_c() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9031000-0000-0000-8000-000000000003',t.org('c')) $$;
CREATE FUNCTION t.cashier() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9031000-0000-0000-8000-000000000004',t.org('a')) $$;
CREATE FUNCTION t.acct_a() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9031000-0000-0000-8000-000000000005',t.org('a')) $$;
CREATE FUNCTION t.acct_c() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9031000-0000-0000-8000-000000000006',t.org('c')) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- Shop a: products (one with an ETA item code, one without), stock, ETA on, branch data, one open shift on POS 1.
SELECT t.owner_a();
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"T3-TV","cash_price":"1140","eta_item_code":"EG-674859545-TV","eta_item_type":"EGS"}'));
INSERT INTO t.ids VALUES('nocode',public.create_product('{"name_ar":"مروحة","name_en":"Fan","sku":"T3-FAN","cash_price":"1140"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('tv'),'quantity',40),jsonb_build_object('product_id',t.id('nocode'),'quantity',40)),'t03-found');
SELECT public.update_branch(t.id('main'),'Main','16 Abbas El Akkad','Nasr City','Cairo',NULL,'0',
  (SELECT default_cash_account_id FROM public.branches WHERE id=t.id('main')),'14');
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
SELECT public.set_eta_settings('preprod','client-a','secret-a-1','4753',true);
SELECT public.set_device_eta(t.id('pos1'),'POS-A1','android 14','1','key-a1','active');
SELECT t.open_shift(t.id('main'),'0','t03-shift-owner',NULL,t.id('pos1'));
RESET ROLE;
-- Devices of the second branch: one active and registered with the ETA, one off.
WITH d AS (INSERT INTO public.devices(organization_id,branch_id,name,is_active) VALUES
    (t.org('a'),t.id('second'),'POS S',true),(t.org('a'),t.id('second'),'POS S Off',false) RETURNING id,name)
INSERT INTO t.ids SELECT CASE name WHEN 'POS S' THEN 'poss' ELSE 'possoff' END,id FROM d;
UPDATE public.devices SET eta_status='active',eta_serial='POS-S1' WHERE id=t.id('poss');
-- Shops b and c: ETA on, branch data.
SELECT t.owner_b();
SET ROLE authenticated;
SELECT public.set_eta_settings('preprod','client-b','secret-b-1','4753',true);
RESET ROLE;
SELECT t.owner_c();
SET ROLE authenticated;
SELECT public.update_branch(t.id('cmain'),'Main','1 St','Giza','Giza',NULL,'0',
  (SELECT default_cash_account_id FROM public.branches WHERE id=t.id('cmain')),'1');
INSERT INTO t.ids VALUES('csecond',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
SELECT public.set_eta_settings('preprod','client-c','secret-c-1','4753',true);
RESET ROLE;

-- ---------------------------------------------------------------- 1. situations (shop a)
-- Real sales (the owner's shift on POS 1) and sales made as the database owner, each pushed to its state
-- by T02's functions; a state no function makes is forced.
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.sell('r_ok');          -- accepted
SELECT t.sell('r_nc','nocode'); -- blocked: no item code
SELECT t.sell('r_rej');         -- rejected
SELECT t.sell('r_head');        -- rejected, will be corrected while it is the newest of its POS
RESET ROLE;
SELECT t.mksale('a','w','main','pos1',1140);                       -- waiting (not built yet)
SELECT t.mksale('a','sub','main','pos1',1140);                     -- submitted
SELECT t.mksale('a','snd','main','pos1',1140);                     -- send_failed (forced)
SELECT t.mksale('a','can','main','pos1',1140);                     -- cancelled (forced)
SELECT t.prep('r_ok','1');
SELECT t.prep('r_rej','2','1');
SELECT t.prep('sub','3','2');
SELECT t.prep('snd','4','3');
SELECT t.prep('can','5','4');
SELECT public.eta_mark(t.fid('r_ok'),'submitted','{"eta_submission_uuid":"SUB1"}');
SELECT public.eta_mark(t.fid('r_ok'),'accepted');
SELECT t.reject('r_rej','ETA_INVALID: CV307 itemData[0].itemCode: the item code is not registered; details: x');
SELECT public.eta_mark(t.fid('sub'),'submitted','{"eta_submission_uuid":"SUB2"}');
UPDATE public.fiscal_submissions SET status='failed',last_error='ETA_UNREACHABLE: down' WHERE id=t.fid('snd');
UPDATE public.fiscal_submissions SET status='cancelled' WHERE id=t.fid('can');
SELECT t.block('r_nc','BLOCKED:ITEM_CODE');
SELECT t.expect('situations: one row per situation, each classified right',
  t.sit('w')='waiting' AND t.sit('sub')='waiting' AND t.sit('r_ok')='accepted' AND t.sit('can')='cancelled'
  AND t.sit('r_nc')='blocked' AND t.sit('snd')='send_failed' AND t.sit('r_rej')='rejected',
  concat_ws(',',t.sit('w'),t.sit('sub'),t.sit('r_ok'),t.sit('can'),t.sit('r_nc'),t.sit('snd'),t.sit('r_rej')));
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('situations: the list says the same, with the branch, the device and a short error',
  (SELECT count(*)=3 AND bool_and(i->>'branch_name'='Main' AND i->>'device_name'='POS 1' AND length(coalesce(i->>'short_error',''))<=120)
     AND bool_and(i->>'situation'=CASE i->>'id' WHEN t.fid('w')::text THEN 'waiting' WHEN t.fid('r_rej')::text THEN 'rejected' ELSE 'blocked' END)
   FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) i
   WHERE i->>'id' IN (t.fid('w')::text,t.fid('r_rej')::text,t.fid('r_nc')::text)));
SELECT t.expect('situations: filter "problem" gives blocked, send_failed and rejected only',
  (SELECT count(*)=3 AND bool_and(i->>'situation' IN ('blocked','send_failed','rejected'))
     AND count(*) FILTER(WHERE i->>'situation'='blocked')=1 AND count(*) FILTER(WHERE i->>'situation'='send_failed')=1
     AND count(*) FILTER(WHERE i->>'situation'='rejected')=1
   FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,'problem',NULL,100)) i));
SELECT t.error('situations: an unknown situation is refused','SELECT public.fiscal_list(NULL,NULL,NULL,''nonsense'')','VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- 2. sort and deadline
SELECT t.mksale('a','dl19','main','pos1',1140,interval '19 hours');
SELECT t.mksale('a','dl21','main','pos1',1140,interval '21 hours');
SELECT t.mksale('a','dl23','main','pos1',1140,interval '23 hours');
SELECT t.mksale('a','dl25','main','pos1',1140,interval '25 hours');
SELECT t.mksale('a','dlc25','main','pos1',1140,interval '25 hours');
SELECT t.mksale('a','dlc95','main','pos1',1140,interval '95 hours');
SELECT t.mksale('a','dlc97','main','pos1',1140,interval '97 hours');
UPDATE public.fiscal_submissions SET reference_old_uuid=t.u('e') WHERE id IN (t.fid('dlc25'),t.fid('dlc95'),t.fid('dlc97'));
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('deadline: a first submission: ok at 19 h, due soon at 21 h and 23 h (under 4 h left), overdue at 25 h',
  t.dg('dl19')->>'deadline_state'='ok' AND t.dg('dl21')->>'deadline_state'='due_soon'
  AND t.dg('dl23')->>'deadline_state'='due_soon' AND t.dg('dl25')->>'deadline_state'='overdue',
  concat_ws(',',t.dg('dl19')->>'deadline_state',t.dg('dl21')->>'deadline_state',t.dg('dl23')->>'deadline_state',t.dg('dl25')->>'deadline_state'));
SELECT t.expect('deadline: a correction (referenceOldUUID) has 96 h: ok at 25 h, due soon at 95 h, overdue at 97 h',
  t.dg('dlc25')->>'deadline_state'='ok' AND t.dg('dlc95')->>'deadline_state'='due_soon' AND t.dg('dlc97')->>'deadline_state'='overdue');
SELECT t.expect('deadline: deadline_at is issue + 24 h (+ 96 h for a correction) and a sale shows it in the list',
  (SELECT (i->>'deadline_at')::timestamptz = (SELECT issued_at+interval '24 hours' FROM public.sales WHERE id=t.id('dl23'))
   FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,'T03-dl23')) i)
  AND (t.dg('dl23')->>'deadline_at')::timestamptz = (SELECT issued_at+interval '24 hours' FROM public.sales WHERE id=t.id('dl23')));
SELECT t.expect('deadline: nothing to wait for once accepted, cancelled or at the ETA',
  t.dg('r_ok')->>'deadline_at' IS NULL AND t.dg('can')->>'deadline_at' IS NULL AND t.dg('sub')->>'deadline_at' IS NULL
  AND t.dg('r_ok')->>'deadline_state'='ok');
RESET ROLE;
-- A rejected receipt waits for its correction: 96 h.
SELECT t.mksale('a','rjold','main','pos1',1140,interval '97 hours');
SELECT t.prep('rjold','6','5');
SELECT t.reject('rjold','ETA_INVALID: old');
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('deadline: a rejected receipt 97 h after issue is overdue',t.dg('rjold')->>'deadline_state'='overdue');
SELECT t.expect('sort: every overdue row comes before every due-soon row, and those before the rest',
  (SELECT max(ord) FILTER (WHERE i->>'deadline_state'='overdue') < min(ord) FILTER (WHERE i->>'deadline_state'='due_soon')
      AND max(ord) FILTER (WHERE i->>'deadline_state'='due_soon') < min(ord) FILTER (WHERE i->>'deadline_state'='ok')
   FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) WITH ORDINALITY x(i,ord)));
SELECT t.expect('sort: the first rows of the list are the overdue ones and a problem comes before a waiting receipt of the same day',
  (SELECT bool_and(i->>'deadline_state'='overdue') FROM (SELECT i FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) WITH ORDINALITY x(i,ord) ORDER BY ord LIMIT 3) y)
  AND (SELECT min(ord) FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) WITH ORDINALITY x(i,ord) WHERE i->>'situation'='rejected' AND i->>'deadline_state'='ok')
    < (SELECT min(ord) FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) WITH ORDINALITY x(i,ord) WHERE i->>'situation'='waiting' AND i->>'deadline_state'='ok'));
RESET ROLE;

-- ---------------------------------------------------------------- 3. decision 1: no plain retry of a rejected receipt
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.error('retry: a rejected receipt is USE_CORRECTION',format('SELECT public.retry_fiscal_submission(%L)',t.fid('r_rej')),'USE_CORRECTION');
SELECT t.expect('retry: a blocked receipt still goes back to pending (prepare queued)',
  public.retry_fiscal_submission(t.fid('r_nc'))->>'status'='pending');
SELECT t.expect('retry: a failed receipt with a UUID still goes back to pending (submit queued)',
  public.retry_fiscal_submission(t.fid('snd'))->>'status'='pending');
RESET ROLE;
SELECT t.expect('retry: the rejected receipt is unchanged, the other two are pending',
  (SELECT f.status='rejected' AND f.eta_uuid=t.u('2') FROM t.fiscal('r_rej') f)
  AND (SELECT f.status='pending' AND f.eta_uuid IS NULL FROM t.fiscal('r_nc') f)
  AND (SELECT f.status='pending' AND f.eta_uuid=t.u('4') FROM t.fiscal('snd') f));
-- Back to the states the next cases need.
SELECT t.block('r_nc','BLOCKED:ITEM_CODE');
UPDATE public.fiscal_submissions SET status='failed',last_error='ETA_UNREACHABLE: down' WHERE id=t.fid('snd');

-- ---------------------------------------------------------------- 4. request a correction
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.error('request: a receipt that is not rejected is NOT_REJECTED',format('SELECT public.fiscal_request_correction(%L)',t.fid('w')),'NOT_REJECTED');
SELECT t.error('request: nor a blocked one',format('SELECT public.fiscal_request_correction(%L)',t.fid('r_nc')),'NOT_REJECTED');
SELECT t.expect('request: a rejected receipt queues one eta.correct job and says so',
  (SELECT j->>'queued'='true' AND j->>'status'='rejected' FROM (SELECT public.fiscal_request_correction(t.fid('rjold')) j) x));
SELECT t.error('request: again -> CORRECTION_QUEUED',format('SELECT public.fiscal_request_correction(%L)',t.fid('rjold')),'CORRECTION_QUEUED');
RESET ROLE;
SELECT t.expect('request: exactly one job, keyed by the row, carrying the UUID the request saw; one audit row',
  (SELECT count(*)=1 AND bool_and(j.dedupe_key='eta.correct:'||t.fid('rjold')::text AND j.payload->>'fiscal_id'=t.fid('rjold')::text
     AND j.payload->>'expected_old_uuid'=t.u('6') AND j.status='queued') FROM public.jobs j WHERE j.job_type='eta.correct' AND j.organization_id=t.org('a'))
  AND t.audits('a','fiscal.correction_requested')=1);
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.error('request: without fiscal.retry -> PERMISSION_DENIED',format('SELECT public.fiscal_request_correction(%L)',t.fid('r_rej')),'PERMISSION_DENIED');
SELECT t.error('request: nor can that user assign a device',format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('r_nc'),t.id('pos1')),'PERMISSION_DENIED');
SELECT t.error('request: nor retry many, nor check now',format('SELECT public.fiscal_retry_many(ARRAY[%L]::uuid[])',t.fid('r_nc')),'PERMISSION_DENIED');
SELECT t.error('request: nor read the list, the details, the diagnosis or the summaries',
  'SELECT public.fiscal_list()','PERMISSION_DENIED');
SELECT t.error('request: ... details',format('SELECT public.fiscal_details(%L)',t.fid('r_rej')),'PERMISSION_DENIED');
SELECT t.error('request: ... diagnose',format('SELECT public.fiscal_diagnose(%L)',t.fid('r_rej')),'PERMISSION_DENIED');
SELECT t.error('request: ... alert summary','SELECT public.fiscal_alert_summary()','PERMISSION_DENIED');
SELECT t.error('request: ... day summary',format('SELECT public.fiscal_day_summary(%L,current_date)',t.id('main')),'PERMISSION_DENIED');
SELECT t.error('request: nor check now',format('SELECT public.fiscal_check_now(%L)',t.fid('sub')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.owner_b();
SET ROLE authenticated;
SELECT t.error('request: another shop''s row -> FISCAL_NOT_FOUND',format('SELECT public.fiscal_request_correction(%L)',t.fid('r_rej')),'FISCAL_NOT_FOUND');
SELECT t.error('request: ... details',format('SELECT public.fiscal_details(%L)',t.fid('r_rej')),'FISCAL_NOT_FOUND');
SELECT t.error('request: ... diagnose',format('SELECT public.fiscal_diagnose(%L)',t.fid('r_rej')),'FISCAL_NOT_FOUND');
SELECT t.error('request: ... assign a device',format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('r_nc'),t.id('bpos')),'FISCAL_NOT_FOUND');
SELECT t.error('request: ... check now',format('SELECT public.fiscal_check_now(%L)',t.fid('sub')),'FISCAL_NOT_FOUND');
SELECT t.error('request: ... retry',format('SELECT public.retry_fiscal_submission(%L)',t.fid('r_nc')),'FISCAL_NOT_FOUND');
SELECT t.expect('request: another shop sees none of shop a''s receipts in its list',
  jsonb_array_length(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100))=0 AND (public.fiscal_alert_summary()->>'blocked')::int=0);
RESET ROLE;
SELECT t.expect('request: nothing of shop a changed',
  (SELECT f.status='rejected' FROM t.fiscal('r_rej') f) AND (SELECT f.status='failed' FROM t.fiscal('r_nc') f)
  AND t.jobs('a','eta.correct')=1);

-- ---------------------------------------------------------------- 5. eta_store_correction
-- r_head: the newest receipt of POS 2 (alone on it); r_old: rejected with a later receipt after it on POS 3.
SELECT t.mksale('a','h1','main','pos2',1140);
SELECT t.mksale('a','o1','main','pos3',1140);
SELECT t.mksale('a','o2','main','pos3',1140);
SELECT t.prep('h1','a');
SELECT t.reject('h1','ETA_INVALID: CV307 bad item');
SELECT t.prep('o1','b');
SELECT t.reject('o1','ETA_INVALID: CV307 bad item');
SELECT t.prep('o2','c','b');
SELECT t.expect('store: the setup chains are as expected',t.tail('pos2')=t.u('a') AND t.tail('pos3')=t.u('c'));
SELECT t.error('store: the wrong expected UUID -> CORRECTION_CONFLICT',
  format('SELECT public.eta_store_correction(%L,%L,%L,''{"receipt_json":"x"}'',''qr'')',t.fid('h1'),t.u('9'),t.u('d')),'CORRECTION_CONFLICT');
SELECT t.error('store: a row that is not rejected -> CORRECTION_CONFLICT',
  format('SELECT public.eta_store_correction(%L,%L,%L,''{"receipt_json":"x"}'',''qr'')',t.fid('o2'),t.u('c'),t.u('d')),'CORRECTION_CONFLICT');
SELECT t.error('store: a new UUID equal to the old one is refused',
  format('SELECT public.eta_store_correction(%L,%L,%L,''{"receipt_json":"x"}'',''qr'')',t.fid('h1'),t.u('a'),t.u('a')),'VALIDATION_FAILED');
SELECT t.expect('store: nothing changed after the refusals',
  (SELECT f.status='rejected' AND f.eta_uuid=t.u('a') AND f.reference_old_uuid IS NULL FROM t.fiscal('h1') f) AND t.tail('pos2')=t.u('a'));
-- The rejected receipt is the head of its POS.
UPDATE public.fiscal_submissions SET payload=payload||'{"sent":true}' WHERE id=t.fid('h1');
SELECT public.eta_store_correction(t.fid('h1'),t.u('a'),t.u('d'),'{"receipt_json":"{\"n\":\"d\"}"}','qr-d');
SELECT t.expect('store: the rejected receipt was the head -> the head is the new UUID, the old one is kept, previousUUID unchanged, pending',
  (SELECT f.status='pending' AND f.eta_uuid=t.u('d') AND f.reference_old_uuid=t.u('a') AND f.previous_uuid=''
     AND f.attempts=0 AND f.last_error IS NULL AND f.next_retry_at<=now() AND f.qr_payload='qr-d'
     AND f.payload->>'receipt_json'='{"n":"d"}' AND NOT (f.payload ? 'sent') FROM t.fiscal('h1') f)
  AND t.tail('pos2')=t.u('d'));
SELECT t.expect('store: and an eta.submit job is queued for its POS',
  EXISTS(SELECT 1 FROM public.jobs j WHERE j.job_type='eta.submit' AND j.dedupe_key='eta.submit:'||t.id('pos2')::text AND j.status='queued'));
SELECT t.expect('store: the next sale of POS 2 would chain to the correction (the stored head)',t.tail('pos2')=t.u('d'));
-- A later receipt exists on POS 3: its head does not move.
SELECT public.eta_store_correction(t.fid('o1'),t.u('b'),t.u('e'),'{"receipt_json":"{\"n\":\"e\"}"}','qr-e');
SELECT t.expect('store: a later receipt exists -> the head is unchanged, the correction keeps its place in the chain',
  t.tail('pos3')=t.u('c')
  AND (SELECT f.status='pending' AND f.eta_uuid=t.u('e') AND f.reference_old_uuid=t.u('b') AND f.previous_uuid='' FROM t.fiscal('o1') f)
  AND (SELECT f.previous_uuid=t.u('b') AND f.eta_uuid=t.u('c') FROM t.fiscal('o2') f));
SELECT public.eta_mark(t.fid('o1'),'rejected','{"last_error":"ETA_INVALID: again"}');
SELECT public.eta_store_correction(t.fid('o1'),t.u('e'),t.u('f'),'{"receipt_json":"{\"n\":\"f\"}"}','qr-f');
SELECT t.expect('store: a second correction takes the latest rejected UUID and keeps the original previousUUID',
  (SELECT f.reference_old_uuid=t.u('e') AND f.eta_uuid=t.u('f') AND f.previous_uuid='' AND f.status='pending' FROM t.fiscal('o1') f) AND t.tail('pos3')=t.u('c'));
SELECT t.error('store: the same request again (the row is pending now) -> CORRECTION_CONFLICT',
  format('SELECT public.eta_store_correction(%L,%L,%L,''{"receipt_json":"x"}'',''qr'')',t.fid('o1'),t.u('e'),t.u('0')),'CORRECTION_CONFLICT');
SET ROLE authenticated;
SELECT t.state('store: authenticated can''t execute eta_store_correction',
  format('SELECT public.eta_store_correction(%L,%L,%L,''{"receipt_json":"x"}'',''qr'')',t.fid('h1'),t.u('d'),t.u('0')),'42501');
SELECT t.state('store: nor eta_load_for_correction',format('SELECT public.eta_load_for_correction(%L)',t.fid('h1')),'42501');
SELECT t.state('store: nor eta_note_correction',format('SELECT public.eta_note_correction(%L,%L,''x'')',t.fid('h1'),t.u('d')),'42501');
RESET ROLE;
SELECT t.expect('store: only the service role may execute the three worker functions (not authenticated, not anon)',
  (SELECT bool_and(has_function_privilege('service_role',p.oid,'EXECUTE') AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
                   AND NOT has_function_privilege('anon',p.oid,'EXECUTE')) AND count(*)=3
   FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('eta_load_for_correction','eta_store_correction','eta_note_correction')));
SELECT t.expect('store: the worker loads a rejected receipt with its stored text, its previous UUID and the sale as it is now',
  (SELECT j->>'status'='pending' AND j->>'eta_uuid'=t.u('d') AND j->'row'->'sale'->>'number'='T03-h1'
     AND j->>'stored_receipt_json'='{"n":"d"}' AND j->>'previous_uuid'=''
   FROM (SELECT public.eta_load_for_correction(t.fid('h1')) j) x));
SELECT t.expect('store: the worker can note why a correction was not stored (only while it is still the rejected receipt)',
  public.eta_note_correction(t.fid('r_rej'),t.u('2'),'CORRECTION_NOTHING_CHANGED: ETA_INVALID: x')
  AND (SELECT f.status='rejected' AND f.last_error='CORRECTION_NOTHING_CHANGED: ETA_INVALID: x' FROM t.fiscal('r_rej') f)
  AND NOT public.eta_note_correction(t.fid('r_rej'),t.u('9'),'nope'));
UPDATE public.fiscal_submissions SET last_error='ETA_INVALID: CV307 itemData[0].itemCode: the item code is not registered; details: x' WHERE id=t.fid('r_rej');

-- ---------------------------------------------------------------- 6. events
SELECT t.expect('events: a fiscal row starts with one event; each status or UUID change adds one',
  t.events('w')=1 AND t.events('r_ok')=4,
  concat_ws(',',t.events('w'),t.events('r_ok')));
SELECT t.expect('events: the accepted receipt has its changes in order, ending submitted -> accepted',
  (SELECT string_agg(coalesce(e.old_status::text,'-')||'>'||e.new_status::text,' ' ORDER BY e.id) FROM public.fiscal_events e WHERE e.fiscal_id=t.fid('r_ok'))
  LIKE '->pending%submitted>accepted',
  (SELECT string_agg(coalesce(e.old_status::text,'-')||'>'||e.new_status::text,' ' ORDER BY e.id) FROM public.fiscal_events e WHERE e.fiscal_id=t.fid('r_ok')));
SELECT t.expect('events: the event carries the UUID and the error at that moment (cut to 500 characters)',
  EXISTS(SELECT 1 FROM public.fiscal_events e WHERE e.fiscal_id=t.fid('h1') AND e.new_status='rejected' AND e.eta_uuid=t.u('a') AND e.message LIKE 'ETA_INVALID%')
  AND EXISTS(SELECT 1 FROM public.fiscal_events e WHERE e.fiscal_id=t.fid('h1') AND e.new_status='pending' AND e.eta_uuid=t.u('d') AND e.old_status='rejected' AND e.message IS NULL));
-- A payload-only change writes none.
SELECT count(*) AS n INTO TEMP ev_before FROM public.fiscal_events WHERE fiscal_id=t.fid('w');
UPDATE public.fiscal_submissions SET payload='{"x":1}'::jsonb,next_retry_at=now(),attempts=attempts WHERE id=t.fid('w');
SELECT t.expect('events: a payload-only change writes no event',(SELECT n FROM ev_before)=(SELECT count(*) FROM public.fiscal_events WHERE fiscal_id=t.fid('w')));
UPDATE public.fiscal_submissions SET payload=NULL WHERE id=t.fid('w');
SELECT t.state('events: UPDATE is refused (APPEND_ONLY)','UPDATE public.fiscal_events SET message=''x''','P0001');
SELECT t.error('events: UPDATE says APPEND_ONLY','UPDATE public.fiscal_events SET message=''x''','APPEND_ONLY');
SELECT t.error('events: DELETE says APPEND_ONLY','DELETE FROM public.fiscal_events','APPEND_ONLY');
SELECT t.expect('events: nothing in the log is a payload (no column of that name, no receipt text)',
  NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fiscal_events' AND column_name='payload')
  AND NOT EXISTS(SELECT 1 FROM public.fiscal_events e WHERE row_to_json(e)::text LIKE '%receipt_json%'));
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.expect('events: a user without fiscal.view sees no events',(SELECT count(*) FROM public.fiscal_events)=0);
SELECT t.state('events: and can''t write one','INSERT INTO public.fiscal_events(organization_id,fiscal_id,new_status) SELECT organization_id,id,status FROM public.fiscal_submissions LIMIT 1','42501');
RESET ROLE;
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('events: a user with fiscal.view reads their own shop''s events, in the details oldest first',
  (SELECT count(*)>0 FROM public.fiscal_events)
  AND (SELECT jsonb_array_length(public.fiscal_details(t.fid('r_ok'))->'events')>=4)
  AND (SELECT bool_and((e->>'id')::bigint > coalesce(prev,0)) FROM (SELECT e, lag((e->>'id')::bigint) OVER (ORDER BY ord) prev
       FROM jsonb_array_elements(public.fiscal_details(t.fid('r_ok'))->'events') WITH ORDINALITY x(e,ord)) y));
SELECT t.expect('events: the details show every UUID the corrected receipt ever had, and its reference to the old one',
  (SELECT array_agg(e->>'eta_uuid' ORDER BY ord) FILTER (WHERE e->>'eta_uuid' IS NOT NULL)
   FROM jsonb_array_elements(public.fiscal_details(t.fid('o1'))->'events') WITH ORDINALITY x(e,ord)) @> ARRAY[t.u('b'),t.u('e'),t.u('f')]
  AND public.fiscal_details(t.fid('o1'))->'row'->>'reference_old_uuid'=t.u('e')
  AND public.fiscal_details(t.fid('o1'))::text NOT LIKE '%receipt_json%');
RESET ROLE;
SELECT t.owner_b();
SET ROLE authenticated;
SELECT t.expect('events: another shop sees none of them',(SELECT count(*) FROM public.fiscal_events)=0);
RESET ROLE;

-- ---------------------------------------------------------------- 7. assign a device (a sale made before POS devices)
SELECT t.mksale('a','nodev','second',NULL,1140);
SELECT t.block('nodev','BLOCKED:NO_DEVICE');
SELECT t.mksale('a','nodev2','second',NULL,1140);
SELECT t.block('nodev2','BLOCKED:NO_DEVICE');
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('assign: a blocked NO_DEVICE row is diagnosed as NO_DEVICE with the assign-device action, ready',
  t.has(t.dg('nodev'),'NO_DEVICE') AND t.dg('nodev')->>'action'='assign_device' AND (t.dg('nodev')->>'ready')::boolean);
SELECT t.error('assign: a device of another branch -> DEVICE_INVALID_FOR_RECEIPT',
  format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('nodev'),t.id('pos1')),'DEVICE_INVALID_FOR_RECEIPT');
SELECT t.error('assign: an inactive device -> DEVICE_INVALID_FOR_RECEIPT',
  format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('nodev'),t.id('possoff')),'DEVICE_INVALID_FOR_RECEIPT');
SELECT t.error('assign: another shop''s device -> DEVICE_INVALID_FOR_RECEIPT',
  format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('nodev'),t.id('bpos')),'DEVICE_INVALID_FOR_RECEIPT');
SELECT t.error('assign: an unknown device -> DEVICE_INVALID_FOR_RECEIPT',
  format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('nodev'),'00000000-0000-4000-8000-000000000000'),'DEVICE_INVALID_FOR_RECEIPT');
SELECT t.error('assign: a row that is not NO_DEVICE (blocked on an item code) -> NOT_BLOCKED_NO_DEVICE',
  format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('r_nc'),t.id('pos1')),'NOT_BLOCKED_NO_DEVICE');
SELECT t.error('assign: nor a rejected one',
  format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('r_rej'),t.id('pos1')),'NOT_BLOCKED_NO_DEVICE');
SELECT t.expect('assign: the same-branch active device is set and the row goes back to pending',
  public.fiscal_assign_device(t.fid('nodev'),t.id('poss'))->>'status'='pending');
RESET ROLE;
SELECT t.expect('assign: the fiscal row has the device, an eta.prepare job is queued for it, the sale is unchanged, one audit row',
  (SELECT f.device_id=t.id('poss') AND f.status='pending' AND f.eta_uuid IS NULL FROM t.fiscal('nodev') f)
  AND EXISTS(SELECT 1 FROM public.jobs j WHERE j.job_type='eta.prepare' AND j.dedupe_key='eta.prepare:'||t.id('poss')::text AND j.status='queued')
  AND (SELECT s.device_id IS NULL FROM public.sales s WHERE s.id=t.id('nodev'))
  AND t.audits('a','fiscal.device_assigned')=1);
SELECT t.expect('assign: T02''s prepare loader takes the device from the fiscal row (the sale has none)',
  (SELECT jsonb_array_length(j->'rows')=1 AND j->'rows'->0->'device'->>'id'=t.id('poss')::text AND j->'rows'->0->'sale'->>'number'='T03-nodev'
   FROM (SELECT public.eta_load_pending_for_device(t.id('poss'),NULL,50) j) x));

-- ---------------------------------------------------------------- 8. diagnosis
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: ITEM_CODE lists the product without a code, with its id and name, and the product page as the fix; not ready',
  (SELECT p->>'fix'='product' AND p->'products'->0->>'product_id'=t.id('nocode')::text AND p->'products'->0->>'name'='مروحة'
     AND NOT (t.dg('r_nc')->>'ready')::boolean AND t.dg('r_nc')->>'action'='retry'
   FROM jsonb_array_elements(t.dg('r_nc')->'problems') p WHERE p->>'code'='ITEM_CODE'));
RESET ROLE;
UPDATE public.products SET eta_item_code='EG-674859545-FAN',eta_item_type='EGS' WHERE id=t.id('nocode');
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: after the product is fixed ITEM_CODE is gone and the receipt is ready to retry',
  NOT t.has(t.dg('r_nc'),'ITEM_CODE') AND (t.dg('r_nc')->>'ready')::boolean);
RESET ROLE;
UPDATE public.products SET eta_item_code=NULL WHERE id=t.id('nocode');
SELECT t.expect('diagnosis: ... and back when the code is removed again (computed live)',t.has(t.dg('r_nc'),'ITEM_CODE'));
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: ETA_REJECTED carries the ETA''s error text for a rejected receipt; nothing else is wrong with it',
  (SELECT p->>'last_error' LIKE 'ETA_INVALID: CV307 itemData[0].itemCode%' FROM jsonb_array_elements(t.dg('r_rej')->'problems') p WHERE p->>'code'='ETA_REJECTED')
  AND t.dg('r_rej')->>'action'='correct' AND (t.dg('r_rej')->>'ready')::boolean);
RESET ROLE;
-- SELLER_DATA: a receipt of the second branch, which has no ETA code, governorate, city, address or building number yet.
SELECT t.mksale('a','sel','second','poss',1140);
SELECT t.block('sel','BLOCKED:SELLER_DATA');
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: SELLER_DATA names the missing fields and the page that fixes them (the branch)',
  (SELECT p->>'fix'='branch' AND p->>'branch_id'=t.id('second')::text
     AND (SELECT array_agg(f->>'field' ORDER BY f->>'field') FROM jsonb_array_elements(p->'fields') f)
       = ARRAY['branch_code','building_number','city','governorate','street']
   FROM jsonb_array_elements(t.dg('sel')->'problems') p WHERE p->>'code'='SELLER_DATA')
  AND NOT (t.dg('sel')->>'ready')::boolean);
SELECT public.update_branch(t.id('second'),'Second','5 Side St','Alexandria','Alexandria',NULL,'1',
  (SELECT default_cash_account_id FROM public.branches WHERE id=t.id('second')),'9');
SELECT t.expect('diagnosis: after the branch is fixed SELLER_DATA is gone and the receipt is ready',
  NOT t.has(t.dg('sel'),'SELLER_DATA') AND (t.dg('sel')->>'ready')::boolean);
RESET ROLE;
UPDATE public.eta_settings SET activity_code=NULL WHERE organization_id=t.org('a');
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: a missing activity code points at the ETA settings',
  (SELECT p->>'fix'='eta_settings' AND p->'fields'->0->>'field'='activity_code' FROM jsonb_array_elements(t.dg('sel')->'problems') p WHERE p->>'code'='SELLER_DATA'));
RESET ROLE;
UPDATE public.eta_settings SET activity_code='4753' WHERE organization_id=t.org('a');
-- BUYER_ID and BUYER_MISSING: a sale of 150,000 EGP and over.
INSERT INTO public.customers(id,organization_id,full_name) VALUES('a9031000-0000-0000-8000-0000000000c1',t.org('a'),'Mona Ali');
SELECT t.mksale('a','big','main','pos1',150000,interval '0','a9031000-0000-0000-8000-0000000000c1');
SELECT t.mksale('a','big2','main','pos1',150000);
SELECT t.mksale('a','small','main','pos1',149999.99);
SELECT t.block('big','BLOCKED:BUYER_ID');
SELECT t.block('big2','BLOCKED:BUYER_ID');
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: BUYER_ID: 150,000 and a customer without a national ID -> the customer page, with customer_id; not ready',
  (SELECT p->>'fix'='customer' AND p->>'customer_id'='a9031000-0000-0000-8000-0000000000c1' FROM jsonb_array_elements(t.dg('big')->'problems') p WHERE p->>'code'='BUYER_ID')
  AND NOT (t.dg('big')->>'ready')::boolean);
SELECT t.expect('diagnosis: BUYER_MISSING: no customer at 150,000 is not fixable here and never ready',
  (SELECT (p->>'fixable')::boolean=false FROM jsonb_array_elements(t.dg('big2')->'problems') p WHERE p->>'code'='BUYER_MISSING')
  AND NOT t.has(t.dg('big2'),'BUYER_ID') AND NOT (t.dg('big2')->>'ready')::boolean);
RESET ROLE;
UPDATE public.customers SET national_id='29001010100015' WHERE id='a9031000-0000-0000-8000-0000000000c1';
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: after the national ID is set BUYER_ID is gone and the receipt is ready',
  NOT t.has(t.dg('big'),'BUYER_ID') AND (t.dg('big')->>'ready')::boolean);
SELECT t.expect('diagnosis: no national ID in any answer (diagnosis, details, list)',
  t.dg('big')::text NOT LIKE '%29001010100015%' AND public.fiscal_details(t.fid('big'))::text NOT LIKE '%29001010100015%'
  AND public.fiscal_list(NULL,NULL,NULL,NULL,'T03-big',100)::text NOT LIKE '%29001010100015%');
RESET ROLE;
UPDATE public.customers SET national_id=NULL,is_business=true,tax_registration_no='674859545' WHERE id='a9031000-0000-0000-8000-0000000000c1';
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: a business buyer with the shop''s own tax number is BUYER_ID too',t.has(t.dg('big'),'BUYER_ID'));
RESET ROLE;
UPDATE public.customers SET national_id='29001010100015',is_business=false,tax_registration_no=NULL WHERE id='a9031000-0000-0000-8000-0000000000c1';
SELECT t.expect('diagnosis: under 150,000 a missing buyer is no problem (the row is simply not blocked)',t.sit('small')='waiting');
-- NO_DEVICE with a device that is off.
SELECT t.mksale('a','offdev','main','posoff',1140);
SELECT t.block('offdev','BLOCKED:NO_DEVICE');
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.expect('diagnosis: a POS that is not active with the ETA is NO_DEVICE too (fix: the device), not ready',
  (SELECT p->>'fix'='device' AND p->>'reason'='not_active' FROM jsonb_array_elements(t.dg('offdev')->'problems') p WHERE p->>'code'='NO_DEVICE')
  AND NOT (t.dg('offdev')->>'ready')::boolean);
SELECT t.expect('diagnosis: a waiting receipt has no problems and no action; a submitted one can be checked now',
  jsonb_array_length(t.dg('w')->'problems')=0 AND t.dg('w')->>'action' IS NULL AND NOT (t.dg('w')->>'ready')::boolean
  AND t.dg('sub')->>'action'='check_now' AND (t.dg('sub')->>'ready')::boolean);
SELECT t.expect('diagnosis: a send_failed receipt retries now; an accepted one has nothing',
  t.dg('snd')->>'action'='retry_now' AND (t.dg('snd')->>'ready')::boolean AND t.dg('r_ok')->>'action' IS NULL);
-- check now
SELECT t.expect('check now: a submitted receipt queues its poll at once and says so',
  public.fiscal_check_now(t.fid('sub'))->>'queued'='true');
SELECT t.error('check now: a receipt that is not submitted -> NOT_SUBMITTED',format('SELECT public.fiscal_check_now(%L)',t.fid('w')),'NOT_SUBMITTED');
SELECT t.error('check now: nor an accepted one',format('SELECT public.fiscal_check_now(%L)',t.fid('r_ok')),'NOT_SUBMITTED');
RESET ROLE;
SELECT t.expect('check now: one eta.poll job keyed by the submission, run now',
  (SELECT count(*)=1 AND bool_and(j.run_at<=now() AND j.payload->>'submission_uuid'='SUB2') FROM public.jobs j
   WHERE j.job_type='eta.poll' AND j.dedupe_key='eta.poll:SUB2:0' AND j.status='queued'));

-- ---------------------------------------------------------------- 9. retry many
SELECT t.mksale('b','bone','bmain','bpos',1140);
SELECT t.owner_a();
SET ROLE authenticated;
-- r_nc: fix the product first.
RESET ROLE;
UPDATE public.products SET eta_item_code='EG-674859545-FAN',eta_item_type='EGS' WHERE id=t.id('nocode');
SELECT t.owner_a();
SET ROLE authenticated;
CREATE TEMP TABLE rm AS SELECT public.fiscal_retry_many(ARRAY[t.fid('r_nc'),t.fid('snd'),t.fid('r_rej'),t.fid('big2'),t.fid('r_ok'),t.fid('rjold'),
        t.fid('bone'),t.fid('r_nc')]) j;
GRANT SELECT ON rm TO authenticated;
SELECT t.expect('retry many: a mixed list -> the eligible ones done, the rest skipped with the right reason',
  (SELECT (j->>'done')::int=3 AND jsonb_array_length(j->'skipped')=4
     AND (SELECT count(*) FROM jsonb_array_elements(j->'skipped') s WHERE s->>'id'=t.fid('big2')::text AND s->>'reason'='NOT_READY')=1
     AND (SELECT count(*) FROM jsonb_array_elements(j->'skipped') s WHERE s->>'id'=t.fid('r_ok')::text AND s->>'reason'='NOT_ELIGIBLE')=1
     AND (SELECT count(*) FROM jsonb_array_elements(j->'skipped') s WHERE s->>'id'=t.fid('rjold')::text AND s->>'reason'='NOT_READY')=1
     AND (SELECT count(*) FROM jsonb_array_elements(j->'skipped') s WHERE s->>'id'=t.fid('bone')::text AND s->>'reason'='FISCAL_NOT_FOUND')=1
   FROM rm), (SELECT j::text FROM rm));
RESET ROLE;
SELECT t.expect('retry many: blocked -> pending (prepare), send_failed -> pending (submit), rejected -> a correction is queued',
  (SELECT f.status='pending' AND f.eta_uuid IS NULL FROM t.fiscal('r_nc') f)
  AND (SELECT f.status='pending' AND f.eta_uuid=t.u('4') FROM t.fiscal('snd') f)
  AND (SELECT f.status='rejected' FROM t.fiscal('r_rej') f)
  AND EXISTS(SELECT 1 FROM public.jobs j WHERE j.job_type='eta.correct' AND j.dedupe_key='eta.correct:'||t.fid('r_rej')::text AND j.status='queued')
  AND t.audits('a','fiscal.retry_many')=1);
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.error('retry many: 201 ids are refused',
  format('SELECT public.fiscal_retry_many((SELECT array_agg(%L::uuid) FROM generate_series(1,201)))',t.fid('r_ok')),'VALIDATION_FAILED');
SELECT t.error('retry many: no ids are refused','SELECT public.fiscal_retry_many(ARRAY[]::uuid[])','VALIDATION_FAILED');
SELECT t.expect('retry many: exactly 200 ids are accepted (the same accepted receipt, counted once, skipped)',
  (SELECT (j->>'done')::int=0 AND jsonb_array_length(j->'skipped')=1
   FROM (SELECT public.fiscal_retry_many((SELECT array_agg(f.id) FROM public.fiscal_submissions f, generate_series(1,200) g WHERE f.id=t.fid('r_ok')))) x(j)));
RESET ROLE;

-- ---------------------------------------------------------------- 10. summaries (shop c)
SELECT t.mksale('c','c_ov','cmain','cpos',1140,interval '25 hours');
SELECT t.mksale('c','c_soon','cmain','cpos',1140,interval '22 hours');
SELECT t.mksale('c','c_blk','cmain','cpos',1140,interval '5 minutes');
SELECT t.mksale('c','c_rej','cmain','cpos',1140,interval '10 minutes');
SELECT t.mksale('c','c_snd','cmain','cpos',1140,interval '1 hour');
SELECT t.mksale('c','c_blk2','csecond',NULL,1140,interval '2 hours');
SELECT t.mksale('c','c_acc','cmain','cpos',1140,interval '3 hours');
SELECT t.mksale('c','c_can','cmain','cpos',1140,interval '4 hours');
SELECT t.block('c_blk','BLOCKED:ITEM_CODE');
SELECT t.block('c_blk2','BLOCKED:NO_DEVICE');
SELECT t.prep('c_rej','01');
SELECT t.reject('c_rej','ETA_INVALID: bad');
SELECT t.prep('c_snd','02','01');
UPDATE public.fiscal_submissions SET status='failed',last_error='ETA_UNREACHABLE: down' WHERE id=t.fid('c_snd');
SELECT t.prep('c_acc','03','02');
SELECT public.eta_mark(t.fid('c_acc'),'submitted','{"eta_submission_uuid":"SUBC"}');
SELECT public.eta_mark(t.fid('c_acc'),'accepted');
UPDATE public.fiscal_submissions SET status='cancelled' WHERE id=t.fid('c_can');
SELECT t.owner_c();
SET ROLE authenticated;
SELECT t.expect('list: the order is overdue, due soon, problems newest first, then the rest',
  (SELECT string_agg(i->>'sale_number',',' ORDER BY ord) FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) WITH ORDINALITY x(i,ord))
  ='T03-c_ov,T03-c_soon,T03-c_blk,T03-c_rej,T03-c_snd,T03-c_blk2,T03-c_acc,T03-c_can',
  (SELECT string_agg(i->>'sale_number',',' ORDER BY ord) FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) WITH ORDINALITY x(i,ord)));
SELECT t.expect('list: by branch',(SELECT count(*)=1 FROM jsonb_array_elements(public.fiscal_list(t.id('csecond'))) i));
SELECT t.expect('list: by situation',(SELECT count(*)=2 FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,'blocked')) i)
  AND (SELECT count(*)=4 FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,'problem')) i));
SELECT t.expect('list: by sale number prefix and by UUID prefix',
  (SELECT count(*)=2 FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,'T03-c_s')) i)
  AND (SELECT count(*)=1 FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,left(t.u('02'),12))) i)
  AND (SELECT count(*)=0 FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,'%')) i));
SELECT t.expect('list: by date',(SELECT count(*)=0 FROM jsonb_array_elements(public.fiscal_list(NULL,current_date+3,NULL)) i)
  AND (SELECT count(*)=8 FROM jsonb_array_elements(public.fiscal_list(NULL,current_date-3,current_date+3)) i));
SELECT t.expect('list: pages with total_count, the limit capped at 100',
  (SELECT count(*)=3 AND bool_and((i->>'total_count')::int=8) FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,3,0)) i)
  AND (SELECT count(*)=2 FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,3,6)) i)
  AND (SELECT count(*)=8 FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,1000)) i));
SELECT t.expect('summary: the alert counts of the whole shop',
  public.fiscal_alert_summary()=jsonb_build_object('blocked',2,'send_failed',1,'rejected',1,'due_soon',1,'overdue',1,'accepted_today',1),
  public.fiscal_alert_summary()::text);
RESET ROLE;
SELECT t.acct_c();
SET ROLE authenticated;
SELECT t.expect('summary: a user of the main branch only counts what they can see (the blocked row of the second branch is not theirs)',
  public.fiscal_alert_summary()=jsonb_build_object('blocked',1,'send_failed',1,'rejected',1,'due_soon',1,'overdue',1,'accepted_today',1),
  public.fiscal_alert_summary()::text);
SELECT t.expect('list: and their list has seven rows, none of the second branch',
  (SELECT count(*)=7 AND bool_and(i->>'branch_id'=t.id('cmain')::text) FROM jsonb_array_elements(public.fiscal_list(NULL,NULL,NULL,NULL,NULL,100)) i));
SELECT t.error('details: a receipt of a branch they can''t see -> FISCAL_NOT_FOUND',format('SELECT public.fiscal_details(%L)',t.fid('c_blk2')),'FISCAL_NOT_FOUND');
SELECT t.error('diagnose: ... and its diagnosis',format('SELECT public.fiscal_diagnose(%L)',t.fid('c_blk2')),'FISCAL_NOT_FOUND');
SELECT t.error('retry: ... and its retry',format('SELECT public.retry_fiscal_submission(%L)',t.fid('c_blk2')),'FISCAL_NOT_FOUND');
SELECT t.error('assign: ... and a device for it',format('SELECT public.fiscal_assign_device(%L,%L)',t.fid('c_blk2'),t.id('cpos')),'FISCAL_NOT_FOUND');
SELECT t.error('day summary: a branch they can''t access -> BRANCH_DENIED',format('SELECT public.fiscal_day_summary(%L,current_date)',t.id('csecond')),'BRANCH_DENIED');
RESET ROLE;
-- The day close hook: one branch, one business day.
SELECT t.mksale('c','y1','cmain','cpos',1140,interval '30 hours',NULL,current_date-1);
SELECT t.mksale('c','y2','cmain','cpos',1140,interval '30 hours',NULL,current_date-1);
SELECT t.mksale('c','y3','cmain','cpos',1140,interval '30 hours',NULL,current_date-1);
SELECT t.prep('y1','04','03');
SELECT t.prep('y2','05','04');
SELECT public.eta_mark(t.fid('y1'),'submitted','{"eta_submission_uuid":"SUBY"}');
SELECT public.eta_mark(t.fid('y1'),'accepted');
SELECT public.eta_mark(t.fid('y2'),'submitted','{"eta_submission_uuid":"SUBY"}');
SELECT public.eta_mark(t.fid('y2'),'accepted');
UPDATE public.fiscal_submissions SET status='cancelled' WHERE id=t.fid('y3');
SELECT t.owner_c();
SET ROLE authenticated;
SELECT t.expect('day summary: counts per situation for the branch and day; today is not all accepted',
  public.fiscal_day_summary(t.id('cmain'),current_date)->>'total'='7'
  AND (public.fiscal_day_summary(t.id('cmain'),current_date)->>'blocked')='1' AND (public.fiscal_day_summary(t.id('cmain'),current_date)->>'send_failed')='1'
  AND (public.fiscal_day_summary(t.id('cmain'),current_date)->>'rejected')='1' AND (public.fiscal_day_summary(t.id('cmain'),current_date)->>'waiting')='2'
  AND (public.fiscal_day_summary(t.id('cmain'),current_date)->>'accepted')='1' AND (public.fiscal_day_summary(t.id('cmain'),current_date)->>'cancelled')='1'
  AND (public.fiscal_day_summary(t.id('cmain'),current_date)->>'all_accepted')='false',
  public.fiscal_day_summary(t.id('cmain'),current_date)::text);
SELECT t.expect('day summary: yesterday is all accepted (a void''s cancelled receipt does not count against it)',
  (public.fiscal_day_summary(t.id('cmain'),current_date-1)->>'accepted')='2' AND (public.fiscal_day_summary(t.id('cmain'),current_date-1)->>'cancelled')='1'
  AND (public.fiscal_day_summary(t.id('cmain'),current_date-1)->>'all_accepted')='true');
SELECT t.expect('day summary: the other branch has its own count',
  (public.fiscal_day_summary(t.id('csecond'),current_date)->>'blocked')='1' AND (public.fiscal_day_summary(t.id('csecond'),current_date)->>'total')='1');
SELECT t.expect('day summary: a day with no receipts has none and nothing waits',
  (public.fiscal_day_summary(t.id('cmain'),current_date-5)->>'total')='0' AND (public.fiscal_day_summary(t.id('cmain'),current_date-5)->>'all_accepted')='true');
SELECT t.error('day summary: another shop''s branch is refused',format('SELECT public.fiscal_day_summary(%L,current_date)',t.id('bmain')),'BRANCH_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- 11. grants and catalog
SELECT t.expect('grants: the monitor functions are executable by authenticated and not by anon',
  (SELECT bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE')) AND count(*)=10
   FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('fiscal_list','fiscal_details','fiscal_diagnose','fiscal_alert_summary',
     'fiscal_day_summary','fiscal_request_correction','fiscal_assign_device','fiscal_check_now','fiscal_retry_many','retry_fiscal_submission')));
SELECT t.expect('grants: the app helpers are executable by neither',
  (SELECT bool_and(NOT has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE')) AND count(*)=8
   FROM pg_proc p WHERE p.pronamespace='app'::regnamespace AND p.proname IN ('fiscal_events_log','fiscal_situation','fiscal_deadline_at','fiscal_deadline_state',
     'eta_receipt_source','fiscal_diagnosis','fiscal_visible','require_fiscal_view')));
SELECT t.expect('grants: fiscal_events is read-only for authenticated and closed to anon; payload stays hidden',
  has_table_privilege('authenticated','public.fiscal_events','SELECT') AND NOT has_table_privilege('authenticated','public.fiscal_events','INSERT,UPDATE,DELETE')
  AND NOT has_any_column_privilege('anon','public.fiscal_events','SELECT')
  AND has_column_privilege('authenticated','public.fiscal_submissions','reference_old_uuid','SELECT')
  AND NOT has_column_privilege('authenticated','public.fiscal_submissions','payload','SELECT'));
SELECT t.expect('grants: every new definer function pins search_path',
  NOT EXISTS(SELECT 1 FROM pg_proc p WHERE p.pronamespace IN ('public'::regnamespace,'app'::regnamespace) AND p.prosecdef
     AND (p.proname LIKE 'fiscal\_%' OR p.proname IN ('eta_load_for_correction','eta_store_correction','eta_note_correction','eta_receipt_source','require_fiscal_view'))
     AND NOT coalesce(p.proconfig @> ARRAY['search_path=""'],false)));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
