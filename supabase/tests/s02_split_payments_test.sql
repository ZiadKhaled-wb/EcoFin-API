-- S02 split payments (EC-69, D64).
-- Run by: node scripts/db-smoke.mjs supabase/tests/s02_split_payments_test.sql (inside BEGIN ... ROLLBACK).
-- A cashier pays one sale with cash, bank transfers and store credit: each line posts to its own
-- ledger (drawer with the shift, bank without, customer balance), the lines must add up to the
-- total, cash can carry what the customer handed over, the shift reports what it took by method,
-- every refusal leaves nothing behind, and the account list is names only.
-- (Many requests at the same moment: scripts/db-stock-cash-proof.mjs.)
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
CREATE TABLE t.docs(tag text,j jsonb);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.error_detail(n text,q text,c text,detail jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND d<>'' AND d::jsonb = detail,SQLERRM||' / '||COALESCE(d,'')); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
CREATE FUNCTION t.level(p text,b text DEFAULT 'main') RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0)::integer $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.credit(c text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.store_credit_balances WHERE customer_id=t.id(c)),0) $$;
CREATE FUNCTION t.expected(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT app.shift_json(t.org('a'),t.id(s),false)->>'expected_cash' $$;
-- Everything a sale writes, counted for shop a: a refused or repeated call must leave it unchanged.
CREATE FUNCTION t.footprint() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',
    (SELECT count(*) FROM public.sales WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.stock_movements WHERE organization_id=t.org('a') AND type='sale_out'),
    (SELECT count(*) FROM public.payments WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.payment_allocations WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.cash_movements WHERE organization_id=t.org('a') AND type='sale'),
    (SELECT count(*) FROM public.store_credit_movements WHERE organization_id=t.org('a')),
    (SELECT COALESCE(sum(next_value),0) FROM public.document_counters WHERE organization_id=t.org('a') AND doc_type IN ('sale','payment')),
    (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='sale.created')) $$;
CREATE FUNCTION t.bad_stock() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws('/',p.sku,k.on_hand,k.ledger),', ')
  FROM (SELECT COALESCE(l.product_id,m.product_id) product_id,COALESCE(l.on_hand,0) on_hand,COALESCE(m.ledger,0) ledger
        FROM (SELECT product_id,branch_id,on_hand FROM public.stock_levels WHERE organization_id=t.org('a') AND stock_state='sellable') l
        FULL JOIN (SELECT product_id,branch_id,sum(quantity) ledger FROM public.stock_movements
                   WHERE organization_id=t.org('a') AND stock_state='sellable' GROUP BY 1,2) m
          ON m.product_id=l.product_id AND m.branch_id=l.branch_id) k
  JOIN public.products p ON p.id=k.product_id WHERE k.on_hand<>k.ledger OR k.on_hand<0 $$;
CREATE FUNCTION t.bad_cash() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws('/',a.name,COALESCE(b.balance,0),COALESCE(m.ledger,0)),', ')
  FROM public.cash_accounts a LEFT JOIN public.cash_balances b ON b.cash_account_id=a.id
  LEFT JOIN (SELECT cash_account_id,sum(amount) ledger FROM public.cash_movements WHERE organization_id=t.org('a') GROUP BY 1) m ON m.cash_account_id=a.id
  WHERE a.organization_id=t.org('a') AND (COALESCE(b.balance,0)<>COALESCE(m.ledger,0) OR COALESCE(b.balance,0)<0) $$;
CREATE FUNCTION t.bad_credit() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws('/',c.customer_id,c.balance,COALESCE(m.ledger,0)),', ')
  FROM public.store_credit_balances c
  LEFT JOIN (SELECT customer_id,sum(amount) ledger FROM public.store_credit_movements GROUP BY 1) m ON m.customer_id=c.customer_id
  WHERE c.organization_id=t.org('a') AND c.balance<>COALESCE(m.ledger,0) $$;
-- A sale whose payments don't add up to its total (there must be none).
CREATE FUNCTION t.unbalanced() RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.sales s WHERE s.organization_id=t.org('a')
    AND s.total<>COALESCE((SELECT sum(a.amount) FROM public.payment_allocations a WHERE a.sale_id=s.id),0) $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q) $$;
