\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.detail(q text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d=PG_EXCEPTION_DETAIL; END; RETURN NULLIF(d,'')::jsonb; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.json(q text) RETURNS jsonb LANGUAGE plpgsql AS $$ DECLARE r jsonb; BEGIN EXECUTE q INTO r; RETURN r; END $$;
CREATE FUNCTION t.policy(p_tag text) RETURNS public.installment_policies LANGUAGE sql AS $$ SELECT x FROM public.installment_policies x WHERE x.id=t.id(p_tag) $$;
-- The engine on a policy tagged p for shop a's today.
CREATE FUNCTION t.terms(p text,i jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT app.installment_terms(t.policy(p),i,app.org_today(t.org('a'))) $$;
-- A customer of shop a made as the database owner.
CREATE FUNCTION t.cust(p_tag text,p_name text,p_limit numeric DEFAULT 0,p_status text DEFAULT 'active') RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones,credit_limit,status)
    VALUES(t.org('a'),p_name,ARRAY['01000000077'],p_limit,p_status::public.customer_status) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
-- A contract of shop a written directly (as any writer could), with its version-1 lines; the two N01
-- triggers then run now ("commit time"). p_mode: engine (the engine's lines), piaster (one piaster
-- moved from line 1's profit to its principal), extra (line 1 one piaster more), gap (no seq 2),
-- dates (every due date a day later), none (no lines). p_markup overrides the engine's markup.
CREATE FUNCTION t.make(p_tag text,p_customer text,p_input jsonb,p_policy text,p_migrated boolean,p_mode text,p_markup numeric DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_t jsonb; v_order uuid; v_id uuid; v_markup numeric; v_fin numeric; l jsonb;
BEGIN
  SET CONSTRAINTS trg_contracts_terms_check, trg_schedule_lines_sum_check DEFERRED;
  v_t := app.installment_terms(t.policy(p_policy),p_input,app.org_today(t.org('a')));
  v_fin := (v_t->>'financed_amount')::numeric;
  v_markup := COALESCE(p_markup,(v_t->>'markup_amount')::numeric);
  IF NOT p_migrated THEN
    INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,total,idempotency_key)
      VALUES(t.org('a'),'N01-SO-'||p_tag,t.id(p_customer),t.id('main'),false,(p_input->>'cash_price')::numeric,(p_input->>'cash_price')::numeric,'n01-so-'||p_tag)
      RETURNING id INTO v_order;
  END IF;
  INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,order_id,policy_id,creditor,cash_price,down_payment,financed_amount,
      markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,is_migrated,idempotency_key)
    VALUES(t.org('a'),'N01-C-'||p_tag,t.id(p_customer),t.id('main'),v_order,t.id(p_policy),'in_house',(p_input->>'cash_price')::numeric,
      (p_input->>'down_payment')::numeric,v_fin,(v_t->>'markup_pct')::numeric,v_markup,v_fin+v_markup,(p_input->>'installments_count')::integer,
      (p_input->>'frequency')::public.installment_frequency,(v_t->>'first_due_date')::date,p_migrated,'n01-c-'||p_tag)
    RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('contract-'||p_tag,v_id);
  IF p_mode<>'none' THEN
    FOR l IN SELECT jsonb_array_elements(v_t->'lines') LOOP
      CONTINUE WHEN p_mode='gap' AND (l->>'seq')::integer=2;
      INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit)
        VALUES(t.org('a'),v_id,1,(l->>'seq')::integer,(l->>'due_date')::date+CASE WHEN p_mode='dates' THEN 1 ELSE 0 END,
          (l->>'principal')::numeric+CASE WHEN p_mode IN ('piaster','extra') AND (l->>'seq')::integer=1 THEN 0.01 ELSE 0 END,
          (l->>'profit')::numeric-CASE WHEN p_mode='piaster' AND (l->>'seq')::integer=1 THEN 0.01 ELSE 0 END);
    END LOOP;
  END IF;
  SET CONSTRAINTS trg_contracts_terms_check, trg_schedule_lines_sum_check IMMEDIATE;
  SET CONSTRAINTS trg_contracts_terms_check, trg_schedule_lines_sum_check DEFERRED;
