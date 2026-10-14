\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request. t.open_shift pairs a free device of the
-- branch (or the one named) and puts it in the request headers the way the API does once it has
-- resolved a device token: x-device-id with the hash of that token (x-device-token-hash). Then it
-- calls public.open_shift unchanged.
CREATE FUNCTION t.pos(p_branch uuid, p_device uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_org uuid := app.current_org_id(); v_id uuid := p_device; v_hash text;
BEGIN
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch AND b.organization_id = v_org) THEN
    RETURN NULL;
  END IF;
  IF v_id IS NULL THEN
    SELECT d.id INTO v_id FROM public.devices d
    WHERE d.organization_id = v_org AND d.branch_id = p_branch AND d.is_active AND d.archived_at IS NULL AND d.name LIKE 'Test POS %'
      AND NOT EXISTS (SELECT 1 FROM public.shifts s WHERE s.device_id = d.id AND s.status = 'open')
    ORDER BY d.name LIMIT 1;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.devices (organization_id, branch_id, name) VALUES (v_org, p_branch, 'Test POS ' || gen_random_uuid())
    RETURNING id INTO v_id;
  END IF;
  -- Paired, as the pairing screens leave it: the device holds the hash of a token.
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
GRANT EXECUTE ON FUNCTION t.pos(uuid, uuid), t.open_shift(uuid, text, text, uuid, uuid) TO authenticated;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE (jsonb_build_object('x-org-id',o) || COALESCE((SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.employees e ON e.id=s.employee_id JOIN public.devices d ON d.id=s.device_id WHERE s.organization_id=o AND s.status='open' AND d.is_active AND d.archived_at IS NULL AND d.token_hash IS NOT NULL ORDER BY (e.auth_user_id::text=u) DESC,s.opened_at DESC,s.id DESC LIMIT 1),'{}'::jsonb))::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- (SECURITY DEFINER: a cashier can't read the audit log.)
CREATE FUNCTION t.audits(a text,i text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(i) $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.drawer(s text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT b.balance FROM public.cash_balances b JOIN public.shifts x ON x.drawer_account_id=b.cash_account_id WHERE x.id=t.id(s)),0) $$;
-- What a shift should hold now, as the API says it.
CREATE FUNCTION t.expected(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.shift_json((SELECT organization_id FROM public.shifts WHERE id=t.id(s)),t.id(s),false)->>'expected_cash' $$;
CREATE FUNCTION t.status(s text) RETURNS text LANGUAGE sql AS $$ SELECT status::text FROM public.shifts WHERE id=t.id(s) $$;
-- A cash move call as SQL text, for t.error.
CREATE FUNCTION t.move(s text,dir text,amount text,vault text DEFAULT 'safe',note text DEFAULT 'Change for the till') RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.move_shift_cash(%L,%L,%L,%L,%L,%L)',t.id(s),dir,amount,t.id(vault),note,'k02-'||md5(random()::text)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a, shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('K02 '||s,'k02-'||s,'retail','Owner',s||'k02@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('p',64)),('b',repeat('q',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a6020000-0000-0000-8000-000000000001','ak02@example.com'),('a6020000-0000-0000-8000-000000000002','bk02@example.com'),
  ('a6020000-0000-0000-8000-000000000003','k02cashier1@example.com'),('a6020000-0000-0000-8000-000000000004','k02cashier2@example.com'),
  ('a6020000-0000-0000-8000-000000000005','k02accountant@example.com'),('a6020000-0000-0000-8000-000000000006','k02warehouse@example.com');
SELECT public.accept_invite(repeat('p',64),'a6020000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a6020000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'safe_b',default_cash_account_id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a6020000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','K2',NULL,NULL,NULL,NULL,NULL));
SELECT public.post_cash_opening(t.id('safe'),'5000.00','Counted on day one','k02-opening');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
INSERT INTO t.ids SELECT 'spare',(public.create_cash_account('Spare','safe',t.id('main'))->>'id')::uuid;
SELECT public.set_cash_account_active(t.id('spare'),false);
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('c1','a6020000-0000-0000-8000-000000000003','Mona Cashier','CASHIER','main');
SELECT t.emp('c2','a6020000-0000-0000-8000-000000000004','Omar Cashier','CASHIER','main');
SELECT t.emp('acc','a6020000-0000-0000-8000-000000000005','K02 Accountant','ACCOUNTANT','main');
SELECT t.emp('wh','a6020000-0000-0000-8000-000000000006','K02 Warehouse','WAREHOUSE','main');
WITH d AS (INSERT INTO public.devices(organization_id,branch_id,name) VALUES(t.org('a'),t.id('main'),'POS 1') RETURNING id) INSERT INTO t.ids SELECT 'pos1',id FROM d;
WITH d AS (INSERT INTO public.devices(organization_id,branch_id,name) VALUES(t.org('a'),t.id('second'),'POS 2') RETURNING id) INSERT INTO t.ids SELECT 'pos2',id FROM d;
WITH d AS (INSERT INTO public.devices(organization_id,branch_id,name,is_active) VALUES(t.org('a'),t.id('main'),'POS old',false) RETURNING id) INSERT INTO t.ids SELECT 'pos_old',id FROM d;

-- ---------------------------------------------------------------- open
SELECT t.as_user('a6020000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 's1',(t.open_shift(t.id('main'),'500.00','k02-open-1',t.id('safe'))->>'id')::uuid;
RESET ROLE;
SELECT t.expect('open: an open shift numbered SH with the float taken from the safe into its own drawer',
  s->>'number' LIKE '%-SH-%' AND s->>'status'='open' AND s->>'opening_float'='500.00' AND s->>'expected_cash'='500.00'
  AND s->>'employee_name'='Mona Cashier' AND s->>'counted_cash' IS NULL
  AND t.cash('safe')=4500 AND t.drawer('s1')=500
  AND (SELECT kind='drawer' AND branch_id=t.id('main') FROM public.cash_accounts WHERE id=(s->>'drawer_account_id')::uuid)
  AND jsonb_array_length(s->'movements')=1 AND s->'movements'->0->>'type'='float_in'
  AND s->'movements'->0->>'amount'='500.00' AND s->'movements'->0->>'source_number' LIKE '%-CX-%'
  AND t.audits('shift.opened','s1')=1, s::text)
FROM (SELECT app.shift_json(t.org('a'),t.id('s1'),true) s) x;
SET ROLE authenticated;
SELECT current_user AS test4_role \gset
RESET ROLE;
\ir helpers/test4_snapshot.sql
SET ROLE :"test4_role";
SELECT t.snapshot(t.org('a'))::text AS test4_snapshot \gset
SELECT t.expect('open: the same key again -> the same shift, nothing moves',
  (public.open_shift(t.id('main'),'500.00','k02-open-1',t.id('safe'))->>'id')::uuid=t.id('s1')
  AND t.cash('safe')=4500 AND (SELECT count(*) FROM public.shifts)=1);
SELECT t.expect('TEST4 replay snapshot 1',t.snapshot(t.org('a'))=:'test4_snapshot'::jsonb);
SELECT t.error('open: one open shift per cashier',format('SELECT t.open_shift(%L,%L,%L)',t.id('main'),'0','k02-open-again'),'SHIFT_ALREADY_OPEN');
SELECT t.expect('current: the cashier''s open shift',(public.get_current_shift()->>'id')::uuid=t.id('s1'));

-- ---------------------------------------------------------------- Done when: expected cash is the shift's drawer ledger
RESET ROLE;
-- A cash sale of 300 and a refund of 50, as S01 will post them (drawer, tagged with the shift).
INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,shift_id,amount,type,source_type,source_id,business_date)
SELECT t.org('a'),drawer_account_id,branch_id,id,v.amount,v.type::public.cash_movement_type,'sale',gen_random_uuid(),app.org_today(t.org('a'))
FROM public.shifts,(VALUES(300,'sale'),(-50,'refund'))v(amount,type) WHERE id=t.id('s1');
SELECT t.expect('Done when: expected cash = float + the shift''s drawer ledger (750), not the safe (4 500)',
  t.expected('s1')='750.00' AND t.cash('safe')=4500 AND t.drawer('s1')=750
  AND (SELECT expected_cash=750 AND cash_in=800 AND cash_out=50 FROM public.v_shift_expected_cash WHERE shift_id=t.id('s1')));
SELECT t.as_user('a6020000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;

-- ---------------------------------------------------------------- cash in and out during the shift
SELECT t.expect('pay-out: 200 dropped into the safe',
  public.move_shift_cash(t.id('s1'),'out','200.00',t.id('safe'),'  Too much cash in the till ','k02-out-1')->>'expected_cash'='550.00'
  AND t.cash('safe')=4700);
SELECT t.snapshot(t.org('a'))::text AS test4_snapshot \gset
SELECT t.expect('pay-out: the same key again -> nothing moves',
  public.move_shift_cash(t.id('s1'),'out','200.00',t.id('safe'),'Too much cash in the till','k02-out-1')->>'expected_cash'='550.00'
  AND t.cash('safe')=4700 AND t.audits('shift.cash_moved','s1')=1);
SELECT t.expect('TEST4 replay snapshot 2',t.snapshot(t.org('a'))=:'test4_snapshot'::jsonb);
SELECT t.expect('pay-in: 100 of change from the safe',
  public.move_shift_cash(t.id('s1'),'in','100.00',t.id('safe'),'Change for the till','k02-in-1')->>'expected_cash'='650.00'
  AND t.cash('safe')=4600 AND t.drawer('s1')=650);
SELECT t.error('cash: an unknown direction',t.move('s1','sideways','10.00'),'VALIDATION_FAILED');
SELECT t.error('cash: no note',t.move('s1','in','10.00','safe','  '),'VALIDATION_FAILED');
SELECT t.error('cash: amount 0',t.move('s1','in','0.00'),'VALIDATION_FAILED');
SELECT t.error('cash: another branch''s safe',t.move('s1','in','10.00','safe2'),'VAULT_INVALID');
SELECT t.error('cash: a bank is not a vault for a drawer',t.move('s1','in','10.00','bank'),'VAULT_INVALID');
SELECT t.error('cash: another shop''s safe',t.move('s1','in','10.00','safe_b'),'VAULT_INVALID');
SELECT t.error('cash: an inactive safe',t.move('s1','in','10.00','spare'),'CASH_ACCOUNT_INACTIVE');
SELECT t.error('cash: more out than the drawer holds',t.move('s1','out','651.00'),'INSUFFICIENT_FUNDS');
SELECT t.error('cash: more in than the safe holds',t.move('s1','in','99999.00'),'INSUFFICIENT_FUNDS');
SELECT t.error('cash: a system key',format('SELECT public.move_shift_cash(%L,%L,%L,%L,%L,%L)',t.id('s1'),'in','1.00',t.id('safe'),'A note','system:k02'),'VALIDATION_FAILED');
SELECT t.expect('cash: refused moves changed nothing',t.expected('s1')='650.00' AND t.cash('safe')=4600);

-- ---------------------------------------------------------------- close
SELECT t.error('close: an unknown denomination',format('SELECT public.close_shift(%L,%L,%L)',t.id('s1'),'{"25":1}',t.id('safe')),'VALIDATION_FAILED');
SELECT t.error('close: a count that is not a whole number',format('SELECT public.close_shift(%L,%L,%L)',t.id('s1'),'{"200":1.5}',t.id('safe')),'VALIDATION_FAILED');
SELECT t.error_detail('close: a difference needs a reason',format('SELECT public.close_shift(%L,%L,%L)',t.id('s1'),'{"200":3,"20":2}',t.id('safe')),
  'SHIFT_DIFFERENCE_REASON_REQUIRED','{"expected":"650.00","counted":"640.00","difference":"-10.00"}');
SELECT t.error('close: counted cash needs a safe',format('SELECT public.close_shift(%L,%L,NULL,%L)',t.id('s1'),'{"200":3,"20":2}','Ten short'),'VALIDATION_FAILED');
SELECT t.error('close: into another branch''s safe',format('SELECT public.close_shift(%L,%L,%L,%L)',t.id('s1'),'{"200":3,"20":2}',t.id('safe2'),'Ten short'),'VAULT_INVALID');
SELECT t.expect('close: still open after the refused closes',t.status('s1')='open' AND t.expected('s1')='650.00');
SELECT t.expect('close: counted 640 of 650 with a reason -> closed, expected, counted and difference kept',
  s->>'status'='closed' AND s->>'expected_cash'='650.00' AND s->>'counted_cash'='640.00' AND s->>'difference'='-10.00'
  AND s->>'difference_reason'='Ten pounds short' AND s->'count_breakdown'='{"200":3,"20":2}'::jsonb
  AND s->>'closed_by_name'='Mona Cashier' AND s->>'closed_at' IS NOT NULL, s::text)
FROM (SELECT public.close_shift(t.id('s1'),'{"200":3,"20":2}',t.id('safe'),'  Ten pounds short ') s) x;
RESET ROLE;
SELECT t.expect('close: the drawer is empty, the counted cash is in the safe, the difference is an adjustment',
  t.drawer('s1')=0 AND t.cash('safe')=5240
  AND (SELECT count(*)=1 AND bool_and(amount=-10 AND note='Ten pounds short') FROM public.cash_movements WHERE shift_id=t.id('s1') AND type='adjustment')
  AND (SELECT count(*)=1 AND bool_and(severity='warning' AND reason='Ten pounds short') FROM public.audit_log WHERE action='shift.closed' AND entity_id=t.id('s1')));
SELECT t.expect('close: the view keeps the snapshot for a closed shift',
  (SELECT expected_cash=650 AND counted_cash=640 AND difference=-10 FROM public.v_shift_expected_cash WHERE shift_id=t.id('s1')));

-- ---------------------------------------------------------------- Done when: a closed shift can't take sales
SELECT t.error('Done when: a closed shift takes no cash movement (so no sale)',
  format('INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,shift_id,amount,type,source_type,source_id,business_date) SELECT organization_id,drawer_account_id,branch_id,id,10,%L,%L,gen_random_uuid(),current_date FROM public.shifts WHERE id=%L','sale','sale',t.id('s1')),'SHIFT_CLOSED');
SELECT t.error('Done when: selling needs an open shift',format('SELECT app.require_open_shift(%L,%L)',t.org('a'),t.id('c1')),'SHIFT_REQUIRED');
SELECT t.as_user('a6020000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('close: again -> answered unchanged, nothing moves',
  public.close_shift(t.id('s1'),'{"200":9}',t.id('safe'),'Again')->>'counted_cash'='640.00' AND t.cash('safe')=5240
  AND t.audits('shift.closed','s1')=1);
SELECT t.error('close: no cash moves on a closed shift',t.move('s1','in','10.00'),'SHIFT_CLOSED');
SELECT t.expect('current: no open shift after closing',public.get_current_shift() IS NULL);

-- ---------------------------------------------------------------- a second shift: same drawer, nothing carried over
SELECT t.error('open: a float needs a safe',format('SELECT t.open_shift(%L,%L,%L)',t.id('main'),'100.00','k02-no-vault'),'VALIDATION_FAILED');
SELECT t.error('open: no float, no safe',format('SELECT t.open_shift(%L,%L,%L,%L)',t.id('main'),'0','k02-vault-no-float',t.id('safe')),'VALIDATION_FAILED');
SELECT t.error('open: a negative float',format('SELECT t.open_shift(%L,%L,%L,%L)',t.id('main'),'-5','k02-negative',t.id('safe')),'VALIDATION_FAILED');
SELECT t.error('open: more float than the safe holds',format('SELECT t.open_shift(%L,%L,%L,%L)',t.id('main'),'99999.00','k02-too-much',t.id('safe')),'INSUFFICIENT_FUNDS');
SELECT t.error('open: a device of another branch (O03)',format('SELECT t.open_shift(%L,%L,%L,NULL,%L)',t.id('main'),'0','k02-dev-branch',t.id('pos2')),'DEVICE_BRANCH_MISMATCH');
SELECT t.error('open: an inactive device is no device (O03)',format('SELECT t.open_shift(%L,%L,%L,NULL,%L)',t.id('main'),'0','k02-dev-old',t.id('pos_old')),'DEVICE_REQUIRED');
SELECT t.error('open: a branch the cashier doesn''t work in',format('SELECT t.open_shift(%L,%L,%L)',t.id('second'),'0','k02-other-branch'),'BRANCH_DENIED');
INSERT INTO t.ids SELECT 's2',(t.open_shift(t.id('main'),'0','k02-open-2',NULL,t.id('pos1'))->>'id')::uuid;
SELECT t.expect('second shift: the same drawer, on a device, expected 0 (nothing from the first shift)',
  (SELECT drawer_account_id FROM public.shifts WHERE id=t.id('s2'))=(SELECT drawer_account_id FROM public.shifts WHERE id=t.id('s1'))
  AND t.expected('s2')='0.00' AND public.get_current_shift()->>'device_name'='POS 1'
  AND (SELECT count(*) FROM public.cash_accounts WHERE organization_id=t.org('a') AND kind='drawer')=1);
RESET ROLE;
SELECT t.as_user('a6020000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('open: the device already has an open shift',format('SELECT t.open_shift(%L,%L,%L,NULL,%L)',t.id('main'),'0','k02-dev-busy',t.id('pos1')),'SHIFT_ALREADY_OPEN');
INSERT INTO t.ids SELECT 's3',(t.open_shift(t.id('main'),'200.00','k02-open-3',t.id('safe'))->>'id')::uuid;
SELECT t.expect('another cashier: their own drawer and shift',
  (SELECT drawer_account_id FROM public.shifts WHERE id=t.id('s3'))<>(SELECT drawer_account_id FROM public.shifts WHERE id=t.id('s1'))
  AND t.expected('s3')='200.00');
SELECT t.error('who: a cashier can''t read another cashier''s shift',format('SELECT public.get_shift(%L)',t.id('s2')),'SHIFT_NOT_FOUND');
SELECT t.error('who: a cashier can''t close another cashier''s shift',format('SELECT public.close_shift(%L,%L)',t.id('s2'),'{}'),'SHIFT_NOT_FOUND');
SELECT t.error('who: a cashier can''t move another cashier''s cash',t.move('s2','in','10.00'),'SHIFT_NOT_FOUND');
SELECT t.expect('who: a cashier lists only their own shifts',(public.list_shifts()->>'total')::int=1);
SELECT t.expect('vaults: the branch''s active safes by name, no balances',
  (SELECT array_agg(x->>'name') FROM jsonb_array_elements(v->'items') x)=ARRAY['الخزنة الرئيسية'] AND NOT (v->'items'->0) ? 'balance', v::text)
FROM (SELECT public.list_shift_vaults(t.id('main')) v) x;
SELECT t.error('vaults: a branch the cashier doesn''t work in',format('SELECT public.list_shift_vaults(%L)',t.id('second')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.as_user('a6020000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('close: an exact count of 0 needs no reason and no safe',
  s->>'status'='closed' AND s->>'difference'='0.00' AND s->>'difference_reason' IS NULL AND s->>'counted_cash'='0.00', s::text)
FROM (SELECT public.close_shift(t.id('s2'),'{}',NULL,'Not needed') s) x;
RESET ROLE;

-- ---------------------------------------------------------------- the owner takes over; readers
SELECT t.as_user('a6020000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('take over: the owner adds cash to a cashier''s shift',
  public.move_shift_cash(t.id('s3'),'in','50.00',t.id('safe'),'More change','k02-owner-in')->>'expected_cash'='250.00');
SELECT t.expect('take over: the owner closes it (an overage of 5)',
  s->>'status'='closed' AND s->>'difference'='5.00' AND s->>'closed_by_name'='Owner'
  AND s->>'employee_name'='Omar Cashier', s::text)
FROM (SELECT public.close_shift(t.id('s3'),'{"200":1,"50":1,"5":1}',t.id('safe'),'Found five pounds') s) x;
SELECT t.expect('list: every shift of the branches; filters by status, cashier, branch and day',
  (public.list_shifts()->>'total')::int=3 AND (public.list_shifts(NULL,NULL,'closed')->>'total')::int=3
  AND (public.list_shifts(NULL,NULL,'open')->>'total')::int=0
  AND (public.list_shifts(NULL,t.id('c1'))->>'total')::int=2
  AND (public.list_shifts(t.id('second'))->>'total')::int=0
  AND (public.list_shifts(t.id('main'),NULL,NULL,current_date-1,current_date+1,2,1)->>'total')::int=3
  AND jsonb_array_length(public.list_shifts(t.id('main'),NULL,NULL,current_date-1,current_date+1,2,1)->'items')=2
  AND (public.list_shifts(NULL,NULL,NULL,current_date+2)->>'total')::int=0
  AND NOT (public.list_shifts()->'items'->0) ? 'movements');
SELECT t.error('list: an unknown status',$$SELECT public.list_shifts(NULL,NULL,'paused')$$,'VALIDATION_FAILED');
SELECT t.error('list: an unknown cashier',format('SELECT public.list_shifts(NULL,%L)',gen_random_uuid()),'EMPLOYEE_NOT_FOUND');
SELECT t.expect('K01: the float, the moves and the closing show as cash transfers of the safe',
  (public.list_cash_transfers(t.id('safe'))->>'total')::int=7);
RESET ROLE;
SELECT t.expect('the safe adds up: 5 000 - 500 + 200 - 100 + 640 - 200 - 50 + 255',t.cash('safe')=5245,t.cash('safe')::text);
SELECT t.as_user('a6020000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('who: an ACCOUNTANT (cash.view) reads every shift',
  (public.list_shifts()->>'total')::int=3 AND public.get_shift(t.id('s1'))->>'status'='closed' AND public.get_current_shift() IS NULL);
SELECT t.error('who: an ACCOUNTANT can''t open a shift',format('SELECT t.open_shift(%L,%L,%L)',t.id('main'),'0','k02-accountant'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a6020000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: a WAREHOUSE user can''t list shifts',$$SELECT public.list_shifts()$$,'PERMISSION_DENIED');
SELECT t.error('who: a WAREHOUSE user has no current shift to read',$$SELECT public.get_current_shift()$$,'PERMISSION_DENIED');
SELECT t.error('who: a WAREHOUSE user can''t open a shift',format('SELECT t.open_shift(%L,%L,%L)',t.id('main'),'0','k02-warehouse'),'PERMISSION_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- tenancy, ledger, expired shop, grants
SELECT t.as_user('a6020000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: a''s shift',format('SELECT public.get_shift(%L)',t.id('s1')),'SHIFT_NOT_FOUND');
SELECT t.error('shop b: closing a''s shift',format('SELECT public.close_shift(%L,%L)',t.id('s1'),'{}'),'SHIFT_NOT_FOUND');
SELECT t.error('shop b: a''s branch',format('SELECT t.open_shift(%L,%L,%L)',t.id('main'),'0','k02-b-branch'),'BRANCH_NOT_FOUND');
SELECT t.error('shop b: a float from a''s safe',format('SELECT t.open_shift(%L,%L,%L,%L)',t.id('main_b'),'10.00','k02-b-safe',t.id('safe')),'VAULT_INVALID');
SELECT t.error('shop b: a''s vault list',format('SELECT public.list_shift_vaults(%L)',t.id('main')),'BRANCH_NOT_FOUND');
SELECT t.expect('shop b: lists no shifts',(public.list_shifts()->>'total')::int=0);
SELECT t.error('no direct writes',format('INSERT INTO public.shifts(organization_id,number,branch_id,employee_id,drawer_account_id,idempotency_key) VALUES(%L,%L,%L,%L,%L,%L)',t.org('b'),'X',t.id('main_b'),t.id('c1'),t.id('safe_b'),'k02-direct'),'permission denied for table shifts');
RESET ROLE;
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a6020000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired shop: shifts still read',(public.list_shifts()->>'total')::int=2 AND public.get_shift(t.id('s1')) ? 'movements');
SELECT t.error('expired shop: no new shift',format('SELECT t.open_shift(%L,%L,%L)',t.id('main'),'0','k02-expired'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('grants: the seven functions for authenticated, helpers not',
  has_function_privilege('authenticated','t.open_shift(uuid,text,text,uuid,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.move_shift_cash(uuid,text,text,uuid,text,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.close_shift(uuid,jsonb,uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_current_shift()','EXECUTE')
  AND has_function_privilege('authenticated','public.get_shift(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_shifts(uuid,uuid,text,date,date,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_shift_vaults(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','t.open_shift(uuid,text,text,uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.shift_json(uuid,uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.require_open_shift(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.shift_transfer(uuid,uuid,public.shifts,public.cash_accounts,numeric,boolean,text,text)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
