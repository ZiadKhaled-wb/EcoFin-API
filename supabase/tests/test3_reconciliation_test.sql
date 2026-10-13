-- TEST-3 (EC-132): stock and cash reconciliation after a Sprint 3 day in one shop.
-- Run by: node scripts/db-smoke.mjs supabase/tests/test3_reconciliation_test.sql (inside BEGIN ... ROLLBACK).
-- A shop buys chairs and phones (IMEI units), pays from the safe and a bank, returns goods for
-- cash, transfers to a second branch, adjusts, registers an opening unit, runs a shift with an
-- expense and a short count. Then:
--   1. for every product and branch: stock level = sum of the stock ledger, never below zero;
--   2. for every safe, bank and drawer: balance = sum of the cash ledger;
--   3. nothing can push stock or a safe below zero, and the caches can't be written directly;
--   4. an IMEI unit is in one place only and can't be sold twice;
--   5. an invoice above the approval threshold (U06) posts nothing until the owner approves.
-- (Two requests at the same moment: scripts/db-stock-cash-proof.mjs.)
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
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- (SECURITY DEFINER: the caller's role doesn't read the ledgers, the caches or app.* directly.)
CREATE FUNCTION t.level(p text,b text) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b)),0)::integer $$;
CREATE FUNCTION t.cash(a text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.cash_balances WHERE cash_account_id=t.id(a)),0) $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.units WHERE organization_id=t.org('a') AND serial=s $$;
CREATE FUNCTION t.unit_state(s text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws(' ',u.status,(SELECT tag FROM t.ids i WHERE i.id=u.branch_id AND i.tag IN ('main','second')))
  FROM public.units u WHERE u.id=t.unit(s) $$;
CREATE FUNCTION t.status(i text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT status::text FROM public.purchase_invoices WHERE id=t.id(i) $$;
CREATE FUNCTION t.owed() RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT balance FROM public.v_supplier_balances WHERE supplier_id=t.id('nile')),0) $$;
CREATE FUNCTION t.mismatches() RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$ SELECT count(*) FROM app.ledger_mismatches(t.org('a')) $$;
-- Stock levels of shop a that differ from their ledger sum, or are below zero.
CREATE FUNCTION t.bad_stock() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws('/',p.sku,k.branch_id,k.on_hand,k.ledger),', ')
  FROM (SELECT COALESCE(l.product_id,m.product_id) product_id,COALESCE(l.branch_id,m.branch_id) branch_id,
               COALESCE(l.on_hand,0) on_hand,COALESCE(m.ledger,0) ledger
        FROM (SELECT product_id,branch_id,on_hand FROM public.stock_levels WHERE organization_id=t.org('a')) l
        FULL JOIN (SELECT product_id,branch_id,sum(quantity) ledger FROM public.stock_movements
                   WHERE organization_id=t.org('a') AND stock_state='sellable' GROUP BY 1,2) m
          ON m.product_id=l.product_id AND m.branch_id=l.branch_id) k
  JOIN public.products p ON p.id=k.product_id
  WHERE k.on_hand<>k.ledger OR k.on_hand<0 $$;
-- Cash accounts of shop a whose balance differs from their ledger sum, or is below zero.
CREATE FUNCTION t.bad_cash() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(concat_ws('/',a.name,a.kind,COALESCE(b.balance,0),COALESCE(m.ledger,0)),', ')
  FROM public.cash_accounts a
  LEFT JOIN public.cash_balances b ON b.cash_account_id=a.id
  LEFT JOIN (SELECT cash_account_id,sum(amount) ledger FROM public.cash_movements WHERE organization_id=t.org('a') GROUP BY 1) m
    ON m.cash_account_id=a.id
  WHERE a.organization_id=t.org('a') AND (COALESCE(b.balance,0)<>COALESCE(m.ledger,0) OR COALESCE(b.balance,0)<0) $$;
CREATE FUNCTION t.kinds() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT string_agg(DISTINCT a.kind::text,',' ORDER BY a.kind::text) FROM public.cash_accounts a
  WHERE a.organization_id=t.org('a') AND EXISTS(SELECT 1 FROM public.cash_movements m WHERE m.cash_account_id=a.id) $$;