CREATE FUNCTION t.pcash(amount text,tendered text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('method','cash','amount',amount,'tendered',tendered)) $$;
CREATE FUNCTION t.pbank(amount text,acct text,ref text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('method','bank_transfer','amount',amount,'cash_account_id',t.id(acct),'reference',ref)) $$;
CREATE FUNCTION t.pcredit(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method','store_credit','amount',amount) $$;
-- A post_sale call as SQL text, for t.error (a fresh key each time unless one is given).
CREATE FUNCTION t.sell(lines jsonb,expected text,pays jsonb DEFAULT NULL,customer text DEFAULT NULL,key text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_sale(%L,%L,%L,%L,%L)',lines,expected,COALESCE(key,'s02-'||md5(random()::text)),t.id(customer),pays) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (two branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S02 '||s,'s02-'||s,'retail_pro','Owner',s||'s02@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('u',64)),('b',repeat('v',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a7050000-0000-0000-8000-000000000001','as02@example.com'),('a7050000-0000-0000-8000-000000000002','bs02@example.com'),
  ('a7050000-0000-0000-8000-000000000003','s02cashier@example.com'),('a7050000-0000-0000-8000-000000000006','s02warehouse@example.com');
SELECT public.accept_invite(repeat('u',64),'a7050000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('v',64),'a7050000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id=t.org('a');
SELECT t.as_user('a7050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"S2-CH","cash_price":"100"}'));
INSERT INTO t.ids VALUES('sofa',public.create_product('{"name_ar":"كنبة","name_en":"Sofa","sku":"S2-SF","cash_price":"380"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',60),
  jsonb_build_object('product_id',t.id('sofa'),'quantity',5)),'s02-found');
INSERT INTO t.ids SELECT 'nbe',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
INSERT INTO t.ids SELECT 'cib',(public.create_cash_account('CIB','bank',t.id('main'))->>'id')::uuid;
INSERT INTO t.ids SELECT 'ahli',(public.create_cash_account('Ahli','bank',t.id('second'))->>'id')::uuid;
INSERT INTO t.ids SELECT 'closed',(public.create_cash_account('Closed Bank','bank',t.id('main'))->>'id')::uuid;
SELECT public.set_cash_account_active(t.id('closed'),false);
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branch text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a7050000-0000-0000-8000-000000000003','S02 Cashier','CASHIER');
SELECT t.emp('wh','a7050000-0000-0000-8000-000000000006','S02 Warehouse','WAREHOUSE');
INSERT INTO public.customers(id,organization_id,full_name) VALUES
  ('a7050000-0000-0000-8000-0000000000c1',t.org('a'),'Mona Buyer'),('a7050000-0000-0000-8000-0000000000c3',t.org('b'),'Shop B Buyer');
INSERT INTO t.ids VALUES('mona','a7050000-0000-0000-8000-0000000000c1'),('buyer_b','a7050000-0000-0000-8000-0000000000c3');
-- Nothing creates store credit before S05: seed Mona's balance with 300.00 in the ledger.
INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date)
  VALUES(t.org('a'),t.id('mona'),300.00,'sales_return',gen_random_uuid(),t.id('main'),app.org_today(t.org('a')));
-- Shop b: a bank of its own.
SELECT t.as_user('a7050000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'bank_b',(public.create_cash_account('Bank B','bank',NULL)->>'id')::uuid;
RESET ROLE;
SELECT t.expect('setup: 60 chairs and 5 sofas; Mona has 300.00 of store credit',
  t.level('chair')=60 AND t.level('sofa')=5 AND t.credit('mona')=300.00,concat_ws(' ',t.level('chair'),t.level('sofa'),t.credit('mona')));

-- ---------------------------------------------------------------- the list of accounts
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('accounts: without an open shift the list is empty',public.list_sale_payment_accounts()='{"items":[]}'::jsonb,public.list_sale_payment_accounts()::text);
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'0','s02-shift-cashier')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',(SELECT drawer_account_id FROM public.shifts WHERE id=t.id('shift'));
INSERT INTO t.docs SELECT 'accounts',public.list_sale_payment_accounts();
SELECT t.expect('accounts: the branch''s active bank and the shop-wide one, by name only (no safe, drawer, other branch, inactive bank)',
  jsonb_array_length(j->'items')=2 AND j->'items'->0->>'name'='CIB' AND j->'items'->1->>'name'='NBE'
  AND j->'items'->0->>'id'=t.id('cib')::text AND NOT (j->'items'->0 ? 'balance') AND (SELECT count(*) FROM jsonb_object_keys(j->'items'->0))=2,j::text)
  FROM t.docs WHERE tag='accounts';
