-- S05 returns and exchanges (EC-72, D88).
-- Run by: node scripts/db-smoke.mjs supabase/tests/s05_returns_test.sql (inside BEGIN ... ROLLBACK).
-- A manager takes goods back against the original sale: amounts from the stored lines (a line
-- returned in pieces gives back exactly its total and tax), the exact serial, damaged stock kept
-- apart, money back by the sale's own methods or store credit, the period and its owner override,
-- a warranty claim's refund. The installment sale of the slice's Done when: two payments, one item
-- back, 4 280.00 left over 10 installments of 428.00; then the rest back and the overpaid part
-- refunded. An exchange up and down. The ETA return receipt waits for the sale's UUID. Ledgers,
-- R02's balance and statement, K04's returns, idempotency, other shops, grants.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from n05_contract_changes_test.sql).
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
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
CREATE FUNCTION t.pv() RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT (app.current_installment_policy(t.org('a'))).version $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.units WHERE serial=s AND organization_id=t.org('a') $$;
CREATE FUNCTION t.unit_status(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT status::text FROM public.units WHERE id=t.unit(s) $$;
CREATE FUNCTION t.level(p text,st text DEFAULT 'sellable') RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id('main') AND stock_state=st::public.stock_state),0) $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.credit(c text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$ SELECT COALESCE((SELECT balance FROM public.store_credit_balances WHERE customer_id=t.id(c)),0) $$;
CREATE FUNCTION t.line_of(sale text,p text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.sale_lines WHERE sale_id=t.id(sale) AND product_id=t.id(p) ORDER BY line_no LIMIT 1 $$;
CREATE FUNCTION t.rl(sale text,p text,q integer,cond text DEFAULT 'resellable',unit text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('sale_line_id',t.line_of(sale,p),'quantity',q,'condition',cond,'unit_id',t.unit(unit))) $$;
CREATE FUNCTION t.cashr(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method','cash','amount',amount) $$;
CREATE FUNCTION t.body(sale text,lines jsonb,refunds jsonb,expected text,extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('sale_id',t.id(sale),'lines',lines,'refunds',refunds,'expected_total',expected,
                            'reason','Customer changed his mind') || extra $$;
CREATE FUNCTION t.ret(sale text,lines jsonb,refunds jsonb,expected text,p_key text,extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_sales_return(t.body(sale,lines,refunds,expected,extra),p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
CREATE FUNCTION t.sell_inst(p_customer text,p_lines jsonb,p_total text,p_down text,p_key text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_installment_sale(jsonb_build_object('lines',p_lines,'expected_total',p_total,'customer_id',t.id(p_customer),
    'terms',jsonb_build_object('down_payment',p_down,'installments_count',12,'frequency','monthly','policy_version',t.pv())),p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
CREATE FUNCTION t.pay(c text,amount text,p_key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.post_collection(jsonb_build_object('customer_id',(SELECT customer_id FROM public.contracts WHERE id=t.id(c)),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id(c),'amount',amount)),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',amount))),p_key) $$;
CREATE FUNCTION t.k(c text) RETURNS public.contracts LANGUAGE sql SECURITY DEFINER AS $$ SELECT * FROM public.contracts WHERE id=t.id(c) $$;
CREATE FUNCTION t.cb(c text) RETURNS public.v_contract_balances LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.v_contract_balances WHERE contract_id=t.id(c) $$;
CREATE FUNCTION t.stmt(cust text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(sum(debit-credit),0) FROM app.customer_statement_rows(t.org('a'),t.id(cust)) $$;
CREATE FUNCTION t.open_balance(cust text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT (app.customer_open_balance(t.org('a'),t.id(cust))->>'open_balance')::numeric $$;
CREATE FUNCTION t.n(tbl text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v bigint; BEGIN EXECUTE format('SELECT count(*) FROM public.%I WHERE organization_id=%L',tbl,t.org('a')) INTO v; RETURN v; END $$;
CREATE FUNCTION t.counts() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',t.n('sales_returns'),t.n('sales_return_lines'),t.n('stock_movements'),t.n('payments'),t.n('cash_movements'),
                   t.n('store_credit_movements'),t.n('contract_changes'),t.n('fiscal_submissions'),
                   (SELECT sum(next_value) FROM public.document_counters WHERE organization_id=t.org('a') AND doc_type='sales_return')) $$;
CREATE FUNCTION t.unchanged(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE before text := t.counts(); BEGIN
  PERFORM t.error(n,q,c);
  PERFORM t.expect(n||' (nothing written)',t.counts()=before,before||' -> '||t.counts());
END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a and b
RESET ROLE;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S05 '||s,'s05-key-'||s,p,'Owner',s||'s05@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a','retail_pro',repeat('x',64)),('b','retail',repeat('y',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0500000-0000-0000-8000-000000000001','as05@example.com'),('a0500000-0000-0000-8000-000000000002','bs05@example.com'),
  ('a0500000-0000-0000-8000-000000000003','s05cashier@example.com'),('a0500000-0000-0000-8000-000000000004','s05manager@example.com'),
  ('a0500000-0000-0000-8000-000000000005','s05warehouse@example.com');
SELECT public.accept_invite(repeat('x',64),'a0500000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a0500000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0,return_policy_days=14
  WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id IN (t.org('a'),t.org('b'));
RESET ROLE;
SELECT t.as_user('a0500000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.set_eta_settings('preprod','client-s05','secret-s05-1','4753',true);
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('sofa',public.create_product('{"name_ar":"كنبة","name_en":"Sofa","sku":"S5-SOFA","cash_price":"6000"}'));
INSERT INTO t.ids VALUES('table',public.create_product('{"name_ar":"طاولة","name_en":"Table","sku":"S5-TABLE","cash_price":"4000"}'));
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"S5-CHAIR","cash_price":"250"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"هاتف","name_en":"Phone","sku":"S5-PHONE","cash_price":"5000","is_serialized":true,"warranty_months":12}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(
  jsonb_build_object('product_id',t.id('sofa'),'quantity',10),jsonb_build_object('product_id',t.id('table'),'quantity',10),
  jsonb_build_object('product_id',t.id('chair'),'quantity',40)),'s05-key-found');
SELECT public.register_units(t.id('phone'),t.id('main'),'3000.00','["S5-IMEI-1","S5-IMEI-2","S5-IMEI-3","S5-IMEI-4"]',NULL,'s05-key-units');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('S05 Bank','bank',NULL)->>'id')::uuid;
INSERT INTO t.ids SELECT 'bank2',(public.create_cash_account('S05 Other Bank','bank',NULL)->>'id')::uuid;
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id('main')) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id('main'));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a0500000-0000-0000-8000-000000000003','S05 Cashier','CASHIER');
SELECT t.emp('manager','a0500000-0000-0000-8000-000000000004','S05 Manager','BRANCH_MANAGER');
SELECT t.emp('wh','a0500000-0000-0000-8000-000000000005','S05 Warehouse','WAREHOUSE');
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),t.id('manager'),t.id('second'));
CREATE FUNCTION t.cust(p_tag text,p_name text,p_phone text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id)
    VALUES(t.org('a'),p_name,ARRAY[p_phone],500000,'active','291010101005'||right(p_phone,2)) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
SELECT t.cust('mona','Mona Cash','01033330001');
SELECT t.cust('ali','Ali Installments','01033330002');
SELECT t.cust('nina','Nina Nothing Paid','01033330003');
SELECT t.cust('wo','Walid WriteOff','01033330004');
-- N05's policy: 20 % up to 24 months, monthly, rounded to 1.
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'no_discount',0,
         1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');

-- The manager sells in an open shift.
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'0','s05-key-shift')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=t.id('shift');
-- s1: 4 chairs + phone 1 = 6 000, half cash, half bank.
INSERT INTO t.docs SELECT 's1',public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',4),
    jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',t.unit('S5-IMEI-1'))),'6000.00','s05-key-s1',t.id('mona'),
  jsonb_build_array(jsonb_build_object('method','cash','amount','3000.00'),
                    jsonb_build_object('method','bank_transfer','amount','3000.00','cash_account_id',t.id('bank'),'reference','S05 T1')));
-- s2: 2 chairs cash (the period case), s3: 1 chair (the other branch case), s4: 1 chair (voided),
-- s5: 2 chairs cash (exchanges), s6: phone 3 to mona (warranty claim).
INSERT INTO t.docs SELECT 's'||n,public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',q)),
  (q*250)::numeric(18,2)::text,'s05-key-s'||n,t.id('mona'),NULL) FROM (VALUES(2,2),(3,1),(4,1),(5,2))v(n,q);
INSERT INTO t.docs SELECT 's6',public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',t.unit('S5-IMEI-3'))),
  '5000.00','s05-key-s6',t.id('mona'),NULL);
RESET ROLE;
INSERT INTO t.ids SELECT tag,(j->>'id')::uuid FROM t.docs WHERE tag IN ('s1','s2','s3','s4','s5','s6');
SELECT t.expect('setup: sales in, drawer 3000+500+250+250+500+5000, bank 3000, chairs 40-10, phone 1 and 3 sold',
  t.cash('drawer')=9500 AND t.cash('bank')=3000 AND t.level('chair')=30 AND t.unit_status('S5-IMEI-1')='sold'
  AND t.unit_status('S5-IMEI-3')='sold',concat_ws(' ',t.cash('drawer'),t.cash('bank'),t.level('chair')));

-- ================================================================ reads and the quote
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r1-able',public.get_sale_returnable(t.id('s1'));
INSERT INTO t.docs SELECT 'q1',public.quote_sales_return(t.body('s1',jsonb_build_array(t.rl('s1','chair',1)),NULL,NULL));
RESET ROLE;
SELECT t.expect('returnable: two lines, 4 chairs and the phone, paid half and half, deadline sale + 14',
  jsonb_array_length(t.doc('r1-able')->'lines')=2
  AND (SELECT (x->>'returnable')::int=4 FROM jsonb_array_elements(t.doc('r1-able')->'lines') x WHERE x->>'sku'='S5-CHAIR')
  AND t.doc('r1-able')->'paid_by_method'->>'cash'='3000.00' AND t.doc('r1-able')->'paid_by_method'->>'bank_transfer'='3000.00'
  AND t.doc('r1-able')->>'deadline'=(t.today()+14)::text AND t.doc('r1-able')->'contract'='null'::jsonb
  AND t.doc('r1-able')->'blocked'='null'::jsonb,t.doc('r1-able')::text);
SELECT t.expect('quote: one chair = 250.00 with its VAT (1000 * 14/114 = 122.81 over 4: 30.70), nothing written',
  t.doc('q1')->>'total'='250.00' AND t.doc('q1')->>'tax_total'='30.70' AND t.doc('q1')->>'refund_due'='250.00'
  AND (SELECT count(*)=0 FROM public.sales_returns WHERE organization_id=t.org('a')),t.doc('q1')::text);

-- ================================================================ cash sale: pieces, methods, caps
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('a reason is required',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00')-'reason','s05-key-noreason'),'REASON_REQUIRED');
SELECT t.unchanged('the cashier''s total must be the server''s',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(t.cashr('240.00')),'240.00'),'s05-key-price'),'PRICE_CHANGED');
SELECT t.unchanged('refunds must add up to the return',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(t.cashr('200.00')),'250.00'),'s05-key-sum'),'PAYMENT_TOTAL_MISMATCH');
INSERT INTO t.docs SELECT 'r1',t.ret('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00','s05-key-r1');
INSERT INTO t.docs SELECT 'r1-again',t.ret('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00','s05-key-r1');
SELECT t.unchanged('a key used for another sale is IDEMPOTENCY_CONFLICT',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s2',jsonb_build_array(t.rl('s2','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00'),'s05-key-r1'),'IDEMPOTENCY_CONFLICT');
SELECT t.unchanged('a system key is refused',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00'),'system:return:x'),'VALIDATION_FAILED');
RESET ROLE;
INSERT INTO t.ids SELECT 'r1',(t.doc('r1')->>'id')::uuid;
SELECT t.expect('r1: one RT, the chair back, 250 out of the drawer, tax 30.70, refund method cash',
  t.doc('r1')->>'number' LIKE '%-RT-%' AND t.doc('r1')->>'kind'='return' AND t.doc('r1')->>'total'='250.00'
  AND t.doc('r1')->>'tax_total'='30.70' AND t.doc('r1')->>'refund_method'='cash' AND t.level('chair')=31
  AND t.cash('drawer')=9250 AND jsonb_array_length(t.doc('r1')->'refunds')=1,t.doc('r1')::text);
SELECT t.expect('replay: the same return, nothing new',
  t.doc('r1-again')->>'id'=t.doc('r1')->>'id' AND (t.doc('r1-again')->>'replayed')::boolean AND t.n('sales_returns')=1);
SELECT t.expect('r1 moved stock once: one sale_return_in on its return line, at the line cost',
  (SELECT count(*)=1 AND bool_and(m.quantity=1 AND m.stock_state='sellable' AND m.source_line_id IS NOT NULL AND m.unit_cost=0)
   FROM public.stock_movements m WHERE m.source_type='sales_return' AND m.source_id=t.id('r1')));

SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('three chairs left: four is RETURN_QTY_EXCEEDED',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','chair',4)),jsonb_build_array(t.cashr('1000.00')),'1000.00'),'s05-key-over'),
  'RETURN_QTY_EXCEEDED',jsonb_build_object('returnable',3));
SELECT t.unchanged('another serial is RETURN_UNIT_MISMATCH',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','phone',1,'resellable','S5-IMEI-2')),jsonb_build_array(t.cashr('2000.00')),'5000.00'),'s05-key-serial'),
  'RETURN_UNIT_MISMATCH');
SELECT t.unchanged('a serialized line without its unit is RETURN_UNIT_MISMATCH',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','phone',1)),jsonb_build_array(t.cashr('2000.00')),'5000.00'),'s05-key-nounit'),
  'RETURN_UNIT_MISMATCH');
SELECT t.error_detail('the bank gave 3 000: 3 500 back by bank is REFUND_EXCEEDS_PAID',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','phone',1,'damaged','S5-IMEI-1')),jsonb_build_array(t.cashr('1500.00'),
    jsonb_build_object('method','bank_transfer','amount','3500.00','cash_account_id',t.id('bank'),'reference','S05 back')),'5000.00'),'s05-key-cap'),
  'REFUND_EXCEEDS_PAID',jsonb_build_object('method','bank_transfer','available','3000.00'));
