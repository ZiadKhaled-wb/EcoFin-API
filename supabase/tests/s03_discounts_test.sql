-- S03 discounts (EC-70, D65).
-- Run by: node scripts/db-smoke.mjs supabase/tests/s03_discounts_test.sql (inside BEGIN ... ROLLBACK).
-- A line or the whole sale can be discounted (amount or percent); the sale discount is spread over the
-- lines by largest remainder; T01 taxes each line on its discounted amount; every line's effective
-- percent must be within the caller's cap, above it needs discount.above_cap or a single-use,
-- 15-minute approval bound to the cart's fingerprint that a manager gave from their own session.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
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
-- Everything a sale writes, counted for shop a: a refused or repeated call must leave it unchanged.
CREATE FUNCTION t.footprint() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT concat_ws('/',
    (SELECT count(*) FROM public.sales WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.stock_movements WHERE organization_id=t.org('a') AND type='sale_out'),
    (SELECT count(*) FROM public.payments WHERE organization_id=t.org('a')),
    (SELECT count(*) FROM public.cash_movements WHERE organization_id=t.org('a') AND type='sale'),
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
CREATE FUNCTION t.unbalanced() RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.sales s WHERE s.organization_id=t.org('a')
    AND s.total<>COALESCE((SELECT sum(a.amount) FROM public.payment_allocations a WHERE a.sale_id=s.id),0) $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q) $$;
