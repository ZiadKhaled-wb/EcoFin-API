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
CREATE FUNCTION t.audits(a text,s text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(s) $$;
CREATE FUNCTION t.bal(s text) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(s)),0) $$;
CREATE FUNCTION t.moves(s text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.cash_movements WHERE cash_account_id=t.id(s) $$;
-- Every row's balance_after = the next (older) row's balance_after + its own amount; the oldest starts at opening.
CREATE FUNCTION t.running_ok(l jsonb) RETURNS boolean LANGUAGE sql AS $$
  WITH r AS (SELECT o,(x->>'amount')::numeric a,(x->>'balance_after')::numeric b FROM jsonb_array_elements(l->'items') WITH ORDINALITY y(x,o))
  SELECT bool_and(r.b - r.a = COALESCE((SELECT n.b FROM r n WHERE n.o=r.o+1),(l->>'opening_balance')::numeric)) FROM r $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (two branches), shop b, five people
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('K01 '||s,'k01-'||s,'retail','Owner',s||'k01@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('k',64)),('b',repeat('m',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a5900000-0000-0000-8000-000000000001','ak01@example.com'),('a5900000-0000-0000-8000-000000000002','bk01@example.com'),
  ('a5900000-0000-0000-8000-000000000003','k01accountant@example.com'),('a5900000-0000-0000-8000-000000000004','k01manager@example.com'),
  ('a5900000-0000-0000-8000-000000000005','k01cashier@example.com'),('a5900000-0000-0000-8000-000000000006','k01stranger@example.com');
SELECT public.accept_invite(repeat('k',64),'a5900000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('m',64),'a5900000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'cash',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'cash_b',default_cash_account_id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a5900000-0000-0000-8000-000000000001',t.org('a'));
INSERT INTO t.ids VALUES('second',public.create_branch('Second','K2',NULL,NULL,NULL,NULL,NULL));
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5900000-0000-0000-8000-000000000003','K01 Accountant','ACCOUNTANT',t.id('main')) RETURNING id AS accountant_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'accountant_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5900000-0000-0000-8000-000000000004','K01 Manager','BRANCH_MANAGER',t.id('second')) RETURNING id AS manager_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'manager_id',t.id('second'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a5900000-0000-0000-8000-000000000005','K01 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
-- A drawer (K02's kind): not managed or listed by K01.
WITH x AS (INSERT INTO public.cash_accounts(organization_id,branch_id,name,kind) VALUES(t.org('a'),t.id('main'),'Drawer 1','drawer') RETURNING id) INSERT INTO t.ids SELECT 'drawer',id FROM x;
SELECT t.expect('setup: each branch has its default safe, no movements yet',
  t.id('cash') IS NOT NULL AND t.id('safe2') IS NOT NULL AND t.moves('cash')=0 AND t.moves('safe2')=0);

-- ---------------------------------------------------------------- create / rename
SELECT t.as_user('a5900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'vault2',(public.create_cash_account('  Back Safe  ','safe',t.id('main'))->>'id')::uuid;
SELECT t.expect('create: a safe in a branch, trimmed, balance 0, not the default',
  a->>'name'='Back Safe' AND a->>'kind'='safe' AND (a->>'branch_id')::uuid=t.id('main') AND a->>'branch_name'='Main'
  AND a->>'balance'='0.00' AND a->>'is_default'='false' AND a->>'is_active'='true', a::text)
FROM (SELECT public.get_cash_account(t.id('vault2')) a) x;
INSERT INTO t.ids SELECT 'nbe',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
SELECT t.expect('create: a shop-wide bank',
  a->'branch_id'='null'::jsonb AND a->'branch_name'='null'::jsonb AND a->>'kind'='bank', a::text)
FROM (SELECT public.get_cash_account(t.id('nbe')) a) x;
INSERT INTO t.ids SELECT 'cib',(public.create_cash_account('CIB','bank',t.id('main'))->>'id')::uuid;
SELECT t.error('create: a safe without a branch',$q$SELECT public.create_cash_account('Loose','safe',NULL)$q$,'VALIDATION_FAILED');
SELECT t.error('create: a drawer',format('SELECT public.create_cash_account(%L,%L,%L)','D2','drawer',t.id('main')),'VALIDATION_FAILED');
SELECT t.error('create: a collector wallet',format('SELECT public.create_cash_account(%L,%L,%L)','W','collector_wallet',t.id('main')),'VALIDATION_FAILED');
SELECT t.error('create: a blank name',format('SELECT public.create_cash_account(%L,%L,%L)','   ','safe',t.id('main')),'VALIDATION_FAILED');
SELECT t.error('create: a name over 100',format('SELECT public.create_cash_account(%L,%L,%L)',repeat('n',101),'safe',t.id('main')),'VALIDATION_FAILED');
SELECT t.error('create: the same name in the same branch',format('SELECT public.create_cash_account(%L,%L,%L)','Back Safe','bank',t.id('main')),'CASH_ACCOUNT_NAME_TAKEN');
SELECT t.error('create: the same name among shop-wide banks',$q$SELECT public.create_cash_account(' NBE ','bank',NULL)$q$,'CASH_ACCOUNT_NAME_TAKEN');
SELECT t.expect('create: the same name in another branch is allowed',
  public.create_cash_account('Back Safe','safe',t.id('second'))->>'name'='Back Safe');
SELECT t.error('create: another shop''s branch',format('SELECT public.create_cash_account(%L,%L,%L)','X','safe',t.id('main_b')),'BRANCH_NOT_FOUND');
SELECT t.expect('create: one cash_account.created row',t.audits('cash_account.created','vault2')=1);
SELECT t.expect('rename: renamed and audited; kind and branch unchanged',
  a->>'name'='Rear Safe' AND a->>'kind'='safe' AND (a->>'branch_id')::uuid=t.id('main') AND t.audits('cash_account.renamed','vault2')=1, a::text)
FROM (SELECT public.rename_cash_account(t.id('vault2'),' Rear Safe ') a) x;
SELECT public.rename_cash_account(t.id('vault2'),'Rear Safe');
SELECT t.expect('rename: the same name again writes no audit row',t.audits('cash_account.renamed','vault2')=1);
SELECT t.error('rename: to a taken name',format('SELECT public.rename_cash_account(%L,%L)',t.id('vault2'),'CIB'),'CASH_ACCOUNT_NAME_TAKEN');
SELECT t.error('rename: a drawer',format('SELECT public.rename_cash_account(%L,%L)',t.id('drawer'),'Drawer X'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.expect('list: safes and banks only, active by default, shop-wide last',
  (SELECT count(*) FROM jsonb_array_elements(l))=6 AND NOT l @> jsonb_build_array(jsonb_build_object('id',t.id('drawer')))
  AND (l->-1->>'id')::uuid=t.id('nbe'), l::text)
FROM (SELECT public.list_cash_accounts() l) x;
SELECT t.expect('list: filters by branch and kind',
  jsonb_array_length(public.list_cash_accounts('active',t.id('main'),'bank'))=1
  AND jsonb_array_length(public.list_cash_accounts('all',NULL,'bank'))=2);
SELECT t.expect('list: the default safe is marked',
  (SELECT bool_and((a->>'is_default')::boolean = ((a->>'id')::uuid IN (t.id('cash'),t.id('safe2')))) FROM jsonb_array_elements(public.list_cash_accounts()) a));
SELECT t.error('list: a bad status',$q$SELECT public.list_cash_accounts('archived')$q$,'VALIDATION_FAILED');

-- ---------------------------------------------------------------- opening balance
SELECT t.expect('opening: 5 000.00 on the empty main safe',
  a->>'balance'='5000.00' AND t.moves('cash')=1, a::text)
FROM (SELECT public.post_cash_opening(t.id('cash'),'5000.00','Counted on day one','k01-open-1') a) x;
SELECT t.expect('opening: one opening movement from one opening_cash import job',
  EXISTS(SELECT 1 FROM public.cash_movements m JOIN public.import_jobs j ON j.id=m.source_id
         WHERE m.cash_account_id=t.id('cash') AND m.type='opening' AND m.source_type='import' AND m.amount=5000
           AND j.kind='opening_cash' AND j.status='completed')
  AND (SELECT count(*) FROM public.import_jobs WHERE organization_id=t.org('a') AND kind='opening_cash')=1
  AND t.audits('cash_account.opening_balance','cash')=1);
SELECT current_user AS test4_role \gset
RESET ROLE;
\ir helpers/test4_snapshot.sql
SET ROLE :"test4_role";
SELECT t.snapshot(t.org('a'))::text AS test4_snapshot \gset
SELECT t.expect('opening: the same key changes nothing',
  public.post_cash_opening(t.id('cash'),'5000.00','Counted on day one','k01-open-1')->>'balance'='5000.00'
  AND t.moves('cash')=1 AND (SELECT count(*) FROM public.import_jobs WHERE organization_id=t.org('a') AND kind='opening_cash')=1);
SELECT t.expect('TEST4 replay snapshot 1',t.snapshot(t.org('a'))=:'test4_snapshot'::jsonb);
SELECT t.error('opening: the key used for another account',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('cib'),'1.00','Other','k01-open-1'),'VALIDATION_FAILED');
SELECT t.error('opening: a second opening',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('cash'),'10.00','Again','k01-open-2'),'CASH_ACCOUNT_HAS_MOVEMENTS');
SELECT t.error('opening: amount 0',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('cib'),'0','Zero','k01-open-3'),'VALIDATION_FAILED');
SELECT t.error('opening: 3 decimals',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('cib'),'1.005','Odd','k01-open-4'),'VALIDATION_FAILED');
SELECT t.error('opening: a short note',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('cib'),'10.00','ab','k01-open-5'),'VALIDATION_FAILED');
SELECT t.error('opening: a system key',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('cib'),'10.00','Start','system:k01'),'VALIDATION_FAILED');
SELECT t.error('opening: a drawer',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('drawer'),'10.00','Start','k01-open-6'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.expect('opening: a shop-wide bank gets its opening',
  public.post_cash_opening(t.id('nbe'),'300.00','Bank statement','k01-open-7')->>'balance'='300.00');
SELECT t.expect('opening: a shop-wide bank books in the caller''s branch', (SELECT branch_id FROM public.cash_movements WHERE cash_account_id=t.id('nbe'))=t.id('main'));

-- ---------------------------------------------------------------- Done when (transfer)
INSERT INTO t.ids SELECT 'tr1',(public.create_cash_transfer(t.id('cash'),t.id('cib'),'1200.00',' to the bank ','k01-tr-1')->>'id')::uuid;
SELECT t.expect('Done when: 1 200.00 from the safe to the bank moves both balances once',
  t.bal('cash')=3800 AND t.bal('cib')=1200 AND t.moves('cash')=2 AND t.moves('cib')=1
  AND (SELECT count(*) FROM public.cash_movements WHERE source_type='cash_transfer' AND source_id=t.id('tr1'))=2
  AND EXISTS(SELECT 1 FROM public.cash_movements WHERE source_id=t.id('tr1') AND cash_account_id=t.id('cash') AND type='transfer_out' AND amount=-1200)
  AND EXISTS(SELECT 1 FROM public.cash_movements WHERE source_id=t.id('tr1') AND cash_account_id=t.id('cib') AND type='transfer_in' AND amount=1200));
SELECT t.expect('transfer: numbered CX, note trimmed, audited once',
  x->>'number' LIKE '%-CX-%' AND x->>'note'='to the bank' AND x->>'amount'='1200.00' AND x->>'from_account_name'='الخزنة الرئيسية'
  AND x->>'to_account_name'='CIB' AND t.audits('cash_transfer.created','tr1')=1, x::text)
FROM (SELECT public.get_cash_transfer(t.id('tr1')) x) y;
SELECT t.snapshot(t.org('a'))::text AS test4_snapshot \gset
SELECT t.expect('transfer: the same key returns the same transfer, nothing new',
  (public.create_cash_transfer(t.id('cash'),t.id('cib'),'1200.00',NULL,'k01-tr-1')->>'id')::uuid=t.id('tr1')
  AND t.bal('cash')=3800 AND (SELECT count(*) FROM public.cash_transfers WHERE organization_id=t.org('a'))=1);
SELECT t.expect('TEST4 replay snapshot 2',t.snapshot(t.org('a'))=:'test4_snapshot'::jsonb);
SELECT t.error('transfer: more than the safe holds',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('cib'),'3800.01','k01-tr-2'),'INSUFFICIENT_FUNDS');
SELECT t.expect('transfer: the refused one posted nothing',
  t.bal('cash')=3800 AND (SELECT count(*) FROM public.cash_transfers WHERE organization_id=t.org('a'))=1 AND t.moves('cash')=2);
