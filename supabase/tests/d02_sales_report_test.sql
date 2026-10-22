-- D02 sales and margin report (EC-94, D89).
-- Run by: node scripts/db-smoke.mjs supabase/tests/d02_sales_report_test.sql (inside BEGIN ... ROLLBACK).
-- Shop a has two branches (main, second), three sellers (owner and manager sell in main / second, clerk in
-- second), a category tree (Furniture > Chairs, Electronics), a serialized TV and plain products, VAT-inclusive
-- prices. Sales over September and October 2026 (all documents are made today, then dated by hand): cash,
-- split (cash + bank), discounted (S03), paid with store credit, installment (N02), a voided sale, an exchange;
-- returns in October of September's and October's sales; documents just outside the period; shop b's own.
-- Every grouping is checked row by row against numbers worked out by hand (see the comments), the totals
-- against the document headers, and the filters, sorting, paging, permissions and isolation.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from d01_owner_dashboard_test.sql).
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
  RETURN public.open_shift(p_branch, p_float, p_key,
    (SELECT b.default_cash_account_id FROM public.branches b WHERE b.id = p_branch), NULL);
END $$;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE TABLE t.docs(tag text,j jsonb);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE (jsonb_build_object('x-org-id',o) || COALESCE((SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.employees e ON e.id=s.employee_id JOIN public.devices d ON d.id=s.device_id WHERE s.organization_id=o AND s.status='open' AND d.is_active AND d.archived_at IS NULL AND d.token_hash IS NOT NULL ORDER BY (e.auth_user_id::text=u) DESC,s.opened_at DESC,s.id DESC LIMIT 1),'{}'::jsonb))::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
CREATE FUNCTION t.pv() RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT (app.current_installment_policy(t.org('a'))).version $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.units WHERE serial=s AND organization_id=t.org('a') $$;
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q) $$;
CREATE FUNCTION t.dl(p text,q integer,d jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q,'discount',d) $$;
CREATE FUNCTION t.pct(v text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('type','percent','value',v) $$;
CREATE FUNCTION t.pcash(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method','cash','amount',amount) $$;
CREATE FUNCTION t.pcredit(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method','store_credit','amount',amount) $$;
CREATE FUNCTION t.pbank(amount text,acct text,ref text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('method','bank_transfer','amount',amount,'cash_account_id',t.id(acct),'reference',ref) $$;
-- The line of a sale for a product (for the return body), the return body and the call.
CREATE FUNCTION t.line_of(sale text,p text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.sale_lines WHERE sale_id=t.id(sale) AND product_id=t.id(p) ORDER BY line_no LIMIT 1 $$;
CREATE FUNCTION t.rl(sale text,p text,q integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('sale_line_id',t.line_of(sale,p),'quantity',q,'condition','resellable') $$;
CREATE FUNCTION t.ret(sale text,lines jsonb,refunds jsonb,expected text,p_key text,extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_sales_return(jsonb_build_object('sale_id',t.id(sale),'lines',lines,'refunds',refunds,'expected_total',expected,
                                                   'reason','Customer changed his mind') || extra,p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
-- One row of a report document by its key; does the row contain the expected members.
CREATE FUNCTION t.row(d jsonb,k text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT r FROM jsonb_array_elements(d->'rows') r WHERE r->>'key'=k $$;
CREATE FUNCTION t.has(d jsonb,k text,e jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(t.row(d,k) @> e,false) $$;
CREATE FUNCTION t.keys(d jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(r->>'key',',' ORDER BY ord),'') FROM jsonb_array_elements(d->'rows') WITH ORDINALITY x(r,ord) $$;
CREATE FUNCTION t.rep(g text,VARIADIC extra text[] DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE j jsonb; q text := format('SELECT public.report_sales(DATE %L, DATE %L, %L', '2026-09-01', '2026-10-31', g);
        i integer := 1;
BEGIN
  WHILE i <= COALESCE(array_length(extra,1),0) LOOP q := q || ', ' || extra[i] ; i := i + 1; END LOOP;
  EXECUTE q || ')' INTO j;
  RETURN j;
END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a, shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('D02 '||s,'d02-key-'||s,'retail_pro','Owner',s||'d02@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('d',64)),('b',repeat('e',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a0200000-0000-0000-8000-000000000001','ad02@example.com'),('a0200000-0000-0000-8000-000000000002','bd02@example.com'),
  ('a0200000-0000-0000-8000-000000000003','d02manager@example.com'),('a0200000-0000-0000-8000-000000000004','d02clerk@example.com'),
  ('a0200000-0000-0000-8000-000000000005','d02viewer@example.com');
SELECT public.accept_invite(repeat('d',64),'a0200000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('e',64),'a0200000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main-b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0 WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id=t.org('a');
INSERT INTO t.ids SELECT 'zero',id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='zero';
INSERT INTO t.ids SELECT 'std',id FROM public.tax_classes WHERE organization_id=t.org('a') AND kind='standard';
SELECT t.as_user('a0200000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids SELECT 'cib',(public.create_cash_account('CIB','bank',t.id('main'))->>'id')::uuid;
INSERT INTO t.ids VALUES('furniture',public.create_category('D02 Furniture',NULL));
INSERT INTO t.ids VALUES('chairs',public.create_category('D02 Chairs',t.id('furniture')));
INSERT INTO t.ids VALUES('electronics',public.create_category('D02 Electronics',NULL));
INSERT INTO t.ids VALUES('chair',public.create_product(jsonb_build_object('name_ar','كرسي','name_en','Chair','sku','D2-CH','cash_price','100','tax_class_id',t.id('zero'),'category_id',t.id('chairs'))));
INSERT INTO t.ids VALUES('table',public.create_product(jsonb_build_object('name_ar','طاولة','name_en','Table','sku','D2-TB','cash_price','1000','tax_class_id',t.id('std'),'category_id',t.id('furniture'))));
INSERT INTO t.ids VALUES('tv',public.create_product(jsonb_build_object('name_ar','تلفزيون','name_en','TV','sku','D2-TV','cash_price','12000','tax_class_id',t.id('std'),'category_id',t.id('electronics'),'is_serialized',true,'warranty_months',12)));
INSERT INTO t.ids VALUES('lamp',public.create_product(jsonb_build_object('name_ar','مصباح','name_en','Lamp','sku','D2-LP','cash_price','50','tax_class_id',t.id('zero'))));
RESET ROLE;
-- The cost snapshot of the plain products (the average cost the sale lines copy).
UPDATE public.products SET avg_cost=60 WHERE id=t.id('chair');
UPDATE public.products SET avg_cost=700 WHERE id=t.id('table');
UPDATE public.products SET avg_cost=20 WHERE id=t.id('lamp');
SELECT t.as_user('a0200000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',60),jsonb_build_object('product_id',t.id('table'),'quantity',10),
                    jsonb_build_object('product_id',t.id('lamp'),'quantity',20)),'d02-key-found');
SELECT public.post_stock_adjustment(t.id('second'),'found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',20),jsonb_build_object('product_id',t.id('lamp'),'quantity',20)),'d02-key-found2');
SELECT public.register_units(t.id('tv'),t.id('main'),'9000.00','["D2-TV-1","D2-TV-2"]',NULL,'d02-key-units');
RESET ROLE;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE id=t.id('main');
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branches text[] DEFAULT ARRAY['main']) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; b text; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branches[1])) RETURNING id INTO v;
  FOREACH b IN ARRAY branches LOOP
    INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(b));
  END LOOP;
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('manager','a0200000-0000-0000-8000-000000000003','D02 Manager','BRANCH_MANAGER',ARRAY['second','main']);
SELECT t.emp('clerk','a0200000-0000-0000-8000-000000000004','D02 Clerk','CASHIER',ARRAY['second']);
SELECT t.emp('viewer','a0200000-0000-0000-8000-000000000005','D02 Viewer','CASHIER',ARRAY['main']);
INSERT INTO t.ids SELECT 'owner',id FROM public.employees WHERE organization_id=t.org('a') AND role='OWNER';
-- The viewer may read reports but is not allowed to see costs (no report.financial).
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted)
  VALUES(t.org('a'),t.id('viewer'),'report.view',true),(t.org('a'),t.id('clerk'),'refund.create',true);
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id,city,address) VALUES
  (t.org('a'),'D02 Customer One',ARRAY['01066660001'],500000,'active','29101010100601','Cairo','5 B Street'),
  (t.org('a'),'D02 Customer Two',ARRAY['01066660002'],500000,'active','29101010100602','Giza','6 B Street');
INSERT INTO t.ids SELECT 'c1',id FROM public.customers WHERE organization_id=t.org('a') AND full_name='D02 Customer One';
INSERT INTO t.ids SELECT 'c2',id FROM public.customers WHERE organization_id=t.org('a') AND full_name='D02 Customer Two';
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'no_discount',0,
         1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');
CREATE FUNCTION t.u(n text) RETURNS text LANGUAGE sql AS $$ SELECT CASE n
  WHEN 'owner' THEN 'a0200000-0000-0000-8000-000000000001' WHEN 'owner-b' THEN 'a0200000-0000-0000-8000-000000000002'
  WHEN 'manager' THEN 'a0200000-0000-0000-8000-000000000003' WHEN 'clerk' THEN 'a0200000-0000-0000-8000-000000000004'
  WHEN 'viewer' THEN 'a0200000-0000-0000-8000-000000000005' END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
-- Shop b: its own branch / category / product (ids to aim at) and a sale that never counts here.
SELECT t.as_user(t.u('owner-b'),t.org('b'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('b-cat',public.create_category('D02 B Cat',NULL));
INSERT INTO t.ids VALUES('b-prod',public.create_product('{"name_ar":"منتج ب","sku":"D2-B","cash_price":"10"}'));
RESET ROLE;
INSERT INTO t.ids SELECT 'b-emp',id FROM public.employees WHERE organization_id=t.org('b') AND role='OWNER';

-- ---------------------------------------------------------------- the documents (made today, dated below)
-- Shifts: the owner in main, the manager and the clerk in second.
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT public.post_cash_opening(t.id('safe'),'20000.00','Opening','d02-key-opening');
SELECT public.post_cash_opening(t.id('safe2'),'2000.00','Opening','d02-key-opening2');
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'500.00','d02-key-shift');
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift-m',t.open_shift(t.id('second'),'200.00','d02-key-shift-m');
RESET ROLE;
SELECT t.as_user(t.u('clerk'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift-c',t.open_shift(t.id('second'),'100.00','d02-key-shift-c');
RESET ROLE;

SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
-- S0: before the period (31 Aug).
INSERT INTO t.docs SELECT 's0',public.post_sale(t.lines(t.items('chair',1)),'100.00','d02-key-s0',NULL,t.lines(t.pcash('100.00')));
-- S1: 3 chairs, cash. S2: 5 chairs to customer one, cash 200 + bank 300.
INSERT INTO t.docs SELECT 's1',public.post_sale(t.lines(t.items('chair',3)),'300.00','d02-key-s1',NULL,t.lines(t.pcash('300.00')));
INSERT INTO t.docs SELECT 's2',public.post_sale(t.lines(t.items('chair',5)),'500.00','d02-key-s2',t.id('c1'),t.lines(t.pcash('200.00'),t.pbank('300.00','cib','TRX-2')));
-- S3: a table (VAT) + 2 lamps. S4: a chair paid by bank, voided the same day.
INSERT INTO t.docs SELECT 's3',public.post_sale(t.lines(t.items('table',1),t.items('lamp',2)),'1100.00','d02-key-s3',NULL,t.lines(t.pcash('1100.00')));
INSERT INTO t.docs SELECT 's4',public.post_sale(t.lines(t.items('chair',1)),'100.00','d02-key-s4',NULL,t.lines(t.pbank('100.00','cib','TRX-4')));
INSERT INTO t.docs SELECT 'void',public.void_sale((t.doc('s4')->>'id')::uuid,'Customer changed mind','d02-key-void');
-- S11: after the period (1 Nov).
INSERT INTO t.docs SELECT 's11',public.post_sale(t.lines(t.items('chair',1)),'100.00','d02-key-s11',NULL,t.lines(t.pcash('100.00')));
RESET ROLE;
INSERT INTO t.ids SELECT 's'||n,(t.doc('s'||n)->>'id')::uuid FROM unnest(ARRAY[0,1,2,3,4,11]) n;
-- R2 first (store credit for customer one), then S6 pays with it.
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r2',t.ret('s2',jsonb_build_array(t.rl('s2','chair',1)),jsonb_build_array(t.pcredit('100.00')),'100.00','d02-key-r2');
-- R1: one chair of S1 back for cash (the sale is September's, the return is October's).
INSERT INTO t.docs SELECT 'r1',t.ret('s1',jsonb_build_array(t.rl('s1','chair',1)),jsonb_build_array(t.pcash('100.00')),'100.00','d02-key-r1');
-- R4: a chair of S2 back on 1 Nov (after the period).
INSERT INTO t.docs SELECT 'r4',t.ret('s2',jsonb_build_array(t.rl('s2','chair',1)),jsonb_build_array(t.pcash('100.00')),'100.00','d02-key-r4');
-- S7: two tables on installments (down 200).
INSERT INTO t.docs SELECT 's7',public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id('table'),'quantity',2)),
    'expected_total','2000.00','customer_id',t.id('c2'),
    'terms',jsonb_build_object('down_payment','200.00','installments_count',12,'frequency','monthly','policy_version',t.pv())),'d02-key-s7');
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
-- S10: a TV (serialized), paid by bank.
INSERT INTO t.docs SELECT 's10',public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1,'unit_id',t.unit('D2-TV-1'))),
  '12000.00','d02-key-s10',NULL,t.lines(t.pbank('12000.00','cib','TRX-10')));
