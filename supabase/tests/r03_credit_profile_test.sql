\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
-- The statement must fail and its message must contain the text (permission denied, check violations).
CREATE FUNCTION t.errlike(n text,q text,p text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND SQLERRM LIKE p,SQLERRM); END; END $$;
-- The DETAIL of the error a statement raises (NULL when it raises none).
CREATE FUNCTION t.detail(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d=PG_EXCEPTION_DETAIL; END; RETURN d; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- Audit rows of an action whose entity is the one tagged s.
CREATE FUNCTION t.audits(a text,s text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action=a AND entity_id=t.id(s) $$;
-- A valid national ID that is new on every n (century 2, 1990-01-01, Cairo).
CREATE FUNCTION t.nid(n integer) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT '290010101'||lpad(n::text,5,'0') $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql AS $$ SELECT app.org_today(t.org('a')) $$;

-- A customer of shop a made as the database owner (the limit is only written here and by set_customer_credit_limit).
CREATE FUNCTION t.cust(p_tag text,p_name text,p_income numeric,p_limit numeric,p_status text,p_nid integer) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,national_id,monthly_income,credit_limit,status)
    VALUES(t.org('a'),p_name,CASE WHEN p_nid IS NULL THEN NULL ELSE t.nid(p_nid) END,p_income,p_limit,p_status::public.customer_status) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
-- A guarantor linked to a customer (archived or not).
CREATE FUNCTION t.guar(p_customer text,p_n integer,p_archived boolean DEFAULT false) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.guarantors(organization_id,full_name,phone,national_id,archived_at)
    VALUES(t.org('a'),'R03 Guarantor '||p_n,'01000000'||lpad(p_n::text,3,'0'),t.nid(500+p_n),CASE WHEN p_archived THEN now() END) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('guar-'||p_n,v_id);
  INSERT INTO public.customer_guarantors(organization_id,customer_id,guarantor_id,relation) VALUES(t.org('a'),t.id(p_customer),v_id,'friend');
END $$;
-- An ID photo (F14 file) of a customer.
CREATE FUNCTION t.photo(p_customer text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.files(organization_id,path,original_name,mime,size_bytes,purpose,entity_type,entity_id)
  VALUES(t.org('a'),t.org('a')::text||'/r03-'||p_customer||'.png','id.png','image/png',100,'customer_id','customer',t.id(p_customer)) $$;
-- A contract of shop a for a customer, as the database owner (nothing creates contracts yet: N02). The credit
-- trigger is deferred: it runs only where a test says so.
CREATE FUNCTION t.contract(p_tag text,p_customer text,p_financed numeric,p_status text,p_migrated boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_order uuid; v_contract uuid; v_policy uuid;
BEGIN
  SELECT id INTO v_policy FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1;
  INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,total,idempotency_key)
    VALUES(t.org('a'),'R03-SO-'||p_tag,t.id(p_customer),t.id('main'),false,p_financed,p_financed,'r03-so-'||p_tag) RETURNING id INTO v_order;
  INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,order_id,policy_id,creditor,cash_price,down_payment,financed_amount,markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,status,closed_at,is_migrated,idempotency_key)
    VALUES(t.org('a'),'R03-C-'||p_tag,t.id(p_customer),t.id('main'),v_order,v_policy,'in_house',p_financed,0,p_financed,0,0,p_financed,6,'monthly',current_date+30,
           p_status::public.contract_status,CASE WHEN p_status='active' THEN NULL ELSE now() END,p_migrated,'r03-c-'||p_tag) RETURNING id INTO v_contract;
  INSERT INTO t.ids VALUES('contract-'||p_tag,v_contract);
END $$;
-- A schedule line due p_due days from today (negative = past).
CREATE FUNCTION t.line(p_tag text,p_contract text,p_seq integer,p_due integer,p_principal numeric,p_profit numeric,p_superseded boolean DEFAULT false) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit,superseded)
    VALUES(t.org('a'),t.id('contract-'||p_contract),1,p_seq,t.today()+p_due,p_principal,p_profit,p_superseded) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('line-'||p_tag,v_id);