SELECT t.error('transfer: from = to',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('cash'),'1.00','k01-tr-3'),'TRANSFER_SAME_ACCOUNT');
SELECT t.error('transfer: a drawer side',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('drawer'),'1.00','k01-tr-4'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('transfer: amount 0',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('cib'),'0.00','k01-tr-5'),'VALIDATION_FAILED');
SELECT t.error('transfer: 3 decimals',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('cib'),'1.001','k01-tr-6'),'VALIDATION_FAILED');
SELECT t.error('transfer: a system key',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('cib'),'1.00','system:k01-tr'),'VALIDATION_FAILED');
SELECT public.set_cash_account_active(t.id('vault2'),false);
SELECT t.error('transfer: an inactive side',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('vault2'),'1.00','k01-tr-7'),'CASH_ACCOUNT_INACTIVE');
SELECT t.error('opening: an inactive account',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('vault2'),'1.00','Start','k01-open-8'),'CASH_ACCOUNT_INACTIVE');
INSERT INTO t.ids SELECT 'tr2',(public.create_cash_transfer(t.id('nbe'),t.id('safe2'),'100.00',NULL,'k01-tr-8')->>'id')::uuid;
SELECT t.expect('transfer: a shop-wide bank books in the other side''s branch',
  (SELECT branch_id FROM public.cash_movements WHERE source_id=t.id('tr2') AND cash_account_id=t.id('nbe'))=t.id('second')
  AND t.bal('safe2')=100 AND t.bal('nbe')=200);

