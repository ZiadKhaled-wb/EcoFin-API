-- D01 owner dashboard (EC-93, D87).
-- Run by: node scripts/db-smoke.mjs supabase/tests/d01_owner_dashboard_test.sql (inside BEGIN ... ROLLBACK).
-- Every tile of get_owner_dashboard equals the detail function it links to, called with the same
-- filters: for all branches and for each branch. Shop a has three branches (main, second, third), shop b
-- has documents of its own that never count. Details are read through the public functions as the
-- same user (search_sales, K04's preview, list_cash_accounts, list_shifts, list_collector_wallets,
-- list_overdue_contracts, low_stock_summary, fiscal_alert_summary, day_close_alerts, the approval lists).
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
-- The active branches the caller can see (what a dashboard for "all branches" covers).
CREATE FUNCTION t.vis() RETURNS uuid[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(array_agg(b.id),ARRAY[]::uuid[]) FROM public.branches b
  WHERE b.organization_id=app.current_org_id() AND b.is_active AND app.has_branch_access(b.id) $$;
CREATE FUNCTION t.tz() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT timezone FROM public.organizations WHERE id=t.org('a') $$;
CREATE FUNCTION t.money(n numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(n,0)::numeric(18,2)::text $$;
-- Independent table reads for the numbers no list gives (paid by method, on contract) of today's sales
-- without the voided ones; b NULL = every branch of shop a.
CREATE FUNCTION t.paid(b uuid) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'cash',t.money(sum(a.amount) FILTER (WHERE p.method='cash')),
    'bank_transfer',t.money(sum(a.amount) FILTER (WHERE p.method='bank_transfer')),
    'store_credit',t.money(sum(a.amount) FILTER (WHERE p.method='store_credit')))
  FROM public.sales s
  JOIN public.payment_allocations a ON a.sale_id=s.id
  JOIN public.payments p ON p.id=a.payment_id AND p.direction='in'
  WHERE s.organization_id=t.org('a') AND s.business_date=t.today() AND (b IS NULL OR s.branch_id=b)
    AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id AND r.kind='void') $$;
CREATE FUNCTION t.on_contract(b uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT t.money(sum(c.financed_amount)) FROM public.contracts c JOIN public.sales s ON s.id=c.sale_id
  WHERE s.organization_id=t.org('a') AND s.business_date=t.today() AND (b IS NULL OR s.branch_id=b)
    AND NOT EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.sale_id=s.id AND r.kind='void') $$;
-- The fiscal_alert_summary of T03 as it was before D01 (copied), for the caller's branches.
CREATE FUNCTION t.old_fiscal() RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
               'blocked', count(*) FILTER (WHERE x.situation = 'blocked'),
               'send_failed', count(*) FILTER (WHERE x.situation = 'send_failed'),
               'rejected', count(*) FILTER (WHERE x.situation = 'rejected'),
               'due_soon', count(*) FILTER (WHERE x.state = 'due_soon'),
               'overdue', count(*) FILTER (WHERE x.state = 'overdue'),
               'accepted_today', count(*) FILTER (WHERE x.status = 'accepted' AND x.accepted_date = x.today))
    FROM (
        SELECT f.status, app.fiscal_situation(f.status, f.eta_uuid, f.last_error) AS situation,
               app.fiscal_deadline_state(app.fiscal_deadline_at(f.status,
                   COALESCE(s.issued_at, r.created_at, f.created_at), f.reference_old_uuid)) AS state,
               (f.accepted_at AT TIME ZONE o.timezone)::date AS accepted_date,
               (now() AT TIME ZONE o.timezone)::date AS today
        FROM public.fiscal_submissions f
        JOIN public.organizations o ON o.id = f.organization_id
        LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        LEFT JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
        WHERE f.organization_id = app.current_org_id() AND app.has_branch_access(f.branch_id)
    ) x $$;
CREATE FUNCTION t.fiscal_branch(b uuid) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT app.fiscal_alert_counts(t.org('a'),ARRAY[b]) $$;