-- A "sale" of one unit as S01 will post it: one sale_out row on the stock ledger.
CREATE FUNCTION t.sell(s text,b text) RETURNS text LANGUAGE sql AS $$
  SELECT format($q$INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,source_type,source_id)
                   VALUES(%L,%L,%L,%L,-1,'sale_out','sale',gen_random_uuid())$q$,t.org('a'),t.id('phone'),t.id(b),t.unit(s)) $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (serials, two branches)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT 'a',public.admin_provision_organization('TEST-3 a','test3-a','retail_pro','Owner','atest3@example.com',NULL,'Main',repeat('r',64),now()+interval '1 day');
INSERT INTO auth.users(id,email) VALUES('a7030000-0000-0000-8000-000000000001','atest3@example.com'),('a7030000-0000-0000-8000-000000000002','test3manager@example.com');
SELECT public.accept_invite(repeat('r',64),'a7030000-0000-0000-8000-000000000001');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
SELECT t.as_user('a7030000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','T3',NULL,NULL,NULL,NULL,NULL));
SELECT public.post_cash_opening(t.id('safe'),'20000.00','Counted on day one','test3-opening');
INSERT INTO t.ids SELECT 'bank',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
SELECT public.create_cash_transfer(t.id('safe'),t.id('bank'),'3000.00','','test3-fund-bank');
INSERT INTO t.ids SELECT 'nile',(public.create_supplier('{"name":"Nile Traders"}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'chair',public.create_product('{"name_ar":"كرسي","sku":"T3-CH","cash_price":"250"}');
INSERT INTO t.ids SELECT 'phone',public.create_product('{"name_ar":"هاتف","sku":"T3-PH","cash_price":"5000","is_serialized":true}');
INSERT INTO t.ids SELECT 'transport',(public.create_expense_category('Transport')->>'id')::uuid;
RESET ROLE;
INSERT INTO public.employees(id,organization_id,auth_user_id,full_name,role,default_branch_id)
VALUES('a7030000-0000-0000-8000-0000000000e2',t.org('a'),'a7030000-0000-0000-8000-000000000002','TEST-3 Manager','BRANCH_MANAGER',t.id('main'));
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),'a7030000-0000-0000-8000-0000000000e2',t.id('main'));

-- ---------------------------------------------------------------- the day
SET ROLE authenticated;
-- Purchase: 10 chairs at 100 and 3 phones at 3 000, approved by the owner.
INSERT INTO t.ids SELECT 'pi',(public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,t.lines(
  jsonb_build_object('product_id',t.id('chair'),'quantity',10,'unit_cost','100.00'),
  jsonb_build_object('product_id',t.id('phone'),'quantity',3,'unit_cost','3000.00','serials',jsonb_build_array('T3-IMEI-1','T3-IMEI-2','T3-IMEI-3'))),
  'test3-invoice')->>'id')::uuid;
CREATE TEMP TABLE approved AS SELECT public.approve_purchase_invoice(t.id('pi')) j;
GRANT SELECT ON approved TO authenticated;
SELECT t.expect('the day: the invoice is approved, stock is in and the supplier is owed its total',
  j->>'status'='approved' AND t.level('chair','main')=10 AND t.level('phone','main')=3 AND t.owed()=(j->>'total')::numeric,
  concat_ws(' ',j->>'status',t.level('chair','main'),t.level('phone','main'),t.owed())) FROM approved;
-- Payments: 4 000 from the safe, 1 000 from the bank.
SELECT public.post_supplier_payment(t.id('nile'),t.id('main'),t.id('safe'),'4000.00','test3-pay-safe');
SELECT public.post_supplier_payment(t.id('nile'),t.id('main'),t.id('bank'),'1000.00','test3-pay-bank');
-- A return for cash into the safe: 2 chairs and the phone T3-IMEI-3.
CREATE TEMP TABLE returned AS SELECT public.post_purchase_return(t.id('pi'),'cash','Arrived scratched',t.lines(
  jsonb_build_object('invoice_line_id',(SELECT l->>'id' FROM approved,jsonb_array_elements(j->'lines') l WHERE l->>'product_id'=t.id('chair')::text),'quantity',2),
  jsonb_build_object('invoice_line_id',(SELECT l->>'id' FROM approved,jsonb_array_elements(j->'lines') l WHERE l->>'product_id'=t.id('phone')::text),
                     'unit_ids',jsonb_build_array(t.unit('T3-IMEI-3')))),
  'test3-return',t.id('safe')) j;