-- A line with a discount: t.dl('tv',1,t.pct('5')).
CREATE FUNCTION t.dl(p text,q integer,d jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q,'discount',d) $$;
CREATE FUNCTION t.pct(v text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('type','percent','value',v) $$;
CREATE FUNCTION t.amt(v text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('type','amount','value',v) $$;
CREATE FUNCTION t.pcash(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method','cash','amount',amount) $$;
CREATE FUNCTION t.pbank(amount text,acct text,ref text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('method','bank_transfer','amount',amount,'cash_account_id',t.id(acct),'reference',ref) $$;
-- A post_sale call as SQL text (reason, sale discount and approval optional; a fresh key unless one is given).
CREATE FUNCTION t.sell(lines jsonb,expected text,reason text DEFAULT NULL,sdisc jsonb DEFAULT NULL,approval text DEFAULT NULL,key text DEFAULT NULL,pays jsonb DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT public.post_sale(%L,%L,%L,NULL,%L,%L,%L,%L)',lines,expected,COALESCE(key,'s03-'||md5(random()::text)),pays,sdisc,reason,t.id(approval)) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- the pure helpers (as postgres)
SELECT t.expect('allocate: 100.00 over 100/200/300 = 16.67, 33.33, 50.00 (exactly 100.00)',
  app.allocate_amount(100.00,ARRAY[100,200,300]::numeric[])=ARRAY[16.67,33.33,50.00]::numeric[],app.allocate_amount(100.00,ARRAY[100,200,300]::numeric[])::text);
SELECT t.expect('allocate: equal weights, the extra piaster goes to the lower line (33.34, 33.33, 33.33)',
  app.allocate_amount(100.00,ARRAY[100,100,100]::numeric[])=ARRAY[33.34,33.33,33.33]::numeric[]);
SELECT t.expect('allocate: 0.01 over three equal lines goes to line 1',app.allocate_amount(0.01,ARRAY[1,1,1]::numeric[])=ARRAY[0.01,0,0]::numeric[]);
SELECT t.error('allocate: more than nothing over zero weights','SELECT app.allocate_amount(1.00,ARRAY[0,0]::numeric[])','VALIDATION_FAILED');

SELECT t.expect('pure: 10 % of a 1 140.00 line is 114.00',
  app.apply_discounts('[{"line_no":1,"unit_price":"1140.00","quantity":1,"discount":{"type":"percent","value":"10"}}]','null')->'lines'->0->>'discount_amount'='114.00');
SELECT t.expect('pure: a percent is rounded half-up (5 % of 33.30 = 1.665 -> 1.67)',
  app.apply_discounts('[{"line_no":1,"unit_price":"33.30","quantity":1,"discount":{"type":"percent","value":"5"}}]',NULL)->'lines'->0->>'discount_amount'='1.67');
SELECT t.expect('pure: a sale discount of 100.00 over 100/200/300 spreads as 16.67, 33.33, 50.00 and adds up',
  (SELECT r->'lines'->0->>'discount_amount'='16.67' AND r->'lines'->1->>'discount_amount'='33.33' AND r->'lines'->2->>'discount_amount'='50.00'
     AND r->>'discount_total'='100.00' AND r->>'sale_discount'='100.00'
   FROM (SELECT app.apply_discounts('[{"line_no":1,"unit_price":"100.00","quantity":1},{"line_no":2,"unit_price":"100.00","quantity":2},{"line_no":3,"unit_price":"300.00","quantity":1}]',
     '{"type":"amount","value":"100.00"}') r) x));
SELECT t.expect('pure: the spread follows the net after the line discount (net 50 and 100: 20.00 is 6.67 + 13.33)',
  (SELECT r->'lines'->0->>'discount_amount'='56.67' AND r->'lines'->1->>'discount_amount'='13.33'
   FROM (SELECT app.apply_discounts('[{"line_no":1,"unit_price":"100.00","quantity":1,"discount":{"type":"amount","value":"50"}},{"line_no":2,"unit_price":"100.00","quantity":1}]',
     '{"type":"amount","value":"20.00"}') r) x),
  app.apply_discounts('[{"line_no":1,"unit_price":"100.00","quantity":1,"discount":{"type":"amount","value":"50"}},{"line_no":2,"unit_price":"100.00","quantity":1}]','{"type":"amount","value":"20.00"}')::text);
SELECT t.expect('pure: stacking 5 % on the line and 5 % on the sale gives a line above 5 % (9.75 %)',
  (SELECT (r->'lines'->0->>'effective_pct')::numeric=9.75 AND r->>'max_effective_pct'='9.75' AND r->>'discount_total'='97.50'
   FROM (SELECT app.apply_discounts('[{"line_no":1,"unit_price":"1000.00","quantity":1,"discount":{"type":"percent","value":"5"}}]','{"type":"percent","value":"5"}') r) x));
SELECT t.error('pure: a negative discount',$$SELECT app.apply_discounts('[{"line_no":1,"unit_price":"10.00","quantity":1,"discount":{"type":"amount","value":"-1"}}]',NULL)$$,'DISCOUNT_INVALID');
SELECT t.error('pure: a percent above 100',$$SELECT app.apply_discounts('[{"line_no":1,"unit_price":"10.00","quantity":1,"discount":{"type":"percent","value":"100.01"}}]',NULL)$$,'DISCOUNT_INVALID');
SELECT t.error('pure: more than the line gross',$$SELECT app.apply_discounts('[{"line_no":1,"unit_price":"10.00","quantity":2,"discount":{"type":"amount","value":"20.01"}}]',NULL)$$,'DISCOUNT_INVALID');
SELECT t.error('pure: a sale discount above the net subtotal',$$SELECT app.apply_discounts('[{"line_no":1,"unit_price":"10.00","quantity":1}]','{"type":"amount","value":"10.01"}')$$,'DISCOUNT_INVALID');
SELECT t.error('pure: an unknown type',$$SELECT app.apply_discounts('[{"line_no":1,"unit_price":"10.00","quantity":1,"discount":{"type":"fixed","value":"1"}}]',NULL)$$,'DISCOUNT_INVALID');
SELECT t.error('pure: three decimals',$$SELECT app.apply_discounts('[{"line_no":1,"unit_price":"10.00","quantity":1,"discount":{"type":"amount","value":"1.005"}}]',NULL)$$,'DISCOUNT_INVALID');
SELECT t.expect('fingerprint: the same cart in another line order is the same; another discount is not',
  app.cart_fingerprint('[{"product_id":"a","quantity":1},{"product_id":"b","quantity":2,"discount":{"type":"percent","value":"5"}}]',NULL)
  = app.cart_fingerprint('[{"product_id":"b","quantity":2,"discount":{"type":"percent","value":"5.00"}},{"product_id":"a","quantity":1}]',NULL)
  AND app.cart_fingerprint('[{"product_id":"a","quantity":1}]',NULL)<>app.cart_fingerprint('[{"product_id":"a","quantity":1,"discount":{"type":"percent","value":"1"}}]',NULL)
  AND app.cart_fingerprint('[{"product_id":"a","quantity":1}]',NULL)<>app.cart_fingerprint('[{"product_id":"a","quantity":1}]','{"type":"amount","value":"1"}')
  AND length(app.cart_fingerprint('[{"product_id":"a","quantity":1}]',NULL))=64);

-- ---------------------------------------------------------------- setup: shop a (two branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S03 '||s,'s03-'||s,'retail_pro','Owner',s||'s03@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('u',64)),('b',repeat('v',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a7060000-0000-0000-8000-000000000001','as03@example.com'),('a7060000-0000-0000-8000-000000000002','bs03@example.com'),
  ('a7060000-0000-0000-8000-000000000003','s03cashier@example.com'),('a7060000-0000-0000-8000-000000000004','s03cashier2@example.com'),
  ('a7060000-0000-0000-8000-000000000005','s03manager@example.com'),('a7060000-0000-0000-8000-000000000006','s03manager2@example.com'),
  ('a7060000-0000-0000-8000-000000000007','s03cashier3@example.com');
SELECT public.accept_invite(repeat('u',64),'a7060000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('v',64),'a7060000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,discount_caps='{"CASHIER":5,"BRANCH_MANAGER":15}' WHERE organization_id=t.org('a');
SELECT t.as_user('a7060000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"S3-TV","cash_price":"1140"}'));
INSERT INTO t.ids VALUES('ex',public.create_product('{"name_ar":"ثلاجة","name_en":"Fridge","sku":"S3-EX","cash_price":"1000"}'));
INSERT INTO t.ids VALUES('p100',public.create_product('{"name_ar":"ب١","name_en":"P100","sku":"S3-P100","cash_price":"100"}'));
INSERT INTO t.ids VALUES('p200',public.create_product('{"name_ar":"ب٢","name_en":"P200","sku":"S3-P200","cash_price":"200"}'));
INSERT INTO t.ids VALUES('p300',public.create_product('{"name_ar":"ب٣","name_en":"P300","sku":"S3-P300","cash_price":"300"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(jsonb_build_object('product_id',t.id('tv'),'quantity',60),
  jsonb_build_object('product_id',t.id('ex'),'quantity',10),jsonb_build_object('product_id',t.id('p100'),'quantity',20),
  jsonb_build_object('product_id',t.id('p200'),'quantity',20),jsonb_build_object('product_id',t.id('p300'),'quantity',20)),'s03-found');
INSERT INTO t.ids SELECT 'nbe',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
SELECT public.open_shift(t.id('main'),'0','s03-shift-owner');
RESET ROLE;
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,VARIADIC branches text[] DEFAULT ARRAY['main']) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; b text; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branches[1])) RETURNING id INTO v;
  FOREACH b IN ARRAY branches LOOP
    INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(b));
  END LOOP;
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('c1','a7060000-0000-0000-8000-000000000003','S03 Cashier','CASHIER','main','second');
SELECT t.emp('c2','a7060000-0000-0000-8000-000000000004','S03 Cashier Two','CASHIER');
SELECT t.emp('c3','a7060000-0000-0000-8000-000000000007','S03 Cashier Three','CASHIER');
SELECT t.emp('m1','a7060000-0000-0000-8000-000000000005','S03 Manager','BRANCH_MANAGER','main','second');
SELECT t.emp('m2','a7060000-0000-0000-8000-000000000006','S03 Manager Two','BRANCH_MANAGER');
-- c3 may give discounts above the cap by an override of his own.
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),t.id('c3'),'discount.above_cap',true);
-- Shifts: c1, c2, c3 and the manager sell at main.
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT * FROM (VALUES('c1','a7060000-0000-0000-8000-000000000003'),('c2','a7060000-0000-0000-8000-000000000004'),
       ('c3','a7060000-0000-0000-8000-000000000007'),('m1','a7060000-0000-0000-8000-000000000005')) v(tag,sub) LOOP
    PERFORM t.as_user(r.sub,t.org('a'));
    SET LOCAL ROLE authenticated;
    INSERT INTO t.ids SELECT 'shift_'||r.tag,(public.open_shift(t.id('main'),'0','s03-shift-'||r.tag)->>'id')::uuid;
    RESET ROLE;
  END LOOP; END $$;
SELECT t.as_user('a7060000-0000-0000-8000-000000000002',t.org('b'));
SELECT t.expect('setup: 60 TVs at main, caps CASHIER 5 / BRANCH_MANAGER 15, c3 has the override, the manager has discount.above_cap by default',
  t.level('tv')=60 AND (SELECT discount_caps='{"CASHIER":5,"BRANCH_MANAGER":15}'::jsonb FROM public.org_settings WHERE organization_id=t.org('a'))
  AND (SELECT EXISTS(SELECT 1 FROM public.role_permissions WHERE role='BRANCH_MANAGER' AND permission_key='discount.above_cap')
       AND NOT EXISTS(SELECT 1 FROM public.role_permissions WHERE role='CASHIER' AND permission_key='discount.above_cap')),t.level('tv')::text);
CREATE TABLE t.mark(tag text,f text);
GRANT SELECT ON t.mark TO authenticated;
INSERT INTO t.mark SELECT 'start',t.footprint();

-- ---------------------------------------------------------------- tax is correct: prices include VAT
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('quote: a 10 % line discount on 1 140.00 (VAT included): discount 114.00, tax 126.00, total 1 026.00; nothing written',
  (SELECT q->>'discount_total'='114.00' AND q->>'tax_total'='126.00' AND q->>'total'='1026.00' AND q->>'subtotal'='1140.00'
     AND q->'lines'->0->>'discount_amount'='114.00' AND q->'lines'->0->>'effective_pct'='10.00' AND q->'lines'->0->>'line_total'='1026.00'
     AND q->>'max_effective_pct'='10.00' AND NOT (q ? 'discount') AND t.footprint()=(SELECT f FROM t.mark WHERE tag='start')
   FROM (SELECT public.quote_sale(t.lines(t.dl('tv',1,t.pct('10')))) q) x));
INSERT INTO t.docs SELECT 'inc',public.post_sale(t.lines(t.dl('tv',1,t.pct('10'))),'1026.00','s03-inc-0001',NULL,NULL,NULL,'Loyal customer');
INSERT INTO t.ids SELECT 'inc',(t.doc('inc')->>'id')::uuid;
SELECT t.expect('prices include VAT: discount_total 114.00, tax_total 126.00, total 1 026.00, the reason kept, the line shows its discount',
  j->>'discount_total'='114.00' AND j->>'tax_total'='126.00' AND j->>'total'='1026.00' AND j->>'subtotal'='1140.00'
  AND j->>'discount_reason'='Loyal customer' AND j->'lines'->0->>'discount_amount'='114.00' AND j->'lines'->0->>'line_total'='1026.00'
  AND j->'lines'->0->>'tax_amount'='126.00' AND j->>'paid_total'='1026.00',j::text) FROM t.docs WHERE tag='inc';
RESET ROLE;
SELECT t.expect('prices include VAT: the sale header equals the lines (discount, tax, total) and the CHECKs held',
  (SELECT s.discount_total=(SELECT sum(discount_amount) FROM public.sale_lines WHERE sale_id=s.id)
      AND s.tax_total=(SELECT sum(tax_amount) FROM public.sale_lines WHERE sale_id=s.id)
      AND s.total=(SELECT sum(line_total) FROM public.sale_lines WHERE sale_id=s.id)
      AND s.total=s.subtotal-s.discount_total AND s.prices_include_vat
   FROM public.sales s WHERE s.id=t.id('inc')));
SELECT t.expect('ledgers: the stock movement is the quantity sold (-1), the cash posted equals the discounted total 1 026.00',
  (SELECT count(*)=1 AND bool_and(quantity=-1) FROM public.stock_movements WHERE source_type='sale' AND source_id=t.id('inc'))
  AND (SELECT count(*)=1 AND bool_and(amount=1026.00) FROM public.cash_movements WHERE source_type='sale' AND source_id=t.id('inc'))
  AND t.level('tv')=59);
SELECT t.expect('audit: sale.created carries the discount and its reason',
  (SELECT after->>'discount_total'='114.00' AND after->>'discount_reason'='Loyal customer' AND after->'discount_approval_id'='null'::jsonb
   FROM public.audit_log WHERE action='sale.created' AND entity_id=t.id('inc')));

-- ---------------------------------------------------------------- tax is correct: prices exclude VAT
UPDATE public.org_settings SET prices_include_vat=false WHERE organization_id=t.org('a');
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'exc',public.post_sale(t.lines(t.dl('ex',1,t.pct('10'))),'1026.00','s03-exc-0001',NULL,NULL,NULL,'Loyal customer');
INSERT INTO t.ids SELECT 'exc',(t.doc('exc')->>'id')::uuid;
SELECT t.expect('prices exclude VAT: 1 000.00 less 10 % = discount 100.00, tax 126.00, total 1 026.00',
  j->>'discount_total'='100.00' AND j->>'tax_total'='126.00' AND j->>'total'='1026.00' AND j->>'subtotal'='1000.00'
  AND j->>'prices_include_vat'='false' AND j->'lines'->0->>'line_total'='1026.00',j::text) FROM t.docs WHERE tag='exc';
RESET ROLE;
SELECT t.expect('prices exclude VAT: the CHECK total = subtotal - discount + tax holds and the lines add up to the header',
  (SELECT s.total=s.subtotal-s.discount_total+s.tax_total
      AND s.discount_total=(SELECT sum(discount_amount) FROM public.sale_lines WHERE sale_id=s.id)
      AND s.tax_total=(SELECT sum(tax_amount) FROM public.sale_lines WHERE sale_id=s.id)
      AND s.total=(SELECT sum(line_total) FROM public.sale_lines WHERE sale_id=s.id)
   FROM public.sales s WHERE s.id=t.id('exc')));
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id=t.org('a');

-- ---------------------------------------------------------------- a sale discount over three lines
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'spread',public.post_sale(t.lines(t.items('p100',1),t.items('p200',1),t.items('p300',1)),'550.00','s03-spread',NULL,NULL,t.amt('50.00'),'Closing offer');
INSERT INTO t.ids SELECT 'spread',(t.doc('spread')->>'id')::uuid;
SELECT t.expect('sale discount: 50.00 over 100/200/300 is 8.33, 16.67, 25.00 on the lines; header discount 50.00, total 550.00',
  j->'lines'->0->>'discount_amount'='8.33' AND j->'lines'->1->>'discount_amount'='16.67' AND j->'lines'->2->>'discount_amount'='25.00'
  AND j->>'discount_total'='50.00' AND j->>'total'='550.00' AND j->>'subtotal'='600.00',j::text) FROM t.docs WHERE tag='spread';
RESET ROLE;
SELECT t.expect('sale discount: the lines add up to the header (discount, tax, total)',
  (SELECT s.discount_total=(SELECT sum(discount_amount) FROM public.sale_lines WHERE sale_id=s.id)
      AND s.tax_total=(SELECT sum(tax_amount) FROM public.sale_lines WHERE sale_id=s.id)
      AND s.total=(SELECT sum(line_total) FROM public.sale_lines WHERE sale_id=s.id)
   FROM public.sales s WHERE s.id=t.id('spread')));

-- ---------------------------------------------------------------- caps
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('cap: a cashier at exactly 5 % is fine',
  (public.post_sale(t.lines(t.dl('tv',1,t.pct('5'))),'1083.00','s03-cap-5',NULL,NULL,NULL,'Regular customer')->>'discount_total')='57.00');
SELECT t.error_detail('cap: a cashier at 5.01 % is refused with the line, the cap and the percent',
  t.sell(t.lines(t.dl('tv',1,t.pct('5.01'))),'1083.00','Regular customer'),'DISCOUNT_ABOVE_CAP','{"line_no":1,"cap_pct":"5.00","effective_pct":"5.01"}');
SELECT t.error_detail('cap: stacking 3 % on the line and 3 % on the sale is refused (5.91 %)',
  t.sell(t.lines(t.dl('tv',1,t.pct('3'))),'1072.63','Regular customer',t.pct('3')),'DISCOUNT_ABOVE_CAP','{"line_no":1,"cap_pct":"5.00","effective_pct":"5.91"}');
SELECT t.error_detail('cap: the second line decides (line 1 at 4 %, line 2 at 6 %)',
  t.sell(t.lines(t.dl('p100',1,t.pct('4')),t.dl('p200',1,t.pct('6'))),'284.00','Regular customer'),'DISCOUNT_ABOVE_CAP','{"line_no":2,"cap_pct":"5.00","effective_pct":"6.00"}');
SELECT t.expect('cap: a refused sale left nothing behind',(SELECT count(*)=4 FROM public.sales WHERE organization_id=t.org('a')) AND t.level('tv')=58);
SELECT t.error('cap: an invalid discount is DISCOUNT_INVALID (a percent above 100)',t.sell(t.lines(t.dl('tv',1,t.pct('101'))),'0.00','Regular customer'),'DISCOUNT_INVALID');
SELECT t.error('reason: a discount without a reason',t.sell(t.lines(t.dl('tv',1,t.pct('1'))),'1128.60'),'DISCOUNT_REASON_REQUIRED');
SELECT t.error('reason: two characters are too short',t.sell(t.lines(t.dl('tv',1,t.pct('1'))),'1128.60','ab'),'DISCOUNT_REASON_REQUIRED');
SELECT t.error('reason: 201 characters are too long',t.sell(t.lines(t.dl('tv',1,t.pct('1'))),'1128.60',repeat('x',201)),'DISCOUNT_REASON_REQUIRED');
SELECT t.error('reason: a sale discount needs one too',t.sell(t.lines(t.items('tv',1)),'1128.60',NULL,t.pct('1')),'DISCOUNT_REASON_REQUIRED');
SELECT t.expect('reason: no discount, no reason needed',(public.post_sale(t.lines(t.items('p100',1)),'100.00','s03-noreason')->>'discount_total')='0.00');
RESET ROLE;
-- A role missing from discount_caps has a cap of 0.
UPDATE public.org_settings SET discount_caps='{"BRANCH_MANAGER":15}' WHERE organization_id=t.org('a');
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('cap: a role missing from discount_caps (cap 0) is refused at 1 %',
  t.sell(t.lines(t.dl('tv',1,t.pct('1'))),'1128.60','Regular customer'),'DISCOUNT_ABOVE_CAP','{"line_no":1,"cap_pct":"0.00","effective_pct":"1.00"}');
RESET ROLE;
UPDATE public.org_settings SET discount_caps='{"CASHIER":5,"BRANCH_MANAGER":15}' WHERE organization_id=t.org('a');
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('cap: a manager at 15 % is fine (171.00)',(public.post_sale(t.lines(t.dl('tv',1,t.pct('15'))),'969.00','s03-mgr-15',NULL,NULL,NULL,'Fair offer')->>'discount_total')='171.00');
SELECT t.expect('cap: a manager above 15 % has discount.above_cap by default, so 20 % goes through',
  (public.post_sale(t.lines(t.dl('tv',1,t.pct('20'))),'912.00','s03-mgr-20',NULL,NULL,NULL,'Fair offer')->>'discount_total')='228.00');
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('cap: the owner has no cap (40 %)',(public.post_sale(t.lines(t.dl('tv',1,t.pct('40'))),'684.00','s03-owner-40',NULL,NULL,NULL,'Owner decision')->>'discount_total')='456.00');
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000007',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('cap: a cashier with a discount.above_cap override may go above it (30 %)',
  (public.post_sale(t.lines(t.dl('tv',1,t.pct('30'))),'798.00','s03-c3-30',NULL,NULL,NULL,'Special customer')->>'discount_total')='342.00');