END $$;
-- A payment of p_principal + p_profit on a line, made p_days_ago days ago (its business date).
CREATE FUNCTION t.pay(p_line text,p_principal numeric,p_profit numeric,p_days_ago integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_pay uuid; v_contract uuid; v_customer uuid; v_cash uuid; v_key text := 'r03-pay-'||p_line||'-'||p_days_ago||'-'||p_principal;
BEGIN
  SELECT sl.contract_id,c.customer_id INTO v_contract,v_customer FROM public.schedule_lines sl JOIN public.contracts c ON c.id=sl.contract_id WHERE sl.id=t.id('line-'||p_line);
  SELECT id INTO v_cash FROM public.cash_accounts WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1;
  INSERT INTO public.payments(organization_id,number,branch_id,direction,method,amount,customer_id,cash_account_id,business_date,idempotency_key)
    VALUES(t.org('a'),'R03-PY-'||substr(gen_random_uuid()::text,1,8),t.id('main'),'in','cash',p_principal+p_profit,v_customer,v_cash,t.today()-p_days_ago,v_key) RETURNING id INTO v_pay;
  INSERT INTO public.payment_allocations(organization_id,payment_id,amount,schedule_line_id,contract_id,principal_amount,profit_amount)
    VALUES(t.org('a'),v_pay,p_principal+p_profit,t.id('line-'||p_line),v_contract,p_principal,p_profit);
END $$;
-- A contract whose credit check runs now ("commit time"), optionally using an approved exception for it.
-- A failure raises; a contract that passes stays (without schedule lines it adds no exposure).
CREATE FUNCTION t.trg(p_tag text,p_customer text,p_financed numeric,p_migrated boolean,p_approval text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  SET CONSTRAINTS trg_contracts_credit_check DEFERRED;
  PERFORM t.contract(p_tag,p_customer,p_financed,'active',p_migrated);
  IF p_approval IS NOT NULL THEN PERFORM app.use_credit_approval(t.id(p_approval),t.id('contract-'||p_tag)); END IF;
  SET CONSTRAINTS trg_contracts_credit_check IMMEDIATE;
  SET CONSTRAINTS trg_contracts_credit_check DEFERRED;
END $$;
-- Ages a decided approval by editing its decision time (the freeze trigger is off for that one statement).
CREATE FUNCTION t.age(p_approval text,p_hours numeric) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.approvals DISABLE TRIGGER trg_approvals_final;
  UPDATE public.approvals SET decided_at=now()-make_interval(secs=>(p_hours*3600)::int) WHERE id=t.id(p_approval);
  ALTER TABLE public.approvals ENABLE TRIGGER trg_approvals_final;
END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a, b (retail), c (starter: no customers module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('R03 '||s,'r03-'||s,p,'Owner',s||'r03@example.com',NULL,'Main',h,now()+interval '1 day')
FROM (VALUES('a','retail',repeat('x',64)),('b','retail',repeat('y',64)),('c','starter',repeat('z',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0730000-0000-0000-8000-000000000001','ar03@example.com'),('a0730000-0000-0000-8000-000000000002','br03@example.com'),
  ('a0730000-0000-0000-8000-000000000003','r03cashier@example.com'),('a0730000-0000-0000-8000-000000000004','r03manager@example.com'),
  ('a0730000-0000-0000-8000-000000000005','r03collector@example.com'),('a0730000-0000-0000-8000-000000000006','r03warehouse@example.com'),
  ('a0730000-0000-0000-8000-000000000008','cr03@example.com');
SELECT public.accept_invite(repeat('x',64),'a0730000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a0730000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('z',64),'a0730000-0000-0000-8000-000000000008');
-- Cashier: sale.create and customer.create, no credit.approve. Manager: credit.approve and sale.create, not the owner.
-- Collector: a read key only. Warehouse: no read key.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES
  (t.org('a'),'a0730000-0000-0000-8000-000000000003','R03 Cashier','CASHIER'),
  (t.org('a'),'a0730000-0000-0000-8000-000000000004','R03 Manager','BRANCH_MANAGER'),
  (t.org('a'),'a0730000-0000-0000-8000-000000000005','R03 Collector','COLLECTOR'),
  (t.org('a'),'a0730000-0000-0000-8000-000000000006','R03 Warehouse','WAREHOUSE');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1;
UPDATE public.org_settings SET credit_limit_income_multiple=3 WHERE organization_id=t.org('a');
WITH x AS (INSERT INTO public.customers(organization_id,full_name,monthly_income,credit_limit) VALUES(t.org('b'),'Shop B Customer',5000,1000) RETURNING id) INSERT INTO t.ids SELECT 'b-early',id FROM x;

-- ---------------------------------------------------------------- the rows the tests share (as the database owner)
-- exp: limit 20 000, exposure 14 000 (2 000 of 16 000 principal paid), score 75 (2 guarantors, income, valid ID)
SELECT t.cust('exp','Exposure Customer',8000,20000,'active',1);
SELECT t.guar('exp',1); SELECT t.guar('exp',2);
SELECT t.contract('x1','exp',11000,'active',true);
SELECT t.line('x1a','x1',1,10,5000,500); SELECT t.line('x1b','x1',2,40,5000,500); SELECT t.line('x1s','x1',3,5,4000,0,true);
SELECT t.pay('x1a',2000,0,1);
SELECT t.contract('x2','exp',6000,'active',true);
SELECT t.line('x2a','x2',1,20,6000,600);
SELECT t.contract('x3','exp',3000,'completed',true);
SELECT t.line('x3a','x3',1,-60,3000,0);
SELECT t.pay('x3a',3000,0,61);
-- resch: a rescheduled contract counts, a written-off one does not
SELECT t.cust('resch','Rescheduled Customer',NULL,20000,'active',2);
SELECT t.contract('r1','resch',1000,'rescheduled',true); SELECT t.line('r1a','r1',1,15,1000,20);
SELECT t.contract('w1','resch',2000,'written_off',true); SELECT t.line('w1a','w1',1,15,2000,40);
-- scores
SELECT t.cust('s80','Score 80',8000,0,'active',3); SELECT t.photo('s80'); SELECT t.guar('s80',3); SELECT t.guar('s80',4);
SELECT t.cust('s40','Score 40',8000,50000,'active',4); SELECT t.photo('s40');
SELECT t.cust('s20','Score 20',NULL,0,'active',NULL); SELECT t.guar('s20',5);
SELECT t.cust('s0','Score 0',NULL,0,'active',NULL);
SELECT t.cust('s3g','Three Guarantors',8000,0,'active',6); SELECT t.photo('s3g'); SELECT t.guar('s3g',6); SELECT t.guar('s3g',7); SELECT t.guar('s3g',8);
SELECT t.cust('sbadid','Bad ID',8000,0,'active',NULL); SELECT t.photo('sbadid');
UPDATE public.customers SET national_id='49001010100015' WHERE id=t.id('sbadid');
SELECT t.cust('s1g','One Guarantor',8000,0,'active',NULL); SELECT t.guar('s1g',9);
-- behaviour
SELECT t.cust('beh','Behaviour One',NULL,0,'active',NULL);
SELECT t.contract('b1','beh',3000,'active',true);
SELECT t.line('b1a','b1',1,-40,900,100); SELECT t.line('b1b','b1',2,-30,900,100); SELECT t.line('b1c','b1',3,-10,900,100); SELECT t.line('b1d','b1',4,20,900,100);
SELECT t.pay('b1a',900,100,41); SELECT t.pay('b1b',900,100,25);
SELECT t.cust('beh2','Behaviour Two',NULL,0,'active',NULL);
SELECT t.contract('c1','beh2',2000,'active',true);
SELECT t.line('c1a','c1',1,-20,900,100); SELECT t.line('c1b','c1',2,-10,900,100); SELECT t.line('c1s','c1',3,-100,900,100,true);
SELECT t.pay('c1a',450,50,25); SELECT t.pay('c1a',450,50,17); SELECT t.pay('c1b',900,100,10);
SELECT t.contract('c2','beh2',1000,'completed',true); SELECT t.line('c2a','c2',1,-90,900,100); SELECT t.pay('c2a',900,100,91);
SELECT t.cust('nocontracts','No Contracts',NULL,0,'active',NULL);
-- the check
SELECT t.cust('watch','Watch Customer',8000,50000,'watch',10); SELECT t.guar('watch',10); SELECT t.guar('watch',11);
SELECT t.cust('blocked','Blocked Customer',8000,50000,'blocked',11); SELECT t.guar('blocked',12); SELECT t.guar('blocked',13);
SELECT t.cust('archived','Archived Customer',8000,50000,'active',12); SELECT t.guar('archived',14); SELECT t.guar('archived',15);
UPDATE public.customers SET archived_at=now() WHERE id=t.id('archived');
SELECT t.cust('trg','Trigger Customer',NULL,20000,'active',NULL);
SELECT t.contract('t0','trg',14000,'active',true); SELECT t.line('t0a','t0',1,30,14000,0);
SELECT t.cust('trgblocked','Trigger Blocked',NULL,20000,'blocked',NULL);

-- ================================================================ pure helpers (as the database owner)
SELECT t.expect('exposure: 16 000 principal on two open contracts, 2 000 paid, a completed one and a superseded line ignored',app.customer_exposure(t.org('a'),t.id('exp'))=14000.00);
SELECT t.expect('exposure: without one contract, that contract''s share is left out',app.customer_exposure(t.org('a'),t.id('exp'),t.id('contract-x2'))=8000.00);
SELECT t.expect('exposure: a rescheduled contract counts, a written-off one does not',app.customer_exposure(t.org('a'),t.id('resch'))=1000.00);
SELECT t.expect('exposure: a customer without contracts owes nothing',app.customer_exposure(t.org('a'),t.id('nocontracts'))=0);
SELECT t.expect('exposure: the same number as the baseline view',(SELECT exposure FROM public.v_customer_exposure WHERE customer_id=t.id('exp'))=app.customer_exposure(t.org('a'),t.id('exp')));
SELECT t.expect('exposure: another shop sees nothing of it',app.customer_exposure(t.org('b'),t.id('exp'))=0);
SELECT t.expect('suggested limit: income 8 000 x multiple 3',app.customer_suggested_limit(t.org('a'),t.id('s80'))=24000);
SELECT t.expect('suggested limit: no income gives null',app.customer_suggested_limit(t.org('a'),t.id('s20')) IS NULL);
UPDATE public.org_settings SET credit_limit_income_multiple=NULL WHERE organization_id=t.org('a');
SELECT t.expect('suggested limit: no multiple gives null',app.customer_suggested_limit(t.org('a'),t.id('s80')) IS NULL);
UPDATE public.org_settings SET credit_limit_income_multiple=2.5 WHERE organization_id=t.org('a');
UPDATE public.customers SET monthly_income=8000.50 WHERE id=t.id('s80');
SELECT t.expect('suggested limit: rounded down to the pound (8 000.50 x 2.5 = 20 001.25)',app.customer_suggested_limit(t.org('a'),t.id('s80'))=20001);
UPDATE public.customers SET monthly_income=8000 WHERE id=t.id('s80');
UPDATE public.org_settings SET credit_limit_income_multiple=3 WHERE organization_id=t.org('a');

-- score
SELECT t.expect('score: 2 guarantors + income + ID + photo = 80',(app.customer_credit_score(t.org('a'),t.id('s80'))->>'score')='80',app.customer_credit_score(t.org('a'),t.id('s80'))::text);
SELECT t.expect('score: the four components with their weights, in order',
  (SELECT string_agg(c->>'key'||':'||(c->>'weight')::numeric::int||':'||trim_scale((c->>'value')::numeric)||':'||(c->>'points')::numeric::int,',' ORDER BY o)
   FROM jsonb_array_elements(app.customer_credit_score(t.org('a'),t.id('s80'))->'components') WITH ORDINALITY x(c,o))='guarantors:40:1:40,income:30:1:30,residence:20:0:0,identity:10:1:10');
SELECT t.expect('score: min score is the shop''s (50)',(app.customer_credit_score(t.org('a'),t.id('s80'))->>'min_score')='50');
SELECT t.expect('score: no guarantors = 40',(app.customer_credit_score(t.org('a'),t.id('s40'))->>'score')='40');
SELECT t.expect('score: one guarantor is half of the guarantor weight (20)',(app.customer_credit_score(t.org('a'),t.id('s20'))->>'score')='20');
SELECT t.expect('score: three guarantors are capped like two (80)',(app.customer_credit_score(t.org('a'),t.id('s3g'))->>'score')='80');
SELECT t.expect('score: nothing at all = 0',(app.customer_credit_score(t.org('a'),t.id('s0'))->>'score')='0');
SELECT t.expect('score: an invalid national ID gives no identity credit, the photo still half (30 + 5)',(app.customer_credit_score(t.org('a'),t.id('sbadid'))->>'score')='35');
SELECT t.expect('score: a photo of another entity type is not an ID photo',
  (SELECT count(*) FROM public.files WHERE organization_id=t.org('a') AND entity_type='customer' AND entity_id=t.id('s0'))=0 AND (app.customer_credit_score(t.org('a'),t.id('s0'))->>'score')='0');
SELECT t.guar('s80',16,true);
SELECT t.expect('score: an archived guarantor does not count (2 + 1 archived = 80, only the two active)',(app.customer_credit_score(t.org('a'),t.id('s80'))->>'score')='80');
UPDATE public.guarantors SET archived_at=now() WHERE id=t.id('guar-4');
SELECT t.expect('score: archiving one of two guarantors drops it to 60',(app.customer_credit_score(t.org('a'),t.id('s80'))->>'score')='60');
UPDATE public.guarantors SET archived_at=NULL WHERE id=t.id('guar-4');
SELECT t.expect('score: another shop''s customer id gives nothing',app.customer_credit_score(t.org('b'),t.id('s80')) IS NULL);

-- behaviour
SELECT t.expect('behaviour: one line on time, one 5 days late, one overdue, one not yet due',
  (b->>'due_lines')::int=3 AND (b->>'on_time_pct')::int=33 AND (b->>'max_days_late')::int=10 AND b->>'current_overdue_amount'='1000.00'
  AND (b->>'overdue_lines')::int=1 AND (b->>'open_contracts')::int=1 AND (b->>'completed_contracts')::int=0,b::text)
FROM (SELECT app.customer_credit_behaviour(t.org('a'),t.id('beh')) b) x;
SELECT t.expect('behaviour: paid in two halves, the last 3 days late = late; paid on the due date = on time; a completed contract counts; a superseded line does not',
  (b->>'due_lines')::int=3 AND (b->>'on_time_pct')::int=67 AND (b->>'max_days_late')::int=3 AND b->>'current_overdue_amount'='0.00'
  AND (b->>'overdue_lines')::int=0 AND (b->>'open_contracts')::int=1 AND (b->>'completed_contracts')::int=1,b::text)
FROM (SELECT app.customer_credit_behaviour(t.org('a'),t.id('beh2')) b) x;
SELECT t.expect('behaviour: a customer with no contracts has nulls and zeros',
  (b->>'due_lines')::int=0 AND b->'on_time_pct'='null'::jsonb AND b->'max_days_late'='null'::jsonb AND b->>'current_overdue_amount'='0.00'
  AND (b->>'overdue_lines')::int=0 AND (b->>'open_contracts')::int=0 AND (b->>'completed_contracts')::int=0,b::text)
FROM (SELECT app.customer_credit_behaviour(t.org('a'),t.id('nocontracts')) b) x;
SELECT t.expect('behaviour: a line that is not due yet is not counted (exp has one due line, paid on time)',
  (b->>'due_lines')::int=1 AND (b->>'on_time_pct')::int=100 AND (b->>'completed_contracts')::int=1 AND (b->>'open_contracts')::int=2,b::text)
FROM (SELECT app.customer_credit_behaviour(t.org('a'),t.id('exp')) b) x;

-- ================================================================ approvals constraint and freeze trigger
SELECT t.errlike('constraint: another kind of approval still can not be decided by its requester',
  format($q$INSERT INTO public.approvals(organization_id,kind,entity_type,status,requested_by,decided_by,decided_at) SELECT %L,'purchase_invoice','x','approved',id,id,now() FROM public.employees WHERE organization_id=%L LIMIT 1$q$,t.org('a'),t.org('a')),
  '%approvals_no_self_approval%');
SELECT t.expect('constraint: the old one is gone and the new one names credit_exception',
  NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.approvals'::regclass AND conname='approvals_check1')
  AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.approvals'::regclass AND conname='approvals_no_self_approval' AND pg_get_constraintdef(oid) LIKE '%credit_exception%'));

-- ================================================================ the limit (owner)
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'lim',(public.create_customer('{"full_name":"Limit Customer","phones":["01100000031"],"monthly_income":"8000"}')->>'id')::uuid;
SELECT t.expect('profile: a new customer has limit 0, nothing owed, nothing available, suggested = income x multiple',
  p->>'credit_limit'='0.00' AND p->>'exposure'='0.00' AND p->>'available'='0.00' AND p->>'over_limit_by'='0.00'
  AND p->>'suggested_limit'='24000.00' AND p->>'status'='active' AND p->>'store_credit'='0.00' AND p->'limit_history'='[]'::jsonb,p::text)
FROM (SELECT public.get_customer_credit_profile(t.id('lim')) p) x;
SELECT t.error('limit: raising needs a reason',format('SELECT public.set_customer_credit_limit(%L,%L,NULL)',t.id('lim'),'15000.00'),'CREDIT_REASON_REQUIRED');
SELECT t.error('limit: a two-letter reason is too short',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'15000.00','ok'),'CREDIT_REASON_REQUIRED');
SELECT t.error('limit: a blank reason is no reason',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'15000.00','    '),'CREDIT_REASON_REQUIRED');
SELECT t.error('limit: a reason over 300',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'15000.00',repeat('r',301)),'VALIDATION_FAILED');
SELECT t.error('limit: negative',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'-5.00','Reason'),'VALIDATION_FAILED');
SELECT t.error('limit: over 99 999 999.99',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'100000000.00','Reason'),'VALIDATION_FAILED');
SELECT t.error('limit: three decimals',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'10.123','Reason'),'VALIDATION_FAILED');
SELECT t.error('limit: not a number',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'abc','Reason'),'VALIDATION_FAILED');
SELECT t.error('limit: null',format('SELECT public.set_customer_credit_limit(%L,NULL,%L)',t.id('lim'),'Reason'),'VALIDATION_FAILED');
SELECT t.expect('limit: nothing changed by the refusals',(public.get_customer_credit_profile(t.id('lim'))->>'credit_limit')='0.00');
SELECT t.expect('limit: the same value (0) is no change',(public.set_customer_credit_limit(t.id('lim'),'0','x')->>'credit_limit')='0.00' AND t.audits('customer.credit_limit_set','lim')=0);
SELECT t.expect('limit: raised to 15 000 with a reason; the profile answers',
  p->>'credit_limit'='15000.00' AND p->>'available'='15000.00' AND jsonb_array_length(p->'limit_history')=1,p::text)
FROM (SELECT public.set_customer_credit_limit(t.id('lim'),'15000.00','  Good payer  ') p) x;
SELECT t.expect('limit: lowering needs no reason',(public.set_customer_credit_limit(t.id('lim'),'12000',NULL)->>'credit_limit')='12000.00');
SELECT t.expect('limit: the same value again changes nothing and writes no audit row',
  (public.set_customer_credit_limit(t.id('lim'),'12000.00','Again')->>'credit_limit')='12000.00');
SELECT t.expect('limit: the maximum is allowed',(public.set_customer_credit_limit(t.id('lim'),'99999999.99','Top')->>'credit_limit')='99999999.99');
SELECT t.expect('history: newest first, from / to / who / reason',
  (SELECT string_agg(h->>'from'||'>'||(h->>'to')||'>'||COALESCE(h->>'by_name','-')||'>'||COALESCE(h->>'reason','-'),' | ' ORDER BY o)
   FROM jsonb_array_elements(public.get_customer_credit_profile(t.id('lim'))->'limit_history') WITH ORDINALITY x(h,o))
  ='12000.00>99999999.99>Owner>Top | 15000.00>12000.00>Owner>- | 0.00>15000.00>Owner>Good payer');
SELECT public.set_customer_credit_limit(t.id('lim'),'1000.00',NULL);
SELECT public.set_customer_credit_limit(t.id('lim'),'2000.00','Step 2');
SELECT public.set_customer_credit_limit(t.id('lim'),'3000.00','Step 3');
SELECT public.set_customer_credit_limit(t.id('lim'),'4000.00','Step 4');
SELECT public.set_customer_credit_limit(t.id('lim'),'5000.00','Step 5');
SELECT public.set_customer_credit_limit(t.id('lim'),'6000.00','Step 6');
SELECT public.set_customer_credit_limit(t.id('lim'),'7000.00','Step 7');
SELECT public.set_customer_credit_limit(t.id('lim'),'8000.00','Step 8');
SELECT t.expect('history: only the last 10, newest first',
  jsonb_array_length(h)=10 AND h->0->>'to'='8000.00' AND h->9->>'to'='12000.00',h::text)
FROM (SELECT public.get_customer_credit_profile(t.id('lim'))->'limit_history' h) x;
-- an archived customer
RESET ROLE;
UPDATE public.customers SET archived_at=now() WHERE id=t.id('lim');
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('limit: an archived customer is refused',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('lim'),'9000.00','Reason'),'CUSTOMER_BLOCKED');
SELECT t.expect('limit: an archived customer is still readable',(public.get_customer_credit_profile(t.id('lim'))->>'credit_limit')='8000.00');
RESET ROLE;
UPDATE public.customers SET archived_at=NULL WHERE id=t.id('lim');
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('limit: update_customer still refuses credit_limit',format('SELECT public.update_customer(%L,%L)',t.id('lim'),'{"credit_limit":"5000.00"}'),'VALIDATION_FAILED');
SELECT t.error('limit: a customer that does not exist',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',gen_random_uuid(),'100.00','Reason'),'CUSTOMER_NOT_FOUND');
SELECT t.error('limit: another shop''s customer',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('b-early'),'100.00','Reason'),'CUSTOMER_NOT_FOUND');
SELECT t.error('profile: another shop''s customer',format('SELECT public.get_customer_credit_profile(%L)',t.id('b-early')),'CUSTOMER_NOT_FOUND');
-- the profile of the exposure customer
SELECT t.expect('profile: limit 20 000, exposure 14 000, available 6 000, no excess, score 75, min 50',
  p->>'credit_limit'='20000.00' AND p->>'exposure'='14000.00' AND p->>'available'='6000.00' AND p->>'over_limit_by'='0.00'
  AND (p->>'score')::int=75 AND (p->>'min_score')::int=50 AND jsonb_array_length(p->'components')=4 AND p->'components'->0->>'key'='guarantors'
  AND p->>'suggested_limit'='24000.00',p::text)