RESET ROLE;
SELECT t.as_user('a7050000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.error('accounts: a warehouse user is refused','SELECT public.list_sale_payment_accounts()','PERMISSION_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- the quote with payments
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('quote: no payments = paid in full, nothing remaining, no change',
  (SELECT q->>'paid'='1000.00' AND q->>'remaining'='0.00' AND q->>'change'='0.00' AND q->'store_credit_balance'='null'::jsonb
   FROM (SELECT public.quote_sale(t.lines(t.items('chair',10))) q) x));
SELECT t.expect('quote: half cash with 600 handed over + half bank: paid, remaining 0, change 100',
  (SELECT q->>'paid'='1000.00' AND q->>'remaining'='0.00' AND q->>'change'='100.00'
   FROM (SELECT public.quote_sale(t.lines(t.items('chair',10)),NULL,t.lines(t.pcash('500.00','600.00'),t.pbank('500.00','nbe','TRX-0'))) q) x));
SELECT t.expect('quote: an incomplete list reports what remains (not an error)',
  (SELECT q->>'paid'='400.00' AND q->>'remaining'='600.00' FROM (SELECT public.quote_sale(t.lines(t.items('chair',10)),NULL,t.lines(t.pcash('400.00'))) q) x));
SELECT t.expect('quote: the customer''s store credit balance is reported',
  public.quote_sale(t.lines(t.items('chair',10)),t.id('mona'))->>'store_credit_balance'='300.00');
SELECT t.error('quote: store credit needs a customer',format('SELECT public.quote_sale(%L,NULL,%L)',t.lines(t.items('chair',10)),t.lines(t.pcredit('100.00'))),'VALIDATION_FAILED');
SELECT t.error('quote: a bank that is not the shop''s',format('SELECT public.quote_sale(%L,NULL,%L)',t.lines(t.items('chair',10)),t.lines(t.pbank('100.00','bank_b','X'))),'VAULT_INVALID');
SELECT t.expect('quote: nothing was written',t.footprint()='0/0/0/0/0/1/0/0',t.footprint());

-- ---------------------------------------------------------------- Done when: half cash, half bank transfer
INSERT INTO t.docs SELECT 's1',public.post_sale(t.lines(t.items('chair',10)),'1000.00','s02-sale-0001',NULL,t.lines(t.pcash('500.00'),t.pbank('500.00','nbe','TRX-1')));
INSERT INTO t.ids SELECT 's1',(t.doc('s1')->>'id')::uuid;
SELECT t.expect('Done when: two payments, cash then the transfer with its reference, paid_total 1 000.00, no change',
  jsonb_array_length(j->'payments')=2 AND j->'payments'->0->>'method'='cash' AND j->'payments'->0->>'amount'='500.00'
  AND j->'payments'->0->>'cash_account_id'=t.id('drawer')::text AND j->'payments'->0->'tendered'='null'::jsonb
  AND j->'payments'->1->>'method'='bank_transfer' AND j->'payments'->1->>'amount'='500.00' AND j->'payments'->1->>'reference'='TRX-1'
  AND j->'payments'->1->>'cash_account_id'=t.id('nbe')::text AND j->'payments'->1->>'cash_account_name'='NBE'
  AND j->>'paid_total'='1000.00' AND j->>'change_total'='0.00',j::text) FROM t.docs WHERE tag='s1';
RESET ROLE;
SELECT t.expect('Done when: the drawer, the shift''s expected cash and the bank are up by exactly 500.00 each',
  t.cash('drawer')=500.00 AND t.expected('shift')='500.00' AND t.cash('nbe')=500.00,concat_ws(' ',t.cash('drawer'),t.expected('shift'),t.cash('nbe')));
SELECT t.expect('Done when: two payments with their allocations to the sale, numbered PY, keys system:sale:<id>:n, both on the shift',
  (SELECT count(*)=2 AND bool_and(p.number LIKE 'MAIN-PY-%' AND p.shift_id=t.id('shift') AND a.amount=p.amount AND p.direction='in'
     AND p.idempotency_key='system:sale:'||t.id('s1')||':'||CASE p.method WHEN 'cash' THEN '1' ELSE '2' END)
   FROM public.payments p JOIN public.payment_allocations a ON a.payment_id=p.id WHERE a.sale_id=t.id('s1')));
SELECT t.expect('Done when: the bank movement is type sale, +500.00, no shift, its note names the sale and the reference; the drawer row carries the shift',
  (SELECT count(*)=1 AND bool_and(m.amount=500.00 AND m.shift_id IS NULL AND m.type='sale' AND m.source_type='sale' AND m.source_id=t.id('s1')
     AND m.note LIKE 'MAIN-SL-% TRX-1' AND m.branch_id=t.id('main')) FROM public.cash_movements m WHERE m.cash_account_id=t.id('nbe'))
  AND (SELECT count(*)=1 AND bool_and(m.amount=500.00 AND m.shift_id=t.id('shift')) FROM public.cash_movements m WHERE m.cash_account_id=t.id('drawer') AND m.type='sale'));
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('Done when: the shift shows both: cash 500.00, bank transfer 500.00, store credit 0.00, sales total 1 000.00',
  (SELECT j->>'sales_total'='1000.00' AND j->'payment_totals'='{"cash":"500.00","bank_transfer":"500.00","store_credit":"0.00"}'::jsonb
   FROM (SELECT public.get_shift(t.id('shift')) j) x));
RESET ROLE;
SELECT t.expect('audit: still one sale.created row, its after lists the payment lines',
  (SELECT count(*)=1 AND bool_and(jsonb_array_length(after->'payments')=2 AND after->'payments'->1->>'reference'='TRX-1'
     AND after->'payments'->1->>'method'='bank_transfer' AND after->'payments'->0->>'amount'='500.00')
   FROM public.audit_log WHERE action='sale.created' AND entity_id=t.id('s1')));
SELECT t.expect('footprint after the first sale',t.footprint()='1/1/2/2/2/1/5/1',t.footprint());

-- ---------------------------------------------------------------- idempotency
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('idempotent: the same key answers the same sale and payments',
  (public.post_sale(t.lines(t.items('chair',10)),'1000.00','s02-sale-0001',NULL,t.lines(t.pcash('500.00'),t.pbank('500.00','nbe','TRX-1')))->>'id')=t.id('s1')::text
  AND (public.post_sale(t.lines(t.items('chair',1)),'100.00','s02-sale-0001')->'payments'->1->>'reference')='TRX-1');
SELECT t.expect('idempotent: nothing was posted twice',t.footprint()='1/1/2/2/2/1/5/1',t.footprint());

-- ---------------------------------------------------------------- no payments = cash in full
INSERT INTO t.docs SELECT 's2',public.post_sale(t.lines(t.items('chair',1)),'100.00','s02-sale-0002');
SELECT t.expect('no payments given: one cash payment of the total (S01)',
  jsonb_array_length(j->'payments')=1 AND j->'payments'->0->>'method'='cash' AND j->'payments'->0->>'amount'='100.00'
  AND j->>'paid_total'='100.00' AND j->>'change_total'='0.00',(j->'payments')::text) FROM t.docs WHERE tag='s2';
SELECT t.expect('an explicit JSON null is the same as no payments',
  (SELECT jsonb_array_length(public.post_sale(t.lines(t.items('chair',1)),'100.00','s02-sale-0003',NULL,'null'::jsonb)->'payments')=1));

-- ---------------------------------------------------------------- cash with change
INSERT INTO t.docs SELECT 's4',public.post_sale(t.lines(t.items('sofa',1)),'380.00','s02-sale-0004',NULL,t.lines(t.pcash('380.00','400.00')));
SELECT t.expect('cash with change: tendered 400.00 stored, change 20.00, change_total 20.00',
  j->'payments'->0->>'tendered'='400.00' AND j->'payments'->0->>'change'='20.00' AND j->>'change_total'='20.00' AND j->>'paid_total'='380.00',(j->'payments')::text)
  FROM t.docs WHERE tag='s4';
SELECT t.error('cash: handed over less than the amount',t.sell(t.lines(t.items('sofa',1)),'380.00',t.lines(t.pcash('380.00','379.99'))),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('cash with change: the drawer is up by 380.00 only (the change never enters it), the payment stores tendered',
  t.cash('drawer')=1080.00 AND (SELECT tendered=400.00 AND amount=380.00 FROM public.payments WHERE number=t.doc('s4')->'payments'->0->>'number' AND organization_id=t.org('a')),t.cash('drawer')::text);

-- ---------------------------------------------------------------- store credit
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('store credit: more than the balance (400 of 300)',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcredit('400.00'),t.pcash('600.00')),'mona'),
  'INSUFFICIENT_STORE_CREDIT','{"balance":"300.00"}');