-- ---------------------------------------------------------------- Done when (ledger)
SELECT t.expect('Done when: with no dates the closing balance = cash_balances = the sum; running balance right; newest first',
  l->>'closing_balance'='3800.00' AND l->>'opening_balance'='0.00' AND (l->>'total')::int=2
  AND l->'items'->0->>'type'='transfer_out' AND l->'items'->0->>'balance_after'='3800.00'
  AND l->'items'->0->>'source_number' LIKE '%-CX-%' AND l->'items'->1->>'type'='opening' AND l->'items'->1->>'balance_after'='5000.00'
  AND l->'account'->>'balance'='3800.00' AND t.running_ok(l)
  AND (SELECT sum(amount) FROM public.cash_movements WHERE cash_account_id=t.id('cash'))=3800, l::text)
FROM (SELECT public.list_cash_account_movements(t.id('cash')) l) x;
RESET ROLE;
-- An older movement (as M02's migration or a past day would leave) to test dated periods.
INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,amount,type,source_type,source_id,business_date,created_at)
VALUES(t.org('a'),t.id('cib'),t.id('main'),250,'adjustment','import',gen_random_uuid(),current_date-10,now()-interval '10 days');
SET ROLE authenticated;
SELECT t.expect('ledger: with from, the opening is the sum before it; closing still the balance',
  l->>'opening_balance'='250.00' AND l->>'closing_balance'='1450.00' AND (l->>'total')::int=1 AND t.running_ok(l)
  AND t.bal('cib')=1450, l::text)