SELECT t.error('approval: someone who needs none is told so (the override)',
  format('SELECT public.request_discount_approval(%L,%L,NULL,%L)',t.id('main'),t.lines(t.dl('tv',1,t.pct('30'))),'Special customer'),'APPROVAL_NOT_NEEDED');
RESET ROLE;

-- ---------------------------------------------------------------- approval flow
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: a request within the cap is not needed',
  format('SELECT public.request_discount_approval(%L,%L,NULL,%L)',t.id('main'),t.lines(t.dl('tv',1,t.pct('4'))),'Regular customer'),'APPROVAL_NOT_NEEDED');
SELECT t.error('approval: no discount at all is not needed',
  format('SELECT public.request_discount_approval(%L,%L,NULL,%L)',t.id('main'),t.lines(t.items('tv',1)),'Regular customer'),'APPROVAL_NOT_NEEDED');
SELECT t.error('approval: a request needs a reason',
  format('SELECT public.request_discount_approval(%L,%L,NULL,NULL)',t.id('main'),t.lines(t.dl('tv',1,t.pct('8')))),'DISCOUNT_REASON_REQUIRED');
INSERT INTO t.docs SELECT 'req1',public.request_discount_approval(t.id('main'),t.lines(t.dl('tv',1,t.pct('8'))),NULL,'Regular customer, 8 % agreed');
INSERT INTO t.ids SELECT 'ap1',(t.doc('req1')->>'approval_id')::uuid;
SELECT t.expect('approval: an 8 % request answers the approval id, 8.00 and the cap 5.00',
  j->>'max_effective_pct'='8.00' AND j->>'cap_pct'='5.00' AND (j->>'approval_id')::uuid IS NOT NULL,j::text) FROM t.docs WHERE tag='req1';