SELECT t.error('store credit: needs a customer',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcredit('300.00'),t.pcash('700.00'))),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 's5',public.post_sale(t.lines(t.items('chair',10)),'1000.00','s02-sale-0005',t.id('mona'),t.lines(t.pcredit('300.00'),t.pcash('700.00')));
SELECT t.expect('store credit: 300.00 of credit + 700.00 cash; the credit payment has no account, the customer is on both',
  jsonb_array_length(j->'payments')=2 AND j->'payments'->0->>'method'='store_credit' AND j->'payments'->0->'cash_account_id'='null'::jsonb
  AND j->'payments'->1->>'method'='cash' AND j->>'customer_id'=t.id('mona')::text AND j->>'paid_total'='1000.00',(j->'payments')::text) FROM t.docs WHERE tag='s5';
RESET ROLE;
SELECT t.expect('store credit: the balance is 0.00 and the ledger has one -300.00 movement for the sale',
  t.credit('mona')=0.00 AND (SELECT count(*)=2 FROM public.store_credit_movements WHERE customer_id=t.id('mona'))
  AND (SELECT count(*)=1 AND bool_and(amount=-300.00 AND branch_id=t.id('main')) FROM public.store_credit_movements
       WHERE customer_id=t.id('mona') AND source_type='sale' AND source_id=(t.doc('s5')->>'id')::uuid)
  AND (SELECT bool_and(customer_id=t.id('mona') AND cash_account_id IS NULL OR method<>'store_credit') FROM public.payments WHERE organization_id=t.org('a')),t.credit('mona')::text);
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('store credit: the balance is spent, a second sale is refused',t.sell(t.lines(t.items('chair',1)),'100.00',t.lines(t.pcredit('100.00')),'mona'),
  'INSUFFICIENT_STORE_CREDIT','{"balance":"0.00"}');