END $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a, b (retail), c (starter: no installments module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('N01 '||s,'n01-'||s,p,'Owner',s||'n01@example.com',NULL,'Main',h,now()+interval '1 day')
FROM (VALUES('a','retail',repeat('x',64)),('b','retail',repeat('y',64)),('c','starter',repeat('z',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0760000-0000-0000-8000-000000000001','an01@example.com'),('a0760000-0000-0000-8000-000000000002','bn01@example.com'),
  ('a0760000-0000-0000-8000-000000000003','n01cashier@example.com'),('a0760000-0000-0000-8000-000000000004','n01warehouse@example.com'),
  ('a0760000-0000-0000-8000-000000000005','cn01@example.com');
SELECT public.accept_invite(repeat('x',64),'a0760000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a0760000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('z',64),'a0760000-0000-0000-8000-000000000005');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,is_active) VALUES
  (t.org('a'),'a0760000-0000-0000-8000-000000000003','N01 Cashier','CASHIER',true),
  (t.org('a'),'a0760000-0000-0000-8000-000000000004','N01 Warehouse','WAREHOUSE',true);
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1;
UPDATE public.org_settings SET credit_min_score=0 WHERE organization_id=t.org('a');
SELECT t.cust('ok','Good Customer',100000);
SELECT t.cust('poor','No Limit Customer',0);
SELECT t.cust('blocked','Blocked Customer',100000,'blocked');
WITH x AS (INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('b'),'Shop B Customer') RETURNING id) INSERT INTO t.ids SELECT 'cust-b',id FROM x;
-- The policy contracts and previews use: tiers 10 % up to 6 months, 20 % up to 24; all frequencies;
-- step 1; 10 % minimum down payment; a guarantor above 20 000 financed, a survey above 30 000.
WITH x AS (INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),COALESCE(max(version),0)+1,10,24,'[{"pct":10,"up_to_months":6},{"pct":20,"up_to_months":24}]','{monthly,weekly,daily}',
    1,20000,1,30000 FROM public.installment_policies WHERE organization_id=t.org('a') RETURNING id)
INSERT INTO t.ids SELECT 'pol',id FROM x;

-- ================================================================ golden cases (both engines)
-- Golden cases: a copy of supabase/tests/fixtures/n01_terms_cases.json (src/test/n01-golden.test.ts keeps them equal).
CREATE TABLE t.golden(doc jsonb);
INSERT INTO t.golden VALUES($golden$
{
  "note": "N01 golden cases (D76). Run by packages/contracts/src/installments.test.ts and supabase/tests/n01_installment_terms_test.sql; both engines must give exactly these terms. Rules: docs/tasks/N01.md decisions 3-9 and docs/ISLAMIC_FINANCE_RULES.md.",
  "cases": [
    {
      "id": "N01-01",
      "title": "1000 / 3 monthly at 0 %, step 0.01: the last line takes the rest",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 3,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 3,
        "frequency": "monthly",
        "duration_months": 3,
        "installment_amount": "333.34",
        "last_installment_amount": "333.32",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-01-15",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "333.34",
            "profit": "0.00",
            "amount": "333.34"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "333.34",
            "profit": "0.00",
            "amount": "333.34"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "333.32",
            "profit": "0.00",
            "amount": "333.32"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-02",
      "title": "1000 / 3 monthly at 0 %, step 1",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "1.00"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 3,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 3,
        "frequency": "monthly",
        "duration_months": 3,
        "installment_amount": "334.00",
        "last_installment_amount": "332.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-01-15",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "334.00",
            "profit": "0.00",
            "amount": "334.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "334.00",
            "profit": "0.00",
            "amount": "334.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "332.00",
            "profit": "0.00",
            "amount": "332.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-03",
      "title": "Financed 12 000, 12 months, tier 20 %: 12 x 1200",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "14000.00",
        "down_payment": "2000.00",
        "installments_count": 12,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "14000.00",
        "down_payment": "2000.00",
        "financed_amount": "12000.00",
        "markup_pct": "20",
        "markup_amount": "2400.00",
        "total_payable": "14400.00",
        "installments_count": 12,
        "frequency": "monthly",
        "duration_months": 12,
        "installment_amount": "1200.00",
        "last_installment_amount": "1200.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-10-15",
        "min_down_payment": "0.00",
        "max_down_payment": "13999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 8,
            "due_date": "2027-06-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 9,
            "due_date": "2027-07-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 10,
            "due_date": "2027-08-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 11,
            "due_date": "2027-09-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 12,
            "due_date": "2027-10-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-04",
      "title": "Tier boundary: 6 months takes the 6-month tier (10 %)",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "6000.00",
        "down_payment": "0.00",
        "installments_count": 6,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "6000.00",
        "down_payment": "0.00",
        "financed_amount": "6000.00",
        "markup_pct": "10",
        "markup_amount": "600.00",
        "total_payable": "6600.00",
        "installments_count": 6,
        "frequency": "monthly",
        "duration_months": 6,
        "installment_amount": "1100.00",
        "last_installment_amount": "1100.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-04-15",
        "min_down_payment": "0.00",
        "max_down_payment": "5999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "1000.00",
            "profit": "100.00",
            "amount": "1100.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "1000.00",
            "profit": "100.00",
            "amount": "1100.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "1000.00",
            "profit": "100.00",
            "amount": "1100.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "1000.00",
            "profit": "100.00",
            "amount": "1100.00"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "1000.00",
            "profit": "100.00",
            "amount": "1100.00"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "1000.00",
            "profit": "100.00",
            "amount": "1100.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-05",
      "title": "Tier boundary: 7 months takes the 12-month tier (20 %)",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "7000.00",
        "down_payment": "0.00",
        "installments_count": 7,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "7000.00",
        "down_payment": "0.00",
        "financed_amount": "7000.00",
        "markup_pct": "20",
        "markup_amount": "1400.00",
        "total_payable": "8400.00",
        "installments_count": 7,
        "frequency": "monthly",
        "duration_months": 7,
        "installment_amount": "1200.00",
        "last_installment_amount": "1200.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-05-15",
        "min_down_payment": "0.00",
        "max_down_payment": "6999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "1000.00",
            "profit": "200.00",
            "amount": "1200.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-06",
      "title": "Fractional tier 32.5 % over 18 months, step 5",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "5.00"
      },
      "input": {
        "cash_price": "25000.00",
        "down_payment": "5000.00",
        "installments_count": 18,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "25000.00",
        "down_payment": "5000.00",
        "financed_amount": "20000.00",
        "markup_pct": "32.5",
        "markup_amount": "6500.00",
        "total_payable": "26500.00",
        "installments_count": 18,
        "frequency": "monthly",
        "duration_months": 18,
        "installment_amount": "1475.00",
        "last_installment_amount": "1425.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2028-04-15",
        "min_down_payment": "0.00",
        "max_down_payment": "24999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "1113.20",
            "profit": "361.80",
            "amount": "1475.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "1113.20",
            "profit": "361.80",
            "amount": "1475.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "1113.20",
            "profit": "361.80",
            "amount": "1475.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "1113.20",
            "profit": "361.80",
            "amount": "1475.00"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 8,
            "due_date": "2027-06-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 9,
            "due_date": "2027-07-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 10,
            "due_date": "2027-08-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 11,
            "due_date": "2027-09-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 12,
            "due_date": "2027-10-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 13,
            "due_date": "2027-11-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 14,
            "due_date": "2027-12-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 15,
            "due_date": "2028-01-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 16,
            "due_date": "2028-02-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 17,
            "due_date": "2028-03-15",
            "principal": "1113.21",
            "profit": "361.79",
            "amount": "1475.00"
          },
          {
            "seq": 18,
            "due_date": "2028-04-15",
            "principal": "1075.47",
            "profit": "349.53",
            "amount": "1425.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-07",
      "title": "Month ends: first due 31 Jan, 4 monthly",
      "today": "2026-12-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "400.00",
        "down_payment": "0.00",
        "installments_count": 4,
        "frequency": "monthly",
        "first_due_date": "2027-01-31"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "400.00",
        "down_payment": "0.00",
        "financed_amount": "400.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "400.00",
        "installments_count": 4,
        "frequency": "monthly",
        "duration_months": 4,
        "installment_amount": "100.00",
        "last_installment_amount": "100.00",
        "first_due_date": "2027-01-31",
        "last_due_date": "2027-04-30",
        "min_down_payment": "0.00",
        "max_down_payment": "399.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2027-01-31",
            "principal": "100.00",
            "profit": "0.00",
            "amount": "100.00"
          },
          {
            "seq": 2,
            "due_date": "2027-02-28",
            "principal": "100.00",
            "profit": "0.00",
            "amount": "100.00"
          },
          {
            "seq": 3,
            "due_date": "2027-03-31",
            "principal": "100.00",
            "profit": "0.00",
            "amount": "100.00"
          },
          {
            "seq": 4,
            "due_date": "2027-04-30",
            "principal": "100.00",
            "profit": "0.00",
            "amount": "100.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-08",
      "title": "Default first due date on the 31st clamps to the 30th",
      "today": "2026-10-31",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "900.00",
        "down_payment": "0.00",
        "installments_count": 3,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "900.00",
        "down_payment": "0.00",
        "financed_amount": "900.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "900.00",
        "installments_count": 3,
        "frequency": "monthly",
        "duration_months": 3,
        "installment_amount": "300.00",
        "last_installment_amount": "300.00",
        "first_due_date": "2026-11-30",
        "last_due_date": "2027-01-30",
        "min_down_payment": "0.00",
        "max_down_payment": "899.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-30",
            "principal": "300.00",
            "profit": "0.00",
            "amount": "300.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-30",
            "principal": "300.00",
            "profit": "0.00",
            "amount": "300.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-30",
            "principal": "300.00",
            "profit": "0.00",
            "amount": "300.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-09",
      "title": "Leap year: first due 31 Dec 2027, Feb 2028 has 29 days",
      "today": "2027-12-01",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "300.00",
        "down_payment": "0.00",
        "installments_count": 3,
        "frequency": "monthly",
        "first_due_date": "2027-12-31"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "300.00",
        "down_payment": "0.00",
        "financed_amount": "300.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "300.00",
        "installments_count": 3,
        "frequency": "monthly",
        "duration_months": 3,
        "installment_amount": "100.00",
        "last_installment_amount": "100.00",
        "first_due_date": "2027-12-31",
        "last_due_date": "2028-02-29",
        "min_down_payment": "0.00",
        "max_down_payment": "299.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2027-12-31",
            "principal": "100.00",
            "profit": "0.00",
            "amount": "100.00"
          },
          {
            "seq": 2,
            "due_date": "2028-01-31",
            "principal": "100.00",
            "profit": "0.00",
            "amount": "100.00"
          },
          {
            "seq": 3,
            "due_date": "2028-02-29",
            "principal": "100.00",
            "profit": "0.00",
            "amount": "100.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-10",
      "title": "Weekly x 10 = 3 months for the tier",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "2000.00",
        "down_payment": "500.00",
        "installments_count": 10,
        "frequency": "weekly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "2000.00",
        "down_payment": "500.00",
        "financed_amount": "1500.00",
        "markup_pct": "10",
        "markup_amount": "150.00",
        "total_payable": "1650.00",
        "installments_count": 10,
        "frequency": "weekly",
        "duration_months": 3,
        "installment_amount": "165.00",
        "last_installment_amount": "165.00",
        "first_due_date": "2026-10-22",
        "last_due_date": "2026-12-24",
        "min_down_payment": "0.00",
        "max_down_payment": "1999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-22",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 2,
            "due_date": "2026-10-29",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 3,
            "due_date": "2026-11-05",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 4,
            "due_date": "2026-11-12",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 5,
            "due_date": "2026-11-19",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 6,
            "due_date": "2026-11-26",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 7,
            "due_date": "2026-12-03",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 8,
            "due_date": "2026-12-10",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 9,
            "due_date": "2026-12-17",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          },
          {
            "seq": 10,
            "due_date": "2026-12-24",
            "principal": "150.00",
            "profit": "15.00",
            "amount": "165.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-11",
      "title": "Daily x 45 = 2 months for the tier",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "4500.00",
        "down_payment": "0.00",
        "installments_count": 45,
        "frequency": "daily"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "4500.00",
        "down_payment": "0.00",
        "financed_amount": "4500.00",
        "markup_pct": "10",
        "markup_amount": "450.00",
        "total_payable": "4950.00",
        "installments_count": 45,
        "frequency": "daily",
        "duration_months": 2,
        "installment_amount": "110.00",
        "last_installment_amount": "110.00",
        "first_due_date": "2026-10-16",
        "last_due_date": "2026-11-29",
        "min_down_payment": "0.00",
        "max_down_payment": "4499.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-16",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 2,
            "due_date": "2026-10-17",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 3,
            "due_date": "2026-10-18",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 4,
            "due_date": "2026-10-19",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 5,
            "due_date": "2026-10-20",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 6,
            "due_date": "2026-10-21",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 7,
            "due_date": "2026-10-22",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 8,
            "due_date": "2026-10-23",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 9,
            "due_date": "2026-10-24",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 10,
            "due_date": "2026-10-25",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 11,
            "due_date": "2026-10-26",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 12,
            "due_date": "2026-10-27",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 13,
            "due_date": "2026-10-28",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 14,
            "due_date": "2026-10-29",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 15,
            "due_date": "2026-10-30",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 16,
            "due_date": "2026-10-31",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 17,
            "due_date": "2026-11-01",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 18,
            "due_date": "2026-11-02",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 19,
            "due_date": "2026-11-03",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 20,
            "due_date": "2026-11-04",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 21,
            "due_date": "2026-11-05",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 22,
            "due_date": "2026-11-06",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 23,
            "due_date": "2026-11-07",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 24,
            "due_date": "2026-11-08",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 25,
            "due_date": "2026-11-09",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 26,
            "due_date": "2026-11-10",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 27,
            "due_date": "2026-11-11",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 28,
            "due_date": "2026-11-12",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 29,
            "due_date": "2026-11-13",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 30,
            "due_date": "2026-11-14",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 31,
            "due_date": "2026-11-15",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 32,
            "due_date": "2026-11-16",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 33,
            "due_date": "2026-11-17",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 34,
            "due_date": "2026-11-18",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 35,
            "due_date": "2026-11-19",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 36,
            "due_date": "2026-11-20",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 37,
            "due_date": "2026-11-21",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 38,
            "due_date": "2026-11-22",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 39,
            "due_date": "2026-11-23",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 40,
            "due_date": "2026-11-24",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 41,
            "due_date": "2026-11-25",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 42,
            "due_date": "2026-11-26",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 43,
            "due_date": "2026-11-27",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 44,
            "due_date": "2026-11-28",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          },
          {
            "seq": 45,
            "due_date": "2026-11-29",
            "principal": "100.00",
            "profit": "10.00",
            "amount": "110.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-12",
      "title": "One installment: the total, no rounding",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "10.00"
      },
      "input": {
        "cash_price": "1234.56",
        "down_payment": "234.56",
        "installments_count": 1,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1234.56",
        "down_payment": "234.56",
        "financed_amount": "1000.00",
        "markup_pct": "10",
        "markup_amount": "100.00",
        "total_payable": "1100.00",
        "installments_count": 1,
        "frequency": "monthly",
        "duration_months": 1,
        "installment_amount": "1100.00",
        "last_installment_amount": "1100.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2026-11-15",
        "min_down_payment": "0.00",
        "max_down_payment": "1234.55",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "1000.00",
            "profit": "100.00",
            "amount": "1100.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-13",
      "title": "Rounding violation: step 50 over 10 installments of a 100 total",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "50.00"
      },
      "input": {
        "cash_price": "100.00",
        "down_payment": "0.00",
        "installments_count": 10,
        "frequency": "weekly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "100.00",
        "down_payment": "0.00",
        "financed_amount": "100.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "100.00",
        "installments_count": 10,
        "frequency": "weekly",
        "duration_months": 3,
        "installment_amount": "50.00",
        "last_installment_amount": null,
        "first_due_date": "2026-10-22",
        "last_due_date": "2026-12-24",
        "min_down_payment": "0.00",
        "max_down_payment": "99.99",
        "max_months_allowed": 24,
        "lines": [],
        "violations": [
          {
            "rule": "rounding",
            "rounding_step": "50.00"
          }
        ]
      }
    },
    {
      "id": "N01-14",
      "title": "Frequency not allowed",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 4,
        "frequency": "weekly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 4,
        "frequency": "weekly",
        "duration_months": 1,
        "installment_amount": "250.00",
        "last_installment_amount": "250.00",
        "first_due_date": "2026-10-22",
        "last_due_date": "2026-11-12",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-22",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          },
          {
            "seq": 2,
            "due_date": "2026-10-29",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          },
          {
            "seq": 3,
            "due_date": "2026-11-05",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          },
          {
            "seq": 4,
            "due_date": "2026-11-12",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          }
        ],
        "violations": [
          {
            "rule": "frequency_not_allowed",
            "allowed": [
              "monthly"
            ]
          }
        ]
      }
    },
    {
      "id": "N01-15",
      "title": "Sale below the minimum",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "1500.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 4,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 4,
        "frequency": "monthly",
        "duration_months": 4,
        "installment_amount": "250.00",
        "last_installment_amount": "250.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-02-15",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "250.00",
            "profit": "0.00",
            "amount": "250.00"
          }
        ],
        "violations": [
          {
            "rule": "sale_below_minimum",
            "min_sale_amount": "1500.00"
          }
        ]
      }
    },
    {
      "id": "N01-16",
      "title": "Down payment equal to the cash price",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "1000.00",
        "installments_count": 4,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "1000.00",
        "financed_amount": "0.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "0.00",
        "installments_count": 4,
        "frequency": "monthly",
        "duration_months": 4,
        "installment_amount": null,
        "last_installment_amount": null,
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-02-15",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [],
        "violations": [
          {
            "rule": "down_payment_too_high",
            "max_down_payment": "999.99"
          }
        ]
      }
    },
    {
      "id": "N01-17",
      "title": "Down payment above the max %",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": "50",
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "500.01",
        "installments_count": 4,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "500.01",
        "financed_amount": "499.99",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "499.99",
        "installments_count": 4,
        "frequency": "monthly",
        "duration_months": 4,
        "installment_amount": "125.00",
        "last_installment_amount": "124.99",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-02-15",
        "min_down_payment": "0.00",
        "max_down_payment": "500.00",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "125.00",
            "profit": "0.00",
            "amount": "125.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "125.00",
            "profit": "0.00",
            "amount": "125.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "125.00",
            "profit": "0.00",
            "amount": "125.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "124.99",
            "profit": "0.00",
            "amount": "124.99"
          }
        ],
        "violations": [
          {
            "rule": "down_payment_too_high",
            "max_down_payment": "500.00"
          }
        ]
      }
    },
    {
      "id": "N01-18",
      "title": "Down payment at the max % passes",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": "50",
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "500.00",
        "installments_count": 4,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "500.00",
        "financed_amount": "500.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "500.00",
        "installments_count": 4,
        "frequency": "monthly",
        "duration_months": 4,
        "installment_amount": "125.00",
        "last_installment_amount": "125.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-02-15",
        "min_down_payment": "0.00",
        "max_down_payment": "500.00",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "125.00",
            "profit": "0.00",
            "amount": "125.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "125.00",
            "profit": "0.00",
            "amount": "125.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "125.00",
            "profit": "0.00",
            "amount": "125.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "125.00",
            "profit": "0.00",
            "amount": "125.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-19",
      "title": "Percent rule: one piaster below the minimum",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "15",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "999.99",
        "down_payment": "149.99",
        "installments_count": 6,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "999.99",
        "down_payment": "149.99",
        "financed_amount": "850.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "850.00",
        "installments_count": 6,
        "frequency": "monthly",
        "duration_months": 6,
        "installment_amount": "141.67",
        "last_installment_amount": "141.65",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-04-15",
        "min_down_payment": "150.00",
        "max_down_payment": "999.98",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "141.65",
            "profit": "0.00",
            "amount": "141.65"
          }
        ],
        "violations": [
          {
            "rule": "down_payment_too_low",
            "min_down_payment": "150.00",
            "down_payment_rule": "percent"
          }
        ]
      }
    },
    {
      "id": "N01-20",
      "title": "Percent rule: at the minimum (half-up)",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "15",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "999.99",
        "down_payment": "150.00",
        "installments_count": 6,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "999.99",
        "down_payment": "150.00",
        "financed_amount": "849.99",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "849.99",
        "installments_count": 6,
        "frequency": "monthly",
        "duration_months": 6,
        "installment_amount": "141.67",
        "last_installment_amount": "141.64",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-04-15",
        "min_down_payment": "150.00",
        "max_down_payment": "999.98",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "141.67",
            "profit": "0.00",
            "amount": "141.67"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "141.64",
            "profit": "0.00",
            "amount": "141.64"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-21",
      "title": "One installment up front: too low",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {
          "monthly": "one_installment"
        },
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          },
          {
            "up_to_months": 12,
            "pct": 20
          },
          {
            "up_to_months": 24,
            "pct": 32.5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "1.00"
      },
      "input": {
        "cash_price": "1200.00",
        "down_payment": "100.00",
        "installments_count": 12,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1200.00",
        "down_payment": "100.00",
        "financed_amount": "1100.00",
        "markup_pct": "20",
        "markup_amount": "220.00",
        "total_payable": "1320.00",
        "installments_count": 12,
        "frequency": "monthly",
        "duration_months": 12,
        "installment_amount": "110.00",
        "last_installment_amount": "110.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-10-15",
        "min_down_payment": "110.00",
        "max_down_payment": "1199.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "91.66",
            "profit": "18.34",
            "amount": "110.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "91.66",
            "profit": "18.34",
            "amount": "110.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "91.66",
            "profit": "18.34",
            "amount": "110.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "91.66",
            "profit": "18.34",
            "amount": "110.00"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          },
          {
            "seq": 8,
            "due_date": "2027-06-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          },
          {
            "seq": 9,
            "due_date": "2027-07-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          },
          {
            "seq": 10,
            "due_date": "2027-08-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          },
          {
            "seq": 11,
            "due_date": "2027-09-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          },
          {
            "seq": 12,
            "due_date": "2027-10-15",
            "principal": "91.67",
            "profit": "18.33",
            "amount": "110.00"
          }
        ],
        "violations": [
          {
            "rule": "down_payment_too_low",
            "min_down_payment": "110.00",
            "down_payment_rule": "one_installment"
          }
        ]
      }
    },
    {
      "id": "N01-22",
      "title": "One installment up front: exactly the minimum",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {
          "monthly": "one_installment"
        },
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 10
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "1.00"
      },
      "input": {
        "cash_price": "1200.00",
        "down_payment": "101.00",
        "installments_count": 12,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1200.00",
        "down_payment": "101.00",
        "financed_amount": "1099.00",
        "markup_pct": "10",
        "markup_amount": "109.90",
        "total_payable": "1208.90",
        "installments_count": 12,
        "frequency": "monthly",
        "duration_months": 12,
        "installment_amount": "101.00",
        "last_installment_amount": "97.90",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-10-15",
        "min_down_payment": "101.00",
        "max_down_payment": "1199.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "91.81",
            "profit": "9.19",
            "amount": "101.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "91.81",
            "profit": "9.19",
            "amount": "101.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 8,
            "due_date": "2027-06-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 9,
            "due_date": "2027-07-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 10,
            "due_date": "2027-08-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 11,
            "due_date": "2027-09-15",
            "principal": "91.82",
            "profit": "9.18",
            "amount": "101.00"
          },
          {
            "seq": 12,
            "due_date": "2027-10-15",
            "principal": "89.00",
            "profit": "8.90",
            "amount": "97.90"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-23",
      "title": "One installment per day of the month so far (the 10th)",
      "today": "2026-10-10",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {
          "daily": "installment_per_day_of_month"
        },
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "1.00"
      },
      "input": {
        "cash_price": "3000.00",
        "down_payment": "600.00",
        "installments_count": 60,
        "frequency": "daily"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "3000.00",
        "down_payment": "600.00",
        "financed_amount": "2400.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "2400.00",
        "installments_count": 60,
        "frequency": "daily",
        "duration_months": 2,
        "installment_amount": "40.00",
        "last_installment_amount": "40.00",
        "first_due_date": "2026-10-11",
        "last_due_date": "2026-12-09",
        "min_down_payment": "430.00",
        "max_down_payment": "2999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-11",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 2,
            "due_date": "2026-10-12",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 3,
            "due_date": "2026-10-13",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 4,
            "due_date": "2026-10-14",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 5,
            "due_date": "2026-10-15",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 6,
            "due_date": "2026-10-16",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 7,
            "due_date": "2026-10-17",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 8,
            "due_date": "2026-10-18",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 9,
            "due_date": "2026-10-19",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 10,
            "due_date": "2026-10-20",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 11,
            "due_date": "2026-10-21",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 12,
            "due_date": "2026-10-22",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 13,
            "due_date": "2026-10-23",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 14,
            "due_date": "2026-10-24",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 15,
            "due_date": "2026-10-25",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 16,
            "due_date": "2026-10-26",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 17,
            "due_date": "2026-10-27",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 18,
            "due_date": "2026-10-28",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 19,
            "due_date": "2026-10-29",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 20,
            "due_date": "2026-10-30",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 21,
            "due_date": "2026-10-31",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 22,
            "due_date": "2026-11-01",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 23,
            "due_date": "2026-11-02",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 24,
            "due_date": "2026-11-03",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 25,
            "due_date": "2026-11-04",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 26,
            "due_date": "2026-11-05",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 27,
            "due_date": "2026-11-06",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 28,
            "due_date": "2026-11-07",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 29,
            "due_date": "2026-11-08",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 30,
            "due_date": "2026-11-09",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 31,
            "due_date": "2026-11-10",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 32,
            "due_date": "2026-11-11",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 33,
            "due_date": "2026-11-12",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 34,
            "due_date": "2026-11-13",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 35,
            "due_date": "2026-11-14",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 36,
            "due_date": "2026-11-15",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 37,
            "due_date": "2026-11-16",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 38,
            "due_date": "2026-11-17",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 39,
            "due_date": "2026-11-18",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 40,
            "due_date": "2026-11-19",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 41,
            "due_date": "2026-11-20",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 42,
            "due_date": "2026-11-21",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 43,
            "due_date": "2026-11-22",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 44,
            "due_date": "2026-11-23",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 45,
            "due_date": "2026-11-24",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 46,
            "due_date": "2026-11-25",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 47,
            "due_date": "2026-11-26",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 48,
            "due_date": "2026-11-27",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 49,
            "due_date": "2026-11-28",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 50,
            "due_date": "2026-11-29",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 51,
            "due_date": "2026-11-30",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 52,
            "due_date": "2026-12-01",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 53,
            "due_date": "2026-12-02",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 54,
            "due_date": "2026-12-03",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 55,
            "due_date": "2026-12-04",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 56,
            "due_date": "2026-12-05",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 57,
            "due_date": "2026-12-06",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 58,
            "due_date": "2026-12-07",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 59,
            "due_date": "2026-12-08",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          },
          {
            "seq": 60,
            "due_date": "2026-12-09",
            "principal": "40.00",
            "profit": "0.00",
            "amount": "40.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-24",
      "title": "One installment per day of the month: too low",
      "today": "2026-10-10",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {
          "daily": "installment_per_day_of_month"
        },
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "1.00"
      },
      "input": {
        "cash_price": "3000.00",
        "down_payment": "400.00",
        "installments_count": 60,
        "frequency": "daily"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "3000.00",
        "down_payment": "400.00",
        "financed_amount": "2600.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "2600.00",
        "installments_count": 60,
        "frequency": "daily",
        "duration_months": 2,
        "installment_amount": "44.00",
        "last_installment_amount": "4.00",
        "first_due_date": "2026-10-11",
        "last_due_date": "2026-12-09",
        "min_down_payment": "430.00",
        "max_down_payment": "2999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-11",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 2,
            "due_date": "2026-10-12",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 3,
            "due_date": "2026-10-13",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 4,
            "due_date": "2026-10-14",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 5,
            "due_date": "2026-10-15",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 6,
            "due_date": "2026-10-16",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 7,
            "due_date": "2026-10-17",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 8,
            "due_date": "2026-10-18",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 9,
            "due_date": "2026-10-19",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 10,
            "due_date": "2026-10-20",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 11,
            "due_date": "2026-10-21",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 12,
            "due_date": "2026-10-22",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 13,
            "due_date": "2026-10-23",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 14,
            "due_date": "2026-10-24",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 15,
            "due_date": "2026-10-25",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 16,
            "due_date": "2026-10-26",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 17,
            "due_date": "2026-10-27",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 18,
            "due_date": "2026-10-28",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 19,
            "due_date": "2026-10-29",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 20,
            "due_date": "2026-10-30",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 21,
            "due_date": "2026-10-31",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 22,
            "due_date": "2026-11-01",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 23,
            "due_date": "2026-11-02",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 24,
            "due_date": "2026-11-03",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 25,
            "due_date": "2026-11-04",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 26,
            "due_date": "2026-11-05",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 27,
            "due_date": "2026-11-06",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 28,
            "due_date": "2026-11-07",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 29,
            "due_date": "2026-11-08",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 30,
            "due_date": "2026-11-09",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 31,
            "due_date": "2026-11-10",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 32,
            "due_date": "2026-11-11",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 33,
            "due_date": "2026-11-12",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 34,
            "due_date": "2026-11-13",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 35,
            "due_date": "2026-11-14",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 36,
            "due_date": "2026-11-15",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 37,
            "due_date": "2026-11-16",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 38,
            "due_date": "2026-11-17",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 39,
            "due_date": "2026-11-18",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 40,
            "due_date": "2026-11-19",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 41,
            "due_date": "2026-11-20",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 42,
            "due_date": "2026-11-21",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 43,
            "due_date": "2026-11-22",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 44,
            "due_date": "2026-11-23",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 45,
            "due_date": "2026-11-24",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 46,
            "due_date": "2026-11-25",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 47,
            "due_date": "2026-11-26",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 48,
            "due_date": "2026-11-27",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 49,
            "due_date": "2026-11-28",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 50,
            "due_date": "2026-11-29",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 51,
            "due_date": "2026-11-30",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 52,
            "due_date": "2026-12-01",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 53,
            "due_date": "2026-12-02",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 54,
            "due_date": "2026-12-03",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 55,
            "due_date": "2026-12-04",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 56,
            "due_date": "2026-12-05",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 57,
            "due_date": "2026-12-06",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 58,
            "due_date": "2026-12-07",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 59,
            "due_date": "2026-12-08",
            "principal": "44.00",
            "profit": "0.00",
            "amount": "44.00"
          },
          {
            "seq": 60,
            "due_date": "2026-12-09",
            "principal": "4.00",
            "profit": "0.00",
            "amount": "4.00"
          }
        ],
        "violations": [
          {
            "rule": "down_payment_too_low",
            "min_down_payment": "430.00",
            "down_payment_rule": "installment_per_day_of_month"
          }
        ]
      }
    },
    {
      "id": "N01-25",
      "title": "Too many months for max_months",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 12,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 12,
            "pct": 5
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "5000.00",
        "down_payment": "0.00",
        "installments_count": 13,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "5000.00",
        "down_payment": "0.00",
        "financed_amount": "5000.00",
        "markup_pct": "5",
        "markup_amount": "250.00",
        "total_payable": "5250.00",
        "installments_count": 13,
        "frequency": "monthly",
        "duration_months": 13,
        "installment_amount": "403.85",
        "last_installment_amount": "403.80",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-11-15",
        "min_down_payment": "0.00",
        "max_down_payment": "4999.99",
        "max_months_allowed": 12,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "384.61",
            "profit": "19.24",
            "amount": "403.85"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 8,
            "due_date": "2027-06-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 9,
            "due_date": "2027-07-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 10,
            "due_date": "2027-08-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 11,
            "due_date": "2027-09-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 12,
            "due_date": "2027-10-15",
            "principal": "384.62",
            "profit": "19.23",
            "amount": "403.85"
          },
          {
            "seq": 13,
            "due_date": "2027-11-15",
            "principal": "384.57",
            "profit": "19.23",
            "amount": "403.80"
          }
        ],
        "violations": [
          {
            "rule": "too_many_months",
            "max_months": 12,
            "duration_months": 13
          }
        ]
      }
    },
    {
      "id": "N01-26",
      "title": "Too many months for the amount tier",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [
          {
            "up_to_amount": "10000.00",
            "max_months": 6
          },
          {
            "up_to_amount": "100000.00",
            "max_months": 12
          }
        ],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "8000.00",
        "down_payment": "0.00",
        "installments_count": 7,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "8000.00",
        "down_payment": "0.00",
        "financed_amount": "8000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "8000.00",
        "installments_count": 7,
        "frequency": "monthly",
        "duration_months": 7,
        "installment_amount": "1142.86",
        "last_installment_amount": "1142.84",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-05-15",
        "min_down_payment": "0.00",
        "max_down_payment": "7999.99",
        "max_months_allowed": 6,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "1142.86",
            "profit": "0.00",
            "amount": "1142.86"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "1142.86",
            "profit": "0.00",
            "amount": "1142.86"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "1142.86",
            "profit": "0.00",
            "amount": "1142.86"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "1142.86",
            "profit": "0.00",
            "amount": "1142.86"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "1142.86",
            "profit": "0.00",
            "amount": "1142.86"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "1142.86",
            "profit": "0.00",
            "amount": "1142.86"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "1142.84",
            "profit": "0.00",
            "amount": "1142.84"
          }
        ],
        "violations": [
          {
            "rule": "too_many_months",
            "max_months": 6,
            "duration_months": 7
          }
        ]
      }
    },
    {
      "id": "N01-27",
      "title": "Above every amount tier: max_months applies",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [
          {
            "up_to_amount": "10000.00",
            "max_months": 6
          }
        ],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "50000.00",
        "down_payment": "0.00",
        "installments_count": 18,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "50000.00",
        "down_payment": "0.00",
        "financed_amount": "50000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "50000.00",
        "installments_count": 18,
        "frequency": "monthly",
        "duration_months": 18,
        "installment_amount": "2777.78",
        "last_installment_amount": "2777.74",
        "first_due_date": "2026-11-15",
        "last_due_date": "2028-04-15",
        "min_down_payment": "0.00",
        "max_down_payment": "49999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 8,
            "due_date": "2027-06-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 9,
            "due_date": "2027-07-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 10,
            "due_date": "2027-08-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 11,
            "due_date": "2027-09-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 12,
            "due_date": "2027-10-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 13,
            "due_date": "2027-11-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 14,
            "due_date": "2027-12-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 15,
            "due_date": "2028-01-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 16,
            "due_date": "2028-02-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 17,
            "due_date": "2028-03-15",
            "principal": "2777.78",
            "profit": "0.00",
            "amount": "2777.78"
          },
          {
            "seq": 18,
            "due_date": "2028-04-15",
            "principal": "2777.74",
            "profit": "0.00",
            "amount": "2777.74"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-28",
      "title": "Installment below the frequency minimum",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "100.00",
        "min_installment_by_frequency": {
          "weekly": "250.00"
        },
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "2000.00",
        "down_payment": "0.00",
        "installments_count": 10,
        "frequency": "weekly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "2000.00",
        "down_payment": "0.00",
        "financed_amount": "2000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "2000.00",
        "installments_count": 10,
        "frequency": "weekly",
        "duration_months": 3,
        "installment_amount": "200.00",
        "last_installment_amount": "200.00",
        "first_due_date": "2026-10-22",
        "last_due_date": "2026-12-24",
        "min_down_payment": "0.00",
        "max_down_payment": "1999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-22",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 2,
            "due_date": "2026-10-29",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 3,
            "due_date": "2026-11-05",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 4,
            "due_date": "2026-11-12",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 5,
            "due_date": "2026-11-19",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 6,
            "due_date": "2026-11-26",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 7,
            "due_date": "2026-12-03",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 8,
            "due_date": "2026-12-10",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 9,
            "due_date": "2026-12-17",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          },
          {
            "seq": 10,
            "due_date": "2026-12-24",
            "principal": "200.00",
            "profit": "0.00",
            "amount": "200.00"
          }
        ],
        "violations": [
          {
            "rule": "installment_below_minimum",
            "min_installment": "250.00"
          }
        ]
      }
    },
    {
      "id": "N01-29",
      "title": "The smaller last line may be below the minimum",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "300.00",
        "min_installment_by_frequency": {},
        "rounding_step": "50.00"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 3,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 3,
        "frequency": "monthly",
        "duration_months": 3,
        "installment_amount": "350.00",
        "last_installment_amount": "300.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-01-15",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "350.00",
            "profit": "0.00",
            "amount": "350.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "350.00",
            "profit": "0.00",
            "amount": "350.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "300.00",
            "profit": "0.00",
            "amount": "300.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-30",
      "title": "First due date today: out of range",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 2,
        "frequency": "monthly",
        "first_due_date": "2026-10-15"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 2,
        "frequency": "monthly",
        "duration_months": 2,
        "installment_amount": "500.00",
        "last_installment_amount": "500.00",
        "first_due_date": "2026-10-15",
        "last_due_date": "2026-11-15",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-15",
            "principal": "500.00",
            "profit": "0.00",
            "amount": "500.00"
          },
          {
            "seq": 2,
            "due_date": "2026-11-15",
            "principal": "500.00",
            "profit": "0.00",
            "amount": "500.00"
          }
        ],
        "violations": [
          {
            "rule": "first_due_date_out_of_range",
            "earliest": "2026-10-16",
            "latest": "2026-12-14"
          }
        ]
      }
    },
    {
      "id": "N01-31",
      "title": "First due date 61 days out: out of range",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 2,
        "frequency": "monthly",
        "first_due_date": "2026-12-15"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 2,
        "frequency": "monthly",
        "duration_months": 2,
        "installment_amount": "500.00",
        "last_installment_amount": "500.00",
        "first_due_date": "2026-12-15",
        "last_due_date": "2027-01-15",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-12-15",
            "principal": "500.00",
            "profit": "0.00",
            "amount": "500.00"
          },
          {
            "seq": 2,
            "due_date": "2027-01-15",
            "principal": "500.00",
            "profit": "0.00",
            "amount": "500.00"
          }
        ],
        "violations": [
          {
            "rule": "first_due_date_out_of_range",
            "earliest": "2026-10-16",
            "latest": "2026-12-14"
          }
        ]
      }
    },
    {
      "id": "N01-32",
      "title": "First due date 60 days out passes",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 0
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 2,
        "frequency": "monthly",
        "first_due_date": "2026-12-14"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "0",
        "markup_amount": "0.00",
        "total_payable": "1000.00",
        "installments_count": 2,
        "frequency": "monthly",
        "duration_months": 2,
        "installment_amount": "500.00",
        "last_installment_amount": "500.00",
        "first_due_date": "2026-12-14",
        "last_due_date": "2027-01-14",
        "min_down_payment": "0.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-12-14",
            "principal": "500.00",
            "profit": "0.00",
            "amount": "500.00"
          },
          {
            "seq": 2,
            "due_date": "2027-01-14",
            "principal": "500.00",
            "profit": "0.00",
            "amount": "500.00"
          }
        ],
        "violations": []
      }
    },
    {
      "id": "N01-33",
      "title": "Several violations at once, in order",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "20",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 6,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 6,
            "pct": 10
          }
        ],
        "allowed_frequencies": [
          "monthly"
        ],
        "min_sale_amount": "5000.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "installments_count": 30,
        "frequency": "weekly",
        "first_due_date": "2027-01-01"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "1000.00",
        "down_payment": "0.00",
        "financed_amount": "1000.00",
        "markup_pct": "10",
        "markup_amount": "100.00",
        "total_payable": "1100.00",
        "installments_count": 30,
        "frequency": "weekly",
        "duration_months": 7,
        "installment_amount": "36.67",
        "last_installment_amount": "36.57",
        "first_due_date": "2027-01-01",
        "last_due_date": "2027-07-23",
        "min_down_payment": "200.00",
        "max_down_payment": "999.99",
        "max_months_allowed": 6,
        "lines": [
          {
            "seq": 1,
            "due_date": "2027-01-01",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 2,
            "due_date": "2027-01-08",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 4,
            "due_date": "2027-01-22",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 5,
            "due_date": "2027-01-29",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 6,
            "due_date": "2027-02-05",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 7,
            "due_date": "2027-02-12",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 8,
            "due_date": "2027-02-19",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 9,
            "due_date": "2027-02-26",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 10,
            "due_date": "2027-03-05",
            "principal": "33.33",
            "profit": "3.34",
            "amount": "36.67"
          },
          {
            "seq": 11,
            "due_date": "2027-03-12",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 12,
            "due_date": "2027-03-19",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 13,
            "due_date": "2027-03-26",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 14,
            "due_date": "2027-04-02",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 15,
            "due_date": "2027-04-09",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 16,
            "due_date": "2027-04-16",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 17,
            "due_date": "2027-04-23",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 18,
            "due_date": "2027-04-30",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 19,
            "due_date": "2027-05-07",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 20,
            "due_date": "2027-05-14",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 21,
            "due_date": "2027-05-21",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 22,
            "due_date": "2027-05-28",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 23,
            "due_date": "2027-06-04",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 24,
            "due_date": "2027-06-11",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 25,
            "due_date": "2027-06-18",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 26,
            "due_date": "2027-06-25",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 27,
            "due_date": "2027-07-02",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 28,
            "due_date": "2027-07-09",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 29,
            "due_date": "2027-07-16",
            "principal": "33.34",
            "profit": "3.33",
            "amount": "36.67"
          },
          {
            "seq": 30,
            "due_date": "2027-07-23",
            "principal": "33.24",
            "profit": "3.33",
            "amount": "36.57"
          }
        ],
        "violations": [
          {
            "rule": "frequency_not_allowed",
            "allowed": [
              "monthly"
            ]
          },
          {
            "rule": "sale_below_minimum",
            "min_sale_amount": "5000.00"
          },
          {
            "rule": "down_payment_too_low",
            "min_down_payment": "200.00",
            "down_payment_rule": "percent"
          },
          {
            "rule": "too_many_months",
            "max_months": 6,
            "duration_months": 7
          },
          {
            "rule": "first_due_date_out_of_range",
            "earliest": "2026-10-16",
            "latest": "2026-12-14"
          }
        ]
      }
    },
    {
      "id": "N01-34",
      "title": "520 weekly installments (the most a contract holds) last 122 months: too many for 120",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 120,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 120,
            "pct": 60
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "1.00"
      },
      "input": {
        "cash_price": "250000.00",
        "down_payment": "0.00",
        "installments_count": 520,
        "frequency": "weekly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "250000.00",
        "down_payment": "0.00",
        "financed_amount": "250000.00",
        "markup_pct": "60",
        "markup_amount": "150000.00",
        "total_payable": "400000.00",
        "installments_count": 520,
        "frequency": "weekly",
        "duration_months": 122,
        "installment_amount": "770.00",
        "last_installment_amount": "370.00",
        "first_due_date": "2026-10-22",
        "last_due_date": "2036-10-02",
        "min_down_payment": "0.00",
        "max_down_payment": "249999.99",
        "max_months_allowed": 120,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-10-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 2,
            "due_date": "2026-10-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 3,
            "due_date": "2026-11-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 4,
            "due_date": "2026-11-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 5,
            "due_date": "2026-11-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 6,
            "due_date": "2026-11-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 7,
            "due_date": "2026-12-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 8,
            "due_date": "2026-12-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 9,
            "due_date": "2026-12-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 10,
            "due_date": "2026-12-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 11,
            "due_date": "2026-12-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 12,
            "due_date": "2027-01-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 13,
            "due_date": "2027-01-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 14,
            "due_date": "2027-01-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 15,
            "due_date": "2027-01-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 16,
            "due_date": "2027-02-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 17,
            "due_date": "2027-02-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 18,
            "due_date": "2027-02-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 19,
            "due_date": "2027-02-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 20,
            "due_date": "2027-03-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 21,
            "due_date": "2027-03-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 22,
            "due_date": "2027-03-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 23,
            "due_date": "2027-03-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 24,
            "due_date": "2027-04-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 25,
            "due_date": "2027-04-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 26,
            "due_date": "2027-04-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 27,
            "due_date": "2027-04-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 28,
            "due_date": "2027-04-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 29,
            "due_date": "2027-05-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 30,
            "due_date": "2027-05-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 31,
            "due_date": "2027-05-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 32,
            "due_date": "2027-05-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 33,
            "due_date": "2027-06-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 34,
            "due_date": "2027-06-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 35,
            "due_date": "2027-06-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 36,
            "due_date": "2027-06-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 37,
            "due_date": "2027-07-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 38,
            "due_date": "2027-07-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 39,
            "due_date": "2027-07-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 40,
            "due_date": "2027-07-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 41,
            "due_date": "2027-07-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 42,
            "due_date": "2027-08-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 43,
            "due_date": "2027-08-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 44,
            "due_date": "2027-08-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 45,
            "due_date": "2027-08-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 46,
            "due_date": "2027-09-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 47,
            "due_date": "2027-09-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 48,
            "due_date": "2027-09-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 49,
            "due_date": "2027-09-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 50,
            "due_date": "2027-09-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 51,
            "due_date": "2027-10-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 52,
            "due_date": "2027-10-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 53,
            "due_date": "2027-10-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 54,
            "due_date": "2027-10-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 55,
            "due_date": "2027-11-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 56,
            "due_date": "2027-11-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 57,
            "due_date": "2027-11-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 58,
            "due_date": "2027-11-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 59,
            "due_date": "2027-12-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 60,
            "due_date": "2027-12-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 61,
            "due_date": "2027-12-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 62,
            "due_date": "2027-12-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 63,
            "due_date": "2027-12-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 64,
            "due_date": "2028-01-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 65,
            "due_date": "2028-01-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 66,
            "due_date": "2028-01-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 67,
            "due_date": "2028-01-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 68,
            "due_date": "2028-02-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 69,
            "due_date": "2028-02-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 70,
            "due_date": "2028-02-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 71,
            "due_date": "2028-02-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 72,
            "due_date": "2028-03-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 73,
            "due_date": "2028-03-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 74,
            "due_date": "2028-03-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 75,
            "due_date": "2028-03-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 76,
            "due_date": "2028-03-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 77,
            "due_date": "2028-04-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 78,
            "due_date": "2028-04-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 79,
            "due_date": "2028-04-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 80,
            "due_date": "2028-04-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 81,
            "due_date": "2028-05-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 82,
            "due_date": "2028-05-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 83,
            "due_date": "2028-05-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 84,
            "due_date": "2028-05-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 85,
            "due_date": "2028-06-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 86,
            "due_date": "2028-06-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 87,
            "due_date": "2028-06-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 88,
            "due_date": "2028-06-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 89,
            "due_date": "2028-06-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 90,
            "due_date": "2028-07-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 91,
            "due_date": "2028-07-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 92,
            "due_date": "2028-07-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 93,
            "due_date": "2028-07-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 94,
            "due_date": "2028-08-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 95,
            "due_date": "2028-08-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 96,
            "due_date": "2028-08-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 97,
            "due_date": "2028-08-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 98,
            "due_date": "2028-08-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 99,
            "due_date": "2028-09-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 100,
            "due_date": "2028-09-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 101,
            "due_date": "2028-09-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 102,
            "due_date": "2028-09-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 103,
            "due_date": "2028-10-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 104,
            "due_date": "2028-10-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 105,
            "due_date": "2028-10-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 106,
            "due_date": "2028-10-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 107,
            "due_date": "2028-11-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 108,
            "due_date": "2028-11-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 109,
            "due_date": "2028-11-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 110,
            "due_date": "2028-11-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 111,
            "due_date": "2028-11-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 112,
            "due_date": "2028-12-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 113,
            "due_date": "2028-12-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 114,
            "due_date": "2028-12-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 115,
            "due_date": "2028-12-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 116,
            "due_date": "2029-01-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 117,
            "due_date": "2029-01-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 118,
            "due_date": "2029-01-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 119,
            "due_date": "2029-01-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 120,
            "due_date": "2029-02-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 121,
            "due_date": "2029-02-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 122,
            "due_date": "2029-02-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 123,
            "due_date": "2029-02-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 124,
            "due_date": "2029-03-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 125,
            "due_date": "2029-03-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 126,
            "due_date": "2029-03-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 127,
            "due_date": "2029-03-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 128,
            "due_date": "2029-03-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 129,
            "due_date": "2029-04-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 130,
            "due_date": "2029-04-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 131,
            "due_date": "2029-04-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 132,
            "due_date": "2029-04-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 133,
            "due_date": "2029-05-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 134,
            "due_date": "2029-05-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 135,
            "due_date": "2029-05-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 136,
            "due_date": "2029-05-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 137,
            "due_date": "2029-05-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 138,
            "due_date": "2029-06-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 139,
            "due_date": "2029-06-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 140,
            "due_date": "2029-06-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 141,
            "due_date": "2029-06-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 142,
            "due_date": "2029-07-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 143,
            "due_date": "2029-07-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 144,
            "due_date": "2029-07-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 145,
            "due_date": "2029-07-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 146,
            "due_date": "2029-08-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 147,
            "due_date": "2029-08-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 148,
            "due_date": "2029-08-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 149,
            "due_date": "2029-08-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 150,
            "due_date": "2029-08-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 151,
            "due_date": "2029-09-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 152,
            "due_date": "2029-09-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 153,
            "due_date": "2029-09-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 154,
            "due_date": "2029-09-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 155,
            "due_date": "2029-10-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 156,
            "due_date": "2029-10-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 157,
            "due_date": "2029-10-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 158,
            "due_date": "2029-10-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 159,
            "due_date": "2029-11-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 160,
            "due_date": "2029-11-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 161,
            "due_date": "2029-11-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 162,
            "due_date": "2029-11-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 163,
            "due_date": "2029-11-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 164,
            "due_date": "2029-12-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 165,
            "due_date": "2029-12-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 166,
            "due_date": "2029-12-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 167,
            "due_date": "2029-12-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 168,
            "due_date": "2030-01-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 169,
            "due_date": "2030-01-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 170,
            "due_date": "2030-01-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 171,
            "due_date": "2030-01-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 172,
            "due_date": "2030-01-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 173,
            "due_date": "2030-02-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 174,
            "due_date": "2030-02-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 175,
            "due_date": "2030-02-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 176,
            "due_date": "2030-02-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 177,
            "due_date": "2030-03-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 178,
            "due_date": "2030-03-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 179,
            "due_date": "2030-03-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 180,
            "due_date": "2030-03-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 181,
            "due_date": "2030-04-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 182,
            "due_date": "2030-04-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 183,
            "due_date": "2030-04-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 184,
            "due_date": "2030-04-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 185,
            "due_date": "2030-05-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 186,
            "due_date": "2030-05-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 187,
            "due_date": "2030-05-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 188,
            "due_date": "2030-05-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 189,
            "due_date": "2030-05-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 190,
            "due_date": "2030-06-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 191,
            "due_date": "2030-06-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 192,
            "due_date": "2030-06-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 193,
            "due_date": "2030-06-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 194,
            "due_date": "2030-07-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 195,
            "due_date": "2030-07-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 196,
            "due_date": "2030-07-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 197,
            "due_date": "2030-07-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 198,
            "due_date": "2030-08-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 199,
            "due_date": "2030-08-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 200,
            "due_date": "2030-08-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 201,
            "due_date": "2030-08-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 202,
            "due_date": "2030-08-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 203,
            "due_date": "2030-09-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 204,
            "due_date": "2030-09-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 205,
            "due_date": "2030-09-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 206,
            "due_date": "2030-09-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 207,
            "due_date": "2030-10-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 208,
            "due_date": "2030-10-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 209,
            "due_date": "2030-10-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 210,
            "due_date": "2030-10-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 211,
            "due_date": "2030-10-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 212,
            "due_date": "2030-11-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 213,
            "due_date": "2030-11-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 214,
            "due_date": "2030-11-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 215,
            "due_date": "2030-11-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 216,
            "due_date": "2030-12-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 217,
            "due_date": "2030-12-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 218,
            "due_date": "2030-12-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 219,
            "due_date": "2030-12-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 220,
            "due_date": "2031-01-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 221,
            "due_date": "2031-01-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 222,
            "due_date": "2031-01-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 223,
            "due_date": "2031-01-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 224,
            "due_date": "2031-01-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 225,
            "due_date": "2031-02-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 226,
            "due_date": "2031-02-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 227,
            "due_date": "2031-02-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 228,
            "due_date": "2031-02-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 229,
            "due_date": "2031-03-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 230,
            "due_date": "2031-03-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 231,
            "due_date": "2031-03-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 232,
            "due_date": "2031-03-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 233,
            "due_date": "2031-04-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 234,
            "due_date": "2031-04-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 235,
            "due_date": "2031-04-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 236,
            "due_date": "2031-04-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 237,
            "due_date": "2031-05-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 238,
            "due_date": "2031-05-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 239,
            "due_date": "2031-05-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 240,
            "due_date": "2031-05-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 241,
            "due_date": "2031-05-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 242,
            "due_date": "2031-06-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 243,
            "due_date": "2031-06-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 244,
            "due_date": "2031-06-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 245,
            "due_date": "2031-06-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 246,
            "due_date": "2031-07-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 247,
            "due_date": "2031-07-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 248,
            "due_date": "2031-07-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 249,
            "due_date": "2031-07-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 250,
            "due_date": "2031-07-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 251,
            "due_date": "2031-08-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 252,
            "due_date": "2031-08-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 253,
            "due_date": "2031-08-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 254,
            "due_date": "2031-08-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 255,
            "due_date": "2031-09-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 256,
            "due_date": "2031-09-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 257,
            "due_date": "2031-09-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 258,
            "due_date": "2031-09-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 259,
            "due_date": "2031-10-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 260,
            "due_date": "2031-10-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 261,
            "due_date": "2031-10-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 262,
            "due_date": "2031-10-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 263,
            "due_date": "2031-10-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 264,
            "due_date": "2031-11-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 265,
            "due_date": "2031-11-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 266,
            "due_date": "2031-11-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 267,
            "due_date": "2031-11-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 268,
            "due_date": "2031-12-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 269,
            "due_date": "2031-12-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 270,
            "due_date": "2031-12-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 271,
            "due_date": "2031-12-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 272,
            "due_date": "2032-01-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 273,
            "due_date": "2032-01-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 274,
            "due_date": "2032-01-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 275,
            "due_date": "2032-01-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 276,
            "due_date": "2032-01-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 277,
            "due_date": "2032-02-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 278,
            "due_date": "2032-02-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 279,
            "due_date": "2032-02-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 280,
            "due_date": "2032-02-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 281,
            "due_date": "2032-03-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 282,
            "due_date": "2032-03-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 283,
            "due_date": "2032-03-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 284,
            "due_date": "2032-03-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 285,
            "due_date": "2032-04-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 286,
            "due_date": "2032-04-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 287,
            "due_date": "2032-04-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 288,
            "due_date": "2032-04-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 289,
            "due_date": "2032-04-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 290,
            "due_date": "2032-05-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 291,
            "due_date": "2032-05-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 292,
            "due_date": "2032-05-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 293,
            "due_date": "2032-05-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 294,
            "due_date": "2032-06-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 295,
            "due_date": "2032-06-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 296,
            "due_date": "2032-06-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 297,
            "due_date": "2032-06-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 298,
            "due_date": "2032-07-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 299,
            "due_date": "2032-07-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 300,
            "due_date": "2032-07-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 301,
            "due_date": "2032-07-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 302,
            "due_date": "2032-07-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 303,
            "due_date": "2032-08-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 304,
            "due_date": "2032-08-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 305,
            "due_date": "2032-08-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 306,
            "due_date": "2032-08-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 307,
            "due_date": "2032-09-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 308,
            "due_date": "2032-09-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 309,
            "due_date": "2032-09-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 310,
            "due_date": "2032-09-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 311,
            "due_date": "2032-09-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 312,
            "due_date": "2032-10-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 313,
            "due_date": "2032-10-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 314,
            "due_date": "2032-10-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 315,
            "due_date": "2032-10-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 316,
            "due_date": "2032-11-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 317,
            "due_date": "2032-11-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 318,
            "due_date": "2032-11-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 319,
            "due_date": "2032-11-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 320,
            "due_date": "2032-12-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 321,
            "due_date": "2032-12-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 322,
            "due_date": "2032-12-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 323,
            "due_date": "2032-12-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 324,
            "due_date": "2032-12-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 325,
            "due_date": "2033-01-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 326,
            "due_date": "2033-01-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 327,
            "due_date": "2033-01-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 328,
            "due_date": "2033-01-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 329,
            "due_date": "2033-02-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 330,
            "due_date": "2033-02-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 331,
            "due_date": "2033-02-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 332,
            "due_date": "2033-02-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 333,
            "due_date": "2033-03-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 334,
            "due_date": "2033-03-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 335,
            "due_date": "2033-03-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 336,
            "due_date": "2033-03-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 337,
            "due_date": "2033-03-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 338,
            "due_date": "2033-04-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 339,
            "due_date": "2033-04-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 340,
            "due_date": "2033-04-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 341,
            "due_date": "2033-04-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 342,
            "due_date": "2033-05-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 343,
            "due_date": "2033-05-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 344,
            "due_date": "2033-05-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 345,
            "due_date": "2033-05-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 346,
            "due_date": "2033-06-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 347,
            "due_date": "2033-06-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 348,
            "due_date": "2033-06-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 349,
            "due_date": "2033-06-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 350,
            "due_date": "2033-06-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 351,
            "due_date": "2033-07-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 352,
            "due_date": "2033-07-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 353,
            "due_date": "2033-07-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 354,
            "due_date": "2033-07-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 355,
            "due_date": "2033-08-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 356,
            "due_date": "2033-08-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 357,
            "due_date": "2033-08-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 358,
            "due_date": "2033-08-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 359,
            "due_date": "2033-09-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 360,
            "due_date": "2033-09-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 361,
            "due_date": "2033-09-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 362,
            "due_date": "2033-09-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 363,
            "due_date": "2033-09-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 364,
            "due_date": "2033-10-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 365,
            "due_date": "2033-10-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 366,
            "due_date": "2033-10-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 367,
            "due_date": "2033-10-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 368,
            "due_date": "2033-11-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 369,
            "due_date": "2033-11-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 370,
            "due_date": "2033-11-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 371,
            "due_date": "2033-11-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 372,
            "due_date": "2033-12-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 373,
            "due_date": "2033-12-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 374,
            "due_date": "2033-12-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 375,
            "due_date": "2033-12-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 376,
            "due_date": "2033-12-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 377,
            "due_date": "2034-01-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 378,
            "due_date": "2034-01-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 379,
            "due_date": "2034-01-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 380,
            "due_date": "2034-01-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 381,
            "due_date": "2034-02-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 382,
            "due_date": "2034-02-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 383,
            "due_date": "2034-02-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 384,
            "due_date": "2034-02-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 385,
            "due_date": "2034-03-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 386,
            "due_date": "2034-03-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 387,
            "due_date": "2034-03-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 388,
            "due_date": "2034-03-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 389,
            "due_date": "2034-03-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 390,
            "due_date": "2034-04-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 391,
            "due_date": "2034-04-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 392,
            "due_date": "2034-04-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 393,
            "due_date": "2034-04-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 394,
            "due_date": "2034-05-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 395,
            "due_date": "2034-05-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 396,
            "due_date": "2034-05-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 397,
            "due_date": "2034-05-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 398,
            "due_date": "2034-06-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 399,
            "due_date": "2034-06-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 400,
            "due_date": "2034-06-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 401,
            "due_date": "2034-06-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 402,
            "due_date": "2034-06-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 403,
            "due_date": "2034-07-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 404,
            "due_date": "2034-07-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 405,
            "due_date": "2034-07-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 406,
            "due_date": "2034-07-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 407,
            "due_date": "2034-08-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 408,
            "due_date": "2034-08-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 409,
            "due_date": "2034-08-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 410,
            "due_date": "2034-08-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 411,
            "due_date": "2034-08-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 412,
            "due_date": "2034-09-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 413,
            "due_date": "2034-09-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 414,
            "due_date": "2034-09-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 415,
            "due_date": "2034-09-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 416,
            "due_date": "2034-10-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 417,
            "due_date": "2034-10-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 418,
            "due_date": "2034-10-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 419,
            "due_date": "2034-10-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 420,
            "due_date": "2034-11-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 421,
            "due_date": "2034-11-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 422,
            "due_date": "2034-11-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 423,
            "due_date": "2034-11-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 424,
            "due_date": "2034-11-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 425,
            "due_date": "2034-12-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 426,
            "due_date": "2034-12-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 427,
            "due_date": "2034-12-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 428,
            "due_date": "2034-12-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 429,
            "due_date": "2035-01-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 430,
            "due_date": "2035-01-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 431,
            "due_date": "2035-01-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 432,
            "due_date": "2035-01-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 433,
            "due_date": "2035-02-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 434,
            "due_date": "2035-02-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 435,
            "due_date": "2035-02-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 436,
            "due_date": "2035-02-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 437,
            "due_date": "2035-03-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 438,
            "due_date": "2035-03-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 439,
            "due_date": "2035-03-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 440,
            "due_date": "2035-03-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 441,
            "due_date": "2035-03-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 442,
            "due_date": "2035-04-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 443,
            "due_date": "2035-04-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 444,
            "due_date": "2035-04-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 445,
            "due_date": "2035-04-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 446,
            "due_date": "2035-05-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 447,
            "due_date": "2035-05-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 448,
            "due_date": "2035-05-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 449,
            "due_date": "2035-05-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 450,
            "due_date": "2035-05-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 451,
            "due_date": "2035-06-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 452,
            "due_date": "2035-06-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 453,
            "due_date": "2035-06-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 454,
            "due_date": "2035-06-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 455,
            "due_date": "2035-07-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 456,
            "due_date": "2035-07-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 457,
            "due_date": "2035-07-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 458,
            "due_date": "2035-07-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 459,
            "due_date": "2035-08-02",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 460,
            "due_date": "2035-08-09",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 461,
            "due_date": "2035-08-16",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 462,
            "due_date": "2035-08-23",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 463,
            "due_date": "2035-08-30",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 464,
            "due_date": "2035-09-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 465,
            "due_date": "2035-09-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 466,
            "due_date": "2035-09-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 467,
            "due_date": "2035-09-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 468,
            "due_date": "2035-10-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 469,
            "due_date": "2035-10-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 470,
            "due_date": "2035-10-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 471,
            "due_date": "2035-10-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 472,
            "due_date": "2035-11-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 473,
            "due_date": "2035-11-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 474,
            "due_date": "2035-11-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 475,
            "due_date": "2035-11-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 476,
            "due_date": "2035-11-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 477,
            "due_date": "2035-12-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 478,
            "due_date": "2035-12-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 479,
            "due_date": "2035-12-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 480,
            "due_date": "2035-12-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 481,
            "due_date": "2036-01-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 482,
            "due_date": "2036-01-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 483,
            "due_date": "2036-01-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 484,
            "due_date": "2036-01-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 485,
            "due_date": "2036-01-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 486,
            "due_date": "2036-02-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 487,
            "due_date": "2036-02-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 488,
            "due_date": "2036-02-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 489,
            "due_date": "2036-02-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 490,
            "due_date": "2036-03-06",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 491,
            "due_date": "2036-03-13",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 492,
            "due_date": "2036-03-20",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 493,
            "due_date": "2036-03-27",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 494,
            "due_date": "2036-04-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 495,
            "due_date": "2036-04-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 496,
            "due_date": "2036-04-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 497,
            "due_date": "2036-04-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 498,
            "due_date": "2036-05-01",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 499,
            "due_date": "2036-05-08",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 500,
            "due_date": "2036-05-15",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 501,
            "due_date": "2036-05-22",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 502,
            "due_date": "2036-05-29",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 503,
            "due_date": "2036-06-05",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 504,
            "due_date": "2036-06-12",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 505,
            "due_date": "2036-06-19",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 506,
            "due_date": "2036-06-26",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 507,
            "due_date": "2036-07-03",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 508,
            "due_date": "2036-07-10",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 509,
            "due_date": "2036-07-17",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 510,
            "due_date": "2036-07-24",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 511,
            "due_date": "2036-07-31",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 512,
            "due_date": "2036-08-07",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 513,
            "due_date": "2036-08-14",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 514,
            "due_date": "2036-08-21",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 515,
            "due_date": "2036-08-28",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 516,
            "due_date": "2036-09-04",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 517,
            "due_date": "2036-09-11",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 518,
            "due_date": "2036-09-18",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 519,
            "due_date": "2036-09-25",
            "principal": "481.25",
            "profit": "288.75",
            "amount": "770.00"
          },
          {
            "seq": 520,
            "due_date": "2036-10-02",
            "principal": "231.25",
            "profit": "138.75",
            "amount": "370.00"
          }
        ],
        "violations": [
          {
            "rule": "too_many_months",
            "max_months": 120,
            "duration_months": 122
          }
        ]
      }
    },
    {
      "id": "N01-35",
      "title": "Profit split with remainders: 10 000 at 33 % over 7",
      "today": "2026-10-15",
      "policy": {
        "id": "00000000-0000-4000-8000-0000000000a1",
        "version": 1,
        "min_down_payment_pct": "0",
        "max_down_payment_pct": null,
        "down_payment_rules": {},
        "max_months": 24,
        "amount_tiers": [],
        "markup_tiers": [
          {
            "up_to_months": 24,
            "pct": 33
          }
        ],
        "allowed_frequencies": [
          "monthly",
          "weekly",
          "daily"
        ],
        "min_sale_amount": "0.00",
        "min_installment": "0.00",
        "min_installment_by_frequency": {},
        "rounding_step": "0.01"
      },
      "input": {
        "cash_price": "10000.00",
        "down_payment": "0.00",
        "installments_count": 7,
        "frequency": "monthly"
      },
      "expected": {
        "policy_id": "00000000-0000-4000-8000-0000000000a1",
        "policy_version": 1,
        "cash_price": "10000.00",
        "down_payment": "0.00",
        "financed_amount": "10000.00",
        "markup_pct": "33",
        "markup_amount": "3300.00",
        "total_payable": "13300.00",
        "installments_count": 7,
        "frequency": "monthly",
        "duration_months": 7,
        "installment_amount": "1900.00",
        "last_installment_amount": "1900.00",
        "first_due_date": "2026-11-15",
        "last_due_date": "2027-05-15",
        "min_down_payment": "0.00",
        "max_down_payment": "9999.99",
        "max_months_allowed": 24,
        "lines": [
          {
            "seq": 1,
            "due_date": "2026-11-15",
            "principal": "1428.57",
            "profit": "471.43",
            "amount": "1900.00"
          },
          {
            "seq": 2,
            "due_date": "2026-12-15",
            "principal": "1428.57",
            "profit": "471.43",
            "amount": "1900.00"
          },
          {
            "seq": 3,
            "due_date": "2027-01-15",
            "principal": "1428.57",
            "profit": "471.43",
            "amount": "1900.00"
          },
          {
            "seq": 4,
            "due_date": "2027-02-15",
            "principal": "1428.57",
            "profit": "471.43",
            "amount": "1900.00"
          },
          {
            "seq": 5,
            "due_date": "2027-03-15",
            "principal": "1428.57",
            "profit": "471.43",
            "amount": "1900.00"
          },
          {
            "seq": 6,
            "due_date": "2027-04-15",
            "principal": "1428.57",
            "profit": "471.43",
            "amount": "1900.00"
          },
          {
            "seq": 7,
            "due_date": "2027-05-15",
            "principal": "1428.58",
            "profit": "471.42",
            "amount": "1900.00"
          }
        ],
        "violations": []
      }
    }
  ]
}
$golden$::jsonb);
INSERT INTO t.results
SELECT 'golden '||(c->>'id')||': '||(c->>'title'),
       app.installment_terms(jsonb_populate_record(NULL::public.installment_policies,
           (c->'policy')||jsonb_build_object('organization_id',t.org('a'))),c->'input',(c->>'today')::date)=c->'expected',
       NULL
