\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request. t.open_shift puts a free device of the
-- branch in the request headers (x-device-id, as the API does once it has resolved a device
-- token) and then calls public.open_shift unchanged.
CREATE FUNCTION t.pos(p_branch uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_org uuid := app.current_org_id(); v_id uuid;
BEGIN
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch AND b.organization_id = v_org) THEN
    RETURN NULL;
  END IF;
  SELECT d.id INTO v_id FROM public.devices d
  WHERE d.organization_id = v_org AND d.branch_id = p_branch AND d.is_active AND d.archived_at IS NULL AND d.name LIKE 'Test POS %'
    AND NOT EXISTS (SELECT 1 FROM public.shifts s WHERE s.device_id = d.id AND s.status = 'open')
  ORDER BY d.name LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO public.devices (organization_id, branch_id, name) VALUES (v_org, p_branch, 'Test POS ' || gen_random_uuid())
    RETURNING id INTO v_id;
  END IF;
  PERFORM set_config('request.headers',
    (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb || jsonb_build_object('x-device-id', v_id))::text, false);
  RETURN v_id;
END $$;
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text, p_vault uuid DEFAULT NULL, p_device uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  -- A named device is the one "paired" for this call; otherwise any free device of the branch.
  IF p_device IS NOT NULL THEN
    PERFORM set_config('request.headers',
      (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb || jsonb_build_object('x-device-id', p_device))::text, false);
  ELSE
    PERFORM t.pos(p_branch);
  END IF;
  RETURN public.open_shift(p_branch, p_float, p_key, p_vault, p_device);