FROM (SELECT public.list_cash_account_movements(t.id('cib'),current_date-5,NULL) l) x;
SELECT t.expect('ledger: with to before today, closing = the sum up to it',
  l->>'closing_balance'='250.00' AND (l->>'total')::int=1, l::text)
FROM (SELECT public.list_cash_account_movements(t.id('cib'),NULL,current_date-5) l) x;
SELECT t.expect('ledger: paging keeps the running balance',
  (l->>'total')::int=2 AND jsonb_array_length(l->'items')=1 AND l->'items'->0->>'balance_after'='250.00', l::text)
FROM (SELECT public.list_cash_account_movements(t.id('cib'),NULL,NULL,1,1) l) x;
SELECT t.error('ledger: from after to',format('SELECT public.list_cash_account_movements(%L,%L,%L)',t.id('cib'),current_date,current_date-1),'VALIDATION_FAILED');
SELECT t.expect('transfers: listed by account, newest first',
  (public.list_cash_transfers(t.id('cash'))->>'total')::int=1 AND (public.list_cash_transfers()->>'total')::int=2
  AND (public.list_cash_transfers()->'items'->0->>'id')::uuid=t.id('tr2'));

-- ---------------------------------------------------------------- deactivate / reactivate
SELECT t.error('deactivate: with a balance',format('SELECT public.set_cash_account_active(%L,false)',t.id('cib')),'CASH_ACCOUNT_HAS_BALANCE');
SELECT t.error('deactivate: the second branch''s safe holds 100',format('SELECT public.set_cash_account_active(%L,false)',t.id('safe2')),'CASH_ACCOUNT_HAS_BALANCE');
SELECT t.expect('deactivate: allowed at 0 (done above), listed as inactive, still readable',
  public.get_cash_account(t.id('vault2'))->>'is_active'='false' AND public.get_cash_account(t.id('vault2'))->'archived_at'<>'null'::jsonb
  AND jsonb_array_length(public.list_cash_accounts('inactive'))=1 AND t.audits('cash_account.deactivated','vault2')=1);