FROM t.golden g, jsonb_array_elements(g.doc->'cases') c;
SELECT t.expect('golden: at least 30 cases',(SELECT jsonb_array_length(doc->'cases')>=30 FROM t.golden));

-- ================================================================ always adds up (generated sweep)
CREATE TABLE t.sweep(n integer,bad integer);
DO $$
DECLARE v_pol public.installment_policies := t.policy('pol'); v_t jsonb; v_cash numeric; v_dp numeric; v_n integer; v_f text; v_step numeric;
        v_total integer:=0; v_bad integer:=0; v_ok boolean;
BEGIN
  v_pol.min_down_payment_pct := 0; v_pol.max_months := 120;
  v_pol.markup_tiers := '[{"pct":7.5,"up_to_months":3},{"pct":18,"up_to_months":12},{"pct":33.33,"up_to_months":120}]';
  FOREACH v_step IN ARRAY ARRAY[0.01,1,5] LOOP
    v_pol.rounding_step := v_step;
    FOREACH v_cash IN ARRAY ARRAY[100.00,999.99,1234.56,25000.00,250000.00] LOOP
      FOREACH v_dp IN ARRAY ARRAY[0,0.1,0.3333] LOOP
        FOR v_f, v_n IN SELECT 'monthly',g FROM generate_series(1,60,7) g UNION ALL SELECT 'weekly',g FROM generate_series(1,104,13) g
                        UNION ALL SELECT 'daily',g FROM generate_series(1,180,17) g LOOP
          v_t := app.installment_terms(v_pol,jsonb_build_object('cash_price',v_cash::text,'down_payment',round(v_cash*v_dp,2)::text,
                   'installments_count',v_n,'frequency',v_f),'2026-10-15');
          CONTINUE WHEN jsonb_array_length(v_t->'lines')=0;
          v_total := v_total+1;
          SELECT count(*)=v_n AND sum((l->>'amount')::numeric)=(v_t->>'total_payable')::numeric
                 AND sum((l->>'principal')::numeric)=(v_t->>'financed_amount')::numeric
                 AND sum((l->>'profit')::numeric)=(v_t->>'markup_amount')::numeric
                 AND bool_and((l->>'amount')::numeric>0 AND (l->>'principal')::numeric>=0 AND (l->>'profit')::numeric>=0
                              AND (l->>'principal')::numeric+(l->>'profit')::numeric=(l->>'amount')::numeric)
                 AND array_agg((l->>'seq')::integer ORDER BY o)=(SELECT array_agg(s) FROM generate_series(1,v_n) s)
                 AND bool_and(o=1 OR (l->>'due_date')::date>(v_t->'lines'->(o::integer-2)->>'due_date')::date)
          INTO v_ok FROM jsonb_array_elements(v_t->'lines') WITH ORDINALITY x(l,o);
          IF NOT v_ok THEN v_bad := v_bad+1; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
  END LOOP;
  INSERT INTO t.sweep VALUES(v_total,v_bad);
