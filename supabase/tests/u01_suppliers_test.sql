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
  SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action=a AND entity_id=t.id(s) $$;
-- "kind number debit credit balance" of every statement row, in order.
CREATE FUNCTION t.rows(st jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(concat_ws(' ',r->>'kind',r->>'number',r->>'debit',r->>'credit',r->>'balance'),' | ' ORDER BY o)
  FROM jsonb_array_elements(st->'rows') WITH ORDINALITY x(r,o) $$;
-- Superuser inserts: what U02-U04 will write later.
CREATE FUNCTION t.invoice(tag text,s text,no text,d date,st public.purchase_invoice_status,sub numeric,tax numeric) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.purchase_invoices(organization_id,number,supplier_invoice_no,supplier_id,branch_id,invoice_date,status,subtotal,tax_total,total,approved_at,idempotency_key,created_at)
  VALUES(t.org('a'),no,'S-'||no,t.id(s),t.id('main'),d,st,sub,tax,sub+tax,CASE WHEN st='approved' THEN now() END,'u01-inv-'||no,clock_timestamp()) RETURNING id) INSERT INTO t.ids SELECT tag,id FROM x $$;
CREATE FUNCTION t.payment(tag text,s text,no text,d date,amt numeric,ref text,rev text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.supplier_payments(organization_id,number,supplier_id,branch_id,cash_account_id,amount,business_date,reference,reverses_payment_id,reason,idempotency_key,created_at)
  VALUES(t.org('a'),no,t.id(s),t.id('main'),t.id('cash'),amt,d,ref,t.id(rev),CASE WHEN rev IS NOT NULL THEN 'bounced' END,'u01-pay-'||no,clock_timestamp()) RETURNING id) INSERT INTO t.ids SELECT tag,id FROM x $$;
CREATE FUNCTION t.ret(tag text,s text,inv text,no text,d date,m public.purchase_refund_mode,amt numeric) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.purchase_returns(organization_id,number,purchase_invoice_id,supplier_id,branch_id,refund_mode,cash_account_id,subtotal,tax_total,total,reason,business_date,idempotency_key,created_at)
  VALUES(t.org('a'),no,t.id(inv),t.id(s),t.id('main'),m,CASE WHEN m='cash' THEN t.id('cash') END,amt,0,amt,'damaged',d,'u01-ret-'||no,clock_timestamp()) RETURNING id) INSERT INTO t.ids SELECT tag,id FROM x $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a, shop b, five people
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('U01 '||s,'u01-'||s,'retail','Owner',s||'u01@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('x',64)),('b',repeat('y',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a1010000-0000-0000-8000-000000000001','au01@example.com'),('a1010000-0000-0000-8000-000000000002','bu01@example.com'),
  ('a1010000-0000-0000-8000-000000000003','u01warehouse@example.com'),('a1010000-0000-0000-8000-000000000004','u01collector@example.com'),
  ('a1010000-0000-0000-8000-000000000005','u01cashier@example.com');
SELECT public.accept_invite(repeat('x',64),'a1010000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a1010000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'cash',id FROM public.cash_accounts WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1;
-- Warehouse: purchase.order_manage + purchase.invoice_create (reads, no writes). Collector, cashier: none of the read keys.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a1010000-0000-0000-8000-000000000003','U01 Warehouse','WAREHOUSE',t.id('main')) RETURNING id AS warehouse_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'warehouse_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a1010000-0000-0000-8000-000000000004','U01 Collector','COLLECTOR');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a1010000-0000-0000-8000-000000000005','U01 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
SELECT t.expect('setup: a cash account for the payments',t.id('cash') IS NOT NULL);

-- ---------------------------------------------------------------- create
SELECT t.as_user('a1010000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"  Nile Traders  ","phone":" 010-1234 5678 ","tax_registration_no":" 123-456-789 ","address":" Cairo ","payment_terms_days":30,"notes":" first "}')->>'id')::uuid;
SELECT t.expect('create: trims, normalises the phone, balance 0',
  s->>'name'='Nile Traders' AND s->>'phone'='01012345678' AND s->>'tax_registration_no'='123-456-789'
  AND s->>'address'='Cairo' AND s->>'notes'='first' AND (s->>'payment_terms_days')::int=30
  AND s->>'balance'='0.00' AND s->'archived_at'='null'::jsonb, s::text)
FROM (SELECT public.get_supplier(t.id('nile')) s) x;
SELECT t.expect('create: defaults (terms 0, optional fields null)',
  s->>'payment_terms_days'='0' AND s->'phone'='null'::jsonb AND s->'tax_registration_no'='null'::jsonb, s::text)