-- R3: one of the two tables back (the contract's profit share goes back with it).
RESET ROLE;
INSERT INTO t.ids SELECT 's7',(t.doc('s7')->'sale'->>'id')::uuid;
INSERT INTO t.ids SELECT 's10',(t.doc('s10')->>'id')::uuid;
INSERT INTO t.ids SELECT 'contract7',(t.doc('s7')->'contract'->>'id')::uuid;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r3',t.ret('s7',jsonb_build_array(t.rl('s7','table',1)),'[]','1000.00','d02-key-r3');
RESET ROLE;
-- The manager (second): S5, 2 chairs with 10 % off.
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's5',public.post_sale(t.lines(t.dl('chair',2,t.pct('10'))),'180.00','d02-key-s5',NULL,t.lines(t.pcash('180.00')),NULL,'Closing offer');
RESET ROLE;
INSERT INTO t.ids SELECT 's5',(t.doc('s5')->>'id')::uuid;
-- The clerk (second): S6 to customer one, a lamp and a chair, 100 by store credit + 50 cash; then an
-- exchange of one chair of S5 (90) for 2 lamps (100): the credit 90 + 10 cash pay the new sale.
SELECT t.as_user(t.u('clerk'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's6',public.post_sale(t.lines(t.items('lamp',1),t.items('chair',1)),'150.00','d02-key-s6',t.id('c1'),t.lines(t.pcredit('100.00'),t.pcash('50.00')));
INSERT INTO t.docs SELECT 'rx',t.ret('s5',jsonb_build_array(t.rl('s5','chair',1)),'[]','90.00','d02-key-rx',
  jsonb_build_object('kind','exchange','new_sale',jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',t.id('lamp'),'quantity',2)),
    'expected_total','100.00','payments',jsonb_build_array(t.pcash('10.00')))));
RESET ROLE;
INSERT INTO t.ids SELECT 's6',(t.doc('s6')->>'id')::uuid;
INSERT INTO t.ids SELECT 's9',(t.doc('rx')->'exchange_sale'->>'id')::uuid;
INSERT INTO t.ids SELECT tag,(t.doc(tag)->>'id')::uuid FROM unnest(ARRAY['r1','r2','r3','r4','rx']) tag;
INSERT INTO t.ids SELECT 'void-row',id FROM public.sales_returns WHERE sale_id=t.id('s4') AND kind='void';
SELECT t.expect('setup: the documents exist',
  (SELECT count(*) FROM t.ids WHERE tag IN ('s0','s1','s2','s3','s4','s5','s6','s7','s9','s10','s11','r1','r2','r3','r4','rx','void-row'))=17);

-- Dated by hand, as the database owner (triggers off): September, October and just outside the period.
SET session_replication_role = replica;
UPDATE public.sales SET business_date=DATE '2026-08-31' WHERE id=t.id('s0');
UPDATE public.sales SET business_date=DATE '2026-09-10' WHERE id IN (t.id('s1'),t.id('s2'));
UPDATE public.sales SET business_date=DATE '2026-09-20' WHERE id IN (t.id('s3'),t.id('s4'));
UPDATE public.sales_returns SET business_date=DATE '2026-09-20' WHERE id=t.id('void-row');
UPDATE public.sales SET business_date=DATE '2026-10-05' WHERE id=t.id('s5');
UPDATE public.sales SET business_date=DATE '2026-10-06' WHERE id=t.id('s6');
UPDATE public.sales SET business_date=DATE '2026-10-08' WHERE id=t.id('s7');
UPDATE public.sales SET business_date=DATE '2026-10-15' WHERE id=t.id('s10');
UPDATE public.sales SET business_date=DATE '2026-10-20' WHERE id=t.id('s9');
UPDATE public.sales SET business_date=DATE '2026-11-01' WHERE id=t.id('s11');
UPDATE public.sales_returns SET business_date=DATE '2026-10-07' WHERE id=t.id('r2');
UPDATE public.sales_returns SET business_date=DATE '2026-10-12' WHERE id=t.id('r1');
UPDATE public.sales_returns SET business_date=DATE '2026-10-20' WHERE id=t.id('rx');
UPDATE public.sales_returns SET business_date=DATE '2026-10-25' WHERE id=t.id('r3');
UPDATE public.sales_returns SET business_date=DATE '2026-11-01' WHERE id=t.id('r4');
-- Shop b: a sale of its own in the period, never counted in shop a.
INSERT INTO public.sales(organization_id,number,branch_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key,issued_at)
  VALUES(t.org('b'),'D02-B-SALE',t.id('main-b'),'pos',false,true,999,999,DATE '2026-09-15','d02-key-b-sale',now());
INSERT INTO public.sale_lines(organization_id,sale_id,line_no,product_id,tax_class_id,quantity,unit_price,discount_amount,tax_rate,tax_amount,line_total,unit_cost)
  SELECT t.org('b'),s.id,1,t.id('b-prod'),(SELECT id FROM public.tax_classes WHERE organization_id=t.org('b') AND kind='zero'),1,999,0,0,0,999,400
  FROM public.sales s WHERE s.number='D02-B-SALE';
SET session_replication_role = origin;
SELECT t.expect('setup: the installment sale has its contract (markup 360 = 20 % of the 1 800 financed)',
  (SELECT markup_amount=360 AND financed_amount=1800 AND sale_id=t.id('s7') FROM public.contracts WHERE id=t.id('contract7')),
  (SELECT concat_ws(' ',markup_amount,financed_amount,cash_price) FROM public.contracts WHERE id=t.id('contract7')));
SELECT t.expect('setup: the discounted sale has 180 gross, discount 20 on its line; the VAT lines are as worked out',
  (SELECT line_total=180 AND discount_amount=20 AND tax_amount=0 FROM public.sale_lines WHERE sale_id=t.id('s5'))
  AND (SELECT line_total=1000 AND tax_amount=122.81 AND unit_cost=700 FROM public.sale_lines WHERE sale_id=t.id('s3') AND product_id=t.id('table'))
  AND (SELECT line_total=12000 AND tax_amount=1473.68 AND unit_cost=9000 FROM public.sale_lines WHERE sale_id=t.id('s10')),
  (SELECT string_agg(concat_ws('/',line_total,discount_amount,tax_amount,unit_cost),' ') FROM public.sale_lines WHERE sale_id IN (t.id('s5'),t.id('s3'),t.id('s10'))));

-- ================================================================ the owner: every grouping
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'month',t.rep('month');
INSERT INTO t.docs SELECT 'day',t.rep('day');
INSERT INTO t.docs SELECT 'branch',t.rep('branch');
INSERT INTO t.docs SELECT 'employee',t.rep('employee');
INSERT INTO t.docs SELECT 'category',t.rep('category');
INSERT INTO t.docs SELECT 'category-top',t.rep('category','p_category_level => ''top''');
INSERT INTO t.docs SELECT 'product',t.rep('product');
INSERT INTO t.docs SELECT 'sale-type',t.rep('sale_type');
INSERT INTO t.docs SELECT 'payment',t.rep('payment_type');
RESET ROLE;

SELECT t.expect('envelope: period, grouping, cost visible, paging, a timestamp, no filters set',
  t.doc('month')->>'from'='2026-09-01' AND t.doc('month')->>'to'='2026-10-31' AND t.doc('month')->>'group_by'='month'
  AND (t.doc('month')->>'can_see_cost')::boolean AND (t.doc('month')->>'page')::int=1 AND (t.doc('month')->>'page_size')::int=50
  AND (t.doc('month')->>'total_count')::int=2 AND (t.doc('month')->>'generated_at')::timestamptz > now()-interval '1 minute'
  AND t.doc('month')->'filters'->'employee_id'='null'::jsonb, t.doc('month')::text);

-- Hand-worked totals of the period (the voided S4, 31 Aug's S0, 1 Nov's S11 and R4, and shop b's sale are out):
-- sales S1 S2 S3 S5 S6 S7 S9 S10 = 8; quantity 3+5+3+2+2+2+2+1 = 20; gross 300+500+1100+180+150+2000+100+12000 = 16330;
-- VAT 122.81+245.61+1473.68 = 1842.10; revenue 14487.90; cost 180+300+740+120+80+1400+40+9000 = 11860; margin 2627.90 (18.1 %).
-- Returns R1 R2 R3 RX = 4: quantity 4; gross 100+100+1000+90 = 1290; VAT 122.81; revenue 1167.19; cost 60+60+700+60 = 880.
SELECT t.expect('totals: sales and returns of the period, from the headers, worked out by hand',
  t.doc('month')->'totals' @> '{"sales_count":8,"quantity":20,"revenue":"14487.90","gross":"16330.00","tax":"1842.10","discount":"20.00","cost":"11860.00","margin":"2627.90","margin_pct":"18.1","return_count":4,"returned_quantity":4,"returned_gross":"1290.00","returned_revenue":"1167.19","returned_tax":"122.81","returned_cost":"880.00","returned_margin":"287.19","net_quantity":16,"net_revenue":"13320.71","net_cost":"10980.00","net_margin":"2340.71","net_margin_pct":"17.6","contract_profit":"360.00","contract_profit_returned":"180.00"}'::jsonb,
  t.doc('month')->>'totals');
SELECT t.expect('totals equal the document headers (independent reads): sales.total / tax_total / cost_total, returns total / tax_total',
  (SELECT sum(total)::text=(t.doc('month')->'totals'->>'gross') AND sum(tax_total)=(t.doc('month')->'totals'->>'tax')::numeric
          AND count(*)=(t.doc('month')->'totals'->>'sales_count')::int AND sum(cost_total)=(t.doc('month')->'totals'->>'cost')::numeric
   FROM public.sales s WHERE s.organization_id=t.org('a') AND s.business_date BETWEEN DATE '2026-09-01' AND DATE '2026-10-31'
     AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id AND r.kind='void'))
  AND (SELECT sum(total)::text=(t.doc('month')->'totals'->>'returned_gross') AND sum(tax_total)=(t.doc('month')->'totals'->>'returned_tax')::numeric
       FROM public.sales_returns r WHERE r.organization_id=t.org('a') AND r.kind IN ('return','exchange')
         AND r.business_date BETWEEN DATE '2026-09-01' AND DATE '2026-10-31'));
SELECT t.expect('the self-check passes for every grouping (rows of all pages = totals)',
  (SELECT bool_and((t.doc(g)->'check'->>'rows_match')::boolean) FROM unnest(ARRAY['month','day','branch','employee','category','category-top','product','sale-type','payment']) g),
  (SELECT string_agg(g||' '||(t.doc(g)->'check')::text,E'\n') FROM unnest(ARRAY['month','day','branch','employee','category','category-top','product','sale-type','payment']) g));
SELECT t.expect('the self-check differences are zero for revenue, tax and returned revenue (and the cost within the rounding)',
  (t.doc('product')->'check'->'differences'->>'revenue')='0.00' AND (t.doc('product')->'check'->'differences'->>'tax')='0.00'
  AND (t.doc('product')->'check'->'differences'->>'returned_revenue')='0.00' AND (t.doc('product')->'check'->'differences'->>'gross')='0.00'
  AND abs((t.doc('product')->'check'->'differences'->>'cost')::numeric)<=0.08, t.doc('product')->>'check');
SELECT t.expect('every grouping answers the same totals (the headers do not depend on the grouping)',
  (SELECT count(DISTINCT t.doc(g)->'totals'->>'gross')=1 AND count(DISTINCT t.doc(g)->'totals'->>'revenue')=1
          AND count(DISTINCT t.doc(g)->'totals'->>'returned_gross')=1
   FROM unnest(ARRAY['month','day','branch','employee','category','product','sale-type','payment']) g));

-- month: September S1 S2 S3 (3 sales, 11 chairs/tables/lamps: 3+5+1+2; gross 1900; VAT 122.81; cost 180+300+740 = 1220);
-- October S5 S6 S7 S9 S10 (5 sales, 9 pieces) and all four returns.
SELECT t.expect('month: September has 3 sales, 11 pieces, 1777.19 revenue, 1220 cost, 557.19 margin, no returns; label YYYY-MM',
  t.has(t.doc('month'),'2026-09-01','{"label":"2026-09","sales_count":3,"quantity":11,"revenue":"1777.19","gross":"1900.00","tax":"122.81","discount":"0.00","cost":"1220.00","margin":"557.19","margin_pct":"31.4","return_count":0,"returned_quantity":0,"returned_gross":"0.00","net_quantity":11,"net_revenue":"1777.19","net_cost":"1220.00","net_margin":"557.19","contract_profit":"0.00","contract_profit_returned":"0.00"}'),
  t.row(t.doc('month'),'2026-09-01')::text);
SELECT t.expect('month: October has 5 sales, 9 pieces, 12710.71 revenue, 10640 cost and all four returns (S1''s and S2''s are September sales)',
  t.has(t.doc('month'),'2026-10-01','{"label":"2026-10","sales_count":5,"quantity":9,"revenue":"12710.71","gross":"14430.00","tax":"1719.29","discount":"20.00","cost":"10640.00","margin":"2070.71","margin_pct":"16.3","return_count":4,"returned_quantity":4,"returned_gross":"1290.00","returned_revenue":"1167.19","returned_tax":"122.81","returned_cost":"880.00","returned_margin":"287.19","net_quantity":5,"net_revenue":"11543.52","net_cost":"9760.00","net_margin":"1783.52","net_margin_pct":"15.5","contract_profit":"360.00","contract_profit_returned":"180.00"}'),
  t.row(t.doc('month'),'2026-10-01')::text);
SELECT t.expect('month: the two rows add up to the totals (revenue, quantity)',
  (SELECT sum((r->>'revenue')::numeric)=14487.90 AND sum((r->>'quantity')::int)=20 FROM jsonb_array_elements(t.doc('month')->'rows') r));
SELECT t.expect('the voided sale, 31 Aug, 1 Nov (a sale and a return) and shop b''s sale are nowhere',
  t.doc('month')->'totals'->>'gross'='16330.00' AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('day')->'rows') r WHERE r->>'key' IN ('2026-08-31','2026-11-01')));

