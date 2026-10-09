\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- Like t.error, and also the error detail (PAYMENT_EXCEEDS_OUTSTANDING's outstanding).
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.audits(a text,i text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(i) $$;
CREATE FUNCTION t.bal(s text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT balance FROM public.v_supplier_balances WHERE supplier_id=t.id(s)),0) $$;
CREATE FUNCTION t.owed(i text) RETURNS numeric LANGUAGE sql AS $$ SELECT outstanding FROM public.v_purchase_invoice_balances WHERE purchase_invoice_id=t.id(i) $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.moves() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.cash_movements WHERE source_type='supplier_payment' $$;
CREATE FUNCTION t.al(i text,a text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('purchase_invoice_id',t.id(i),'amount',a) $$;
-- An invoice of a supplier in main for `qty` TVs at 100.00 + 14%, `days` days old, as the current user.
CREATE FUNCTION t.pi(tag text,sup text,qty integer,days integer,approve boolean DEFAULT true) RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN
  j := public.create_purchase_invoice(t.id(sup),t.id('main'),NULL,current_date-days,
    jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',qty,'unit_cost','100.00')),'u03-pi-'||tag);
  INSERT INTO t.ids VALUES(tag,(j->>'id')::uuid);
  IF approve THEN PERFORM public.approve_purchase_invoice(t.id(tag)); END IF; END $$;
-- A payment call as SQL text, for t.error.
CREATE FUNCTION t.call(sup text,amount text,allocs jsonb DEFAULT NULL,acc text DEFAULT 'safe',branch text DEFAULT 'main') RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_supplier_payment(%L,%L,%L,%L,%L,NULL,%L)',t.id(sup),t.id(branch),t.id(acc),amount,'u03-'||md5(random()::text),allocs) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a, shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('U03 '||s,'u03-'||s,'retail','Owner',s||'u03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('p',64)),('b',repeat('q',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a3030000-0000-0000-8000-000000000001','au03@example.com'),('a3030000-0000-0000-8000-000000000002','bu03@example.com'),
  ('a3030000-0000-0000-8000-000000000003','u03warehouse@example.com'),('a3030000-0000-0000-8000-000000000004','u03manager@example.com'),
  ('a3030000-0000-0000-8000-000000000005','u03accountant@example.com');
SELECT public.accept_invite(repeat('p',64),'a3030000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a3030000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'safe_b',default_cash_account_id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a3030000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','U3',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","sku":"U03-TV","cash_price":"200"}'));
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders","payment_terms_days":7}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'delta',(public.create_supplier('{"name":"Delta Supplies"}')->>'id')::uuid;
SELECT t.pi('a','nile',100,10);            -- 11 400.00, the older one
SELECT t.pi('b','nile',50,5);              --  5 700.00
SELECT t.pi('c','delta',10,1);             --  1 140.00, another supplier
SELECT t.pi('big','delta',500,1);          -- 57 000.00, more than the safe holds
SELECT t.pi('draft','nile',1,1,false);
SELECT public.post_cash_opening(t.id('safe'),'50000.00','Counted on day one','u03-opening');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
INSERT INTO t.ids SELECT 'spare',(public.create_cash_account('Spare','safe',t.id('main'))->>'id')::uuid;
SELECT public.set_cash_account_active(t.id('spare'),false);
RESET ROLE;
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a3030000-0000-0000-8000-000000000003','U03 Warehouse','WAREHOUSE',t.id('main')) RETURNING id AS warehouse_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'warehouse_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a3030000-0000-0000-8000-000000000004','U03 Manager','BRANCH_MANAGER',t.id('second')) RETURNING id AS manager_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'manager_id',t.id('second'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a3030000-0000-0000-8000-000000000005','U03 Accountant','ACCOUNTANT',t.id('main')) RETURNING id AS accountant_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'accountant_id',t.id('main'));
SELECT t.expect('setup: the safe holds 50 000, Nile is owed 11 400 + 5 700',
  t.cash('safe')=50000 AND t.bal('nile')=17100 AND t.owed('a')=11400 AND t.owed('b')=5700, t.bal('nile')::text);

-- ---------------------------------------------------------------- Done when (double click)
SELECT t.as_user('a3030000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'p1',(public.post_supplier_payment(t.id('nile'),t.id('main'),t.id('safe'),'3000.00','u03-p1-key',
  '  TRX-1 ',jsonb_build_array(t.al('a','3000.00')))->>'id')::uuid;
SELECT t.expect('Done when: 3 000 to A -> A owed 8 400, Nile 14 100, the safe 47 000, one movement',
  t.owed('a')=8400 AND t.bal('nile')=14100 AND t.cash('safe')=47000 AND t.moves()=1
  AND (SELECT amount=-3000 AND type='supplier_payment' AND source_id=t.id('p1') AND branch_id=t.id('main')
       FROM public.cash_movements WHERE source_type='supplier_payment'));
SELECT t.expect('Done when: numbered SP, trimmed reference, its allocation, one audit row',
  p->>'number' LIKE '%-SP-%' AND p->>'reference'='TRX-1' AND p->>'amount'='3000.00'
  AND p->>'cash_account_name' IS NOT NULL AND p->>'reversed_by_payment_id' IS NULL
  AND p->'allocations'=jsonb_build_array(jsonb_build_object('purchase_invoice_id',t.id('a'),
        'invoice_number',(SELECT number FROM public.purchase_invoices WHERE id=t.id('a')),'amount','3000.00'))
  AND t.audits('supplier_payment.posted','p1')=1, p::text)
FROM (SELECT public.get_supplier_payment(t.id('p1')) p) x;
SELECT t.expect('Done when: the same key again -> the same payment, nothing moves',
  (public.post_supplier_payment(t.id('nile'),t.id('main'),t.id('safe'),'3000.00','u03-p1-key',NULL,
     jsonb_build_array(t.al('a','3000.00')))->>'id')::uuid=t.id('p1')
  AND t.cash('safe')=47000 AND t.owed('a')=8400 AND t.bal('nile')=14100 AND t.moves()=1
  AND (SELECT count(*) FROM public.supplier_payments)=1 AND t.audits('supplier_payment.posted','p1')=1);

-- ---------------------------------------------------------------- several invoices, oldest first
INSERT INTO t.ids SELECT 'p2',(public.post_supplier_payment(t.id('nile'),t.id('main'),t.id('safe'),'10000.00','u03-p2-key')->>'id')::uuid;
SELECT t.expect('several: 10 000 with no allocations -> A 8 400 (paid off), B 1 600',
  t.owed('a')=0 AND t.owed('b')=4100 AND t.cash('safe')=37000 AND t.bal('nile')=4100
  AND (SELECT jsonb_agg(x->>'amount' ORDER BY x->>'amount' DESC) FROM jsonb_array_elements(public.get_supplier_payment(t.id('p2'))->'allocations') x)
      ='["8400.00","1600.00"]'::jsonb);

-- ---------------------------------------------------------------- overpay and bad allocations
SELECT t.error_detail('overpay: more than Nile is owed',t.call('nile','4100.01'),'PAYMENT_EXCEEDS_OUTSTANDING',
  '{"purchase_invoice_id":null,"outstanding":"4100.00"}');
SELECT t.error_detail('overpay: an allocation above its invoice',t.call('nile','4200.00',jsonb_build_array(t.al('b','4200.00'))),
  'PAYMENT_EXCEEDS_OUTSTANDING',jsonb_build_object('purchase_invoice_id',t.id('b'),'outstanding','4100.00'));
SELECT t.error_detail('overpay: a paid-off invoice takes nothing',t.call('nile','1.00',jsonb_build_array(t.al('a','1.00'))),
  'PAYMENT_EXCEEDS_OUTSTANDING',jsonb_build_object('purchase_invoice_id',t.id('a'),'outstanding','0.00'));
SELECT t.error('allocations: not adding up to the amount',t.call('nile','100.00',jsonb_build_array(t.al('b','50.00'))),'ALLOCATION_INVALID');
SELECT t.error('allocations: another supplier''s invoice',t.call('nile','100.00',jsonb_build_array(t.al('c','100.00'))),'ALLOCATION_INVALID');
SELECT t.error('allocations: a draft invoice',t.call('nile','100.00',jsonb_build_array(t.al('draft','100.00'))),'ALLOCATION_INVALID');
SELECT t.error('allocations: the same invoice twice',t.call('nile','100.00',jsonb_build_array(t.al('b','50.00'),t.al('b','50.00'))),'ALLOCATION_INVALID');
SELECT t.error('allocations: an empty list',t.call('nile','100.00','[]'),'ALLOCATION_INVALID');
SELECT t.error('allocations: an amount of 0',t.call('nile','100.00',jsonb_build_array(t.al('b','0.00'),t.al('a','100.00'))),'ALLOCATION_INVALID');
SELECT t.error('allocations: an unknown key',t.call('nile','100.00',jsonb_build_array(t.al('b','100.00')||'{"note":"x"}')),'ALLOCATION_INVALID');
SELECT t.error('input: amount 0',t.call('nile','0.00'),'VALIDATION_FAILED');
SELECT t.error('input: three decimals',t.call('nile','1.234'),'VALIDATION_FAILED');
SELECT t.error('input: a system key',format('SELECT public.post_supplier_payment(%L,%L,%L,%L,%L)',t.id('nile'),t.id('main'),t.id('safe'),'1.00','system:u03'),'VALIDATION_FAILED');
SELECT t.error('input: a reference over 100 characters',format('SELECT public.post_supplier_payment(%L,%L,%L,%L,%L,%L)',t.id('nile'),t.id('main'),t.id('safe'),'1.00','u03-long-ref',repeat('x',101)),'VALIDATION_FAILED');
SELECT t.error('input: an unknown supplier',format('SELECT public.post_supplier_payment(%L,%L,%L,%L,%L)',gen_random_uuid(),t.id('main'),t.id('safe'),'1.00','u03-unknown'),'SUPPLIER_NOT_FOUND');
SELECT t.expect('refused calls posted nothing',(SELECT count(*) FROM public.supplier_payments)=2 AND t.moves()=2 AND t.cash('safe')=37000);

-- ---------------------------------------------------------------- funds and accounts
SELECT t.error('funds: more than the safe holds',t.call('delta','40000.00'),'INSUFFICIENT_FUNDS');
SELECT t.expect('funds: nothing posted',(SELECT count(*) FROM public.supplier_payments)=2
  AND (SELECT count(*) FROM public.supplier_payment_allocations)=3 AND t.cash('safe')=37000 AND t.owed('big')=57000);
SELECT t.error('account: an inactive safe',t.call('nile','100.00',NULL,'spare'),'CASH_ACCOUNT_INACTIVE');
SELECT t.error('account: another branch''s safe',t.call('nile','100.00',NULL,'safe2'),'VAULT_INVALID');
SELECT t.error('account: another shop''s safe',t.call('nile','100.00',NULL,'safe_b'),'VAULT_INVALID');
SELECT t.error('account: an empty shop-wide bank can''t go below 0',t.call('nile','100.00',NULL,'bank'),'INSUFFICIENT_FUNDS');
SELECT public.create_cash_transfer(t.id('safe'),t.id('bank'),'500.00','','u03-fund-bank');
INSERT INTO t.ids SELECT 'p_bank',(public.post_supplier_payment(t.id('nile'),t.id('main'),t.id('bank'),'200.00','u03-bank-key')->>'id')::uuid;
SELECT t.expect('account: a shop-wide bank pays, booked in the payment''s branch',
  t.cash('bank')=300 AND t.owed('b')=3900
  AND (SELECT branch_id FROM public.cash_movements WHERE source_type='supplier_payment' AND source_id=t.id('p_bank'))=t.id('main'));

-- ---------------------------------------------------------------- credit return interplay
SELECT public.post_purchase_return(t.id('b'),'supplier_credit','Scratched',
  jsonb_build_array(jsonb_build_object('invoice_line_id',(SELECT id FROM public.purchase_invoice_lines WHERE invoice_id=t.id('b')),'quantity',10)),'u03-return');
SELECT t.expect('credit return: B''s outstanding goes down by the return',t.owed('b')=2760 AND t.bal('nile')=2760);
SELECT t.error_detail('credit return: the cap includes it',t.call('nile','2760.01'),'PAYMENT_EXCEEDS_OUTSTANDING','{"outstanding":"2760.00"}');

-- ---------------------------------------------------------------- open invoices and the list
SELECT t.expect('open invoices: only what is owed, oldest first, due date from the terms',
  jsonb_array_length(o->'items')=1 AND o->>'total_outstanding'='2760.00'
  AND (o->'items'->0->>'purchase_invoice_id')::uuid=t.id('b') AND o->'items'->0->>'outstanding'='2760.00'
  AND o->'items'->0->>'paid'='1800.00' AND o->'items'->0->>'returned_credit'='1140.00'
  AND (o->'items'->0->>'due_date')::date=current_date+2 AND NOT (o->'items'->0->>'overdue')::boolean, o::text)
FROM (SELECT public.list_open_supplier_invoices(t.id('nile')) o) x;
SELECT t.expect('open invoices: Delta has two, oldest number first, both due today-1 (overdue)',
  jsonb_array_length(o->'items')=2 AND o->>'total_outstanding'='58140.00'
  AND (o->'items'->0->>'purchase_invoice_id')::uuid=t.id('c') AND (o->'items'->0->>'overdue')::boolean, o::text)
FROM (SELECT public.list_open_supplier_invoices(t.id('delta')) o) x;

-- ---------------------------------------------------------------- reversal
INSERT INTO t.ids SELECT 'r1',(public.reverse_supplier_payment(t.id('p1'),'  Paid the wrong supplier ','u03-r1-key')->>'id')::uuid;
SELECT t.expect('reversal: the safe +3 000, A owed 3 000 again, Nile''s balance back up',
  t.cash('safe')=39500 AND t.owed('a')=3000 AND t.bal('nile')=5760
  AND (SELECT amount=3000 AND reverses_movement_id=(SELECT id FROM public.cash_movements WHERE source_id=t.id('p1'))
       FROM public.cash_movements WHERE source_id=t.id('r1')));
SELECT t.expect('reversal: its own SP number, linked both ways, the reason, audited as a warning',
  r->>'number' LIKE '%-SP-%' AND r->>'number'<>p->>'number' AND (r->>'reverses_payment_id')::uuid=t.id('p1')
  AND (p->>'reversed_by_payment_id')::uuid=t.id('r1') AND r->>'reason'='Paid the wrong supplier'
  AND r->>'amount'='3000.00' AND r->'allocations'='[]'::jsonb
  AND (SELECT count(*)=1 AND bool_and(severity='warning' AND reason='Paid the wrong supplier') FROM public.audit_log
       WHERE action='supplier_payment.reversed' AND entity_id=t.id('p1')), r::text)
FROM (SELECT public.get_supplier_payment(t.id('r1')) r,public.get_supplier_payment(t.id('p1')) p) x;
SELECT t.expect('reversal: the same key again -> the same reversal, nothing moves',
  (public.reverse_supplier_payment(t.id('p1'),'Paid the wrong supplier','u03-r1-key')->>'id')::uuid=t.id('r1') AND t.cash('safe')=39500);
SELECT t.error('reversal: again with a new key',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('p1'),'Again please','u03-r1-again'),'PAYMENT_ALREADY_REVERSED');
SELECT t.error('reversal: a reversal can''t be reversed',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('r1'),'Undo the undo','u03-r1-undo'),'VALIDATION_FAILED');
SELECT t.error('reversal: the key of another payment',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('p2'),'Wrong key','u03-r1-key'),'IDEMPOTENCY_CONFLICT');
SELECT t.error('reversal: a short reason',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('p2'),'no','u03-r-short'),'VALIDATION_FAILED');
SELECT t.error('reversal: an unknown payment',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',gen_random_uuid(),'Unknown','u03-r-unknown'),'SUPPLIER_PAYMENT_NOT_FOUND');
SELECT t.expect('statement: payments and the reversal are on the U01 statement, closing at the balance',
  (SELECT count(*) FROM jsonb_array_elements(s->'rows') r WHERE r->>'kind'='payment')=3
  AND (SELECT count(*) FROM jsonb_array_elements(s->'rows') r WHERE r->>'kind'='payment_reversal')=1
  AND (s->>'closing_balance')::numeric=t.bal('nile'), s::text)
FROM (SELECT public.supplier_statement(t.id('nile')) s) x;
-- The business date is the shop's today (Cairo), which can be a day ahead of the database's UTC date.
SELECT t.expect('list: newest first; without reversals only the payments that count',
  (public.list_supplier_payments(t.id('nile'))->>'total')::int=4
  AND (public.list_supplier_payments(t.id('nile'),NULL,NULL,NULL,false)->>'total')::int=2
  AND (public.list_supplier_payments(t.id('delta'))->>'total')::int=0
  AND (public.list_supplier_payments(NULL,t.id('main'),current_date-1,current_date+1,true,1,1)->'items'->0->>'id') IS NOT NULL
  AND NOT (public.list_supplier_payments()->'items'->0 ? 'allocations'));
SELECT t.error('list: from after to',format('SELECT public.list_supplier_payments(NULL,NULL,%L,%L)',current_date,current_date-1),'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- roles
SELECT t.as_user('a3030000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('who: an ACCOUNTANT pays',
  public.post_supplier_payment(t.id('nile'),t.id('main'),t.id('safe'),'100.00','u03-acc-key',NULL,jsonb_build_array(t.al('a','100.00')))->>'amount'='100.00'
  AND t.owed('a')=2900);
SELECT t.error('who: an ACCOUNTANT can''t reverse',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('p2'),'Not mine to undo','u03-acc-rev'),'APPROVAL_OWNER_ONLY');
RESET ROLE;
SELECT t.as_user('a3030000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: a WAREHOUSE user can''t pay',t.call('nile','1.00'),'PERMISSION_DENIED');
SELECT t.error('who: a WAREHOUSE user can''t list open invoices',format('SELECT public.list_open_supplier_invoices(%L)',t.id('nile')),'PERMISSION_DENIED');
SELECT t.expect('who: a WAREHOUSE user reads payments (purchasing read key)',(public.list_supplier_payments()->>'total')::int=5);
RESET ROLE;
SELECT t.as_user('a3030000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('who: another branch''s manager can''t pay from main',t.call('nile','1.00'),'BRANCH_DENIED');
SELECT t.error('who: a manager can''t reverse',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('p2'),'Not the owner','u03-mgr-rev'),'APPROVAL_OWNER_ONLY');
SELECT t.error('who: another branch''s manager can''t read main''s payment',format('SELECT public.get_supplier_payment(%L)',t.id('p1')),'SUPPLIER_PAYMENT_NOT_FOUND');
SELECT t.expect('who: another branch''s manager lists none and sees no open invoice of main',
  (public.list_supplier_payments()->>'total')::int=0
  AND jsonb_array_length(public.list_open_supplier_invoices(t.id('nile'))->'items')=0);
SELECT t.error('who: paying from the second branch can''t reach main''s invoices',t.call('nile','1.00',NULL,'safe2','second'),'PAYMENT_EXCEEDS_OUTSTANDING');
RESET ROLE;

-- ---------------------------------------------------------------- tenancy, ledger, expired shop, grants
SELECT t.as_user('a3030000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: a''s supplier',format('SELECT public.post_supplier_payment(%L,%L,%L,%L,%L)',t.id('nile'),t.id('main_b'),t.id('safe_b'),'1.00','u03-b-pay'),'SUPPLIER_NOT_FOUND');
SELECT t.error('shop b: a''s payment',format('SELECT public.get_supplier_payment(%L)',t.id('p1')),'SUPPLIER_PAYMENT_NOT_FOUND');
SELECT t.error('shop b: reversing a''s payment',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('p2'),'Not mine','u03-b-rev'),'SUPPLIER_PAYMENT_NOT_FOUND');
SELECT t.error('shop b: a''s open invoices',format('SELECT public.list_open_supplier_invoices(%L)',t.id('nile')),'SUPPLIER_NOT_FOUND');
SELECT t.error('shop b: a''s supplier in the list',format('SELECT public.list_supplier_payments(%L)',t.id('nile')),'SUPPLIER_NOT_FOUND');
SELECT t.expect('shop b: lists no payments',(public.list_supplier_payments()->>'total')::int=0);
SELECT t.error('no direct writes',format('INSERT INTO public.supplier_payments(organization_id,number,supplier_id,branch_id,cash_account_id,amount,business_date,idempotency_key) VALUES(%L,%L,%L,%L,%L,1,current_date,%L)',t.org('b'),'X',t.id('nile'),t.id('main_b'),t.id('safe_b'),'u03-direct'),'permission denied for table supplier_payments');
RESET ROLE;
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
SELECT t.expect('the safe adds up: 50 000 - 3 000 - 10 000 - 500 + 3 000 - 100',t.cash('safe')=39400,t.cash('safe')::text);
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a3030000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired shop: payments and open invoices still read',
  (public.list_supplier_payments()->>'total')::int=5 AND public.list_open_supplier_invoices(t.id('nile')) ? 'items');
SELECT t.error('expired shop: no new payment',t.call('nile','1.00'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no reversal',format('SELECT public.reverse_supplier_payment(%L,%L,%L)',t.id('p2'),'Too late','u03-exp-rev'),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('grants: the five functions for authenticated, the helper not',
  has_function_privilege('authenticated','public.post_supplier_payment(uuid,uuid,uuid,text,text,text,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.reverse_supplier_payment(uuid,text,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_supplier_payments(uuid,uuid,date,date,boolean,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_supplier_payment(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_open_supplier_invoices(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_supplier_payment(uuid,uuid,uuid,text,text,text,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_payment_json(uuid,uuid,boolean)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
