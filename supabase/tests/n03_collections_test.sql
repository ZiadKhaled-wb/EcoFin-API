-- N03 collections (EC-82, D78).
-- Run by: node scripts/db-smoke.mjs supabase/tests/n03_collections_test.sql (inside BEGIN ... ROLLBACK).
-- A cashier at any branch takes a payment on one or several contracts of one customer, split over
-- cash and bank transfers: the allocation (oldest line first, profit then principal), the payment
-- rows under one receipt, the drawer, completion, same-day reversal, the reads and the visibility
-- rule. No late fees (Islamic finance rule 4), no overpayment, no store credit. Every refusal
-- leaves nothing behind. (Many requests at the same moment: scripts/db-stock-cash-proof.mjs.)
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from n02_installment_sale_test.sql).
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
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb @> detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE (jsonb_build_object('x-org-id',o) || COALESCE((SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.employees e ON e.id=s.employee_id JOIN public.devices d ON d.id=s.device_id WHERE s.organization_id=o AND s.status='open' AND d.is_active AND d.archived_at IS NULL AND d.token_hash IS NOT NULL ORDER BY (e.auth_user_id::text=u) DESC,s.opened_at DESC,s.id DESC LIMIT 1),'{}'::jsonb))::text END,false) $$;
-- A user on the device of a given shift (a manager reversing at the cashier's till).
CREATE FUNCTION t.as_on(u text,o uuid,p_shift uuid) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',u,false),set_config('app.org_id','',false),set_config('request.headers',(jsonb_build_object('x-org-id',o) || (SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.devices d ON d.id=s.device_id WHERE s.id=p_shift))::text,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
CREATE FUNCTION t.bal(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.pv() RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT (app.current_installment_policy(t.org('a'))).version $$;
CREATE FUNCTION t.remaining(c text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.contract_remaining(t.org('a'),t.id(c)) $$;
CREATE FUNCTION t.line(c text,s integer) RETURNS public.v_schedule_line_status LANGUAGE sql SECURITY DEFINER AS $$
  SELECT ls.* FROM public.v_schedule_line_status ls JOIN public.contracts k ON k.id=ls.contract_id
  WHERE ls.contract_id=t.id(c) AND ls.seq=s AND ls.version=k.current_version AND NOT ls.superseded $$;
CREATE FUNCTION t.sched(c text,s integer) RETURNS public.schedule_lines LANGUAGE sql SECURITY DEFINER AS $$
  SELECT l.* FROM public.schedule_lines l JOIN public.contracts k ON k.id=l.contract_id
  WHERE l.contract_id=t.id(c) AND l.seq=s AND l.version=k.current_version $$;
-- Everything a collection writes, counted for shop a.
CREATE FUNCTION t.footprint() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',
    (SELECT count(*) FROM public.payments WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.payment_allocations WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.cash_movements WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.store_credit_movements WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.contracts WHERE organization_id=t.org('a') AND status<>'active'),
    (SELECT COALESCE(sum(next_value),0) FROM public.document_counters WHERE organization_id=t.org('a') AND doc_type='payment'),
    (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action LIKE 'collection.%')) $$;
-- Bodies.
CREATE FUNCTION t.k(c text,amount text,expected text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('contract_id',t.id(c),'amount',amount,'expected_remaining',expected)) $$;
CREATE FUNCTION t.cash(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_array(jsonb_build_object('method','cash','amount',amount)) $$;
CREATE FUNCTION t.body(cust text,contracts jsonb,pay jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('customer_id',t.id(cust),'contracts',contracts,'payments',pay) $$;
CREATE FUNCTION t.collect(p_body jsonb,p_key text) RETURNS jsonb LANGUAGE sql AS $$ SELECT public.post_collection(p_body,p_key) $$;
CREATE FUNCTION t.q(p_body jsonb,p_key text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_collection(%L,%L)',p_body,COALESCE(p_key,'n03-key-'||md5(random()::text))) $$;
-- An installment sale (N02) with the commit-time checks run now.
CREATE FUNCTION t.sell(p_product text,p_price text,p_customer text,p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id(p_product),'quantity',1)),
    'expected_total',p_price,'customer_id',t.id(p_customer),
    'terms',jsonb_build_object('down_payment','2000.00','installments_count',12,'frequency','monthly','policy_version',t.pv())),p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (retail_pro), b (retail)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('N03 '||s,'n03-key-'||s,p,'Owner',s||'n03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('q',64)),('b','retail',repeat('r',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0780000-0000-0000-8000-000000000001','an03@example.com'),('a0780000-0000-0000-8000-000000000002','bn03@example.com'),
  ('a0780000-0000-0000-8000-000000000003','n03cashier@example.com'),('a0780000-0000-0000-8000-000000000004','n03warehouse@example.com'),
  ('a0780000-0000-0000-8000-000000000006','n03cashier2@example.com'),('a0780000-0000-0000-8000-000000000007','n03manager@example.com'),
  ('a0780000-0000-0000-8000-000000000008','n03viewer@example.com'),('a0780000-0000-0000-8000-000000000009','n03reverser@example.com');
SELECT public.accept_invite(repeat('q',64),'a0780000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('r',64),'a0780000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'owner',id FROM public.employees WHERE organization_id=t.org('a') AND role='OWNER';
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0 WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'));
SELECT t.as_user('a0780000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','N3',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"N3-TV","cash_price":"12000"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',30)),'n03-key-found');
SELECT public.post_stock_adjustment(t.id('second'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',5)),'n03-key-found-2');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
RESET ROLE;
SELECT t.as_user('a0780000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'bank-b',(public.create_cash_account('Bank B','bank',NULL)->>'id')::uuid;
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0780000-0000-0000-8000-000000000003','N03 Cashier','CASHIER');
SELECT t.emp('wh','a0780000-0000-0000-8000-000000000004','N03 Warehouse','WAREHOUSE');
SELECT t.emp('cashier2','a0780000-0000-0000-8000-000000000006','N03 Cashier Two','CASHIER','second');
SELECT t.emp('manager','a0780000-0000-0000-8000-000000000007','N03 Manager','BRANCH_MANAGER');
SELECT t.emp('viewer','a0780000-0000-0000-8000-000000000008','N03 Viewer','CASHIER');
SELECT t.emp('reverser','a0780000-0000-0000-8000-000000000009','N03 Reverser','CASHIER');
-- The viewer keeps a customer read key (sale.create) but not collection.create; the reverser is a
-- cashier the owner gave collection.reverse (F06 override).
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES
  (t.org('a'),t.id('viewer'),'collection.create',false),(t.org('a'),t.id('reverser'),'collection.reverse',true);
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text,p_nid text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,'active',p_nid) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('ok','Nadia Payer','01011112222','29101010100201');
SELECT t.cust('other','Omar Other','01033334444','29101010100202');
SELECT t.cust('rev','Rana Reverse','01055556666','29101010100203');
SELECT t.cust('fady','Fady Far','01077778888','29101010100204');
-- The policy: 20 % up to 24 months, no guarantor or survey needed below 1 000 000.
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');

-- The cashier opens a shift in the main branch, cashier2 in the second; the contracts are sold.
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','n03-key-shift-1');
INSERT INTO t.docs SELECT 's-c1',t.sell('tv','12000.00','ok','n03-key-sale-c1');
INSERT INTO t.docs SELECT 's-c2',t.sell('tv','12000.00','ok','n03-key-sale-c2');
INSERT INTO t.docs SELECT 's-c3',t.sell('tv','12000.00','other','n03-key-sale-c3');
INSERT INTO t.docs SELECT 's-r1',t.sell('tv','12000.00','rev','n03-key-sale-r1');
INSERT INTO t.docs SELECT 's-r2',t.sell('tv','12000.00','rev','n03-key-sale-r2');
RESET ROLE;
INSERT INTO t.ids SELECT 'shift',(t.doc('shift')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=t.id('shift');
INSERT INTO t.ids SELECT v,(t.doc('s-'||v)->'contract'->>'id')::uuid FROM unnest(ARRAY['c1','c2','c3','r1','r2']) v;
SELECT t.as_user('a0780000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift2',t.open_shift(t.id('second'),'0','n03-key-shift-2');
INSERT INTO t.docs SELECT 's-far',t.sell('tv','12000.00','fady','n03-key-sale-far');
RESET ROLE;
INSERT INTO t.ids SELECT 'shift2',(t.doc('shift2')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer2',drawer_account_id FROM public.shifts WHERE id=t.id('shift2');
INSERT INTO t.ids SELECT 'far',(t.doc('s-far')->'contract'->>'id')::uuid;
SELECT t.expect('setup: five contracts in the main branch and one in the second, 12 lines of 1000.00 each',
  (SELECT count(*)=6 FROM public.contracts WHERE organization_id=t.org('a') AND total_payable=12000)
  AND (SELECT branch_id=t.id('second') FROM public.contracts WHERE id=t.id('far'))
  AND (SELECT count(*)=12 AND min(amount)=1000 AND max(amount)=1000 FROM public.schedule_lines WHERE contract_id=t.id('c1')));

-- ================================================================ the slice's checks: allocation
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'prev',public.preview_collection(t.id('c1'),'2500.00');
RESET ROLE;
SELECT t.expect('preview: 2500.00 pays lines 1-2 and 500.00 of line 3, its profit first',
  (SELECT jsonb_array_length(x->'lines')=3
     AND x->'lines'->0->>'amount'='1000.00' AND (x->'lines'->0->>'pays_off')::boolean
     AND x->'lines'->1->>'amount'='1000.00'
     AND x->'lines'->2->>'amount'='500.00' AND NOT (x->'lines'->2->>'pays_off')::boolean
     AND (x->'lines'->2->>'profit')::numeric=(t.sched('c1',3)).profit
     AND (x->'lines'->2->>'principal')::numeric=500-(t.sched('c1',3)).profit
     AND NOT (x->>'completes_contract')::boolean
   FROM (SELECT t.doc('prev')->'allocation' x) y)
  AND t.doc('prev')->'due'->>'remaining'='12000.00' AND jsonb_array_length(t.doc('prev')->'lines')=12);
SELECT t.expect('allocation: the same contract state and amount give the same rows, every time',
  (SELECT array_agg(a ORDER BY a.seq)::text FROM app.collection_allocation(t.org('a'),t.id('c1'),3456.78) a)
  =(SELECT array_agg(a ORDER BY a.seq)::text FROM app.collection_allocation(t.org('a'),t.id('c1'),3456.78) a));
SELECT t.expect('preview: above the remaining -> exceeds_remaining, no lines (not an error)',
  (SELECT (x->>'exceeds_remaining')::boolean AND jsonb_array_length(x->'lines')=0
   FROM (SELECT public.preview_collection(t.id('c1'),'12000.01')->'allocation' x) y));

-- One installment in cash.
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
CREATE TEMP TABLE before_cash AS SELECT t.bal('drawer') v;
CREATE TEMP TABLE before_sales AS SELECT count(*) n FROM public.sales WHERE organization_id=t.org('a');
INSERT INTO t.docs SELECT 'k1',t.collect(t.body('ok',jsonb_build_array(t.k('c1','1000.00','12000.00')),t.cash('1000.00')),'n03-key-k1');
RESET ROLE;
INSERT INTO t.ids SELECT 'k1',(t.doc('k1')->>'id')::uuid;
SELECT t.expect('collect: 1000.00 pays line 1 exactly, profit and principal as the line has them',
  (SELECT paid=1000 AND paid_profit=profit AND paid_principal=principal AND status IN ('paid') FROM t.line('c1',1) l)
  AND (SELECT paid=0 FROM t.line('c1',2)));
SELECT t.expect('collect: one payment row, its own receipt (collection_id = id), the request key, the shift''s branch',
  (SELECT count(*)=1 FROM public.payments WHERE collection_id=t.id('k1'))
  AND (SELECT collection_id=id AND idempotency_key='n03-key-k1' AND direction='in' AND method='cash' AND amount=1000
            AND branch_id=t.id('main') AND shift_id=t.id('shift') AND customer_id=t.id('ok') AND cash_account_id=t.id('drawer')
       FROM public.payments WHERE id=t.id('k1')));
SELECT t.expect('collect: the drawer +1000.00 (one collection movement on the shift)',
  t.bal('drawer')=(SELECT v FROM before_cash)+1000
  AND (SELECT count(*)=1 AND sum(amount)=1000 AND bool_and(type='collection' AND shift_id=t.id('shift'))
       FROM public.cash_movements WHERE source_type='payment' AND source_id=t.id('k1')));
SELECT t.expect('answer: receipt number, customer, the contract with its allocation and what is left',
  (SELECT x->>'number' IS NOT NULL AND x->>'amount'='1000.00' AND x->'customer'->>'name'='Nadia Payer'
     AND jsonb_array_length(x->'payments')=1 AND x->'contracts'->0->>'number'=(SELECT number FROM public.contracts WHERE id=t.id('c1'))
     AND x->'contracts'->0->'after'->>'remaining'='11000.00' AND x->'contracts'->0->>'status'='active'
     AND jsonb_array_length(x->'contracts'->0->'allocation'->'lines')=1 AND x->'reversal'='null'::jsonb
   FROM (SELECT t.doc('k1') x) y));
SELECT t.expect('audit: collection.created (info) on the receipt, the shift''s branch',
  (SELECT count(*)=1 FROM public.audit_log WHERE action='collection.created' AND entity_id=t.id('k1') AND severity='info'
     AND branch_id=t.id('main') AND after->>'total'='1000.00'));
-- The same key again.
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
CREATE TEMP TABLE fp1 AS SELECT t.footprint() v;
INSERT INTO t.docs SELECT 'k1-again',t.collect(t.body('ok',jsonb_build_array(t.k('c1','1000.00')),t.cash('1000.00')),'n03-key-k1');
RESET ROLE;
SELECT t.expect('idempotency: the same key -> the same receipt, nothing written twice',
  t.doc('k1-again')->>'id'=t.id('k1')::text AND t.footprint()=(SELECT v FROM fp1));

-- 2500.00: lines 2-3 and 500.00 of line 4, its profit first.
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'k2',t.collect(t.body('ok',jsonb_build_array(t.k('c1','2500.00')),t.cash('2500.00')),'n03-key-k2');
RESET ROLE;
SELECT t.expect('collect: 2500.00 pays lines 2-3 and 500.00 of line 4 (its profit first)',
  (SELECT status='paid' FROM t.line('c1',2)) AND (SELECT status='paid' FROM t.line('c1',3))
  AND (SELECT paid=500 AND paid_profit=profit AND paid_principal=500-profit FROM t.line('c1',4))
  AND (SELECT paid=0 FROM t.line('c1',5)) AND t.remaining('c1')=8500);
SELECT t.expect('not a sale: no sale, stock movement or ETA receipt was written by collections',
  (SELECT count(*) FROM public.sales WHERE organization_id=t.org('a'))=(SELECT n FROM before_sales)
  AND NOT EXISTS (SELECT 1 FROM public.payment_allocations pa JOIN public.payments p ON p.id=pa.payment_id
                  WHERE p.collection_id IS NOT NULL AND (pa.sale_id IS NOT NULL OR pa.charge_id IS NOT NULL)));

-- ================================================================ split methods and several contracts
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
CREATE TEMP TABLE before_bank AS SELECT t.bal('bank') v;
INSERT INTO t.docs SELECT 'split',t.collect(t.body('ok',jsonb_build_array(t.k('c2','1000.00')),
  jsonb_build_array(jsonb_build_object('method','cash','amount','600.00','tendered','700.00'),
                    jsonb_build_object('method','bank_transfer','amount','400.00','cash_account_id',t.id('bank'),'reference','TRX-1'))),'n03-key-split');
RESET ROLE;
INSERT INTO t.ids SELECT 'split',(t.doc('split')->>'id')::uuid;
SELECT t.expect('split: two payment rows under one receipt (the first), drawer +600.00, bank +400.00 with no shift',
  (SELECT count(*)=2 AND sum(amount)=1000 FROM public.payments WHERE collection_id=t.id('split'))
  AND (SELECT method='cash' AND tendered=700 FROM public.payments WHERE id=t.id('split'))
  AND (SELECT idempotency_key='system:collection:'||t.id('split')||':2' AND method='bank_transfer' AND reference='TRX-1'
       FROM public.payments WHERE collection_id=t.id('split') AND id<>t.id('split'))
  AND t.bal('bank')=(SELECT v FROM before_bank)+400
  AND (SELECT shift_id IS NULL FROM public.cash_movements WHERE cash_account_id=t.id('bank') AND source_type='payment'
       AND source_id=(SELECT id FROM public.payments WHERE collection_id=t.id('split') AND id<>t.id('split'))));
SELECT t.expect('split: allocations spread over the two rows, each row balanced, line 1 paid profit first',
  (SELECT sum(pa.amount)=600 FROM public.payment_allocations pa WHERE pa.payment_id=t.id('split'))
  AND (SELECT sum(pa.amount)=400 AND sum(pa.profit_amount)=0 FROM public.payment_allocations pa
       JOIN public.payments p ON p.id=pa.payment_id WHERE p.collection_id=t.id('split') AND p.id<>t.id('split'))
  AND NOT EXISTS (SELECT 1 FROM public.payment_allocations pa JOIN public.payments p ON p.id=pa.payment_id
                  WHERE p.collection_id=t.id('split') AND pa.principal_amount+pa.profit_amount<>pa.amount)
  AND (SELECT status='paid' AND paid_profit=profit FROM t.line('c2',1)));
SELECT t.expect('split: the answer shows both lines with the change on the cash one',
  (SELECT jsonb_array_length(x->'payments')=2 AND x->'payments'->0->>'change'='100.00' FROM (SELECT t.doc('split') x) y));
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'multi',t.collect(t.body('ok',jsonb_build_array(t.k('c1','1000.00'),t.k('c2','500.00')),
  jsonb_build_array(jsonb_build_object('method','cash','amount','1200.00'),
                    jsonb_build_object('method','bank_transfer','amount','300.00','cash_account_id',t.id('bank'),'reference','TRX-2'))),'n03-key-multi');
RESET ROLE;
INSERT INTO t.ids SELECT 'multi',(t.doc('multi')->>'id')::uuid;
SELECT t.expect('several contracts: one receipt, c1 gets 1000.00 and c2 500.00 on their oldest open lines',
  (SELECT sum(pa.amount) FILTER (WHERE pa.contract_id=t.id('c1'))=1000 AND sum(pa.amount) FILTER (WHERE pa.contract_id=t.id('c2'))=500
   FROM public.payment_allocations pa JOIN public.payments p ON p.id=pa.payment_id WHERE p.collection_id=t.id('multi'))
  AND t.remaining('c1')=7500 AND t.remaining('c2')=10500
  AND (SELECT jsonb_array_length(x->'contracts')=2 AND x->'contracts'->1->>'amount'='500.00' FROM (SELECT t.doc('multi') x) y));

-- ================================================================ refusals (nothing written)
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
CREATE TEMP TABLE fp2 AS SELECT t.footprint() v;
SELECT t.error_detail('refused: one cent above what is left -> COLLECTION_EXCEEDS_REMAINING (nothing for c1 either)',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00'),t.k('c2','10500.01')),t.cash('10600.01'))),
  'COLLECTION_EXCEEDS_REMAINING',jsonb_build_object('contract_id',t.id('c2'),'remaining','10500.00'));
SELECT t.error('refused: another customer''s contract -> CONTRACT_NOT_FOUND',
  t.q(t.body('ok',jsonb_build_array(t.k('c3','100.00')),t.cash('100.00'))),'CONTRACT_NOT_FOUND');
SELECT t.error('refused: an unknown contract -> CONTRACT_NOT_FOUND',
  t.q(jsonb_build_object('customer_id',t.id('ok'),'contracts',jsonb_build_array(jsonb_build_object('contract_id',gen_random_uuid(),'amount','1.00')),'payments',t.cash('1.00'))),'CONTRACT_NOT_FOUND');
SELECT t.error('refused: the same contract twice -> VALIDATION_FAILED',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00'),t.k('c1','100.00')),t.cash('200.00'))),'VALIDATION_FAILED');
SELECT t.error('refused: a store credit line -> VALIDATION_FAILED',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00')),jsonb_build_array(jsonb_build_object('method','store_credit','amount','100.00')))),'VALIDATION_FAILED');
SELECT t.error_detail('refused: lines not adding up -> PAYMENT_TOTAL_MISMATCH',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00')),t.cash('90.00'))),'PAYMENT_TOTAL_MISMATCH',jsonb_build_object('total','100.00','paid','90.00'));
SELECT t.error_detail('refused: the screen''s remaining is old -> COLLECTION_DUE_CHANGED',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00','8500.00')),t.cash('100.00'))),'COLLECTION_DUE_CHANGED',jsonb_build_object('remaining','7500.00'));
SELECT t.error('refused: amount 0 -> VALIDATION_FAILED',t.q(t.body('ok',jsonb_build_array(t.k('c1','0.00')),t.cash('0.00'))),'VALIDATION_FAILED');
SELECT t.error('refused: three decimals -> VALIDATION_FAILED',t.q(t.body('ok',jsonb_build_array(t.k('c1','1.001')),t.cash('1.00'))),'VALIDATION_FAILED');
SELECT t.error('refused: tendered below the cash amount -> VALIDATION_FAILED',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00')),jsonb_build_array(jsonb_build_object('method','cash','amount','100.00','tendered','50.00')))),'VALIDATION_FAILED');
SELECT t.error('refused: two cash lines -> VALIDATION_FAILED',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00')),t.cash('50.00')||t.cash('50.00'))),'VALIDATION_FAILED');
SELECT t.error('refused: five payment lines -> VALIDATION_FAILED',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','5.00')),(SELECT jsonb_agg(jsonb_build_object('method','bank_transfer','amount','1.00','cash_account_id',t.id('bank'),'reference','R'||i)) FROM generate_series(1,5) i))),'VALIDATION_FAILED');
SELECT t.error('refused: an unknown field -> VALIDATION_FAILED',t.q(t.body('ok',jsonb_build_array(t.k('c1','1.00')),t.cash('1.00'))||'{"overpay":true}'),'VALIDATION_FAILED');
SELECT t.error('refused: shop B''s bank account -> VAULT_INVALID',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','100.00')),jsonb_build_array(jsonb_build_object('method','bank_transfer','amount','100.00','cash_account_id',t.id('bank-b'),'reference','X')))),'VAULT_INVALID');
SELECT t.error('refused: a key a sale used -> IDEMPOTENCY_CONFLICT',t.q(t.body('ok',jsonb_build_array(t.k('c1','1.00')),t.cash('1.00')),'n03-key-sale-c1'),'IDEMPOTENCY_CONFLICT');
SELECT t.error('refused: a system key -> VALIDATION_FAILED',t.q(t.body('ok',jsonb_build_array(t.k('c1','1.00')),t.cash('1.00')),'system:collection:x:2'),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.as_user('a0780000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('refused: no collection.create (warehouse) -> PERMISSION_DENIED',t.q(t.body('ok',jsonb_build_array(t.k('c1','1.00')),t.cash('1.00'))),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0780000-0000-0000-8000-000000000007',t.org('a'));
SET ROLE authenticated;
SELECT t.error('refused: no open shift (the manager) -> SHIFT_REQUIRED',t.q(t.body('ok',jsonb_build_array(t.k('c1','1.00')),t.cash('1.00'))),'SHIFT_REQUIRED');
RESET ROLE;
SELECT t.expect('refusals: nothing written, no number taken',t.footprint()=(SELECT v FROM fp2),t.footprint()||' vs '||(SELECT v FROM fp2));

-- ================================================================ no late fees (rule 4)
INSERT INTO public.charges(organization_id,contract_id,schedule_line_id,assessed_on,amount)
  VALUES(t.org('a'),t.id('c2'),(t.sched('c2',3)).id,current_date,50);
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('no fees: a charge on the contract is not in what is left nor in the preview',
  (SELECT x->'due'->>'remaining'='10500.00' AND NOT (x ? 'fees_due') AND NOT (x->'due' ? 'fees_due')
   FROM (SELECT public.preview_collection(t.id('c2'),'100.00') x) y));
INSERT INTO t.docs SELECT 'nofee',t.collect(t.body('ok',jsonb_build_array(t.k('c2','100.00')),t.cash('100.00')),'n03-key-nofee');
RESET ROLE;
SELECT t.expect('no fees: a collection never pays a charge',
  NOT EXISTS (SELECT 1 FROM public.payment_allocations WHERE charge_id IS NOT NULL AND organization_id=t.org('a')));

-- ================================================================ any branch
SELECT t.as_user('a0780000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
CREATE TEMP TABLE before_d2 AS SELECT t.bal('drawer2') v;
INSERT INTO t.docs SELECT 'far-branch',t.collect(t.body('ok',jsonb_build_array(t.k('c1','500.00')),t.cash('500.00')),'n03-key-far-branch');
RESET ROLE;
SELECT t.expect('any branch: a main-branch contract paid on a second-branch shift; the money and the payment are the second branch''s',
  (SELECT branch_id=t.id('second') AND shift_id=t.id('shift2') FROM public.payments WHERE id=(t.doc('far-branch')->>'id')::uuid)
  AND t.bal('drawer2')=(SELECT v FROM before_d2)+500 AND t.remaining('c1')=7000
  AND (SELECT branch_id=t.id('second') FROM public.cash_movements WHERE source_id=(t.doc('far-branch')->>'id')::uuid));

-- ================================================================ completion
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'close',t.collect(t.body('ok',jsonb_build_array(t.k('c1','7000.00','7000.00')),t.cash('7000.00')),'n03-key-close');
RESET ROLE;
SELECT t.expect('completion: the last payment closes the contract (completed, closed_at), every line paid',
  (SELECT status='completed' AND closed_at IS NOT NULL FROM public.contracts WHERE id=t.id('c1'))
  AND NOT EXISTS (SELECT 1 FROM public.v_schedule_line_status WHERE contract_id=t.id('c1') AND NOT superseded AND status<>'paid')
  AND (t.doc('close')->'contracts'->0->'allocation'->>'completes_contract')::boolean
  AND t.doc('close')->'contracts'->0->>'status'='completed');
SELECT t.expect('completion: contract.completed audited; R03 exposure no longer counts it',
  (SELECT count(*)=1 FROM public.audit_log WHERE action='contract.completed' AND entity_id=t.id('c1'))
  AND (SELECT exposure FROM public.v_customer_exposure WHERE customer_id=t.id('ok'))
      =(SELECT principal_outstanding FROM public.v_contract_balances WHERE contract_id=t.id('c2')));
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('completion: a completed contract takes no more -> CONTRACT_NOT_OPEN',
  t.q(t.body('ok',jsonb_build_array(t.k('c1','1.00')),t.cash('1.00'))),'CONTRACT_NOT_OPEN',jsonb_build_object('status','completed'));
SELECT t.expect('completion: the closing key again still returns its receipt',
  public.post_collection(t.body('ok',jsonb_build_array(t.k('c1','7000.00')),t.cash('7000.00')),'n03-key-close')->>'id'=t.doc('close')->>'id');
RESET ROLE;

-- ================================================================ reversal (the owner's example)
-- On the 12th the customer pays two installments, then takes the money back the same day.
CREATE TEMP TABLE rev_before AS SELECT (SELECT row_to_json(b)::text FROM public.v_contract_balances b WHERE contract_id=t.id('r1')) bal,
  (SELECT exposure FROM public.v_customer_exposure WHERE customer_id=t.id('rev')) exposure, t.bal('drawer') drawer, t.bal('bank') bank;
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r-pay',t.collect(t.body('rev',jsonb_build_array(t.k('r1','2000.00')),
  jsonb_build_array(jsonb_build_object('method','cash','amount','1500.00'),
                    jsonb_build_object('method','bank_transfer','amount','500.00','cash_account_id',t.id('bank'),'reference','TRX-R'))),'n03-key-r-pay');
RESET ROLE;
INSERT INTO t.ids SELECT 'r-pay',(t.doc('r-pay')->>'id')::uuid;
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('reversal: a cashier without collection.reverse -> PERMISSION_DENIED',
  format('SELECT public.reverse_collection(%L,%L,%L)',t.id('r-pay'),'{"reason":"changed mind"}','n03-key-rv-0'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_on('a0780000-0000-0000-8000-000000000007',t.org('a'),t.id('shift'));
SET ROLE authenticated;
SELECT t.error('reversal: no reason -> VALIDATION_FAILED',format('SELECT public.reverse_collection(%L,%L,%L)',t.id('r-pay'),'{"reason":" "}','n03-key-rv-x'),'VALIDATION_FAILED');
SELECT t.error('reversal: a payment row that is not a receipt -> COLLECTION_NOT_FOUND',
  format('SELECT public.reverse_collection(%L,%L,%L)',(SELECT id FROM public.payments WHERE collection_id=t.id('r-pay') AND id<>t.id('r-pay')),'{"reason":"changed mind"}','n03-key-rv-y'),'COLLECTION_NOT_FOUND');
INSERT INTO t.docs SELECT 'rv',public.reverse_collection(t.id('r-pay'),'{"reason":"changed mind"}','n03-key-rv-1');
INSERT INTO t.docs SELECT 'rv-again',public.reverse_collection(t.id('r-pay'),'{"reason":"changed mind"}','n03-key-rv-1');
SELECT t.error_detail('reversal: twice with another key -> COLLECTION_NOT_REVERSIBLE already_reversed',
  format('SELECT public.reverse_collection(%L,%L,%L)',t.id('r-pay'),'{"reason":"again"}','n03-key-rv-2'),'COLLECTION_NOT_REVERSIBLE',jsonb_build_object('reason','already_reversed'));
RESET ROLE;
SELECT t.expect('reversal: two out rows reverse the two rows, under one reversal receipt, with the reason',
  (SELECT count(*)=2 AND bool_and(r.direction='out' AND r.amount=p.amount AND r.method=p.method AND r.reason='changed mind')
     AND count(DISTINCT r.collection_id)=1
   FROM public.payments p JOIN public.payments r ON r.reverses_payment_id=p.id WHERE p.collection_id=t.id('r-pay'))
  AND (t.doc('rv')->'reversal'->>'number') IS NOT NULL AND t.doc('rv-again')->'reversal'->>'id'=t.doc('rv')->'reversal'->>'id');
SELECT t.expect('reversal: drawer and bank back where they were; the installments unpaid again',
  t.bal('drawer')=(SELECT drawer FROM rev_before) AND t.bal('bank')=(SELECT bank FROM rev_before)
  AND (SELECT paid=0 FROM t.line('r1',1)) AND (SELECT paid=0 FROM t.line('r1',2)));
SELECT t.expect('reversal: the contract, its balance and R03 exposure equal what they were before the collection',
  (SELECT row_to_json(b)::text FROM public.v_contract_balances b WHERE contract_id=t.id('r1'))=(SELECT bal FROM rev_before)
  AND (SELECT exposure FROM public.v_customer_exposure WHERE customer_id=t.id('rev'))=(SELECT exposure FROM rev_before));
SELECT t.expect('reversal: collection.reversed audited (warning, the reason)',
  (SELECT count(*)=1 FROM public.audit_log WHERE action='collection.reversed' AND entity_id=t.id('r-pay') AND severity='warning' AND reason='changed mind'));
-- ...and pays the 12th alone.
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r-one',t.collect(t.body('rev',jsonb_build_array(t.k('r1','1000.00')),t.cash('1000.00')),'n03-key-r-one');
INSERT INTO t.docs SELECT 'r-two',t.collect(t.body('rev',jsonb_build_array(t.k('r1','1000.00')),t.cash('1000.00')),'n03-key-r-two');
RESET ROLE;
SELECT t.expect('reversal: then the 12th alone pays line 1',(SELECT status='paid' FROM t.line('r1',1)) AND (SELECT status='paid' FROM t.line('r1',2)));
SELECT t.as_on('a0780000-0000-0000-8000-000000000009',t.org('a'),t.id('shift'));
SET ROLE authenticated;
SELECT t.error_detail('reversal: an older collection while a later one counts -> not_latest',
  format('SELECT public.reverse_collection(%L,%L,%L)',(t.doc('r-one')->>'id'),'{"reason":"wrong"}','n03-key-rv-3'),'COLLECTION_NOT_REVERSIBLE',jsonb_build_object('reason','not_latest'));
INSERT INTO t.docs SELECT 'rv-two',public.reverse_collection((t.doc('r-two')->>'id')::uuid,'{"reason":"wrong one"}','n03-key-rv-4');
RESET ROLE;
SELECT t.expect('reversal: a cashier the owner gave collection.reverse reverses the latest one',
  (SELECT paid=0 FROM t.line('r1',2)) AND (SELECT status='paid' FROM t.line('r1',1)));
-- A completing collection reversed reopens the contract.
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r2-all',t.collect(t.body('rev',jsonb_build_array(t.k('r2','12000.00')),t.cash('12000.00')),'n03-key-r2-all');
RESET ROLE;
SELECT t.as_on('a0780000-0000-0000-8000-000000000001',t.org('a'),t.id('shift'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'rv-r2',public.reverse_collection((t.doc('r2-all')->>'id')::uuid,'{"reason":"bank bounced"}','n03-key-rv-5');
RESET ROLE;
SELECT t.expect('reversal: a completed contract is active again (closed_at cleared, contract.reopened)',
  (SELECT status='completed' FROM jsonb_to_record(t.doc('r2-all')->'contracts'->0) AS x(status text))
  AND (SELECT status='active' AND closed_at IS NULL FROM public.contracts WHERE id=t.id('r2'))
  AND t.remaining('r2')=12000
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='contract.reopened' AND entity_id=t.id('r2')));
-- Not the same day: the collection's business date moved back (rows are append-only: replica role).
SET session_replication_role = replica;
UPDATE public.payments SET business_date=business_date-1 WHERE id=(t.doc('r-one')->>'id')::uuid;
SET session_replication_role = origin;
SELECT t.as_on('a0780000-0000-0000-8000-000000000007',t.org('a'),t.id('shift'));
SET ROLE authenticated;
SELECT t.error_detail('reversal: another business day -> not_same_day',
  format('SELECT public.reverse_collection(%L,%L,%L)',(t.doc('r-one')->>'id'),'{"reason":"late"}','n03-key-rv-6'),'COLLECTION_NOT_REVERSIBLE',jsonb_build_object('reason','not_same_day'));
RESET ROLE;

-- ================================================================ rescheduled contract
-- A seeded version 2 (N05 is not built): only its lines are paid.
SET session_replication_role = replica;
UPDATE public.schedule_lines SET superseded=true WHERE contract_id=t.id('c3') AND version=1;
INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit)
  SELECT t.org('a'),t.id('c3'),2,g,current_date+g*30,2500,500 FROM generate_series(1,4) g;
UPDATE public.contracts SET current_version=2,status='rescheduled' WHERE id=t.id('c3');
SET session_replication_role = origin;
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'v2',t.collect(t.body('other',jsonb_build_array(t.k('c3','3000.00')),t.cash('3000.00')),'n03-key-v2');
RESET ROLE;
SELECT t.expect('rescheduled: only version-2 lines are allocated',
  NOT EXISTS (SELECT 1 FROM public.payment_allocations pa JOIN public.schedule_lines l ON l.id=pa.schedule_line_id
              WHERE pa.payment_id=(t.doc('v2')->>'id')::uuid AND l.version<>2)
  AND (SELECT status='paid' FROM t.line('c3',1)) AND t.remaining('c3')=9000);

-- ================================================================ reads and visibility
SET session_replication_role = replica;
UPDATE public.schedule_lines SET due_date=current_date-40 WHERE contract_id=t.id('c2') AND seq=2;
SET session_replication_role = origin;
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('list: by contract number prefix, name, phone and exact national ID',
  (SELECT x->'items'->0->>'id'=t.id('c2')::text FROM (SELECT public.list_contracts(jsonb_build_object('q',(SELECT number FROM public.contracts WHERE id=t.id('c2')))) x) y)
  AND (SELECT jsonb_array_length(public.list_contracts('{"q":"nadia"}')->'items')=1)
  AND (SELECT jsonb_array_length(public.list_contracts('{"q":"3333"}')->'items')=1)
  AND (SELECT jsonb_array_length(public.list_contracts('{"q":"29101010100203"}')->'items')=2)
  AND (SELECT jsonb_array_length(public.list_contracts('{"q":"2910101010020"}')->'items')=0));
SELECT t.expect('list: completed contracts only with status all; overdue filter; customer filter',
  (SELECT jsonb_array_length(public.list_contracts(jsonb_build_object('customer_id',t.id('ok')))->'items')=1)
  AND (SELECT jsonb_array_length(public.list_contracts(jsonb_build_object('customer_id',t.id('ok'),'status','all'))->'items')=2)
  AND (SELECT jsonb_array_length(x->'items')=1 AND x->'items'->0->>'id'=t.id('c2')::text
       FROM (SELECT public.list_contracts('{"overdue":true}') x) y));
SELECT t.expect('list: the cursor pages through every branch (a cashier holds collection.create)',
  (SELECT jsonb_array_length(p1->'items')=2 AND p1->>'next_cursor' IS NOT NULL
     AND jsonb_array_length(public.list_contracts(jsonb_build_object('limit',2,'cursor',p1->>'next_cursor'))->'items')=2
   FROM (SELECT public.list_contracts('{"limit":2}') p1) y)
  AND (SELECT count(*)=5 FROM jsonb_array_elements(public.list_contracts('{}')->'items'))
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_contracts('{}')->'items') i WHERE i->>'id'=t.id('far')::text));
SELECT t.expect('visibility: the cashier opens a second-branch contract',(public.get_contract(t.id('far'))->>'id')=t.id('far')::text);
SELECT t.error('list: an unknown filter -> VALIDATION_FAILED','SELECT public.list_contracts(''{"branch":"x"}'')','VALIDATION_FAILED');
RESET ROLE;
SELECT t.as_user('a0780000-0000-0000-8000-000000000008',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('visibility: without the collection keys only the own branch''s contracts are listed',
  NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_contracts('{}')->'items') i WHERE i->>'id'=t.id('far')::text)
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_contracts('{}')->'items') i WHERE i->>'id'=t.id('c2')::text));
SELECT t.error('visibility: and another branch''s contract page -> CONTRACT_NOT_FOUND',format('SELECT public.get_contract(%L)',t.id('far')),'CONTRACT_NOT_FOUND');
SELECT t.error('visibility: no preview without collection.create -> PERMISSION_DENIED',format('SELECT public.preview_collection(%L)',t.id('c2')),'PERMISSION_DENIED');
SELECT t.error('visibility: no receipt without a collection key -> PERMISSION_DENIED',format('SELECT public.get_collection(%L)',t.id('k1')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('receipt: get_collection answers the receipt; a reversed one shows its reversal',
  (public.get_collection(t.id('k1'))->>'number')=(SELECT number FROM public.payments WHERE id=t.id('k1'))
  AND (public.get_collection(t.id('r-pay'))->'reversal'->>'reason')='changed mind');
SELECT t.error('receipt: a sale''s payment -> COLLECTION_NOT_FOUND',
  format('SELECT public.get_collection(%L)',(SELECT p.id FROM public.payments p JOIN public.payment_allocations a ON a.payment_id=p.id WHERE a.sale_id IS NOT NULL AND p.organization_id=t.org('a') LIMIT 1)),'COLLECTION_NOT_FOUND');
INSERT INTO t.docs SELECT 'print1',public.record_collection_receipt_print(t.id('k1'));
INSERT INTO t.docs SELECT 'print2',public.record_collection_receipt_print(t.id('k1'));
SELECT t.expect('print: the first print is the original, the next a copy',
  t.doc('print1')->'print'->>'copy'='false' AND t.doc('print2')->'print'->>'print_no'='2'
  AND t.doc('print2')->'print'->>'copy'='true' AND (public.get_collection(t.id('k1'))->>'receipt_prints')='2');
RESET ROLE;
SELECT t.as_user('a0780000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop B: shop A''s receipt -> COLLECTION_NOT_FOUND',format('SELECT public.get_collection(%L)',t.id('k1')),'COLLECTION_NOT_FOUND');
SELECT t.error('shop B: shop A''s contract preview -> CONTRACT_NOT_FOUND',format('SELECT public.preview_collection(%L)',t.id('c2')),'CONTRACT_NOT_FOUND');
SELECT t.expect('shop B: shop A''s contracts are not listed',jsonb_array_length(public.list_contracts('{}')->'items')=0);
RESET ROLE;

-- ================================================================ permissions: collection.reverse
SELECT t.expect('permission: collection.reverse exists (installments); OWNER and BRANCH_MANAGER hold it, a CASHIER does not',
  EXISTS (SELECT 1 FROM public.permissions WHERE key='collection.reverse' AND module='installments')
  AND EXISTS (SELECT 1 FROM public.role_permissions WHERE role='BRANCH_MANAGER' AND permission_key='collection.reverse')
  AND NOT EXISTS (SELECT 1 FROM public.role_permissions WHERE role='CASHIER' AND permission_key='collection.reverse'));

-- ================================================================ expired shop
UPDATE public.organizations SET subscription_start=NULL, subscription_end=app.org_today(id)-1 WHERE id=t.org('a');
SELECT t.as_user('a0780000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('expired: the preview and the receipt can still be read',
  (public.preview_collection(t.id('c2'))->'contract'->>'id')=t.id('c2')::text AND (public.get_collection(t.id('k1'))->>'id')=t.id('k1')::text);
SELECT t.error('expired: a collection is refused',t.q(t.body('ok',jsonb_build_array(t.k('c2','1.00')),t.cash('1.00'))),'SUBSCRIPTION_EXPIRED');
RESET ROLE;

-- ================================================================ ledgers and grants
SELECT t.expect('ledgers: every cash balance of shop a equals its movements',
  NOT EXISTS (SELECT 1 FROM public.cash_accounts a LEFT JOIN public.cash_balances b ON b.cash_account_id=a.id
              WHERE a.organization_id=t.org('a') AND COALESCE(b.balance,0)<>COALESCE((SELECT sum(amount) FROM public.cash_movements m WHERE m.cash_account_id=a.id),0)));
SELECT t.expect('ledgers: N03 wrote no store credit',NOT EXISTS (SELECT 1 FROM public.store_credit_movements WHERE organization_id=t.org('a')));
SELECT t.expect('grants: the helpers are not executable by authenticated; the six public functions are',
  NOT has_function_privilege('authenticated','app.post_collection_core(uuid,uuid,uuid,public.shifts,uuid,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.collection_allocation(uuid,uuid,numeric)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.collection_input(jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.collection_json(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_collection(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.post_collection(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.reverse_collection(uuid,jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.preview_collection(uuid,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_contracts(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_collection(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.record_collection_receipt_print(uuid)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