-- day: 10 days with a sale or a return.
SELECT t.expect('day: 10 days, ascending; 10 Sep holds S1 + S2 (8 chairs, 800), 7 Oct only R2 (no sale, a return), 20 Oct the exchange''s sale and return',
  t.keys(t.doc('day'))='2026-09-10,2026-09-20,2026-10-05,2026-10-06,2026-10-07,2026-10-08,2026-10-12,2026-10-15,2026-10-20,2026-10-25'
  AND (t.doc('day')->>'total_count')::int=10
  AND t.has(t.doc('day'),'2026-09-10','{"sales_count":2,"quantity":8,"gross":"800.00","revenue":"800.00","cost":"480.00","margin":"320.00"}')
  AND t.has(t.doc('day'),'2026-09-20','{"sales_count":1,"quantity":3,"gross":"1100.00","tax":"122.81","revenue":"977.19","cost":"740.00"}')
  AND t.has(t.doc('day'),'2026-10-07','{"sales_count":0,"quantity":0,"revenue":"0.00","margin_pct":null,"return_count":1,"returned_gross":"100.00","net_revenue":"-100.00","net_cost":"-60.00","net_margin":"-40.00"}')
  AND t.has(t.doc('day'),'2026-10-20','{"sales_count":1,"quantity":2,"gross":"100.00","return_count":1,"returned_gross":"90.00","net_revenue":"10.00"}')
  AND t.has(t.doc('day'),'2026-10-25','{"sales_count":0,"return_count":1,"returned_gross":"1000.00","returned_revenue":"877.19","returned_tax":"122.81","returned_cost":"700.00","contract_profit_returned":"180.00"}'),
  t.keys(t.doc('day')));