GRANT SELECT ON returned TO authenticated;
-- A transfer to the second branch: 3 chairs and the phone T3-IMEI-2.
INSERT INTO t.ids SELECT 'tr',(public.create_stock_transfer(t.id('main'),t.id('second'),NULL,t.lines(
  jsonb_build_object('product_id',t.id('chair'),'quantity',3),
  jsonb_build_object('product_id',t.id('phone'),'unit_id',t.unit('T3-IMEI-2'),'quantity',1)),'test3-transfer')->>'id')::uuid;
SELECT public.send_stock_transfer(t.id('tr'));
SELECT public.receive_stock_transfer(t.id('tr'),'[]');
-- Adjustments: a chair lost in main, two found in the second branch.
SELECT public.post_stock_adjustment(t.id('main'),'loss',NULL,t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',-1)),'test3-loss');
SELECT public.post_stock_adjustment(t.id('second'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',2)),'test3-found');
-- An opening unit registered in the second branch.
SELECT public.register_units(t.id('phone'),t.id('second'),'2900.00','["T3-IMEI-9"]',NULL,'test3-units');
-- A shift: float 500 from the safe, 120 of transport from the drawer, 370 counted (10 short).
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'500.00','test3-shift',t.id('safe'))->>'id')::uuid;
SELECT public.post_expense(t.id('transport'),'120.00','test3-expense-shift',NULL,NULL,true,'Delivery van');
SELECT public.close_shift(t.id('shift'),'{"200":1,"100":1,"50":1,"20":1}',t.id('safe'),'Ten pounds short');
-- An expense of 50 from the bank.
SELECT public.post_expense(t.id('transport'),'50.00','test3-expense-bank',t.id('main'),t.id('bank'));

-- ---------------------------------------------------------------- 1. stock level = ledger sum, never below zero
SELECT t.expect('1. the day ends with the expected stock: chairs 4 + 5, phones 1 + 2',
  t.level('chair','main')=4 AND t.level('chair','second')=5 AND t.level('phone','main')=1 AND t.level('phone','second')=2,
  concat_ws(' ',t.level('chair','main'),t.level('chair','second'),t.level('phone','main'),t.level('phone','second')));
SELECT t.expect('1. for every product and branch: stock level = sum of the stock ledger, none below zero',t.bad_stock() IS NULL,t.bad_stock());
SELECT t.expect('1. app.ledger_mismatches finds nothing in the shop',t.mismatches()=0,t.mismatches()::text);

-- ---------------------------------------------------------------- 2. cash balance = ledger sum
SELECT t.expect('2. the safe: 20 000 - 3 000 - 4 000 + the refund - 500 + 370',
  t.cash('safe')=20000-3000-4000+(j->>'total')::numeric-500+370,concat_ws(' ',t.cash('safe'),j->>'total')) FROM returned;
SELECT t.expect('2. the bank: 3 000 - 1 000 - 50',t.cash('bank')=1950.00,t.cash('bank')::text);
SELECT t.expect('2. for every safe, bank and drawer: balance = sum of the cash ledger, none below zero',t.bad_cash() IS NULL,t.bad_cash());
SELECT t.expect('2. the day moved cash on a safe, a bank and a drawer',t.kinds()='bank,drawer,safe',t.kinds());

-- ---------------------------------------------------------------- 3. nothing goes below zero; caches are not writable
SELECT t.error('3. a loss of 5 chairs where 4 are left',
  format('SELECT public.post_stock_adjustment(%L,%L,NULL,%L,%L)',t.id('main'),'loss',t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',-5)),'test3-loss-5'),'OUT_OF_STOCK');
SELECT t.error('3. a transfer of 5 chairs where 4 are left',
  format('SELECT public.send_stock_transfer((public.create_stock_transfer(%L,%L,NULL,%L,%L)->>%L)::uuid)',t.id('main'),t.id('second'),
         t.lines(jsonb_build_object('product_id',t.id('chair'),'quantity',5)),'test3-transfer-5','id'),'OUT_OF_STOCK');
SELECT t.error('3. an expense of more than the bank holds',
  format('SELECT public.post_expense(%L,%L,%L,%L,%L)',t.id('transport'),'1950.01','test3-expense-much',t.id('main'),t.id('bank')),'INSUFFICIENT_FUNDS');
SELECT t.error('3. a supplier payment of more than the bank holds',
  format('SELECT public.post_supplier_payment(%L,%L,%L,%L,%L)',t.id('nile'),t.id('main'),t.id('bank'),'2000.00','test3-pay-much'),'INSUFFICIENT_FUNDS');
SELECT t.error('3. a stock level can''t be written directly',format('UPDATE public.stock_levels SET on_hand=99 WHERE product_id=%L',t.id('chair')),'permission denied for table stock_levels');
SELECT t.error('3. a cash balance can''t be written directly',format('UPDATE public.cash_balances SET balance=99 WHERE cash_account_id=%L',t.id('safe')),'permission denied for table cash_balances');
SELECT t.error('3. the stock ledger can''t be written directly',
  format('INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id) VALUES(%L,%L,%L,5,%L,%L,gen_random_uuid())',
         t.org('a'),t.id('chair'),t.id('main'),'adjustment','stock_adjustment'),'permission denied for table stock_movements');
RESET ROLE;
-- Even the database owner can't push a level below zero: the ledger trigger refuses.
SELECT t.error('3. the ledger itself refuses a row that would go below zero',
  format('INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id) VALUES(%L,%L,%L,-5,%L,%L,gen_random_uuid())',
         t.org('a'),t.id('chair'),t.id('main'),'sale_out','sale'),'OUT_OF_STOCK');
SELECT t.error('3. the cash ledger refuses a row that would take a safe below zero',
  format('INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,amount,type,source_type,source_id) VALUES(%L,%L,%L,-999999,%L,%L,gen_random_uuid())',
         t.org('a'),t.id('safe'),t.id('main'),'expense','expense'),'INSUFFICIENT_FUNDS');
SELECT t.expect('3. the refused calls changed nothing',
  t.level('chair','main')=4 AND t.cash('bank')=1950.00 AND t.bad_stock() IS NULL AND t.bad_cash() IS NULL,concat_ws(' ',t.level('chair','main'),t.cash('bank')));

-- ---------------------------------------------------------------- 4. an IMEI unit: one place, sold once
SELECT t.expect('4. each unit is where its last movement put it',
  t.unit_state('T3-IMEI-1')='in_stock main' AND t.unit_state('T3-IMEI-2')='in_stock second' AND t.unit_state('T3-IMEI-9')='in_stock second'
  AND t.unit_state('T3-IMEI-3') LIKE 'returned%',concat_ws(' | ',t.unit_state('T3-IMEI-1'),t.unit_state('T3-IMEI-2'),t.unit_state('T3-IMEI-3'),t.unit_state('T3-IMEI-9')));
SELECT t.expect('4. every unit in stock sits in exactly one branch by its own ledger',
  NOT EXISTS(SELECT 1 FROM (SELECT m.unit_id,count(*) FILTER(WHERE s.total>0) places,sum(s.total) total
                            FROM (SELECT unit_id,branch_id,sum(quantity) total FROM public.stock_movements
                                  WHERE organization_id=t.org('a') AND unit_id IS NOT NULL GROUP BY 1,2) s
                            JOIN (SELECT DISTINCT unit_id FROM public.stock_movements WHERE organization_id=t.org('a') AND unit_id IS NOT NULL) m USING(unit_id)
                            GROUP BY 1) k
             JOIN public.units u ON u.id=k.unit_id
             WHERE k.places<>(u.status='in_stock')::int OR k.total<>(u.status='in_stock')::int));
SET ROLE authenticated;
SELECT t.error('4. a serial already in the shop can''t be registered again',
  format('SELECT public.register_units(%L,%L,%L,%L,NULL,%L)',t.id('phone'),t.id('main'),'2900.00','["t3-imei-2"]','test3-units-again'),'SERIAL_TAKEN');
SELECT t.error('4. the unit now in the second branch can''t be written off in main',
  format('SELECT public.post_stock_adjustment(%L,%L,NULL,%L,%L)',t.id('main'),'loss',
         t.lines(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.unit('T3-IMEI-2'),'quantity',-1)),'test3-loss-unit'),'UNIT_NOT_AVAILABLE');
SELECT t.error('4. ...and can''t be transferred out of main again',
  format('SELECT public.create_stock_transfer(%L,%L,NULL,%L,%L)',t.id('main'),t.id('second'),
         t.lines(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.unit('T3-IMEI-2'),'quantity',1)),'test3-transfer-unit'),'UNIT_NOT_AVAILABLE');
RESET ROLE;
SELECT t.error('4. selling it in main while it is in the second branch',t.sell('T3-IMEI-2','main'),'UNIT_NOT_AVAILABLE');
SELECT t.error('4. selling the unit that went back to the supplier',t.sell('T3-IMEI-3','main'),'UNIT_NOT_AVAILABLE');
DO $$ BEGIN EXECUTE t.sell('T3-IMEI-2','second'); END $$;
SELECT t.expect('4. sold once: the unit is sold and the second branch has one phone left',
  t.unit_state('T3-IMEI-2') LIKE 'sold%' AND t.level('phone','second')=1,concat_ws(' ',t.unit_state('T3-IMEI-2'),t.level('phone','second')));
SELECT t.error('4. selling the same unit twice',t.sell('T3-IMEI-2','second'),'UNIT_NOT_AVAILABLE');
SELECT t.expect('4. after the sale every level still equals its ledger',t.bad_stock() IS NULL AND t.mismatches()=0,t.bad_stock());

-- ---------------------------------------------------------------- 5. U06: above the threshold nothing posts until the owner approves
UPDATE public.org_settings SET purchase_approval_threshold=10000.00 WHERE organization_id=t.org('a');
SELECT t.as_user('a7030000-0000-0000-8000-000000000002',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'big',(public.create_purchase_invoice(t.id('nile'),t.id('main'),NULL,current_date,t.lines(
  jsonb_build_object('product_id',t.id('chair'),'quantity',200,'unit_cost','100.00')),'test3-big')->>'id')::uuid;
CREATE TEMP TABLE before_big AS SELECT t.owed() owed,t.level('chair','main') chairs;
GRANT SELECT ON before_big TO authenticated;
SELECT t.expect('5. a manager''s approve of 20 000+ answers pending_approval',
  (public.approve_purchase_invoice(t.id('big'))->>'status')='pending_approval');
SELECT t.expect('5. ...and posts nothing: no stock, no supplier balance',
  t.status('big')='pending_approval' AND t.level('chair','main')=chairs AND t.owed()=owed,concat_ws(' ',t.status('big'),t.level('chair','main'),t.owed())) FROM before_big;
SELECT t.error('5. the manager can''t approve it again',format('SELECT public.approve_purchase_invoice(%L)',t.id('big')),'APPROVAL_OWNER_ONLY');
SELECT t.error('5. it can''t be paid while it waits',
  format('SELECT public.post_supplier_payment(%L,%L,%L,%L,%L,NULL,%L)',t.id('nile'),t.id('main'),t.id('safe'),'100.00','test3-pay-big',
         jsonb_build_array(jsonb_build_object('purchase_invoice_id',t.id('big'),'amount','100.00'))),'ALLOCATION_INVALID');
SELECT t.as_user('a7030000-0000-0000-8000-000000000001',t.org('a'));
SELECT t.expect('5. the owner approves: now the stock is in and the supplier is owed more',
  (public.approve_purchase_invoice(t.id('big'),'Checked with the supplier')->>'status')='approved');
SELECT t.expect('5. ...200 chairs arrived and the balance rose by the invoice total',
  t.level('chair','main')=chairs+200 AND t.owed()>owed+20000-0.01,concat_ws(' ',t.level('chair','main'),t.owed())) FROM before_big;
RESET ROLE;
SELECT t.expect('at the end every stock level and cash balance still equals its ledger',
  t.bad_stock() IS NULL AND t.bad_cash() IS NULL AND t.mismatches()=0,concat_ws(' ',t.bad_stock(),t.bad_cash(),t.mismatches()));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
