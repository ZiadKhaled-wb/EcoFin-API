-- S08 offline cash sales (EC-75). Test ids S1-S21 of docs/testing/plans/S08.md.
-- Run by: node scripts/db-smoke.mjs supabase/tests/s08_offline_test.sql (inside BEGIN ... ROLLBACK).
-- Contents are built here with T01 (app.compute_document_tax) and fake receipt UUIDs; the worker's
-- signature and UUID checks are simulated by calling app.offline_process as the service role with
-- their results (the real ones run in src/offline/*.test.ts and the integration tests).
-- now() is the same all through the transaction: "issued now" equals the lease's issue time.
\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE TABLE t.docs(tag text,j jsonb);
CREATE TABLE t.dev(device uuid PRIMARY KEY,seq integer,head text);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.state(n text,q text,s text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND SQLSTATE=s,SQLSTATE||' '||SQLERRM); END; END $$;
-- The caller's session: a user and a shop, no device.
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),
         set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.doc(s text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM t.docs WHERE tag=s $$;
-- O03: this request comes from a paired device (paired here unless p_pair is false).
CREATE FUNCTION t.pos(p_device uuid,p_pair boolean DEFAULT true) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash text;
BEGIN
  IF p_pair THEN
    UPDATE public.devices d SET token_hash=COALESCE(d.token_hash,encode(sha256(convert_to(d.id::text,'UTF8')),'hex')),
           paired_at=COALESCE(d.paired_at,now()) WHERE d.id=p_device;
  END IF;
  SELECT d.token_hash INTO v_hash FROM public.devices d WHERE d.id=p_device;
  PERFORM set_config('request.headers',(COALESCE(NULLIF(current_setting('request.headers',true),''),'{}')::jsonb
       || jsonb_build_object('x-device-id',p_device,'x-device-token-hash',COALESCE(v_hash,'none')))::text,false);
  RETURN p_device;
END $$;
CREATE FUNCTION t.unit(s text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT id FROM public.units WHERE serial=s $$;
CREATE FUNCTION t.level(p text) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id('main') AND stock_state='sellable'),0) $$;
CREATE FUNCTION t.drawer(shift text) RETURNS numeric LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT b.balance FROM public.cash_balances b JOIN public.shifts s ON s.drawer_account_id=b.cash_account_id WHERE s.id=t.id(shift)),0) $$;
CREATE FUNCTION t.os(tag text) RETURNS public.offline_sales LANGUAGE sql SECURITY DEFINER AS $$
  SELECT o FROM public.offline_sales o WHERE o.number=t.doc(tag)->>'number' AND o.content_hash=encode(sha256(convert_to(t.doc(tag)->>'content','UTF8')),'hex') $$;
CREATE FUNCTION t.fs(tag text) RETURNS public.fiscal_submissions LANGUAGE sql SECURITY DEFINER AS $$
  SELECT f FROM public.fiscal_submissions f WHERE f.offline_sale_id=(t.os(tag)).id $$;
CREATE FUNCTION t.sale(tag text) RETURNS public.sales LANGUAGE sql SECURITY DEFINER AS $$
  SELECT s FROM public.sales s WHERE s.id=(t.os(tag)).sale_id $$;
CREATE FUNCTION t.alerts(code text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.audit_log a WHERE a.action='offline.alert' AND a.after->>'code'=code
    AND a.organization_id IN (t.org('a'),t.org('b')) $$;
CREATE FUNCTION t.events(tag text,k text) RETURNS bigint LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*) FROM public.fiscal_events e WHERE e.fiscal_id=(t.fs(tag)).id AND e.kind=k $$;
CREATE FUNCTION t.head(dev text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT eta_last_uuid FROM public.devices WHERE id=t.id(dev) $$;
CREATE FUNCTION t.pubkey(c text DEFAULT 'M') RETURNS text LANGUAGE sql AS $$ SELECT 'MFkw'||repeat(c,120) $$;
CREATE FUNCTION t.sig() RETURNS text LANGUAGE sql AS $$ SELECT repeat('A',86)||'==' $$;
CREATE FUNCTION t.item(tag text) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('content',t.doc(tag)->>'content','signature',t.sig()) $$;
CREATE FUNCTION t.items(VARIADIC tags text[]) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_agg(t.item(x) ORDER BY o) FROM unnest(tags) WITH ORDINALITY u(x,o) $$;
CREATE FUNCTION t.result(r jsonb,i integer) RETURNS text LANGUAGE sql AS $$ SELECT (r->'results'->i->>'result')||COALESCE(':'||(r->'results'->i->>'code'),'') $$;

-- One offline sale under a lease, built like the POS builds it: the snapshot's prices, T01's totals,
-- the next sequence of the device and its chain head. Options: at (an interval from now), price,
-- prev (previousUUID), rin, receipt_total (a wrong receipt), bad_tax (printed tax one piaster off),
-- idem (the idempotency key), seq (a sequence already used: the counter does not move).
CREATE FUNCTION t.mk(p_tag text,p_lease text,p_lines jsonb,p_opts jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  L jsonb := t.doc(p_lease); v_dev uuid := (L->'lease'->>'device_id')::uuid; v_seq integer; v_head text; v_snap jsonb;
  v_lines jsonb := '[]'; v_taxin jsonb := '[]'; v_items jsonb := '[]'; v_tax jsonb; x jsonb; v_p jsonb; v_price text;
  v_number text; v_issued text; v_uuid text; v_prev text; v_receipt jsonb; v_content jsonb; i integer;
  v_total text; v_taxtotal text; v_idem text; v_eta boolean;
BEGIN
  SELECT d.seq,d.head INTO v_seq,v_head FROM t.dev d WHERE d.device=v_dev;
  IF NOT FOUND THEN
    v_seq := (L->'lease'->>'next_seq')::integer-1; v_head := L->'lease'->>'chain_head';
    INSERT INTO t.dev VALUES(v_dev,v_seq,v_head);
  END IF;
  v_seq := COALESCE((p_opts->>'seq')::integer,v_seq+1);
  SELECT s.data INTO v_snap FROM public.offline_snapshots s WHERE s.id=(L->'lease'->>'snapshot_id')::uuid;
  FOR x IN SELECT jsonb_array_elements(p_lines) LOOP
    SELECT p INTO v_p FROM jsonb_array_elements(v_snap->'products') p WHERE p->>'id'=t.id(x->>'p')::text;
    v_price := COALESCE(x->>'price',v_p->>'price');
    v_lines := v_lines||jsonb_build_object('product_id',t.id(x->>'p'),'unit_id',t.unit(x->>'serial'),'quantity',(x->>'q')::integer,
                                           'unit_price',v_price,'tax_rate',v_p->>'tax_rate');
    v_taxin := v_taxin||jsonb_build_object('unit_price',v_price,'quantity',(x->>'q')::integer,'line_discount','0','tax_rate',v_p->>'tax_rate');
    v_items := v_items||jsonb_build_object('internalCode',v_p->>'sku','quantity',(x->>'q')::integer);
  END LOOP;
  v_tax := app.compute_document_tax(jsonb_build_object('prices_include_vat',(v_snap->>'prices_include_vat')::boolean,
                                                       'document_discount','0','lines',v_taxin));
  FOR i IN 0..jsonb_array_length(v_lines)-1 LOOP
    v_lines := jsonb_set(v_lines,ARRAY[i::text],(v_lines->i)||jsonb_build_object(
      'tax_amount',(v_tax->'lines'->i->>'tax')::numeric(18,2)::text,'line_total',(v_tax->'lines'->i->>'gross')::numeric(18,2)::text));
  END LOOP;
  v_total := (v_tax->>'total')::numeric(18,2)::text;
  v_taxtotal := (v_tax->>'tax_total')::numeric(18,2)::text;
  IF p_opts ? 'bad_tax' THEN
    v_lines := jsonb_set(v_lines,'{0,tax_amount}',to_jsonb(((v_lines->0->>'tax_amount')::numeric+0.01)::numeric(18,2)::text));
    v_taxtotal := (v_taxtotal::numeric+0.01)::numeric(18,2)::text;
  END IF;
  v_number := 'OFF-'||(L->>'offline_code')||'-'||lpad(v_seq::text,6,'0');
  v_issued := to_char((now()+COALESCE((p_opts->>'at')::interval,'0'))AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_uuid := encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex');
  v_prev := COALESCE(p_opts->>'prev',v_head);
  v_idem := COALESCE(p_opts->>'idem',gen_random_uuid()::text);
  v_eta := (L->'eta'->>'enabled')::boolean;
  IF v_eta THEN
    v_receipt := jsonb_build_object(
      'header',jsonb_build_object('dateTimeIssued',v_issued,'receiptNumber',v_number,'uuid',v_uuid,'previousUUID',v_prev),
      'seller',jsonb_build_object('rin',COALESCE(p_opts->>'rin',regexp_replace(L->'eta'->'seller'->>'rin','\D','','g')),
                                  'branchCode',L->'eta'->'seller'->>'branch_code','deviceSerialNumber',L->'eta'->>'device_serial'),
      'itemData',v_items,'totalAmount',COALESCE(p_opts->>'receipt_total',v_total)::numeric);
  END IF;
  v_content := jsonb_build_object('v',1,'lease_id',L->'lease'->>'id','device_id',v_dev,'seq',v_seq,'number',v_number,
    'idempotency_key',v_idem,'issued_at',v_issued,'cashier_id',L->'lease'->>'cashier_id','lines',v_lines,
    'subtotal',(v_tax->>'subtotal')::numeric(18,2)::text,'tax_total',v_taxtotal,'total',v_total,
    'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',v_total,'tendered',v_total,'change','0.00')),
    'receipt',COALESCE(v_receipt,'null'::jsonb));
  IF NOT p_opts ? 'seq' THEN
    UPDATE t.dev d SET seq=v_seq,head=CASE WHEN v_eta THEN v_uuid ELSE d.head END WHERE d.device=v_dev;
  END IF;
  INSERT INTO t.docs VALUES(p_tag,jsonb_build_object('content',v_content::text,'number',v_number,'uuid',v_uuid,'prev',v_prev,
                                                     'seq',v_seq,'idem',v_idem,'total',v_total,'issued_at',v_issued));
  RETURN t.doc(p_tag);
END $$;
-- The worker's step (run as the service role): the signature and UUID results, and the QR text.
CREATE FUNCTION t.run(tag text,sig boolean DEFAULT true,uid boolean DEFAULT true) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.offline_process((t.os(tag)).id,sig,uid,'qr-'||(t.doc(tag)->>'number')) $$;
CREATE FUNCTION t.st(tag text) RETURNS text LANGUAGE sql AS $$ SELECT (t.os(tag)).status||COALESCE(':'||(t.os(tag)).conflict_code,'') $$;
CREATE FUNCTION t.day(shop text,ago integer) RETURNS date LANGUAGE sql SECURITY DEFINER AS $$
  SELECT ((now()-make_interval(days=>ago)) AT TIME ZONE (SELECT timezone FROM public.organizations WHERE id=t.org(shop)))::date $$;
CREATE FUNCTION t.day_totals(d date) RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object('sales',(SELECT count(*) FROM public.sales WHERE organization_id=t.org('a') AND branch_id=t.id('main') AND business_date=d),
    'totals',(SELECT totals FROM public.day_closes WHERE organization_id=t.org('a') AND branch_id=t.id('main') AND business_date=d)) $$;

-- ---------------------------------------------------------------- S1 totals parity (the fixture of U2)
-- supabase/tests/fixtures/s08_offline_totals.json, embedded (src/test/s08-golden.test.ts keeps the two equal).
CREATE TABLE t.golden(j jsonb);
INSERT INTO t.golden VALUES($golden$
{
    "note": "S08 offline totals (D7). Generated once by supabase/tests/s08_offline_test.sql (S1) from T01's app.compute_document_tax; read by packages/contracts/src/offline.test.ts (U2). Both must give exactly these results.",
    "cases": [
        {
            "id": "O01",
            "lines": [
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "1140.00"
                }
            ],
            "title": "Prices include VAT: 1140.00 at 14%",
            "expected": {
                "lines": [
                    {
                        "line_total": "1140.00",
                        "tax_amount": "140.00"
                    }
                ],
                "total": "1140.00",
                "subtotal": "1140.00",
                "tax_total": "140.00"
            },
            "prices_include_vat": true
        },
        {
            "id": "O02",
            "lines": [
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "1000.00"
                }
            ],
            "title": "Prices exclude VAT: 1000.00 at 14%",
            "expected": {
                "lines": [
                    {
                        "line_total": "1140.00",
                        "tax_amount": "140.00"
                    }
                ],
                "total": "1140.00",
                "subtotal": "1000.00",
                "tax_total": "140.00"
            },
            "prices_include_vat": false
        },
        {
            "id": "O03",
            "lines": [
                {
                    "quantity": 1,
                    "tax_rate": "0.00",
                    "unit_price": "500.00"
                }
            ],
            "title": "Zero-rated, prices include VAT",
            "expected": {
                "lines": [
                    {
                        "line_total": "500.00",
                        "tax_amount": "0.00"
                    }
                ],
                "total": "500.00",
                "subtotal": "500.00",
                "tax_total": "0.00"
            },
            "prices_include_vat": true
        },
        {
            "id": "O04",
            "lines": [
                {
                    "quantity": 2,
                    "tax_rate": "0.00",
                    "unit_price": "250.00"
                }
            ],
            "title": "Exempt, prices exclude VAT, quantity 2",
            "expected": {
                "lines": [
                    {
                        "line_total": "500.00",
                        "tax_amount": "0.00"
                    }
                ],
                "total": "500.00",
                "subtotal": "500.00",
                "tax_total": "0.00"
            },
            "prices_include_vat": false
        },
        {
            "id": "O05",
            "lines": [
                {
                    "quantity": 3,
                    "tax_rate": "14.00",
                    "unit_price": "99.99"
                }
            ],
            "title": "Quantity 3 at 99.99, prices include VAT",
            "expected": {
                "lines": [
                    {
                        "line_total": "299.97",
                        "tax_amount": "36.84"
                    }
                ],
                "total": "299.97",
                "subtotal": "299.97",
                "tax_total": "36.84"
            },
            "prices_include_vat": true
        },
        {
            "id": "O06",
            "lines": [
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "0.57"
                },
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "1.71"
                },
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "10.83"
                }
            ],
            "title": "Three lines rounding at the half, prices include VAT",
            "expected": {
                "lines": [
                    {
                        "line_total": "0.57",
                        "tax_amount": "0.07"
                    },
                    {
                        "line_total": "1.71",
                        "tax_amount": "0.21"
                    },
                    {
                        "line_total": "10.83",
                        "tax_amount": "1.33"
                    }
                ],
                "total": "13.11",
                "subtotal": "13.11",
                "tax_total": "1.61"
            },
            "prices_include_vat": true
        },
        {
            "id": "O07",
            "lines": [
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "0.25"
                },
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "0.75"
                },
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "1.25"
                }
            ],
            "title": "Three lines rounding at the half, prices exclude VAT",
            "expected": {
                "lines": [
                    {
                        "line_total": "0.29",
                        "tax_amount": "0.04"
                    },
                    {
                        "line_total": "0.86",
                        "tax_amount": "0.11"
                    },
                    {
                        "line_total": "1.43",
                        "tax_amount": "0.18"
                    }
                ],
                "total": "2.58",
                "subtotal": "2.25",
                "tax_total": "0.33"
            },
            "prices_include_vat": false
        },
        {
            "id": "O08",
            "lines": [
                {
                    "quantity": 2,
                    "tax_rate": "14.00",
                    "unit_price": "1140.00"
                },
                {
                    "quantity": 1,
                    "tax_rate": "0.00",
                    "unit_price": "300.00"
                },
                {
                    "quantity": 3,
                    "tax_rate": "14.00",
                    "unit_price": "49.99"
                }
            ],
            "title": "Mixed rates and quantities, prices include VAT",
            "expected": {
                "lines": [
                    {
                        "line_total": "2280.00",
                        "tax_amount": "280.00"
                    },
                    {
                        "line_total": "300.00",
                        "tax_amount": "0.00"
                    },
                    {
                        "line_total": "149.97",
                        "tax_amount": "18.42"
                    }
                ],
                "total": "2729.97",
                "subtotal": "2729.97",
                "tax_total": "298.42"
            },
            "prices_include_vat": true
        },
        {
            "id": "O09",
            "lines": [
                {
                    "quantity": 3,
                    "tax_rate": "14.00",
                    "unit_price": "333.33"
                },
                {
                    "quantity": 7,
                    "tax_rate": "5.00",
                    "unit_price": "12.35"
                },
                {
                    "quantity": 1,
                    "tax_rate": "14.00",
                    "unit_price": "0.01"
                }
            ],
            "title": "Mixed rates and quantities, prices exclude VAT",
            "expected": {
                "lines": [
                    {
                        "line_total": "1139.99",
                        "tax_amount": "140.00"
                    },
                    {
                        "line_total": "90.77",
                        "tax_amount": "4.32"
                    },
                    {
                        "line_total": "0.01",
                        "tax_amount": "0.00"
                    }
                ],
                "total": "1230.77",
                "subtotal": "1086.45",
                "tax_total": "144.32"
            },
            "prices_include_vat": false
        }
    ]
}
$golden$);
SELECT t.expect('S1 '||(c->>'id')||' T01 in SQL gives the fixture''s totals',
  jsonb_build_object('lines',(SELECT jsonb_agg(jsonb_build_object('tax_amount',(l->>'tax')::numeric(18,2)::text,'line_total',(l->>'gross')::numeric(18,2)::text) ORDER BY o)
                              FROM jsonb_array_elements(x->'lines') WITH ORDINALITY y(l,o)),
                     'subtotal',(x->>'subtotal')::numeric(18,2)::text,'tax_total',(x->>'tax_total')::numeric(18,2)::text,
                     'total',(x->>'total')::numeric(18,2)::text)=c->'expected',x::text)
FROM t.golden g,jsonb_array_elements(g.j->'cases') c,
     LATERAL (SELECT app.compute_document_tax(jsonb_build_object('prices_include_vat',(c->>'prices_include_vat')::boolean,'document_discount','0',
       'lines',(SELECT jsonb_agg(l||'{"line_discount":"0"}'::jsonb ORDER BY o) FROM jsonb_array_elements(c->'lines') WITH ORDINALITY z(l,o)))) x) q;
SELECT t.expect('S1 the fixture has its nine cases',(SELECT jsonb_array_length(j->'cases')=9 FROM t.golden));

-- ---------------------------------------------------------------- setup: shops a (ETA on), b (other), e (ETA off)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('S08 '||s,'s08-'||s,'retail_pro','Owner',s||'s08@example.com',NULL,'Main',h,now()+interval '1 day')
  FROM (VALUES('a',repeat('p',64)),('b',repeat('q',64)),('e',repeat('r',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES
  ('a0800000-0000-0000-8000-000000000001','as08@example.com'),('a0800000-0000-0000-8000-000000000002','bs08@example.com'),
  ('a0800000-0000-0000-8000-000000000003','s08cashier@example.com'),('a0800000-0000-0000-8000-000000000004','s08cashier2@example.com'),
  ('a0800000-0000-0000-8000-000000000005','s08manager@example.com'),('a0800000-0000-0000-8000-000000000006','s08wh@example.com'),
  ('a0800000-0000-0000-8000-000000000007','s08cashier3@example.com'),('a0800000-0000-0000-8000-000000000008','es08@example.com'),
  ('a0800000-0000-0000-8000-000000000009','s08mgr2@example.com');
SELECT public.accept_invite(repeat('p',64),'a0800000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('q',64),'a0800000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('r',64),'a0800000-0000-0000-8000-000000000008');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'bmain',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO t.ids SELECT 'emain',id FROM public.branches WHERE organization_id=t.org('e') AND is_main;
UPDATE public.org_settings SET prices_include_vat=true WHERE organization_id IN (t.org('a'),t.org('b'),t.org('e'));
UPDATE public.organizations SET tax_registration_no='674859545',legal_name='S08 Shop A LLC' WHERE id=t.org('a');
WITH d AS (INSERT INTO public.devices(organization_id,branch_id,name) VALUES
    (t.org('a'),t.id('main'),'POS 1'),(t.org('a'),t.id('main'),'POS 2'),(t.org('a'),t.id('main'),'POS 3'),
    (t.org('a'),t.id('main'),'POS 4'),(t.org('a'),t.id('main'),'POS X'),(t.org('b'),t.id('bmain'),'B POS'),
    (t.org('e'),t.id('emain'),'E POS') RETURNING id,name)
INSERT INTO t.ids SELECT CASE name WHEN 'POS 1' THEN 'pos1' WHEN 'POS 2' THEN 'pos2' WHEN 'POS 3' THEN 'pos3' WHEN 'POS 4' THEN 'pos4'
  WHEN 'POS X' THEN 'posx' WHEN 'B POS' THEN 'bpos' ELSE 'epos' END,id FROM d;
CREATE FUNCTION t.emp(tag text,shop text,sub uuid,name text,r public.employee_role,branch text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN
  INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org(shop),sub,name,r,t.id(branch)) RETURNING id INTO v;
  INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org(shop),v,t.id(branch));
  INSERT INTO t.ids VALUES(tag,v); END $$;
SELECT t.emp('cashier','a','a0800000-0000-0000-8000-000000000003','S08 Cashier','CASHIER','main');
SELECT t.emp('cashier2','a','a0800000-0000-0000-8000-000000000004','S08 Cashier 2','CASHIER','main');
SELECT t.emp('manager','a','a0800000-0000-0000-8000-000000000005','S08 Manager','BRANCH_MANAGER','main');
SELECT t.emp('wh','a','a0800000-0000-0000-8000-000000000006','S08 Warehouse','WAREHOUSE','main');
SELECT t.emp('cashier3','a','a0800000-0000-0000-8000-000000000007','S08 Cashier 3','CASHIER','main');
CREATE FUNCTION t.owner_a() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000001',t.org('a')) $$;
CREATE FUNCTION t.owner_b() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000002',t.org('b')) $$;
CREATE FUNCTION t.owner_e() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000008',t.org('e')) $$;
CREATE FUNCTION t.cashier() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000003',t.org('a')) $$;
CREATE FUNCTION t.cashier2() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000004',t.org('a')) $$;
CREATE FUNCTION t.manager() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000005',t.org('a')) $$;
CREATE FUNCTION t.wh() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000006',t.org('a')) $$;
CREATE FUNCTION t.cashier3() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000007',t.org('a')) $$;
CREATE FUNCTION t.mgr2() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user('a0800000-0000-0000-8000-000000000009',t.org('a')) $$;
CREATE FUNCTION t.svc() RETURNS void LANGUAGE sql AS $$ SELECT t.as_user(NULL) $$;
-- Opens a shift on a device for the caller (pairing the device for this request).
CREATE FUNCTION t.open(shift text,dev text,key text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(t.id(dev));
  INSERT INTO t.ids SELECT shift,(public.open_shift((SELECT branch_id FROM public.devices WHERE id=t.id(dev)),'0',key,NULL,t.id(dev))->>'id')::uuid;
END $$;
CREATE FUNCTION t.branch_of(dev text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$ SELECT branch_id FROM public.devices WHERE id=t.id(dev) $$;
GRANT USAGE ON SCHEMA t TO authenticated,service_role;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA t TO authenticated,service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated,service_role;

-- Shop a: products, stock, serials, branch ETA data, ETA on, four registered POS.
SELECT t.owner_a();
SET ROLE authenticated;
INSERT INTO t.ids VALUES('tv',public.create_product('{"name_ar":"تلفزيون","name_en":"TV","sku":"S8-TV","cash_price":"1140","eta_item_code":"EG-674859545-TV","eta_item_type":"EGS"}'));
INSERT INTO t.ids VALUES('fan',public.create_product('{"name_ar":"مروحة","name_en":"Fan","sku":"S8-FAN","cash_price":"300"}'));
INSERT INTO t.ids VALUES('cheap',public.create_product('{"name_ar":"كوب","name_en":"Cup","sku":"S8-CUP","cash_price":"100","eta_item_code":"EG-674859545-CUP","eta_item_type":"EGS"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"هاتف","name_en":"Phone","sku":"S8-PHONE","cash_price":"5000","is_serialized":true,"eta_item_code":"EG-674859545-PH","eta_item_type":"EGS"}'));
INSERT INTO t.ids VALUES('tab',public.create_product('{"name_ar":"تابلت","name_en":"Tablet","sku":"S8-TAB","cash_price":"3000","is_serialized":true,"eta_item_code":"EG-674859545-TB","eta_item_type":"EGS"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',40),
  jsonb_build_object('product_id',t.id('fan'),'quantity',40),jsonb_build_object('product_id',t.id('cheap'),'quantity',5)),'s08-found');
SELECT public.register_units(t.id('phone'),t.id('main'),'3000.00','["S8-P-1","S8-P-2","S8-P-3","S8-P-4"]',NULL,'s08-units-phone');
SELECT public.register_units(t.id('tab'),t.id('main'),'2000.00','["S8-T-1"]',NULL,'s08-units-tab');
SELECT public.update_branch(t.id('main'),'Main','16 Abbas El Akkad','Nasr City','Cairo',NULL,'0',
  (SELECT default_cash_account_id FROM public.branches WHERE id=t.id('main')),'14');
INSERT INTO t.ids VALUES('second',public.create_branch('Second','S2',NULL,NULL,NULL,NULL,NULL));
SELECT public.set_eta_settings('preprod','client-s08','secret-s08-1','4753',true);
SELECT public.set_device_eta(t.id('pos1'),'POS-A1','android 14','1','key-a1','active');
SELECT public.set_device_eta(t.id('pos2'),'POS-A2','android 14','1','key-a2','active');
SELECT public.set_device_eta(t.id('pos3'),'POS-A3','android 14','1','key-a3','active');
SELECT public.set_device_eta(t.id('pos4'),'POS-A4','android 14','1','key-a4','active');
RESET ROLE;
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),t.id('manager'),t.id('second'));
INSERT INTO public.devices(organization_id,branch_id,name) SELECT t.org('a'),t.id('second'),'POS S';
INSERT INTO t.ids SELECT 'poss',id FROM public.devices WHERE name='POS S' AND organization_id=t.org('a');
SELECT t.emp('mgr2','a','a0800000-0000-0000-8000-000000000009','S08 Manager 2','BRANCH_MANAGER','second');

-- ---------------------------------------------------------------- S4 settings bounds
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.error('S4 a max sale of 150 000 is refused','SELECT public.set_offline_settings(true,''150000.00'',12,100,''200000.00'')','VALIDATION_FAILED');
SELECT t.error('S4 21 hours is refused','SELECT public.set_offline_settings(true,''20000.00'',21,100,''200000.00'')','VALIDATION_FAILED');
SELECT t.error('S4 0 sales is refused','SELECT public.set_offline_settings(true,''20000.00'',12,0,''200000.00'')','VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'settings',public.set_offline_settings(true,'20000.00',12,100,'200000.00');
INSERT INTO t.docs SELECT 'settings_read',public.get_offline_settings();
RESET ROLE;
SELECT t.expect('S4 the owner turns offline on with the defaults',
  t.doc('settings')=jsonb_build_object('offline_enabled',true,'offline_max_sale_total','20000.00','offline_max_hours',12,
                                       'offline_max_sales',100,'offline_max_lease_total','200000.00')
  AND t.doc('settings_read')=t.doc('settings'),t.doc('settings')::text);
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.error('S4 a cashier can''t change the offline settings','SELECT public.set_offline_settings(true,''20000.00'',12,100,''200000.00'')','PERMISSION_DENIED');
RESET ROLE;
SELECT t.expect('S4 the setting is audited',(SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='offline.settings_updated'));

-- Shifts: the cashier on POS 1, the owner on POS 2, cashier 2 on POS 3, cashier 3 on POS 4, the
-- manager on POS X (no ETA registration), manager 2 on POS S (the second branch).
SELECT t.cashier(); SET ROLE authenticated; SELECT t.open('s1','pos1','s08-shift-1'); RESET ROLE;
SELECT t.owner_a(); SET ROLE authenticated; SELECT t.open('s2','pos2','s08-shift-2'); RESET ROLE;
SELECT t.cashier2(); SET ROLE authenticated; SELECT t.open('s3','pos3','s08-shift-3'); RESET ROLE;
SELECT t.cashier3(); SET ROLE authenticated; SELECT t.open('s4','pos4','s08-shift-4'); RESET ROLE;
SELECT t.manager(); SET ROLE authenticated; SELECT t.open('sx','posx','s08-shift-x'); RESET ROLE;
SELECT t.mgr2(); SET ROLE authenticated; SELECT t.open('ss','poss','s08-shift-s'); RESET ROLE;

-- ---------------------------------------------------------------- S2 lease refusals
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.error('S2 no device token: DEVICE_REVOKED',format('SELECT public.issue_offline_lease(%L,NULL)',t.pubkey()),'DEVICE_REVOKED');
RESET ROLE;
SELECT t.cashier2(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
SELECT t.error('S2 another cashier''s shift: OFFLINE_NOT_SHIFT_OWNER',format('SELECT public.issue_offline_lease(%L,NULL)',t.pubkey()),'OFFLINE_NOT_SHIFT_OWNER');
RESET ROLE;
SELECT t.manager(); SELECT t.pos(t.id('posx'));
SET ROLE authenticated;
SELECT t.error('S2 ETA on, the device not ETA-active: OFFLINE_ETA_NOT_READY',format('SELECT public.issue_offline_lease(%L,NULL)',t.pubkey()),'OFFLINE_ETA_NOT_READY');
RESET ROLE;
SELECT t.owner_b();
SET ROLE authenticated;
SELECT t.open('bs','bpos','s08-shift-b');
SELECT t.error('S2 offline disabled: OFFLINE_DISABLED',format('SELECT public.issue_offline_lease(%L,NULL)',t.pubkey()),'OFFLINE_DISABLED');
RESET ROLE;
SELECT t.wh(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
SELECT t.error('S2 no sale.create: PERMISSION_DENIED',format('SELECT public.issue_offline_lease(%L,NULL)',t.pubkey()),'PERMISSION_DENIED');
RESET ROLE;

-- ---------------------------------------------------------------- S3 lease content
SELECT t.cashier(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'L1',public.issue_offline_lease(t.pubkey(),NULL);
INSERT INTO t.docs SELECT 'L1b',public.issue_offline_lease(t.pubkey(),t.doc('L1')->'lease'->>'snapshot_hash');
RESET ROLE;
SELECT t.expect('S3 the lease: the device, its shift, its cashier, the limits, sequence 1, the chain head, the code D1',
  t.doc('L1')->'lease'->>'device_id'=t.id('pos1')::text AND t.doc('L1')->'lease'->>'shift_id'=t.id('s1')::text
  AND t.doc('L1')->'lease'->>'cashier_id'=t.id('cashier')::text AND (t.doc('L1')->'lease'->>'next_seq')::integer=1
  AND t.doc('L1')->'lease'->'limits'->>'max_sale_total'='20000.00' AND t.doc('L1')->'lease'->>'chain_head'=''
  AND t.doc('L1')->>'offline_code'='D1' AND (t.doc('L1')->'eta'->>'enabled')::boolean
  AND t.doc('L1')->'eta'->>'device_serial'='POS-A1' AND t.doc('L1')->'eta'->'seller'->>'building_number'='14'
  AND (t.doc('L1')->'lease'->>'expires_at')::timestamptz=(t.doc('L1')->'lease'->>'issued_at')::timestamptz+interval '12 hours',
  (t.doc('L1')->'lease')::text);
SELECT t.expect('S3 the snapshot has no cost, supplier or margin',
  t.doc('L1')->'snapshot' IS NOT NULL AND (t.doc('L1')->'snapshot')::text !~* 'cost|supplier|margin'
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(t.doc('L1')->'snapshot'->'products') p,jsonb_object_keys(p) k WHERE k ~* 'cost|supplier|margin'));
SELECT t.expect('S3 ETA on: a product without an ETA code is not sellable offline (NO_ETA_CODE); stock and units are there',
  (SELECT p->>'offline_sellable'='false' AND p->>'reason'='NO_ETA_CODE' FROM jsonb_array_elements(t.doc('L1')->'snapshot'->'products') p WHERE p->>'id'=t.id('fan')::text)
  AND (SELECT (p->>'on_hand')::integer=40 AND p->>'price'='1140.00' AND p->>'offline_sellable'='true' FROM jsonb_array_elements(t.doc('L1')->'snapshot'->'products') p WHERE p->>'id'=t.id('tv')::text)
  AND (SELECT jsonb_array_length(p->'units')=4 FROM jsonb_array_elements(t.doc('L1')->'snapshot'->'products') p WHERE p->>'id'=t.id('phone')::text));
SELECT t.expect('S3 the same content reuses the snapshot row and is not sent again; one key, audited once',
  t.doc('L1b')->'lease'->>'snapshot_id'=t.doc('L1')->'lease'->>'snapshot_id' AND jsonb_typeof(t.doc('L1b')->'snapshot')='null'
  AND (SELECT count(*)=1 FROM public.offline_snapshots WHERE branch_id=t.id('main'))
  AND (SELECT count(*)=1 FROM public.device_offline_keys WHERE device_id=t.id('pos1'))
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='device.offline_key_added' AND entity_id=t.id('pos1')));

-- ---------------------------------------------------------------- S5 the direct-database path
SELECT t.mk('a1','L1','[{"p":"tv","q":2}]');
SELECT t.mk('a2','L1','[{"p":"tv","q":1}]');
SELECT t.mk('a3','L1','[{"p":"phone","q":1,"serial":"S8-P-1"}]');
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.error('S5 a cashier without a device: DEVICE_REVOKED',format('SELECT public.sync_offline_sales(%L)',t.items('a1')),'DEVICE_REVOKED');
RESET ROLE;
SELECT t.cashier(); SELECT t.pos(t.id('pos3'));
SET ROLE authenticated;
SELECT t.error('S5 another device''s token: DEVICE_MISMATCH',format('SELECT public.sync_offline_sales(%L)',t.items('a1')),'DEVICE_MISMATCH');
SELECT t.state('S5 app.offline_process as authenticated: permission denied',format('SELECT app.offline_process(%L,true,true,NULL)',gen_random_uuid()),'42501');
SELECT t.state('S5 the worker''s wrapper as authenticated: permission denied',format('SELECT public.offline_worker_process(%L,true,true,NULL)',gen_random_uuid()),'42501');
SELECT t.state('S5 a direct INSERT into offline_sales is refused',
  format('INSERT INTO public.offline_sales(organization_id,branch_id,device_id,seq,number,idempotency_key,issued_at,content,content_hash,signature,total,source) VALUES(%L,%L,%L,1,''x'',''x'',now(),''{}'',repeat(''a'',64),''x'',1,''sync'')',t.org('a'),t.id('main'),t.id('pos1')),'42501');
SELECT t.state('S5 a direct INSERT into fiscal_submissions is refused',
  format('INSERT INTO public.fiscal_submissions(organization_id,branch_id,doc_type,environment,internal_id) VALUES(%L,%L,''b2c_receipt'',''preprod'',''x'')',t.org('a'),t.id('main')),'42501');
SELECT t.state('S5 the content is not readable by authenticated','SELECT content FROM public.offline_sales','42501');
SELECT t.state('S5 the signature is not readable by authenticated','SELECT signature FROM public.offline_sales','42501');
RESET ROLE;
SELECT t.expect('S5 grants: the content and signature columns are not granted; the worker''s functions are the service role''s',
  NOT has_column_privilege('authenticated','public.offline_sales','content','SELECT')
  AND NOT has_column_privilege('authenticated','public.offline_sales','signature','SELECT')
  AND has_column_privilege('authenticated','public.offline_sales','status','SELECT')
  AND NOT has_table_privilege('authenticated','public.offline_leases','INSERT')
  AND NOT has_function_privilege('authenticated','app.offline_load_received(uuid,integer)','EXECUTE')
  AND has_function_privilege('service_role','app.offline_process(uuid,boolean,boolean,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.sync_offline_sales(jsonb)','EXECUTE'));

-- ---------------------------------------------------------------- S6 / S8 receive, in sequence order
SELECT t.cashier(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
-- Sent out of order: received in sequence order, answered in request order.
INSERT INTO t.docs SELECT 'r1',public.sync_offline_sales(t.items('a3','a1','a2'));
RESET ROLE;
SELECT t.expect('S6 three new sales are received (answered in request order)',
  t.result(t.doc('r1'),0)='received' AND t.result(t.doc('r1'),1)='received' AND t.result(t.doc('r1'),2)='received'
  AND (t.doc('r1')->'results'->0->>'seq')::integer=3 AND t.st('a1')='received' AND (t.os('a1')).source='sync'
  AND (t.os('a1')).lease_id=(t.doc('L1')->'lease'->>'id')::uuid AND (t.os('a1')).shift_id=t.id('s1'),t.doc('r1')::text);
SELECT t.expect('S8 three items: the head is the last UUID; each chained to the one before, no fork',
  t.head('pos1')=t.doc('a3')->>'uuid' AND t.doc('a1')->>'prev'='' AND t.doc('a2')->>'prev'=t.doc('a1')->>'uuid'
  AND t.events('a1','chain_fork')+t.events('a2','chain_fork')+t.events('a3','chain_fork')=0
  AND t.events('a1','offline_received')=1,t.head('pos1'));
SELECT t.expect('S8 the fiscal row carries the printed receipt: UUID, previous, payload text, pending, not released',
  (t.fs('a1')).eta_uuid=t.doc('a1')->>'uuid' AND (t.fs('a1')).previous_uuid='' AND (t.fs('a1')).status='pending'
  AND (t.fs('a1')).offline_released_at IS NULL AND (t.fs('a1')).sale_id IS NULL AND (t.fs('a1')).internal_id=t.doc('a1')->>'number'
  AND ((t.fs('a1')).payload->>'receipt_json')::jsonb->'header'->>'uuid'=t.doc('a1')->>'uuid'
  AND (SELECT count(*)=1 FROM public.jobs WHERE job_type='offline.process' AND dedupe_key='offline.process:'||t.id('pos1') AND status='queued'));
SELECT t.mk('a1x','L1','[{"p":"tv","q":5}]','{"seq":1}');
SELECT t.cashier(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r2',public.sync_offline_sales(t.items('a1'));
INSERT INTO t.docs SELECT 'r3',public.sync_offline_sales(t.items('a1x'));
RESET ROLE;
SELECT t.expect('S6 the same item again: duplicate, one row',
  t.result(t.doc('r2'),0)='duplicate' AND (SELECT count(*)=1 FROM public.offline_sales WHERE device_id=t.id('pos1') AND seq=1));
SELECT t.expect('S6 the same sequence with other content: rejected SEQ_REUSED, an alert, nothing stored',
  t.result(t.doc('r3'),0)='rejected:SEQ_REUSED' AND t.alerts('SEQ_REUSED')=1 AND t.os('a1x') IS NULL
  AND (SELECT count(*)=1 FROM public.offline_sales WHERE device_id=t.id('pos1') AND seq=1));
-- A receipt that is not its sale's; another shop's tax number; a gap (sequence 6 never arrives).
SELECT t.mk('m1','L1','[{"p":"tv","q":1}]','{"receipt_total":"999.00"}');
SELECT t.mk('n1','L1','[{"p":"tv","q":1}]','{"rin":"313717919"}');
UPDATE t.dev SET seq=seq+1 WHERE device=t.id('pos1');
SELECT t.mk('gp','L1','[{"p":"tv","q":1}]');
SELECT t.cashier(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r4',public.sync_offline_sales(t.items('m1','n1','gp'));
RESET ROLE;
SELECT t.expect('S6 another shop''s tax number: NOT_OURS, stored rejected, an alert, no fiscal row',
  t.result(t.doc('r4'),1)='rejected:NOT_OURS' AND t.st('n1')='rejected:NOT_OURS' AND t.fs('n1') IS NULL AND t.alerts('NOT_OURS')=1);
SELECT t.expect('S6 a gap: the seq_gap flag (sequence 6 missing)',
  t.result(t.doc('r4'),2)='received' AND (t.os('gp')).flags=ARRAY['seq_gap']
  AND (SELECT after->>'missing_from'='6' AND after->>'missing_to'='6' FROM public.audit_log WHERE action='offline.alert' AND after->>'code'='SEQ_GAP'),
  (t.os('gp')).flags::text);
SELECT t.expect('S7 a receipt that is not the body''s: hold RECEIPT_MISMATCH, an offline.bug alert',
  t.result(t.doc('r4'),0)='received:RECEIPT_MISMATCH' AND (t.os('m1')).fiscal_hold='RECEIPT_MISMATCH' AND t.alerts('offline.bug')=1);

-- ---------------------------------------------------------------- S9 process: posted, verification failed
INSERT INTO t.docs SELECT 'before',jsonb_build_object('drawer',t.drawer('s1'),'tv',t.level('tv'));
SELECT t.svc(); SET ROLE service_role;
INSERT INTO t.docs SELECT 'p_a1',t.run('a1');
INSERT INTO t.docs SELECT 'p_a2',t.run('a2',false,true);
INSERT INTO t.docs SELECT 'p_a3',t.run('a3');
INSERT INTO t.docs SELECT 'p_a1_again',t.run('a1');
RESET ROLE;
SELECT t.expect('S9 posted: the offline number, the printed time, offline_created_at, the shift and cashier',
  t.st('a1')='posted' AND (t.sale('a1')).number=t.doc('a1')->>'number'
  AND (t.sale('a1')).issued_at=(t.doc('a1')->>'issued_at')::timestamptz AND (t.sale('a1')).offline_created_at=(t.sale('a1')).issued_at
  AND (t.sale('a1')).shift_id=t.id('s1') AND (t.sale('a1')).device_id=t.id('pos1') AND (t.sale('a1')).created_by=t.id('cashier')
  AND (t.sale('a1')).total=2280 AND (t.sale('a1')).idempotency_key=t.doc('a1')->>'idem',t.doc('p_a1')::text);
SELECT t.expect('S9 posted: stock -2, drawer +total, one fiscal row (the offline one, linked), released, eta.submit queued',
  t.level('tv')=(t.doc('before')->>'tv')::integer-2 AND t.drawer('s1')=(t.doc('before')->>'drawer')::numeric+2280+5000
  AND (SELECT count(*)=1 FROM public.fiscal_submissions WHERE sale_id=(t.sale('a1')).id)
  AND (t.fs('a1')).sale_id=(t.sale('a1')).id AND (t.fs('a1')).offline_released_at IS NOT NULL AND (t.fs('a1')).qr_payload='qr-'||(t.doc('a1')->>'number')
  AND t.events('a1','offline_released')=1
  AND (SELECT count(*)>=1 FROM public.jobs WHERE job_type='eta.submit' AND dedupe_key LIKE 'eta.submit:'||t.id('pos1')||'%'),
  concat_ws(' ',t.level('tv'),t.drawer('s1')));
SELECT t.expect('S9 a serial: the unit is sold',
  t.st('a3')='posted' AND (SELECT status='sold' FROM public.units WHERE id=t.unit('S8-P-1')));
SELECT t.expect('S9 processed twice: the second run skips',(t.doc('p_a1_again')->>'skipped')::boolean);
SELECT t.expect('S9 verification failed: rejected VERIFY_FAILED, the fiscal row cancelled, an alert and an event, no sale',
  t.st('a2')='rejected:VERIFY_FAILED' AND (t.fs('a2')).status='cancelled' AND (t.fs('a2')).last_error='OFFLINE_VERIFY_FAILED'
  AND (t.fs('a2')).offline_released_at IS NULL AND t.alerts('VERIFY_FAILED')=1 AND t.events('a2','offline_verify_failed')=1
  AND (t.os('a2')).sale_id IS NULL);
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('m1'); SELECT t.run('gp');
RESET ROLE;
SELECT t.expect('S7 the mismatched receipt''s sale is posted, but its fiscal row is never released',
  t.st('m1')='posted' AND (t.fs('m1')).offline_released_at IS NULL AND t.st('gp')='posted');

-- ---------------------------------------------------------------- S10-S13, S8: conflicts and edge cases
SELECT t.mk('sr','L1','[{"p":"phone","q":1,"serial":"S8-P-2"}]');
SELECT t.mk('lx','L1','[{"p":"tv","q":20}]');
SELECT t.mk('pm','L1','[{"p":"tv","q":1,"price":"1000.00"}]');
SELECT t.mk('tm','L1','[{"p":"tv","q":1}]','{"bad_tax":true}');
SELECT t.mk('sh','L1','[{"p":"cheap","q":3}]');
SELECT t.mk('du','L1','[{"p":"tv","q":1}]',jsonb_build_object('idem','5e8e0c4e-0000-4000-8000-00000000d0d0'));
SELECT t.mk('fk','L1','[{"p":"tv","q":1}]',jsonb_build_object('prev',repeat('f',64)));
SELECT t.mk('tb','L1','[{"p":"tv","q":1}]','{"at":"-10 minutes"}');
SELECT t.mk('d3','L1','[{"p":"tv","q":1}]','{"at":"-3 days"}');
SELECT t.mk('ta','L1','[{"p":"tv","q":1}]','{"at":"13 hours"}');
-- Meanwhile, online on POS 2: the serial S8-P-2, four of the five cups, and the sale whose answer
-- was lost (the offline duplicate carries its key).
SELECT t.owner_a(); SELECT t.pos(t.id('pos2'));
SET ROLE authenticated;
SELECT public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'quantity',1,'unit_id',t.unit('S8-P-2'))),'5000.00','s08-online-p2');
SELECT public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('cheap'),'quantity',4)),'400.00','s08-online-cups');
INSERT INTO t.ids SELECT 'online_du',(public.post_sale(jsonb_build_array(jsonb_build_object('product_id',t.id('tv'),'quantity',1)),'1140.00','5e8e0c4e-0000-4000-8000-00000000d0d0')->>'id')::uuid;
RESET ROLE;
SELECT t.cashier(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'r5',public.sync_offline_sales(t.items('sr','lx','pm','tm','sh','du','fk','tb','d3','ta'));
RESET ROLE;
SELECT t.expect('S8 a previousUUID that is not the head: a chain_fork event with both values, and the head still moves',
  t.events('fk','chain_fork')=1 AND t.events('sh','chain_fork')=0
  AND (SELECT message FROM public.fiscal_events WHERE fiscal_id=(t.fs('fk')).id AND kind='chain_fork')
      ='head='||(t.doc('du')->>'uuid')||' previous='||repeat('f',64)
  AND t.head('pos1')=t.doc('ta')->>'uuid');
SELECT t.svc(); SET ROLE service_role;
SELECT t.run(x) FROM unnest(ARRAY['sr','lx','pm','tm','sh','du','fk','tb','d3','ta']) x;
RESET ROLE;
SELECT t.expect('S10 the serial sold online meanwhile: SERIAL_UNAVAILABLE, the receipt still released',
  t.st('sr')='conflict:SERIAL_UNAVAILABLE' AND (t.fs('sr')).offline_released_at IS NOT NULL);
SELECT t.expect('S10 over the lease''s max sale: LIMIT_EXCEEDED, released',
  t.st('lx')='conflict:LIMIT_EXCEEDED' AND (t.fs('lx')).offline_released_at IS NOT NULL);
SELECT t.expect('S10 a price below the snapshot: PRICE_MISMATCH, released',
  t.st('pm')='conflict:PRICE_MISMATCH' AND (t.fs('pm')).offline_released_at IS NOT NULL);
SELECT t.expect('S10 before the lease and after it expired: TIME_INVALID, released',
  t.st('tb')='conflict:TIME_INVALID' AND t.st('ta')='conflict:TIME_INVALID'
  AND (t.fs('tb')).offline_released_at IS NOT NULL AND (t.fs('ta')).offline_released_at IS NOT NULL);
SELECT t.expect('S11 totals T01 does not give: TOTALS_MISMATCH, hold RECEIPT_MISMATCH, never released, offline.bug',
  t.st('tm')='conflict:TOTALS_MISMATCH' AND (t.os('tm')).fiscal_hold='RECEIPT_MISMATCH'
  AND (t.fs('tm')).offline_released_at IS NULL AND t.alerts('offline.bug')=2);
SELECT t.expect('S12 a shortage: an adjustment then the sale, on_hand 0, the stock_adjusted flag, the ledger reconciles',
  t.st('sh')='posted' AND (t.os('sh')).flags @> ARRAY['stock_adjusted'] AND t.level('cheap')=0
  AND (SELECT count(*)=1 FROM public.stock_adjustments WHERE organization_id=t.org('a') AND note='S08 offline shortage: '||(t.doc('sh')->>'number'))
  AND (SELECT sum(quantity)=2 FROM public.stock_movements WHERE organization_id=t.org('a') AND product_id=t.id('cheap') AND type='adjustment'
       AND source_id=(SELECT id FROM public.stock_adjustments WHERE note='S08 offline shortage: '||(t.doc('sh')->>'number')))
  AND NOT EXISTS (SELECT 1 FROM app.ledger_mismatches(t.org('a'))),t.level('cheap')::text);
SELECT t.expect('S13 the online sale with the same key exists: duplicate, the offline receipt cancelled, still one sale, reprint_needed',
  t.st('du')='duplicate' AND (t.os('du')).sale_id=t.id('online_du') AND (t.os('du')).flags @> ARRAY['reprint_needed']
  AND (t.fs('du')).status='cancelled' AND (t.fs('du')).last_error='OFFLINE_DUPLICATE_OF_ONLINE' AND t.events('du','offline_duplicate')=1
  AND (SELECT count(*)=1 FROM public.sales WHERE organization_id=t.org('a') AND idempotency_key='5e8e0c4e-0000-4000-8000-00000000d0d0'));
SELECT t.expect('S8 the forked receipt is posted and released like any other',t.st('fk')='posted' AND (t.fs('fk')).offline_released_at IS NOT NULL);

-- D12.2: what is held or not processed is never claimed for sending; what is released is.
SELECT t.svc(); SET ROLE service_role;
INSERT INTO t.docs SELECT 'claim',public.eta_claim_for_submit(t.id('pos1'),500,300);
INSERT INTO t.docs SELECT 'deadline',public.eta_claim_deadline_alerts(t.id('pos1'),20,now()+interval '21 hours');
RESET ROLE;
SELECT t.expect('D12.2 the submit loader takes released rows only, oldest first',
  (SELECT bool_and(x->>'internal_id' NOT IN (t.doc('m1')->>'number',t.doc('tm')->>'number',t.doc('a2')->>'number',t.doc('du')->>'number'))
          AND bool_or(x->>'internal_id'=t.doc('a1')->>'number') AND bool_or(x->>'internal_id'=t.doc('d3')->>'number')
          AND (array_agg(x->>'internal_id' ORDER BY o))[1]=t.doc('d3')->>'number'
   FROM jsonb_array_elements(t.doc('claim')) WITH ORDINALITY y(x,o)),t.doc('claim')::text);
SELECT t.expect('D12.3 the deadline alert counts an offline receipt from its offline sale''s time',
  (SELECT bool_or(x->>'internal_id'=t.doc('m1')->>'number') FROM jsonb_array_elements(t.doc('deadline')) x));

-- ---------------------------------------------------------------- S19 correction of an offline receipt without a sale
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.error('S19 a T03 correction of an offline receipt whose sale isn''t posted: OFFLINE_REVIEW_REQUIRED',
  format('SELECT public.fiscal_request_correction(%L)',(t.fs('tm')).id),'OFFLINE_REVIEW_REQUIRED');
RESET ROLE;

-- ---------------------------------------------------------------- S15 resolution
SELECT t.cashier();
SET ROLE authenticated;
SELECT t.error('S15 a cashier: PERMISSION_DENIED',format('SELECT public.resolve_offline_sale(%L,''use_serial'',''the right unit'',%L)',(t.os('sr')).id,
  jsonb_build_object('1',t.unit('S8-P-3'))),'PERMISSION_DENIED');
SELECT t.error('S15 a cashier can''t list them',format('SELECT public.list_offline_sales(NULL,NULL)'),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.owner_b();
SET ROLE authenticated;
SELECT t.error('S15 another shop: not found',format('SELECT public.resolve_offline_sale(%L,''accept'',''not mine'')',(t.os('lx')).id),'OFFLINE_SALE_NOT_FOUND');
SELECT t.error('S15 another shop can''t read it either',format('SELECT public.get_offline_sale(%L)',(t.os('lx')).id),'OFFLINE_SALE_NOT_FOUND');
INSERT INTO t.docs SELECT 'list_b',public.list_offline_sales(NULL,NULL);
RESET ROLE;
SELECT t.expect('S15 another shop''s list is empty',t.doc('list_b')='[]'::jsonb);
SELECT t.manager();
SET ROLE authenticated;
SELECT t.error('S15 no reason: REASON_REQUIRED',format('SELECT public.resolve_offline_sale(%L,''accept'','' '')',(t.os('lx')).id),'REASON_REQUIRED');
SELECT t.error('S15 a wrong action for the code: RESOLUTION_NOT_ALLOWED',format('SELECT public.resolve_offline_sale(%L,''use_serial'',''why not'',%L)',(t.os('lx')).id,
  jsonb_build_object('1',t.unit('S8-P-3'))),'RESOLUTION_NOT_ALLOWED');
SELECT t.error('S15 reject is only for a revoked lease: RESOLUTION_NOT_ALLOWED',format('SELECT public.resolve_offline_sale(%L,''reject'',''no way'')',(t.os('pm')).id),'RESOLUTION_NOT_ALLOWED');
SELECT t.error('S11 TOTALS_MISMATCH has no action: RESOLUTION_NOT_ALLOWED',format('SELECT public.resolve_offline_sale(%L,''accept'',''looks fine'')',(t.os('tm')).id),'RESOLUTION_NOT_ALLOWED');
SELECT t.error('S15 use_serial with another product''s unit is refused',format('SELECT public.resolve_offline_sale(%L,''use_serial'',''the tablet'',%L)',(t.os('sr')).id,
  jsonb_build_object('1',t.unit('S8-T-1'))),'UNIT_PRODUCT_MISMATCH');
INSERT INTO t.docs SELECT 'res_sr',public.resolve_offline_sale((t.os('sr')).id,'use_serial','the box held S8-P-3',jsonb_build_object('1',t.unit('S8-P-3')));
INSERT INTO t.docs SELECT 'res_lx',public.resolve_offline_sale((t.os('lx')).id,'accept','the customer paid in full, ok');
INSERT INTO t.docs SELECT 'list',public.list_offline_sales('conflict',NULL);
INSERT INTO t.docs SELECT 'detail',public.get_offline_sale((t.os('pm')).id);
RESET ROLE;
SELECT t.expect('S15 the list and the detail: no content; the printed lines, the payment',
  jsonb_array_length(t.doc('list'))>=4 AND NOT (t.doc('list')::text LIKE '%"content"%')
  AND t.doc('detail')->'lines'->0->>'unit_price'='1000.00' AND t.doc('detail')->'lines'->0->>'sku'='S8-TV'
  AND t.doc('detail')->'payment'->>'amount'='1000.00' AND NOT (t.doc('detail') ? 'content') AND NOT (t.doc('detail') ? 'signature'),
  t.doc('detail')::text);
SELECT t.expect('S15 a resolution: received again, the override stored, the reason, an audit row, offline.process queued',
  t.st('sr')='received' AND (t.os('sr')).overrides->'units'->>'1'=t.unit('S8-P-3')::text AND (t.os('sr')).resolution_reason='the box held S8-P-3'
  AND (SELECT count(*)=2 FROM public.audit_log WHERE action='offline_sale.resolved' AND organization_id=t.org('a')));
-- D10: the receipt was released with the conflict, and the ETA accepted it before the decision.
UPDATE public.fiscal_submissions SET status='accepted', accepted_at=now(), eta_uuid=(t.os('sr')).eta_uuid, updated_at=now()
 WHERE id=(t.fs('sr')).id;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('sr'); SELECT t.run('lx');
RESET ROLE;
SELECT t.expect('S15 a receipt accepted before the decision: the posted sale is linked to it, nothing else changes',
  (t.fs('sr')).sale_id=(t.sale('sr')).id AND (t.fs('sr')).status='accepted' AND (t.fs('sr')).offline_sale_id=(t.os('sr')).id);
SELECT t.error('S15 an accepted receipt stays final otherwise',
  format('UPDATE public.fiscal_submissions SET last_error=''x'' WHERE id=%L',(t.fs('sr')).id),'DOCUMENT_FINAL');
SELECT t.expect('S15 use_serial with a valid unit: posted with that unit; accept: posted',
  t.st('sr')='posted' AND (SELECT unit_id=t.unit('S8-P-3') FROM public.sale_lines WHERE sale_id=(t.sale('sr')).id)
  AND t.st('lx')='posted' AND (t.sale('lx')).total=22800);
SELECT t.expect('D11 a posted sale ends identical to its printed receipt (number, time, total)',
  (SELECT bool_and(s.total=(t.doc(x)->>'total')::numeric AND s.number=t.doc(x)->>'number' AND s.issued_at=(t.doc(x)->>'issued_at')::timestamptz)
   FROM unnest(ARRAY['a1','a3','sr','lx','sh','fk']) x JOIN public.sales s ON s.id=(t.os(x)).sale_id));

-- ---------------------------------------------------------------- S21 closed days
SELECT t.owner_a();
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'pv3',public.get_day_close_preview(t.id('main'),t.day('a',3));
SELECT t.error('S21 a day with an offline sale in conflict can''t be closed: OFFLINE_SALES_OPEN',
  format('SELECT public.close_day(%L,%L,%L,''S08 test close'')',t.id('main'),t.day('a',3),t.doc('pv3')->>'hash'),'OFFLINE_SALES_OPEN');
RESET ROLE;
SELECT t.manager();
SET ROLE authenticated;
SELECT public.resolve_offline_sale((t.os('d3')).id,'accept','sold three days ago, the network was down');
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('d3');
RESET ROLE;
SELECT t.expect('S21 resolved: posted on its own (open) day',
  t.st('d3')='posted' AND (t.sale('d3')).business_date=t.day('a',3) AND NOT ((t.os('d3')).flags @> ARRAY['late_business_date']));
SELECT t.owner_a();
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'pv3b',public.get_day_close_preview(t.id('main'),t.day('a',3));
INSERT INTO t.docs SELECT 'close3',public.close_day(t.id('main'),t.day('a',3),t.doc('pv3b')->>'hash','S08 test close');
-- Day -2 is closed while d2 is still on the device: the server can't see it.
INSERT INTO t.docs SELECT 'pv2',public.get_day_close_preview(t.id('main'),t.day('a',2));
INSERT INTO t.docs SELECT 'close2',public.close_day(t.id('main'),t.day('a',2),t.doc('pv2')->>'hash','S08 test close');
RESET ROLE;
SELECT t.expect('S21 after resolving, K04 closes the day; the next day closes too',
  t.doc('close3')->>'status'='closed' AND t.doc('close2')->>'status'='closed');
INSERT INTO t.docs SELECT 'day2_before',t.day_totals(t.day('a',2));
SELECT t.mk('d2','L1','[{"p":"tv","q":1}]','{"at":"-2 days"}');
SELECT t.cashier(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
SELECT public.sync_offline_sales(t.items('d2'));
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('d2');
RESET ROLE;
SELECT t.manager();
SET ROLE authenticated;
SELECT public.resolve_offline_sale((t.os('d2')).id,'accept','sold two days ago, synced late');
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('d2');
RESET ROLE;
SELECT t.expect('S21 a sale of a closed day: posted on today''s open day, late_business_date, issued_at unchanged, the closed day untouched',
  t.st('d2')='posted' AND (t.sale('d2')).business_date=t.day('a',0) AND (t.os('d2')).flags @> ARRAY['late_business_date']
  AND (t.sale('d2')).issued_at=(t.doc('d2')->>'issued_at')::timestamptz
  AND t.day_totals(t.day('a',2))=t.doc('day2_before'),t.day_totals(t.day('a',2))::text);

-- ---------------------------------------------------------------- S16 shift close, S10 SHIFT_CLOSED, post_to_shift
SELECT t.cashier2(); SELECT t.pos(t.id('pos3'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'L3',public.issue_offline_lease(t.pubkey('N'),NULL);
RESET ROLE;
SELECT t.mk('b1','L3','[{"p":"tv","q":1}]');
SELECT t.mk('b2','L3','[{"p":"tv","q":1}]');
SELECT t.cashier2(); SELECT t.pos(t.id('pos3'));
SET ROLE authenticated;
SELECT public.sync_offline_sales(t.items('b1'));
SELECT t.error('S16 the cashier''s close with a received offline sale: OFFLINE_SALES_OPEN',
  format('SELECT public.close_shift(%L,''{}''::jsonb,NULL,NULL)',t.id('s3')),'OFFLINE_SALES_OPEN');
RESET ROLE;
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.error('S16 force_close_shift with a received offline sale: OFFLINE_SALES_OPEN',
  format('SELECT public.force_close_shift(%L,''0'',''the cashier left'')',t.id('s3')),'OFFLINE_SALES_OPEN');
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('b1');
RESET ROLE;
SELECT t.cashier2(); SELECT t.pos(t.id('pos3'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'close_s3',public.close_shift(t.id('s3'),'{}'::jsonb,NULL,'counted nothing, test');
RESET ROLE;
SELECT t.expect('S16 posted: the cashier''s close works',t.st('b1')='posted' AND (SELECT status='closed' FROM public.shifts WHERE id=t.id('s3')));
-- b2 was sold before the close and reaches the server after it.
SELECT t.cashier2(); SELECT t.pos(t.id('pos3'));
SET ROLE authenticated;
SELECT public.sync_offline_sales(t.items('b2'));
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('b2');
RESET ROLE;
SELECT t.expect('S10 the shift was closed while the device was offline: SHIFT_CLOSED, released',
  t.st('b2')='conflict:SHIFT_CLOSED' AND (t.fs('b2')).offline_released_at IS NOT NULL);
INSERT INTO t.docs SELECT 'drawer2',to_jsonb(t.drawer('s2'));
SELECT t.manager();
SET ROLE authenticated;
SELECT t.error('S15 post_to_shift to an open shift of another branch is refused',
  format('SELECT public.resolve_offline_sale(%L,''post_to_shift'',''the second branch'',NULL,%L)',(t.os('b2')).id,t.id('ss')),'SHIFT_NOT_FOUND');
SELECT public.resolve_offline_sale((t.os('b2')).id,'post_to_shift','into the owner''s drawer',NULL,t.id('s2'));
RESET ROLE;
SELECT t.owner_a();
SET ROLE authenticated;
SELECT t.error('S16 the target shift can''t close while the sale waits for it',
  format('SELECT public.force_close_shift(%L,''0'',''end of day'')',t.id('s2')),'OFFLINE_SALES_OPEN');
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('b2');
RESET ROLE;
SELECT t.expect('S15 post_to_shift in the same branch: posted into that drawer',
  t.st('b2')='posted' AND (t.sale('b2')).shift_id=t.id('s2') AND t.drawer('s2')=(t.doc('drawer2')#>>'{}')::numeric+1140);

-- ---------------------------------------------------------------- S14 lease revoked, S17 import
SELECT t.cashier3(); SELECT t.pos(t.id('pos4'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'L4',public.issue_offline_lease(t.pubkey('P'),NULL);
RESET ROLE;
SELECT t.owner_a();
SET ROLE authenticated;
SELECT public.unpair_device(t.id('pos4'));
RESET ROLE;
SELECT t.expect('S14 unpairing revokes the device''s leases',
  (SELECT bool_and(revoked_at IS NOT NULL) FROM public.offline_leases WHERE device_id=t.id('pos4')));
SELECT t.mk('v1','L4','[{"p":"tv","q":1}]','{"at":"30 seconds"}');
SELECT t.mk('v2','L4','[{"p":"tv","q":1}]','{"at":"30 seconds"}');
SELECT t.cashier3(); SELECT t.pos(t.id('pos4'),false);
SET ROLE authenticated;
SELECT t.error('S14 the unpaired device can''t sync: DEVICE_REVOKED',format('SELECT public.sync_offline_sales(%L)',t.items('v1')),'DEVICE_REVOKED');
SELECT t.error('S17 import needs offline.resolve',format('SELECT public.import_offline_sales(%L,%L)',t.id('pos4'),t.items('v1')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.manager();
SET ROLE authenticated;
SELECT t.error('S17 another shop''s device: DEVICE_NOT_FOUND',format('SELECT public.import_offline_sales(%L,%L)',t.id('bpos'),t.items('v1')),'DEVICE_NOT_FOUND');
SELECT t.error('S17 more than 500 items is refused',format('SELECT public.import_offline_sales(%L,%L)',t.id('pos4'),
  (SELECT jsonb_agg(t.item('v1')) FROM generate_series(1,501))),'VALIDATION_FAILED');
INSERT INTO t.docs SELECT 'imp',public.import_offline_sales(t.id('pos4'),t.items('v1','v2'));
RESET ROLE;
SELECT t.expect('S17 imported rows land with source import (here held: LEASE_REVOKED)',
  t.result(t.doc('imp'),0)='received:LEASE_REVOKED' AND (t.os('v1')).source='import' AND (t.os('v2')).source='import'
  AND (t.os('v1')).fiscal_hold='LEASE_REVOKED'
  AND (SELECT count(*)=1 FROM public.audit_log WHERE action='offline_sales.imported' AND organization_id=t.org('a')),t.doc('imp')::text);
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('v1'); SELECT t.run('v2');
RESET ROLE;
SELECT t.expect('S14 a sale under a revoked lease waits for the manager, its receipt not released',
  t.st('v1')='conflict:LEASE_REVOKED' AND (t.fs('v1')).offline_released_at IS NULL AND (t.os('v1')).sale_id IS NULL);
SELECT t.manager();
SET ROLE authenticated;
SELECT public.resolve_offline_sale((t.os('v1')).id,'accept','the device was found, the sale is real');
SELECT public.resolve_offline_sale((t.os('v2')).id,'reject','the device was stolen');
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('v1');
RESET ROLE;
SELECT t.expect('S14 accept: released and posted',
  t.st('v1')='posted' AND (t.fs('v1')).offline_released_at IS NOT NULL AND (t.os('v1')).fiscal_hold IS NULL);
SELECT t.expect('S14 reject: rejected, the fiscal row cancelled, never released',
  t.st('v2')='rejected:LEASE_REVOKED' AND (t.fs('v2')).status='cancelled' AND (t.fs('v2')).offline_released_at IS NULL);
SELECT t.owner_a();
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'fc4',public.force_close_shift(t.id('s4'),'0','the drawer went with the device');
RESET ROLE;
SELECT t.expect('S16 once resolved, force_close_shift works',(SELECT status='closed' FROM public.shifts WHERE id=t.id('s4')));

-- ---------------------------------------------------------------- S18 a shop with ETA off
SELECT t.owner_e();
SET ROLE authenticated;
SELECT t.open('es','epos','s08-shift-e');
SELECT public.set_offline_settings(true,'20000.00',12,100,'200000.00');
INSERT INTO t.ids VALUES('ecup',public.create_product('{"name_ar":"كوب","name_en":"Cup","sku":"S8E-CUP","cash_price":"50"}'));
SELECT public.post_stock_adjustment(t.id('emain'),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',t.id('ecup'),'quantity',10)),'s08e-found');
INSERT INTO t.docs SELECT 'LE',public.issue_offline_lease(t.pubkey('E'),NULL);
RESET ROLE;
SELECT t.mk('e1','LE','[{"p":"ecup","q":2}]');
SELECT t.owner_e(); SELECT t.pos(t.id('epos'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 're',public.sync_offline_sales(t.items('e1'));
RESET ROLE;
SELECT t.svc(); SET ROLE service_role;
SELECT t.run('e1');
RESET ROLE;
SELECT t.expect('S18 ETA off: no receipt, no fiscal row, posted',
  NOT (t.doc('LE')->'eta'->>'enabled')::boolean AND ((t.doc('e1')->>'content')::jsonb->'receipt')='null'::jsonb
  AND t.result(t.doc('re'),0)='received' AND t.fs('e1') IS NULL AND t.st('e1')='posted'
  AND (SELECT count(*)=0 FROM public.fiscal_submissions WHERE organization_id=t.org('e')));

-- ---------------------------------------------------------------- D15 the version a newer POS may send
SELECT t.cashier(); SELECT t.pos(t.id('pos1'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'rv',public.sync_offline_sales(jsonb_build_array(jsonb_build_object(
  'content',jsonb_set((t.doc('a1')->>'content')::jsonb,'{v}','2')::text,'signature',t.sig())));
RESET ROLE;
SELECT t.expect('D15 a newer content version waits on the device: retry_later, nothing stored',
  t.result(t.doc('rv'),0)='retry_later:UNSUPPORTED_VERSION');

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