-- branch: main S1 S2 S3 S7 S10 + returns R1 R2 R3; second S5 S6 S9 + RX.
SELECT t.expect('branch main: 5 sales, 14 pieces, 15900 gross, 14057.90 revenue, 11620 cost; 3 returns (1200 gross, 820 cost, profit share 180)',
  t.has(t.doc('branch'),t.id('main')::text,'{"label":"Main","sales_count":5,"quantity":14,"gross":"15900.00","tax":"1842.10","revenue":"14057.90","discount":"0.00","cost":"11620.00","margin":"2437.90","return_count":3,"returned_quantity":3,"returned_gross":"1200.00","returned_tax":"122.81","returned_revenue":"1077.19","returned_cost":"820.00","returned_margin":"257.19","net_revenue":"12980.71","net_cost":"10800.00","net_margin":"2180.71","contract_profit":"360.00","contract_profit_returned":"180.00"}'),
  t.row(t.doc('branch'),t.id('main')::text)::text);
SELECT t.expect('branch second: 3 sales, 6 pieces, 430 gross, no VAT, 20 discount, 240 cost; the exchange''s return 90 (cost 60)',
  t.has(t.doc('branch'),t.id('second')::text,'{"label":"Second","sub_label":"S2","sales_count":3,"quantity":6,"gross":"430.00","tax":"0.00","revenue":"430.00","discount":"20.00","cost":"240.00","margin":"190.00","return_count":1,"returned_quantity":1,"returned_gross":"90.00","returned_revenue":"90.00","returned_cost":"60.00","net_revenue":"340.00","net_cost":"180.00","net_margin":"160.00","contract_profit":"0.00"}'),
  t.row(t.doc('branch'),t.id('second')::text)::text);

