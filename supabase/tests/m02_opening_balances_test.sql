-- M02 opening balances: open installment contracts and opening cash (EC-101, D85).
-- Run by: node scripts/db-smoke.mjs supabase/tests/m02_opening_balances_test.sql (inside BEGIN ... ROLLBACK).
-- A 30-line file of 4 contracts for 3 customers imports and the open debt equals the file's total;
-- the ledgers stay clean (no cash, stock, sale or payment row), every contract balances, the split
-- and the all-principal default, overdue lines (N04 adds warnings and no fee), guarantors, rows that
-- differ, unknown / ambiguous customers, a re-import, opening cash, the report, the sign-off, the
-- reversal, a closed day, permissions and another shop.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
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
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(p_branch, NULL);
  RETURN public.open_shift(p_branch, p_float, p_key, NULL, NULL);
END $$;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE TABLE t.docs(tag text,j jsonb);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,COALESCE(b,false),d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE (jsonb_build_object('x-org-id',o) || COALESCE((SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.employees e ON e.id=s.employee_id JOIN public.devices d ON d.id=s.device_id WHERE s.organization_id=o AND s.status='open' AND d.is_active AND d.archived_at IS NULL AND d.token_hash IS NOT NULL ORDER BY (e.auth_user_id::text=u) DESC,s.opened_at DESC,s.id DESC LIMIT 1),'{}'::jsonb))::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
-- A file row (what F14 stores) for shop a; the dry run reads it by tag 'file'.
CREATE FUNCTION t.file(tag text, purpose public.file_purpose DEFAULT 'import') RETURNS uuid LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.files(organization_id,path,original_name,mime,size_bytes,sha256,purpose)
    VALUES(t.org('a'),t.org('a')::text||'/import/'||tag||'.csv',tag||'.csv','text/csv',10,repeat('a',64),purpose) RETURNING id)
  INSERT INTO t.ids SELECT tag,id FROM x RETURNING id $$;
-- The lines of one contract: n monthly lines from day `start` (relative to today), `amt` each.
-- The contract columns repeat on every line, like the file does; extra adds columns (guarantors...).
CREATE FUNCTION t.cl(ref text, nid text, orig text, paid text, start integer, n integer, amt text, extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('contract_ref',ref,'customer_national_id',nid,'original_total',orig,'paid_before',paid,
    'contract_date','2025-01-15','due_date',(t.today()+start+30*g)::text,'amount',amt) || extra ORDER BY g)
  FROM generate_series(0,n-1) g $$;