SELECT public.set_cash_account_active(t.id('vault2'),false);
SELECT t.expect('deactivate: the same state again writes no audit row',t.audits('cash_account.deactivated','vault2')=1);
SELECT t.expect('reactivate: back to active, audited',
  public.set_cash_account_active(t.id('vault2'),true)->>'is_active'='true' AND t.audits('cash_account.reactivated','vault2')=1);
SELECT t.error('create: an inactive account''s name stays taken (the baseline key covers all)',
  format('SELECT public.set_cash_account_active(%L,false)',t.id('vault2'))||format(';SELECT public.create_cash_account(%L,%L,%L)','Rear Safe','safe',t.id('main')),'CASH_ACCOUNT_NAME_TAKEN');
SELECT public.set_cash_account_active(t.id('vault2'),true);
INSERT INTO t.ids SELECT 'empty2',(public.create_cash_account('Spare','safe',t.id('second'))->>'id')::uuid;
SELECT t.expect('setup: an empty non-default safe in the second branch',t.bal('empty2')=0);
RESET ROLE;
-- The default-vault rule with an empty default: second's default moves to an emptied safe.
UPDATE public.branches SET default_cash_account_id=t.id('empty2') WHERE id=t.id('second');
SET ROLE authenticated;
SELECT t.error('deactivate: a branch''s default vault (empty)',format('SELECT public.set_cash_account_active(%L,false)',t.id('empty2')),'CASH_ACCOUNT_IS_DEFAULT');
RESET ROLE;
UPDATE public.branches SET default_cash_account_id=t.id('safe2') WHERE id=t.id('second');

-- ---------------------------------------------------------------- who
SELECT t.as_user('a5900000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('accountant: reads its branch and shop-wide banks',
  (SELECT count(*) FROM jsonb_array_elements(public.list_cash_accounts()))=4
  AND (public.get_cash_account(t.id('nbe'))->>'id')::uuid=t.id('nbe'));
SELECT t.expect('accountant: transfers',
  public.create_cash_transfer(t.id('cib'),t.id('cash'),'50.00',NULL,'k01-acc-1')->>'amount'='50.00' AND t.bal('cash')=3850);