-- employee: the seller. The return of S5's chair (taken back by the clerk) counts against the manager.
SELECT t.expect('employee owner: S1 S2 S3 S7 S10 (as main) and the returns of their sales R1 R2 R3',
  t.has(t.doc('employee'),t.id('owner')::text,'{"sales_count":5,"quantity":14,"gross":"15900.00","revenue":"14057.90","cost":"11620.00","return_count":3,"returned_gross":"1200.00","returned_cost":"820.00","net_revenue":"12980.71","contract_profit":"360.00"}'),
  t.row(t.doc('employee'),t.id('owner')::text)::text);
SELECT t.expect('employee manager: S5 (180, cost 120, discount 20) and the exchange return of S5''s chair (taken back by the clerk, counted against the seller)',
  t.has(t.doc('employee'),t.id('manager')::text,'{"label":"D02 Manager","sales_count":1,"quantity":2,"gross":"180.00","revenue":"180.00","discount":"20.00","cost":"120.00","margin":"60.00","return_count":1,"returned_quantity":1,"returned_gross":"90.00","returned_cost":"60.00","net_revenue":"90.00","net_cost":"60.00","net_margin":"30.00"}'),
  t.row(t.doc('employee'),t.id('manager')::text)::text);
SELECT t.expect('employee clerk: S6 and the exchange''s new sale S9 (3 pieces, 250), no return against them (they only took one back)',
  t.has(t.doc('employee'),t.id('clerk')::text,'{"label":"D02 Clerk","sales_count":2,"quantity":4,"gross":"250.00","revenue":"250.00","cost":"120.00","margin":"130.00","return_count":0,"returned_gross":"0.00"}'),
  t.row(t.doc('employee'),t.id('clerk')::text)::text);