-- ---------------------------------------------------------------- several transfers
INSERT INTO t.docs SELECT 's6',public.post_sale(t.lines(t.items('chair',10)),'1000.00','s02-sale-0006',NULL,
  t.lines(t.pbank('400.00','nbe','TRX-A'),t.pbank('400.00','cib','TRX-B'),t.pbank('200.00','nbe','  TRX-C  ')));
SELECT t.expect('three transfers: two banks, the reference trimmed, in the order given',
  jsonb_array_length(j->'payments')=3 AND j->'payments'->2->>'reference'='TRX-C' AND j->'payments'->1->>'cash_account_name'='CIB',(j->'payments')::text)
  FROM t.docs WHERE tag='s6';
RESET ROLE;
SELECT t.expect('three transfers: NBE 1 100.00 (500 + 400 + 200), CIB 400.00, the drawer untouched by them',
  t.cash('nbe')=1100.00 AND t.cash('cib')=400.00 AND t.cash('drawer')=1780.00,concat_ws(' ',t.cash('nbe'),t.cash('cib'),t.cash('drawer')));
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('the shift by method: cash 1 780.00, transfers 1 500.00, store credit 300.00, sales 3 580.00',
  (SELECT j->>'sales_total'='3580.00' AND j->'payment_totals'='{"cash":"1780.00","bank_transfer":"1500.00","store_credit":"300.00"}'::jsonb
   FROM (SELECT public.get_shift(t.id('shift')) j) x),(public.get_shift(t.id('shift'))->'payment_totals')::text);
SELECT t.expect('the shift''s expected cash counts the cash half only',t.expected('shift')='1780.00',t.expected('shift'));
SELECT t.expect('the sale is readable with its payments and totals',
  public.get_sale(t.id('s1'))->>'paid_total'='1000.00' AND jsonb_array_length(public.get_sale(t.id('s1'))->'payments')=2);

-- ---------------------------------------------------------------- refusals leave nothing behind
RESET ROLE;
CREATE TABLE t.mark(f text);
INSERT INTO t.mark SELECT t.footprint();
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('mismatch: paid less',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcash('500.00'),t.pbank('499.99','nbe','R'))),
  'PAYMENT_TOTAL_MISMATCH','{"total":"1000.00","paid":"999.99"}');
SELECT t.error_detail('mismatch: paid more',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcash('1000.01'))),
  'PAYMENT_TOTAL_MISMATCH','{"total":"1000.00","paid":"1000.01"}');