SELECT t.expect('approval: it is pending, and the requester can read it',
  (SELECT j->>'status'='pending' AND j->>'max_effective_pct'='8.00' AND j->>'used'='false' AND j->>'reason'='Regular customer, 8 % agreed'
     AND j->'lines'->0->>'sku'='S3-TV'
   FROM (SELECT public.get_discount_approval(t.id('ap1')) j) x));
SELECT t.error('approval: selling with it while pending',t.sell(t.lines(t.dl('tv',1,t.pct('8'))),'1048.80','Regular customer',NULL,'ap1'),'APPROVAL_INVALID');
SELECT t.error('approval: a cashier cannot decide',format('SELECT public.decide_discount_approval(%L,true,NULL)',t.id('ap1')),'PERMISSION_DENIED');
SELECT t.error('approval: a cashier cannot list the approvals','SELECT public.list_discount_approvals()','PERMISSION_DENIED');
RESET ROLE;
-- The requester gets the permission later: still not allowed to decide their own request.
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) VALUES(t.org('a'),t.id('c1'),'discount.above_cap',true);
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: the requester deciding their own request',format('SELECT public.decide_discount_approval(%L,true,NULL)',t.id('ap1')),'APPROVAL_SELF');
RESET ROLE;
DELETE FROM public.employee_permission_overrides WHERE employee_id=t.id('c1');
SELECT t.as_user('a7060000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('approval: the pending list shows the request to a manager with access to its branch',
  (SELECT jsonb_array_length(j->'items')=1 AND j->'items'->0->>'id'=t.id('ap1')::text AND j->'items'->0->>'requested_by_name'='S03 Cashier'
     AND j->'items'->0->>'branch_name'='Main' AND j->'items'->0->>'max_effective_pct'='8.00' AND j->'items'->0->>'cap_pct'='5.00'
   FROM (SELECT public.list_discount_approvals('pending') j) x));