-- category (leaf = the product's current category): Chairs, Furniture (the table), Electronics, none (lamps).
SELECT t.expect('category Chairs: 4 sales (S1 S2 S5 S6), 11 chairs, 1080 gross, cost 660, discount 20; 3 returns (R1 R2 RX) 290 gross, cost 180',
  t.has(t.doc('category'),t.id('chairs')::text,'{"label":"D02 Chairs","sales_count":4,"quantity":11,"gross":"1080.00","tax":"0.00","revenue":"1080.00","discount":"20.00","cost":"660.00","margin":"420.00","return_count":3,"returned_quantity":3,"returned_gross":"290.00","returned_revenue":"290.00","returned_cost":"180.00","net_revenue":"790.00","net_cost":"480.00","net_margin":"310.00"}'),
  t.row(t.doc('category'),t.id('chairs')::text)::text);
SELECT t.expect('category Furniture (leaf): the tables only: 2 sales, 3 tables, 3000 gross, VAT 368.42, cost 2100, profit 360; the table return 1000',
  t.has(t.doc('category'),t.id('furniture')::text,'{"label":"D02 Furniture","sales_count":2,"quantity":3,"gross":"3000.00","tax":"368.42","revenue":"2631.58","cost":"2100.00","margin":"531.58","return_count":1,"returned_quantity":1,"returned_gross":"1000.00","returned_revenue":"877.19","returned_cost":"700.00","contract_profit":"360.00","contract_profit_returned":"180.00"}'),
  t.row(t.doc('category'),t.id('furniture')::text)::text);
SELECT t.expect('category Electronics and "no category" (the lamps: 3 sales, 5 lamps, 250 gross, cost 100)',
  t.has(t.doc('category'),t.id('electronics')::text,'{"sales_count":1,"quantity":1,"gross":"12000.00","tax":"1473.68","revenue":"10526.32","cost":"9000.00","margin":"1526.32"}')
  AND t.has(t.doc('category'),'none','{"label":null,"sales_count":3,"quantity":5,"gross":"250.00","revenue":"250.00","cost":"100.00","margin":"150.00","return_count":0}'),
  t.keys(t.doc('category')));
SELECT t.expect('category top level: Chairs roll up into Furniture (6 sales, 14 pieces, 4080 gross, cost 2760, 4 returns 1290); Chairs is no row',
  t.has(t.doc('category-top'),t.id('furniture')::text,'{"sales_count":6,"quantity":14,"gross":"4080.00","tax":"368.42","revenue":"3711.58","cost":"2760.00","margin":"951.58","return_count":4,"returned_quantity":4,"returned_gross":"1290.00","returned_cost":"880.00"}')
  AND t.row(t.doc('category-top'),t.id('chairs')::text) IS NULL AND (t.doc('category-top')->>'total_count')::int=3,
  t.keys(t.doc('category-top')));

SELECT t.expect('product: chair / table / tv / lamp as the categories above; the TV''s SKU is the sub label',
  t.has(t.doc('product'),t.id('chair')::text,'{"label":"كرسي","label_en":"Chair","sub_label":"D2-CH","quantity":11,"gross":"1080.00","cost":"660.00","returned_quantity":3,"returned_gross":"290.00"}')
  AND t.has(t.doc('product'),t.id('table')::text,'{"label_en":"Table","sales_count":2,"quantity":3,"gross":"3000.00","cost":"2100.00","returned_quantity":1,"contract_profit":"360.00"}')
  AND t.has(t.doc('product'),t.id('tv')::text,'{"sub_label":"D2-TV","sales_count":1,"quantity":1,"revenue":"10526.32","cost":"9000.00","margin_pct":"14.5"}')
  AND t.has(t.doc('product'),t.id('lamp')::text,'{"sales_count":3,"quantity":5,"gross":"250.00","cost":"100.00"}'),
  t.keys(t.doc('product')));
SELECT t.expect('product: the contract profit of a two-line sale is split over its lines (one line here = all of it); the sale type grouping keeps it apart from margin',
  t.has(t.doc('sale-type'),'installment','{"sales_count":1,"quantity":2,"gross":"2000.00","tax":"245.61","revenue":"1754.39","cost":"1400.00","margin":"354.39","contract_profit":"360.00","return_count":1,"returned_gross":"1000.00","contract_profit_returned":"180.00"}')
  AND t.has(t.doc('sale-type'),'cash','{"sales_count":7,"quantity":18,"gross":"14330.00","tax":"1596.49","revenue":"12733.51","cost":"10460.00","margin":"2273.51","contract_profit":"0.00","return_count":3,"returned_quantity":3,"returned_gross":"290.00"}'),
  t.keys(t.doc('sale-type')));
SELECT t.expect('the installment sale''s contract profit (360) is not in any margin: margin = revenue - cost on the cash price',
  (t.doc('month')->'totals'->>'margin')::numeric=(t.doc('month')->'totals'->>'revenue')::numeric-(t.doc('month')->'totals'->>'cost')::numeric);

-- payment type: money received. Cash 300+200+1100+180+50+200(down)+100 (the exchange sale: 10 cash + the credit 90 through the drawer)
-- = 2130; bank 300+12000 = 12300; store credit 100; on contract 1800 (the financed amount); they add up to the gross 16330.
SELECT t.expect('payment type: cash 2130, bank 12300, store credit 100, on contract 1800; they add up to the sales of the period (16330)',
  t.keys(t.doc('payment'))='cash,bank_transfer,store_credit,on_contract'
  AND t.has(t.doc('payment'),'cash','{"amount":"2130.00"}') AND t.has(t.doc('payment'),'bank_transfer','{"amount":"12300.00"}')
  AND t.has(t.doc('payment'),'store_credit','{"amount":"100.00"}') AND t.has(t.doc('payment'),'on_contract','{"amount":"1800.00"}')
  AND (SELECT sum((r->>'amount')::numeric) FROM jsonb_array_elements(t.doc('payment')->'rows') r)=16330
  AND (SELECT sum(total) FROM public.sales s WHERE s.organization_id=t.org('a') AND s.business_date BETWEEN DATE '2026-09-01' AND DATE '2026-10-31'
         AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id AND r.kind='void'))=16330,
  t.doc('payment')::text);
SELECT t.expect('payment type: quantity, revenue and cost are null (money only); refunds by the return''s method: store credit 100, on contract 1000 (the table), and they add up to the returns (1290)',
  t.has(t.doc('payment'),'cash','{"quantity":null,"revenue":null,"cost":null,"margin":null,"sales_count":null}')
  AND t.has(t.doc('payment'),'store_credit','{"refunded":"100.00","net_amount":"0.00"}')
  AND t.has(t.doc('payment'),'on_contract','{"refunded":"1000.00","net_amount":"800.00"}')
  AND (SELECT sum((r->>'refunded')::numeric) FROM jsonb_array_elements(t.doc('payment')->'rows') r)=1290
  AND t.doc('payment')->'totals'->>'amount'='16330.00' AND t.doc('payment')->'totals'->>'refunded'='1290.00',
  t.doc('payment')::text);

-- ================================================================ filters
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'f-branch',t.rep('month',format('p_branch_id => %L',t.id('second')));
INSERT INTO t.docs SELECT 'f-emp',t.rep('day',format('p_employee_id => %L',t.id('manager')));
INSERT INTO t.docs SELECT 'f-cat',t.rep('product',format('p_category_id => %L',t.id('furniture')));
INSERT INTO t.docs SELECT 'f-cat-leaf',t.rep('product',format('p_category_id => %L',t.id('chairs')));
INSERT INTO t.docs SELECT 'f-prod',t.rep('branch',format('p_product_id => %L',t.id('lamp')));
INSERT INTO t.docs SELECT 'f-type',t.rep('day','p_sale_type => ''installment''');
INSERT INTO t.docs SELECT 'f-pay-emp',t.rep('payment_type',format('p_employee_id => %L',t.id('manager')));
RESET ROLE;
SELECT t.expect('filter branch (second): the branch''s numbers, the check still runs against the branch''s headers',
  t.doc('f-branch')->'totals' @> '{"sales_count":3,"gross":"430.00","returned_gross":"90.00"}'::jsonb
  AND (t.doc('f-branch')->'check'->>'rows_match')::boolean AND t.doc('f-branch')->'filters'->>'branch_id'=t.id('second')::text,
  t.doc('f-branch')::text);
SELECT t.expect('filter employee (manager): only S5 and the return of its chair; the totals are the sum of the rows and the check is null',
  t.keys(t.doc('f-emp'))='2026-10-05,2026-10-20'
  AND t.doc('f-emp')->'totals' @> '{"sales_count":1,"quantity":2,"gross":"180.00","revenue":"180.00","return_count":1,"returned_gross":"90.00","net_revenue":"90.00"}'::jsonb
  AND t.doc('f-emp')->'check'='null'::jsonb, t.doc('f-emp')::text);
SELECT t.expect('filter category (Furniture) includes its sub-category Chairs: 4 products shown are chair and table only; totals 6 sales, 14 pieces, 4080 gross',
  t.keys(t.doc('f-cat')) IN (t.id('chair')::text||','||t.id('table')::text,t.id('table')::text||','||t.id('chair')::text)
  AND t.doc('f-cat')->'totals' @> '{"sales_count":6,"quantity":14,"gross":"4080.00","return_count":4,"returned_gross":"1290.00"}'::jsonb
  AND t.doc('f-cat')->'check'='null'::jsonb, t.doc('f-cat')::text);
SELECT t.expect('filter category (Chairs, the child): chairs only, not the parent''s tables',
  t.keys(t.doc('f-cat-leaf'))=t.id('chair')::text AND t.doc('f-cat-leaf')->'totals' @> '{"quantity":11,"gross":"1080.00"}'::jsonb);