FROM (SELECT public.get_customer_credit_profile(t.id('exp')) p) x;
SELECT t.expect('profile: the behaviour block rides along',(public.get_customer_credit_profile(t.id('exp'))->'behaviour'->>'open_contracts')='2');
-- lowering below the exposure is allowed; the profile then shows the excess
SELECT t.expect('limit: below the exposure is allowed; available 0 and the excess shown',
  p->>'credit_limit'='10000.00' AND p->>'available'='0.00' AND p->>'over_limit_by'='4000.00' AND p->>'exposure'='14000.00',p::text)
FROM (SELECT public.set_customer_credit_limit(t.id('exp'),'10000.00','Slowing down') p) x;
SELECT t.expect('limit: raised back to 20 000',(public.set_customer_credit_limit(t.id('exp'),'20000.00','Paid down')->>'available')='6000.00');
RESET ROLE;
SELECT t.expect('limit: audit rows hold before / after and the reason, warnings when raising',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='customer.credit_limit_set' AND entity_type='customer' AND entity_id=t.id('lim'))=11
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.credit_limit_set' AND entity_id=t.id('lim') AND severity='warning' AND reason='Good payer' AND before->>'credit_limit'='0.00' AND after->>'credit_limit'='15000.00')
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='customer.credit_limit_set' AND entity_id=t.id('lim') AND severity='info' AND reason IS NULL AND before->>'credit_limit'='15000.00' AND after->>'credit_limit'='12000.00'),
  (SELECT count(*)::text FROM public.audit_log WHERE action='customer.credit_limit_set' AND entity_id=t.id('lim')));