SELECT t.error('approval: an invalid status filter',$$SELECT public.list_discount_approvals('open')$$,'VALIDATION_FAILED');
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('approval: the manager approves with a note',public.decide_discount_approval(t.id('ap1'),true,'Fine')->>'status'='approved');
SELECT t.error('approval: deciding twice',format('SELECT public.decide_discount_approval(%L,false,NULL)',t.id('ap1')),'APPROVAL_NOT_PENDING');
RESET ROLE;
SELECT t.expect('approval: decided by the manager, the note kept, still unused',
  (SELECT status='approved' AND decided_by=t.id('m1') AND decision_note='Fine' AND decided_at IS NOT NULL AND entity_id IS NULL
   FROM public.approvals WHERE id=t.id('ap1')));
SELECT t.expect('audit: approval.requested and approval.decided are written',
  (SELECT count(*)=1 FROM public.audit_log WHERE action='approval.requested' AND entity_id=t.id('ap1'))
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='approval.decided' AND entity_id=t.id('ap1') AND after->>'status'='approved'));
INSERT INTO t.mark SELECT 'ap1',t.footprint();
-- Another cashier can't use it.
SELECT t.as_user('a7060000-0000-0000-8000-000000000004',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: another cashier using it',t.sell(t.lines(t.dl('tv',1,t.pct('8'))),'1048.80','Regular customer',NULL,'ap1'),'APPROVAL_INVALID');
SELECT t.error('approval: another cashier can''t read it',format('SELECT public.get_discount_approval(%L)',t.id('ap1')),'APPROVAL_NOT_FOUND');
SELECT t.error('approval: another cashier can''t cancel it',format('SELECT public.cancel_discount_approval(%L)',t.id('ap1')),'APPROVAL_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: a different cart (9 %)',t.sell(t.lines(t.dl('tv',1,t.pct('9'))),'1037.40','Regular customer',NULL,'ap1'),'APPROVAL_INVALID');
SELECT t.error('approval: a different cart (two TVs at 8 %)',t.sell(t.lines(t.dl('tv',2,t.pct('8'))),'2097.60','Regular customer',NULL,'ap1'),'APPROVAL_INVALID');
SELECT t.error('approval: the same discount as an amount is a different cart',t.sell(t.lines(t.dl('tv',1,t.amt('91.20'))),'1048.80','Regular customer',NULL,'ap1'),'APPROVAL_INVALID');
SELECT t.error('approval: an approval id of nothing',format('SELECT public.post_sale(%L,%L,%L,NULL,NULL,NULL,%L,%L)',t.lines(t.dl('tv',1,t.pct('8'))),'1048.80','s03-x-000001','Regular customer',gen_random_uuid()),'APPROVAL_INVALID');
RESET ROLE;
SELECT t.expect('approval: every refusal left nothing behind',t.footprint()=(SELECT f FROM t.mark WHERE tag='ap1'),t.footprint());
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'apsale',public.post_sale(t.lines(t.dl('tv',1,t.pct('8'))),'1048.80','s03-ap-sale',NULL,NULL,NULL,'Regular customer, 8 % agreed',t.id('ap1'));
INSERT INTO t.ids SELECT 'apsale',(t.doc('apsale')->>'id')::uuid;
SELECT t.expect('approval: the sale with the approval succeeds at 8 %: discount 91.20, total 1 048.80',
  j->>'discount_total'='91.20' AND j->>'total'='1048.80',j::text) FROM t.docs WHERE tag='apsale';
SELECT t.expect('approval: GET shows it approved and used',(SELECT j->>'status'='approved' AND j->>'used'='true' AND j->>'decided_by_name'='S03 Manager' AND j->>'decision_note'='Fine'
  FROM (SELECT public.get_discount_approval(t.id('ap1')) j) x));
SELECT t.error('approval: using it again',t.sell(t.lines(t.dl('tv',1,t.pct('8'))),'1048.80','Regular customer',NULL,'ap1'),'APPROVAL_INVALID');
SELECT t.error('approval: it can no longer be cancelled',format('SELECT public.cancel_discount_approval(%L)',t.id('ap1')),'APPROVAL_NOT_PENDING');
RESET ROLE;
SELECT t.expect('approval: its entity_id is the sale, it stays approved, and the audit names it',
  (SELECT entity_id=t.id('apsale') AND status='approved' FROM public.approvals WHERE id=t.id('ap1'))
  AND (SELECT after->>'discount_approval_id'=t.id('ap1')::text FROM public.audit_log WHERE action='sale.created' AND entity_id=t.id('apsale')));
DO $$ BEGIN
  BEGIN UPDATE public.approvals SET decision_note='changed' WHERE id=t.id('ap1'); PERFORM t.expect('approval: a decided approval can not be edited',false,'no error');
  EXCEPTION WHEN others THEN PERFORM t.expect('approval: a decided approval can not be edited',split_part(SQLERRM,':',1)='DOCUMENT_FINAL',SQLERRM); END;
  BEGIN UPDATE public.approvals SET entity_id=gen_random_uuid() WHERE id=t.id('ap1'); PERFORM t.expect('approval: nor can its sale be changed once set',false,'no error');
  EXCEPTION WHEN others THEN PERFORM t.expect('approval: nor can its sale be changed once set',split_part(SQLERRM,':',1)='DOCUMENT_FINAL',SQLERRM); END;
END $$;

-- Idempotency: the same key with an approval gives the same sale and spends the approval once.
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'ap2',(public.request_discount_approval(t.id('main'),t.lines(t.dl('tv',1,t.pct('7'))),NULL,'Regular customer')->>'approval_id')::uuid;
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT public.decide_discount_approval(t.id('ap2'),true,NULL);
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'idem1',public.post_sale(t.lines(t.dl('tv',1,t.pct('7'))),'1060.20','s03-idem',NULL,NULL,NULL,'Regular customer',t.id('ap2'));
INSERT INTO t.docs SELECT 'idem2',public.post_sale(t.lines(t.dl('tv',1,t.pct('7'))),'1060.20','s03-idem',NULL,NULL,NULL,'Regular customer',t.id('ap2'));
SELECT t.expect('idempotent: the same key twice with an approval is the same sale',t.doc('idem1')->>'id'=t.doc('idem2')->>'id' AND t.doc('idem1')->>'total'='1060.20');
RESET ROLE;
SELECT t.expect('idempotent: one sale more, the approval spent once on that sale',
  (SELECT entity_id=(t.doc('idem1')->>'id')::uuid FROM public.approvals WHERE id=t.id('ap2'))
  AND (SELECT count(*)=1 FROM public.sales WHERE idempotency_key='s03-idem'),t.footprint());

-- 16 minutes after the decision the approval has expired.
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'ap3',(public.request_discount_approval(t.id('main'),t.lines(t.dl('tv',1,t.pct('6'))),NULL,'Regular customer')->>'approval_id')::uuid;
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT public.decide_discount_approval(t.id('ap3'),true,NULL);
RESET ROLE;
ALTER TABLE public.approvals DISABLE TRIGGER trg_approvals_final;
UPDATE public.approvals SET decided_at=now()-interval '16 minutes' WHERE id=t.id('ap3');
ALTER TABLE public.approvals ENABLE TRIGGER trg_approvals_final;
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: decided 16 minutes ago',t.sell(t.lines(t.dl('tv',1,t.pct('6'))),'1071.60','Regular customer',NULL,'ap3'),'APPROVAL_INVALID');
RESET ROLE;
ALTER TABLE public.approvals DISABLE TRIGGER trg_approvals_final;
UPDATE public.approvals SET decided_at=now()-interval '14 minutes' WHERE id=t.id('ap3');
ALTER TABLE public.approvals ENABLE TRIGGER trg_approvals_final;
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('approval: decided 14 minutes ago is still good',(public.post_sale(t.lines(t.dl('tv',1,t.pct('6'))),'1071.60','s03-ap3-0001',NULL,NULL,NULL,'Regular customer',t.id('ap3'))->>'total')='1071.60');

-- Another branch: asked for the second branch, used at the main one.
INSERT INTO t.ids SELECT 'ap4',(public.request_discount_approval(t.id('second'),t.lines(t.dl('tv',1,t.pct('8'))),NULL,'Regular customer')->>'approval_id')::uuid;
INSERT INTO t.ids SELECT 'ap5',(public.request_discount_approval(t.id('second'),t.lines(t.dl('tv',1,t.pct('9'))),NULL,'Regular customer')->>'approval_id')::uuid;
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('list: the manager with both branches sees the two requests of the second branch ',
  (SELECT jsonb_array_length(j->'items')=2 AND (SELECT array_agg(i->>'id' ORDER BY i->>'id') FROM jsonb_array_elements(j->'items') i)=(SELECT array_agg(x::text ORDER BY x::text) FROM unnest(ARRAY[t.id('ap4'),t.id('ap5')]) x) AND j->'items'->0->>'branch_name'='Second'
   FROM (SELECT public.list_discount_approvals('pending') j) x));
SELECT public.decide_discount_approval(t.id('ap4'),true,NULL);
SELECT t.expect('list: a decided request leaves the pending list and shows under approved',
  (SELECT jsonb_array_length(public.list_discount_approvals('pending')->'items')=1 AND jsonb_array_length(public.list_discount_approvals('approved')->'items')=4));
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000006',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('list: the manager of the main branch only does not see the second branch''s request',
  (SELECT jsonb_array_length(j->'items')=0 FROM (SELECT public.list_discount_approvals('pending') j) x));