END $$;
SELECT t.expect('sweep: every schedule adds up exactly (amount = total, principal = financed, profit = markup), lines > 0, seq 1..n, dates rising',
  (SELECT n>900 AND bad=0 FROM t.sweep),(SELECT n||' schedules, '||bad||' bad' FROM t.sweep));

-- ================================================================ the spec's examples (by hand)
SELECT t.expect('example: 1000.00 at 0 %, 3 monthly, step 0.01 -> 333.34, 333.34, 333.32',
  (SELECT array_agg(l->>'amount' ORDER BY o)=ARRAY['333.34','333.34','333.32'] FROM jsonb_array_elements(
     (SELECT expected FROM (SELECT c->'expected' expected FROM t.golden, jsonb_array_elements(doc->'cases') c WHERE c->>'id'='N01-01') x)->'lines') WITH ORDINALITY y(l,o)));
SELECT t.expect('example: step 1 -> 334, 334, 332',
  (SELECT array_agg(l->>'amount' ORDER BY o)=ARRAY['334.00','334.00','332.00'] FROM jsonb_array_elements(
     (SELECT c->'expected'->'lines' FROM t.golden, jsonb_array_elements(doc->'cases') c WHERE c->>'id'='N01-02')) WITH ORDINALITY y(l,o)));
