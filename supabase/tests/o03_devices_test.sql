-- O03 POS devices (EC-146, D69).
-- Run by: node scripts/db-smoke.mjs supabase/tests/o03_devices_test.sql (inside BEGIN ... ROLLBACK).
-- A device is created inside the plan limit, paired with a one-time code whose hash is all the
-- database ever holds, and resolved from a token hash for its own shop only. A shift needs the
-- device of the request and keeps it; a sale takes its shift's device; a device with an open
-- shift can't be moved or turned off; no hash is readable, returned or audited.
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
-- The caller, the shop and (d) the two headers the API sets once it resolved a device token:
-- x-device-id and the hash of that token. h: 'stored' sends the hash the device holds now (a
-- request from its paired computer), NULL sends none (a hand-made x-device-id), anything else is
-- sent as it is.
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL,d text DEFAULT NULL,h text DEFAULT 'stored') RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),
         set_config('request.headers',(jsonb_strip_nulls(jsonb_build_object('x-org-id',o,'x-device-id',d,'x-device-token-hash',
           CASE WHEN h='stored' THEN (SELECT x.token_hash FROM public.devices x WHERE x.id::text=d) ELSE h END)))::text,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- A SHA-256 shaped hash made of one hex digit.
CREATE FUNCTION t.h(c text) RETURNS text LANGUAGE sql AS $$ SELECT repeat(c,64) $$;
-- A device row as the database owner sees it (the test acts as `authenticated` at times).
CREATE FUNCTION t.dev(tag text) RETURNS public.devices LANGUAGE sql SECURITY DEFINER AS $$ SELECT d FROM public.devices d WHERE d.id=t.id(tag) $$;
CREATE FUNCTION t.audits(shop text,act text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.audit_log a WHERE a.organization_id=t.org(shop) AND a.action=act $$;
-- A code for a device, made as the shop's owner would: only the hash arrives.
CREATE FUNCTION t.code(tag text,c text,mins integer DEFAULT 15) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.create_device_pairing_code(t.id(tag),t.h(c),now()+make_interval(mins=>mins)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop s (starter), shop r, shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('O03 '||s,'o03-'||s,p,'Owner',s||'o03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('s','starter',repeat('u',64)),('r','retail_pro',repeat('v',64)),('b','retail_pro',repeat('w',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a9030000-0000-0000-8000-000000000001','so03@example.com'),('a9030000-0000-0000-8000-000000000002','ro03@example.com'),
  ('a9030000-0000-0000-8000-000000000003','bo03@example.com'),('a9030000-0000-0000-8000-000000000004','o03cashier@example.com'),
  ('a9030000-0000-0000-8000-000000000005','o03accountant@example.com');
SELECT public.accept_invite(repeat('u',64),'a9030000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('v',64),'a9030000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('w',64),'a9030000-0000-0000-8000-000000000003');
INSERT INTO t.ids SELECT 'smain',id FROM public.branches WHERE organization_id=t.org('s') AND is_main;
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('r') AND is_main;
INSERT INTO t.ids SELECT 'bmain',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id=t.org('r');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES
  (t.org('r'),'a9030000-0000-0000-8000-000000000004','O03 Cashier','CASHIER',t.id('main')),
  (t.org('r'),'a9030000-0000-0000-8000-000000000005','O03 Accountant','ACCOUNTANT',t.id('main'));
INSERT INTO t.ids SELECT CASE e.role WHEN 'CASHIER' THEN 'cashier' ELSE 'accountant' END,e.id FROM public.employees e
  WHERE e.organization_id=t.org('r') AND e.role IN ('CASHIER','ACCOUNTANT');
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id)
  SELECT t.org('r'),e.id,t.id('main') FROM public.employees e WHERE e.organization_id=t.org('r') AND e.role IN ('CASHIER','ACCOUNTANT');
-- The callers. owner_*: no device; the cashier's requests name a device where a case says so.
CREATE FUNCTION t.owner_s() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9030000-0000-0000-8000-000000000001',t.org('s')) $$;
CREATE FUNCTION t.owner_r(d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9030000-0000-0000-8000-000000000002',t.org('r'),d) $$;
CREATE FUNCTION t.owner_b(d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9030000-0000-0000-8000-000000000003',t.org('b'),d) $$;
CREATE FUNCTION t.cashier(d text DEFAULT NULL,h text DEFAULT 'stored') RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9030000-0000-0000-8000-000000000004',t.org('r'),d,h) $$;
-- A pairing attempt that must fail: the answer is NULL (the API's PAIRING_CODE_INVALID), never an error.
CREATE FUNCTION t.refused(n text,code text,token text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  BEGIN v := public.pair_device(code,token); PERFORM t.expect(n,v IS NULL,v::text);
  EXCEPTION WHEN others THEN PERFORM t.expect(n,false,SQLERRM); END;
END $$;
-- The failed attempts counted so far are forgotten, so a case can make its own.
CREATE FUNCTION t.forget_attempts() RETURNS void LANGUAGE sql SECURITY DEFINER AS $$ DELETE FROM public.device_pairing_attempts WHERE true $$;
CREATE FUNCTION t.attempts(emp text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.device_pairing_attempts a WHERE a.employee_id=t.id(emp) $$;
CREATE FUNCTION t.accountant() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a9030000-0000-0000-8000-000000000005',t.org('r')) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- 1. the plan limit (starter: 2 devices)
SELECT t.owner_s();
SET ROLE authenticated;
INSERT INTO t.ids VALUES('s1',public.create_device(t.id('smain'),'POS-1'));
INSERT INTO t.ids VALUES('s2',public.create_device(t.id('smain'),'POS-2'));
SELECT t.error('limit: a third device on starter (2 devices)',format('SELECT public.create_device(%L,''POS-3'')',t.id('smain')),'PLAN_LIMIT_REACHED');
SELECT public.set_device_active(t.id('s2'),false,'Broken screen');
INSERT INTO t.ids VALUES('s3',public.create_device(t.id('smain'),'POS-3'));
SELECT t.error('limit: turning a device on again goes through the plan limit',format('SELECT public.set_device_active(%L,true)',t.id('s2')),'PLAN_LIMIT_REACHED');
RESET ROLE;
SELECT t.expect('limit: two devices were created, the third only after one was turned off',
  (SELECT count(*)=3 AND count(*) FILTER(WHERE is_active)=2 FROM public.devices WHERE organization_id=t.org('s'))
  AND (SELECT NOT d.is_active FROM t.dev('s2') d) AND t.audits('s','device.created')=3);

-- ---------------------------------------------------------------- 2. managing devices (shop r)
SELECT t.owner_r();
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('r1',public.create_device(t.id('main'),'  POS-1 '));
INSERT INTO t.ids VALUES('r2',public.create_device(t.id('main'),'POS-2'));
INSERT INTO t.ids VALUES('r3',public.create_device(t.id('second'),'pos-1'));
SELECT t.error('manage: a name another device of the branch has, in another case',format('SELECT public.create_device(%L,''pos-1'')',t.id('main')),'DEVICE_NAME_TAKEN');
SELECT t.error('manage: a blank name',format('SELECT public.create_device(%L,''   '')',t.id('main')),'VALIDATION_FAILED');
SELECT t.error('manage: a name over 50 characters',format('SELECT public.create_device(%L,%L)',t.id('main'),repeat('x',51)),'VALIDATION_FAILED');
SELECT t.error('manage: a branch of another shop',format('SELECT public.create_device(%L,''POS-9'')',t.id('bmain')),'BRANCH_NOT_FOUND');
SELECT t.error('manage: renaming to a taken name',format('SELECT public.update_device(%L,''POS-1'')',t.id('r2')),'DEVICE_NAME_TAKEN');
SELECT t.error('manage: moving to a branch where the name is taken',format('SELECT public.update_device(%L,NULL,%L)',t.id('r3'),t.id('main')),'DEVICE_NAME_TAKEN');
SELECT t.error('manage: moving to a branch of another shop',format('SELECT public.update_device(%L,NULL,%L)',t.id('r2'),t.id('bmain')),'BRANCH_NOT_FOUND');
SELECT t.error('manage: turning a device off without a reason',format('SELECT public.set_device_active(%L,false,''  '')',t.id('r2')),'REASON_REQUIRED');
SELECT t.expect('manage: a rename answers the device, with its branch and no hash',
  (SELECT j->>'name'='Till 2' AND j->>'branch_name'='Main' AND (j->>'paired')::boolean=false AND j->>'paired_at' IS NULL
     AND NOT (j ? 'token_hash') AND NOT (j ? 'pairing_code_hash')
   FROM (SELECT public.update_device(t.id('r2'),' Till 2 ') j) x));
SELECT public.update_device(t.id('r2'),'POS-2');
RESET ROLE;
SELECT t.expect('manage: names are trimmed; the same name is fine in another branch',
  (SELECT d.name='POS-1' AND d.branch_id=t.id('main') AND d.is_active AND d.token_hash IS NULL FROM t.dev('r1') d)
  AND (SELECT d.name='pos-1' AND d.branch_id=t.id('second') FROM t.dev('r3') d));
SELECT t.owner_b();
SET ROLE authenticated;
INSERT INTO t.ids VALUES('b1',public.create_device(t.id('bmain'),'POS-1'));
SELECT t.error('manage: another shop''s device can''t be renamed',format('SELECT public.update_device(%L,''Mine'')',t.id('r1')),'DEVICE_NOT_FOUND');
SELECT t.error('manage: another shop''s device can''t be turned off',format('SELECT public.set_device_active(%L,false,''x'')',t.id('r1')),'DEVICE_NOT_FOUND');
SELECT t.error('manage: another shop''s device gets no pairing code',format('SELECT t.code(''r1'',''1'')'),'DEVICE_NOT_FOUND');
SELECT t.error('manage: another shop''s device can''t be unpaired',format('SELECT public.unpair_device(%L)',t.id('r1')),'DEVICE_NOT_FOUND');
RESET ROLE;
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.error('manage: a cashier (no device.manage) can''t create a device',format('SELECT public.create_device(%L,''POS-7'')',t.id('main')),'PERMISSION_DENIED');
SELECT t.error('manage: a cashier can''t make a pairing code','SELECT t.code(''r1'',''1'')','PERMISSION_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- 3. pairing
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.error('pairing: a code hash of the wrong shape',format('SELECT public.create_device_pairing_code(%L,''ABCDEFGH'',now()+interval ''15 minutes'')',t.id('r1')),'VALIDATION_FAILED');
SELECT t.error('pairing: a code that would live longer than 15 minutes','SELECT t.code(''r1'',''1'',20)','VALIDATION_FAILED');
SELECT t.error('pairing: a code that has already expired','SELECT t.code(''r1'',''1'',-1)','VALIDATION_FAILED');
SELECT t.expect('pairing: making a code answers the expiry only, never the hash',
  (SELECT j ? 'expires_at' AND j::text NOT LIKE '%'||t.h('1')||'%' FROM (SELECT t.code('r1','1') j) x));
RESET ROLE;
SELECT t.expect('pairing: the device holds the hash of the code and its expiry, 15 minutes on',
  (SELECT d.pairing_code_hash=t.h('1') AND d.pairing_expires_at=now()+interval '15 minutes' AND d.token_hash IS NULL FROM t.dev('r1') d));
SELECT t.accountant();
SET ROLE authenticated;
SELECT t.error('pairing: an employee with neither shift.operate nor device.manage',format('SELECT public.pair_device(%L,%L)',t.h('1'),t.h('a')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.owner_b();
SET ROLE authenticated;
SELECT t.refused('pairing: the code of another shop''s device',t.h('1'),t.h('a'));
RESET ROLE;
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.refused('pairing: a wrong code',t.h('2'),t.h('a'));
SELECT t.refused('pairing: a code that is not a hash','ABCDEFGH',t.h('a'));
SELECT t.error('pairing: a token hash of the wrong shape',format('SELECT public.pair_device(%L,''token'')',t.h('1')),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('pairing: each failed attempt was counted for the employee who made it; a refused permission was not',
  t.attempts('cashier')=2 AND t.attempts('accountant')=0);
SELECT t.forget_attempts();
SELECT t.expect('pairing: none of the failed attempts used the code up or paired the device',
  (SELECT d.pairing_code_hash=t.h('1') AND d.token_hash IS NULL FROM t.dev('r1') d) AND t.audits('r','device.paired')=0);
SET ROLE authenticated;
SELECT t.expect('pairing: a cashier (shift.operate) pairs with the code and is told which device this is',
  (SELECT j->>'device_id'=t.id('r1')::text AND j->>'name'='POS-1' AND j->>'branch_id'=t.id('main')::text AND j->>'branch_name'='Main'
     AND j::text NOT LIKE '%'||t.h('a')||'%' AND j::text NOT LIKE '%'||t.h('1')||'%'
   FROM (SELECT public.pair_device(t.h('1'),t.h('a')) j) x));
SELECT t.refused('pairing: a used code',t.h('1'),t.h('b'));
RESET ROLE;
SELECT t.expect('pairing: the device holds the token hash, who paired it and when; the code is gone',
  (SELECT d.token_hash=t.h('a') AND d.paired_at=now() AND d.paired_by=t.id('cashier') AND d.pairing_code_hash IS NULL AND d.pairing_expires_at IS NULL FROM t.dev('r1') d));
SELECT t.forget_attempts();
-- An expired code: made a quarter of an hour ago.
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.code('r2','3');
RESET ROLE;
UPDATE public.devices SET pairing_expires_at=now()-interval '1 second' WHERE id=t.id('r2');
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.refused('pairing: an expired code',t.h('3'),t.h('b'));
RESET ROLE;
-- A new code replaces an older unused one.
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.code('r2','4');
SELECT t.code('r2','5');
RESET ROLE;
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.refused('pairing: an older code, once a new one was made',t.h('4'),t.h('b'));
SELECT public.pair_device(t.h('5'),t.h('b'));
RESET ROLE;
SELECT t.expect('pairing: the newer code paired the second device',(SELECT d.token_hash=t.h('b') FROM t.dev('r2') d));
SELECT t.forget_attempts();
-- A device in a branch the employee doesn't work in, and a device turned off after its code was made.
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.code('r3','6');
RESET ROLE;
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.refused('pairing: a device of a branch the employee does not work in',t.h('6'),t.h('c'));
RESET ROLE;
UPDATE public.devices SET is_active=false WHERE id=t.id('r3');
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.refused('pairing: a device that was turned off after its code was made',t.h('6'),t.h('c'));
SELECT t.error('pairing: no code for a device that is off','SELECT t.code(''r3'',''7'')','DEVICE_INVALID');
RESET ROLE;
UPDATE public.devices SET is_active=true WHERE id=t.id('r3');
SELECT t.owner_r();
SET ROLE authenticated;
SELECT public.pair_device(t.h('6'),t.h('c'));
-- Pairing again replaces the token.
SELECT t.code('r1','8');
SELECT public.pair_device(t.h('8'),t.h('d'));
RESET ROLE;
SELECT t.expect('pairing: the owner (device.manage) pairs too; pairing again replaces the token',
  (SELECT d.token_hash=t.h('c') FROM t.dev('r3') d) AND (SELECT d.token_hash=t.h('d') AND d.pairing_code_hash IS NULL FROM t.dev('r1') d));
SELECT t.expect('pairing: each pairing is audited; the one that replaced a pairing is a warning that says so',
  (SELECT count(*)=4 AND count(*) FILTER(WHERE a.severity='warning' AND (a."after"->>'replaced_pairing')::boolean)=1
     AND count(*) FILTER(WHERE a.severity='info' AND NOT (a."after"->>'replaced_pairing')::boolean)=3
   FROM public.audit_log a WHERE a.organization_id=t.org('r') AND a.action='device.paired'),
  (SELECT string_agg(a.severity||' '||a."after"::text,' | ') FROM public.audit_log a WHERE a.organization_id=t.org('r') AND a.action='device.paired'));

-- The limit: 5 failures in a minute, then nothing is looked at, not even the right code. It is
-- counted in the database, so it holds for a call that never went through the API.
SELECT t.forget_attempts();
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.code('r2','e');
RESET ROLE;
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.refused('limit: wrong code '||n,t.h('f'),t.h('b')) FROM generate_series(1,5) n;
SELECT t.refused('limit: the sixth attempt in a minute is refused even with the right code',t.h('e'),t.h('b'));
RESET ROLE;
SELECT t.expect('limit: five failures were counted, the refused sixth changed nothing',
  t.attempts('cashier')=5 AND (SELECT d.pairing_code_hash=t.h('e') AND d.token_hash=t.h('b') FROM t.dev('r2') d));
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.refused('limit: it is counted for each employee: the owner is not held back, and fails on their own',t.h('f'),t.h('b'));
RESET ROLE;
UPDATE public.device_pairing_attempts SET created_at=created_at-interval '61 seconds';
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.expect('limit: a minute later the right code pairs again',public.pair_device(t.h('e'),t.h('b'))->>'device_id'=t.id('r2')::text);
RESET ROLE;
SELECT t.forget_attempts();
SELECT t.expect('limit: the attempts table is the function''s own: no grant, RLS on, no policy',
  NOT has_table_privilege('authenticated','public.device_pairing_attempts','SELECT')
  AND NOT has_table_privilege('authenticated','public.device_pairing_attempts','INSERT')
  AND NOT has_table_privilege('anon','public.device_pairing_attempts','SELECT')
  AND (SELECT c.relrowsecurity FROM pg_class c WHERE c.oid='public.device_pairing_attempts'::regclass)
  AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname='public' AND p.tablename='device_pairing_attempts'));

-- ---------------------------------------------------------------- 4. resolve_device
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.expect('resolve: the token hash of a device of the shop answers the device and its branch, and no hash',
  (SELECT j->>'device_id'=t.id('r1')::text AND j->>'name'='POS-1' AND j->>'branch_id'=t.id('main')::text AND j->>'branch_name'='Main'
     AND j::text NOT LIKE '%'||t.h('d')||'%' FROM (SELECT public.resolve_device(t.h('d')) j) x));
SELECT t.expect('resolve: the replaced token, an unknown hash and a text that is no hash answer nothing',
  public.resolve_device(t.h('a')) IS NULL AND public.resolve_device(t.h('e')) IS NULL AND public.resolve_device('token') IS NULL
  AND public.resolve_device(NULL) IS NULL);
RESET ROLE;
SELECT t.owner_b();
SET ROLE authenticated;
SELECT t.expect('resolve: another shop''s token answers nothing',public.resolve_device(t.h('d')) IS NULL);
RESET ROLE;
SELECT t.as_user('a9030000-0000-0000-8000-000000000004');
SET ROLE authenticated;
SELECT t.expect('resolve: an employee of one shop needs no shop header',public.resolve_device(t.h('d'))->>'device_id'=t.id('r1')::text);
RESET ROLE;
SELECT t.as_user(NULL);
SET ROLE authenticated;
SELECT t.expect('resolve: without a session it answers nothing',public.resolve_device(t.h('d')) IS NULL);
RESET ROLE;
SELECT t.expect('resolve: the first request of a device sets last_seen_at',(SELECT d.last_seen_at=now() FROM t.dev('r1') d));
UPDATE public.devices SET last_seen_at=now()-interval '3 minutes' WHERE id=t.id('r1');
SELECT t.cashier();
SET ROLE authenticated;
SELECT public.resolve_device(t.h('d'));
RESET ROLE;
SELECT t.expect('resolve: last_seen_at is not written again inside 5 minutes',(SELECT d.last_seen_at=now()-interval '3 minutes' FROM t.dev('r1') d));
UPDATE public.devices SET last_seen_at=now()-interval '6 minutes' WHERE id=t.id('r1');
SET ROLE authenticated;
SELECT public.resolve_device(t.h('d'));
RESET ROLE;
SELECT t.expect('resolve: after 5 minutes it moves',(SELECT d.last_seen_at=now() FROM t.dev('r1') d));
SELECT t.expect('resolve: it writes no audit row',t.audits('r','device.resolved')=0
  AND (SELECT count(*)=0 FROM public.audit_log a WHERE a.organization_id=t.org('r') AND a.action LIKE 'device.%'
       AND a.action NOT IN ('device.created','device.updated','device.pairing_code_created','device.paired')));
-- A device that is off, a branch that is off, an archived device.
UPDATE public.devices SET is_active=false WHERE id=t.id('r1');
SET ROLE authenticated;
SELECT t.expect('resolve: a device that is off answers nothing',public.resolve_device(t.h('d')) IS NULL);
RESET ROLE;
UPDATE public.devices SET is_active=true WHERE id=t.id('r1');
UPDATE public.branches SET is_active=false WHERE id=t.id('second');
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.expect('resolve: a device of a branch that is off answers nothing',public.resolve_device(t.h('c')) IS NULL AND public.resolve_device(t.h('d')) IS NOT NULL);
RESET ROLE;
UPDATE public.branches SET is_active=true WHERE id=t.id('second');

-- ---------------------------------------------------------------- 5. app.current_device_id()
SELECT t.cashier(t.id('r1')::text);
SELECT t.expect('current device: the header''s device, when it is an active device of the caller''s shop',app.current_device_id()=t.id('r1'));
SELECT t.cashier(t.id('b1')::text);
SELECT t.expect('current device: another shop''s device is no device',app.current_device_id() IS NULL);
SELECT t.cashier(t.id('s2')::text);
SELECT t.expect('current device: another shop''s inactive device is no device',app.current_device_id() IS NULL);
-- The proof: a device id alone is what anyone can write who calls the database without the API.
SELECT t.cashier(t.id('r1')::text,NULL);
SELECT t.expect('current device: a hand-made x-device-id without the token hash is no device',app.current_device_id() IS NULL);
SELECT t.cashier(t.id('r1')::text,t.h('a'));
SELECT t.expect('current device: with the hash of a token that was replaced it is no device',app.current_device_id() IS NULL);
SELECT t.cashier(t.id('r1')::text,(SELECT d.token_hash FROM t.dev('r2') d));
SELECT t.expect('current device: with another device''s hash it is no device',app.current_device_id() IS NULL);
SELECT t.cashier(t.id('r1')::text,'not-a-hash');
SELECT t.expect('current device: with a text that is no hash it is no device',app.current_device_id() IS NULL);
SELECT t.cashier('not-a-uuid');
SELECT t.expect('current device: a header that is no uuid is no device',app.current_device_id() IS NULL);
SELECT t.cashier();
SELECT t.expect('current device: no header, no device',app.current_device_id() IS NULL);
SELECT t.as_user(NULL,NULL,t.id('r1')::text);
SELECT t.expect('current device: no session, no device',app.current_device_id() IS NULL);
UPDATE public.devices SET is_active=false WHERE id=t.id('r1');
SELECT t.cashier(t.id('r1')::text);
SELECT t.expect('current device: a device that is off is no device',app.current_device_id() IS NULL);
UPDATE public.devices SET is_active=true,archived_at=now() WHERE id=t.id('r1');
SELECT t.expect('current device: an archived device is no device',app.current_device_id() IS NULL);
UPDATE public.devices SET archived_at=NULL WHERE id=t.id('r1');
SELECT t.expect('current device: authenticated can''t call it directly',NOT has_function_privilege('authenticated','app.current_device_id()','EXECUTE'));

-- ---------------------------------------------------------------- 6. a shift needs the device of the request
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.error('shift: without a device',format('SELECT public.open_shift(%L,''0'',''o03-no-device'')',t.id('main')),'DEVICE_REQUIRED');
RESET ROLE;
SELECT t.cashier(t.id('b1')::text);
SET ROLE authenticated;
SELECT t.error('shift: a hand-made header naming another shop''s device',format('SELECT public.open_shift(%L,''0'',''o03-foreign-device'')',t.id('main')),'DEVICE_REQUIRED');
RESET ROLE;
SELECT t.cashier(t.id('r1')::text,NULL);
SET ROLE authenticated;
SELECT t.error('shift: a hand-made header naming a paired device of the shop, without its token hash',format('SELECT public.open_shift(%L,''0'',''o03-forged-device'')',t.id('main')),'DEVICE_REQUIRED');
RESET ROLE;
SELECT t.cashier(t.id('r3')::text);
SET ROLE authenticated;
SELECT t.error('shift: a device of another branch',format('SELECT public.open_shift(%L,''0'',''o03-other-branch'')',t.id('main')),'DEVICE_BRANCH_MISMATCH');
RESET ROLE;
SELECT t.cashier(t.id('r1')::text);
SET ROLE authenticated;
SELECT t.error('shift: a device id in the call that is not the request''s device',format('SELECT public.open_shift(%L,''0'',''o03-mismatch'',NULL,%L)',t.id('main'),t.id('r2')),'DEVICE_MISMATCH');
INSERT INTO t.ids SELECT 'shift',(public.open_shift(t.id('main'),'0','o03-shift')->>'id')::uuid;
SELECT t.expect('shift: the same key answers the same shift',(public.open_shift(t.id('main'),'0','o03-shift')->>'id')::uuid=t.id('shift'));
RESET ROLE;
SELECT t.expect('shift: it is opened on the device of the request, and the audit row names it',
  (SELECT s.device_id=t.id('r1') AND s.status='open' AND s.employee_id=t.id('cashier') FROM public.shifts s WHERE s.id=t.id('shift'))
  AND (SELECT a."after"->>'device_id'=t.id('r1')::text FROM public.audit_log a WHERE a.organization_id=t.org('r') AND a.action='shift.opened' AND a.entity_id=t.id('shift')));
SELECT t.expect('shift: none of the refused attempts opened one',(SELECT count(*)=1 FROM public.shifts s WHERE s.organization_id=t.org('r')));
SELECT t.cashier(t.id('r2')::text);
SET ROLE authenticated;
SELECT t.error('shift: one open shift per cashier',format('SELECT public.open_shift(%L,''0'',''o03-second'')',t.id('main')),'SHIFT_ALREADY_OPEN');
RESET ROLE;
SELECT t.owner_r(t.id('r1')::text);
SET ROLE authenticated;
SELECT t.error('shift: one open shift per device',format('SELECT public.open_shift(%L,''0'',''o03-same-device'')',t.id('main')),'SHIFT_ALREADY_OPEN');

-- ---------------------------------------------------------------- 7. a device with an open shift
SELECT t.error('open shift: the device can''t be moved',format('SELECT public.update_device(%L,NULL,%L)',t.id('r1'),t.id('second')),'DEVICE_HAS_OPEN_SHIFT');
SELECT t.error('open shift: the device can''t be turned off',format('SELECT public.set_device_active(%L,false,''Stolen'')',t.id('r1')),'DEVICE_HAS_OPEN_SHIFT');
SELECT public.update_device(t.id('r1'),'Front till');
RESET ROLE;
SELECT t.expect('open shift: the device is still there, paired, in its branch; a rename is fine',
  (SELECT d.is_active AND d.token_hash=t.h('d') AND d.branch_id=t.id('main') AND d.name='Front till' FROM t.dev('r1') d));

-- ---------------------------------------------------------------- 8. a sale takes its shift's device
SELECT t.owner_r();
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"O3-TV","cash_price":"1140","eta_item_code":"EG-674859545-TV","eta_item_type":"EGS"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',10)),'o03-found');
SELECT public.set_eta_settings('preprod','client-r','secret-r-1','4753',true);
RESET ROLE;
-- The cashier sells from a request that names no device at all, then from one that names another.
SELECT t.cashier();
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'sale1',(public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),'1140.00','o03-sale-1')->>'id')::uuid;
RESET ROLE;
SELECT t.cashier(t.id('r2')::text);
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'sale2',(public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),'1140.00','o03-sale-2')->>'id')::uuid;
RESET ROLE;
SELECT t.expect('sale: both sales carry the device of their shift',
  (SELECT count(*)=2 AND bool_and(s.device_id=t.id('r1') AND s.shift_id=t.id('shift')) FROM public.sales s WHERE s.id IN (t.id('sale1'),t.id('sale2'))),
  (SELECT string_agg(COALESCE(s.device_id::text,'null'),',') FROM public.sales s WHERE s.organization_id=t.org('r')));
SELECT t.expect('sale: the ETA receipt of each sale is for the same device (never blocked for want of one)',
  (SELECT count(*)=2 AND bool_and(f.device_id=t.id('r1') AND f.status='pending') FROM public.fiscal_submissions f WHERE f.sale_id IN (t.id('sale1'),t.id('sale2'))),
  (SELECT string_agg(COALESCE(f.device_id::text,'null')||' '||f.status,',') FROM public.fiscal_submissions f WHERE f.organization_id=t.org('r')));
-- The rule itself, on the table: a sale row that names another device than its shift's is refused.
SELECT t.error('sale: a row that names another device than its shift''s',
  format($q$INSERT INTO public.sales SELECT (jsonb_populate_record(NULL::public.sales,to_jsonb(s)||jsonb_build_object('id',gen_random_uuid(),'number','O03-X','idempotency_key','o03-x','device_id',%L))).* FROM public.sales s WHERE s.id=%L$q$,t.id('r2'),t.id('sale1')),
  'DEVICE_MISMATCH');
SELECT t.expect('sale: the rule is a BEFORE INSERT trigger on sales',
  (SELECT count(*)=1 FROM pg_trigger g WHERE g.tgrelid='public.sales'::regclass AND g.tgname='trg_sales_a_device' AND NOT g.tgisinternal AND (g.tgtype & 2)=2 AND (g.tgtype & 4)=4));

-- ---------------------------------------------------------------- 9. unpairing and turning a device off
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.code('r2','9');
SELECT t.expect('unpair: answers the device as unpaired',public.unpair_device(t.id('r2'))=jsonb_build_object('id',t.id('r2'),'paired',false));
SELECT t.expect('unpair: the token of the device resolves to nothing from now on',public.resolve_device(t.h('b')) IS NULL);
SELECT t.refused('unpair: the code made before it is gone too',t.h('9'),t.h('f'));
RESET ROLE;
SELECT t.expect('unpair: no token, no code, still an active device',
  (SELECT d.token_hash IS NULL AND d.paired_at IS NULL AND d.paired_by IS NULL AND d.pairing_code_hash IS NULL AND d.is_active FROM t.dev('r2') d)
  AND t.audits('r','device.unpaired')=1);
SELECT t.cashier(t.id('r2')::text);
SET ROLE authenticated;
INSERT INTO t.ids VALUES('sale3',(public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),'1140.00','o03-sale-3')->>'id')::uuid);
RESET ROLE;
SELECT t.expect('unpair: the open shift of another device goes on selling on its own device',(SELECT s.device_id=t.id('r1') FROM public.sales s WHERE s.id=t.id('sale3')));
-- The cashier closes; now the device can be turned off, which unpairs it.
SELECT t.cashier();
SET ROLE authenticated;
SELECT public.close_shift(t.id('shift'),'{}'::jsonb,NULL,'O03 test');
RESET ROLE;
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.code('r1','0');
SELECT t.expect('off: answers id and is_active',public.set_device_active(t.id('r1'),false,' Stolen ')=jsonb_build_object('id',t.id('r1'),'is_active',false));
SELECT t.expect('off: the token of the device resolves to nothing',public.resolve_device(t.h('d')) IS NULL);
SELECT t.refused('off: its pairing code is gone',t.h('0'),t.h('f'));
RESET ROLE;
SELECT t.owner_r(t.id('r1')::text);
SET ROLE authenticated;
SELECT t.error('off: no shift on a device that is off',format('SELECT public.open_shift(%L,''0'',''o03-device-off'')',t.id('main')),'DEVICE_REQUIRED');
SELECT t.expect('on: answers id and is_active',public.set_device_active(t.id('r1'),true)=jsonb_build_object('id',t.id('r1'),'is_active',true));
SELECT t.expect('on: turning it on twice changes nothing',public.set_device_active(t.id('r1'),true)=jsonb_build_object('id',t.id('r1'),'is_active',true));
RESET ROLE;
SELECT t.expect('on: the device is active again and still unpaired',(SELECT d.is_active AND d.token_hash IS NULL AND d.pairing_code_hash IS NULL FROM t.dev('r1') d));
SELECT t.expect('off/on: each is audited once, turning off as a warning with its reason',
  (SELECT count(*)=1 AND bool_and(a.severity='warning' AND a.reason='Stolen' AND (a."after"->>'was_paired')::boolean)
   FROM public.audit_log a WHERE a.organization_id=t.org('r') AND a.action='device.deactivated')
  AND t.audits('r','device.reactivated')=1);

-- ---------------------------------------------------------------- 10. secrets
SELECT t.expect('secrets: authenticated can read neither hash column of devices',
  NOT has_column_privilege('authenticated','public.devices','pairing_code_hash','SELECT')
  AND NOT has_column_privilege('authenticated','public.devices','token_hash','SELECT')
  AND NOT has_column_privilege('anon','public.devices','token_hash','SELECT')
  AND has_column_privilege('authenticated','public.devices','paired_at','SELECT'));
SELECT t.owner_r();
SET ROLE authenticated;
SELECT t.state('secrets: selecting the token hash is refused','SELECT token_hash FROM public.devices','42501');
SELECT t.state('secrets: selecting the code hash is refused','SELECT pairing_code_hash FROM public.devices','42501');
SELECT t.state('secrets: a device can''t be paired by writing the column','UPDATE public.devices SET token_hash=repeat(''f'',64)','42501');
SELECT t.expect('secrets: the device list says paired or not, when it was paired and last seen, and holds no hash',
  (SELECT count(*)=3 AND count(*) FILTER(WHERE (d->>'paired')::boolean)=1 AND bool_and(d ? 'paired_at' AND d ? 'last_seen_at')
     AND bool_and(NOT (d ? 'token_hash') AND NOT (d ? 'pairing_code_hash')) FROM jsonb_array_elements(public.list_devices()) d),
  public.list_devices()::text);
RESET ROLE;
SELECT t.expect('secrets: no audit row of any shop holds a code hash or a token hash',
  NOT EXISTS (SELECT 1 FROM public.audit_log a, unnest(ARRAY['0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f']) c
              WHERE a.organization_id IN (t.org('s'),t.org('r'),t.org('b')) AND row_to_json(a)::text LIKE '%'||t.h(c)||'%'));
SELECT t.expect('secrets: the device functions are for signed-in users only; resolve asks for no permission key',
  NOT has_function_privilege('anon','public.pair_device(text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.resolve_device(text)','EXECUTE')
  AND has_function_privilege('authenticated','public.resolve_device(text)','EXECUTE')
  AND has_function_privilege('authenticated','public.pair_device(text,text)','EXECUTE'));
SELECT t.expect('secrets: token hashes are unique, and so is a device name in its branch',
  (SELECT count(*)=2 FROM pg_indexes i WHERE i.schemaname='public' AND i.tablename='devices' AND i.indexname IN ('devices_token_hash_idx','devices_branch_name_idx') AND i.indexdef LIKE 'CREATE UNIQUE%'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
