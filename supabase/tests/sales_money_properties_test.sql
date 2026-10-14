\ir helpers/test4_setup.sql
\ir helpers/test4_snapshot.sql
SELECT setseed(0.4242);
CREATE FUNCTION t.vat_mode(inclusive boolean) RETURNS void LANGUAGE sql SECURITY DEFINER AS $$ UPDATE public.org_settings SET prices_include_vat=inclusive WHERE organization_id=t.org('a') $$;
GRANT EXECUTE ON FUNCTION t.vat_mode(boolean) TO authenticated;
SET statement_timeout = '60s';
SELECT t.as_user('a7050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('p3',public.create_product('{"name_ar":"ثالث","sku":"TEST4-P3","cash_price":"99.99"}'));
INSERT INTO t.ids VALUES('p4',public.create_product('{"name_ar":"رابع","sku":"TEST4-P4","cash_price":"114.01"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(t.items('chair',6000),t.items('sofa',6000),t.items('p3',6000),t.items('p4',6000)),'test4-property-stock');
RESET ROLE;
INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date)
VALUES(t.org('a'),t.id('mona'),100000,'sales_return',gen_random_uuid(),t.id('main'),app.org_today(t.org('a')));
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'0','test4-property-shift')->>'id')::uuid;
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=t.id('shift');
SELECT setseed(0.4242);
DO $$
DECLARE cart jsonb; sd jsonb; quote jsonb; sale jsonb; pays jsonb; total numeric; cash numeric; bank numeric; credit numeric;
  initial_cash numeric := t.cash('drawer'); expected_cash numeric := 0; n integer; i integer; q integer; d numeric;
  tags text[] := ARRAY['chair','sofa','p3','p4'];
BEGIN
  FOR n IN 1..200 LOOP
    PERFORM t.vat_mode(n%2=0);
    cart := '[]';
    FOR i IN 1..(1+floor(random()*4)::integer) LOOP
      q := 1+floor(random()*5)::integer; d := round((random()*4)::numeric,2);
      cart := cart || jsonb_build_array(t.items(tags[i],q)||jsonb_build_object('discount',jsonb_build_object('type','percent','value',d::text)));
    END LOOP;
    sd := jsonb_build_object('type','percent','value',round(random()::numeric,2)::text);
    BEGIN
      quote := public.quote_sale(cart,t.id('mona'),NULL,sd);
      total := (quote->>'total')::numeric;
      cash := round(total*random()::numeric,2);
      bank := round((total-cash)*random()::numeric,2); credit := total-cash-bank;
      pays := '[]';
      IF cash>0 THEN pays := pays||jsonb_build_array(t.pcash(cash::text,(cash+10)::text)); END IF;
      IF bank>0 THEN pays := pays||jsonb_build_array(t.pbank(bank::text,'nbe','TEST4-'||n)); END IF;
      IF credit>0 THEN pays := pays||jsonb_build_array(t.pcredit(credit::text)); END IF;
      sale := public.post_sale(cart,total::text,'test4-random-'||n,t.id('mona'),pays,sd,'TEST4 seeded');
      expected_cash := expected_cash+cash;
      PERFORM t.expect('seed 0.4242 case '||n||': payments and change',
        (sale->>'paid_total')::numeric=total AND (sale->>'change_total')::numeric=CASE WHEN cash>0 THEN 10 ELSE 0 END,sale::text);
      PERFORM t.expect('seed 0.4242 case '||n||': header arithmetic',
        total=(sale->>'subtotal')::numeric-(sale->>'discount_total')::numeric+CASE WHEN (sale->>'prices_include_vat')::boolean THEN 0 ELSE (sale->>'tax_total')::numeric END,sale::text);
      PERFORM t.expect('seed 0.4242 case '||n||': line totals and discounts',
        (SELECT sum((l->>'line_total')::numeric)=total AND sum((l->>'tax_amount')::numeric)=(sale->>'tax_total')::numeric
          AND bool_and((l->>'discount_amount')::numeric<=(l->>'unit_price')::numeric*(l->>'quantity')::integer)
         FROM jsonb_array_elements(sale->'lines') l),sale::text);
      PERFORM t.expect('seed 0.4242 case '||n||': no negative stock',t.bad_stock() IS NULL,t.bad_stock());
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'seed=0.4242 case=% cart=% payments=% error=%',n,cart,pays,SQLERRM; END;
  END LOOP;
  PERFORM t.expect('seed 0.4242: drawer increased by cash minus change',t.cash('drawer')=initial_cash+expected_cash);
END $$;
RESET ROLE;
SELECT t.expect('200 sales posted',(SELECT count(*)=200 FROM public.sales WHERE organization_id=t.org('a')));
SELECT t.expect('all stock equals ledgers',t.bad_stock() IS NULL,t.bad_stock());
SELECT t.expect('all cash equals ledgers',t.bad_cash() IS NULL,t.bad_cash());
SELECT t.expect('all store credit equals ledgers',t.bad_credit() IS NULL,t.bad_credit());
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