-- ================================================================ the limit: who
SELECT t.as_user('a0730000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('limit: a manager (credit.approve) can set it',(public.set_customer_credit_limit(t.id('s0'),'1000.00','First limit')->>'credit_limit')='1000.00');
RESET ROLE;
SELECT t.as_user('a0730000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('limit: a cashier can not',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('s0'),'5000.00','Reason'),'PERMISSION_DENIED');
SELECT t.expect('profile: a cashier (customer.create) can read it',(public.get_customer_credit_profile(t.id('exp'))->>'credit_limit')='20000.00');
RESET ROLE;
SELECT t.as_user('a0730000-0000-0000-8000-000000000005',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('limit: a collector can not',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('s0'),'5000.00','Reason'),'PERMISSION_DENIED');
SELECT t.expect('profile: a collector (collection.create) can read it',(public.get_customer_credit_profile(t.id('exp'))->>'credit_limit')='20000.00');
RESET ROLE;
SELECT t.as_user('a0730000-0000-0000-8000-000000000006',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('limit: a warehouse user can not',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('s0'),'5000.00','Reason'),'PERMISSION_DENIED');
SELECT t.error('profile: a warehouse user can not read',format('SELECT public.get_customer_credit_profile(%L)',t.id('exp')),'PERMISSION_DENIED');
SELECT t.error('check: a warehouse user can not read it',format('SELECT public.get_customer_credit_check(%L,%L)',t.id('exp'),'100.00'),'PERMISSION_DENIED');
SELECT t.error('exception: a warehouse user can not read one',format('SELECT public.get_credit_exception(%L)',gen_random_uuid()),'PERMISSION_DENIED');
SELECT t.error('exception: a warehouse user can not list them','SELECT public.list_credit_exceptions()','PERMISSION_DENIED');
SELECT t.error('exception: a warehouse user can not ask for one',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'8000.00','Reason'),'PERMISSION_DENIED');
RESET ROLE;

-- ================================================================ the check (as the database owner: the helpers are not granted)
SELECT t.expect('check: financed 6 000.00 on limit 20 000 with 14 000 owed passes (null)',app.check_customer_credit(t.org('a'),t.id('exp'),6000.00,NULL) IS NULL);
SELECT t.error('check: 6 000.01 is over (Done when)',format('SELECT app.check_customer_credit(%L,%L,6000.01,NULL)',t.org('a'),t.id('exp')),'CREDIT_LIMIT_EXCEEDED');
SELECT t.expect('check: the error carries limit, exposure, available, requested, score, min_score and the reasons',
  d::jsonb=jsonb_build_object('limit','20000.00','exposure','14000.00','available','6000.00','requested','6000.01','score',75,'min_score',50,'reasons',jsonb_build_array('limit')),d)
FROM (SELECT t.detail(format('SELECT app.check_customer_credit(%L,%L,6000.01,NULL)',t.org('a'),t.id('exp'))) d) x;
SELECT t.error('check: no amount',format('SELECT app.check_customer_credit(%L,%L,NULL,NULL)',t.org('a'),t.id('exp')),'VALIDATION_FAILED');
SELECT t.error('check: a zero amount',format('SELECT app.check_customer_credit(%L,%L,0,NULL)',t.org('a'),t.id('exp')),'VALIDATION_FAILED');
SELECT t.error('check: another shop''s customer',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('b'),t.id('exp')),'CUSTOMER_NOT_FOUND');
SELECT t.error('check: a customer that does not exist',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),gen_random_uuid()),'CUSTOMER_NOT_FOUND');
SELECT t.error('check: a blocked customer',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('blocked')),'CUSTOMER_BLOCKED');
SELECT t.error('check: an archived customer',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('archived')),'CUSTOMER_BLOCKED');
SELECT t.error('check: a watch customer needs an exception even within the limit',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('watch')),'CREDIT_CUSTOMER_WATCH');
SELECT t.expect('check: the watch error names the reason',(t.detail(format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('watch')))::jsonb->'reasons')='["watch"]'::jsonb);
SELECT t.error('check: a score below the minimum (40 < 50)',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('s40')),'CREDIT_SCORE_TOO_LOW');
SELECT t.expect('check: the score error names the reason',(t.detail(format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('s40')))::jsonb->'reasons')='["score"]'::jsonb);
SELECT t.error('check: limit and score together raise the limit error, with both reasons',format('SELECT app.check_customer_credit(%L,%L,60000,NULL)',t.org('a'),t.id('s40')),'CREDIT_LIMIT_EXCEEDED');
SELECT t.expect('check: both reasons are listed',(t.detail(format('SELECT app.check_customer_credit(%L,%L,60000,NULL)',t.org('a'),t.id('s40')))::jsonb->'reasons')='["limit","score"]'::jsonb);
SELECT t.expect('check: a customer with limit 0 has nothing available (a new customer needs an exception)',
  (t.detail(format('SELECT app.check_customer_credit(%L,%L,1,NULL)',t.org('a'),t.id('nocontracts')))::jsonb->>'available')='0.00');