SELECT t.error('an amount of 0',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcash('0.00'),t.pcash('1000.00'))),'VALIDATION_FAILED');
SELECT t.error('two cash lines',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcash('500.00'),t.pcash('500.00'))),'VALIDATION_FAILED');
SELECT t.error('two store credit lines',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcredit('100.00'),t.pcredit('100.00'),t.pcash('800.00')),'mona'),'VALIDATION_FAILED');
SELECT t.error('four transfers',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('250.00','nbe','1'),t.pbank('250.00','nbe','2'),t.pbank('250.00','cib','3'),t.pbank('250.00','cib','4'))),'VALIDATION_FAILED');
SELECT t.error('six lines',t.sell(t.lines(t.items('chair',10)),'1000.00',jsonb_build_array(t.pcash('1.00'),t.pbank('1.00','nbe','1'),t.pbank('1.00','nbe','2'),t.pbank('1.00','nbe','3'),t.pcredit('1.00'),t.pbank('1.00','nbe','4'))),'VALIDATION_FAILED');
SELECT t.error('an empty list',t.sell(t.lines(t.items('chair',10)),'1000.00','[]'::jsonb),'VALIDATION_FAILED');
SELECT t.error('a bank transfer without a reference',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('1000.00','nbe',NULL))),'VALIDATION_FAILED');
SELECT t.error('a blank reference',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('1000.00','nbe','   '))),'VALIDATION_FAILED');
SELECT t.error('a safe is not a bank',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('1000.00','safe','S'))),'VAULT_INVALID');
SELECT t.error('a drawer is not a bank',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('1000.00','drawer','D'))),'VAULT_INVALID');
SELECT t.error('another branch''s bank',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('1000.00','ahli','A'))),'VAULT_INVALID');
SELECT t.error('an inactive bank',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('1000.00','closed','C'))),'CASH_ACCOUNT_INACTIVE');
SELECT t.error('another shop''s bank',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pbank('1000.00','bank_b','B'))),'VAULT_INVALID');
SELECT t.error('another shop''s customer with store credit',t.sell(t.lines(t.items('chair',10)),'1000.00',t.lines(t.pcredit('100.00'),t.pcash('900.00')),'buyer_b'),'CUSTOMER_NOT_FOUND');
SELECT t.error('an unknown method',t.sell(t.lines(t.items('chair',10)),'1000.00','[{"method":"cheque","amount":"1000.00"}]'::jsonb),'VALIDATION_FAILED');
SELECT t.error('card is V2',t.sell(t.lines(t.items('chair',10)),'1000.00','[{"method":"card","amount":"1000.00"}]'::jsonb),'VALIDATION_FAILED');
SELECT t.error('a field that does not belong to the method',t.sell(t.lines(t.items('chair',10)),'1000.00','[{"method":"cash","amount":"1000.00","reference":"X"}]'::jsonb),'VALIDATION_FAILED');
SELECT t.error('not a list',t.sell(t.lines(t.items('chair',10)),'1000.00','{"method":"cash","amount":"1000.00"}'::jsonb),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('refused: no sale, no stock, no number, no payment, no ledger row changed',t.footprint()=(SELECT f FROM t.mark),t.footprint()||' vs '||(SELECT f FROM t.mark));

-- ---------------------------------------------------------------- reconciliation
SELECT t.expect('reconciliation: every stock level = its ledger',t.bad_stock() IS NULL,t.bad_stock());
SELECT t.expect('reconciliation: every cash balance = its ledger, none below zero',t.bad_cash() IS NULL,t.bad_cash());
SELECT t.expect('reconciliation: every store credit balance = its ledger',t.bad_credit() IS NULL,t.bad_credit());
SELECT t.expect('reconciliation: the payments of every sale add up to its total',t.unbalanced()=0,t.unbalanced()::text);
SELECT t.expect('reconciliation: app.ledger_mismatches finds nothing in the shop',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));

-- ---------------------------------------------------------------- grants
SELECT t.expect('grants: the new read for authenticated, not anon; helpers not granted',
  has_function_privilege('authenticated','public.list_sale_payment_accounts()','EXECUTE')
  AND NOT has_function_privilege('anon','public.list_sale_payment_accounts()','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.sale_payments_input(jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.sale_payments_check(uuid,uuid,uuid,jsonb)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