SELECT t.error_detail('cash: 3 000 paid, 250 back already: 2 751 is REFUND_EXCEEDS_PAID',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','phone',1,'damaged','S5-IMEI-1')),jsonb_build_array(t.cashr('2751.00'),
    jsonb_build_object('method','store_credit','amount','2249.00')),'5000.00'),'s05-key-cap2'),
  'REFUND_EXCEEDS_PAID',jsonb_build_object('method','cash','available','2750.00'));
SELECT t.unchanged('a bank the sale was not paid into is VAULT_INVALID',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s1',jsonb_build_array(t.rl('s1','phone',1,'damaged','S5-IMEI-1')),jsonb_build_array(
    jsonb_build_object('method','bank_transfer','amount','5000.00','cash_account_id',t.id('bank2'),'reference','S05 back')),'5000.00'),'s05-key-bank2'),
  'VAULT_INVALID');
-- The phone comes back damaged: 3 000 to the bank it came from, 2 000 as store credit (any part).
INSERT INTO t.docs SELECT 'r2',t.ret('s1',jsonb_build_array(t.rl('s1','phone',1,'damaged','S5-IMEI-1')),jsonb_build_array(
    jsonb_build_object('method','bank_transfer','amount','3000.00','cash_account_id',t.id('bank'),'reference','S05 back'),
    jsonb_build_object('method','store_credit','amount','2000.00')),'5000.00','s05-key-r2');
