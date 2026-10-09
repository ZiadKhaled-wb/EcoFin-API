\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- The error text of a call ('' when it works).
CREATE FUNCTION t.try(q text) RETURNS text LANGUAGE plpgsql AS $$ BEGIN EXECUTE q; RETURN ''; EXCEPTION WHEN others THEN RETURN SQLERRM; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.level(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0) $$;
CREATE FUNCTION t.moves(i text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.stock_movements WHERE source_id=t.id(i) $$;
CREATE FUNCTION t.audits(a text,i text) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.audit_log WHERE action=a AND entity_id=t.id(i) $$;
CREATE FUNCTION t.avg(p text) RETURNS text LANGUAGE sql AS $$ SELECT avg_cost::text FROM public.products WHERE id=t.id(p) $$;
CREATE FUNCTION t.bal(s text) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE((SELECT balance FROM public.v_supplier_balances WHERE supplier_id=t.id(s)),0) $$;
CREATE FUNCTION t.status(i text) RETURNS text LANGUAGE sql AS $$ SELECT status::text FROM public.purchase_invoices WHERE id=t.id(i) $$;
CREATE FUNCTION t.approvals(i text,st text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.approvals WHERE kind='purchase_invoice' AND entity_id=t.id(i) AND status::text=st $$;
CREATE FUNCTION t.listed(i text,st text DEFAULT 'pending') RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS(SELECT 1 FROM jsonb_array_elements(public.list_purchase_approvals(st,NULL,100,0)->'items') x
                WHERE x->'invoice'->>'id'=t.id(i)::text) $$;
-- A draft of p at cost c (exempt class: total = cost x qty) in branch b, made by the current user.
CREATE FUNCTION t.pi(tag text,p text,c text,b text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
DECLARE j jsonb; BEGIN
  j := public.create_purchase_invoice(t.id('nile'),t.id(b),NULL,current_date,
         jsonb_build_array(jsonb_build_object('product_id',t.id(p),'quantity',1,'unit_cost',c,'tax_class_id',t.id('exempt'))),
         'u06-'||tag||'-key');
  INSERT INTO t.ids VALUES(tag,(j->>'id')::uuid); END $$;
CREATE FUNCTION t.threshold(v numeric) RETURNS void LANGUAGE sql AS $$
  UPDATE public.org_settings SET purchase_approval_threshold=v WHERE organization_id=t.org('a') $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (main, second), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('U06 '||s,'u06-'||s,'retail','Owner',s||'u06@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('o',64)),('b',repeat('q',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a6060000-0000-0000-8000-000000000001','au06@example.com'),('a6060000-0000-0000-8000-000000000002','bu06@example.com'),
  ('a6060000-0000-0000-8000-000000000003','u06manager@example.com'),('a6060000-0000-0000-8000-000000000004','u06manager2@example.com'),
  ('a6060000-0000-0000-8000-000000000005','u06warehouse@example.com');
SELECT public.accept_invite(repeat('o',64),'a6060000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a6060000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'exempt',id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='exempt';
INSERT INTO t.ids SELECT 'owner',id FROM public.employees WHERE organization_id=t.org('a') AND role='OWNER';
SELECT t.as_user('a6060000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','U6',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","sku":"U06-TV","cash_price":"60000"}'));
INSERT INTO t.ids VALUES('sofa',public.create_product('{"name_ar":"كنبة","sku":"U06-SF","cash_price":"20000"}'));
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
RESET ROLE;
-- Managers (BRANCH_MANAGER: create + approve) of main and of second; a warehouse user in main.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a6060000-0000-0000-8000-000000000003','U06 Manager','BRANCH_MANAGER',t.id('main')) RETURNING id AS mgr_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'mgr_id',t.id('main'));
INSERT INTO t.ids VALUES('mgr',:'mgr_id');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a6060000-0000-0000-8000-000000000004','U06 Manager Two','BRANCH_MANAGER',t.id('second')) RETURNING id AS mgr2_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'mgr2_id',t.id('second'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a6060000-0000-0000-8000-000000000005','U06 Warehouse','WAREHOUSE',t.id('main')) RETURNING id AS wh_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'wh_id',t.id('main'));

-- ---------------------------------------------------------------- no threshold: a manager approves 50 000
SELECT t.as_user('a6060000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.pi('big','tv','50000.00');
SELECT t.expect('no threshold (NULL): a manager approves 50 000 directly (stock in)',
  (public.approve_purchase_invoice(t.id('big'))->>'status')='approved' AND t.level('tv','main')=1 AND t.approvals('big','pending')=0);
SELECT t.expect('...the audit records no threshold and above = false',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='purchase_invoice.approved' AND entity_id=t.id('big')
         AND after->'threshold'='null'::jsonb AND after->'above'='false'::jsonb));
RESET ROLE;
SELECT t.threshold(10000.00);

-- ---------------------------------------------------------------- exactly 10 000.00 posts (strictly greater)
SELECT t.as_user('a6060000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.pi('exact','sofa','10000.00');
SELECT t.expect('exactly 10 000.00: approved directly (strictly greater)',
  (public.approve_purchase_invoice(t.id('exact'))->>'status')='approved' AND t.moves('exact')=1);

-- ---------------------------------------------------------------- Done when: 12 000 by a manager waits
SELECT t.pi('p1','tv','12000.00');
SELECT t.expect('Done when: the manager''s approve answers pending_approval with the approval',
  j->>'status'='pending_approval' AND j->'approval'->>'status'='pending' AND j->'approval'->>'amount'='12000.00'
  AND j->'approval'->>'threshold'='10000.00' AND j->'approval'->>'requested_by_name'='U06 Manager'
  AND j->'approval'->'decided_at'='null'::jsonb, j::text)
FROM (SELECT public.approve_purchase_invoice(t.id('p1')) j) x;
SELECT t.expect('...no stock movement, no cost change, no supplier balance change',
  t.moves('p1')=0 AND t.level('tv','main')=1 AND t.avg('tv')='50000.0000' AND t.bal('nile')=60000.00,
  concat_ws(' ',t.moves('p1'),t.level('tv','main'),t.avg('tv'),t.bal('nile')));
SELECT t.expect('...one pending approval row and one approval_requested audit row',
  t.approvals('p1','pending')=1 AND t.audits('purchase_invoice.approval_requested','p1')=1
  AND t.audits('purchase_invoice.approved','p1')=0
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='purchase_invoice.approval_requested' AND entity_id=t.id('p1')
             AND after->>'threshold'='10000.00' AND after->>'total'='12000.00'));
SELECT t.error('Done when: the manager can''t approve it (again)',format('SELECT public.approve_purchase_invoice(%L,%L)',t.id('p1'),'please'),'APPROVAL_OWNER_ONLY');
SELECT t.error('a pending invoice can''t be edited',format('SELECT public.update_purchase_invoice(%L,%L)',t.id('p1'),'{"supplier_invoice_no":"X"}'),'PURCHASE_INVOICE_NOT_EDITABLE');
SELECT t.error('a manager can''t reject a pending invoice',format('SELECT public.reject_purchase_invoice(%L,%L)',t.id('p1'),'Not needed'),'APPROVAL_OWNER_ONLY');

-- ---------------------------------------------------------------- Done when: the approval list
SELECT t.expect('Done when: the manager (main) sees it in the approval list',t.listed('p1'));
SELECT t.expect('...with the invoice summary and the approval',
  x->'invoice'->>'status'='pending_approval' AND x->'invoice'->>'total'='12000.00' AND x->'approval'->>'status'='pending'
  AND (x->'invoice'->>'lines_count')::int=1, x::text)
FROM jsonb_array_elements(public.list_purchase_approvals()->'items') x WHERE x->'invoice'->>'id'=t.id('p1')::text;
RESET ROLE;
SELECT t.as_user('a6060000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('a manager of another branch doesn''t see it',NOT t.listed('p1'));
SELECT t.error('...and can''t filter by main',format('SELECT public.list_purchase_approvals(%L,%L)','pending',t.id('main')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.as_user('a6060000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('a WAREHOUSE user can''t read the approval list',$q$SELECT public.list_purchase_approvals()$q$,'PERMISSION_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- the owner decides a pending invoice
SELECT t.as_user('a6060000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('the owner sees it too',t.listed('p1'));
SELECT t.error('owner: approve a pending invoice without a note',format('SELECT public.approve_purchase_invoice(%L)',t.id('p1')),'APPROVAL_NOTE_REQUIRED');
SELECT t.error('owner: a note under 3 characters',format('SELECT public.approve_purchase_invoice(%L,%L)',t.id('p1'),' ok '),'APPROVAL_NOTE_REQUIRED');
SELECT t.expect('...nothing posted by the refusals',t.moves('p1')=0 AND t.status('p1')='pending_approval');
SELECT t.expect('owner: approves with a note',
  j->>'status'='approved' AND j->'approval'->>'status'='approved' AND j->'approval'->>'note'='Checked with the supplier'
  AND j->'approval'->>'decided_by_name'='Owner' AND j->>'outstanding'='12000.00', j::text)
FROM (SELECT public.approve_purchase_invoice(t.id('p1'),'  Checked with the supplier ') j) x;
SELECT t.expect('...stock in once, cost updated (1 at 50 000 + 1 at 12 000 -> 31 000), balance up',
  t.moves('p1')=1 AND t.level('tv','main')=2 AND t.avg('tv')='31000.0000' AND t.bal('nile')=72000.00,
  concat_ws(' ',t.moves('p1'),t.level('tv','main'),t.avg('tv'),t.bal('nile')));
SELECT t.expect('...the approval row: approved by the owner with the note, one statement',
  EXISTS(SELECT 1 FROM public.approvals WHERE entity_id=t.id('p1') AND status='approved'
         AND decided_by=t.id('owner') AND decision_note='Checked with the supplier' AND decided_at IS NOT NULL
         AND requested_by=t.id('mgr')));
SELECT t.expect('...audited as approved with the note as the reason',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='purchase_invoice.approved' AND entity_id=t.id('p1')
         AND reason='Checked with the supplier' AND before->>'status'='pending_approval'));
SELECT public.approve_purchase_invoice(t.id('p1'));
SELECT t.expect('owner: approving again changes nothing (U02 idempotency)',
  t.moves('p1')=1 AND t.audits('purchase_invoice.approved','p1')=1 AND t.level('tv','main')=2);
SELECT t.expect('...and it leaves the pending list for the approved one',NOT t.listed('p1') AND t.listed('p1','approved'));
RESET ROLE;

-- Another pending one: rejected by the owner with a reason.
SELECT t.as_user('a6060000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.pi('p2','sofa','15000.00');
SELECT public.approve_purchase_invoice(t.id('p2'));
RESET ROLE;
SELECT t.as_user('a6060000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('owner: rejects a pending invoice with a reason',
  j->>'status'='rejected' AND j->>'rejected_reason'='Too expensive' AND j->'approval'->>'status'='rejected'
  AND j->'approval'->>'note'='Too expensive', j::text)
FROM (SELECT public.reject_purchase_invoice(t.id('p2'),'Too expensive') j) x;
SELECT t.expect('...nothing posted; the approval rejected by the owner; audited',
  t.moves('p2')=0 AND t.approvals('p2','rejected')=1 AND t.approvals('p2','pending')=0
  AND t.audits('purchase_invoice.rejected','p2')=1
  AND EXISTS(SELECT 1 FROM public.approvals WHERE entity_id=t.id('p2') AND decided_by=t.id('owner')));

-- The owner approving a draft above the threshold: posted directly, no approval row.
SELECT t.pi('own','sofa','20000.00');
SELECT t.expect('owner: a draft above the threshold is approved directly',
  (public.approve_purchase_invoice(t.id('own'))->>'status')='approved' AND t.moves('own')=1
  AND (SELECT count(*) FROM public.approvals WHERE entity_id=t.id('own'))=0);
SELECT t.expect('...the audit records {threshold, above: true}',
  EXISTS(SELECT 1 FROM public.audit_log WHERE action='purchase_invoice.approved' AND entity_id=t.id('own')
         AND after->>'threshold'='10000.00' AND after->'above'='true'::jsonb));
RESET ROLE;

-- ---------------------------------------------------------------- a pending invoice stays pending
SELECT t.as_user('a6060000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.pi('p3','sofa','13000.00');
SELECT public.approve_purchase_invoice(t.id('p3'));
RESET ROLE;
SELECT t.threshold(NULL);
SELECT t.as_user('a6060000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('threshold removed: a manager''s approve of a pending invoice still -> APPROVAL_OWNER_ONLY',format('SELECT public.approve_purchase_invoice(%L)',t.id('p3')),'APPROVAL_OWNER_ONLY');
SELECT t.expect('...still pending, nothing posted',t.status('p3')='pending_approval' AND t.moves('p3')=0);
SELECT t.pi('after','sofa','90000.00');
SELECT t.expect('...while a new draft above the old threshold now posts directly',
  (public.approve_purchase_invoice(t.id('after'))->>'status')='approved');
RESET ROLE;
SELECT t.threshold(10000.00);
SELECT t.expect('one pending approval per invoice (the index)',
  t.try(format('INSERT INTO public.approvals(organization_id,branch_id,kind,entity_type,entity_id,amount,status,requested_by) VALUES(%L,%L,%L,%L,%L,1,%L,%L)',
        t.org('a'),t.id('main'),'purchase_invoice','purchase_invoice',t.id('p3'),'pending',t.id('mgr'))) LIKE '%approvals_one_pending_purchase_key%');
SELECT t.expect('a decided approval is frozen (trigger)',
  t.try(format('UPDATE public.approvals SET decision_note=%L WHERE entity_id=%L','x',t.id('p1'))) LIKE 'DOCUMENT_FINAL%');

-- ---------------------------------------------------------------- tenancy, expired shop, grants
SELECT t.as_user('a6060000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.error('shop b: approve',format('SELECT public.approve_purchase_invoice(%L,%L)',t.id('p3'),'Not mine at all'),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.error('shop b: reject',format('SELECT public.reject_purchase_invoice(%L,%L)',t.id('p3'),'Not mine'),'PURCHASE_INVOICE_NOT_FOUND');
SELECT t.expect('shop b: the approval list is empty (and RLS hides the rows)',
  (public.list_purchase_approvals()->>'total')::int=0 AND NOT EXISTS(SELECT 1 FROM public.approvals));
RESET ROLE;
SELECT t.expect('shop b''s refused calls changed nothing',t.status('p3')='pending_approval' AND t.approvals('p3','pending')=1);
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a6060000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the approval list still reads',t.listed('p3'));
SELECT t.error('expired shop: no decision',format('SELECT public.approve_purchase_invoice(%L,%L)',t.id('p3'),'Fine by me'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('list: an unknown status',$q$SELECT public.list_purchase_approvals('waiting')$q$,'VALIDATION_FAILED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('ledger caches match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
SELECT t.expect('grants: the new approve signature, the list; no anon; helpers not granted',
  has_function_privilege('authenticated','public.approve_purchase_invoice(uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_purchase_approvals(text,uuid,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.approve_purchase_invoice(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.list_purchase_approvals(text,uuid,integer,integer)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.purchase_approval_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.post_purchase_invoice(uuid,uuid,public.purchase_invoices)','EXECUTE')
  AND NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='approve_purchase_invoice' AND pronargs=1));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