SELECT t.error('accountant: can''t create',format('SELECT public.create_cash_account(%L,%L,%L)','Acc','safe',t.id('main')),'PERMISSION_DENIED');
SELECT t.error('accountant: can''t post an opening',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('vault2'),'1.00','Start','k01-acc-2'),'PERMISSION_DENIED');
SELECT t.error('accountant: can''t see the second branch''s safe',format('SELECT public.get_cash_account(%L)',t.id('safe2')),'CASH_ACCOUNT_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a5900000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('manager of second: can''t move money out of main''s safe',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('safe2'),'1.00','k01-man-1'),'BRANCH_DENIED');
SELECT t.expect('manager of second: sees its safes and the shop-wide bank, not main''s',
  l @> jsonb_build_array(jsonb_build_object('id',t.id('nbe'))) AND l @> jsonb_build_array(jsonb_build_object('id',t.id('safe2')))
  AND NOT l @> jsonb_build_array(jsonb_build_object('id',t.id('cash'))), l::text)
FROM (SELECT public.list_cash_accounts() l) x;
SELECT t.expect('manager of second: moves money out of its safe into main''s',
  public.create_cash_transfer(t.id('safe2'),t.id('cash'),'10.00',NULL,'k01-man-2')->>'amount'='10.00');
SELECT t.error('manager of second: main''s ledger is not found',format('SELECT public.list_cash_account_movements(%L)',t.id('cash')),'CASH_ACCOUNT_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a5900000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('cashier: no cash.view, no list',$q$SELECT public.list_cash_accounts()$q$,'PERMISSION_DENIED');
SELECT t.error('cashier: no transfers list',$q$SELECT public.list_cash_transfers()$q$,'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a5900000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.error('not an employee: no list',$q$SELECT public.list_cash_accounts()$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;

-- ---------------------------------------------------------------- tenancy and grants
SELECT t.as_user('a5900000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: get a''s account',format('SELECT public.get_cash_account(%L)',t.id('cash')),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: a''s ledger',format('SELECT public.list_cash_account_movements(%L)',t.id('cash')),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: a''s transfers by account',format('SELECT public.list_cash_transfers(%L)',t.id('cash')),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: a''s transfer',format('SELECT public.get_cash_transfer(%L)',t.id('tr1')),'CASH_TRANSFER_NOT_FOUND');
SELECT t.error('shop b: rename a''s account',format('SELECT public.rename_cash_account(%L,%L)',t.id('cib'),'B'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: deactivate a''s account',format('SELECT public.set_cash_account_active(%L,false)',t.id('vault2')),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: an opening on a''s account',format('SELECT public.post_cash_opening(%L,%L,%L,%L)',t.id('vault2'),'1.00','Start','k01-shopb-1'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: a''s account as the destination',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash_b'),t.id('cash'),'1.00','k01-shopb-2'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: a''s account as the source',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('cash_b'),'1.00','k01-shopb-3'),'CASH_ACCOUNT_NOT_FOUND');
SELECT t.error('shop b: a''s branch for a new safe',format('SELECT public.create_cash_account(%L,%L,%L)','X','safe',t.id('main')),'BRANCH_NOT_FOUND');
SELECT t.expect('shop b: lists only its own accounts and no transfers',
  jsonb_array_length(public.list_cash_accounts('all'))=1 AND (public.list_cash_transfers()->>'total')::int=0);
SELECT t.error('no direct writes',format('INSERT INTO public.cash_accounts(organization_id,name,kind) VALUES(%L,%L,%L)',t.org('b'),'Direct','bank'),'permission denied for table cash_accounts');
SELECT t.error('no direct movements',format('INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,amount,type,source_type,source_id,business_date) VALUES(%L,%L,%L,1,%L,%L,%L,current_date)',t.org('b'),t.id('cash_b'),t.id('main'),'opening','import',gen_random_uuid()),'permission denied for table cash_movements');
RESET ROLE;
SELECT t.expect('shop b''s refused calls wrote nothing in a',
  NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('b') AND action LIKE 'cash%')
  AND t.bal('cash_b')=0);
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));

-- ---------------------------------------------------------------- expired shop, closed day
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a5900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired shop: accounts and ledgers still read',
  jsonb_array_length(public.list_cash_accounts())>0 AND (public.list_cash_account_movements(t.id('cash'))->>'total')::int>0);
SELECT t.error('expired shop: no transfer',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('cib'),'1.00','k01-exp-1'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no new account',$q$SELECT public.create_cash_account('Late','bank',NULL)$q$,'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
INSERT INTO public.day_closes(organization_id,branch_id,business_date,closed_by)
SELECT t.org('a'),t.id('second'),app.org_today(t.org('a')),e.id FROM public.employees e WHERE e.organization_id=t.org('a') AND e.role='OWNER';
SET ROLE authenticated;
SELECT t.error('closed day: no transfer out of the closed branch',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('safe2'),t.id('cash'),'1.00','k01-day-1'),'DAY_CLOSED');
SELECT t.error('closed day: no transfer into it either',format('SELECT public.create_cash_transfer(%L,%L,%L,NULL,%L)',t.id('cash'),t.id('safe2'),'1.00','k01-day-2'),'DAY_CLOSED');
RESET ROLE;
SELECT t.expect('closed day: nothing posted',
  (SELECT count(*) FROM public.cash_transfers WHERE idempotency_key LIKE 'k01-day-%')=0);

SELECT t.expect('no anon grants, authenticated runs the ten functions, not the helpers',
  NOT has_function_privilege('anon','public.create_cash_transfer(uuid,uuid,text,text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.list_cash_accounts(text,uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.create_cash_account(text,text,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.rename_cash_account(uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_cash_account_active(uuid,boolean)','EXECUTE')
  AND has_function_privilege('authenticated','public.post_cash_opening(uuid,text,text,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.create_cash_transfer(uuid,uuid,text,text,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_cash_accounts(text,uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_cash_account(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_cash_account_movements(uuid,date,date,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_cash_transfers(uuid,date,date,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_cash_transfer(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.cash_account_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.cash_account_for_write(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.cash_account_for_read(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.cash_transfer_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.cash_fallback_branch(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.require_cash_view()','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