-- Rows as the API passes them (row 2, 3, ... ; the header is row 1).
CREATE FUNCTION t.fr(VARIADIC parts jsonb[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('row',rn+1,'values',v) ORDER BY rn)
  FROM (SELECT row_number() OVER (ORDER BY po,o) AS rn, e AS v
        FROM unnest(parts) WITH ORDINALITY p(j,po), jsonb_array_elements(p.j) WITH ORDINALITY x(e,o)) s $$;
CREATE FUNCTION t.rows(VARIADIC v text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('row',o+1,'values',x::jsonb) ORDER BY o) FROM unnest(v) WITH ORDINALITY u(x,o) $$;
CREATE FUNCTION t.dry(k text,rows jsonb,key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.create_import(k,t.id('file'),NULL,rows,'{}',key) $$;
CREATE FUNCTION t.codes(job jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg((e->>'row')||':'||COALESCE(e->>'column','-')||':'||(e->>'code'),' | ' ORDER BY (e->>'row')::int, e->>'column', e->>'code') FROM jsonb_array_elements(job->'report'->'errors') e $$;
CREATE FUNCTION t.run(job jsonb,rows jsonb,key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM public.queue_import((job->>'id')::uuid,key);
  RESET ROLE;                                  -- the worker runs as the service role
  r := public.jobs_import_apply((job->>'id')::uuid,rows);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
CREATE FUNCTION t.pay(ref text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_collection(jsonb_build_object('customer_id',(SELECT customer_id FROM public.contracts WHERE organization_id=t.org('a') AND upper(migration_source->>'contract_ref')=upper(ref) AND (migration_source->>'reversed') IS DISTINCT FROM 'true'),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',(SELECT id FROM public.contracts WHERE organization_id=t.org('a') AND upper(migration_source->>'contract_ref')=upper(ref) AND (migration_source->>'reversed') IS DISTINCT FROM 'true'),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
CREATE FUNCTION t.kid(ref text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.contracts WHERE organization_id=t.org('a') AND upper(migration_source->>'contract_ref')=upper(ref) AND (migration_source->>'reversed') IS DISTINCT FROM 'true' $$;
CREATE FUNCTION t.k(ref text) RETURNS public.contracts LANGUAGE sql SECURITY DEFINER AS $$ SELECT * FROM public.contracts WHERE id=t.kid(ref) $$;
CREATE FUNCTION t.remaining(job uuid) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(sum(b.remaining),0) FROM public.v_contract_balances b JOIN public.contracts c ON c.id=b.contract_id WHERE c.migration_batch_id=job $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;

-- ---------------------------------------------------------------- setup: shops a (retail_pro) and b
RESET ROLE;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('M02 '||s,'m02-key-'||s,p,'Owner',s||'m02@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('d',64)),('b','retail_pro',repeat('e',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0900000-0000-0000-8000-000000000001','am02@example.com'),('a0900000-0000-0000-8000-000000000002','bm02@example.com'),
  ('a0900000-0000-0000-8000-000000000003','m02cashier@example.com'),('a0900000-0000-0000-8000-000000000004','m02manager@example.com'),
  ('a0900000-0000-0000-8000-000000000005','m02clerk@example.com');
SELECT public.accept_invite(repeat('d',64),'a0900000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('e',64),'a0900000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'));
UPDATE public.org_settings SET credit_min_score=0,customer_ban_days=0,overdue_warning_interval_days=10 WHERE organization_id=t.org('a');
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0900000-0000-0000-8000-000000000003','M02 Cashier','CASHIER');
SELECT t.emp('manager','a0900000-0000-0000-8000-000000000004','M02 Manager','BRANCH_MANAGER');
SELECT t.emp('clerk','a0900000-0000-0000-8000-000000000005','M02 Clerk','BRANCH_MANAGER');
-- The clerk may import data but not see national IDs and has no cash keys (the owner still has all).
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES
  (t.org('a'),t.id('clerk'),'import.data',true),(t.org('a'),t.id('clerk'),'installment.create',true),(t.org('a'),t.id('clerk'),'customer.create',true),
  (t.org('a'),t.id('clerk'),'customer.view_pii',false),(t.org('a'),t.id('clerk'),'cash.adjust',false),(t.org('a'),t.id('clerk'),'report.financial',true);
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'percent_of_future_profit',50,
         1000,1,1000
  FROM public.installment_policies WHERE organization_id=t.org('a');
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text,p_nid text,p_status public.customer_status DEFAULT 'active') RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,p_status,p_nid) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('c1','Amal Ahmed','01033330001','29101010100501');
SELECT t.cust('c2','Basma Badr','01033330002','29101010100502');
SELECT t.cust('c3','Cairo Customer','01033330003','29101010100503');
SELECT t.cust('c4','Dina Twin One','01033330009','29101010100504');
SELECT t.cust('c5','Dina Twin Two','01033330009','29101010100505');
SELECT t.cust('c6','Blocked Bassem','01033330006','29101010100506','blocked');
-- A guarantor the shop already has.
INSERT INTO public.guarantors(organization_id,full_name,phone,national_id) VALUES(t.org('a'),'Old Guarantor','01044440001','28805050100022') RETURNING id AS old_g \gset
INSERT INTO t.ids VALUES('old_g',:'old_g');
SELECT t.file('file');
INSERT INTO public.files(organization_id,path,original_name,mime,size_bytes,sha256,purpose) VALUES(t.org('b'),t.org('b')::text||'/import/b.csv','b.csv','text/csv',10,repeat('b',64),'import') RETURNING id AS bfile \gset
INSERT INTO t.ids VALUES('bfile',:'bfile');

-- ================================================================ opening contracts: the 30-line file
-- 4 contracts / 3 customers / 30 lines. K-100: 9 x 1000 (all principal), K-101: 5 x 1000 with two
-- guarantors (one new, one the shop already has), K-102: 12 x 1000 with principal 10000 + profit 2000,
-- K-103: 4 x 1000 with two lines already late (-40 and -10 days).
RESET ROLE;
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.fr(
  t.cl('K-100','29101010100501','12000','3000',30,9,'1000.00'),
  t.cl('K-101','29101010100501','5000','0',30,5,'1000.00', jsonb_build_object(
      'guarantor1_national_id','29005050100011','guarantor1_name','New Guarantor','guarantor1_phone','01055550001','guarantor1_relation','brother',
      'guarantor2_national_id','28805050100022','guarantor2_relation','friend')),
  t.cl('K-102','29101010100502','20000','8000',30,12,'1000.00', jsonb_build_object('remaining_principal','10000','remaining_profit','2000','frequency','monthly')),
  t.cl('K-103','','6000','2000',-40,4,'1000.00','{"customer_phone":"01033330003"}')) AS frows \gset
-- K-103's lines are at -40, -10, +20, +50.
SELECT t.dry('opening_contracts',:'frows'::jsonb,'m02-dry-1') AS j1 \gset
SELECT t.expect('dry run: validated, 4 contracts, 30 lines, open total 30000, no error',
  :'j1'::jsonb->>'status'='validated' AND (:'j1'::jsonb->>'rows_total')::int=30 AND (:'j1'::jsonb#>>'{report,errors_total}')::int=0
  AND :'j1'::jsonb#>>'{report,summary,contracts}'='4' AND :'j1'::jsonb#>>'{report,summary,lines}'='30'
  AND :'j1'::jsonb#>>'{report,summary,open_total}'='30000.00' AND (:'j1'::jsonb#>>'{report,actions,create}')::int=4,:'j1'::text);
SELECT t.expect('dry run reports the overdue part: 2000 on one contract, 40 days',
  :'j1'::jsonb#>>'{report,summary,overdue_total}'='2000.00' AND :'j1'::jsonb#>>'{report,summary,overdue_contracts}'='1'
  AND (SELECT e->>'overdue_days'='40' AND e->>'lines'='4' AND e->>'overdue_total'='2000.00' FROM jsonb_array_elements(:'j1'::jsonb#>'{report,contracts}') e WHERE e->>'contract_ref'='K-103'),
  (:'j1'::jsonb#>'{report,contracts}')::text);
SELECT t.expect('dry run: one new guarantor, a fees note, the national IDs masked in the preview',
  :'j1'::jsonb#>>'{report,summary,new_guarantors}'='1'
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'j1'::jsonb#>'{report,warnings}') w WHERE w->>'message' LIKE 'Fees in the old records%')
  AND NOT (:'j1'::jsonb#>>'{report,preview}') LIKE '%29101010100501%');
RESET ROLE;
SELECT t.expect('dry run saved nothing',
  (SELECT count(*)=0 FROM public.contracts WHERE organization_id=t.org('a') AND is_migrated)
  AND (SELECT count(*)=1 FROM public.guarantors WHERE organization_id=t.org('a')));
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.run(:'j1'::jsonb,:'frows'::jsonb,'m02-run-1') AS r1 \gset
RESET ROLE;
SELECT t.expect('import: completed, 4 created',:'r1'::jsonb->>'status'='completed'
  AND (SELECT status='completed' AND report#>>'{applied,create}'='4' AND rows_ok=30 FROM public.import_jobs WHERE id=(:'j1'::jsonb->>'id')::uuid),:'r1'::text);
SELECT t.expect('Done when: the system''s open debt equals the file''s total (30000)',
  t.remaining((:'j1'::jsonb->>'id')::uuid)=30000
  AND (SELECT sum(total_payable)=30000 FROM public.contracts WHERE migration_batch_id=(:'j1'::jsonb->>'id')::uuid));
SELECT t.expect('each contract carries is_migrated, its batch, its source, a new EcoFin number and no sale',
  (SELECT count(*)=4 AND bool_and(is_migrated AND sale_id IS NULL AND order_id IS NULL AND status='active' AND down_payment=0
     AND cash_price=financed_amount AND number LIKE '%CT-%' AND migration_source ? 'contract_ref' AND migration_source ? 'paid_before'
     AND migration_batch_id=(:'j1'::jsonb->>'id')::uuid) FROM public.contracts WHERE organization_id=t.org('a'))
  AND (t.k('K-100')).migration_source=jsonb_build_object('contract_ref','K-100','contract_date','2025-01-15','original_total','12000.00','paid_before','3000.00'),
  (SELECT jsonb_agg(number) FROM public.contracts WHERE organization_id=t.org('a'))::text);
SELECT t.expect('only what is left is stored: K-100 financed 9000 + markup 0 = 9000 (everything left is principal)',
  (t.k('K-100')).financed_amount=9000 AND (t.k('K-100')).markup_amount=0 AND (t.k('K-100')).total_payable=9000 AND (t.k('K-100')).installments_count=9
  AND (SELECT sum(principal)=9000 AND sum(profit)=0 AND count(*)=9 FROM public.schedule_lines WHERE contract_id=t.kid('K-100')));
SELECT t.expect('the split follows remaining_principal / remaining_profit: K-102 10000 + 2000, lines add up exactly',
  (t.k('K-102')).financed_amount=10000 AND (t.k('K-102')).markup_amount=2000 AND (t.k('K-102')).total_payable=12000 AND (t.k('K-102')).markup_pct=20
  AND (SELECT sum(principal)=10000 AND sum(profit)=2000 AND count(*)=12 AND bool_and(amount=1000 AND principal>=0 AND profit>0)
       FROM public.schedule_lines WHERE contract_id=t.kid('K-102'))
  AND (SELECT sum(profit)=0 FROM public.schedule_lines WHERE contract_id=t.kid('K-101')),
  (SELECT string_agg(profit::text,',' ORDER BY seq) FROM public.schedule_lines WHERE contract_id=t.kid('K-102')));
SELECT t.expect('lines run 1..n by due date and the first due date is the first line''s',
  (SELECT bool_and(l.due_date=c.first_due_date) FROM public.schedule_lines l JOIN public.contracts c ON c.id=l.contract_id WHERE c.number=(t.k('K-103')).number AND l.seq=1)
  AND (SELECT min(due_date)=t.today()-40 FROM public.schedule_lines WHERE contract_id=t.kid('K-103'))
  AND (SELECT array_agg(seq ORDER BY seq)=ARRAY[1,2,3,4] FROM public.schedule_lines WHERE contract_id=t.kid('K-103')));
SELECT t.expect('Done when: nothing in the cash, stock, sale or payment ledgers',
  (SELECT count(*)=0 FROM public.cash_movements WHERE organization_id=t.org('a') AND type<>'opening')
  AND (SELECT count(*)=0 FROM public.stock_movements WHERE organization_id=t.org('a'))
  AND (SELECT count(*)=0 FROM public.sales WHERE organization_id=t.org('a'))
  AND (SELECT count(*)=0 FROM public.payments WHERE organization_id=t.org('a'))
  AND (SELECT count(*)=0 FROM public.charges WHERE organization_id=t.org('a')));
SELECT t.expect('version 1 balances (the commit-time check passed) and the contract answer shows migration_source',
  (app.contract_json(t.org('a'),t.kid('K-100')))#>>'{migration_source,contract_ref}'='K-100'
  AND (app.contract_json(t.org('a'),t.kid('K-100')))#>>'{balance,remaining}'='9000.00');
SELECT t.expect('the customer account''s contract row carries migration_source (and null on others)',
  (app.customer_contract_json(t.org('a'),t.kid('K-100')))#>>'{migration_source,paid_before}'='3000.00'
  AND (app.customer_contract_json(t.org('a'),t.kid('K-100')))->>'is_migrated'='true');
SELECT t.expect('guarantors: the new one is created and linked; the old one is reused; K-100 has none',
  (SELECT count(*)=2 FROM public.guarantors WHERE organization_id=t.org('a'))
  AND (SELECT full_name='New Guarantor' AND phone='01055550001' FROM public.guarantors WHERE organization_id=t.org('a') AND national_id='29005050100011')
  AND (SELECT count(*)=2 FROM public.contract_guarantors WHERE contract_id=t.kid('K-101'))
  AND (SELECT count(*)=0 FROM public.contract_guarantors WHERE contract_id=t.kid('K-100'))
  AND (SELECT count(*)=2 FROM public.customer_guarantors WHERE customer_id=t.id('c1'))
  AND (SELECT relation='brother' FROM public.customer_guarantors cg JOIN public.guarantors g ON g.id=cg.guarantor_id WHERE cg.customer_id=t.id('c1') AND g.national_id='29005050100011')
  AND (SELECT relation='friend' FROM public.customer_guarantors cg JOIN public.guarantors g ON g.id=cg.guarantor_id WHERE cg.customer_id=t.id('c1') AND g.national_id='28805050100022'));
SELECT t.expect('audit: one contract.migrated row per contract and the import.completed row carries the summary',
  (SELECT count(*)=4 FROM public.audit_log WHERE organization_id=t.org('a') AND action='contract.migrated' AND employee_id IS NOT NULL)
  AND (SELECT after#>>'{summary,open_total}'='30000.00' FROM public.audit_log WHERE entity_id=(:'j1'::jsonb->>'id')::uuid AND action='import.completed'));
-- N04 treats the late lines like any other: warnings, no fee (rule 4).
SELECT t.as_user(NULL);
SELECT public.jobs_overdue_run(t.org('a')) AS od \gset
SELECT t.expect('N04: the overdue migrated contract gets a warning, and no fee and no charge exists',
  (SELECT count(*)=1 FROM public.overdue_actions WHERE organization_id=t.org('a') AND kind='warning' AND contract_id=t.kid('K-103'))
  AND (SELECT count(*)=0 FROM public.charges WHERE organization_id=t.org('a'))
  AND (SELECT overdue_amount=2000 AND overdue_lines=2 AND max_days_late=40 FROM public.v_contract_balances WHERE contract_id=t.kid('K-103'))
  AND (SELECT fees_due=0 FROM public.v_contract_balances WHERE contract_id=t.kid('K-103')),:'od'::text);

-- ================================================================ re-import and bad files
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.dry('opening_contracts',:'frows'::jsonb,'m02-dry-2') AS j2 \gset
SELECT t.expect('the same file again fails cleanly: IMPORT_CONTRACT_EXISTS once per contract, nothing duplicated',
  :'j2'::jsonb->>'status'='failed' AND (:'j2'::jsonb#>>'{report,errors_total}')::int=4
  AND t.codes(:'j2'::jsonb)='2:contract_ref:IMPORT_CONTRACT_EXISTS | 11:contract_ref:IMPORT_CONTRACT_EXISTS | 16:contract_ref:IMPORT_CONTRACT_EXISTS | 28:contract_ref:IMPORT_CONTRACT_EXISTS',
  t.codes(:'j2'::jsonb));
SELECT t.error('a failed job cannot be imported',format($q$SELECT public.queue_import(%L,'m02-run-2')$q$,:'j2'::jsonb->>'id'),'IMPORT_NOT_VALIDATED');
RESET ROLE;
SELECT t.expect('still 4 migrated contracts',(SELECT count(*)=4 FROM public.contracts WHERE organization_id=t.org('a') AND is_migrated));
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
-- Not balanced: original - paid = 5000 but the lines add up to 4000.
SELECT t.dry('opening_contracts',t.fr(t.cl('K-200','29101010100501','5000','0',10,4,'1000.00')),'m02-dry-3') AS j3 \gset
SELECT t.expect('original_total - paid_before <> the lines: IMPORT_CONTRACT_NOT_BALANCED on the first line, both numbers in the message',
  :'j3'::jsonb->>'status'='failed' AND t.codes(:'j3'::jsonb)='2:paid_before:IMPORT_CONTRACT_NOT_BALANCED'
  AND (:'j3'::jsonb#>>'{report,errors,0,message}') LIKE '%5000.00%4000.00%',(:'j3'::jsonb#>>'{report,errors}')::text);
-- Rows that disagree, an unknown customer, an ambiguous phone, a blocked customer (a warning only).
SELECT t.fr(
  t.cl('K-201','29101010100501','3000','0',10,2,'1500.00') || t.cl('K-201','29101010100502','3000','0',70,1,'0.00'),
  t.cl('K-202','29101010100599','1000','0',10,1,'1000.00'),
  t.cl('K-203','','1000','0',10,1,'1000.00','{"customer_phone":"01033330009"}'),
  t.cl('K-204','29101010100506','1000','0',10,1,'1000.00')) AS badrows \gset
SELECT t.dry('opening_contracts',:'badrows'::jsonb,'m02-dry-4') AS j4 \gset
SELECT t.expect('errors by row and column: amount 0, customer not found, ambiguous phone',
  :'j4'::jsonb->>'status'='failed'
  AND t.codes(:'j4'::jsonb)='4:amount:IMPORT_INVALID_VALUE | 5:customer_national_id:IMPORT_CUSTOMER_NOT_FOUND | 6:customer_phone:IMPORT_AMBIGUOUS_MATCH',
  t.codes(:'j4'::jsonb));
SELECT t.dry('opening_contracts',t.fr(
  t.cl('K-205','29101010100501','4500','0',10,2,'1500.00') || t.cl('K-205','29101010100502','4500','0',70,1,'1500.00'),
  t.cl('K-204','29101010100506','1000','0',10,1,'1000.00')),'m02-dry-5') AS j5 \gset
SELECT t.expect('rows of one contract that disagree: IMPORT_CONTRACT_ROWS_DIFFER on the later row',
  t.codes(:'j5'::jsonb) LIKE '%4:customer_national_id:IMPORT_CONTRACT_ROWS_DIFFER%',t.codes(:'j5'::jsonb));
SELECT t.expect('a blocked customer is accepted with a warning',
  EXISTS (SELECT 1 FROM jsonb_array_elements(:'j5'::jsonb#>'{report,warnings}') w WHERE w->>'message' LIKE 'Contract K-204: the customer is blocked%')
  AND t.codes(:'j5'::jsonb) NOT LIKE '%5:%',t.codes(:'j5'::jsonb));
-- Required cells, wrong values, a lone remaining_principal, an incomplete new guarantor.
SELECT t.dry('opening_contracts',t.fr(
  jsonb_build_array(jsonb_build_object('customer_national_id','29101010100501','original_total','1000','paid_before','0','due_date',(t.today()+5)::text,'amount','1000')),
  jsonb_build_array(jsonb_build_object('contract_ref','K-206','customer_national_id','29101010100501','original_total','1000','paid_before','0','contract_date','2025-01-01','amount','1000')),
  t.cl('K-207','29101010100501','1000','0',10,1,'1000.00', jsonb_build_object('frequency','yearly')),
  t.cl('K-208','29101010100501','1000','0',10,1,'1000.00', jsonb_build_object('remaining_principal','900')),
  t.cl('K-209','29101010100501','1000','0',10,1,'1000.00', jsonb_build_object('guarantor1_national_id','29005050100033','guarantor1_name','No Phone')),
  t.cl('K-210','29101010100501','1000','0',10,1,'1000.00', jsonb_build_object('remaining_principal','900','remaining_profit','200')),
  t.cl('K-211','29101010100501','1000','0',10,1,'1000.00', jsonb_build_object('guarantor1_national_id','29101010100501','guarantor1_name','Self','guarantor1_phone','01066660001'))),'m02-dry-6') AS j6 \gset
SELECT t.expect('required and wrong cells are reported by row and column',
  t.codes(:'j6'::jsonb)='2:contract_ref:IMPORT_REQUIRED | 3:due_date:IMPORT_REQUIRED | 4:frequency:IMPORT_INVALID_VALUE | 5:remaining_profit:IMPORT_INVALID_VALUE | 6:guarantor1_phone:IMPORT_GUARANTOR_INCOMPLETE | 7:remaining_principal:IMPORT_CONTRACT_NOT_BALANCED | 8:guarantor1_national_id:IMPORT_INVALID_VALUE',
  t.codes(:'j6'::jsonb));
RESET ROLE;
SELECT t.expect('bad files saved nothing',(SELECT count(*)=4 FROM public.contracts WHERE organization_id=t.org('a') AND is_migrated)
  AND (SELECT count(*)=2 FROM public.guarantors WHERE organization_id=t.org('a')));

-- ================================================================ opening cash
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.rows(
  '{"account_name":"Main safe","kind":"safe","balance":"5000.50"}',
  '{"account_name":"CIB","kind":"bank","bank_shop_wide":"yes","balance":"20000"}',
  '{"account_name":"NBE","kind":"bank","branch_code":"","balance":"0"}') AS crows \gset
SELECT t.dry('opening_cash',:'crows'::jsonb,'m02-cash-dry-1') AS cj1 \gset
SELECT t.expect('opening cash dry run: validated, 3 accounts to create, nothing saved',
  :'cj1'::jsonb->>'status'='validated' AND (:'cj1'::jsonb#>>'{report,actions,create}')::int=3,:'cj1'::text);
RESET ROLE;
SELECT t.expect('the dry run created no account',(SELECT count(*)=0 FROM public.cash_accounts WHERE organization_id=t.org('a') AND name IN ('Main safe','CIB','NBE')));
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.run(:'cj1'::jsonb,:'crows'::jsonb,'m02-cash-run-1') AS cr1 \gset
RESET ROLE;
SELECT t.expect('opening cash import: completed, 3 accounts created',:'cr1'::jsonb->>'status'='completed'
  AND (SELECT count(*)=3 FROM public.cash_accounts WHERE organization_id=t.org('a') AND name IN ('Main safe','CIB','NBE')),:'cr1'::text);
SELECT t.expect('one opening movement through the job per positive balance (none for 0)',
  (SELECT count(*)=2 FROM public.cash_movements WHERE organization_id=t.org('a') AND source_id=(:'cj1'::jsonb->>'id')::uuid AND type='opening' AND source_type='import')
  AND (SELECT count(*)=0 FROM public.cash_movements m JOIN public.cash_accounts a ON a.id=m.cash_account_id WHERE a.organization_id=t.org('a') AND a.name='NBE'),
  (SELECT string_agg(a.name||':'||m.type||':'||m.amount||':'||m.source_type,' | ') FROM public.cash_movements m JOIN public.cash_accounts a ON a.id=m.cash_account_id WHERE m.organization_id=t.org('a')));
SELECT t.expect('balances equal the file',
  (SELECT cb.balance=5000.50 FROM public.cash_balances cb JOIN public.cash_accounts a ON a.id=cb.cash_account_id WHERE a.organization_id=t.org('a') AND a.name='Main safe')
  AND (SELECT cb.balance=20000 FROM public.cash_balances cb JOIN public.cash_accounts a ON a.id=cb.cash_account_id WHERE a.organization_id=t.org('a') AND a.name='CIB'));
SELECT t.expect('kinds and branches: the shop-wide bank has no branch, the other bank is the main branch''s',
  (SELECT a.branch_id IS NULL AND a.kind='bank' FROM public.cash_accounts a WHERE a.organization_id=t.org('a') AND a.name='CIB')
  AND (SELECT a.kind='bank' AND a.branch_id=t.id('main') FROM public.cash_accounts a WHERE a.organization_id=t.org('a') AND a.name='NBE')
  AND (SELECT a.kind='safe' AND a.branch_id=t.id('main') FROM public.cash_accounts a WHERE a.organization_id=t.org('a') AND a.name='Main safe'));
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.dry('opening_cash',t.rows(
  '{"account_name":"Main safe","kind":"safe","balance":"100"}',
  '{"account_name":"Drawer 1","kind":"drawer","balance":"100"}',
  '{"account_name":"Wallet","kind":"collector_wallet","balance":"10"}',
  '{"account_name":"Vault","kind":"safe","balance":"-5"}',
  '{"account_name":"Vault","kind":"safe","balance":"5"}',
  '{"account_name":"Vault","kind":"safe","balance":"6"}',
  '{"account_name":"Shop safe","kind":"safe","bank_shop_wide":"yes","balance":"5"}',
  '{"account_name":"Far","kind":"safe","branch_code":"ZZZ","balance":"5"}',
  '{"kind":"safe","balance":"5"}'),'m02-cash-dry-2') AS cj2 \gset
SELECT t.expect('opening cash errors: account with movements, drawer / wallet kinds, negative, duplicate, shop-wide safe, unknown branch, missing name',
  t.codes(:'cj2'::jsonb)='2:account_name:CASH_ACCOUNT_HAS_MOVEMENTS | 3:kind:IMPORT_ACCOUNT_KIND | 4:kind:IMPORT_ACCOUNT_KIND | 5:balance:IMPORT_INVALID_VALUE | 7:account_name:IMPORT_DUPLICATE_ROW | 8:bank_shop_wide:IMPORT_INVALID_VALUE | 9:branch_code:IMPORT_INVALID_VALUE | 10:account_name:IMPORT_REQUIRED',
  t.codes(:'cj2'::jsonb));
-- A manager without cash.adjust cannot import cash; the clerk (no cash keys) neither.
RESET ROLE;
SELECT t.as_user('a0900000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('opening_cash needs cash.adjust as well as import.data',
  format($q$SELECT public.create_import('opening_cash',%L,NULL,%L::jsonb,'{}','m02-clerk-cash')$q$,t.id('file'),t.rows('{"account_name":"X","kind":"safe","balance":"1"}')::text),'PERMISSION_DENIED');
RESET ROLE;

-- ================================================================ the report
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.get_migration_report('{}') AS rep \gset
SELECT t.expect('report: 4 contracts, 3 customers, imported 30000 = open now 30000, overdue 2000, nothing collected, original 43000, paid before 13000',
  :'rep'::jsonb#>>'{totals,contracts}'='4' AND :'rep'::jsonb#>>'{totals,customers}'='3'
  AND :'rep'::jsonb#>>'{totals,imported_total}'='30000.00' AND :'rep'::jsonb#>>'{totals,open_now}'='30000.00'
  AND :'rep'::jsonb#>>'{totals,overdue_now}'='2000.00' AND :'rep'::jsonb#>>'{totals,collected_since}'='0.00'
  AND :'rep'::jsonb#>>'{totals,original_total}'='43000.00' AND :'rep'::jsonb#>>'{totals,paid_before}'='13000.00',:'rep'::text);
SELECT t.expect('report: per customer rows (Amal 2 contracts 14000) and per branch, with the owner seeing the national ID',
  (SELECT e->>'contracts'='2' AND e->>'open_now'='14000.00' AND e->>'national_id'='29101010100501' FROM jsonb_array_elements(:'rep'::jsonb->'customers') e WHERE e->>'name'='Amal Ahmed')
  AND jsonb_array_length(:'rep'::jsonb->'branches')=1 AND :'rep'::jsonb#>>'{branches,0,open_now}'='30000.00');
SELECT t.expect('report: the opening cash (posted vs now) and the batches with their state',
  :'rep'::jsonb#>>'{cash_totals,opening_posted}'='25000.50' AND jsonb_array_length(:'rep'::jsonb->'cash')=2
  AND (SELECT count(*)=2 FROM jsonb_array_elements(:'rep'::jsonb->'batches') b WHERE (b->>'can_reverse')::boolean OR b->>'kind'='opening_cash'),:'rep'::text);
SELECT public.get_migration_report(jsonb_build_object('customer_id',t.id('c2'))) AS rep2 \gset
SELECT t.expect('report filtered by customer: one contract, no cash section',
  :'rep2'::jsonb#>>'{totals,contracts}'='1' AND :'rep2'::jsonb#>>'{totals,open_now}'='12000.00' AND jsonb_array_length(:'rep2'::jsonb->'cash')=0);
SELECT public.get_migration_report(jsonb_build_object('batch_id',:'j1'::jsonb->>'id','branch_id',t.id('main'))) AS rep3 \gset
SELECT t.expect('report filtered by batch and branch',:'rep3'::jsonb#>>'{totals,contracts}'='4' AND jsonb_array_length(:'rep3'::jsonb->'cash')=0);
SELECT t.error('report: a filter that is not one',$q$SELECT public.get_migration_report('{"x":"1"}')$q$,'VALIDATION_FAILED');
SELECT t.error('report: another shop''s batch is not found',format($q$SELECT public.get_migration_report(jsonb_build_object('batch_id',%L))$q$,gen_random_uuid()),'IMPORT_JOB_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0900000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT public.get_migration_report('{}') AS rep4 \gset
SELECT t.expect('without customer.view_pii the national IDs are masked in the report',
  (SELECT e->>'national_id' NOT LIKE '29101010100501' AND e->>'national_id' LIKE '%0501' FROM jsonb_array_elements(:'rep4'::jsonb->'customers') e WHERE e->>'name'='Amal Ahmed'),
  (SELECT e->>'national_id' FROM jsonb_array_elements(:'rep4'::jsonb->'customers') e WHERE e->>'name'='Amal Ahmed'));
RESET ROLE;
SELECT t.as_user('a0900000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('report: a cashier has neither key','SELECT public.get_migration_report(''{}'')','PERMISSION_DENIED');
SELECT t.error('sign-offs list: a cashier has neither key','SELECT public.list_migration_signoffs()','PERMISSION_DENIED');
SELECT t.error('sign-off: a cashier is denied',format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','1','batch_ids',jsonb_build_array(%L),'note','nope'))$q$,:'j1'::jsonb->>'id'),'PERMISSION_DENIED');
SELECT t.error('reverse: a cashier is denied',format($q$SELECT public.reverse_migration_batch(%L,'nothing wrong')$q$,:'j1'::jsonb->>'id'),'PERMISSION_DENIED');
SELECT t.error('import: a cashier is denied',format($q$SELECT public.create_import('opening_contracts',%L,NULL,%L::jsonb,'{}','m02-cashier')$q$,t.id('file'),:'frows'::text),'PERMISSION_DENIED');
RESET ROLE;

-- ================================================================ a collection, then the sign-off
SELECT t.as_user('a0900000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','m02-key-shift');
INSERT INTO t.docs SELECT 'pay',t.pay('K-100','1000.00','m02-key-pay-1');
RESET ROLE;
SELECT t.expect('a collection on a migrated contract: it is the normal N03 path (open drops by 1000, imported stays)',
  (SELECT remaining=8000 AND paid=1000 FROM public.v_contract_balances WHERE contract_id=t.kid('K-100'))
  AND t.remaining((:'j1'::jsonb->>'id')::uuid)=29000);
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('collected since migration shows in the report',public.get_migration_report('{}')#>>'{totals,collected_since}'='1000.00'
  AND public.get_migration_report('{}')#>>'{totals,imported_total}'='30000.00' AND public.get_migration_report('{}')#>>'{totals,open_now}'='29000.00');
SELECT t.error('reverse after a collection: MIGRATION_NOT_REVERSIBLE naming the contract',
  format($q$SELECT public.reverse_migration_batch(%L,'wrong customers')$q$,:'j1'::jsonb->>'id'),'MIGRATION_NOT_REVERSIBLE');
SELECT t.error_detail('reverse after a collection: the detail names the blocking contract',
  format($q$SELECT public.reverse_migration_batch(%L,'wrong customers')$q$,:'j1'::jsonb->>'id'),'MIGRATION_NOT_REVERSIBLE',
  jsonb_build_object('reason','collection','number',(SELECT number FROM public.contracts WHERE id=t.kid('K-100'))));
SELECT t.error_detail('sign-off: a wrong total is refused with expected / system / difference',
  format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','29999.00','batch_ids',jsonb_build_array(%L),'note','signed paper'))$q$,:'j1'::jsonb->>'id'),
  'MIGRATION_TOTAL_MISMATCH',jsonb_build_object('field','open_total','expected','29999.00','system','30000.00','difference','-1.00'));
RESET ROLE;
SELECT t.expect('a refused sign-off stores nothing',(SELECT count(*)=0 FROM public.migration_signoffs WHERE organization_id=t.org('a')));
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('sign-off: a wrong cash total is refused too',
  format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','0','expected_cash_total','1','batch_ids',jsonb_build_array(%L),'note','signed paper'))$q$,:'cj1'::jsonb->>'id'),
  'MIGRATION_TOTAL_MISMATCH',jsonb_build_object('field','cash_total','system','25000.50'));
SELECT t.error('sign-off: unknown keys are refused',format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','30000','batch_ids',jsonb_build_array(%L),'note','signed paper','x',1))$q$,:'j1'::jsonb->>'id'),'VALIDATION_FAILED');
SELECT t.error('sign-off: a batch of another shop is not found',format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','30000','batch_ids',jsonb_build_array(%L),'note','signed paper'))$q$,gen_random_uuid()),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('sign-off: a note is required',format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','30000','batch_ids',jsonb_build_array(%L),'note','x'))$q$,:'j1'::jsonb->>'id'),'VALIDATION_FAILED');
-- The right total: the amount IMPORTED, even though 1000 was collected since.
SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','30000.00','expected_cash_total','25000.50',
  'batch_ids',jsonb_build_array(:'j1'::jsonb->>'id',:'cj1'::jsonb->>'id'),'note','Signed by the owner against the paper ledger')) AS so \gset
SELECT t.expect('Done when: the right total signs off (the total at import, not what is left); the sign-off row is complete',
  :'so'::jsonb->>'expected_open_total'='30000.00' AND :'so'::jsonb->>'system_open_total'='30000.00'
  AND :'so'::jsonb->>'system_cash_total'='25000.50' AND :'so'::jsonb->>'expected_cash_total'='25000.50'
  AND jsonb_array_length(:'so'::jsonb->'batch_ids')=2 AND :'so'::jsonb#>>'{signed_by,name}'='Owner',:'so'::text);
SELECT t.expect('audit migration.signed_off (warning)',
  (SELECT severity='warning' AND employee_id IS NOT NULL FROM public.audit_log WHERE action='migration.signed_off' AND entity_id=(:'so'::jsonb->>'id')::uuid));
SELECT t.error('a batch can be in one sign-off only',format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','30000','batch_ids',jsonb_build_array(%L),'note','signed again'))$q$,:'j1'::jsonb->>'id'),'MIGRATION_SIGNED_OFF');
SELECT t.error('a signed-off batch cannot be reversed',format($q$SELECT public.reverse_migration_batch(%L,'too late')$q$,:'j1'::jsonb->>'id'),'MIGRATION_SIGNED_OFF');
SELECT t.expect('the sign-offs list has it',jsonb_array_length(public.list_migration_signoffs()->'items')=1);
SELECT t.expect('the report marks the batch signed off and not reversible',
  (SELECT (b->>'signoff_id') IS NOT NULL AND NOT (b->>'can_reverse')::boolean FROM jsonb_array_elements(public.get_migration_report('{}')->'batches') b WHERE b->>'id'=:'j1'::jsonb->>'id'));
RESET ROLE;
DO $$ BEGIN
  BEGIN UPDATE public.migration_signoffs SET note='changed'; PERFORM t.expect('a sign-off cannot be edited',false);
  EXCEPTION WHEN others THEN PERFORM t.expect('a sign-off cannot be edited',true); END;
  BEGIN DELETE FROM public.migration_signoffs; PERFORM t.expect('a sign-off cannot be deleted',false);
  EXCEPTION WHEN others THEN PERFORM t.expect('a sign-off cannot be deleted',true); END;
END $$;

-- ================================================================ reversal of a wrong batch
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.fr(
  t.cl('K-300','29101010100501','4000','0',10,4,'1000.00'),
  t.cl('K-301','29101010100502','2000','0',10,2,'1000.00')) AS wrows \gset
SELECT t.dry('opening_contracts',:'wrows'::jsonb,'m02-dry-7') AS wj \gset
SELECT t.run(:'wj'::jsonb,:'wrows'::jsonb,'m02-run-7') AS wr \gset
RESET ROLE;
SELECT t.expect('a second batch imports (the first one stays untouched)',
  :'wr'::jsonb->>'status'='completed' AND (SELECT count(*)=6 FROM public.contracts WHERE organization_id=t.org('a') AND is_migrated));
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('reverse: a reason is required',format($q$SELECT public.reverse_migration_batch(%L,'x')$q$,:'wj'::jsonb->>'id'),'VALIDATION_FAILED');
SELECT public.reverse_migration_batch((:'wj'::jsonb->>'id')::uuid,'Wrong customers in the file') AS rv \gset
RESET ROLE;
SELECT t.expect('reversal: both contracts are written off through the write-off record, flagged reversed, and nothing was deleted',
  (:'rv'::jsonb->>'reversed_contracts')='2' AND :'rv'::jsonb#>>'{job,kind}'='opening_contracts'
  AND (SELECT count(*)=2 AND bool_and(status='written_off' AND closed_at IS NOT NULL AND (migration_source->>'reversed')='true') FROM public.contracts WHERE migration_batch_id=(:'wj'::jsonb->>'id')::uuid)
  AND (SELECT count(*)=2 AND bool_and(kind='write_off' AND reason LIKE 'Migration batch reversed: Wrong customers%' AND amount>0) FROM public.contract_changes cc JOIN public.contracts c ON c.id=cc.contract_id WHERE c.migration_batch_id=(:'wj'::jsonb->>'id')::uuid)
  AND (SELECT count(*)=6 FROM public.contracts WHERE organization_id=t.org('a') AND is_migrated),:'rv'::text);
SELECT t.expect('audit migration.batch_reversed (warning)',(SELECT severity='warning' AND reason='Wrong customers in the file' FROM public.audit_log WHERE action='migration.batch_reversed' AND entity_id=(:'wj'::jsonb->>'id')::uuid));
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.get_migration_report('{}') AS rep5 \gset
SELECT t.expect('the report leaves the reversed contracts out',:'rep5'::jsonb#>>'{totals,contracts}'='4' AND :'rep5'::jsonb#>>'{totals,imported_total}'='30000.00');
SELECT t.expect('reversing again is a no-op that answers the same count',public.reverse_migration_batch((:'wj'::jsonb->>'id')::uuid,'Wrong customers in the file')->>'reversed_contracts'='2'
  AND (SELECT count(*)=2 FROM public.contract_changes WHERE idempotency_key LIKE 'm02rev:%'));
SELECT t.error('a reversed batch cannot be signed off',format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','0','batch_ids',jsonb_build_array(%L),'note','signed again'))$q$,:'wj'::jsonb->>'id'),'VALIDATION_FAILED');
-- The corrected file with the same contract numbers imports again.
SELECT t.dry('opening_contracts',:'wrows'::jsonb,'m02-dry-8') AS wj2 \gset
SELECT t.expect('after a reversal the same contract numbers can be imported again',:'wj2'::jsonb->>'status'='validated',t.codes(:'wj2'::jsonb));
-- The opening cash batch is not reversible here.
SELECT t.error('an opening cash batch cannot be reversed here',format($q$SELECT public.reverse_migration_batch(%L,'try cash')$q$,:'cj1'::jsonb->>'id'),'IMPORT_JOB_NOT_FOUND');
RESET ROLE;

-- ================================================================ a closed day (K04) fails the import
DO $$
DECLARE v_job jsonb; v_cj jsonb; v_s1 text; v_c1 text; v_s2 text; v_c2 text;
BEGIN
  PERFORM t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
  BEGIN
    INSERT INTO public.day_closes(organization_id,branch_id,business_date,status,closed_by)
      VALUES(t.org('a'),t.id('main'),t.today(),'closed',(SELECT id FROM public.employees WHERE auth_user_id='a0900000-0000-0000-8000-000000000001'));
    v_job := t.dry('opening_contracts',t.fr(t.cl('K-400','29101010100501','1000','0',10,1,'1000.00')),'m02-dry-closed');
    v_cj := t.dry('opening_cash',t.rows('{"account_name":"Closed safe","kind":"safe","balance":"5"}'),'m02-cash-dry-closed');
    v_s1 := v_job->>'status'; v_c1 := t.codes(v_job); v_s2 := v_cj->>'status'; v_c2 := t.codes(v_cj);
    RAISE EXCEPTION 'T_ROLLBACK_CLOSED_DAY';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'T_ROLLBACK_CLOSED_DAY' THEN PERFORM t.expect('closed day block ran',false,SQLERRM); END IF;
  END;
  PERFORM t.expect('a closed today fails the dry run of contracts with DAY_CLOSED',v_s1='failed' AND v_c1='2:branch_code:DAY_CLOSED',v_c1);
  PERFORM t.expect('a closed today fails opening cash with a balance with DAY_CLOSED',v_s2='failed' AND v_c2='2:branch_code:DAY_CLOSED',v_c2);
  PERFORM t.expect('the closed-day rows were rolled back',(SELECT count(*)=0 FROM public.day_closes WHERE organization_id=t.org('a')));
END $$;
RESET ROLE;

-- ================================================================ another shop, plans, and the M01 kinds
SELECT t.as_user('a0900000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('another shop cannot read shop a''s batch in the report',format($q$SELECT public.get_migration_report(jsonb_build_object('batch_id',%L))$q$,:'j1'::jsonb->>'id'),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('another shop cannot sign off shop a''s batch',format($q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','30000','batch_ids',jsonb_build_array(%L),'note','not mine'))$q$,:'j1'::jsonb->>'id'),'IMPORT_JOB_NOT_FOUND');
SELECT t.error('another shop cannot reverse shop a''s batch',format($q$SELECT public.reverse_migration_batch(%L,'not mine at all')$q$,:'wj'::jsonb->>'id'),'IMPORT_JOB_NOT_FOUND');
SELECT t.expect('another shop sees no sign-offs and an empty report',jsonb_array_length(public.list_migration_signoffs()->'items')=0
  AND public.get_migration_report('{}')#>>'{totals,contracts}'='0');
SELECT t.error('another shop''s file is not found for an opening contracts import',format($q$SELECT public.create_import('opening_contracts',%L,NULL,%L::jsonb,'{}','m02-b-file')$q$,t.id('file'),:'frows'::text),'FILE_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0900000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('opening contracts take no branch id',format($q$SELECT public.create_import('opening_contracts',%L,%L,%L::jsonb,'{}','m02-branch')$q$,t.id('file'),t.id('main'),:'frows'::text),'VALIDATION_FAILED');
SELECT t.dry('customers',t.rows('{"full_name":"New Customer","phones":"01077770001"}'),'m02-m01-customers') AS mj \gset
SELECT t.expect('the M01 kinds still work',:'mj'::jsonb->>'status'='validated' AND (:'mj'::jsonb#>>'{report,actions,create}')::int=1 AND NOT (:'mj'::jsonb->'report' ? 'summary'),:'mj'::text);
RESET ROLE;

-- ================================================================ plumbing: field keys, codes, grants
SELECT t.expect('field keys: opening_contracts',app.import_kind_columns('opening_contracts')=ARRAY['contract_ref','customer_national_id','customer_phone','branch_code','contract_date','original_total','paid_before','frequency','remaining_principal','remaining_profit','notes','due_date','amount','guarantor1_national_id','guarantor1_name','guarantor1_phone','guarantor1_address','guarantor1_relation','guarantor2_national_id','guarantor2_name','guarantor2_phone','guarantor2_address','guarantor2_relation']);
SELECT t.expect('field keys: opening_cash',app.import_kind_columns('opening_cash')=ARRAY['branch_code','account_name','kind','bank_shop_wide','balance']);
SELECT t.expect('required keys of the two kinds',app.import_required_keys('opening_contracts')=ARRAY['import.data','installment.create','customer.create']
  AND app.import_required_keys('opening_cash')=ARRAY['import.data','cash.adjust','cash.account_manage']);
SELECT t.expect('every error code the SQL can report is one the contract knows',app.import_row_codes()=ARRAY['IMPORT_REQUIRED','IMPORT_INVALID_VALUE','IMPORT_DUPLICATE_ROW','IMPORT_AMBIGUOUS_MATCH','IMPORT_APPLY_FAILED','PRODUCT_ARCHIVED','PRODUCT_NOT_FOUND','PRODUCT_SKU_TAKEN','PRODUCT_BARCODE_TAKEN','PRODUCT_SERIAL_LOCKED','PRODUCT_CATEGORY_ARCHIVED','CATEGORY_DEPTH','CATEGORY_NAME_TAKEN','CUSTOMER_NATIONAL_ID_TAKEN','CUSTOMER_NATIONAL_ID_LOCKED','NATIONAL_ID_INVALID','SUPPLIER_PHONE_TAKEN','SUPPLIER_NAME_TAKEN','SERIAL_INVALID','SERIAL_TAKEN','UNIT_NOT_ALLOWED','UNIT_REQUIRED','OPENING_STOCK_LOCKED','TAX_CLASS_NOT_FOUND','MODULE_NOT_IN_PLAN','OUT_OF_STOCK','IMPORT_CONTRACT_ROWS_DIFFER','IMPORT_CONTRACT_NOT_BALANCED','IMPORT_CONTRACT_EXISTS','IMPORT_CUSTOMER_NOT_FOUND','IMPORT_GUARANTOR_INCOMPLETE','IMPORT_ACCOUNT_KIND','CASH_ACCOUNT_HAS_MOVEMENTS','CASH_ACCOUNT_INACTIVE','CASH_ACCOUNT_NAME_TAKEN','DAY_CLOSED','POLICY_NOT_SET']);
SELECT t.expect('the new functions are granted to authenticated only where they are routes; the helpers to nobody',
  has_function_privilege('authenticated','public.get_migration_report(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.sign_off_migration(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_migration_signoffs()','EXECUTE')
  AND has_function_privilege('authenticated','public.reverse_migration_batch(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.import_opening_contracts(uuid,uuid,jsonb,boolean,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.import_opening_cash(uuid,uuid,jsonb,boolean,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.migration_batch_blocker(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_migration_report(jsonb)','EXECUTE')
  AND NOT has_table_privilege('authenticated','public.migration_signoffs','SELECT'));

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