-- What every tile must be, from the detail functions called with the same branch (b NULL = all), as the
-- current user. Returns the tiles object in the dashboard's shape.
CREATE FUNCTION t.expected(b uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  br uuid[] := CASE WHEN b IS NULL THEN t.vis() ELSE ARRAY[b] END; x uuid; j jsonb; tz text := t.tz();
  s_count bigint; s_total numeric; c_count bigint := 0; c_total numeric := 0; c_field numeric := 0;
  safes numeric; banks numeric; drawers numeric; wallets numeric; sh jsonb; flt jsonb;
  ov jsonb; low jsonb; fs jsonb; al jsonb; disc int; purch int; cred int; early bigint;
BEGIN
  SELECT count(*), COALESCE(sum(total::numeric),0) INTO s_count, s_total
    FROM public.search_sales(NULL,b,NULL,NULL,t.today(),t.today(),NULL,100,0) WHERE status<>'voided';
  FOREACH x IN ARRAY br LOOP
    j := public.get_day_close_preview(x,t.today()) -> 'totals' -> 'collections';
    c_count := c_count + (j->>'count')::bigint; c_total := c_total + (j->>'total')::numeric;
    c_field := c_field + (j->>'in_field')::numeric;
  END LOOP;
  SELECT COALESCE(sum((a->>'balance')::numeric) FILTER (WHERE a->>'kind'='safe'),0),
         COALESCE(sum((a->>'balance')::numeric) FILTER (WHERE a->>'kind'='bank'),0)
    INTO safes, banks FROM jsonb_array_elements(public.list_cash_accounts('active',b)) a;
  sh := public.list_shifts(b,NULL,'open',NULL,NULL,100,0);
  SELECT COALESCE(sum((i->>'expected_cash')::numeric),0), count(*) FILTER (WHERE ((i->>'opened_at')::timestamptz AT TIME ZONE tz)::date < t.today())
    INTO drawers, early FROM jsonb_array_elements(sh->'items') i;
  flt := CASE WHEN b IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('branch_id',b) END;
  SELECT COALESCE(sum((w->>'balance')::numeric),0) INTO wallets FROM jsonb_array_elements(public.list_collector_wallets(flt)->'items') w;
  ov := public.list_overdue_contracts(flt || '{"limit":100}');
  low := public.low_stock_summary(5);
  fs := CASE WHEN b IS NULL THEN public.fiscal_alert_summary() ELSE t.fiscal_branch(b) END;
  al := public.day_close_alerts();
  SELECT count(*) INTO disc FROM jsonb_array_elements(public.list_discount_approvals('pending')->'items');
  SELECT (public.list_purchase_approvals('pending',b,1,0)->>'total')::int INTO purch;
  SELECT count(*) INTO cred FROM jsonb_array_elements(public.list_credit_exceptions('pending')->'items');
  RETURN jsonb_build_object(
    'sales_today',jsonb_build_object('count',s_count,'total',t.money(s_total),'paid_by_method',t.paid(b),'on_contract',t.on_contract(b)),
    'collections_today',jsonb_build_object('count',c_count,'total',t.money(c_total),'in_field',t.money(c_field)),
    'cash',jsonb_build_object('safes',t.money(safes),'banks',t.money(banks),'drawers',t.money(drawers),'wallets',t.money(wallets),
                              'total_in_branches',t.money(safes+drawers+wallets)),
    'open_shifts',jsonb_build_object('count',(sh->>'total')::bigint,
        'oldest_opened_at',(SELECT min((i->>'opened_at')::timestamptz) FROM jsonb_array_elements(sh->'items') i),
        'from_earlier_days',early),
    'overdue',jsonb_build_object('contracts',(ov->'totals'->>'contracts')::bigint,'amount',ov->'totals'->>'overdue_amount',
        'customers',(SELECT count(DISTINCT i->'customer'->>'id') FROM jsonb_array_elements(ov->'items') i)),
    'low_stock',jsonb_build_object('products',CASE WHEN b IS NULL THEN (low->>'total')::bigint
        ELSE (SELECT (z->>'low')::bigint FROM jsonb_array_elements(low->'branches') z WHERE z->>'branch_id'=b::text) END),
    'eta',jsonb_build_object('needs_action',(fs->>'blocked')::bigint+(fs->>'send_failed')::bigint+(fs->>'rejected')::bigint+(fs->>'due_soon')::bigint+(fs->>'overdue')::bigint,
        'blocked',(fs->>'blocked')::bigint,'send_failed',(fs->>'send_failed')::bigint,'rejected',(fs->>'rejected')::bigint,
        'due_soon',(fs->>'due_soon')::bigint,'overdue',(fs->>'overdue')::bigint),
    'unclosed_days',jsonb_build_object(
        'days',(SELECT COALESCE(sum(jsonb_array_length(z->'unclosed_days')),0) FROM jsonb_array_elements(al->'branches') z WHERE (z->>'branch_id')::uuid=ANY(br)),
        'branches',(SELECT count(*) FROM jsonb_array_elements(al->'branches') z WHERE (z->>'branch_id')::uuid=ANY(br) AND jsonb_array_length(z->'unclosed_days')>0)),
    'approvals',jsonb_build_object('discount',disc,'purchase',purch,'credit',cred,'total',disc+purch+cred));
END $$;
-- The tile names.
CREATE FUNCTION t.tiles() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['sales_today','collections_today','cash','open_shifts','overdue','low_stock','eta','unclosed_days','approvals'] $$;
-- Every tile of a dashboard document equals the expected one; the names that differ come back.
CREATE FUNCTION t.diff(d jsonb,e jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(k||': '||COALESCE(d->'tiles'->k,'null'::jsonb)::text||' <> '||COALESCE(e->k,'null'::jsonb)::text,E'\n'),'')
  FROM unnest(t.tiles()) k WHERE d->'tiles'->k IS DISTINCT FROM e->k $$;
-- How many tiles of a dashboard are not null.
CREATE FUNCTION t.shown(d jsonb) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(array_agg(k ORDER BY k),'{}') FROM unnest(t.tiles()) k WHERE jsonb_typeof(d->'tiles'->k)='object' $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids,t.docs TO authenticated;
GRANT INSERT ON t.results,t.ids,t.docs TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (three branches), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('D01 '||s,'d01-key-'||s,'retail_pro','Owner',s||'d01@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('d',64)),('b',repeat('e',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a0100000-0000-0000-8000-000000000001','ad01@example.com'),('a0100000-0000-0000-8000-000000000002','bd01@example.com'),
  ('a0100000-0000-0000-8000-000000000003','d01manager@example.com'),('a0100000-0000-0000-8000-000000000004','d01cashier@example.com'),
  ('a0100000-0000-0000-8000-000000000005','d01clerk@example.com'),('a0100000-0000-0000-8000-000000000006','d01col@example.com'),
  ('a0100000-0000-0000-8000-000000000007','d01nokeys@example.com'),('a0100000-0000-0000-8000-000000000008','d01lawyer@example.com');
SELECT public.accept_invite(repeat('d',64),'a0100000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('e',64),'a0100000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'safe',default_cash_account_id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main-b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true,credit_min_score=0,customer_ban_days=0 WHERE organization_id=t.org('a');
UPDATE public.organizations SET installments_enabled=true WHERE id=t.org('a');
SELECT t.as_user('a0100000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('third',public.create_branch('Third','S3',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids SELECT 'cib',(public.create_cash_account('CIB','bank',t.id('main'))->>'id')::uuid;
INSERT INTO t.ids SELECT 'nbe',(public.create_cash_account('NBE','bank',NULL)->>'id')::uuid;
INSERT INTO t.ids VALUES('chair',public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"D1-CH","cash_price":"100"}'));
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"D1-TV","cash_price":"12000"}'));
INSERT INTO t.ids VALUES('lamp',public.create_product('{"name_ar":"مصباح","name_en":"Lamp","sku":"D1-LP","cash_price":"50","min_stock":5}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',50),jsonb_build_object('product_id',t.id('tv'),'quantity',5),
                    jsonb_build_object('product_id',t.id('lamp'),'quantity',8)),'d01-key-found');
SELECT public.post_stock_adjustment(t.id('second'),'found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('chair'),'quantity',20)),'d01-key-found2');
INSERT INTO t.ids SELECT 'transport',(public.create_expense_category('Transport')->>'id')::uuid;
RESET ROLE;
INSERT INTO t.ids SELECT 'safe2',default_cash_account_id FROM public.branches WHERE id=t.id('second');
CREATE FUNCTION t.emp(tag text,sub uuid,name text,r public.employee_role,branches text[] DEFAULT ARRAY['main']) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; b text; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),sub,name,r,t.id(branches[1])) RETURNING id INTO v;
  FOREACH b IN ARRAY branches LOOP
    INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),v,t.id(b));
  END LOOP;
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('manager','a0100000-0000-0000-8000-000000000003','D01 Manager','BRANCH_MANAGER',ARRAY['main','second']);
SELECT t.emp('cashier','a0100000-0000-0000-8000-000000000004','D01 Cashier','CASHIER');
SELECT t.emp('clerk','a0100000-0000-0000-8000-000000000005','D01 Clerk','CASHIER',ARRAY['second']);
SELECT t.emp('col','a0100000-0000-0000-8000-000000000006','D01 Collector','COLLECTOR');
SELECT t.emp('nokeys','a0100000-0000-0000-8000-000000000007','D01 No Keys','CASHIER');
SELECT t.emp('lawyer','a0100000-0000-0000-8000-000000000008','D01 Lawyer','LAWYER');
-- "No keys": the cashier's three dashboard keys are taken away.
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted)
  SELECT t.org('a'),t.id('nokeys'),k,false FROM unnest(ARRAY['sale.create','shift.operate','stock.view']) k;
INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status,national_id,city,address) VALUES
  (t.org('a'),'D01 Customer One',ARRAY['01055550001'],500000,'active','29101010100501','Cairo','5 B Street'),
  (t.org('a'),'D01 Customer Two',ARRAY['01055550002'],500000,'active','29101010100502','Giza','6 B Street');
INSERT INTO t.ids SELECT 'c1',id FROM public.customers WHERE organization_id=t.org('a') AND full_name='D01 Customer One';
INSERT INTO t.ids SELECT 'c2',id FROM public.customers WHERE organization_id=t.org('a') AND full_name='D01 Customer Two';
INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,grace_days,early_settlement_rule,early_settlement_pct,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":20,"up_to_months":24}]','{monthly}',1,3,'percent_of_future_profit',50,
         1000000,1,1000000
  FROM public.installment_policies WHERE organization_id=t.org('a');
CREATE FUNCTION t.u(n text) RETURNS text LANGUAGE sql AS $$ SELECT CASE n
  WHEN 'owner' THEN 'a0100000-0000-0000-8000-000000000001' WHEN 'owner-b' THEN 'a0100000-0000-0000-8000-000000000002'
  WHEN 'manager' THEN 'a0100000-0000-0000-8000-000000000003' WHEN 'cashier' THEN 'a0100000-0000-0000-8000-000000000004'
  WHEN 'clerk' THEN 'a0100000-0000-0000-8000-000000000005' WHEN 'col' THEN 'a0100000-0000-0000-8000-000000000006'
  WHEN 'nokeys' THEN 'a0100000-0000-0000-8000-000000000007' WHEN 'lawyer' THEN 'a0100000-0000-0000-8000-000000000008' END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- the day
-- Main: opening 10000 in the safe, the owner's shift (float 500); a cash sale, a split sale, a bank sale
-- that is voided, two installment sales (2000 down each), a 1000 counter collection, a 50 expense; the
-- collector collects 400 in the field. Second: the clerk's shift (float 100) opened yesterday, a 200 cash
-- sale. Third: nothing. Yesterday: a sale in main (a day not closed). Shop b: a sale of its own.
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT public.post_cash_opening(t.id('safe'),'10000.00','Opening','d01-key-opening');
SELECT public.post_cash_opening(t.id('safe2'),'800.00','Opening','d01-key-opening2');
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'500.00','d01-key-shift');
RESET ROLE;
INSERT INTO t.ids SELECT 'shift',(t.doc('shift')->>'id')::uuid;
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 's1',public.post_sale(t.lines(t.items('chair',3)),'300.00','d01-key-s1',NULL,t.lines(t.pcash('300.00')));
INSERT INTO t.docs SELECT 's2',public.post_sale(t.lines(t.items('chair',5)),'500.00','d01-key-s2',NULL,t.lines(t.pcash('200.00'),t.pbank('300.00','cib','TRX-1')));
INSERT INTO t.docs SELECT 's3',public.post_sale(t.lines(t.items('chair',1)),'100.00','d01-key-s3',NULL,t.lines(t.pbank('100.00','nbe','TRX-2')));
INSERT INTO t.docs SELECT 'inst1',public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),
    'expected_total','12000.00','customer_id',t.id('c1'),
    'terms',jsonb_build_object('down_payment','2000.00','installments_count',12,'frequency','monthly','policy_version',t.pv())),'d01-key-inst1');
