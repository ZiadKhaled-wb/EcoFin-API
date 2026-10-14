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
-- O03: a shift needs the paired POS device of the request. t.open_shift pairs a free device of the
-- branch (or the one named) and puts it in the request headers the way the API does once it has
-- resolved a device token: x-device-id with the hash of that token (x-device-token-hash). Then it
-- calls public.open_shift unchanged.
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
  -- Paired, as the pairing screens leave it: the device holds the hash of a token.
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
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text, p_vault uuid DEFAULT NULL, p_device uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(p_branch, p_device);
  RETURN public.open_shift(p_branch, p_float, p_key, p_vault, p_device);
END $$;
GRANT EXECUTE ON FUNCTION t.pos(uuid, uuid), t.open_shift(uuid, text, text, uuid, uuid) TO authenticated;
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
UPDATE public.org_settings SET prices_include_vat=true, discount_caps='{"CASHIER":5,"BRANCH_MANAGER":15}'::jsonb WHERE organization_id=t.org('a');
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