SELECT t.expect('filter product (lamp): lamps only, by branch; a product filter keeps only that product''s lines',
  t.doc('f-prod')->'totals' @> '{"sales_count":3,"quantity":5,"gross":"250.00","cost":"100.00"}'::jsonb
  AND t.has(t.doc('f-prod'),t.id('main')::text,'{"sales_count":1,"quantity":2,"gross":"100.00"}')
  AND t.has(t.doc('f-prod'),t.id('second')::text,'{"sales_count":2,"quantity":3,"gross":"150.00"}'), t.doc('f-prod')::text);
SELECT t.expect('filter sale type (installment): the installment sale and its return only, the profit beside them',
  t.keys(t.doc('f-type'))='2026-10-08,2026-10-25'
  AND t.doc('f-type')->'totals' @> '{"sales_count":1,"gross":"2000.00","contract_profit":"360.00","contract_profit_returned":"180.00","return_count":1}'::jsonb);
SELECT t.expect('payment type with an employee filter: only the manager''s sale S5 (180 cash) and the exchange refund; no check',
  t.has(t.doc('f-pay-emp'),'cash','{"amount":"180.00"}') AND t.has(t.doc('f-pay-emp'),'bank_transfer','{"amount":"0.00"}')
  AND t.doc('f-pay-emp')->'totals'->>'amount'='180.00' AND t.doc('f-pay-emp')->'check'='null'::jsonb, t.doc('f-pay-emp')::text);

-- ================================================================ sorting and paging
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'o-rev',t.rep('product');
INSERT INTO t.docs SELECT 'o-rev-asc',t.rep('product','p_sort => ''revenue_asc''');
INSERT INTO t.docs SELECT 'o-qty',t.rep('product','p_sort => ''quantity_desc''');
INSERT INTO t.docs SELECT 'o-margin',t.rep('product','p_sort => ''margin_desc''');
INSERT INTO t.docs SELECT 'o-margin-asc',t.rep('product','p_sort => ''margin_asc''');
INSERT INTO t.docs SELECT 'o-net',t.rep('product','p_sort => ''net_revenue_desc''');
INSERT INTO t.docs SELECT 'o-key',t.rep('branch','p_sort => ''key_asc''');
INSERT INTO t.docs SELECT 'o-key-day',t.rep('month','p_sort => ''revenue_desc''');
INSERT INTO t.docs SELECT 'o-p1',t.rep('product','p_page => 1','p_page_size => 2');
INSERT INTO t.docs SELECT 'o-p2',t.rep('product','p_page => 2','p_page_size => 2');
INSERT INTO t.docs SELECT 'o-p3',t.rep('product','p_page => 3','p_page_size => 2');
RESET ROLE;
SELECT t.expect('sort revenue_desc (the default for a product grouping): tv, table, chair, lamp',
  t.keys(t.doc('o-rev'))=concat_ws(',',t.id('tv'),t.id('table'),t.id('chair'),t.id('lamp')) AND t.doc('o-rev')->>'sort'='revenue_desc', t.keys(t.doc('o-rev')));
SELECT t.expect('sort revenue_asc, quantity_desc (chair 11, lamp 5, table 3, tv 1), margin_desc (tv, table, chair, lamp), margin_asc, net_revenue_desc',
  t.keys(t.doc('o-rev-asc'))=concat_ws(',',t.id('lamp'),t.id('chair'),t.id('table'),t.id('tv'))
  AND t.keys(t.doc('o-qty'))=concat_ws(',',t.id('chair'),t.id('lamp'),t.id('table'),t.id('tv'))
  AND t.keys(t.doc('o-margin'))=concat_ws(',',t.id('tv'),t.id('table'),t.id('chair'),t.id('lamp'))
  AND t.keys(t.doc('o-margin-asc'))=concat_ws(',',t.id('lamp'),t.id('chair'),t.id('table'),t.id('tv'))
  AND t.keys(t.doc('o-net'))=concat_ws(',',t.id('tv'),t.id('table'),t.id('chair'),t.id('lamp')),
  concat_ws(' | ',t.keys(t.doc('o-qty')),t.keys(t.doc('o-margin'))));
SELECT t.expect('sort key_asc by name (Main, Second); a month grouping defaults to key_asc, a product grouping to revenue_desc',
  t.keys(t.doc('o-key'))=t.id('main')::text||','||t.id('second')::text AND t.doc('month')->>'sort'='key_asc' AND t.doc('o-key-day')->>'sort'='revenue_desc'
  AND t.keys(t.doc('o-key-day'))='2026-10-01,2026-09-01', t.keys(t.doc('o-key-day')));
SELECT t.expect('paging: 2 per page, 4 rows; page 3 is empty; totals and the check cover the whole result on every page',
  t.keys(t.doc('o-p1'))=t.id('tv')::text||','||t.id('table')::text AND t.keys(t.doc('o-p2'))=t.id('chair')::text||','||t.id('lamp')::text
  AND jsonb_array_length(t.doc('o-p3')->'rows')=0 AND (t.doc('o-p1')->>'total_count')::int=4 AND (t.doc('o-p3')->>'total_count')::int=4
  AND t.doc('o-p1')->'totals'=t.doc('o-p3')->'totals' AND (t.doc('o-p3')->'check'->>'rows_match')::boolean
  AND (t.doc('o-p2')->>'page')::int=2 AND (t.doc('o-p2')->>'page_size')::int=2);

-- ================================================================ who sees what
SELECT t.as_user(t.u('viewer'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'v-month',t.rep('month');
INSERT INTO t.docs SELECT 'v-product',t.rep('product');
INSERT INTO t.docs SELECT 'v-pay',t.rep('payment_type');
RESET ROLE;
SELECT t.expect('without report.financial: every cost, margin and contract-profit value is null, can_see_cost is false, revenue and returns stay',
  NOT (t.doc('v-month')->>'can_see_cost')::boolean
  AND t.doc('v-month')->'totals' @> '{"cost":null,"margin":null,"margin_pct":null,"returned_cost":null,"returned_margin":null,"net_cost":null,"net_margin":null,"net_margin_pct":null,"contract_profit":null,"contract_profit_returned":null}'::jsonb
  AND t.doc('v-month')->'totals'->>'net_revenue' IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('v-product')->'rows') r WHERE r->>'cost' IS NOT NULL OR r->>'margin' IS NOT NULL OR r->>'contract_profit' IS NOT NULL OR r->>'net_margin' IS NOT NULL),
  t.doc('v-month')->>'totals');
SELECT t.expect('the viewer works in main only: their report is main''s numbers (5 sales, 15900 gross), the check passes without the cost',
  t.doc('v-month')->'totals' @> '{"sales_count":5,"gross":"15900.00","returned_gross":"1200.00"}'::jsonb
  AND (t.doc('v-month')->'check'->>'rows_match')::boolean AND t.doc('v-month')->'check'->'differences'->'cost'='null'::jsonb,
  t.doc('v-month')->>'check');