SELECT t.error('decide: nor can they decide it',format('SELECT public.decide_discount_approval(%L,true,NULL)',t.id('ap5')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: approved for another branch',t.sell(t.lines(t.dl('tv',1,t.pct('8'))),'1048.80','Regular customer',NULL,'ap4'),'APPROVAL_INVALID');
SELECT t.expect('cancel: the requester takes a pending request back',public.cancel_discount_approval(t.id('ap5'))->>'status'='cancelled');
SELECT t.error('cancel: twice',format('SELECT public.cancel_discount_approval(%L)',t.id('ap5')),'APPROVAL_NOT_PENDING');
SELECT t.error('cancel: a cancelled approval is not usable',t.sell(t.lines(t.dl('tv',1,t.pct('9'))),'1037.40','Regular customer',NULL,'ap5'),'APPROVAL_INVALID');
RESET ROLE;
-- A rejected approval does not sell.
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'ap6',(public.request_discount_approval(t.id('main'),t.lines(t.dl('tv',1,t.pct('9'))),NULL,'Regular customer')->>'approval_id')::uuid;
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.expect('approval: a manager can reject',public.decide_discount_approval(t.id('ap6'),false,'Too much')->>'status'='rejected');
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: a rejected approval can not be used',t.sell(t.lines(t.dl('tv',1,t.pct('9'))),'1037.40','Regular customer',NULL,'ap6'),'APPROVAL_INVALID');
RESET ROLE;
-- A sale discount asked as a request (the fingerprint covers it).
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'ap7',(public.request_discount_approval(t.id('main'),t.lines(t.items('p100',1),t.items('p200',1)),t.pct('8'),'Two items, 8 % off')->>'approval_id')::uuid;
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT public.decide_discount_approval(t.id('ap7'),true,NULL);
RESET ROLE;
SELECT t.as_user('a7060000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.error('approval: the sale discount is part of the cart (7 % instead of 8 %)',t.sell(t.lines(t.items('p100',1),t.items('p200',1)),'279.00','Two items, 8 % off',t.pct('7'),'ap7'),'APPROVAL_INVALID');
SELECT t.expect('approval: the same cart with its 8 % sale discount sells (total 276.00)',
  (public.post_sale(t.lines(t.items('p100',1),t.items('p200',1)),'276.00','s03-ap7-0001',NULL,NULL,t.pct('8'),'Two items, 8 % off',t.id('ap7'))->>'total')='276.00');
RESET ROLE;

-- ---------------------------------------------------------------- another shop
SELECT t.as_user('a7060000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('cross-shop: shop b''s owner deciding shop a''s approval',format('SELECT public.decide_discount_approval(%L,true,NULL)',t.id('ap5')),'APPROVAL_NOT_FOUND');
SELECT t.error('cross-shop: nor reading it',format('SELECT public.get_discount_approval(%L)',t.id('ap5')),'APPROVAL_NOT_FOUND');
SELECT t.expect('cross-shop: shop b''s list is empty',jsonb_array_length(public.list_discount_approvals('approved')->'items')=0);
RESET ROLE;

-- ---------------------------------------------------------------- with S02: split payments on the discounted total
SELECT t.as_user('a7060000-0000-0000-8000-000000000005',t.org('a'));
SET ROLE authenticated;
SELECT t.error_detail('S02: paying the undiscounted amount fails (1 140.00 for a total of 1 083.00)',
  t.sell(t.lines(t.dl('tv',1,t.pct('5'))),'1083.00','Regular customer',NULL,NULL,NULL,t.lines(t.pcash('600.00'),t.pbank('540.00','nbe','TRX-0'))),
  'PAYMENT_TOTAL_MISMATCH','{"total":"1083.00","paid":"1140.00"}');
INSERT INTO t.docs SELECT 'split',public.post_sale(t.lines(t.dl('tv',1,t.pct('5'))),'1083.00','s03-split',NULL,t.lines(t.pcash('500.00'),t.pbank('583.00','nbe','TRX-1')),NULL,'Regular customer');
SELECT t.expect('S02: half cash, the rest by bank transfer, adding up to the discounted total 1 083.00',
  j->>'total'='1083.00' AND j->>'discount_total'='57.00' AND j->>'paid_total'='1083.00' AND jsonb_array_length(j->'payments')=2,j::text) FROM t.docs WHERE tag='split';
RESET ROLE;
SELECT t.expect('S02: each part posted to its ledger (the bank +583.00)',
  t.cash('nbe')=583.00 AND (SELECT sum(amount)=500.00 FROM public.cash_movements WHERE source_type='sale' AND source_id=(t.doc('split')->>'id')::uuid AND cash_account_id<>t.id('nbe')),t.cash('nbe')::text);

-- ---------------------------------------------------------------- reconciliation and grants
SELECT t.expect('reconciliation: every stock level = its ledger',t.bad_stock() IS NULL,t.bad_stock());
SELECT t.expect('reconciliation: every cash balance = its ledger, none below zero',t.bad_cash() IS NULL,t.bad_cash());
SELECT t.expect('reconciliation: the payments of every sale add up to its (discounted) total',t.unbalanced()=0,t.unbalanced()::text);
SELECT t.expect('reconciliation: every sale: total = subtotal - discount (+ tax when prices exclude VAT), lines add up',
  NOT EXISTS(SELECT 1 FROM public.sales s WHERE s.organization_id=t.org('a') AND
    (s.discount_total<>(SELECT sum(discount_amount) FROM public.sale_lines WHERE sale_id=s.id)
     OR s.total<>(SELECT sum(line_total) FROM public.sale_lines WHERE sale_id=s.id))));
SELECT t.expect('reconciliation: app.ledger_mismatches finds nothing in the shop',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
SELECT t.expect('reconciliation: every used approval points to exactly one sale of the shop',
  NOT EXISTS(SELECT 1 FROM public.approvals a WHERE a.kind='discount_above_cap' AND a.entity_id IS NOT NULL
             AND NOT EXISTS(SELECT 1 FROM public.sales s WHERE s.id=a.entity_id AND s.organization_id=a.organization_id))
  AND (SELECT count(*)=count(DISTINCT entity_id) FROM public.approvals WHERE kind='discount_above_cap' AND entity_id IS NOT NULL));
SELECT t.expect('grants: the new public functions for authenticated, not anon; the helpers not granted',
  has_function_privilege('authenticated','public.request_discount_approval(uuid,jsonb,jsonb,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.decide_discount_approval(uuid,boolean,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.cancel_discount_approval(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.get_discount_approval(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_discount_approvals(text)','EXECUTE')
  AND has_function_privilege('authenticated','public.post_sale(jsonb,text,text,uuid,jsonb,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.request_discount_approval(uuid,jsonb,jsonb,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.decide_discount_approval(uuid,boolean,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.apply_discounts(jsonb,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.allocate_amount(numeric,numeric[])','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.cart_fingerprint(jsonb,jsonb)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.discount_cap_pct(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.check_discount_allowed(uuid,jsonb,text,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.sale_cart(uuid,uuid,jsonb,boolean,jsonb)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
