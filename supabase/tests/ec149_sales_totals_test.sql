-- EC-149 / BUG-2: one sales rule across the dashboard, the shift, the day close and the sales report (D94).
-- Run by: node scripts/db-smoke.mjs supabase/tests/ec149_sales_totals_test.sql (inside BEGIN ... ROLLBACK).
-- One day in the main branch over two shifts: a cash sale, a split sale, an installment sale, a counter
-- collection, two voided sales (one cash, one split), a partial return and an exchange. The day close,
-- the two shifts, the owner dashboard and the D02 report give the same sales count, total, VAT and money
-- by method; voids are out of all of it and keep their own line; returns keep theirs, with their VAT.
-- Edge cases: a void after a return or after the shift closed is refused; a return on a later day than
-- its sale; an S10 order deposit; the day list of a closed day; a day closed before the rule (with and
-- without a void).
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request (copied from k04_day_close_test.sql).
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
CREATE FUNCTION t.lines(VARIADIC l jsonb[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(l) $$;
CREATE FUNCTION t.items(p text,q integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('product_id',t.id(p),'quantity',q) $$;
CREATE FUNCTION t.pcash(amount text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('method','cash','amount',amount) $$;
CREATE FUNCTION t.pbank(amount text,acct text,ref text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('method','bank_transfer','amount',amount,'cash_account_id',t.id(acct),'reference',ref) $$;
CREATE FUNCTION t.sale_id(tag text) RETURNS uuid LANGUAGE sql AS $$ SELECT (t.doc(tag)->>'id')::uuid $$;
CREATE FUNCTION t.line_of(sale text,p text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.sale_lines WHERE sale_id=t.sale_id(sale) AND product_id=t.id(p) ORDER BY line_no LIMIT 1 $$;
CREATE FUNCTION t.ret(sale text,p text,refunds jsonb,expected text,p_key text,extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; BEGIN
  r := public.post_sales_return(jsonb_build_object('sale_id',t.sale_id(sale),
         'lines',jsonb_build_array(jsonb_build_object('sale_line_id',t.line_of(sale,p),'quantity',1,'condition','resellable')),
         'refunds',refunds,'expected_total',expected,'reason','Customer changed his mind') || extra,p_key);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN r;
END $$;
-- A shift closed with exactly its expected cash, counted as one-pound coins.
CREATE FUNCTION t.close_shift(p_shift uuid,p_vault uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_exp integer := (public.get_shift(p_shift)->>'expected_cash')::numeric::integer;
BEGIN RETURN public.close_shift(p_shift,jsonb_build_object('1',v_exp),p_vault,NULL); END $$;
-- What the tables say for a branch and day: the sales not voided, their tax and their money by method.
CREATE FUNCTION t.counted(p_branch text,d date) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  WITH s AS (SELECT x.* FROM public.sales x WHERE x.organization_id=t.org('a') AND x.branch_id=t.id(p_branch) AND x.business_date=d
               AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=x.id AND r.kind='void'))
  SELECT jsonb_build_object('count',(SELECT count(*) FROM s),'total',(SELECT COALESCE(sum(total),0) FROM s),
    'tax',(SELECT COALESCE(sum(tax_total),0) FROM s),
    'all_tax',(SELECT COALESCE(sum(x.tax_total),0) FROM public.sales x WHERE x.organization_id=t.org('a') AND x.branch_id=t.id(p_branch) AND x.business_date=d),
    'cash',(SELECT COALESCE(sum(a.amount),0) FROM s JOIN public.payment_allocations a ON a.sale_id=s.id
            JOIN public.payments p ON p.id=a.payment_id AND p.direction='in' AND p.method='cash'),
    'bank',(SELECT COALESCE(sum(a.amount),0) FROM s JOIN public.payment_allocations a ON a.sale_id=s.id
            JOIN public.payments p ON p.id=a.payment_id AND p.direction='in' AND p.method='bank_transfer')) $$;
CREATE FUNCTION t.n(j jsonb,VARIADIC p text[]) RETURNS numeric LANGUAGE sql AS $$ SELECT (j#>>p)::numeric $$;
-- A D02 payment-type row by key.
CREATE FUNCTION t.prow(j jsonb,k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT x FROM jsonb_array_elements(j->'rows') x WHERE x->>'key'=k $$;
-- A stored snapshot as the rule before EC-149 wrote it: no returns VAT and no shift takings, the shift's
-- payment totals being every incoming payment of the shift, and (p_with_voids) the voided sales counted.
CREATE FUNCTION t.old_snapshot(p_totals jsonb,p_with_voids boolean) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_set(jsonb_set(p_totals,'{returns}',(p_totals->'returns')-'tax_total'),'{shifts,items}',
           COALESCE((SELECT jsonb_agg((i-ARRAY['sales_count','sales_total','tax_total','collections','deposits'])
                       || jsonb_build_object('payment_totals',(SELECT jsonb_build_object(
                            'cash',app.dc_money(sum(p.amount) FILTER (WHERE p.method='cash')),
                            'bank_transfer',app.dc_money(sum(p.amount) FILTER (WHERE p.method='bank_transfer')),
                            'store_credit',app.dc_money(sum(p.amount) FILTER (WHERE p.method='store_credit')))
                          FROM public.payments p WHERE p.shift_id=(i->>'id')::uuid AND p.direction='in')) ORDER BY n)
                     FROM jsonb_array_elements(p_totals#>'{shifts,items}') WITH ORDINALITY x(i,n)),'[]'::jsonb))
         || CASE WHEN p_with_voids THEN jsonb_build_object('sales',(p_totals->'sales')
              || jsonb_build_object('count',(p_totals#>>'{sales,count}')::int+(p_totals#>>'{sales,voided,count}')::int,
                                    'total',app.dc_money((p_totals#>>'{sales,total}')::numeric+(p_totals#>>'{sales,voided,total}')::numeric)))
            ELSE '{}'::jsonb END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a, branches main and second
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT 'a',public.admin_provision_organization('EC149 a','ec149-key-a','retail_pro','Owner','aec149@example.com',NULL,'Main',repeat('q',64),now()+interval '1 day');
INSERT INTO auth.users(id,email) VALUES('a1490000-0000-0000-8000-000000000001','aec149@example.com');
SELECT public.accept_invite(repeat('q',64),'a1490000-0000-0000-8000-000000000001');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0 WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id=t.org('a');
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids SELECT 'cib',(public.create_cash_account('CIB','bank',t.id('main'))->>'id')::uuid;
INSERT INTO t.ids SELECT p,public.create_product(jsonb_build_object('name_ar',p,'name_en',p,'sku','EC149-'||p,'cash_price',price))
  FROM (VALUES('lamp','1850'),('chair','350'),('sofa','42750'),('tv','25000'),('radio','2200'),('kettle','1000'),('cup','500'),('fan','1000')) v(p,price);
SELECT public.post_stock_adjustment(b,'found',NULL,(SELECT jsonb_agg(jsonb_build_object('product_id',id,'quantity',20)) FROM t.ids
         WHERE tag IN ('lamp','chair','sofa','tv','radio','kettle','cup','fan')),'ec149-key-found-'||b)
  FROM unnest(ARRAY[t.id('main'),t.id('second')]) b;
RESET ROLE;
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id,city,address)
  VALUES(t.org('a'),'EC149 Customer',ARRAY['01055550149'],500000,'active','29101010100149','Cairo','5 B Street');
INSERT INTO t.ids SELECT 'c1',id FROM public.customers WHERE organization_id=t.org('a') AND full_name='EC149 Customer';
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'percent_of_future_profit',50,
         1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');

-- ---------------------------------------------------------------- shift 1 in main (the 22 Oct day, and more)
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.post_cash_opening(t.id('safe'),'5000.00','Opening','ec149-key-opening');
INSERT INTO t.docs SELECT 'sh1',t.open_shift(t.id('main'),'100.00','ec149-key-sh1');
RESET ROLE;
INSERT INTO t.ids SELECT 'sh1',(t.doc('sh1')->>'id')::uuid;
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's1',public.post_sale(t.lines(t.items('lamp',1),t.items('chair',1)),'2200.00','ec149-key-s1',NULL,t.lines(t.pcash('2200.00')));
INSERT INTO t.docs SELECT 's2',public.post_sale(t.lines(t.items('sofa',1)),'42750.00','ec149-key-s2',NULL,t.lines(t.pcash('20000.00'),t.pbank('22750.00','cib','TRX-149')));
INSERT INTO t.docs SELECT 'inst',public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),
    'expected_total','25000.00','customer_id',t.id('c1'),
    'terms',jsonb_build_object('down_payment','5000.00','installments_count',12,'frequency','monthly','policy_version',t.pv())),'ec149-key-inst');
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO t.docs SELECT 'col',public.post_collection(jsonb_build_object('customer_id',t.id('c1'),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',(t.doc('inst')->'contract'->>'id')::uuid,'amount','2200.00')),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','2200.00'))),'ec149-key-col');
INSERT INTO t.docs SELECT 's4',public.post_sale(t.lines(t.items('radio',1)),'2200.00','ec149-key-s4',NULL,t.lines(t.pcash('2200.00')));
INSERT INTO t.docs SELECT 's5',public.post_sale(t.lines(t.items('kettle',1)),'1000.00','ec149-key-s5',NULL,t.lines(t.pcash('500.00'),t.pbank('500.00','cib','TRX-150')));
INSERT INTO t.docs SELECT 'v4',public.void_sale(t.sale_id('s4'),'Customer changed mind','ec149-key-v4');
INSERT INTO t.docs SELECT 'v5',public.void_sale(t.sale_id('s5'),'Wrong item rung up','ec149-key-v5');
-- The return of 350 (the chair of s1, cash), then a void of s1 is refused.
INSERT INTO t.docs SELECT 'r1',t.ret('s1','chair',jsonb_build_array(t.pcash('350.00')),'350.00','ec149-key-r1');
SELECT t.error('edge: a void after a partial return is VOID_HAS_RETURNS',
  format('SELECT public.void_sale(%L,%L,%L)',t.sale_id('s1'),'Too late','ec149-key-v1'),'VOID_HAS_RETURNS');
-- An exchange: the cup (500) for a kettle (1000), 500 more in cash.
INSERT INTO t.docs SELECT 'sx',public.post_sale(t.lines(t.items('cup',1)),'500.00','ec149-key-sx',NULL,t.lines(t.pcash('500.00')));
INSERT INTO t.docs SELECT 'x1',t.ret('sx','cup','[]','500.00','ec149-key-x1',
  jsonb_build_object('kind','exchange','new_sale',jsonb_build_object('lines',jsonb_build_array(t.items('kettle',1)),
    'expected_total','1000.00','payments',jsonb_build_array(t.pcash('500.00')))));
INSERT INTO t.docs SELECT 'sh1-closed',t.close_shift(t.id('sh1'),t.id('safe'));
RESET ROLE;
INSERT INTO t.ids SELECT 'x1sale',(t.doc('x1')->'exchange_sale'->>'id')::uuid;
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.error('edge: a void once the shift is closed is VOID_SHIFT_CLOSED',
  format('SELECT public.void_sale(%L,%L,%L)',t.id('x1sale'),'Too late','ec149-key-vx'),'VOID_SHIFT_CLOSED');
-- Shift 2 in main: one more cash sale.
INSERT INTO t.docs SELECT 'sh2',t.open_shift(t.id('main'),'100.00','ec149-key-sh2');
RESET ROLE;
INSERT INTO t.ids SELECT 'sh2',(t.doc('sh2')->>'id')::uuid;
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's6',public.post_sale(t.lines(t.items('fan',1)),'1000.00','ec149-key-s6',NULL,t.lines(t.pcash('1000.00')));
-- An S10 order with a 1000 cash deposit on shift 2: not a sale until it is delivered.
INSERT INTO t.docs SELECT 'ord',public.create_sales_order(t.id('main'),t.id('c1'),'5 B Street',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('sofa'),'quantity',1,'unit_price','42750','fulfilment','to_order')),'ec149-key-ord');
INSERT INTO t.docs SELECT 'dep',public.record_order_deposit((t.doc('ord')->>'id')::uuid,jsonb_build_array(t.pcash('1000.00')),'ec149-key-dep');
INSERT INTO t.docs SELECT 'sh2-closed',t.close_shift(t.id('sh2'),t.id('safe'));
-- The reads.
INSERT INTO t.docs SELECT 'p',public.get_day_close_preview(t.id('main'),t.today());
INSERT INTO t.docs SELECT 'dash',public.get_owner_dashboard(t.id('main'));
INSERT INTO t.docs SELECT 'g1',public.get_shift(t.id('sh1'));
INSERT INTO t.docs SELECT 'g2',public.get_shift(t.id('sh2'));
INSERT INTO t.docs SELECT 'rep',public.report_sales(t.today(),t.today(),'day',t.id('main'));
INSERT INTO t.docs SELECT 'rpay',public.report_sales(t.today(),t.today(),'payment_type',t.id('main'));
RESET ROLE;
INSERT INTO t.docs SELECT 'tab',t.counted('main',t.today());

-- ================================================================ the same numbers everywhere
-- Counted: s1 2200, s2 42750, inst 25000, sx 500, the exchange's kettle 1000, s6 1000 = 6 sales, 72450.
-- Voided: s4 2200 (cash) and s5 1000 (500 cash + 500 bank). Returns: the chair 350 and the exchanged cup 500.
SELECT t.expect('sales count: day close = dashboard = D02 = shift 1 + shift 2 = the tables = 6 (voids out)',
  t.n(t.doc('p'),'totals','sales','count')=6
  AND t.n(t.doc('dash'),'tiles','sales_today','count')=6
  AND t.n(t.doc('rep'),'totals','sales_count')=6
  AND t.n(t.doc('g1'),'sales_count')+t.n(t.doc('g2'),'sales_count')=6
  AND t.n(t.doc('tab'),'count')=6,
  concat_ws(' / ',t.doc('p')#>>'{totals,sales}',t.doc('dash')#>>'{tiles,sales_today}',t.doc('rep')->>'totals'));
SELECT t.expect('sales total: day close = dashboard = D02 gross = shift 1 + shift 2 = 72450 (returns not netted)',
  t.n(t.doc('p'),'totals','sales','total')=72450
  AND t.n(t.doc('dash'),'tiles','sales_today','total')=72450
  AND t.n(t.doc('rep'),'totals','gross')=72450
  AND t.n(t.doc('g1'),'sales_total')+t.n(t.doc('g2'),'sales_total')=72450
  AND t.n(t.doc('tab'),'total')=72450,
  concat_ws(' / ',t.doc('p')#>>'{totals,sales,total}',t.doc('g1')->>'sales_total',t.doc('g2')->>'sales_total'));
SELECT t.expect('VAT: day close = D02 = shift 1 + shift 2 = the counted sales'' VAT; the voided sales'' VAT is not in it',
  t.n(t.doc('p'),'totals','sales','tax_total')=t.n(t.doc('tab'),'tax')
  AND t.n(t.doc('rep'),'totals','tax')=t.n(t.doc('tab'),'tax')
  AND t.n(t.doc('g1'),'tax_total')+t.n(t.doc('g2'),'tax_total')=t.n(t.doc('tab'),'tax')
  AND t.n(t.doc('tab'),'all_tax')-t.n(t.doc('tab'),'tax')=(SELECT sum(r.tax_total) FROM public.sales_returns r
        WHERE r.organization_id=t.org('a') AND r.kind='void' AND r.business_date=t.today())
  AND t.n(t.doc('tab'),'all_tax')>t.n(t.doc('tab'),'tax'),
  concat_ws(' / ',t.doc('p')#>>'{totals,sales,tax_total}',t.doc('rep')#>>'{totals,tax}',t.doc('tab')::text));
SELECT t.expect('cash taken from sales: day close = dashboard = D02 = shift 1 + shift 2 = 29700 (the installment''s 5000 down only; no void, no collection)',
  t.n(t.doc('p'),'totals','sales','paid_by_method','cash')=29700
  AND t.n(t.doc('dash'),'tiles','sales_today','paid_by_method','cash')=29700
  AND t.n(t.prow(t.doc('rpay'),'cash'),'amount')=29700
  AND t.n(t.doc('g1'),'payment_totals','cash')+t.n(t.doc('g2'),'payment_totals','cash')=29700
  AND t.n(t.doc('tab'),'cash')=29700,
  concat_ws(' / ',t.doc('p')#>>'{totals,sales,paid_by_method}',t.doc('g1')->>'payment_totals',t.doc('g2')->>'payment_totals'));
SELECT t.expect('bank and on contract: the same everywhere (bank 22750 without the voided 500; on contract 20000)',
  t.n(t.doc('p'),'totals','sales','paid_by_method','bank_transfer')=22750
  AND t.n(t.doc('dash'),'tiles','sales_today','paid_by_method','bank_transfer')=22750
  AND t.n(t.prow(t.doc('rpay'),'bank_transfer'),'amount')=22750
  AND t.n(t.doc('g1'),'payment_totals','bank_transfer')+t.n(t.doc('g2'),'payment_totals','bank_transfer')=22750
  AND t.n(t.doc('tab'),'bank')=22750
  AND t.n(t.doc('p'),'totals','sales','on_contract')=20000
  AND t.n(t.doc('dash'),'tiles','sales_today','on_contract')=20000
  AND t.n(t.prow(t.doc('rpay'),'on_contract'),'amount')=20000,
  t.doc('p')#>>'{totals,sales}');
SELECT t.expect('voided line: the day close still shows the 2 voids (3200), one of them split cash + bank',
  t.n(t.doc('p'),'totals','sales','voided','count')=2 AND t.n(t.doc('p'),'totals','sales','voided','total')=3200,
  t.doc('p')#>>'{totals,sales,voided}');
SELECT t.expect('returns: their own line on the day close (2: the chair and the exchanged cup, 850 cash) with their VAT = D02''s returned tax',
  t.n(t.doc('p'),'totals','returns','count')=2 AND t.n(t.doc('p'),'totals','returns','total')=850
  AND t.n(t.doc('p'),'totals','returns','refunded_by_method','cash')=850
  AND t.n(t.doc('p'),'totals','returns','tax_total')=t.n(t.doc('rep'),'totals','returned_tax')
  AND t.n(t.doc('p'),'totals','returns','tax_total')=(SELECT sum(r.tax_total) FROM public.sales_returns r
        WHERE r.organization_id=t.org('a') AND r.kind<>'void' AND r.branch_id=t.id('main') AND r.business_date=t.today())
  AND t.n(t.doc('rep'),'totals','return_count')=2,
  t.doc('p')#>>'{totals,returns}');
SELECT t.expect('collections: the counter 2200 is its own figure on shift 1 and on the day close, not in the cash from sales',
  t.n(t.doc('g1'),'collections','cash')=2200 AND t.n(t.doc('g2'),'collections','cash')=0
  AND t.n(t.doc('p'),'totals','collections','total')=2200
  AND t.n(t.doc('g1'),'payment_totals','cash')=28700,
  t.doc('g1')::text);
SELECT t.expect('deposits: the order deposit is its own figure on shift 2, not in its cash from sales nor in the day''s sales',
  t.n(t.doc('g2'),'deposits','cash')=1000 AND t.n(t.doc('g2'),'payment_totals','cash')=1000
  AND t.n(t.doc('g1'),'deposits','cash')=0 AND t.n(t.doc('p'),'totals','sales','count')=6
  AND t.n(t.doc('g2'),'expected_cash')=2100,
  t.doc('g2')::text);
SELECT t.expect('shift rows of the day close = the shift summaries (same takings for each shift)',
  (SELECT bool_and(i->'payment_totals'=g->'payment_totals' AND i->'collections'=g->'collections' AND i->'deposits'=g->'deposits'
                   AND i->>'sales_total'=g->>'sales_total' AND i->>'tax_total'=g->>'tax_total' AND i->'sales_count'=g->'sales_count')
   FROM jsonb_array_elements(t.doc('p')#>'{totals,shifts,items}') i
   JOIN (VALUES(t.doc('g1')),(t.doc('g2'))) v(g) ON g->>'id'=i->>'id')
  AND jsonb_array_length(t.doc('p')#>'{totals,shifts,items}')=2,
  t.doc('p')#>>'{totals,shifts}');
SELECT t.expect('drawer: each shift''s expected cash is still its drawer ledger (shift 1: the 100 float + its sales, collection, voids and returns = 30150)',
  t.n(t.doc('g1'),'expected_cash')=100+(SELECT sum(m.amount) FROM public.cash_movements m
                                    WHERE m.shift_id=t.id('sh1') AND m.cash_account_id=(t.doc('g1')->>'drawer_account_id')::uuid
                                      AND m.source_type<>'cash_transfer')
  AND t.n(t.doc('g1'),'expected_cash')=30150,
  t.doc('g1')->>'expected_cash');

-- ================================================================ a return on a later day than its sale (second branch)
-- b1 1000 and b2 500 in cash today; b2 is moved to yesterday (as if sold then), then returned today.
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT public.post_cash_opening(t.id('safe2'),'1000.00','Opening','ec149-key-opening2');
INSERT INTO t.docs SELECT 'shb',t.open_shift(t.id('second'),'100.00','ec149-key-shb');
RESET ROLE;
INSERT INTO t.ids SELECT 'shb',(t.doc('shb')->>'id')::uuid;
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'b1',public.post_sale(t.lines(t.items('kettle',1)),'1000.00','ec149-key-b1',NULL,t.lines(t.pcash('1000.00')));
INSERT INTO t.docs SELECT 'b2',public.post_sale(t.lines(t.items('cup',1)),'500.00','ec149-key-b2',NULL,t.lines(t.pcash('500.00')));
RESET ROLE;
SET session_replication_role = replica;
UPDATE public.sales SET business_date=t.today()-1 WHERE id=t.sale_id('b2');
SET session_replication_role = origin;
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'rb2',t.ret('b2','cup',jsonb_build_array(t.pcash('500.00')),'500.00','ec149-key-rb2');
INSERT INTO t.docs SELECT 'pb-today',public.get_day_close_preview(t.id('second'),t.today());
INSERT INTO t.docs SELECT 'pb-yday',public.get_day_close_preview(t.id('second'),t.today()-1);
INSERT INTO t.docs SELECT 'shb-closed',t.close_shift(t.id('shb'),t.id('safe2'));
RESET ROLE;
SELECT t.expect('edge: a return on a later day is on the return''s day only; the sale stays on its own day',
  t.n(t.doc('pb-today'),'totals','sales','count')=1 AND t.n(t.doc('pb-today'),'totals','sales','total')=1000
  AND t.n(t.doc('pb-today'),'totals','returns','count')=1 AND t.n(t.doc('pb-today'),'totals','returns','total')=500
  AND t.n(t.doc('pb-yday'),'totals','sales','count')=1 AND t.n(t.doc('pb-yday'),'totals','sales','total')=500
  AND t.n(t.doc('pb-yday'),'totals','returns','count')=0,
  concat_ws(' / ',t.doc('pb-today')#>>'{totals,sales}',t.doc('pb-yday')#>>'{totals,sales}'));

-- ================================================================ closed days
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'p-main',public.get_day_close_preview(t.id('main'),t.today());
INSERT INTO t.docs SELECT 'dc-main',public.close_day(t.id('main'),t.today(),t.doc('p-main')->>'hash','EC-149 test close');
INSERT INTO t.docs SELECT 'p-second',public.get_day_close_preview(t.id('second'),t.today());
INSERT INTO t.docs SELECT 'dc-second',public.close_day(t.id('second'),t.today(),t.doc('p-second')->>'hash','EC-149 test close');
INSERT INTO t.docs SELECT 'list',public.list_day_closes(NULL,t.today(),t.today());
INSERT INTO t.docs SELECT 'get-main',public.get_day_close((t.doc('dc-main')->>'id')::uuid);
SELECT t.error('edge: a void on a closed day is refused (its shift is closed)',
  format('SELECT public.void_sale(%L,%L,%L)',t.sale_id('s6'),'After the close','ec149-key-v6'),'VOID_SHIFT_CLOSED');
RESET ROLE;
INSERT INTO t.ids SELECT 'dc-main',(t.doc('dc-main')->>'id')::uuid;
INSERT INTO t.ids SELECT 'dc-second',(t.doc('dc-second')->>'id')::uuid;
CREATE FUNCTION t.list_row(l text,b text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(t.doc(l)->'items') x WHERE x->>'branch_id'=t.id(b)::text $$;
SELECT t.expect('closed day: the snapshot holds the rule''s numbers; the list shows the stored total; no drift',
  t.doc('dc-main')#>'{totals,sales}'=t.doc('p')#>'{totals,sales}'
  AND t.list_row('list','main')->>'status'='closed'
  AND t.list_row('list','main')->>'sales_total'=t.doc('dc-main')#>>'{totals,sales,total}'
  AND t.list_row('list','main')->>'sales_total'='72450.00'
  AND NOT (t.doc('get-main')->>'drift')::boolean,
  concat_ws(' / ',t.list_row('list','main')::text,t.doc('get-main')->>'drift'));

-- A day closed before the rule: the stored snapshot as the old rule wrote it (main: voids counted;
-- second: no void). The issued snapshot is replaced here only to stand for an older one.
SET session_replication_role = replica;
UPDATE public.day_closes SET totals=t.old_snapshot(totals,true) WHERE id=t.id('dc-main');
UPDATE public.day_closes SET totals=t.old_snapshot(totals,false) WHERE id=t.id('dc-second');
SET session_replication_role = origin;
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'old-main',public.get_day_close(t.id('dc-main'));
INSERT INTO t.docs SELECT 'old-second',public.get_day_close(t.id('dc-second'));
INSERT INTO t.docs SELECT 'old-list',public.list_day_closes(NULL,t.today(),t.today());
RESET ROLE;
SELECT t.expect('edge: a day closed before the rule with a void shows drift; the list shows its stored (old) total',
  (t.doc('old-main')->>'drift')::boolean AND t.doc('old-main')#>>'{totals,sales,total}'='75650.00'
  AND t.list_row('old-list','main')->>'sales_total'='75650.00',
  concat_ws(' / ',t.doc('old-main')->>'drift',t.list_row('old-list','main')::text));
SELECT t.expect('edge: a day closed before the rule without a void (no returns VAT, old shift takings) shows no drift',
  NOT (t.doc('old-second')->>'drift')::boolean AND NOT (t.doc('old-second')#>'{totals,returns}' ? 'tax_total')
  AND NOT (t.doc('old-second')#>'{totals,shifts,items,0}' ? 'sales_count'),
  t.doc('old-second')::text);
-- The owner reopens the old day and closes it again: a new snapshot by the rule, no drift.
SELECT t.as_user('a1490000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'reopen',public.reopen_day(t.id('dc-main'),'Recompute under the EC-149 rule');
INSERT INTO t.docs SELECT 'reopen-list',public.list_day_closes(t.id('main'),t.today(),t.today());
INSERT INTO t.docs SELECT 'p-again',public.get_day_close_preview(t.id('main'),t.today());
INSERT INTO t.docs SELECT 'dc-again',public.close_day(t.id('main'),t.today(),t.doc('p-again')->>'hash','EC-149 test reclose');
INSERT INTO t.docs SELECT 'get-again',public.get_day_close(t.id('dc-main'));
RESET ROLE;
SELECT t.expect('edge: reopened, the list shows the live counted total; closed again, the snapshot is the rule''s and there is no drift',
  t.doc('reopen-list')#>>'{items,0,status}'='reopened' AND t.doc('reopen-list')#>>'{items,0,sales_total}'='72450.00'
  AND t.doc('get-again')#>>'{totals,sales,total}'='72450.00' AND NOT (t.doc('get-again')->>'drift')::boolean,
  concat_ws(' / ',t.doc('reopen-list')::text,t.doc('get-again')->>'drift'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