SELECT t.expect('example: financed 12 000, 12 months, tier 20 % -> profit 2400.00, total 14 400.00, 12 x 1200.00',
  (SELECT x->>'markup_pct'='20' AND x->>'markup_amount'='2400.00' AND x->>'total_payable'='14400.00'
          AND (SELECT bool_and(l->>'amount'='1200.00') AND count(*)=12 FROM jsonb_array_elements(x->'lines') l)
   FROM t.terms('pol','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}') x));
SELECT t.expect('example: first due 2027-01-31 monthly x 4 -> 01-31, 02-28, 03-31, 04-30',
  (SELECT array_agg(app.installment_due_date('2027-01-31','monthly',s)::text ORDER BY s)=ARRAY['2027-01-31','2027-02-28','2027-03-31','2027-04-30'] FROM generate_series(1,4) s));
SELECT t.expect('example: first due 2028-01-31 -> 2028-02-29 in the leap year',app.installment_due_date('2028-01-31','monthly',2)='2028-02-29');
SELECT t.expect('example: weekly x 10 lasts 3 months, daily x 45 lasts 2',
  app.installment_duration_months('weekly',10)=3 AND app.installment_duration_months('daily',45)=2 AND app.installment_duration_months('monthly',7)=7);
SELECT t.expect('example: markup_pct is the whole-term profit % (no per-period rate in the answer)',
  (SELECT NOT (x ? 'rate') AND NOT (x ? 'interest') AND x->>'markup_pct'='10'
   FROM t.terms('pol','{"cash_price":"6000.00","down_payment":"600.00","installments_count":6,"frequency":"monthly"}') x));