END $$;
GRANT EXECUTE ON FUNCTION t.pos(uuid), t.open_shift(uuid, text, text, uuid, uuid) TO authenticated;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- (SECURITY DEFINER: not every role of this test reads the audit log, the balances or app.*.)
CREATE FUNCTION t.audits(a text,i text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(i) $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.expected(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.shift_json((SELECT organization_id FROM public.shifts WHERE id=t.id(s)),t.id(s),false)->>'expected_cash' $$;
CREATE FUNCTION t.count() RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT count(*) FROM public.expenses WHERE organization_id IN (SELECT (result->>'organization_id')::uuid FROM t.shops) $$;
-- A vault expense call as SQL text, for t.error.
CREATE FUNCTION t.call(cat text,amount text,acc text DEFAULT 'safe',branch text DEFAULT 'main') RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_expense(%L,%L,%L,%L,%L)',t.id(cat),amount,'k03-'||md5(random()::text),t.id(branch),t.id(acc)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a, shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('K03 '||s,'k03-'||s,'retail','Owner',s||'k03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('p',64)),('b',repeat('q',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a6030000-0000-0000-8000-000000000001','ak03@example.com'),('a6030000-0000-0000-8000-000000000002','bk03@example.com'),
  ('a6030000-0000-0000-8000-000000000003','k03accountant@example.com'),('a6030000-0000-0000-8000-000000000004','k03manager@example.com'),
  ('a6030000-0000-0000-8000-000000000005','k03cashier@example.com'),('a6030000-0000-0000-8000-000000000006','k03manager2@example.com');
SELECT public.accept_invite(repeat('p',64),'a6030000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a6030000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'safe_b',default_cash_account_id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a6030000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','K3',NULL,NULL,NULL,NULL,NULL));
SELECT public.post_cash_opening(t.id('safe'),'5000.00','Counted on day one','k03-opening');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
SELECT public.create_cash_transfer(t.id('safe'),t.id('bank'),'1000.00','','k03-fund-bank');
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
INSERT INTO t.ids SELECT 'spare',(public.create_cash_account('Spare','safe',t.id('main'))->>'id')::uuid;
SELECT public.set_cash_account_active(t.id('spare'),false);
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('acc','a6030000-0000-0000-8000-000000000003','K03 Accountant','ACCOUNTANT','main');
SELECT t.emp('mgr','a6030000-0000-0000-8000-000000000004','K03 Manager','BRANCH_MANAGER','main');
SELECT t.emp('cashier','a6030000-0000-0000-8000-000000000005','K03 Cashier','CASHIER','main');
SELECT t.emp('mgr2','a6030000-0000-0000-8000-000000000006','K03 Manager Two','BRANCH_MANAGER','second');
-- A receipt photo and a file of another purpose (F14 registers them through the API).
INSERT INTO public.files(id,organization_id,bucket,path,mime,size_bytes,purpose)
VALUES('a6030000-0000-0000-8000-0000000000f1',t.org('a'),'tenant-files',t.org('a')::text||'/receipts/r1.jpg','image/jpeg',10,'expense_receipt'),
      ('a6030000-0000-0000-8000-0000000000f2',t.org('a'),'tenant-files',t.org('a')::text||'/logo.png','image/png',10,'logo'),
      ('a6030000-0000-0000-8000-0000000000f3',t.org('b'),'tenant-files',t.org('b')::text||'/receipts/r1.jpg','image/jpeg',10,'expense_receipt');
INSERT INTO t.ids VALUES('receipt','a6030000-0000-0000-8000-0000000000f1'),('logo','a6030000-0000-0000-8000-0000000000f2'),('receipt_b','a6030000-0000-0000-8000-0000000000f3');

-- ---------------------------------------------------------------- categories
SELECT t.as_user('a6030000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'rent',(public.create_expense_category('  Rent ')->>'id')::uuid;
INSERT INTO t.ids SELECT 'transport',(public.create_expense_category('Transport')->>'id')::uuid;
INSERT INTO t.ids SELECT 'old',(public.create_expense_category('Old category')->>'id')::uuid;
SELECT t.expect('categories: created with a trimmed name, audited, listed by name',
  (SELECT array_agg(x->>'name') FROM jsonb_array_elements(public.list_expense_categories()) x)=ARRAY['Old category','Rent','Transport']
  AND t.audits('expense_category.created','rent')=1);
SELECT t.error('categories: the same name',$$SELECT public.create_expense_category('Rent')$$,'EXPENSE_CATEGORY_NAME_TAKEN');
SELECT t.error('categories: a blank name',$$SELECT public.create_expense_category('  ')$$,'VALIDATION_FAILED');
SELECT t.error('categories: 81 characters',format('SELECT public.create_expense_category(%L)',repeat('x',81)),'VALIDATION_FAILED');
SELECT t.expect('categories: renamed, audited once; the same name again writes nothing',
  public.rename_expense_category(t.id('transport'),' Transport and delivery ')->>'name'='Transport and delivery'
  AND public.rename_expense_category(t.id('transport'),'Transport and delivery')->>'name'='Transport and delivery'
  AND t.audits('expense_category.renamed','transport')=1);
SELECT t.error('categories: renamed to a taken name',format('SELECT public.rename_expense_category(%L,%L)',t.id('transport'),'Rent'),'EXPENSE_CATEGORY_NAME_TAKEN');
SELECT t.expect('categories: archived, twice changes nothing',
  public.set_expense_category_archived(t.id('old'),true)->>'archived_at' IS NOT NULL
  AND public.set_expense_category_archived(t.id('old'),true)->>'archived_at' IS NOT NULL);
SELECT t.expect('categories: an archived one is audited once and hidden unless asked',
  t.audits('expense_category.archived','old')=1
  AND jsonb_array_length(public.list_expense_categories())=2 AND jsonb_array_length(public.list_expense_categories(true))=3);
SELECT t.error('categories: an unknown one',format('SELECT public.rename_expense_category(%L,%L)',gen_random_uuid(),'X'),'EXPENSE_CATEGORY_NOT_FOUND');

-- ---------------------------------------------------------------- Done when: an expense lowers the vault
INSERT INTO t.ids SELECT 'e1',(public.post_expense(t.id('rent'),'1200.00','k03-e1-key',t.id('main'),t.id('safe'),false,'  October rent ',t.id('receipt'))->>'id')::uuid;
RESET ROLE;
SELECT t.expect('Done when: 1 200 of rent leaves the safe: numbered EX, one expense movement on the shop day',
  x->>'number' LIKE '%-EX-%' AND x->>'amount'='1200.00' AND x->>'category_name'='Rent' AND x->>'note'='October rent'
  AND (x->>'receipt_file_id')::uuid=t.id('receipt') AND x->>'cash_account_kind'='safe' AND x->>'shift_id' IS NULL
  AND x->>'reversed_by_expense_id' IS NULL AND x->>'created_by_name'='K03 Accountant'
  AND t.cash('safe')=2800
  AND (SELECT count(*)=1 AND bool_and(amount=-1200 AND type='expense' AND business_date=app.org_today(t.org('a')) AND branch_id=t.id('main'))
       FROM public.cash_movements WHERE source_type='expense' AND source_id=t.id('e1'))
  AND (x->>'business_date')::date=app.org_today(t.org('a')) AND t.audits('expense.posted','e1')=1, x::text)
FROM (SELECT app.expense_json(t.org('a'),t.id('e1')) x) y;
SELECT t.as_user('a6030000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('idempotent: the same key again -> the same expense, nothing spent twice',
  (public.post_expense(t.id('rent'),'1200.00','k03-e1-key',t.id('main'),t.id('safe'))->>'id')::uuid=t.id('e1')
  AND t.cash('safe')=2800 AND t.count()=1);
INSERT INTO t.ids SELECT 'e2',(public.post_expense(t.id('transport'),'150.50','k03-e2-key',t.id('main'),t.id('bank'))->>'id')::uuid;
SELECT t.expect('a shop-wide bank pays, booked in the expense''s branch',
  t.cash('bank')=849.50 AND (SELECT branch_id FROM public.cash_movements WHERE source_id=t.id('e2'))=t.id('main'));
SELECT t.error('input: amount 0',t.call('rent','0.00'),'VALIDATION_FAILED');
SELECT t.error('input: three decimals',t.call('rent','1.234'),'VALIDATION_FAILED');
SELECT t.error('input: an archived category',t.call('old','10.00'),'EXPENSE_CATEGORY_ARCHIVED');
SELECT t.error('input: an unknown category',format('SELECT public.post_expense(%L,%L,%L,%L,%L)',gen_random_uuid(),'10.00','k03-unknown-cat',t.id('main'),t.id('safe')),'EXPENSE_CATEGORY_NOT_FOUND');
SELECT t.error('input: no source',format('SELECT public.post_expense(%L,%L,%L,%L)',t.id('rent'),'10.00','k03-no-source',t.id('main')),'VALIDATION_FAILED');
SELECT t.error('input: a vault and the shift',format('SELECT public.post_expense(%L,%L,%L,%L,%L,true)',t.id('rent'),'10.00','k03-both',t.id('main'),t.id('safe')),'VALIDATION_FAILED');
SELECT t.error('input: a note over 500 characters',format('SELECT public.post_expense(%L,%L,%L,%L,%L,false,%L)',t.id('rent'),'10.00','k03-long-note',t.id('main'),t.id('safe'),repeat('x',501)),'VALIDATION_FAILED');
SELECT t.error('input: a file that is not a receipt',format('SELECT public.post_expense(%L,%L,%L,%L,%L,false,NULL,%L)',t.id('rent'),'10.00','k03-logo',t.id('main'),t.id('safe'),t.id('logo')),'FILE_NOT_FOUND');
SELECT t.error('input: another shop''s receipt',format('SELECT public.post_expense(%L,%L,%L,%L,%L,false,NULL,%L)',t.id('rent'),'10.00','k03-receipt-b',t.id('main'),t.id('safe'),t.id('receipt_b')),'FILE_NOT_FOUND');
SELECT t.error('input: a system key',format('SELECT public.post_expense(%L,%L,%L,%L,%L)',t.id('rent'),'10.00','system:k03',t.id('main'),t.id('safe')),'VALIDATION_FAILED');
SELECT t.error('funds: more than the safe holds',t.call('rent','2800.01'),'INSUFFICIENT_FUNDS');
SELECT t.error('account: an inactive safe',t.call('rent','10.00','spare'),'CASH_ACCOUNT_INACTIVE');
SELECT t.error('account: another branch''s safe',t.call('rent','10.00','safe2'),'VAULT_INVALID');
SELECT t.error('account: another shop''s safe',t.call('rent','10.00','safe_b'),'VAULT_INVALID');
SELECT t.error('account: a branch the accountant doesn''t work in',t.call('rent','10.00','safe2','second'),'BRANCH_DENIED');
SELECT t.error('shift: no open shift to pay from',format('SELECT public.post_expense(%L,%L,%L,NULL,NULL,true)',t.id('rent'),'10.00','k03-no-shift'),'SHIFT_REQUIRED');
SELECT t.expect('refused calls spent nothing',t.count()=2 AND t.cash('safe')=2800 AND t.cash('bank')=849.50);
RESET ROLE;

-- ---------------------------------------------------------------- Done when: an expense lowers the drawer (current shift)
SELECT t.as_user('a6030000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('shift: a manager with no open shift',format('SELECT public.post_expense(%L,%L,%L,NULL,NULL,true)',t.id('rent'),'10.00','k03-mgr-no-shift'),'SHIFT_REQUIRED');
INSERT INTO t.ids SELECT 's1',(t.open_shift(t.id('main'),'300.00','k03-shift-1',t.id('safe'))->>'id')::uuid;
INSERT INTO t.ids SELECT 'e3',(public.post_expense(t.id('transport'),'40.00','k03-e3-key',NULL,NULL,true,'Courier')->>'id')::uuid;
SELECT t.expect('Done when: 40 from the open shift lowers the drawer and the shift''s expected cash',
  x->>'cash_account_kind'='drawer' AND (x->>'shift_id')::uuid=t.id('s1') AND x->>'shift_number' LIKE '%-SH-%'
  AND (x->>'branch_id')::uuid=t.id('main') AND t.expected('s1')='260.00' AND t.cash('safe')=2500, x::text)
FROM (SELECT public.get_expense(t.id('e3')) x) y;
SELECT t.error('shift: more than the drawer holds',format('SELECT public.post_expense(%L,%L,%L,NULL,NULL,true)',t.id('rent'),'260.01','k03-drawer-big'),'INSUFFICIENT_FUNDS');
SELECT t.error('who: a manager can''t reverse',format('SELECT public.reverse_expense(%L,%L,%L)',t.id('e3'),'Not the owner','k03-mgr-rev'),'APPROVAL_OWNER_ONLY');
RESET ROLE;

-- ---------------------------------------------------------------- reversal
SELECT t.as_user('a6030000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'r3',(public.reverse_expense(t.id('e3'),'  Paid twice ','k03-r3-key')->>'id')::uuid;
SELECT t.expect('reversal (shift still open): the money is back in the drawer and the shift expects 300 again',
  t.expected('s1')='300.00' AND (r->>'reverses_expense_id')::uuid=t.id('e3') AND (r->>'shift_id')::uuid=t.id('s1')
  AND r->>'note'='Paid twice' AND r->>'number'<>x->>'number' AND (x->>'reversed_by_expense_id')::uuid=t.id('r3'), r::text)
FROM (SELECT public.get_expense(t.id('r3')) r,public.get_expense(t.id('e3')) x) y;
SELECT t.expect('reversal: the same key again -> the same reversal',
  (public.reverse_expense(t.id('e3'),'Paid twice','k03-r3-key')->>'id')::uuid=t.id('r3') AND t.expected('s1')='300.00');
SELECT t.error('reversal: again with a new key',format('SELECT public.reverse_expense(%L,%L,%L)',t.id('e3'),'Again','k03-r3-again'),'EXPENSE_ALREADY_REVERSED');
SELECT t.error('reversal: a reversal can''t be reversed',format('SELECT public.reverse_expense(%L,%L,%L)',t.id('r3'),'Undo','k03-r3-undo'),'VALIDATION_FAILED');
SELECT t.error('reversal: the key of another expense',format('SELECT public.reverse_expense(%L,%L,%L)',t.id('e1'),'Wrong key','k03-r3-key'),'IDEMPOTENCY_CONFLICT');
SELECT t.error('reversal: a short reason',format('SELECT public.reverse_expense(%L,%L,%L)',t.id('e1'),'no','k03-r-short'),'VALIDATION_FAILED');
SELECT t.error('reversal: an unknown expense',format('SELECT public.reverse_expense(%L,%L,%L)',gen_random_uuid(),'Unknown','k03-r-unknown'),'EXPENSE_NOT_FOUND');
SELECT t.error('reversal: a vault expense goes back to its own account',format('SELECT public.reverse_expense(%L,%L,%L,%L)',t.id('e1'),'Other account','k03-r-other',t.id('bank')),'VALIDATION_FAILED');
INSERT INTO t.ids SELECT 'r1',(public.reverse_expense(t.id('e1'),'Rent was paid by transfer','k03-r1-key')->>'id')::uuid;
RESET ROLE;
SELECT t.expect('reversal (vault): the safe is back up by 1 200, the movement is linked, audited as a warning',
  t.cash('safe')=3700
  AND (SELECT amount=1200 AND reverses_movement_id=(SELECT id FROM public.cash_movements WHERE source_id=t.id('e1')) FROM public.cash_movements WHERE source_id=t.id('r1'))
  AND (SELECT count(*)=1 AND bool_and(severity='warning' AND reason='Rent was paid by transfer') FROM public.audit_log WHERE action='expense.reversed' AND entity_id=t.id('e1')));
-- An expense from a shift that is closed by the time it is reversed.
SELECT t.as_user('a6030000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'e4',(public.post_expense(t.id('transport'),'60.00','k03-e4-key',NULL,NULL,true)->>'id')::uuid;
SELECT public.close_shift(t.id('s1'),'{"200":1,"20":2}',t.id('safe'));
RESET ROLE;
SELECT t.as_user('a6030000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('reversal (closed shift): the vault the money goes back to is needed',format('SELECT public.reverse_expense(%L,%L,%L)',t.id('e4'),'Courier refunded','k03-r4-none'),'VAULT_INVALID');
SELECT t.error('reversal (closed shift): another branch''s safe',format('SELECT public.reverse_expense(%L,%L,%L,%L)',t.id('e4'),'Courier refunded','k03-r4-bad',t.id('safe2')),'VAULT_INVALID');
SELECT t.expect('reversal (closed shift): into the safe, not the closed shift''s drawer',
  r->>'cash_account_kind'='safe' AND r->>'shift_id' IS NULL AND t.cash('safe')=3700+240+60, r::text)
FROM (SELECT public.reverse_expense(t.id('e4'),'Courier refunded','k03-r4-key',t.id('safe')) r) y;

-- ---------------------------------------------------------------- list and report
INSERT INTO t.ids SELECT 'e5',(public.post_expense(t.id('rent'),'500.00','k03-e5-key',t.id('main'),t.id('safe'))->>'id')::uuid;
SELECT t.expect('list: every row of the caller''s branches; filters by category, branch and day; without reversals only what counts',
  (public.list_expenses()->>'total')::int=8
  AND (public.list_expenses(NULL,t.id('rent'))->>'total')::int=3
  AND (public.list_expenses(t.id('second'))->>'total')::int=0
  AND (public.list_expenses(t.id('main'),NULL,current_date-1,current_date+1,true,3,1)->>'total')::int=8
  AND jsonb_array_length(public.list_expenses(t.id('main'),NULL,current_date-1,current_date+1,true,3,1)->'items')=3
  AND (public.list_expenses(NULL,NULL,current_date+2)->>'total')::int=0
  AND (public.list_expenses(NULL,NULL,NULL,NULL,false)->>'total')::int=2);
SELECT t.error('list: from after to',format('SELECT public.list_expenses(NULL,NULL,%L,%L)',current_date,current_date-1),'VALIDATION_FAILED');
SELECT t.error('list: an unknown category',format('SELECT public.list_expenses(NULL,%L)',gen_random_uuid()),'EXPENSE_CATEGORY_NOT_FOUND');
SELECT t.expect('report: per category, reversed expenses left out, biggest first, with the total',
  r->'items'=jsonb_build_array(
    jsonb_build_object('category_id',t.id('rent'),'category_name','Rent','count',1,'total','500.00'),
    jsonb_build_object('category_id',t.id('transport'),'category_name','Transport and delivery','count',1,'total','150.50'))
  AND r->>'total'='650.50' AND (r->>'count')::int=2, r::text)
FROM (SELECT public.expense_report(current_date-1,current_date+1) r) y;
SELECT t.expect('report: one branch; an empty period',
  public.expense_report(current_date-1,current_date+1,t.id('second'))->>'total'='0.00'
  AND public.expense_report(current_date-30,current_date-20)->'items'='[]'::jsonb);
SELECT t.error('report: from after to',format('SELECT public.expense_report(%L,%L)',current_date,current_date-1),'VALIDATION_FAILED');
SELECT t.error('report: more than a year',format('SELECT public.expense_report(%L,%L)',current_date-400,current_date),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('the safe adds up: 5 000 - 1 000 - 1 200 - 300 + 1 200 + 240 + 60 - 500',t.cash('safe')=3500,t.cash('safe')::text);

-- ---------------------------------------------------------------- roles
SELECT t.as_user('a6030000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: a CASHIER can''t record an expense',t.call('rent','1.00'),'PERMISSION_DENIED');
SELECT t.error('who: a CASHIER can''t list expenses',$$SELECT public.list_expenses()$$,'PERMISSION_DENIED');
SELECT t.error('who: a CASHIER can''t list categories',$$SELECT public.list_expense_categories()$$,'PERMISSION_DENIED');
SELECT t.error('who: a CASHIER can''t add a category',$$SELECT public.create_expense_category('Tips')$$,'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a6030000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: another branch''s manager can''t read main''s expense',format('SELECT public.get_expense(%L)',t.id('e1')),'EXPENSE_NOT_FOUND');
SELECT t.expect('who: another branch''s manager lists none of main''s expenses and reports 0',
  (public.list_expenses()->>'total')::int=0 AND public.expense_report(current_date-1,current_date+1)->>'total'='0.00');
SELECT t.error('who: another branch''s manager can''t filter by main',format('SELECT public.list_expenses(%L)',t.id('main')),'BRANCH_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- tenancy, ledger, expired shop, grants
SELECT t.as_user('a6030000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: a''s expense',format('SELECT public.get_expense(%L)',t.id('e1')),'EXPENSE_NOT_FOUND');
SELECT t.error('shop b: reversing a''s expense',format('SELECT public.reverse_expense(%L,%L,%L)',t.id('e5'),'Not mine','k03-b-rev'),'EXPENSE_NOT_FOUND');
SELECT t.error('shop b: a''s category',format('SELECT public.post_expense(%L,%L,%L,%L,%L)',t.id('rent'),'1.00','k03-b-cat',t.id('main_b'),t.id('safe_b')),'EXPENSE_CATEGORY_NOT_FOUND');
SELECT t.error('shop b: renaming a''s category',format('SELECT public.rename_expense_category(%L,%L)',t.id('rent'),'Mine'),'EXPENSE_CATEGORY_NOT_FOUND');
SELECT t.expect('shop b: lists no expenses and no categories',(public.list_expenses()->>'total')::int=0 AND public.list_expense_categories(true)='[]'::jsonb);
SELECT t.expect('shop b: the same category name is free in another shop',public.create_expense_category('Rent')->>'name'='Rent');
SELECT t.error('no direct writes',format('INSERT INTO public.expenses(organization_id,number,branch_id,category_id,amount,cash_account_id,business_date,idempotency_key) VALUES(%L,%L,%L,%L,1,%L,current_date,%L)',t.org('b'),'X',t.id('main_b'),t.id('rent'),t.id('safe_b'),'k03-direct'),'permission denied for table expenses');
RESET ROLE;
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a6030000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired shop: expenses, categories and the report still read',
  (public.list_expenses()->>'total')::int=8 AND jsonb_array_length(public.list_expense_categories())=2
  AND public.expense_report(current_date-1,current_date+1)->>'total'='650.50');
SELECT t.error('expired shop: no new expense',t.call('rent','1.00'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no new category',$$SELECT public.create_expense_category('Late')$$,'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('grants: the nine functions for authenticated, helpers not',
  has_function_privilege('authenticated','public.post_expense(uuid,text,text,uuid,uuid,boolean,text,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.reverse_expense(uuid,text,text,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_expenses(uuid,uuid,date,date,boolean,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_expense(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.expense_report(date,date,uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_expense_categories(boolean)','EXECUTE')
  AND has_function_privilege('authenticated','public.create_expense_category(text)','EXECUTE')
  AND has_function_privilege('authenticated','public.rename_expense_category(uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_expense_category_archived(uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_expense(uuid,text,text,uuid,uuid,boolean,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.expense_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.require_expense_read()','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