-- The other three chairs, one by one: 30.70, 30.71 (cumulative rounding), 30.70.
INSERT INTO t.docs SELECT 'r3',t.ret('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(jsonb_build_object('method','store_credit','amount','250.00')),'250.00','s05-key-r3');
INSERT INTO t.docs SELECT 'r4',t.ret('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(jsonb_build_object('method','store_credit','amount','250.00')),'250.00','s05-key-r4');
INSERT INTO t.docs SELECT 'r5',t.ret('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(jsonb_build_object('method','store_credit','amount','250.00')),'250.00','s05-key-r5');
INSERT INTO t.docs SELECT 's1-after',public.get_sale_details(t.id('s1'));
INSERT INTO t.docs SELECT 's1-able',public.get_sale_returnable(t.id('s1'));
RESET ROLE;
SELECT t.expect('r2: the damaged phone is in damaged stock, the unit returned (not sellable), bank -3000, credit +2000 (+750 for the chairs below)',
  t.unit_status('S5-IMEI-1')='returned' AND t.level('phone','damaged')=1 AND t.level('phone')=2 AND t.cash('bank')=0
  AND t.credit('mona')=2750 AND t.doc('r2')->>'refund_method'='bank_transfer',
  concat_ws(' ',t.unit_status('S5-IMEI-1'),t.level('phone','damaged'),t.level('phone'),t.cash('bank'),t.credit('mona')));
SELECT t.expect('pieces: the chair line gave back exactly its 1000.00 and 122.81 (30.70 + 30.71 + 30.70 + 30.70)',
  (SELECT sum(rl.refund_amount)=1000 AND sum(rl.tax_amount)=122.81 FROM public.sales_return_lines rl WHERE rl.sale_line_id=t.line_of('s1','chair'))
  AND t.doc('r3')->>'tax_total'='30.71' AND t.doc('r4')->>'tax_total'='30.70' AND t.doc('r5')->>'tax_total'='30.70',
  (SELECT string_agg(rl.tax_amount::text,',' ORDER BY rl.created_at) FROM public.sales_return_lines rl WHERE rl.sale_line_id=t.line_of('s1','chair')));
SELECT t.expect('s1 fully returned: status returned, nothing returnable, mona has 2 750 of credit',
  t.doc('s1-after')->>'status'='returned' AND jsonb_array_length(t.doc('s1-after')->'returns')=5
  AND t.doc('s1-able')->>'blocked'='fully_returned' AND t.credit('mona')=2750);
SELECT t.expect('mona''s statement: sales minus payments minus returns = minus her store credit (R02 rule)',
  t.stmt('mona')=-t.credit('mona'),concat_ws(' ',t.stmt('mona'),t.credit('mona')));

-- ================================================================ refusals
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT public.void_sale(t.id('s4'),'Wrong customer','s05-key-void4');
SELECT t.unchanged('a voided sale has nothing to return',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s4',jsonb_build_array(t.rl('s4','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00'),'s05-key-voided'),'ALREADY_VOIDED');
RESET ROLE;
SET LOCAL session_replication_role = replica;
UPDATE public.sales SET business_date=business_date-20 WHERE id=t.id('s2');
UPDATE public.sales SET business_date=business_date-30 WHERE id=t.id('s6');
UPDATE public.sales SET branch_id=t.id('second') WHERE id=t.id('s3');
SET LOCAL session_replication_role = origin;
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('20 days old, the manager: RETURN_PERIOD_EXPIRED with the deadline',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s2',jsonb_build_array(t.rl('s2','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00'),'s05-key-late'),
  'RETURN_PERIOD_EXPIRED',jsonb_build_object('deadline',(t.today()-6)::text));
SELECT t.unchanged('the sale of another branch is RETURN_OTHER_BRANCH',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s3',jsonb_build_array(t.rl('s3','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00'),'s05-key-branch'),'RETURN_OTHER_BRANCH');
SELECT t.unchanged('a line of another sale is refused',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s5',jsonb_build_array(jsonb_build_object('sale_line_id',t.line_of('s2','chair'),'quantity',1)),jsonb_build_array(t.cashr('250.00')),'250.00'),
  's05-key-otherline'),'VALIDATION_FAILED');
SELECT t.unchanged('an unknown key in the body is refused',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s5',jsonb_build_array(t.rl('s5','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00','{"fee":"10"}'),'s05-key-fee'),'VALIDATION_FAILED');
-- S12: an open claim on phone 3 (sold 30 days ago) lifts the period; the claim closes.
INSERT INTO t.ids SELECT 'claim',(public.open_warranty_claim(t.line_of('s6','phone'),t.unit('S5-IMEI-3'),'Screen failed','Fine','s05-key-claim')->>'claim_id')::uuid;
INSERT INTO t.docs SELECT 'claim-refund',public.request_claim_refund(t.id('claim'));
SELECT t.unchanged('a warranty claim lifts the period for its own line only, not another line with it',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s6',jsonb_build_array(t.rl('s6','phone',1,'damaged','S5-IMEI-3'),jsonb_build_object('sale_line_id',t.line_of('s2','chair'),'quantity',1)),
    jsonb_build_array(t.cashr('5250.00')),'5250.00',jsonb_build_object('warranty_claim_id',t.id('claim'))),'s05-key-claim-extra'),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'r6',t.ret('s6',jsonb_build_array(t.rl('s6','phone',1,'damaged','S5-IMEI-3')),jsonb_build_array(t.cashr('5000.00')),
  '5000.00','s05-key-r6',jsonb_build_object('warranty_claim_id',t.id('claim')));
RESET ROLE;
SELECT t.expect('claim refund: the claim answers its sale, line and unit',
  t.doc('claim-refund')->>'sale_id'=t.id('s6')::text AND t.doc('claim-refund')->>'unit_id'=t.unit('S5-IMEI-3')::text,
  t.doc('claim-refund')::text);
SELECT t.expect('claim refund: the return passes the period and closes the claim',
  (SELECT status='closed' AND resolution LIKE '%refunded by %-RT-%' FROM public.warranty_claims WHERE id=t.id('claim'))
  AND t.doc('r6')->>'total'='5000.00',(SELECT status||' '||COALESCE(resolution,'') FROM public.warranty_claims WHERE id=t.id('claim')));
-- The owner passes the period (a warning in the audit).
SELECT t.as_user('a0500000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'owner_shift',(t.open_shift(t.id('main'),'0','s05-key-owner-shift')->>'id')::uuid;
RESET ROLE;
-- the owner's drawer has no cash: store credit
SELECT t.as_user('a0500000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r7',t.ret('s2',jsonb_build_array(t.rl('s2','chair',1)),jsonb_build_array(jsonb_build_object('method','store_credit','amount','250.00')),'250.00','s05-key-r7');
SELECT t.unchanged('the owner''s empty drawer can''t pay cash: INSUFFICIENT_FUNDS',format('SELECT public.post_sales_return(%L,%L)',
  t.body('s2',jsonb_build_array(t.rl('s2','chair',1)),jsonb_build_array(t.cashr('250.00')),'250.00'),'s05-key-empty'),'INSUFFICIENT_FUNDS');
RESET ROLE;
SELECT t.expect('owner override: the late return is posted and audited as a warning',
  (SELECT severity='warning' AND after->>'period_override'='true' FROM public.audit_log
   WHERE organization_id=t.org('a') AND action='sales_return.created' AND entity_id=(t.doc('r7')->>'id')::uuid));
SELECT t.as_user('a0500000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('a cashier has no refund.create','SELECT public.get_sale_returnable('''||t.id('s5')||''')','PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0500000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b: shop a''s sale is SALE_NOT_FOUND','SELECT public.get_sale_returnable('''||t.id('s5')||''')','SALE_NOT_FOUND');
SELECT t.error('shop b: shop a''s return is RETURN_NOT_FOUND','SELECT public.get_sales_return('''||t.id('r1')||''')','RETURN_NOT_FOUND');
SELECT t.expect('shop b: lists none of shop a''s returns',(public.list_sales_returns('{}')->>'total_count')::int=0);
RESET ROLE;

-- ================================================================ exchange
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'x-before',jsonb_build_object('drawer',t.cash('drawer'),'table',t.level('table'),'chair',t.level('chair'));
INSERT INTO t.docs SELECT 'qx',public.quote_sales_return(t.body('s5',jsonb_build_array(t.rl('s5','chair',1)),NULL,NULL,
  jsonb_build_object('kind','exchange','new_sale',jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',t.id('table'),'quantity',1))))));
-- Up: one chair (250) for a table (4 000): the customer pays 3 750 in cash.
INSERT INTO t.docs SELECT 'x1',t.ret('s5',jsonb_build_array(t.rl('s5','chair',1)),'[]','250.00','s05-key-x1',
  jsonb_build_object('kind','exchange','new_sale',jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',t.id('table'),'quantity',1)),
    'expected_total','4000.00','payments',jsonb_build_array(t.cashr('3750.00')))));
RESET ROLE;
INSERT INTO t.ids SELECT 'x1sale',(t.doc('x1')->'exchange_sale'->>'id')::uuid;
SELECT t.expect('exchange quote: credit 250 used, 3 750 to pay',
  t.doc('qx')->'exchange'->>'new_total'='4000.00' AND t.doc('qx')->'exchange'->>'credit_used'='250.00'
  AND t.doc('qx')->'exchange'->>'to_pay'='3750.00' AND t.doc('qx')->>'refund_due'='0.00',t.doc('qx')::text);
SELECT t.expect('exchange up: kind exchange linked to a new 4 000 sale paid 3 750 + the 250 credit; drawer +3 750; chair +1, table -1',
  t.doc('x1')->>'kind'='exchange' AND t.doc('x1')->'exchange_sale'->>'total'='4000.00'
  AND t.cash('drawer')=(t.doc('x-before')->>'drawer')::numeric+3750
  AND t.level('chair')=(t.doc('x-before')->>'chair')::int+1 AND t.level('table')=(t.doc('x-before')->>'table')::int-1
  AND (SELECT sum(a.amount)=4000 FROM public.payment_allocations a JOIN public.payments p ON p.id=a.payment_id
       WHERE a.sale_id=t.id('x1sale') AND p.direction='in')
  AND (SELECT count(*)=2 FROM public.payments WHERE organization_id=t.org('a') AND idempotency_key LIKE 'system:exchange:%'),
  concat_ws(' ',t.cash('drawer'),t.doc('x-before')::text,t.doc('x1')::text));
-- Down: that table (4 000) back for two chairs (500): 3 500 back in cash.
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'x2-before',jsonb_build_object('drawer',t.cash('drawer'));
INSERT INTO t.docs SELECT 'x2',t.ret('x1sale',jsonb_build_array(t.rl('x1sale','table',1)),jsonb_build_array(t.cashr('3500.00')),'4000.00','s05-key-x2',
  jsonb_build_object('kind','exchange','new_sale',jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',2)),
    'expected_total','500.00')));
RESET ROLE;
SELECT t.expect('exchange down: 3 500 back from the drawer, the new sale fully paid by the credit',
  t.cash('drawer')=(t.doc('x2-before')->>'drawer')::numeric-3500 AND t.doc('x2')->'exchange_sale'->>'total'='500.00',
  concat_ws(' ',t.cash('drawer'),t.doc('x2-before')::text));

-- ================================================================ installment sale (the Done when)
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'ali-sale',t.sell_inst('ali',jsonb_build_array(jsonb_build_object('product_id',t.id('sofa'),'quantity',1),
  jsonb_build_object('product_id',t.id('table'),'quantity',1)),'10000.00','1000.00','s05-key-ali');
RESET ROLE;
INSERT INTO t.ids SELECT 'ali-s',(t.doc('ali-sale')->'sale'->>'id')::uuid;
INSERT INTO t.ids SELECT 'c-ali',(t.doc('ali-sale')->'contract'->>'id')::uuid;
SELECT t.expect('setup: 10 000 sale, 1 000 down, 9 000 financed, 1 800 profit, 12 lines of 900 (750 + 150)',
  (t.k('c-ali')).financed_amount=9000 AND (t.k('c-ali')).markup_amount=1800
  AND (SELECT count(*)=12 AND bool_and(amount=900 AND principal=750 AND profit=150) FROM public.schedule_lines WHERE contract_id=t.id('c-ali')));
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.pay('c-ali','900.00','s05-key-pay1');
SELECT t.pay('c-ali','900.00','s05-key-pay2');
SELECT t.unchanged('an exchange of an installment sale is refused',format('SELECT public.post_sales_return(%L,%L)',
  t.body('ali-s',jsonb_build_array(t.rl('ali-s','table',1)),'[]','4000.00',jsonb_build_object('kind','exchange','new_sale',
    jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',1)),'expected_total','250.00'))),'s05-key-xinst'),
  'EXCHANGE_NOT_FOR_CONTRACT');
INSERT INTO t.docs SELECT 'qa',public.quote_sales_return(t.body('ali-s',jsonb_build_array(t.rl('ali-s','table',1)),NULL,NULL));
INSERT INTO t.docs SELECT 'ra',t.ret('ali-s',jsonb_build_array(t.rl('ali-s','table',1)),'[]','4000.00','s05-key-ra');
RESET ROLE;
SELECT t.expect('quote: credit 4 000 + 720 profit share = 4 720; 9 000 left -> 4 280; 10 installments of 428.00',
  t.doc('qa')->'contract'->>'credit'='4720.00' AND t.doc('qa')->'contract'->>'remaining_before'='9000.00'
  AND t.doc('qa')->'contract'->>'remaining_after'='4280.00' AND (t.doc('qa')->'contract'->>'installments_left')::int=10
  AND t.doc('qa')->'contract'->>'installment_amount'='428.00' AND t.doc('qa')->'contract'->>'overpaid'='0.00',t.doc('qa')::text);
SELECT t.expect('Done when: after two payments one item back leaves 4 280.00 (3 500 principal + 780 profit) over 10 lines of 428',
  t.doc('ra')->>'refund_method'='contract_adjustment' AND (t.cb('c-ali')).remaining=4280
  AND (SELECT count(*)=10 AND bool_and(amount=428) AND sum(principal)=3500 AND sum(profit)=780
       FROM public.schedule_lines WHERE contract_id=t.id('c-ali') AND NOT superseded)
  AND (t.k('c-ali')).current_version=2 AND (t.k('c-ali')).status='active'
  AND (SELECT count(*)=1 AND bool_and(kind='return_adjustment' AND amount=4280 AND sales_return_id=(t.doc('ra')->>'id')::uuid)
       FROM public.contract_changes WHERE contract_id=t.id('c-ali')),
  concat_ws(' ',(t.cb('c-ali')).remaining,(SELECT string_agg(amount::text,',' ORDER BY seq) FROM public.schedule_lines WHERE contract_id=t.id('c-ali') AND NOT superseded)));
SELECT t.expect('the new lines keep the old due dates (lines 3..12)',
  (SELECT array_agg(due_date ORDER BY seq) FROM public.schedule_lines WHERE contract_id=t.id('c-ali') AND version=2)
  =(SELECT array_agg(due_date ORDER BY seq) FROM public.schedule_lines WHERE contract_id=t.id('c-ali') AND version=1 AND seq>2));
SELECT t.expect('R02: open balance = the view''s remaining = the statement (4 280)',
  t.open_balance('ali')=4280 AND t.stmt('ali')=4280
  AND (app.customer_open_balance(t.org('a'),t.id('ali'))->>'returns')::numeric=4720,
  concat_ws(' ',t.open_balance('ali'),t.stmt('ali'),app.customer_open_balance(t.org('a'),t.id('ali'))::text));
SELECT t.expect('stock +1 table, no money moved, tax of the table reversed once (4000 * 14/114 = 491.23)',
  (SELECT count(*)=0 FROM public.payment_allocations WHERE return_id=(t.doc('ra')->>'id')::uuid)
  AND t.doc('ra')->>'tax_total'='491.23');
-- The rest back: credit 6 000 + 1 080 = 7 080 > 4 280 left: 2 800 overpaid, refunded in cash; status returned.
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('the overpaid part must be refunded in full',format('SELECT public.post_sales_return(%L,%L)',
  t.body('ali-s',jsonb_build_array(t.rl('ali-s','sofa',1)),'[]','6000.00'),'s05-key-rb0'),'PAYMENT_TOTAL_MISMATCH');
INSERT INTO t.docs SELECT 'rb',t.ret('ali-s',jsonb_build_array(t.rl('ali-s','sofa',1)),jsonb_build_array(t.cashr('2800.00')),'6000.00','s05-key-rb');
RESET ROLE;
SELECT t.expect('all back: contract returned, nothing left, 2 800 paid back, the statement closes at 0',
  (t.k('c-ali')).status='returned' AND (t.cb('c-ali')).remaining=0 AND t.doc('rb')->>'refund_method'='cash'
  AND t.open_balance('ali')=0 AND t.stmt('ali')=0
  AND (SELECT count(*)=2 FROM public.contract_changes WHERE contract_id=t.id('c-ali') AND kind='return_adjustment'),
  concat_ws(' ',(t.k('c-ali')).status,(t.cb('c-ali')).remaining,t.stmt('ali')));
-- Nothing paid yet: 4 000 sale, 400 down; all back: 4 720 credit, 4 320 owed -> the 400 down payment back as store credit.
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'nina-sale',t.sell_inst('nina',jsonb_build_array(jsonb_build_object('product_id',t.id('table'),'quantity',1)),'4000.00','400.00','s05-key-nina');
RESET ROLE;
INSERT INTO t.ids SELECT 'nina-s',(t.doc('nina-sale')->'sale'->>'id')::uuid;
INSERT INTO t.ids SELECT 'c-nina',(t.doc('nina-sale')->'contract'->>'id')::uuid;
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'rn',t.ret('nina-s',jsonb_build_array(t.rl('nina-s','table',1)),jsonb_build_array(jsonb_build_object('method','store_credit','amount','400.00')),'4000.00','s05-key-rn');
RESET ROLE;
SELECT t.expect('nothing paid: the down payment comes back as store credit, contract returned, balance 0',
  (t.k('c-nina')).status='returned' AND t.credit('nina')=400 AND t.open_balance('nina')=0 AND t.stmt('nina')=-400,
  concat_ws(' ',(t.k('c-nina')).status,t.credit('nina'),t.stmt('nina')));
-- A written-off contract can't take a return.
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'wo-sale',t.sell_inst('wo',jsonb_build_array(jsonb_build_object('product_id',t.id('table'),'quantity',1)),'4000.00','400.00','s05-key-wo');
RESET ROLE;
INSERT INTO t.ids SELECT 'wo-s',(t.doc('wo-sale')->'sale'->>'id')::uuid;
INSERT INTO t.ids SELECT 'c-wo',(t.doc('wo-sale')->'contract'->>'id')::uuid;
SELECT t.as_user('a0500000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.write_off_contract(t.id('c-wo'),jsonb_build_object('reason','Customer emigrated, nothing to collect',
  'expected_remaining',(t.cb('c-wo')).remaining::numeric(18,2)::text),'s05-key-writeoff');
SELECT t.unchanged('a written-off contract is CONTRACT_NOT_OPEN',format('SELECT public.post_sales_return(%L,%L)',
  t.body('wo-s',jsonb_build_array(t.rl('wo-s','table',1)),'[]','4000.00'),'s05-key-rwo'),'CONTRACT_NOT_OPEN');
RESET ROLE;

-- ================================================================ ETA, K04, lists, ledgers, grants
SELECT t.expect('ETA: one b2c_return per return of a fiscal sale, on the return''s POS, pending',
  (SELECT count(*) FROM public.fiscal_submissions WHERE organization_id=t.org('a') AND doc_type='b2c_return')
  =(SELECT count(*) FROM public.sales_returns r WHERE r.organization_id=t.org('a') AND r.kind<>'void')
  AND (SELECT bool_and(f.device_id=(SELECT device_id FROM public.shifts WHERE id=r.shift_id) AND f.status='pending')
       FROM public.fiscal_submissions f JOIN public.sales_returns r ON r.id=f.return_id WHERE f.organization_id=t.org('a')));
SELECT t.expect('ETA: the return waits for the sale''s UUID',
  NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.eta_load_pending_for_device((SELECT device_id FROM public.shifts WHERE id=t.id('shift')))->'rows') x
              WHERE x->>'kind'='return'));
UPDATE public.fiscal_submissions SET eta_uuid=repeat('a',64) WHERE sale_id=t.id('s5');
INSERT INTO t.docs SELECT 'eta',public.eta_load_pending_for_device((SELECT device_id FROM public.shifts WHERE id=t.id('shift')),NULL,200);
SELECT t.expect('ETA: then it is loaded with the original UUID, its returned line and amounts',
  (SELECT count(*)=1 AND bool_and(x->'original'->>'uuid'=repeat('a',64) AND x->'sale'->>'total'='250.00'
          AND jsonb_array_length(x->'lines')=1 AND x->'lines'->0->>'quantity'='1' AND x->'lines'->0->>'line_total'='250.00')
   FROM jsonb_array_elements(t.doc('eta')->'rows') x WHERE x->>'kind'='return'),t.doc('eta')::text);
SELECT t.as_user('a0500000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'k04',public.get_day_close_preview(t.id('main'),t.today());
INSERT INTO t.docs SELECT 'list',public.list_sales_returns('{}');
INSERT INTO t.docs SELECT 'list-x',public.list_sales_returns('{"kind":"exchange"}');
INSERT INTO t.docs SELECT 'one',public.get_sales_return(t.id('r1'));
INSERT INTO t.docs SELECT 'print1',public.record_return_receipt_print(t.id('r1'));
INSERT INTO t.docs SELECT 'print2',public.record_return_receipt_print(t.id('r1'));
RESET ROLE;
SELECT t.expect('K04: today''s returns (voids apart) and what went back by method',
  (t.doc('k04')->'totals'->'returns'->>'count')::int=(SELECT count(*) FROM public.sales_returns WHERE organization_id=t.org('a') AND kind<>'void' AND business_date=t.today())
  AND (t.doc('k04')->'totals'->'returns'->'refunded_by_method'->>'bank_transfer')::numeric=3000,
  (t.doc('k04')->'totals'->'returns')::text);
SELECT t.expect('lists: every return (voids included), the exchanges by kind; a detail; prints 1 then a copy',
  (t.doc('list')->>'total_count')::int=t.n('sales_returns') AND (t.doc('list-x')->>'total_count')::int=2
  AND t.doc('one')->>'number'=t.doc('r1')->>'number' AND jsonb_array_length(t.doc('one')->'lines')=1
  AND t.doc('print1')->>'copy'='false' AND t.doc('print2')->>'copy'='true');
SELECT t.expect('ledgers: every stock level, cash balance and store credit balance equals its ledger',
  (SELECT count(*)=0 FROM app.ledger_mismatches()),(SELECT string_agg(ledger||' '||subject_id,'; ') FROM app.ledger_mismatches()));
SELECT t.expect('grants: the six functions for authenticated only, the helpers for nobody',
  has_function_privilege('authenticated','public.post_sales_return(jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.quote_sales_return(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_sale_returnable(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_sales_returns(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_sales_return(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.record_return_receipt_print(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.post_sales_return(jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.return_compute(uuid,public.shifts,jsonb,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.return_contract_plan(uuid,public.contracts,public.sales,numeric,boolean)','EXECUTE')
  AND NOT has_table_privilege('authenticated','public.sales_returns','INSERT'));
SELECT t.as_user('a0500000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error('a warehouse user reads no return','SELECT public.list_sales_returns(''{}'')','PERMISSION_DENIED');
RESET ROLE;

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