-- ================================================================ rules: each violation with its details
SELECT t.expect('rule: a down payment one piaster below the 10 % minimum is too low, at it passes',
  (SELECT x->'violations'=jsonb_build_array(jsonb_build_object('rule','down_payment_too_low','min_down_payment','600.00','down_payment_rule','percent'))
   FROM t.terms('pol','{"cash_price":"6000.00","down_payment":"599.99","installments_count":6,"frequency":"monthly"}') x)
  AND (SELECT x->'violations'='[]' FROM t.terms('pol','{"cash_price":"6000.00","down_payment":"600.00","installments_count":6,"frequency":"monthly"}') x));
SELECT t.expect('rule: 25 months is too many (max 24) and says so',
  (SELECT x->'violations'@>jsonb_build_array(jsonb_build_object('rule','too_many_months','max_months',24,'duration_months',25))
   FROM t.terms('pol','{"cash_price":"6000.00","down_payment":"600.00","installments_count":25,"frequency":"monthly"}') x));
SELECT t.expect('rule: a first due date of today is out of range',
  (SELECT x->'violations'->0->>'rule'='first_due_date_out_of_range' AND x->'violations'->0->>'earliest'=(app.org_today(t.org('a'))+1)::text
   FROM t.terms('pol',jsonb_build_object('cash_price','6000.00','down_payment','600.00','installments_count',6,'frequency','monthly',
     'first_due_date',app.org_today(t.org('a'))::text)) x));