UPDATE public.org_settings SET credit_min_score=80 WHERE organization_id=t.org('a');
SELECT t.error('check: the shop''s own minimum score is used (75 < 80)',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('exp')),'CREDIT_SCORE_TOO_LOW');
UPDATE public.org_settings SET credit_min_score=50 WHERE organization_id=t.org('a');

-- ================================================================ exceptions: request, decide, cancel
SELECT t.as_user('a0730000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('request: a reason is required',format('SELECT public.request_credit_exception(%L,%L,NULL)',t.id('exp'),'8000.00'),'CREDIT_REASON_REQUIRED');
SELECT t.error('request: a two-letter reason',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'8000.00','ab'),'CREDIT_REASON_REQUIRED');
SELECT t.error('request: a reason over 300',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'8000.00',repeat('r',301)),'VALIDATION_FAILED');
SELECT t.error('request: a zero amount',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'0.00','Reason'),'VALIDATION_FAILED');
SELECT t.error('request: a negative amount',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'-1.00','Reason'),'VALIDATION_FAILED');
SELECT t.error('request: three decimals',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'8000.001','Reason'),'VALIDATION_FAILED');
SELECT t.error('request: an amount that passes anyway needs no exception',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'5000.00','Reason'),'APPROVAL_NOT_NEEDED');
SELECT t.error('request: a blocked customer can not be excepted',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('blocked'),'1000.00','Reason'),'CUSTOMER_BLOCKED');
SELECT t.error('request: an archived customer can not be excepted',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('archived'),'1000.00','Reason'),'CUSTOMER_BLOCKED');
SELECT t.error('request: another shop''s customer',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('b-early'),'1000.00','Reason'),'CUSTOMER_NOT_FOUND');
SELECT t.expect('preview: before any request, 8 000 is not allowed and needs approval; nothing pending',
  c->>'allowed'='false' AND c->>'needs_approval'='true' AND c->'reasons'='["limit"]'::jsonb AND c->>'limit'='20000.00' AND c->>'exposure'='14000.00'
  AND c->>'available'='6000.00' AND (c->>'score')::int=75 AND (c->>'min_score')::int=50 AND c->'pending_approval_id'='null'::jsonb AND c->'approved_approval_id'='null'::jsonb,c::text)
FROM (SELECT public.get_customer_credit_check(t.id('exp'),'8000.00') c) x;
SELECT t.expect('preview: 6 000.00 is allowed and needs nothing',
  c->>'allowed'='true' AND c->>'needs_approval'='false' AND c->'reasons'='[]'::jsonb,c::text)
FROM (SELECT public.get_customer_credit_check(t.id('exp'),'6000.00') c) x;
INSERT INTO t.ids SELECT 'ex1',(public.request_credit_exception(t.id('exp'),'8000.00','  New fridge for a regular  ')->>'id')::uuid;
SELECT t.expect('request: pending, with the snapshot of the moment, the reasons and who asked',
  e->>'status'='pending' AND e->>'financed_amount'='8000.00' AND e->'reasons'='["limit"]'::jsonb AND e->>'reason'='New fridge for a regular'
  AND e->>'customer_name'='Exposure Customer' AND (e->>'customer_id')::uuid=t.id('exp') AND e->>'requested_by_name'='R03 Cashier' AND e->>'mine'='true'
  AND e->'snapshot'=jsonb_build_object('limit','20000.00','exposure','14000.00','available','6000.00','score',75,'min_score',50)
  AND e->'decided_at'='null'::jsonb AND e->'expires_at'='null'::jsonb AND e->>'used'='false',e::text)
FROM (SELECT public.get_credit_exception(t.id('ex1')) e) x;
SELECT t.expect('preview: the pending request shows for an amount it covers (7 000), not for one it does not (9 000)',
  (public.get_customer_credit_check(t.id('exp'),'7000.00')->>'pending_approval_id')=t.id('ex1')::text
  AND public.get_customer_credit_check(t.id('exp'),'9000.00')->'pending_approval_id'='null'::jsonb);