INSERT INTO t.docs SELECT 'inst2',public.post_installment_sale(jsonb_build_object(
    'lines',jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),
    'expected_total','12000.00','customer_id',t.id('c2'),
    'terms',jsonb_build_object('down_payment','2000.00','installments_count',12,'frequency','monthly','policy_version',t.pv())),'d01-key-inst2');
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO t.docs SELECT 'col',public.post_collection(jsonb_build_object('customer_id',t.id('c1'),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',(t.doc('inst1')->'contract'->>'id')::uuid,'amount','1000.00')),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','1000.00'))),'d01-key-col');
INSERT INTO t.docs SELECT 'e2',public.post_expense(t.id('transport'),'50.00','d01-key-e2',t.id('main'),NULL,true,'Taxi',NULL);
INSERT INTO t.docs SELECT 'void',public.void_sale((t.doc('s3')->>'id')::uuid,'Customer changed mind','d01-key-void');
SELECT public.set_customer_collector(t.id('c1'),t.id('col'),'East side');
RESET ROLE;
INSERT INTO t.ids SELECT 'contract1',(t.doc('inst1')->'contract'->>'id')::uuid;
INSERT INTO t.ids SELECT 'contract2',(t.doc('inst2')->'contract'->>'id')::uuid;
-- The collector collects 400 in the field (into their own wallet, no shift).
SELECT t.as_user(t.u('col'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'field',public.post_field_collection(jsonb_build_object('customer_id',t.id('c1'),
    'contracts',jsonb_build_array(jsonb_build_object('contract_id',t.id('contract1'),'amount','400.00')),
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','400.00'))),'d01-key-field');
RESET ROLE;
-- The clerk's shift in the second branch, with a 200 cash sale.
SELECT t.as_user(t.u('clerk'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift2',t.open_shift(t.id('second'),'100.00','d01-key-shift2');
RESET ROLE;
INSERT INTO t.ids SELECT 'shift2',(t.doc('shift2')->>'id')::uuid;
SELECT t.as_user(t.u('clerk'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'c-sale',public.post_sale(t.lines(t.items('chair',2)),'200.00','d01-key-csale',NULL,t.lines(t.pcash('200.00')));
RESET ROLE;
-- Dated back, as the database owner: the clerk's shift was opened yesterday; the first two schedule lines of
-- both contracts are late; a sale of yesterday in main (a day not closed); shop b has a sale.
SET session_replication_role = replica;
UPDATE public.shifts SET opened_at=opened_at-interval '1 day' WHERE id=t.id('shift2');
UPDATE public.schedule_lines SET due_date=due_date-75 WHERE contract_id IN (t.id('contract1'),t.id('contract2')) AND seq<=2;
INSERT INTO public.sales(organization_id,number,branch_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key,issued_at)
  VALUES(t.org('a'),'D01-YESTERDAY',t.id('main'),'pos',false,true,70,70,t.today()-1,'d01-key-yesterday',now()-interval '1 day');
INSERT INTO public.sales(organization_id,number,branch_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key,issued_at)
  VALUES(t.org('b'),'D01-B-SALE',t.id('main-b'),'pos',false,true,999,999,t.today(),'d01-key-b-sale',now());
SET session_replication_role = origin;
-- ETA receipts: a blocked and a send-failed one in main (sales s1 and s2), a rejected one in second;
-- shop b has a failed one of its own.
INSERT INTO public.fiscal_submissions(organization_id,branch_id,doc_type,sale_id,environment,internal_id,status,last_error)
  VALUES(t.org('a'),t.id('main'),'b2c_receipt',(t.doc('s1')->>'id')::uuid,'preprod','D01-F1','failed','ETA_UNREACHABLE: down');
INSERT INTO public.fiscal_submissions(organization_id,branch_id,doc_type,sale_id,environment,internal_id,status,eta_uuid,last_error)
  VALUES(t.org('a'),t.id('main'),'b2c_receipt',(t.doc('s2')->>'id')::uuid,'preprod','D01-F2','failed',repeat('a',64),'ETA_UNREACHABLE: down');
INSERT INTO public.fiscal_submissions(organization_id,branch_id,doc_type,sale_id,environment,internal_id,status,last_error)
  VALUES(t.org('a'),t.id('second'),'b2c_receipt',(t.doc('c-sale')->>'id')::uuid,'preprod','D01-F3','rejected','ETA_INVALID: x');
INSERT INTO public.fiscal_submissions(organization_id,branch_id,doc_type,sale_id,environment,internal_id,status,last_error)
  SELECT t.org('b'),t.id('main-b'),'b2c_receipt',id,'preprod','D01-FB','failed','ETA_UNREACHABLE: down' FROM public.sales WHERE number='D01-B-SALE';
-- Approvals waiting: discounts in main and second, purchases in main and second, a credit exception;
-- one decided discount (not counted) and shop b's three (never counted).
INSERT INTO public.approvals(organization_id,branch_id,kind,entity_type,amount,status,requested_by,reason) VALUES
  (t.org('a'),t.id('main'),'discount_above_cap','discount_request',9,'pending',t.id('cashier'),'Discount one'),
  (t.org('a'),t.id('second'),'discount_above_cap','discount_request',8,'pending',t.id('clerk'),'Discount two'),
  (t.org('a'),t.id('main'),'purchase_invoice','purchase_invoice',5000,'pending',t.id('cashier'),'Purchase one'),
  (t.org('a'),t.id('second'),'purchase_invoice','purchase_invoice',6000,'pending',t.id('clerk'),'Purchase two'),
  (t.org('a'),t.id('main'),'credit_exception','customer',7000,'pending',t.id('cashier'),'Credit one'),
  (t.org('b'),t.id('main-b'),'discount_above_cap','discount_request',9,'pending',(SELECT id FROM public.employees WHERE organization_id=t.org('b') LIMIT 1),'B discount'),
  (t.org('b'),t.id('main-b'),'purchase_invoice','purchase_invoice',5000,'pending',(SELECT id FROM public.employees WHERE organization_id=t.org('b') LIMIT 1),'B purchase'),
  (t.org('b'),t.id('main-b'),'credit_exception','customer',7000,'pending',(SELECT id FROM public.employees WHERE organization_id=t.org('b') LIMIT 1),'B credit');
INSERT INTO public.approvals(organization_id,branch_id,kind,entity_type,amount,status,requested_by,decided_by,decided_at,reason) VALUES
  (t.org('a'),t.id('main'),'discount_above_cap','discount_request',9,'approved',t.id('cashier'),t.id('manager'),now(),'Discount decided');

-- ================================================================ the owner: all branches and each branch
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'o-all',public.get_owner_dashboard();
INSERT INTO t.docs SELECT 'o-main',public.get_owner_dashboard(t.id('main'));
INSERT INTO t.docs SELECT 'o-second',public.get_owner_dashboard(t.id('second'));
INSERT INTO t.docs SELECT 'o-third',public.get_owner_dashboard(t.id('third'));
INSERT INTO t.docs SELECT 'x-all',t.expected(NULL);
INSERT INTO t.docs SELECT 'x-main',t.expected(t.id('main'));
INSERT INTO t.docs SELECT 'x-second',t.expected(t.id('second'));
INSERT INTO t.docs SELECT 'x-third',t.expected(t.id('third'));
INSERT INTO t.docs SELECT 'old-fiscal',t.old_fiscal();
INSERT INTO t.docs SELECT 'new-fiscal',public.fiscal_alert_summary();
INSERT INTO t.docs SELECT 'k04-all',jsonb_build_object(
  'main',public.get_day_close_preview(t.id('main'),t.today())->'totals'->'sales',
  'second',public.get_day_close_preview(t.id('second'),t.today())->'totals'->'sales');
RESET ROLE;

SELECT t.expect('envelope: the shop''s date, the branch filter and a timestamp',
  t.doc('o-all')->>'business_date'=t.today()::text AND t.doc('o-all')->'branch_id'='null'::jsonb
  AND t.doc('o-main')->>'branch_id'=t.id('main')::text AND (t.doc('o-all')->>'generated_at')::timestamptz > now()-interval '1 minute'
  AND t.shown(t.doc('o-all'))=(SELECT array_agg(k ORDER BY k) FROM unnest(t.tiles()) k), t.doc('o-all')::text);
SELECT t.expect('all branches: every tile equals its detail',t.diff(t.doc('o-all'),t.doc('x-all'))='',t.diff(t.doc('o-all'),t.doc('x-all')));
SELECT t.expect('main: every tile equals its detail',t.diff(t.doc('o-main'),t.doc('x-main'))='',t.diff(t.doc('o-main'),t.doc('x-main')));
SELECT t.expect('second: every tile equals its detail',t.diff(t.doc('o-second'),t.doc('x-second'))='',t.diff(t.doc('o-second'),t.doc('x-second')));
SELECT t.expect('third: every tile equals its detail',t.diff(t.doc('o-third'),t.doc('x-third'))='',t.diff(t.doc('o-third'),t.doc('x-third')));

-- The numbers are not all zero: what the day holds, worked out by hand.
SELECT t.expect('sales (all): 5 sales without the voided one and yesterday''s, 25000 in total; by method 1000 cash... ',
  t.doc('o-all')->'tiles'->'sales_today'->>'count'='5' AND t.doc('o-all')->'tiles'->'sales_today'->>'total'='25000.00'
  AND t.doc('o-all')->'tiles'->'sales_today'->'paid_by_method'->>'bank_transfer'='300.00'
  AND t.doc('o-all')->'tiles'->'sales_today'->>'on_contract'='20000.00',
  t.doc('o-all')->'tiles'->>'sales_today');
SELECT t.expect('sales: main 4 sales, second 1 sale of 200, third none',
  t.doc('o-main')->'tiles'->'sales_today'->>'count'='4' AND t.doc('o-second')->'tiles'->'sales_today'->>'total'='200.00'
  AND t.doc('o-third')->'tiles'->'sales_today'->>'count'='0' AND t.doc('o-third')->'tiles'->'sales_today'->>'total'='0.00');
SELECT t.expect('sales: shop b''s 999 sale and yesterday''s 70 are not counted anywhere',
  t.doc('o-all')->'tiles'->'sales_today'->>'total'<>'1094.00' AND (t.doc('o-all')->'tiles'->'sales_today'->>'total')::numeric=25000);
SELECT t.expect('sales: K04''s paid by method for the same sales (its sales still count the voided bank sale of 100)',
  (t.doc('k04-all')->'main'->'paid_by_method'->>'bank_transfer')::numeric - 100 = (t.doc('o-main')->'tiles'->'sales_today'->'paid_by_method'->>'bank_transfer')::numeric
  AND (t.doc('k04-all')->'main'->'paid_by_method'->>'cash')::numeric = (t.doc('o-main')->'tiles'->'sales_today'->'paid_by_method'->>'cash')::numeric
  AND (t.doc('k04-all')->'main'->>'on_contract')::numeric = (t.doc('o-main')->'tiles'->'sales_today'->>'on_contract')::numeric
  AND (t.doc('k04-all')->'second'->>'total')::numeric = (t.doc('o-second')->'tiles'->'sales_today'->>'total')::numeric,
  t.doc('k04-all')::text);
SELECT t.expect('collections: the counter 1000 and the field 400 (all), in the field 400, in main only',
  t.doc('o-all')->'tiles'->'collections_today'='{"count":2,"total":"1400.00","in_field":"400.00"}'::jsonb
  AND t.doc('o-main')->'tiles'->'collections_today'='{"count":2,"total":"1400.00","in_field":"400.00"}'::jsonb
  AND t.doc('o-second')->'tiles'->'collections_today'='{"count":0,"total":"0.00","in_field":"0.00"}'::jsonb,
  t.doc('o-all')->'tiles'->>'collections_today');
SELECT t.expect('cash: wallets 400, a shop-wide bank only without a branch filter, drawers of the open shifts',
  (t.doc('o-all')->'tiles'->'cash'->>'wallets')='400.00' AND (t.doc('o-second')->'tiles'->'cash'->>'wallets')='0.00'
  AND (t.doc('o-all')->'tiles'->'cash'->>'total_in_branches')::numeric=
      (t.doc('o-all')->'tiles'->'cash'->>'safes')::numeric+(t.doc('o-all')->'tiles'->'cash'->>'drawers')::numeric+(t.doc('o-all')->'tiles'->'cash'->>'wallets')::numeric
  AND (t.doc('o-all')->'tiles'->'cash'->>'banks')::numeric=
      (t.doc('o-main')->'tiles'->'cash'->>'banks')::numeric+(t.doc('o-second')->'tiles'->'cash'->>'banks')::numeric
        +(t.doc('o-third')->'tiles'->'cash'->>'banks')::numeric+(SELECT COALESCE(sum(balance),0) FROM public.cash_balances WHERE cash_account_id=t.id('nbe')),
  t.doc('o-all')->'tiles'->>'cash');
SELECT t.expect('open shifts: two (one opened yesterday), the oldest is the clerk''s; main has one, second one from an earlier day',
  (t.doc('o-all')->'tiles'->'open_shifts'->>'count')='2' AND (t.doc('o-all')->'tiles'->'open_shifts'->>'from_earlier_days')='1'
  AND (t.doc('o-main')->'tiles'->'open_shifts'->>'count')='1' AND (t.doc('o-main')->'tiles'->'open_shifts'->>'from_earlier_days')='0'
  AND (t.doc('o-second')->'tiles'->'open_shifts'->>'from_earlier_days')='1'
  AND t.doc('o-third')->'tiles'->'open_shifts'='{"count":0,"oldest_opened_at":null,"from_earlier_days":0}'::jsonb,
  t.doc('o-all')->'tiles'->>'open_shifts');
SELECT t.expect('overdue: both contracts, two customers, no fee; main has them, second none',
  (t.doc('o-all')->'tiles'->'overdue'->>'contracts')='2' AND (t.doc('o-all')->'tiles'->'overdue'->>'customers')='2'
  AND (t.doc('o-all')->'tiles'->'overdue'->>'amount')='2600.00' AND (t.doc('o-main')->'tiles'->'overdue'->>'contracts')='2'
  AND (t.doc('o-second')->'tiles'->'overdue'->>'contracts')='0'
  AND NOT t.doc('o-all')->'tiles'->'overdue' ? 'fee',
  t.doc('o-all')->'tiles'->>'overdue');
SELECT t.expect('low stock: below the minimum per branch and product: main none, second the lamp and the TV, third all three',
  (t.doc('o-all')->'tiles'->'low_stock'->>'products')='5' AND (t.doc('o-main')->'tiles'->'low_stock'->>'products')='0'
  AND (t.doc('o-second')->'tiles'->'low_stock'->>'products')='2' AND (t.doc('o-third')->'tiles'->'low_stock'->>'products')='3',
  t.doc('o-all')->'tiles'->>'low_stock');
SELECT t.expect('eta: blocked 1 and send_failed 1 in main, rejected 1 in second, shop b''s failed receipt not counted',
  t.doc('o-all')->'tiles'->'eta'->>'needs_action'='3' AND t.doc('o-main')->'tiles'->'eta'->>'needs_action'='2'
  AND t.doc('o-main')->'tiles'->'eta'->>'blocked'='1' AND t.doc('o-main')->'tiles'->'eta'->>'send_failed'='1'
  AND t.doc('o-second')->'tiles'->'eta'->>'rejected'='1' AND t.doc('o-third')->'tiles'->'eta'->>'needs_action'='0',
  t.doc('o-all')->'tiles'->>'eta');
SELECT t.expect('unclosed days: yesterday''s sale in main is one day, in one branch',
  t.doc('o-all')->'tiles'->'unclosed_days'='{"days":1,"branches":1}'::jsonb AND t.doc('o-main')->'tiles'->'unclosed_days'='{"days":1,"branches":1}'::jsonb
  AND t.doc('o-second')->'tiles'->'unclosed_days'='{"days":0,"branches":0}'::jsonb,
  t.doc('o-all')->'tiles'->>'unclosed_days');
SELECT t.expect('approvals: discounts and credit lists have no branch filter, purchases do; shop b and the decided one never count',
  t.doc('o-all')->'tiles'->'approvals'='{"discount":2,"purchase":2,"credit":1,"total":5}'::jsonb
  AND t.doc('o-main')->'tiles'->'approvals'='{"discount":2,"purchase":1,"credit":1,"total":4}'::jsonb
  AND t.doc('o-second')->'tiles'->'approvals'='{"discount":2,"purchase":1,"credit":1,"total":4}'::jsonb
  AND t.doc('o-third')->'tiles'->'approvals'='{"discount":2,"purchase":0,"credit":1,"total":3}'::jsonb,
  t.doc('o-all')->'tiles'->>'approvals');

-- ================================================================ fiscal_alert_summary keeps its answer
SELECT t.expect('fiscal_alert_summary: the answer through app.fiscal_alert_counts equals the T03 query',
  t.doc('old-fiscal')=t.doc('new-fiscal') AND (t.doc('new-fiscal')->>'send_failed')='1',t.doc('new-fiscal')::text);
SELECT t.expect('fiscal_alert_counts: the branches add up to the shop''s summary',
  (SELECT bool_and((t.fiscal_branch(t.id('main'))->>k)::int+(t.fiscal_branch(t.id('second'))->>k)::int+(t.fiscal_branch(t.id('third'))->>k)::int=(t.doc('new-fiscal')->>k)::int)
   FROM unnest(ARRAY['blocked','send_failed','rejected','due_soon','overdue','accepted_today']) k));

-- ================================================================ a manager of two branches (the "some branches" path)
SELECT t.as_user(t.u('manager'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'm-all',public.get_owner_dashboard();
INSERT INTO t.docs SELECT 'm-main',public.get_owner_dashboard(t.id('main'));
INSERT INTO t.docs SELECT 'mx-all',t.expected(NULL);
INSERT INTO t.docs SELECT 'mx-main',t.expected(t.id('main'));
SELECT t.error('branch: a branch the manager doesn''t work in is BRANCH_DENIED',format('SELECT public.get_owner_dashboard(%L)',t.id('third')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.expect('manager (main + second): all branches equals the details, a sum of the two branches',
  t.diff(t.doc('m-all'),t.doc('mx-all'))='' AND t.diff(t.doc('m-main'),t.doc('mx-main'))='',
  t.diff(t.doc('m-all'),t.doc('mx-all'))||t.diff(t.doc('m-main'),t.doc('mx-main')));
SELECT t.expect('manager: the overdue tile of two branches equals the owner''s (the third has nothing); the third branch is left out of low stock',
  t.doc('m-all')->'tiles'->'overdue'=t.doc('o-all')->'tiles'->'overdue'
  AND (t.doc('m-all')->'tiles'->'low_stock'->>'products')='2' AND (t.doc('o-all')->'tiles'->'low_stock'->>'products')='5',
  t.doc('m-all')->'tiles'->>'overdue');

-- ================================================================ who sees what
SELECT t.as_user(t.u('cashier'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'cashier',public.get_owner_dashboard();
RESET ROLE;
SELECT t.as_user(t.u('nokeys'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'nokeys',public.get_owner_dashboard();
RESET ROLE;
SELECT t.as_user(t.u('col'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'd-col',public.get_owner_dashboard();
INSERT INTO t.docs SELECT 'col-x',public.list_overdue_contracts('{}');
RESET ROLE;
SELECT t.as_user(t.u('lawyer'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'lawyer',public.get_owner_dashboard();
RESET ROLE;
SELECT t.as_user(t.u('clerk'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'clerk',public.get_owner_dashboard();
SELECT t.error('branch: a branch the clerk doesn''t work in is BRANCH_DENIED',format('SELECT public.get_owner_dashboard(%L)',t.id('main')),'BRANCH_DENIED');
RESET ROLE;
SELECT t.expect('cashier (main only): sales of main, their own open shifts (none), low stock; the rest null',
  t.shown(t.doc('cashier'))=ARRAY['low_stock','open_shifts','sales_today']
  AND t.doc('cashier')->'tiles'->'sales_today'=t.doc('o-main')->'tiles'->'sales_today'
  AND (t.doc('cashier')->'tiles'->'open_shifts'->>'count')='0',
  t.doc('cashier')::text);
SELECT t.expect('a cashier without sale.create, shift.operate and stock.view gets an answer with every tile null, not a denial',
  t.shown(t.doc('nokeys'))='{}' AND t.doc('nokeys')->>'business_date'=t.today()::text AND t.doc('nokeys')->'tiles'->'cash'='null'::jsonb
  AND jsonb_typeof(t.doc('nokeys')->'tiles')='object',t.doc('nokeys')::text);
SELECT t.expect('collector: only the overdue tile, of their own customer (one contract), equal to their overdue list',
  t.shown(t.doc('d-col'))=ARRAY['overdue'] AND t.doc('d-col')->'tiles'->'overdue'->>'contracts'='1'
  AND t.doc('d-col')->'tiles'->'overdue'->>'customers'='1' AND t.doc('d-col')->'tiles'->'overdue'->>'amount'='600.00'
  AND t.doc('d-col')->'tiles'->'overdue'->>'contracts'=t.doc('col-x')->'totals'->>'contracts'
  AND t.doc('d-col')->'tiles'->'overdue'->>'amount'=t.doc('col-x')->'totals'->>'overdue_amount'
  AND (t.doc('o-all')->'tiles'->'overdue'->>'contracts')='2',
  t.doc('d-col')::text);
SELECT t.expect('lawyer (overdue.view only): the overdue tile and nothing else',t.shown(t.doc('lawyer'))=ARRAY['overdue'],t.doc('lawyer')::text);
SELECT t.expect('clerk (second only): sales and open shifts of their branch; low stock counts their branch only',
  t.shown(t.doc('clerk'))=ARRAY['low_stock','open_shifts','sales_today']
  AND t.doc('clerk')->'tiles'->'sales_today'->>'total'='200.00' AND t.doc('clerk')->'tiles'->'open_shifts'->>'count'='1'
  AND t.doc('clerk')->'tiles'->'open_shifts'->>'from_earlier_days'='1' AND t.doc('clerk')->>'branch_id' IS NULL,
  t.doc('clerk')::text);

-- ================================================================ errors, other shop, expired shop
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT t.error('branch: another shop''s branch is BRANCH_NOT_FOUND',format('SELECT public.get_owner_dashboard(%L)',t.id('main-b')),'BRANCH_NOT_FOUND');
SELECT t.error('branch: an unknown id is BRANCH_NOT_FOUND',format('SELECT public.get_owner_dashboard(%L)',gen_random_uuid()),'BRANCH_NOT_FOUND');
RESET ROLE;
SELECT t.as_user(t.u('owner-b'),t.org('b'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'b-all',public.get_owner_dashboard();
RESET ROLE;
SELECT t.expect('shop b sees its own documents only: 1 sale of 999, one failed receipt, three approvals, nothing of shop a',
  t.doc('b-all')->'tiles'->'sales_today'->>'total'='999.00' AND t.doc('b-all')->'tiles'->'sales_today'->>'count'='1'
  AND t.doc('b-all')->'tiles'->'eta'->>'send_failed'='0' AND t.doc('b-all')->'tiles'->'eta'->>'blocked'='1'
  AND t.doc('b-all')->'tiles'->'approvals'='{"discount":1,"purchase":1,"credit":1,"total":3}'::jsonb
  AND t.doc('b-all')->'tiles'->'overdue'->>'contracts'='0',
  t.doc('b-all')::text);
SELECT t.as_user(NULL);
SET ROLE authenticated;
SELECT t.error('anonymous session: NOT_AN_EMPLOYEE','SELECT public.get_owner_dashboard()','NOT_AN_EMPLOYEE');
RESET ROLE;
-- An expired shop still reads.
UPDATE public.organizations SET subscription_start=NULL,subscription_end=t.today()-5 WHERE id=t.org('a');
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'expired',public.get_owner_dashboard();
RESET ROLE;
SELECT t.expect('an expired shop still reads: the same tiles',
  t.doc('expired')->'tiles'=t.doc('o-all')->'tiles' AND jsonb_typeof(t.doc('expired')->'tiles'->'sales_today')='object',t.doc('expired')::text);
UPDATE public.organizations SET subscription_end=NULL WHERE id=t.org('a');

-- ================================================================ a shop without the eta module
UPDATE public.organizations SET plan_key='retail' WHERE id=t.org('b');
UPDATE public.plans SET modules=array_remove(modules,'eta') WHERE key='retail';
SELECT t.as_user(t.u('owner-b'),t.org('b'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'b-noeta',public.get_owner_dashboard();
RESET ROLE;
SELECT t.expect('a plan without the eta module: the eta tile is null, the rest stays',
  t.doc('b-noeta')->'tiles'->'eta'='null'::jsonb AND jsonb_typeof(t.doc('b-noeta')->'tiles'->'sales_today')='object',t.doc('b-noeta')::text);

-- ================================================================ an inactive branch is left out of "all"
SELECT t.as_user(t.u('owner'),t.org('a'));
SET ROLE authenticated;
SELECT public.set_branch_active(t.id('third'),false,'Closed for the test',false);
INSERT INTO t.docs SELECT 'o-all-inactive',public.get_owner_dashboard();
INSERT INTO t.docs SELECT 'o-third-inactive',public.get_owner_dashboard(t.id('third'));
RESET ROLE;
SELECT t.expect('an inactive branch is left out of all branches (low stock 5 -> 2) but can still be asked for by id',
  t.doc('o-all-inactive')->'tiles'->'low_stock'->>'products'='2' AND t.doc('o-third-inactive')->'tiles'->'low_stock'->>'products' IS NOT NULL
  AND t.doc('o-third-inactive')->>'branch_id'=t.id('third')::text,
  t.doc('o-all-inactive')->'tiles'->>'low_stock');

-- ================================================================ grants
SELECT t.expect('grants: the public read for signed-in users only; the app helpers are not granted',
  has_function_privilege('authenticated','public.get_owner_dashboard(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_owner_dashboard(uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.dashboard_branches(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.dashboard_sales(uuid,uuid[],date)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.dashboard_collections(uuid,uuid[],date)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.dashboard_cash(uuid,uuid[],boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.dashboard_shifts(uuid,uuid[],date,uuid)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.dashboard_overdue(uuid,uuid[],boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.dashboard_overdue_customers(uuid,uuid[])','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.fiscal_alert_counts(uuid,uuid[])','EXECUTE')
  AND has_function_privilege('authenticated','public.fiscal_alert_summary()','EXECUTE'));
SELECT t.expect('definer: every new function is SECURITY DEFINER with an empty search_path',
  (SELECT count(*)=9 AND bool_and(p.prosecdef AND p.proconfig @> ARRAY['search_path=""']) FROM pg_proc p
   WHERE (p.pronamespace='app'::regnamespace AND p.proname LIKE 'dashboard\_%') OR p.proname IN ('get_owner_dashboard','fiscal_alert_counts')
         AND p.pronamespace IN ('app'::regnamespace,'public'::regnamespace)));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