FROM (SELECT public.create_supplier('{"name":"Delta Supply"}') s) x;
SELECT t.error('create: an unknown key',$q$SELECT public.create_supplier('{"name":"X1","category":"general"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: organization_id in the body',format('SELECT public.create_supplier(%L)',jsonb_build_object('name','X2','organization_id',t.org('b'))),'VALIDATION_FAILED');
SELECT t.error('create: no name',$q$SELECT public.create_supplier('{"phone":"0101111111"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a blank name',$q$SELECT public.create_supplier('{"name":"   "}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a name over 150',format('SELECT public.create_supplier(%L)',jsonb_build_object('name',repeat('n',151))),'VALIDATION_FAILED');
SELECT t.error('create: a bad phone',$q$SELECT public.create_supplier('{"name":"X3","phone":"01ab234567"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a short phone',$q$SELECT public.create_supplier('{"name":"X4","phone":"12345"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a bad tax number',$q$SELECT public.create_supplier('{"name":"X5","tax_registration_no":"12-34"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: terms over 365',$q$SELECT public.create_supplier('{"name":"X6","payment_terms_days":400}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: fractional terms',$q$SELECT public.create_supplier('{"name":"X7","payment_terms_days":1.5}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: terms as text',$q$SELECT public.create_supplier('{"name":"X8","payment_terms_days":"30"}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: a name as a number',$q$SELECT public.create_supplier('{"name":12}')$q$,'VALIDATION_FAILED');
SELECT t.error('create: the same active name in another letter case',$q$SELECT public.create_supplier('{"name":" nile TRADERS "}')$q$,'SUPPLIER_NAME_TAKEN');
SELECT t.error('create: the same phone (written differently)',$q$SELECT public.create_supplier('{"name":"Other","phone":"0101 234-5678"}')$q$,'SUPPLIER_PHONE_TAKEN');
INSERT INTO t.ids SELECT 'old',(public.create_supplier('{"name":"Old Co","phone":"+201000000001"}')->>'id')::uuid;
SELECT public.set_supplier_archived(t.id('old'),true);
INSERT INTO t.ids SELECT 'old2',(public.create_supplier('{"name":"old co","phone":"+201000000001"}')->>'id')::uuid;
SELECT t.expect('create: an archived supplier''s name and phone are free again',t.id('old2') IS NOT NULL AND t.id('old2')<>t.id('old'));
SELECT t.expect('create: one supplier.created row with the after state',
  t.audits('supplier.created','nile')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='supplier.created' AND entity_id=t.id('nile')
    AND entity_type='supplier' AND after->>'name'='Nile Traders' AND NOT after ? 'balance'));
SELECT t.expect('create: refused calls wrote no row',
  (SELECT count(*) FROM public.suppliers WHERE organization_id=t.org('a'))=4);

-- ---------------------------------------------------------------- update
SELECT public.update_supplier(t.id('nile'),'{"address":"Giza","name":"Nile Traders","payment_terms_days":30}');
SELECT t.expect('update: only the changed keys in before and after',
  t.audits('supplier.updated','nile')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='supplier.updated' AND entity_id=t.id('nile')
    AND before='{"address":"Cairo"}'::jsonb AND after='{"address":"Giza"}'::jsonb),
  (SELECT before::text||' '||after::text FROM public.audit_log WHERE action='supplier.updated' AND entity_id=t.id('nile')));
SELECT public.update_supplier(t.id('nile'),'{"address":" Giza ","phone":"01012345678"}');
SELECT t.expect('update: no actual change, no audit row',t.audits('supplier.updated','nile')=1);
SELECT t.expect('update: phone cleared to null, notes emptied to null',
  s->'phone'='null'::jsonb AND s->'notes'='null'::jsonb, s::text)
FROM (SELECT public.update_supplier(t.id('nile'),'{"phone":null,"notes":""}') s) x;
SELECT public.update_supplier(t.id('nile'),'{"phone":"01012345678"}');
SELECT t.error('update: an archived supplier',format('SELECT public.update_supplier(%L,%L)',t.id('old'),'{"address":"x"}'),'SUPPLIER_NOT_FOUND');
SELECT t.error('update: to another active supplier''s name',format('SELECT public.update_supplier(%L,%L)',t.id('old2'),'{"name":"NILE traders"}'),'SUPPLIER_NAME_TAKEN');
SELECT t.error('update: to another active supplier''s phone',format('SELECT public.update_supplier(%L,%L)',t.id('old2'),'{"phone":"010 1234 5678"}'),'SUPPLIER_PHONE_TAKEN');
SELECT t.error('update: an unknown key',format('SELECT public.update_supplier(%L,%L)',t.id('nile'),'{"archived_at":null}'),'VALIDATION_FAILED');
SELECT t.error('update: a bad phone',format('SELECT public.update_supplier(%L,%L)',t.id('nile'),'{"phone":"abc"}'),'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- statement (Done when)
-- Nile: 2 approved invoices, 1 draft, 1 rejected, 2 payments, a reversal of one, a credit and a cash return.
SELECT t.invoice('inv1','nile','PI-U01-1','2026-09-01','approved',1000,0);
SELECT t.payment('pay1','nile','SP-U01-1','2026-09-03',400,'CHQ-1');
SELECT t.invoice('draft','nile','PI-U01-3','2026-09-05','draft',300,0);
SELECT t.invoice('rejected','nile','PI-U01-4','2026-09-06','rejected',200,0);
SELECT t.invoice('inv2','nile','PI-U01-2','2026-09-10','approved',450.50,50);
SELECT t.payment('pay2','nile','SP-U01-2','2026-09-12',100,NULL);
SELECT t.payment('rev2','nile','SP-U01-3','2026-09-13',100,'CHQ-2 back','pay2');
SELECT t.ret('ret1','nile','inv1','PR-U01-1','2026-09-15','supplier_credit',50.25);
SELECT t.ret('ret2','nile','inv2','PR-U01-2','2026-09-16','cash',30);
-- Draft Co: only a draft invoice. PO Co: only a sent purchase order.
SELECT t.as_user('a1010000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'draftco',(public.create_supplier('{"name":"Draft Co"}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'poco',(public.create_supplier('{"name":"PO Co"}')->>'id')::uuid;
RESET ROLE;
SELECT t.invoice('draftinv','draftco','PI-U01-9','2026-09-20','pending_approval',10,0);
INSERT INTO public.purchase_orders(organization_id,number,supplier_id,branch_id,status,idempotency_key)
  VALUES(t.org('a'),'PO-U01-1',t.id('poco'),t.id('main'),'sent','u01-po-1');

SELECT t.as_user('a1010000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('statement: closing = invoices - payments - credit returns = v_supplier_balances.balance',
  st->>'closing_balance'='1050.25' AND st->>'opening_balance'='0.00'
  AND (st->>'closing_balance')::numeric=(SELECT balance FROM public.v_supplier_balances WHERE supplier_id=t.id('nile'))
  AND st->'supplier'->>'balance'='1050.25'
  AND st->'totals'='{"invoiced":"1500.50","paid":"400.00","returned":"50.25"}'::jsonb
  AND st->'from'='null'::jsonb AND st->'to'='null'::jsonb,
  st->>'closing_balance'||' '||(st->'totals')::text)
FROM (SELECT public.supplier_statement(t.id('nile')) st) x;
SELECT t.expect('statement: every row in order with the right running balance; drafts and rejected invoices are not listed',
  t.rows(st)='invoice PI-U01-1 1000.00 0.00 1000.00 | payment SP-U01-1 0.00 400.00 600.00 | invoice PI-U01-2 500.50 0.00 1100.50'
    ||' | payment SP-U01-2 0.00 100.00 1000.50 | payment_reversal SP-U01-3 100.00 0.00 1100.50'
    ||' | return PR-U01-1 0.00 50.25 1050.25 | return PR-U01-2 0.00 0.00 1050.25', t.rows(st))
FROM (SELECT public.supplier_statement(t.id('nile')) st) x;
SELECT t.expect('statement: the cash return has debit 0, credit 0 and its refund mode; the credit return says supplier_credit',
  EXISTS(SELECT 1 FROM jsonb_array_elements(st->'rows') r WHERE r->>'document_id'=t.id('ret2')::text
         AND r->>'debit'='0.00' AND r->>'credit'='0.00' AND r->>'refund_mode'='cash' AND r->>'reference'='PI-U01-2')
  AND EXISTS(SELECT 1 FROM jsonb_array_elements(st->'rows') r WHERE r->>'document_id'=t.id('ret1')::text AND r->>'refund_mode'='supplier_credit'))
FROM (SELECT public.supplier_statement(t.id('nile')) st) x;
SELECT t.expect('statement: invoice and payment rows carry their reference, date and branch',
  EXISTS(SELECT 1 FROM jsonb_array_elements(st->'rows') r WHERE r->>'document_id'=t.id('inv1')::text
         AND r->>'reference'='S-PI-U01-1' AND r->>'date'='2026-09-01' AND r->>'branch_id'=t.id('main')::text AND r->'refund_mode'='null'::jsonb)
  AND EXISTS(SELECT 1 FROM jsonb_array_elements(st->'rows') r WHERE r->>'document_id'=t.id('pay1')::text AND r->>'reference'='CHQ-1')
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(st->'rows') r WHERE r->>'document_id' IN (t.id('draft')::text,t.id('rejected')::text)))
FROM (SELECT public.supplier_statement(t.id('nile')) st) x;
SELECT t.expect('dates: from sets the opening balance; rows and totals cover the period only',
  st->>'opening_balance'='600.00' AND st->>'closing_balance'='1050.25' AND jsonb_array_length(st->'rows')=5
  AND st->'rows'->0->>'balance'='1100.50' AND st->>'from'='2026-09-10'
  AND st->'totals'='{"invoiced":"500.50","paid":"0.00","returned":"50.25"}'::jsonb, (st->'totals')::text)
FROM (SELECT public.supplier_statement(t.id('nile'),'2026-09-10',NULL) st) x;
SELECT t.expect('dates: from and to',
  st->>'opening_balance'='600.00' AND st->>'closing_balance'='1000.50' AND t.rows(st)='invoice PI-U01-2 500.50 0.00 1100.50 | payment SP-U01-2 0.00 100.00 1000.50'
  AND st->'totals'='{"invoiced":"500.50","paid":"100.00","returned":"0.00"}'::jsonb, t.rows(st))
FROM (SELECT public.supplier_statement(t.id('nile'),'2026-09-10','2026-09-12') st) x;
SELECT t.expect('dates: only to (no opening)',
  st->>'opening_balance'='0.00' AND st->>'closing_balance'='600.00' AND jsonb_array_length(st->'rows')=2)
FROM (SELECT public.supplier_statement(t.id('nile'),NULL,'2026-09-03') st) x;
SELECT t.expect('dates: an empty period keeps the balance',
  st->>'opening_balance'='1050.25' AND st->>'closing_balance'='1050.25' AND st->'rows'='[]'::jsonb)
FROM (SELECT public.supplier_statement(t.id('nile'),'2026-12-01','2026-12-31') st) x;
SELECT t.error('dates: from after to',format('SELECT public.supplier_statement(%L,%L,%L)',t.id('nile'),'2026-09-12','2026-09-10'),'VALIDATION_FAILED');
SELECT t.expect('statement: a supplier without documents',
  st->>'closing_balance'='0.00' AND st->'rows'='[]'::jsonb AND st->'supplier'->>'name'='Delta Supply')
FROM (SELECT public.supplier_statement((SELECT id FROM public.suppliers WHERE organization_id=t.org('a') AND name='Delta Supply')) st) x;
SELECT t.expect('statement: an archived supplier is readable',public.supplier_statement(t.id('old'))->'supplier'->>'archived_at' IS NOT NULL);

-- ---------------------------------------------------------------- list
SELECT t.expect('list: active by default, ordered by name',
  (SELECT string_agg(i->>'name',',' ORDER BY o) FROM jsonb_array_elements(l->'items') WITH ORDINALITY x(i,o))='Delta Supply,Draft Co,Nile Traders,old co,PO Co'
  AND (l->>'total')::int=5, l::text)
FROM (SELECT public.list_suppliers() l) x;
SELECT t.expect('list: the balance is on every row',
  (SELECT i->>'balance' FROM jsonb_array_elements(public.list_suppliers('nile')->'items') i)='1050.25');
SELECT t.expect('list: a name search (case-insensitive)',(public.list_suppliers(' NILE ')->>'total')::int=1);
SELECT t.expect('list: a phone prefix, written with spaces and dashes',
  (public.list_suppliers('010-123')->'items'->0->>'id')=t.id('nile')::text AND (public.list_suppliers('+2010')->>'total')::int=1);
SELECT t.expect('list: wildcards are literal',(public.list_suppliers('%')->>'total')::int=0 AND (public.list_suppliers('_')->>'total')::int=0);
SELECT t.expect('list: archived and all',
  (public.list_suppliers(NULL,'archived')->'items'->0->>'id')=t.id('old')::text AND (public.list_suppliers(NULL,'archived')->>'total')::int=1
  AND (public.list_suppliers(NULL,'all')->>'total')::int=6);
SELECT t.expect('list: paging',
  jsonb_array_length(public.list_suppliers(NULL,'all',2,2)->'items')=2 AND (public.list_suppliers(NULL,'all',2,2)->>'total')::int=6
  AND public.list_suppliers(NULL,'all',2,2)->'items'->0->>'name'='Nile Traders');
SELECT t.error('list: limit 0',$q$SELECT public.list_suppliers(NULL,'active',0,0)$q$,'VALIDATION_FAILED');
SELECT t.error('list: limit 101',$q$SELECT public.list_suppliers(NULL,'active',101,0)$q$,'VALIDATION_FAILED');
SELECT t.error('list: an unknown status',$q$SELECT public.list_suppliers(NULL,'deleted')$q$,'VALIDATION_FAILED');
SELECT t.error('list: a search over 100',format('SELECT public.list_suppliers(%L)',repeat('s',101)),'VALIDATION_FAILED');

-- ---------------------------------------------------------------- archive and restore
SELECT t.error('archive: refused with a balance',format('SELECT public.set_supplier_archived(%L,true)',t.id('nile')),'SUPPLIER_HAS_BALANCE');
SELECT t.error('archive: refused with an invoice pending approval',format('SELECT public.set_supplier_archived(%L,true)',t.id('draftco')),'SUPPLIER_HAS_OPEN_DOCUMENTS');
SELECT t.error('archive: refused with a sent purchase order',format('SELECT public.set_supplier_archived(%L,true)',t.id('poco')),'SUPPLIER_HAS_OPEN_DOCUMENTS');
SELECT t.expect('archive: refusals change nothing and write no row',
  (SELECT archived_at IS NULL FROM public.suppliers WHERE id=t.id('nile')) AND t.audits('supplier.archived','nile')=0 AND t.audits('supplier.archived','draftco')=0);
SELECT t.expect('archive: allowed at balance 0 without open documents; audited as a warning',
  t.audits('supplier.archived','old')=1 AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='supplier.archived' AND entity_id=t.id('old')
    AND severity='warning' AND before->'archived_at'='null'::jsonb AND after->>'archived_at' IS NOT NULL));
SELECT public.set_supplier_archived(t.id('old'),true);
SELECT t.expect('archive: the same state again changes nothing, no audit row',t.audits('supplier.archived','old')=1);
SELECT t.error('restore: clashes with an active name',format('SELECT public.set_supplier_archived(%L,false)',t.id('old')),'SUPPLIER_NAME_TAKEN');
SELECT public.update_supplier(t.id('old2'),'{"name":"Old Co Two"}');
SELECT t.error('restore: clashes with an active phone',format('SELECT public.set_supplier_archived(%L,false)',t.id('old')),'SUPPLIER_PHONE_TAKEN');
SELECT public.update_supplier(t.id('old2'),'{"phone":null}');
SELECT t.expect('restore: works once nothing clashes',public.set_supplier_archived(t.id('old'),false)->'archived_at'='null'::jsonb);
SELECT t.expect('restore: audited',
  t.audits('supplier.restored','old')=1
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='supplier.restored' AND entity_id=t.id('old') AND severity='info'));
SELECT t.error('archive: an unknown id',format('SELECT public.set_supplier_archived(%L,true)',gen_random_uuid()),'SUPPLIER_NOT_FOUND');
SELECT t.error('archive: null',format('SELECT public.set_supplier_archived(%L,NULL)',t.id('old')),'VALIDATION_FAILED');
RESET ROLE;

-- ---------------------------------------------------------------- who may read and write
SELECT t.as_user('a1010000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('warehouse (purchase.invoice_create) reads the list, a supplier and a statement',
  (public.list_suppliers()->>'total')::int=6 AND public.get_supplier(t.id('nile'))->>'name'='Nile Traders'
  AND public.supplier_statement(t.id('nile'))->>'closing_balance'='1050.25');
SELECT t.error('warehouse: no create',$q$SELECT public.create_supplier('{"name":"W1"}')$q$,'PERMISSION_DENIED');
SELECT t.error('warehouse: no update',format('SELECT public.update_supplier(%L,%L)',t.id('nile'),'{"address":"W"}'),'PERMISSION_DENIED');
SELECT t.error('warehouse: no archive',format('SELECT public.set_supplier_archived(%L,true)',t.id('poco')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a1010000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('collector: no list',$q$SELECT public.list_suppliers()$q$,'PERMISSION_DENIED');
SELECT t.error('collector: no get',format('SELECT public.get_supplier(%L)',t.id('nile')),'PERMISSION_DENIED');
SELECT t.error('collector: no statement',format('SELECT public.supplier_statement(%L)',t.id('nile')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a1010000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('cashier: no list',$q$SELECT public.list_suppliers()$q$,'PERMISSION_DENIED');
SELECT t.error('cashier: no statement',format('SELECT public.supplier_statement(%L)',t.id('nile')),'PERMISSION_DENIED');
SELECT t.as_user('a1010000-0000-0000-8000-000000000099',t.org('a'));
SELECT t.error('not an employee: list',$q$SELECT public.list_suppliers()$q$,'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee: statement',format('SELECT public.supplier_statement(%L)',t.id('nile')),'NOT_AN_EMPLOYEE');
SELECT t.error('not an employee: create',$q$SELECT public.create_supplier('{"name":"N1"}')$q$,'NOT_AN_EMPLOYEE');
RESET ROLE;
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a1010000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the list and the statement still read',
  (public.list_suppliers()->>'total')::int=6 AND public.supplier_statement(t.id('nile'))->>'closing_balance'='1050.25');
SELECT t.error('expired shop: no create',$q$SELECT public.create_supplier('{"name":"E1"}')$q$,'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no archive',format('SELECT public.set_supplier_archived(%L,true)',t.id('poco')),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ---------------------------------------------------------------- tenancy
SELECT t.as_user('a1010000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.error('shop b: get a''s supplier',format('SELECT public.get_supplier(%L)',t.id('nile')),'SUPPLIER_NOT_FOUND');
SELECT t.error('shop b: a''s statement',format('SELECT public.supplier_statement(%L)',t.id('nile')),'SUPPLIER_NOT_FOUND');
SELECT t.error('shop b: update a''s supplier',format('SELECT public.update_supplier(%L,%L)',t.id('nile'),'{"address":"B"}'),'SUPPLIER_NOT_FOUND');
SELECT t.error('shop b: archive a''s supplier',format('SELECT public.set_supplier_archived(%L,true)',t.id('poco')),'SUPPLIER_NOT_FOUND');
SELECT t.error('shop b: restore a''s supplier',format('SELECT public.set_supplier_archived(%L,false)',t.id('poco')),'SUPPLIER_NOT_FOUND');
SELECT t.expect('shop b: lists none of a''s suppliers; RLS hides them too',
  (public.list_suppliers(NULL,'all')->>'total')::int=0 AND NOT EXISTS(SELECT 1 FROM public.suppliers));
SELECT t.expect('shop b: may use the same name and phone (unique per shop)',
  public.create_supplier('{"name":"Nile Traders","phone":"01012345678"}')->>'balance'='0.00');
SELECT t.error('no direct writes',format('INSERT INTO public.suppliers(organization_id,name) VALUES(%L,%L)',t.org('b'),'Direct'),'permission denied for table suppliers');
RESET ROLE;
SELECT t.expect('shop b''s refused calls left a''s rows and audit as they were',
  (SELECT address FROM public.suppliers WHERE id=t.id('nile'))='Giza' AND (SELECT archived_at IS NULL FROM public.suppliers WHERE id=t.id('poco'))
  AND NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id=t.org('b') AND entity_id IN (t.id('nile'),t.id('poco'))));

-- ---------------------------------------------------------------- grants
SELECT t.expect('no anon grants',
  NOT has_function_privilege('anon','public.list_suppliers(text,text,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_supplier(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.supplier_statement(uuid,date,date)','EXECUTE')
  AND NOT has_function_privilege('anon','public.create_supplier(jsonb)','EXECUTE')
  AND NOT has_function_privilege('anon','public.update_supplier(uuid,jsonb)','EXECUTE')
  AND NOT has_function_privilege('anon','public.set_supplier_archived(uuid,boolean)','EXECUTE'));
SELECT t.expect('authenticated runs the six functions, not the helpers',
  has_function_privilege('authenticated','public.list_suppliers(text,text,integer,integer)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_supplier(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.supplier_statement(uuid,date,date)','EXECUTE')
  AND has_function_privilege('authenticated','public.create_supplier(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.update_supplier(uuid,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_supplier_archived(uuid,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.can_read_suppliers()','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_read_guard()','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_apply(public.suppliers,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_fields_json(public.suppliers)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_unique_error(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.supplier_statement_rows(uuid,uuid)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