SELECT t.as_user(t.u('viewer'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('without report.financial a margin sort is refused',
  format('SELECT public.report_sales(DATE %L,DATE %L,%L,p_sort => %L)','2026-09-01','2026-10-31','product','margin_desc'),'VALIDATION_FAILED');
SELECT t.error('a branch the viewer does not work in is BRANCH_DENIED',
  format('SELECT public.report_sales(DATE %L,DATE %L,%L,p_branch_id => %L)','2026-09-01','2026-10-31','month',t.id('second')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('clerk'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('a cashier without report.view is PERMISSION_DENIED',
  format('SELECT public.report_sales(DATE %L,DATE %L,%L)','2026-09-01','2026-10-31','month'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'm-month',t.rep('month');
RESET ROLE;
SELECT t.expect('a branch manager (report.view and report.financial) of both branches sees what the owner sees',
  (t.doc('m-month')->>'can_see_cost')::boolean AND t.doc('m-month')->'totals'=t.doc('month')->'totals');
SELECT t.as_user(NULL);
SET ROLE authenticated;
SELECT t.error('no session is NOT_AN_EMPLOYEE',format('SELECT public.report_sales(DATE %L,DATE %L,%L)','2026-09-01','2026-10-31','month'),'NOT_AN_EMPLOYEE');
RESET ROLE;

-- ================================================================ errors and the other shop
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('another shop''s branch is BRANCH_NOT_FOUND',format('SELECT public.report_sales(DATE %L,DATE %L,%L,p_branch_id => %L)','2026-09-01','2026-10-31','month',t.id('main-b')),'BRANCH_NOT_FOUND');
SELECT t.error('another shop''s employee is EMPLOYEE_NOT_FOUND',format('SELECT public.report_sales(DATE %L,DATE %L,%L,p_employee_id => %L)','2026-09-01','2026-10-31','month',t.id('b-emp')),'EMPLOYEE_NOT_FOUND');
SELECT t.error('another shop''s category is CATEGORY_NOT_FOUND',format('SELECT public.report_sales(DATE %L,DATE %L,%L,p_category_id => %L)','2026-09-01','2026-10-31','month',t.id('b-cat')),'CATEGORY_NOT_FOUND');
SELECT t.error('another shop''s product is PRODUCT_NOT_FOUND',format('SELECT public.report_sales(DATE %L,DATE %L,%L,p_product_id => %L)','2026-09-01','2026-10-31','month',t.id('b-prod')),'PRODUCT_NOT_FOUND');
SELECT t.error('an unknown branch is BRANCH_NOT_FOUND',format('SELECT public.report_sales(DATE %L,DATE %L,%L,p_branch_id => %L)','2026-09-01','2026-10-31','month','00000000-0000-4000-8000-0000000002d2'),'BRANCH_NOT_FOUND');
SELECT t.error('367 days is VALIDATION_FAILED','SELECT public.report_sales(DATE ''2025-10-30'', DATE ''2026-10-31'', ''month'')','VALIDATION_FAILED');
SELECT t.error('from after to is VALIDATION_FAILED','SELECT public.report_sales(DATE ''2026-10-31'', DATE ''2026-09-01'', ''month'')','VALIDATION_FAILED');
SELECT t.error('an unknown grouping is VALIDATION_FAILED','SELECT public.report_sales(DATE ''2026-09-01'', DATE ''2026-10-31'', ''colour'')','VALIDATION_FAILED');
SELECT t.error('an unknown sale type is VALIDATION_FAILED','SELECT public.report_sales(DATE ''2026-09-01'', DATE ''2026-10-31'', ''month'', p_sale_type => ''layaway'')','VALIDATION_FAILED');
SELECT t.error('an unknown sort is VALIDATION_FAILED','SELECT public.report_sales(DATE ''2026-09-01'', DATE ''2026-10-31'', ''month'', p_sort => ''best'')','VALIDATION_FAILED');
SELECT t.error('page size 1001 is VALIDATION_FAILED','SELECT public.report_sales(DATE ''2026-09-01'', DATE ''2026-10-31'', ''month'', p_page_size => 1001)','VALIDATION_FAILED');
SELECT t.error('page 0 is VALIDATION_FAILED','SELECT public.report_sales(DATE ''2026-09-01'', DATE ''2026-10-31'', ''month'', p_page => 0)','VALIDATION_FAILED');
SELECT t.error('payment type cannot be split by product','SELECT public.report_sales(DATE ''2026-09-01'', DATE ''2026-10-31'', ''payment_type'', p_product_id => '''||t.id('chair')||''')','VALIDATION_FAILED');
SELECT t.expect('366 days (the longest period) is allowed',
  (public.report_sales(DATE '2025-10-31', DATE '2026-10-31', 'month')->>'total_count')::int=3);
RESET ROLE;
-- Shop b sees its own 999 sale and none of shop a's.
SELECT t.as_user(t.u('owner-b'),t.org('b'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'b-month',t.rep('month');
RESET ROLE;
SELECT t.expect('shop b''s report holds its own 999 sale only',
  t.doc('b-month')->'totals' @> '{"sales_count":1,"gross":"999.00","return_count":0}'::jsonb AND t.keys(t.doc('b-month'))='2026-09-01',
  t.doc('b-month')::text);
-- An empty period answers zeros, no rows, and a passing check.
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'empty',public.report_sales(DATE '2020-01-01', DATE '2020-01-31', 'product');
RESET ROLE;
SELECT t.expect('an empty period: no rows, zero totals, margin_pct null, the check passes',
  jsonb_array_length(t.doc('empty')->'rows')=0 AND (t.doc('empty')->>'total_count')::int=0
  AND t.doc('empty')->'totals' @> '{"sales_count":0,"revenue":"0.00","margin_pct":null,"return_count":0}'::jsonb
  AND (t.doc('empty')->'check'->>'rows_match')::boolean, t.doc('empty')::text);

-- ================================================================ the read works in an expired shop
UPDATE public.organizations SET subscription_start=NULL,subscription_end=t.today()-5 WHERE id=t.org('a');
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'expired',t.rep('month');
RESET ROLE;
SELECT t.expect('an expired shop still reads its report', t.doc('expired')->'totals'=t.doc('month')->'totals', t.doc('expired')::text);

-- ================================================================ grants and definitions
SELECT t.expect('grants: the read to authenticated only, nothing for anon or for the app. helpers',
  has_function_privilege('authenticated','public.report_sales(date,date,text,uuid,uuid,uuid,uuid,text,text,integer,integer,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.report_sales(date,date,text,uuid,uuid,uuid,uuid,text,text,integer,integer,text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.report_money(numeric)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.report_measures(boolean,bigint,bigint,numeric,numeric,numeric,numeric,numeric,numeric,bigint,bigint,numeric,numeric,numeric,numeric,numeric,numeric,numeric)','EXECUTE'));
SELECT t.expect('definer: the read is SECURITY DEFINER and every report function has an empty search_path',
  (SELECT count(*)=3 AND bool_and(p.proconfig @> ARRAY['search_path=""']) AND bool_and(p.prosecdef) FILTER (WHERE p.proname='report_sales')
   FROM pg_proc p WHERE p.proname IN ('report_sales','report_money','report_measures')
     AND p.pronamespace IN ('app'::regnamespace,'public'::regnamespace)));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