SELECT t.expect('rule: the default first due date is one period after today',
  (SELECT x->>'first_due_date'=(app.org_today(t.org('a'))+7)::text
   FROM t.terms('pol','{"cash_price":"6000.00","down_payment":"600.00","installments_count":6,"frequency":"weekly"}') x));

-- ================================================================ confirm side for N02
SELECT t.error('check: a shop without a policy -> POLICY_NOT_SET',
  $$SELECT app.check_installment_terms(gen_random_uuid(),'{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}',1)$$,'POLICY_NOT_SET');
SELECT t.error('check: an older version than the current one -> POLICY_CHANGED',
  format($$SELECT app.check_installment_terms(%L,'{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}',1)$$,t.org('a')),'POLICY_CHANGED');
SELECT t.expect('check: POLICY_CHANGED carries the current version',
  t.detail(format($$SELECT app.check_installment_terms(%L,'{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}',1)$$,t.org('a')))
  =jsonb_build_object('current_version',(t.policy('pol')).version));
SELECT t.error('check: terms breaking the policy -> INSTALLMENT_TERMS_INVALID',
  format($$SELECT app.check_installment_terms(%L,'{"cash_price":"1000.00","down_payment":"0.00","installments_count":2,"frequency":"monthly"}',%s)$$,t.org('a'),(t.policy('pol')).version),'INSTALLMENT_TERMS_INVALID');
SELECT t.expect('check: INSTALLMENT_TERMS_INVALID lists the violations',
  t.detail(format($$SELECT app.check_installment_terms(%L,'{"cash_price":"1000.00","down_payment":"0.00","installments_count":2,"frequency":"monthly"}',%s)$$,t.org('a'),(t.policy('pol')).version))
  ->'violations'->0->>'rule'='down_payment_too_low');
SELECT t.expect('check: valid terms come back with their lines',
  (SELECT x->>'total_payable'='990.00' AND jsonb_array_length(x->'lines')=2
   FROM app.check_installment_terms(t.org('a'),'{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}',(t.policy('pol')).version) x));
SELECT t.error('check: a malformed body -> VALIDATION_FAILED',
  format($$SELECT app.check_installment_terms(%L,'{"cash_price":"10.001","down_payment":"0","installments_count":2,"frequency":"monthly"}',%s)$$,t.org('a'),(t.policy('pol')).version),'VALIDATION_FAILED');
SELECT t.error('check: 521 installments -> VALIDATION_FAILED',
  format($$SELECT app.check_installment_terms(%L,'{"cash_price":"1000.00","down_payment":"100.00","installments_count":521,"frequency":"weekly"}',%s)$$,t.org('a'),(t.policy('pol')).version),'VALIDATION_FAILED');