SELECT t.error('decide: a cashier can not decide',format('SELECT public.decide_credit_exception(%L,true,NULL)',t.id('ex1')),'PERMISSION_DENIED');
SELECT t.error('decide: a cashier can not decide even their own request',format('SELECT public.decide_credit_exception(%L,false,%L)',t.id('ex1'),'Self'),'PERMISSION_DENIED');
INSERT INTO t.ids SELECT 'ex2',(public.request_credit_exception(t.id('exp'),'9000.00','Second ask')->>'id')::uuid;
INSERT INTO t.ids SELECT 'ex3',(public.request_credit_exception(t.id('exp'),'9500.00','Third ask, to be cancelled')->>'id')::uuid;
INSERT INTO t.ids SELECT 'ex4',(public.request_credit_exception(t.id('watch'),'1000.00','Watch customer, small amount')->>'id')::uuid;
SELECT t.expect('request: a watch customer can be excepted (reason watch)',(public.get_credit_exception(t.id('ex4'))->'reasons')='["watch"]'::jsonb);
INSERT INTO t.ids SELECT 'ex5',(public.request_credit_exception(t.id('s40'),'1000.00','Low score, small amount')->>'id')::uuid;
SELECT t.expect('request: a low-score customer can be excepted (reason score)',(public.get_credit_exception(t.id('ex5'))->'reasons')='["score"]'::jsonb);
INSERT INTO t.ids SELECT 'ex6',(public.request_credit_exception(t.id('trg'),'8000.00','Trigger customer, first')->>'id')::uuid;
INSERT INTO t.ids SELECT 'ex7',(public.request_credit_exception(t.id('trg'),'7000.00','Trigger customer, second')->>'id')::uuid;
INSERT INTO t.ids SELECT 'ex8',(public.request_credit_exception(t.id('trg'),'9000.00','Trigger customer, third')->>'id')::uuid;
SELECT t.expect('cancel: the requester takes a pending request back',(public.cancel_credit_exception(t.id('ex3'))->>'status')='cancelled');
SELECT t.error('cancel: a cancelled request can not be cancelled again',format('SELECT public.cancel_credit_exception(%L)',t.id('ex3')),'APPROVAL_NOT_PENDING');
RESET ROLE;
SELECT t.as_user('a0730000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('cancel: someone else can not cancel it (not found)',format('SELECT public.cancel_credit_exception(%L)',t.id('ex1')),'APPROVAL_NOT_FOUND');
SELECT t.error('decide: a cancelled request can not be decided',format('SELECT public.decide_credit_exception(%L,true,NULL)',t.id('ex3')),'APPROVAL_NOT_PENDING');
SELECT t.error('decide: rejecting needs a note',format('SELECT public.decide_credit_exception(%L,false,NULL)',t.id('ex2')),'APPROVAL_NOTE_REQUIRED');
SELECT t.error('decide: a blank note is no note',format('SELECT public.decide_credit_exception(%L,false,%L)',t.id('ex2'),'   '),'APPROVAL_NOTE_REQUIRED');
SELECT t.error('decide: a note over 500',format('SELECT public.decide_credit_exception(%L,false,%L)',t.id('ex2'),repeat('n',501)),'VALIDATION_FAILED');
SELECT t.error('decide: approve is required',format('SELECT public.decide_credit_exception(%L,NULL,NULL)',t.id('ex2')),'VALIDATION_FAILED');
SELECT t.error('decide: an approval that does not exist',format('SELECT public.decide_credit_exception(%L,true,NULL)',gen_random_uuid()),'APPROVAL_NOT_FOUND');
SELECT t.expect('decide: a manager rejects with a note',(public.decide_credit_exception(t.id('ex2'),false,'Too much for this customer')->>'status')='rejected');
SELECT t.expect('decide: the manager approves the first request; it is valid for 24 hours and not used',
  e->>'status'='approved' AND e->>'decided_by_name'='R03 Manager' AND e->>'used'='false' AND e->>'mine'='false'
  AND (e->>'expires_at')::timestamptz=(e->>'decided_at')::timestamptz+interval '24 hours',e::text)
FROM (SELECT public.decide_credit_exception(t.id('ex1'),true,'  Known customer  ') e) x;
SELECT t.expect('preview: with the exception approved, 7 000 is allowed through it and shows its id',
  c->>'allowed'='true' AND c->>'needs_approval'='false' AND c->>'approved_approval_id'=t.id('ex1')::text AND c->'reasons'='["limit"]'::jsonb,c::text)
FROM (SELECT public.get_customer_credit_check(t.id('exp'),'7000.00') c) x;
SELECT t.expect('preview: 9 000 is above what the exception covers (8 000) and still needs approval',
  c->>'allowed'='false' AND c->>'needs_approval'='true' AND c->'approved_approval_id'='null'::jsonb,c::text)
FROM (SELECT public.get_customer_credit_check(t.id('exp'),'9000.00') c) x;
SELECT t.error('decide: a decided request can not be decided again',format('SELECT public.decide_credit_exception(%L,false,%L)',t.id('ex1'),'Changed my mind'),'APPROVAL_NOT_PENDING');
SELECT t.error('decide: a rejected request can not be approved',format('SELECT public.decide_credit_exception(%L,true,NULL)',t.id('ex2')),'APPROVAL_NOT_PENDING');
SELECT public.decide_credit_exception(t.id('ex4'),true,NULL);
SELECT public.decide_credit_exception(t.id('ex5'),true,NULL);
SELECT public.decide_credit_exception(t.id('ex6'),true,NULL);
SELECT public.decide_credit_exception(t.id('ex7'),true,NULL);
SELECT public.decide_credit_exception(t.id('ex8'),true,NULL);
-- the manager's own request: a manager can not decide it, the owner can decide the owner's own
INSERT INTO t.ids SELECT 'ex-mgr',(public.request_credit_exception(t.id('exp'),'8000.00','Manager''s own sale')->>'id')::uuid;
SELECT t.error('decide: a manager can not decide their own request',format('SELECT public.decide_credit_exception(%L,true,NULL)',t.id('ex-mgr')),'APPROVAL_SELF');
SELECT t.expect('cancel: a manager may cancel their own request',(public.cancel_credit_exception(t.id('ex-mgr'))->>'status')='cancelled');
SELECT t.error('cancel: a manager can not cancel the cashier''s decided request (not found, only the requester)',format('SELECT public.cancel_credit_exception(%L)',t.id('ex1')),'APPROVAL_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'ex-own',(public.request_credit_exception(t.id('exp'),'7500.00','Owner sells on credit')->>'id')::uuid;
SELECT t.expect('decide: the OWNER may decide their own request (one-person shop)',(public.decide_credit_exception(t.id('ex-own'),true,NULL)->>'status')='approved');
SELECT t.error('cancel: the requester can not cancel once it is decided',format('SELECT public.cancel_credit_exception(%L)',t.id('ex-own')),'APPROVAL_NOT_PENDING');
SELECT t.expect('decide: the owner''s own approval is a normal approved row (decided by the requester)',
  EXISTS(SELECT 1 FROM public.approvals WHERE id=t.id('ex-own') AND status='approved' AND decided_by=requested_by));
SELECT t.expect('list: nothing is pending now, so the default list is empty',jsonb_array_length(public.list_credit_exceptions()->'items')=0);
INSERT INTO t.ids SELECT 'ex-pending',(public.request_credit_exception(t.id('exp'),'12000.00','Pending for the list')->>'id')::uuid;
SELECT t.expect('list: a new pending request comes first even though older rows are decided',
  public.list_credit_exceptions('all')->'items'->0->>'id'=t.id('ex-pending')::text AND public.list_credit_exceptions()->'items'->0->>'id'=t.id('ex-pending')::text);
SELECT t.expect('list: the default list holds only the pending request',jsonb_array_length(public.list_credit_exceptions()->'items')=1);
SELECT t.expect('list: all of them (11 requests in shop a), by status 7 approved, 1 rejected, 2 cancelled, 1 pending',
  jsonb_array_length(public.list_credit_exceptions('all')->'items')=11 AND jsonb_array_length(public.list_credit_exceptions('approved')->'items')=7
  AND jsonb_array_length(public.list_credit_exceptions('rejected')->'items')=1 AND jsonb_array_length(public.list_credit_exceptions('cancelled')->'items')=2
  AND jsonb_array_length(public.list_credit_exceptions('pending')->'items')=1,
  public.list_credit_exceptions('all')::text);
SELECT t.error('list: an unknown status',format('SELECT public.list_credit_exceptions(%L)','bogus'),'VALIDATION_FAILED');
SELECT t.expect('get: any customer reader sees a request (mine is true only for the requester)',
  (public.get_credit_exception(t.id('ex1'))->>'mine')='false' AND (public.get_credit_exception(t.id('ex-own'))->>'mine')='true');
RESET ROLE;
-- an approval of another kind is not a credit exception, and the discount functions don't see these
INSERT INTO public.approvals(organization_id,kind,entity_type,requested_by,branch_id,amount) SELECT t.org('a'),'discount_above_cap','sale',id,t.id('main'),10 FROM public.employees WHERE organization_id=t.org('a') AND role='CASHIER' LIMIT 1;
INSERT INTO t.ids SELECT 'disc',id FROM public.approvals WHERE organization_id=t.org('a') AND kind='discount_above_cap' LIMIT 1;
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('decide: a discount approval is not found by the credit function',format('SELECT public.decide_credit_exception(%L,true,NULL)',t.id('disc')),'APPROVAL_NOT_FOUND');
SELECT t.error('get: a discount approval is not found by the credit function',format('SELECT public.get_credit_exception(%L)',t.id('disc')),'APPROVAL_NOT_FOUND');
SELECT t.error('decide: the discount function does not see a credit exception',format('SELECT public.decide_discount_approval(%L,true,NULL)',t.id('ex-pending')),'APPROVAL_NOT_FOUND');
SELECT t.error('get: the discount read does not see a credit exception',format('SELECT public.get_discount_approval(%L)',t.id('ex-pending')),'APPROVAL_NOT_FOUND');
RESET ROLE;
SELECT t.expect('list: the discount approval is not in the credit list',
  NOT EXISTS(SELECT 1 FROM public.approvals WHERE kind='credit_exception' AND id=t.id('disc')));

-- ================================================================ the check with an exception (as the database owner)
SELECT t.expect('check: an approved exception for 8 000 covers 6 000.01 and the check returns its id',app.check_customer_credit(t.org('a'),t.id('exp'),6000.01,t.id('ex1'))=t.id('ex1'));
SELECT t.expect('check: it covers exactly its amount (8 000.00)',app.check_customer_credit(t.org('a'),t.id('exp'),8000.00,t.id('ex1'))=t.id('ex1'));
SELECT t.error('check: not 8 000.01 (a smaller exception)',format('SELECT app.check_customer_credit(%L,%L,8000.01,%L)',t.org('a'),t.id('exp'),t.id('ex1')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: another customer''s exception',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),t.id('ex4')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: a rejected exception',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),t.id('ex2')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: a cancelled exception',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),t.id('ex3')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: a pending exception',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),t.id('ex-pending')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: an id that is no approval',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),gen_random_uuid()),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: a discount approval is not a credit exception',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),t.id('disc')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: another shop can not use it',format('SELECT app.check_customer_credit(%L,%L,100,%L)',t.org('b'),t.id('b-early'),t.id('ex1')),'CREDIT_APPROVAL_INVALID');
SELECT t.expect('check: a watch customer passes with an approved exception',app.check_customer_credit(t.org('a'),t.id('watch'),1000,t.id('ex4'))=t.id('ex4'));
SELECT t.expect('check: a low-score customer passes with an approved exception',app.check_customer_credit(t.org('a'),t.id('s40'),1000,t.id('ex5'))=t.id('ex5'));
SELECT t.error('check: a blocked customer fails even with an approval',format('SELECT app.check_customer_credit(%L,%L,100,%L)',t.org('a'),t.id('blocked'),t.id('ex4')),'CUSTOMER_BLOCKED');
SELECT t.expect('check: when nothing is needed the approval is ignored (null)',app.check_customer_credit(t.org('a'),t.id('exp'),100,t.id('ex1')) IS NULL);
SELECT t.age('ex1',23);
SELECT t.expect('check: 23 hours after the decision it is still good',app.check_customer_credit(t.org('a'),t.id('exp'),7000,t.id('ex1'))=t.id('ex1'));
SELECT t.age('ex1',25);
SELECT t.error('check: 25 hours after the decision it has expired',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),t.id('ex1')),'CREDIT_APPROVAL_INVALID');
SELECT t.expect('expired: the exception still reads as approved, with its end time in the past',
  (app.credit_exception_json(t.org('a'),t.id('ex1'))->>'status')='approved' AND (app.credit_exception_json(t.org('a'),t.id('ex1'))->>'expires_at')::timestamptz<now());