-- ================================================================ commit-time triggers (any writer)
SELECT t.make('valid','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'engine');
SELECT t.expect('trigger: a contract with the engine''s terms and lines commits',
  (SELECT total_payable=14400 FROM public.contracts WHERE id=t.id('contract-valid')));
SELECT t.error('trigger: one piaster moved inside line 1 (sums still equal) -> lines mismatch',
  $$SELECT t.make('moved','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'piaster')$$,'INSTALLMENT_TERMS_INVALID');
SELECT t.error('trigger: line 1 one piaster more -> refused (the lines are not the engine''s)',
  $$SELECT t.make('extra','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'extra')$$,'INSTALLMENT_TERMS_INVALID');
SELECT t.error('trigger: a gap in seq -> refused',
  $$SELECT t.make('gap','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'gap')$$,'INSTALLMENT_TERMS_INVALID');
SELECT t.error('trigger: due dates a day off -> refused',
  $$SELECT t.make('dates','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'dates')$$,'INSTALLMENT_TERMS_INVALID');
SELECT t.error('trigger: a contract without lines -> refused',
  $$SELECT t.make('nolines','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'none')$$,'INSTALLMENT_TERMS_INVALID');
SELECT t.error('trigger: a profit lower than the policy''s -> refused',
  $$SELECT t.make('cheap','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'none',1200)$$,'INSTALLMENT_TERMS_INVALID');
SELECT t.expect('trigger: the mismatch is named',
  t.detail($$SELECT t.make('cheap2','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'none',1200)$$)
  =jsonb_build_object('mismatch','markup_amount'));
SELECT t.error('trigger: terms breaking the policy (no down payment) -> refused',
  $$SELECT t.make('nodown','ok','{"cash_price":"14000.00","down_payment":"0.00","installments_count":12,"frequency":"monthly"}','pol',false,'engine')$$,'INSTALLMENT_TERMS_INVALID');
SELECT t.make('mig','ok','{"cash_price":"5000.00","down_payment":"0.00","installments_count":40,"frequency":"monthly"}','pol',true,'engine');
SELECT t.expect('trigger: a migrated contract keeps the terms it had (no down payment, 40 months: outside the policy)',
  EXISTS(SELECT 1 FROM public.contracts WHERE id=t.id('contract-mig') AND down_payment=0 AND installments_count=40));
SELECT t.error('trigger: but a migrated contract''s lines must still add up (one piaster more)',
  $$SELECT t.make('mig-bad','ok','{"cash_price":"5000.00","down_payment":"0.00","installments_count":40,"frequency":"monthly"}','pol',true,'extra')$$,'SCHEDULE_NOT_BALANCED');
SELECT t.error('trigger: and run 1..n without a gap',
  $$SELECT t.make('mig-gap','ok','{"cash_price":"5000.00","down_payment":"0.00","installments_count":40,"frequency":"monthly"}','pol',true,'gap')$$,'SCHEDULE_NOT_BALANCED');
-- A new policy version: the old contract never changes; the next contract must use the new version.
CREATE TABLE t.before AS SELECT seq,due_date,principal,profit FROM public.schedule_lines WHERE contract_id=t.id('contract-valid');
WITH x AS (INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,rounding_step)
  SELECT t.org('a'),max(version)+1,10,24,'[{"pct":30,"up_to_months":24}]','{monthly}',1 FROM public.installment_policies WHERE organization_id=t.org('a') RETURNING id)
INSERT INTO t.ids SELECT 'pol2',id FROM x;
SELECT t.expect('policy change: the earlier contract and its lines are unchanged',
  (SELECT markup_amount=2400 AND total_payable=14400 AND policy_id=t.id('pol') FROM public.contracts WHERE id=t.id('contract-valid'))
  AND NOT EXISTS((SELECT seq,due_date,principal,profit FROM public.schedule_lines WHERE contract_id=t.id('contract-valid')) EXCEPT (SELECT * FROM t.before)));
SELECT t.error('policy change: a new contract on the old version -> POLICY_CHANGED',
  $$SELECT t.make('old','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol',false,'engine')$$,'POLICY_CHANGED');
SELECT t.make('new','ok','{"cash_price":"14000.00","down_payment":"2000.00","installments_count":12,"frequency":"monthly"}','pol2',false,'engine');
SELECT t.expect('policy change: a new contract on the new version commits with the new profit',
  (SELECT markup_amount=3600 FROM public.contracts WHERE id=t.id('contract-new')));
-- Back to the first policy for the previews.
WITH x AS (INSERT INTO public.installment_policies(organization_id,version,min_down_payment_pct,max_months,markup_tiers,allowed_frequencies,
    rounding_step,guarantor_required_above,guarantors_required_count,survey_required_above)
  SELECT t.org('a'),max(version)+1,10,24,'[{"pct":10,"up_to_months":6},{"pct":20,"up_to_months":24}]','{monthly,weekly,daily}',1,20000,1,30000
  FROM public.installment_policies WHERE organization_id=t.org('a') RETURNING id)
INSERT INTO t.ids SELECT 'pol3',id FROM x;

-- ================================================================ preview (as the shop's people)
-- Guarantors of the good customer (made by the owner).
SELECT t.as_user('a0760000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids SELECT 'g1',(public.create_guarantor('{"full_name":"First Guarantor","phone":"01000000101","national_id":"29001010100015"}')->>'id')::uuid;
INSERT INTO t.ids SELECT 'g2',(public.create_guarantor('{"full_name":"Unlinked Guarantor","phone":"01000000102","national_id":"29001010100023"}')->>'id')::uuid;
SELECT public.link_customer_guarantor(t.id('ok'),t.id('g1'),'brother');
RESET ROLE;
CREATE TABLE t.counts AS SELECT (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a')) a,(SELECT count(*) FROM public.contracts WHERE organization_id=t.org('a')) c;

SELECT t.as_user('a0760000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('preview: a cashier previews without a customer: terms, no customer, can_confirm false',
  (SELECT x->'terms'->>'total_payable'='990.00' AND x->'customer'='null' AND x->>'can_confirm'='false'
   FROM public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}') x));
SELECT t.expect('preview: with a good customer under 20 000: credit, guarantors, survey answered; can_confirm true',
  (SELECT x->'customer'->'credit'->>'allowed'='true' AND x->'customer'->'survey'->>'met'='true'
          AND x->'customer'->'guarantors'->>'selected_met'='true' AND x->>'can_confirm'='true'
   FROM public.preview_installment_terms(jsonb_build_object('cash_price','1000.00','down_payment','100.00','installments_count',2,
     'frequency','monthly','customer_id',t.id('ok'))) x));
SELECT t.expect('preview: above 20 000 the guarantor is needed: without picking one can_confirm is false',
  (SELECT x->'customer'->'guarantors'->>'required_count'='1' AND x->'customer'->'guarantors'->>'selected'='0'
          AND x->'customer'->'guarantors'->>'selected_met'='false' AND x->>'can_confirm'='false'
   FROM public.preview_installment_terms(jsonb_build_object('cash_price','25000.00','down_payment','2500.00','installments_count',12,
     'frequency','monthly','customer_id',t.id('ok'))) x));
SELECT t.expect('preview: picking the linked guarantor meets it',
  (SELECT x->'customer'->'guarantors'->>'selected'='1' AND x->'customer'->'guarantors'->>'selected_met'='true' AND x->>'can_confirm'='true'
   FROM public.preview_installment_terms(jsonb_build_object('cash_price','25000.00','down_payment','2500.00','installments_count',12,
     'frequency','monthly','customer_id',t.id('ok'),'guarantor_ids',jsonb_build_array(t.id('g1')))) x));
SELECT t.expect('preview: an unlinked guarantor is not counted and makes the contract fail R04',
  (SELECT x->'customer'->'guarantors'->>'selected'='1' AND x->'customer'->'guarantors'->>'selected_met'='false' AND x->>'can_confirm'='false'
   FROM public.preview_installment_terms(jsonb_build_object('cash_price','25000.00','down_payment','2500.00','installments_count',12,
     'frequency','monthly','customer_id',t.id('ok'),'guarantor_ids',jsonb_build_array(t.id('g1'),t.id('g2')))) x));
SELECT t.expect('preview: above 30 000 a survey is needed: can_confirm false with the survey not met',
  (SELECT x->'customer'->'survey'->>'required'='true' AND x->'customer'->'survey'->>'met'='false' AND x->>'can_confirm'='false'
   FROM public.preview_installment_terms(jsonb_build_object('cash_price','40000.00','down_payment','4000.00','installments_count',12,
     'frequency','monthly','customer_id',t.id('ok'),'guarantor_ids',jsonb_build_array(t.id('g1')))) x));
SELECT t.expect('preview: a customer over the limit: credit not allowed, can_confirm false',
  (SELECT x->'customer'->'credit'->>'allowed'='false' AND x->'customer'->'credit'->'reasons' ? 'limit' AND x->>'can_confirm'='false'
   FROM public.preview_installment_terms(jsonb_build_object('cash_price','1000.00','down_payment','100.00','installments_count',2,
     'frequency','monthly','customer_id',t.id('poor'))) x));
SELECT t.expect('preview: a violation answers with the list, not an error',
  (SELECT x->'terms'->'violations'->0->>'rule'='down_payment_too_low' AND x->>'can_confirm'='false'
   FROM public.preview_installment_terms(jsonb_build_object('cash_price','1000.00','down_payment','0.00','installments_count',2,
     'frequency','monthly','customer_id',t.id('ok'))) x));
SELECT t.error('preview: a blocked customer -> CUSTOMER_BLOCKED',format($$SELECT public.preview_installment_terms(%L)$$,
  jsonb_build_object('cash_price','1000.00','down_payment','100.00','installments_count',2,'frequency','monthly','customer_id',t.id('blocked'))),'CUSTOMER_BLOCKED');
SELECT t.error('preview: shop B''s customer -> CUSTOMER_NOT_FOUND',format($$SELECT public.preview_installment_terms(%L)$$,
  jsonb_build_object('cash_price','1000.00','down_payment','100.00','installments_count',2,'frequency','monthly','customer_id',t.id('cust-b'))),'CUSTOMER_NOT_FOUND');
SELECT t.error('preview: an unknown key -> VALIDATION_FAILED',
  $$SELECT public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly","organization_id":"x"}')$$,'VALIDATION_FAILED');
SELECT t.error('preview: the same guarantor twice -> VALIDATION_FAILED',format($$SELECT public.preview_installment_terms(%L)$$,
  jsonb_build_object('cash_price','1000.00','down_payment','100.00','installments_count',2,'frequency','monthly','customer_id',t.id('ok'),
    'guarantor_ids',jsonb_build_array(t.id('g1'),t.id('g1')))),'VALIDATION_FAILED');
RESET ROLE;
SELECT t.expect('preview: nothing is written (no audit row, no contract)',
  (SELECT a=(SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a')) AND c=(SELECT count(*) FROM public.contracts WHERE organization_id=t.org('a')) FROM t.counts));

-- Who may preview.
SELECT t.as_user('a0760000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('who: a warehouse user (no installment.create) -> PERMISSION_DENIED',
  $$SELECT public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}')$$,'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0760000-0000-0000-8000-0000000000ff',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('who: not an employee -> NOT_AN_EMPLOYEE',
  $$SELECT public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}')$$,'NOT_AN_EMPLOYEE');
RESET ROLE;
SELECT t.as_user('a0760000-0000-0000-8000-000000000005',t.org('c'));
SET LOCAL ROLE authenticated;
SELECT t.error('who: a plan without installments -> MODULE_NOT_IN_PLAN',
  $$SELECT public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}')$$,'MODULE_NOT_IN_PLAN');
RESET ROLE;
UPDATE public.organizations SET installments_enabled=false WHERE id=t.org('a');
SELECT t.as_user('a0760000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('who: installments switched off -> INSTALLMENTS_DISABLED',
  $$SELECT public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}')$$,'INSTALLMENTS_DISABLED');
RESET ROLE;
UPDATE public.organizations SET installments_enabled=true, subscription_start=NULL, subscription_end=app.org_today(id)-1 WHERE id=t.org('a');
SELECT t.as_user('a0760000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('who: an expired (read-only) shop may still preview',
  (SELECT x->'terms'->>'total_payable'='990.00'
   FROM public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"100.00","installments_count":2,"frequency":"monthly"}') x));
RESET ROLE;

-- ================================================================ grants
SELECT t.expect('grants: the app helpers are not executable by authenticated',
  NOT has_function_privilege('authenticated','app.installment_terms(public.installment_policies,jsonb,date)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.check_installment_terms(uuid,jsonb,integer)','EXECUTE')
  AND NOT has_function_privilege('authenticated','app.installment_input(jsonb)','EXECUTE')
  AND NOT has_function_privilege('anon','public.preview_installment_terms(jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.preview_installment_terms(jsonb)','EXECUTE'));
SELECT t.expect('grants: the two safety-net triggers are deferred constraint triggers',
  (SELECT count(*)=2 FROM pg_trigger WHERE tgname IN ('trg_contracts_terms_check','trg_schedule_lines_sum_check') AND tgdeferrable AND tginitdeferred));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