SELECT t.expect('expired: the preview does not offer it any more',app.credit_exception_usable(t.org('a'),t.id('exp'),8000) IS NULL);
SELECT t.age('ex1',1);
SELECT t.expect('expired: back within 24 hours the preview offers it again',app.credit_exception_usable(t.org('a'),t.id('exp'),8000)=t.id('ex1'));

-- the contract that uses it
SELECT t.contract('u1','exp',7000,'active',true);
SELECT t.error('use: an exception of another customer can not be used for this contract',format('SELECT app.use_credit_approval(%L,%L)',t.id('ex4'),t.id('contract-u1')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('use: a pending exception can not be used',format('SELECT app.use_credit_approval(%L,%L)',t.id('ex-pending'),t.id('contract-u1')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('use: a rejected exception can not be used',format('SELECT app.use_credit_approval(%L,%L)',t.id('ex2'),t.id('contract-u1')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('use: a contract that does not exist',format('SELECT app.use_credit_approval(%L,%L)',t.id('ex1'),gen_random_uuid()),'CREDIT_APPROVAL_INVALID');
SELECT app.use_credit_approval(t.id('ex1'),t.id('contract-u1'));
SELECT t.expect('use: the contract''s id is written once into entity_id and the exception reads as used',
  (SELECT entity_id FROM public.approvals WHERE id=t.id('ex1'))=t.id('contract-u1') AND (SELECT (app.credit_exception_json(t.org('a'),t.id('ex1'))->>'used')='true'));
SELECT t.error('use: a second use is refused',format('SELECT app.use_credit_approval(%L,%L)',t.id('ex1'),t.id('contract-u1')),'CREDIT_APPROVAL_INVALID');
SELECT t.error('check: a used exception is refused',format('SELECT app.check_customer_credit(%L,%L,7000,%L)',t.org('a'),t.id('exp'),t.id('ex1')),'CREDIT_APPROVAL_INVALID');
SELECT t.errlike('freeze: the used exception can not change in any other way',format('UPDATE public.approvals SET amount=1 WHERE id=%L',t.id('ex1')),'DOCUMENT_FINAL%');
SELECT t.errlike('freeze: its contract id can not be written again',format('UPDATE public.approvals SET entity_id=%L WHERE id=%L',gen_random_uuid(),t.id('ex1')),'DOCUMENT_FINAL%');
SELECT t.errlike('freeze: a decided exception can not change its amount',format('UPDATE public.approvals SET amount=1 WHERE id=%L',t.id('ex4')),'DOCUMENT_FINAL%');
SELECT t.errlike('freeze: the entity id and another column together are refused',format('UPDATE public.approvals SET entity_id=%L,amount=1 WHERE id=%L',gen_random_uuid(),t.id('ex4')),'DOCUMENT_FINAL%');
SELECT t.errlike('freeze: a rejected exception can not be used (entity id)',format('UPDATE public.approvals SET entity_id=%L WHERE id=%L',gen_random_uuid(),t.id('ex2')),'DOCUMENT_FINAL%');
SELECT t.errlike('freeze: a cancelled exception can not be approved after the fact',format('UPDATE public.approvals SET status=%L WHERE id=%L','approved',t.id('ex3')),'DOCUMENT_FINAL%');
-- S03's own use of the same trigger still works: an approved discount approval takes its sale id once.
UPDATE public.approvals SET status='approved',decided_by=(SELECT id FROM public.employees WHERE organization_id=t.org('a') AND role='BRANCH_MANAGER' LIMIT 1),decided_at=now() WHERE id=t.id('disc');
UPDATE public.approvals SET entity_id=gen_random_uuid() WHERE id=t.id('disc');
SELECT t.expect('freeze: an approved discount approval takes its sale id once',(SELECT entity_id IS NOT NULL FROM public.approvals WHERE id=t.id('disc')));
SELECT t.errlike('freeze: and not a second time',format('UPDATE public.approvals SET entity_id=%L WHERE id=%L',gen_random_uuid(),t.id('disc')),'DOCUMENT_FINAL%');

-- ================================================================ the safety net: the deferred trigger on contracts
SELECT t.error('trigger: an over-limit contract with no approval fails at commit (Done when)',$q$SELECT t.trg('tc1','trg',6000.01,false,NULL)$q$,'CREDIT_LIMIT_EXCEEDED');
SELECT t.expect('trigger: the error carries the numbers (exposure without the new contract)',
  d::jsonb=jsonb_build_object('limit','20000.00','exposure','14000.00','available','6000.00','requested','6000.01','score',0,'min_score',50,'reasons',jsonb_build_array('limit')),d)
FROM (SELECT t.detail($q$SELECT t.trg('tc1b','trg',6000.01,false,NULL)$q$) d) x;
SELECT t.expect('trigger: the failed contract was not kept',NOT EXISTS(SELECT 1 FROM public.contracts WHERE number IN ('R03-C-tc1','R03-C-tc1b')));
SELECT t.trg('tc2','trg',6000.00,false,NULL);
SELECT t.expect('trigger: within the limit (6 000.00) it commits',EXISTS(SELECT 1 FROM public.contracts WHERE number='R03-C-tc2'));
SELECT t.trg('tc3','trg',90000,true,NULL);
SELECT t.expect('trigger: a migrated (M02) contract is exempt',EXISTS(SELECT 1 FROM public.contracts WHERE number='R03-C-tc3' AND is_migrated));
SELECT t.trg('tc4','trg',8000,false,'ex6');
SELECT t.expect('trigger: over the limit, with an approved exception used for this contract (8 000), it commits',EXISTS(SELECT 1 FROM public.contracts WHERE number='R03-C-tc4'));
SELECT t.error('trigger: the same exception can not be used for a second contract',$q$SELECT t.trg('tc5','trg',7500,false,'ex6')$q$,'CREDIT_APPROVAL_INVALID');
SELECT t.error('trigger: and a second over-limit contract without an exception fails',$q$SELECT t.trg('tc5b','trg',7500,false,NULL)$q$,'CREDIT_LIMIT_EXCEEDED');
SELECT t.error('trigger: an exception for less than the contract (7 000 for 8 000) fails at commit',$q$SELECT t.trg('tc6','trg',8000,false,'ex7')$q$,'CREDIT_LIMIT_EXCEEDED');
SELECT t.trg('tc7','trg',7000,false,'ex8');
SELECT t.expect('trigger: an exception for more than the contract (9 000 for 7 000) commits',EXISTS(SELECT 1 FROM public.contracts WHERE number='R03-C-tc7'));
SELECT t.error('trigger: a blocked customer fails even within the limit',$q$SELECT t.trg('tc8','trgblocked',100,false,NULL)$q$,'CUSTOMER_BLOCKED');
SELECT t.error('trigger: a contract bought against an exception of another customer is not covered',$q$SELECT t.trg('tc9','trg',8000,false,'ex4')$q$,'CREDIT_APPROVAL_INVALID');
SELECT t.expect('trigger: nothing the trigger let through added exposure (no schedule lines)',app.customer_exposure(t.org('a'),t.id('trg'))=14000.00);

-- ================================================================ preview after the exception was used
SELECT t.expect('preview (database owner view): ex6 is used, so no usable approval is shown for 7 500',
  app.credit_exception_usable(t.org('a'),t.id('trg'),7500) IS NULL);

-- ================================================================ tenancy and plan (shop b, shop c)
SELECT t.as_user('a0730000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.error('shop b: reads shop a''s customer profile',format('SELECT public.get_customer_credit_profile(%L)',t.id('exp')),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop b: previews shop a''s customer',format('SELECT public.get_customer_credit_check(%L,%L)',t.id('exp'),'100.00'),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop b: requests an exception for shop a''s customer',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'8000.00','Reason'),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop b: reads shop a''s exception',format('SELECT public.get_credit_exception(%L)',t.id('ex-own')),'APPROVAL_NOT_FOUND');
SELECT t.error('shop b: decides shop a''s exception',format('SELECT public.decide_credit_exception(%L,true,NULL)',t.id('ex-pending')),'APPROVAL_NOT_FOUND');
SELECT t.error('shop b: cancels shop a''s exception',format('SELECT public.cancel_credit_exception(%L)',t.id('ex-pending')),'APPROVAL_NOT_FOUND');
SELECT t.expect('shop b: lists none of shop a''s exceptions',jsonb_array_length(public.list_credit_exceptions('all')->'items')=0);
SELECT t.expect('shop b: its own customer has its own profile (limit 1 000)',(public.get_customer_credit_profile(t.id('b-early'))->>'credit_limit')='1000.00');
RESET ROLE;
SELECT t.as_user('a0730000-0000-0000-8000-000000000008',t.org('c'));
SET LOCAL ROLE authenticated;
SELECT t.error('starter plan: no profile',format('SELECT public.get_customer_credit_profile(%L)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no preview',format('SELECT public.get_customer_credit_check(%L,%L)',gen_random_uuid(),'100.00'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no exception read',format('SELECT public.get_credit_exception(%L)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no exception list','SELECT public.list_credit_exceptions()','MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no limit',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',gen_random_uuid(),'100.00','Reason'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no request',format('SELECT public.request_credit_exception(%L,%L,%L)',gen_random_uuid(),'100.00','Reason'),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no decision',format('SELECT public.decide_credit_exception(%L,true,NULL)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
SELECT t.error('starter plan: no cancel',format('SELECT public.cancel_credit_exception(%L)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
RESET ROLE;
-- An expired shop reads but can't write.
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the profile, the preview, an exception and the list still read',
  (public.get_customer_credit_profile(t.id('exp'))->>'credit_limit')='20000.00' AND public.get_customer_credit_check(t.id('exp'),'100.00') IS NOT NULL
  AND public.get_credit_exception(t.id('ex-own')) IS NOT NULL AND jsonb_array_length(public.list_credit_exceptions('all')->'items')>0);
SELECT t.error('expired shop: no limit',format('SELECT public.set_customer_credit_limit(%L,%L,%L)',t.id('exp'),'30000.00','Reason'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no request',format('SELECT public.request_credit_exception(%L,%L,%L)',t.id('exp'),'12000.00','Reason'),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no decision',format('SELECT public.decide_credit_exception(%L,true,NULL)',t.id('ex-pending')),'SUBSCRIPTION_EXPIRED');
SELECT t.error('expired shop: no cancel',format('SELECT public.cancel_credit_exception(%L)',t.id('ex-pending')),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ================================================================ settings: custom weights are used (owner, through update_org_settings)
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.update_org_settings('{"credit_score_weights":{"guarantors":10,"income":60,"residence":20,"identity":10}}');
SELECT t.expect('score: custom weights from update_org_settings are used (s20: one guarantor = 5 points)',
  (public.get_customer_credit_profile(t.id('s20'))->>'score')='5' AND (public.get_customer_credit_profile(t.id('s80'))->>'score')='80');
SELECT public.update_org_settings('{"credit_score_weights":{"guarantors":25,"income":25,"residence":25,"identity":25}}');
SELECT t.expect('score: 12.5 + 25 = 37.5 rounds half up to 38',(public.get_customer_credit_profile(t.id('s1g'))->>'score')='38',public.get_customer_credit_profile(t.id('s1g'))::text);
SELECT t.expect('score: the components show the weights and points',
  (public.get_customer_credit_profile(t.id('s1g'))->'components'->0->>'points')::numeric=12.5 AND (public.get_customer_credit_profile(t.id('s1g'))->'components'->1->>'points')::numeric=25);
SELECT public.update_org_settings('{"credit_score_weights":{"guarantors":40,"income":30,"residence":20,"identity":10}}');
SELECT public.update_org_settings('{"credit_min_score":90}');
SELECT t.expect('settings: a raised minimum score shows on the profile and in the preview',
  (public.get_customer_credit_profile(t.id('exp'))->>'min_score')='90' AND public.get_customer_credit_check(t.id('exp'),'100.00')->'reasons'='["score"]'::jsonb);
SELECT public.update_org_settings('{"credit_min_score":50}');
SELECT public.update_org_settings('{"credit_limit_income_multiple":"2"}');
SELECT t.expect('settings: the suggested limit follows the multiple, the limit does not (s80: 16 000 vs limit 0)',
  (public.get_customer_credit_profile(t.id('s80'))->>'suggested_limit')='16000.00' AND (public.get_customer_credit_profile(t.id('s80'))->>'credit_limit')='0.00');
SELECT public.update_org_settings('{"credit_limit_income_multiple":"3"}');
RESET ROLE;

-- ================================================================ nothing is granted that should not be
SELECT t.as_user('a0730000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.errlike('grants: authenticated can not call the check',format('SELECT app.check_customer_credit(%L,%L,100,NULL)',t.org('a'),t.id('exp')),'permission denied%');
SELECT t.errlike('grants: authenticated can not use an approval',format('SELECT app.use_credit_approval(%L,%L)',t.id('ex-own'),gen_random_uuid()),'permission denied%');
SELECT t.errlike('grants: authenticated can not compute a score',format('SELECT app.customer_credit_score(%L,%L)',t.org('a'),t.id('exp')),'permission denied%');
SELECT t.errlike('grants: authenticated can not write a limit directly',format('UPDATE public.customers SET credit_limit=1 WHERE id=%L',t.id('exp')),'permission denied%');
SELECT t.errlike('grants: authenticated can not insert an approval directly',format($q$INSERT INTO public.approvals(organization_id,kind,entity_type,requested_by) VALUES(%L,'credit_exception','contract',%L)$q$,t.org('a'),gen_random_uuid()),'permission denied%');
SELECT t.errlike('grants: authenticated can not decide an approval directly',format($q$UPDATE public.approvals SET status='approved' WHERE id=%L$q$,t.id('ex-pending')),'permission denied%');
RESET ROLE;
SELECT t.expect('grants: exactly the eight public functions are executable by authenticated and none by anon or public',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
     AND p.proname IN ('get_customer_credit_profile','get_customer_credit_check','get_credit_exception','list_credit_exceptions','set_customer_credit_limit','request_credit_exception','decide_credit_exception','cancel_credit_exception')
     AND has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE'))=8);
SELECT t.expect('grants: no app function of R03 is executable by authenticated or anon',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='app'
     AND p.proname IN ('credit_exception_ttl','parse_credit_amount','customer_exposure','customer_suggested_limit','customer_credit_score','customer_credit_behaviour','customer_credit_profile_json','credit_reasons','credit_exception_usable','check_customer_credit','use_credit_approval','credit_exception_json','contracts_credit_check')
     AND (has_function_privilege('authenticated',p.oid,'EXECUTE') OR has_function_privilege('anon',p.oid,'EXECUTE')))=0);

-- ================================================================ audit
SELECT t.expect('audit: every credit exception action wrote one row of entity type approval; a decision is a warning when approved',
  t.audits('credit_exception.requested','ex1')=1 AND t.audits('credit_exception.approved','ex1')=1 AND t.audits('credit_exception.rejected','ex2')=1
  AND t.audits('credit_exception.cancelled','ex3')=1 AND t.audits('credit_exception.approved','ex2')=0
  AND (SELECT bool_and(entity_type='approval') FROM public.audit_log WHERE organization_id=t.org('a') AND action LIKE 'credit_exception.%')
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='credit_exception.approved' AND entity_id=t.id('ex1') AND severity='warning' AND reason='Known customer')
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='credit_exception.rejected' AND entity_id=t.id('ex2') AND severity='info' AND reason='Too much for this customer')
  AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='credit_exception.requested' AND entity_id=t.id('ex1') AND reason='New fridge for a regular' AND after->>'financed_amount'='8000.00' AND after->'reasons'='["limit"]'::jsonb));
SELECT t.expect('audit: a refused call wrote nothing (ex1 has exactly two rows: requested and approved)',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND entity_id=t.id('ex1'))=2);
SELECT t.expect('audit: no R03 audit row holds a 14-digit national ID',
  NOT EXISTS(SELECT 1 FROM public.audit_log WHERE organization_id IN (t.org('a'),t.org('b'))
    AND (action='customer.credit_limit_set' OR action LIKE 'credit_exception.%')
    AND (COALESCE(before::text,'')||COALESCE(after::text,'')) ~ '[0-9]{14}'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
