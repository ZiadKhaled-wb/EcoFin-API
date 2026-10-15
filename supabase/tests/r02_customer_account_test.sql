\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.errlike(n text,q text,p text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND SQLERRM LIKE p,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.today() RETURNS date LANGUAGE sql SECURITY DEFINER AS $$ SELECT app.org_today(t.org('a')) $$;
CREATE FUNCTION t.acct() RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.cash_accounts WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1 $$;

-- Everything below is written as the database owner: nothing creates contracts, collections or fees yet (N02-N05).
CREATE FUNCTION t.cust(p_tag text,p_name text) RETURNS void LANGUAGE sql AS $$
  WITH x AS (INSERT INTO public.customers(organization_id,full_name,phones) VALUES(t.org('a'),p_name,ARRAY['01000000777']) RETURNING id)
  INSERT INTO t.ids SELECT p_tag,id FROM x $$;
-- A sale of p_total for a customer, p_days_ago days ago (no lines: the account reads the header only).
CREATE FUNCTION t.sale(p_tag text,p_customer text,p_total numeric,p_days_ago integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.sales(organization_id,number,branch_id,customer_id,prices_include_vat,subtotal,total,business_date,idempotency_key)
    VALUES(t.org('a'),'R02-SL-'||p_tag,t.id('main'),t.id(p_customer),true,p_total,p_total,t.today()-p_days_ago,'r02-sale-'||p_tag) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('sale-'||p_tag,v_id);
END $$;
-- A contract on a sale (or on nothing: an M02 opening contract). is_migrated keeps the deferred R03/R04 checks out.
CREATE FUNCTION t.contract(p_tag text,p_customer text,p_sale text,p_cash numeric,p_down numeric,p_markup numeric,p_status text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_policy uuid;
BEGIN
  SELECT id INTO v_policy FROM public.installment_policies WHERE organization_id=t.org('a') ORDER BY version DESC LIMIT 1;
  INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,sale_id,policy_id,creditor,cash_price,down_payment,financed_amount,markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,status,closed_at,is_migrated,idempotency_key)
    VALUES(t.org('a'),'R02-C-'||p_tag,t.id(p_customer),t.id('main'),CASE WHEN p_sale IS NULL THEN NULL ELSE t.id('sale-'||p_sale) END,v_policy,'in_house',
           p_cash,p_down,p_cash-p_down,0,p_markup,p_cash-p_down+p_markup,4,'monthly',current_date,
           p_status::public.contract_status,CASE WHEN p_status IN ('active','rescheduled') THEN NULL ELSE now() END,true,'r02-c-'||p_tag) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('contract-'||p_tag,v_id);
END $$;
CREATE FUNCTION t.line(p_tag text,p_contract text,p_version integer,p_seq integer,p_due integer,p_principal numeric,p_profit numeric,p_superseded boolean DEFAULT false) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit,superseded)
    VALUES(t.org('a'),t.id('contract-'||p_contract),p_version,p_seq,t.today()+p_due,p_principal,p_profit,p_superseded) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('line-'||p_tag,v_id);
END $$;
-- A payment row of the customer (no allocation).
CREATE FUNCTION t.payment(p_tag text,p_customer text,p_dir text,p_method text,p_amount numeric,p_days_ago integer,p_reverses text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.payments(organization_id,number,branch_id,direction,method,amount,customer_id,cash_account_id,reference,business_date,reverses_payment_id,reason,idempotency_key)
    VALUES(t.org('a'),'R02-PY-'||p_tag,t.id('main'),p_dir::public.payment_direction,p_method::public.payment_method,p_amount,t.id(p_customer),
           CASE WHEN p_method='store_credit' THEN NULL ELSE t.acct() END,CASE WHEN p_method='bank_transfer' THEN 'TRX-'||p_tag END,
           t.today()-p_days_ago,CASE WHEN p_reverses IS NULL THEN NULL ELSE t.id('pay-'||p_reverses) END,
           CASE WHEN p_reverses IS NULL THEN NULL ELSE 'Wrong customer' END,'r02-pay-'||p_tag) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('pay-'||p_tag,v_id);
END $$;
-- A payment in on a schedule line (a collection).
CREATE FUNCTION t.collect(p_tag text,p_line text,p_principal numeric,p_profit numeric,p_days_ago integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_contract uuid; v_customer uuid; v_cust_tag text;
BEGIN
  SELECT sl.contract_id,c.customer_id INTO v_contract,v_customer FROM public.schedule_lines sl JOIN public.contracts c ON c.id=sl.contract_id WHERE sl.id=t.id('line-'||p_line);
  SELECT tag INTO v_cust_tag FROM t.ids WHERE id=v_customer LIMIT 1;
  PERFORM t.payment(p_tag,v_cust_tag,'in','cash',p_principal+p_profit,p_days_ago);
  INSERT INTO public.payment_allocations(organization_id,payment_id,amount,schedule_line_id,contract_id,principal_amount,profit_amount)
    VALUES(t.org('a'),t.id('pay-'||p_tag),p_principal+p_profit,t.id('line-'||p_line),v_contract,p_principal,p_profit);
END $$;
-- A payment in that pays a sale.
CREATE FUNCTION t.paysale(p_tag text,p_customer text,p_sale text,p_method text,p_amount numeric,p_days_ago integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.payment(p_tag,p_customer,'in',p_method,p_amount,p_days_ago);
  INSERT INTO public.payment_allocations(organization_id,payment_id,amount,sale_id) VALUES(t.org('a'),t.id('pay-'||p_tag),p_amount,t.id('sale-'||p_sale));
  IF p_method='store_credit' THEN
    INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date)
      VALUES(t.org('a'),t.id(p_customer),-p_amount,'sale',t.id('sale-'||p_sale),t.id('main'),t.today()-p_days_ago);
  END IF;
END $$;
CREATE FUNCTION t.ret(p_tag text,p_sale text,p_kind text,p_method text,p_total numeric,p_days_ago integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.sales_returns(organization_id,number,sale_id,branch_id,kind,refund_method,subtotal,total,reason,business_date,idempotency_key)
    VALUES(t.org('a'),'R02-RT-'||p_tag,t.id('sale-'||p_sale),t.id('main'),p_kind::public.return_kind,p_method::public.refund_method,p_total,p_total,'R02 test',t.today()-p_days_ago,'r02-ret-'||p_tag) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('ret-'||p_tag,v_id);
END $$;
-- A refund of a return: cash goes out, store credit goes back to the customer's balance (no cash account).
CREATE FUNCTION t.refund(p_tag text,p_customer text,p_ret text,p_method text,p_amount numeric,p_days_ago integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.payment(p_tag,p_customer,'out',p_method,p_amount,p_days_ago);
  INSERT INTO public.payment_allocations(organization_id,payment_id,amount,return_id) VALUES(t.org('a'),t.id('pay-'||p_tag),p_amount,t.id('ret-'||p_ret));
  IF p_method='store_credit' THEN
    INSERT INTO public.store_credit_movements(organization_id,customer_id,amount,source_type,source_id,branch_id,business_date)
      VALUES(t.org('a'),t.id(p_customer),p_amount,'sales_return',t.id('ret-'||p_ret),t.id('main'),t.today()-p_days_ago);
  END IF;
END $$;
CREATE FUNCTION t.fee(p_tag text,p_line text,p_amount numeric,p_days_ago integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.charges(organization_id,contract_id,schedule_line_id,assessed_on,amount)
    SELECT t.org('a'),sl.contract_id,sl.id,t.today()-p_days_ago,p_amount FROM public.schedule_lines sl WHERE sl.id=t.id('line-'||p_line) RETURNING id INTO v_id;
  INSERT INTO t.ids VALUES('fee-'||p_tag,v_id);
END $$;
CREATE FUNCTION t.waive(p_fee text,p_amount numeric) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.charge_waivers(organization_id,charge_id,amount,reason,approved_by,idempotency_key)
  VALUES(t.org('a'),t.id('fee-'||p_fee),p_amount,'Good customer',(SELECT id FROM public.employees WHERE organization_id=t.org('a') AND role='OWNER' LIMIT 1),'r02-waive-'||p_fee) $$;
CREATE FUNCTION t.bal(p_customer text,k text) RETURNS numeric LANGUAGE sql AS $$ SELECT (app.customer_open_balance(t.org('a'),t.id(p_customer))->>k)::numeric $$;
CREATE FUNCTION t.remaining(p_customer text) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum(remaining),0) FROM public.v_contract_balances WHERE customer_id=t.id(p_customer) AND status IN ('active','rescheduled') $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shops a, b (retail), c (starter: no customers module)
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('R02 '||s,'r02-'||s,p,'Owner',s||'r02@example.com',NULL,'Main',h,now()+interval '1 day')
FROM (VALUES('a','retail',repeat('x',64)),('b','retail',repeat('y',64)),('c','starter',repeat('z',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0740000-0000-0000-8000-000000000001','ar02@example.com'),('a0740000-0000-0000-8000-000000000002','br02@example.com'),
  ('a0740000-0000-0000-8000-000000000003','r02cashier@example.com'),('a0740000-0000-0000-8000-000000000006','r02warehouse@example.com'),
  ('a0740000-0000-0000-8000-000000000008','cr02@example.com');
SELECT public.accept_invite(repeat('x',64),'a0740000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('y',64),'a0740000-0000-0000-8000-000000000002');
SELECT public.accept_invite(repeat('z',64),'a0740000-0000-0000-8000-000000000008');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES
  (t.org('a'),'a0740000-0000-0000-8000-000000000003','R02 Cashier','CASHIER'),
  (t.org('a'),'a0740000-0000-0000-8000-000000000006','R02 Warehouse','WAREHOUSE');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') ORDER BY created_at LIMIT 1;

-- ob: two installment sales; k1 12 000 (10 000 + 2 000 markup), k2 7 200 (6 000 + 1 200); 3 000 collected on k1
SELECT t.cust('ob','Open Balance Customer');
SELECT t.sale('s1','ob',10000,40); SELECT t.contract('k1','ob','s1',10000,0,2000,'active');
SELECT t.line('k1a','k1',1,1,-30,2500,500); SELECT t.line('k1b','k1',1,2,-5,2500,500); SELECT t.line('k1c','k1',1,3,25,2500,500); SELECT t.line('k1d','k1',1,4,55,2500,500);
SELECT t.sale('s2','ob',6000,35); SELECT t.contract('k2','ob','s2',6000,0,1200,'active');
SELECT t.line('k2a','k2',1,1,-3,3000,600); SELECT t.line('k2b','k2',1,2,27,3000,600);
SELECT t.collect('c1','k1a',2500,500,29);
-- a completed contract of the same customer (paid in full) and a reversed collection on k2
SELECT t.sale('s3','ob',1000,90); SELECT t.contract('k3','ob','s3',1000,0,0,'completed');
SELECT t.line('k3a','k3',1,1,-60,1000,0); SELECT t.collect('c3','k3a',1000,0,61);
SELECT t.collect('c2','k2a',500,0,2); SELECT t.payment('c2r','ob','out','cash',500,1,'c2');

-- rs: a rescheduled contract: v1 two lines of 2 500, 1 000 paid on the first, both superseded; v2 one line of 4 200
SELECT t.cust('rs','Rescheduled Customer');
SELECT t.contract('k4','rs',NULL,5000,0,0,'rescheduled');
SELECT t.line('k4a','k4',1,1,-40,2500,0,true); SELECT t.line('k4b','k4',1,2,-10,2500,0,true);
SELECT t.collect('c4','k4a',1000,0,45);
SELECT t.line('k4n','k4',2,1,30,4000,200);

-- od: lines 100, 45 and 10 days late and one not yet due
SELECT t.cust('od','Overdue Customer');
SELECT t.contract('k5','od',NULL,4000,0,0,'active');
SELECT t.line('k5a','k5',1,1,-100,1000,0); SELECT t.line('k5b','k5',1,2,-45,1000,0); SELECT t.line('k5c','k5',1,3,-10,1000,0); SELECT t.line('k5d','k5',1,4,20,1000,0);

-- st: the statement customer (expected running balance in the comments)
SELECT t.cust('st','Statement Customer');
SELECT t.sale('a','st',1000,30); SELECT t.paysale('pa','st','a','cash',1000,30);                          -- 0
SELECT t.sale('b','st',5000,25); SELECT t.paysale('pb','st','b','bank_transfer',1000,25);                 -- 4 000
SELECT t.contract('k6','st','b',5000,1000,800,'active');                                                   -- 4 800
SELECT t.line('k6a','k6',1,1,-20,1000,200); SELECT t.line('k6b','k6',1,2,10,1000,200); SELECT t.line('k6c','k6',1,3,40,1000,200); SELECT t.line('k6d','k6',1,4,70,1000,200);
SELECT t.collect('pk','k6a',1000,200,20);                                                                  -- 3 600
SELECT t.fee('f1','k6b',100,15);                                                                           -- 3 700
SELECT t.sale('c','st',500,10); SELECT t.paysale('pc','st','c','cash',500,10);                            -- 3 700
SELECT t.ret('v','c','void','cash',500,10); SELECT t.refund('rv','st','v','cash',500,10);                 -- 3 700
SELECT t.sale('d','st',300,5); SELECT t.paysale('pd','st','d','cash',300,5);                              -- 3 700
SELECT t.ret('r','d','return','store_credit',300,5); SELECT t.refund('rr','st','r','store_credit',300,5); -- 3 400 (store credit 300)
SELECT t.sale('e','st',200,2); SELECT t.paysale('pe','st','e','store_credit',200,2);                      -- 3 600 (store credit 100)
SELECT t.waive('f1',40);                                                                                   -- 3 560 (today)

-- nothing: a customer of shop a with no money at all; b1: shop B's customer
SELECT t.cust('nothing','Quiet Customer');
WITH x AS (INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('b'),'Shop B Customer') RETURNING id) INSERT INTO t.ids SELECT 'b1',id FROM x;
-- documents: an ID photo of ob and a file on its contract k1
INSERT INTO public.files(organization_id,path,original_name,mime,size_bytes,purpose,entity_type,entity_id) VALUES
  (t.org('a'),t.org('a')::text||'/r02-ob.png','id.png','image/png',100,'customer_id','customer',t.id('ob')),
  (t.org('a'),t.org('a')::text||'/r02-k1.pdf','contract.pdf','application/pdf',100,'customer_id','contract',t.id('contract-k1'));

-- ================================================================ open balance (the slice's "Done when")
SELECT t.expect('contract total: a contract never rescheduled = its total payable (12 000)',app.customer_contract_total(t.org('a'),t.id('contract-k1'))=12000.00);
SELECT t.expect('open balance without returns = the views'' remaining (12 000 + 7 200 - 3 000 = 16 200)',
  t.bal('ob','open_balance')=16200 AND t.bal('ob','open_balance')=t.remaining('ob'),app.customer_open_balance(t.org('a'),t.id('ob'))::text);
SELECT t.expect('open balance: a completed contract adds 0 and a reversed collection does not count',
  t.bal('ob','contract_totals')=19200 AND t.bal('ob','payments')=3000);
SELECT t.ret('adj','s2','return','contract_adjustment',1200,1);
SELECT t.expect('Done when: open balance = contract totals 19 200 - payments 3 000 - returns 1 200 = 15 000',
  t.bal('ob','contract_totals')=19200 AND t.bal('ob','payments')=3000 AND t.bal('ob','returns')=1200 AND t.bal('ob','open_balance')=15000);
SELECT t.expect('open balance: a return refunded another way is not a contract return',
  t.bal('st','returns')=0 AND t.bal('st','open_balance')=3600);
SELECT t.expect('rescheduled: contract total = current lines 4 200 + 1 000 paid on superseded lines = 5 200; open 4 200 = the views',
  app.customer_contract_total(t.org('a'),t.id('contract-k4'))=5200 AND t.bal('rs','open_balance')=4200 AND t.remaining('rs')=4200);
SELECT t.expect('open balance: a customer with nothing owes 0',t.bal('nothing','open_balance')=0 AND t.bal('nothing','total_due')=0);
SELECT t.expect('open balance: another shop sees nothing',(app.customer_open_balance(t.org('b'),t.id('ob'))->>'open_balance')::numeric=0);

-- fees
SELECT t.fee('f2','k1b',150,3); SELECT t.waive('f2',50);
SELECT t.expect('fees: 150 charged, 50 waived = 100 due; total due = open balance + 100; not in the open balance',
  t.bal('ob','fees_due')=100 AND t.bal('ob','total_due')=15100 AND t.bal('ob','open_balance')=15000);

-- ================================================================ overdue
SELECT t.expect('overdue: 100, 45 and 10 days late land in their buckets, one line not yet due',
  (SELECT a->>'late_1_30'='1000.00' AND a->>'late_31_60'='1000.00' AND a->>'late_61_90'='0.00' AND a->>'late_90_plus'='1000.00' AND a->>'not_yet_due'='1000.00'
   FROM (SELECT app.customer_overdue_json(t.org('a'),t.id('od'))->'aging' a) x),app.customer_overdue_json(t.org('a'),t.id('od'))::text);
SELECT t.expect('overdue: 3 000 on three lines, max 100 days late, next due = the oldest unpaid line',
  (SELECT o->>'overdue_amount'='3000.00' AND (o->>'overdue_lines')::int=3 AND (o->>'max_days_late')::int=100
          AND (o->>'next_due_date')::date=t.today()-100 AND o->>'next_due_amount'='1000.00'
   FROM (SELECT app.customer_overdue_json(t.org('a'),t.id('od')) o) x));
SELECT t.collect('c5','k5a',1000,0,0);
SELECT t.expect('overdue: once the oldest line is paid, next due moves to the 45-day line and the 90+ bucket empties',
  (SELECT (o->>'next_due_date')::date=t.today()-45 AND o->>'overdue_amount'='2000.00' AND o->'aging'->>'late_90_plus'='0.00'
   FROM (SELECT app.customer_overdue_json(t.org('a'),t.id('od')) o) x));
SELECT t.expect('overdue: a customer without contracts has zeros and nulls',
  (SELECT o->>'overdue_amount'='0.00' AND (o->>'overdue_lines')::int=0 AND o->>'max_days_late' IS NULL AND o->>'next_due_date' IS NULL AND o->>'next_due_amount' IS NULL
   FROM (SELECT app.customer_overdue_json(t.org('a'),t.id('nothing')) o) x));

-- ================================================================ the public reads (owner of shop a)
SELECT t.as_user('a0740000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('account: the balance block carries the open balance, fees, store credit and the R03 numbers',
  (SELECT b->>'open_balance'='15000.00' AND b->>'fees_due'='100.00' AND b->>'total_due'='15100.00' AND b->>'store_credit'='0.00'
          AND b->>'credit_limit'='0.00' AND b->>'available'='0.00'
   FROM (SELECT public.get_customer_account(t.id('ob'))->'balance' b) x),public.get_customer_account(t.id('ob'))->>'balance');
SELECT t.expect('account: the customer head has no national ID',
  (SELECT a->'customer'->>'full_name'='Open Balance Customer' AND a->'customer'->'phones'='["01000000777"]'::jsonb AND NOT (a->'customer' ? 'national_id')
   FROM (SELECT public.get_customer_account(t.id('ob')) a) x));
SELECT t.expect('account: every contract, newest first, with its balances',
  (SELECT jsonb_array_length(a->'contracts')=3 AND (SELECT count(*) FROM jsonb_array_elements(a->'contracts') c WHERE c->>'number'='R02-C-k1'
             AND c->>'total_payable'='12000.00' AND c->>'contract_total'='12000.00' AND c->>'paid'='3000.00' AND c->>'remaining'='9000.00'
             AND c->>'fees_due'='100.00' AND c->>'sale_number'='R02-SL-s1' AND c->'branch'->>'name' IS NOT NULL)=1
   FROM (SELECT public.get_customer_account(t.id('ob')) a) x));
SELECT t.expect('account: totals skip a voided sale, count every return and leave store-credit payments out',
  (SELECT x->>'purchases_count'='4' AND x->>'purchases_total'='6500.00' AND x->>'returns_count'='2' AND x->>'returns_total'='800.00'
          AND x->>'payments_in'='4000.00' AND x->>'payments_out'='500.00' AND x->>'last_purchase_at' IS NOT NULL AND x->>'last_payment_at' IS NOT NULL
   FROM (SELECT public.get_customer_account(t.id('st'))->'totals' x) y),public.get_customer_account(t.id('st'))->>'totals');
SELECT t.expect('account: recent payments are effective (a reversed one and its reversal are left out) and say what they paid',
  (SELECT jsonb_array_length(a->'recent_payments')=2
          AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(a->'recent_payments') p WHERE p->>'number' IN ('R02-PY-c2','R02-PY-c2r'))
          AND EXISTS (SELECT 1 FROM jsonb_array_elements(a->'recent_payments') p, jsonb_array_elements(p->'allocated_to') al
                      WHERE p->>'number'='R02-PY-c1' AND al->>'kind'='schedule_line' AND al->>'document_number'='R02-C-k1 #1' AND al->>'amount'='3000.00')
   FROM (SELECT public.get_customer_account(t.id('ob')) a) x),public.get_customer_account(t.id('ob'))->>'recent_payments');
SELECT t.expect('account: at most 10 recent payments, newest first',
  (SELECT jsonb_array_length(a->'recent_payments')=8 AND a->'recent_payments'->0->>'number'='R02-PY-pe'
   FROM (SELECT public.get_customer_account(t.id('st')) a) x),public.get_customer_account(t.id('st'))->>'recent_payments');
SELECT t.expect('account: recent returns with their sale',
  (SELECT jsonb_array_length(a->'recent_returns')=2 AND EXISTS (SELECT 1 FROM jsonb_array_elements(a->'recent_returns') r
     WHERE r->>'number'='R02-RT-v' AND r->>'kind'='void' AND r->>'sale_number'='R02-SL-c' AND r->>'total'='500.00')
   FROM (SELECT public.get_customer_account(t.id('st')) a) x));
SELECT t.expect('account: documents on the customer and on its contracts are counted',(public.get_customer_account(t.id('ob'))->>'documents_count')::int=2);
SELECT t.expect('account: a quiet customer reads with empty lists and zeros',
  (SELECT a->'contracts'='[]'::jsonb AND a->'recent_payments'='[]'::jsonb AND a->'recent_returns'='[]'::jsonb AND a->'totals'->>'purchases_total'='0.00'
          AND (a->>'documents_count')::int=0 AND a->'balance'->>'open_balance'='0.00'
   FROM (SELECT public.get_customer_account(t.id('nothing')) a) x));

-- schedule
SELECT t.expect('schedule: the current lines first, then the superseded ones, with their statuses',
  (SELECT string_agg((l->>'version')||'.'||(l->>'seq')||':'||(l->>'status'),',' ORDER BY o)='2.1:upcoming,1.1:superseded,1.2:superseded'
   FROM jsonb_array_elements(public.get_customer_contract_schedule(t.id('rs'),t.id('contract-k4'))->'lines') WITH ORDINALITY x(l,o)),
  public.get_customer_contract_schedule(t.id('rs'),t.id('contract-k4'))::text);
SELECT t.expect('schedule: paid, overdue and upcoming lines of k1 with days late only when overdue',
  (SELECT string_agg((l->>'seq')||':'||(l->>'status')||':'||(l->>'days_late')||':'||(l->>'remaining'),',' ORDER BY o)='1:paid:0:0.00,2:overdue:5:3000.00,3:upcoming:0:3000.00,4:upcoming:0:3000.00'
   FROM jsonb_array_elements(public.get_customer_contract_schedule(t.id('ob'),t.id('contract-k1'))->'lines') WITH ORDINALITY x(l,o)),
  public.get_customer_contract_schedule(t.id('ob'),t.id('contract-k1'))->>'lines');
SELECT t.expect('schedule: the fee with its waiver and what is due',
  (SELECT c->>'amount'='150.00' AND c->>'waived'='50.00' AND c->>'paid'='0.00' AND c->>'due'='100.00' AND (c->>'seq')::int=2
   FROM (SELECT public.get_customer_contract_schedule(t.id('ob'),t.id('contract-k1'))->'charges'->0 c) x));
SELECT t.expect('schedule: the contract block is the same as the account''s',
  public.get_customer_contract_schedule(t.id('ob'),t.id('contract-k1'))->'contract'
  =(SELECT c FROM jsonb_array_elements(public.get_customer_account(t.id('ob'))->'contracts') c WHERE c->>'number'='R02-C-k1'));
SELECT t.error('schedule: another customer''s contract',format('SELECT public.get_customer_contract_schedule(%L,%L)',t.id('st'),t.id('contract-k1')),'CONTRACT_NOT_FOUND');
SELECT t.error('schedule: an unknown contract',format('SELECT public.get_customer_contract_schedule(%L,%L)',t.id('ob'),gen_random_uuid()),'CONTRACT_NOT_FOUND');

-- statement
SELECT t.expect('statement: the rows of the whole history in order with the running balance',
  (SELECT string_agg(r->>'kind'||':'||(r->>'debit')::numeric::int||'/'||(r->>'credit')::numeric::int||'='||(r->>'balance')::numeric::int,',' ORDER BY o)
     ='sale:1000/0=1000,payment_in:0/1000=0,sale:5000/0=5000,contract:800/0=5800,payment_in:0/1000=4800,payment_in:0/1200=3600,fee:100/0=3700,'
    ||'sale:500/0=4200,payment_in:0/500=3700,payment_out:500/0=4200,return:0/500=3700,sale:300/0=4000,payment_in:0/300=3700,return:0/300=3400,sale:200/0=3600,fee_waiver:0/40=3560'
   FROM jsonb_array_elements(public.customer_statement(t.id('st'))->'rows') WITH ORDINALITY x(r,o)),
  public.customer_statement(t.id('st'))->>'rows');
SELECT t.expect('statement: closing without dates = total due - store credit (3 660 - 100 = 3 560)',
  (public.customer_statement(t.id('st'))->>'closing_balance')::numeric=3560
  AND (public.get_customer_account(t.id('st'))->'balance'->>'total_due')::numeric-(public.get_customer_account(t.id('st'))->'balance'->>'store_credit')::numeric=3560);
SELECT t.expect('statement: the closing check holds for every customer of the test',
  (SELECT bool_and((public.customer_statement(t.id(c))->>'closing_balance')::numeric
                   =(public.get_customer_account(t.id(c))->'balance'->>'total_due')::numeric-(public.get_customer_account(t.id(c))->'balance'->>'store_credit')::numeric)
   FROM unnest(ARRAY['ob','rs','od','st','nothing']) c));
SELECT t.expect('statement: a store-credit payment and a store-credit refund add no row; a void is a return row',
  NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.customer_statement(t.id('st'))->'rows') r WHERE r->>'number' IN ('R02-PY-pe','R02-PY-rr'))
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(public.customer_statement(t.id('st'))->'rows') r WHERE r->>'number'='R02-RT-v' AND r->>'kind'='return' AND r->>'detail'='void'));
SELECT t.expect('statement: a payment row says its method and its bank reference',
  EXISTS (SELECT 1 FROM jsonb_array_elements(public.customer_statement(t.id('st'))->'rows') r
          WHERE r->>'number'='R02-PY-pb' AND r->>'detail'='bank_transfer' AND r->>'reference'='TRX-pb'));
SELECT t.expect('statement: a reversal undoes its payment (credit 500, then debit 500)',
  (SELECT string_agg(r->>'kind'||':'||(r->>'debit')::numeric::int||'/'||(r->>'credit')::numeric::int,',' ORDER BY o)='payment_in:0/500,payment_reversal:500/0'
   FROM jsonb_array_elements(public.customer_statement(t.id('ob'))->'rows') WITH ORDINALITY x(r,o) WHERE r->>'number' IN ('R02-PY-c2','R02-PY-c2r')));
SELECT t.expect('statement: a contract without a sale (M02) adds its total payable',
  EXISTS (SELECT 1 FROM jsonb_array_elements(public.customer_statement(t.id('od'))->'rows') r WHERE r->>'kind'='contract' AND r->>'debit'='4000.00'));
SELECT t.expect('statement: a range: opening = everything before it, rows inside it, closing after them',
  (SELECT s->>'opening_balance'='3700.00' AND jsonb_array_length(s->'rows')=7 AND s->>'closing_balance'='3400.00'
          AND s->'totals'->>'debit'='1300.00' AND s->'totals'->>'credit'='1600.00' AND (s->>'from')::date=t.today()-12 AND (s->>'to')::date=t.today()-3
   FROM (SELECT public.customer_statement(t.id('st'),t.today()-12,t.today()-3) s) x),
  public.customer_statement(t.id('st'),t.today()-12,t.today()-3)::text);
SELECT t.expect('statement: only a start date runs to today',(public.customer_statement(t.id('st'),t.today()-1,NULL)->>'closing_balance')::numeric=3560
  AND (public.customer_statement(t.id('st'),t.today()-1,NULL)->>'opening_balance')::numeric=3600);
SELECT t.expect('statement: a quiet customer has no rows and 0',
  (SELECT s->'rows'='[]'::jsonb AND s->>'opening_balance'='0.00' AND s->>'closing_balance'='0.00' FROM (SELECT public.customer_statement(t.id('nothing')) s) x));
SELECT t.error('statement: from after to',format('SELECT public.customer_statement(%L,%L,%L)',t.id('st'),t.today(),t.today()-1),'VALIDATION_FAILED');
SELECT t.error('statement: more than three years',format('SELECT public.customer_statement(%L,%L,%L)',t.id('st'),t.today()-1100,t.today()),'VALIDATION_FAILED');
SELECT t.expect('statement: exactly three years is fine',public.customer_statement(t.id('st'),(t.today()-interval '3 years')::date,t.today()) IS NOT NULL);
RESET ROLE;

-- ================================================================ who and tenancy
SELECT t.as_user('a0740000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier (a customer read key): reads the account, the schedule and the statement',
  public.get_customer_account(t.id('ob')) IS NOT NULL AND public.get_customer_contract_schedule(t.id('ob'),t.id('contract-k1')) IS NOT NULL
  AND public.customer_statement(t.id('ob')) IS NOT NULL);
RESET ROLE;
SELECT t.as_user('a0740000-0000-0000-8000-000000000006',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('warehouse (no customer read key): no account',format('SELECT public.get_customer_account(%L)',t.id('ob')),'PERMISSION_DENIED');
SELECT t.error('warehouse: no schedule',format('SELECT public.get_customer_contract_schedule(%L,%L)',t.id('ob'),t.id('contract-k1')),'PERMISSION_DENIED');
SELECT t.error('warehouse: no statement',format('SELECT public.customer_statement(%L)',t.id('ob')),'PERMISSION_DENIED');
RESET ROLE;
SELECT t.as_user('a0740000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
SELECT t.error('shop B: shop A''s customer is not found (account)',format('SELECT public.get_customer_account(%L)',t.id('ob')),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop B: shop A''s customer is not found (schedule)',format('SELECT public.get_customer_contract_schedule(%L,%L)',t.id('ob'),t.id('contract-k1')),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop B: shop A''s customer is not found (statement)',format('SELECT public.customer_statement(%L)',t.id('ob')),'CUSTOMER_NOT_FOUND');
SELECT t.expect('shop B: its own customer reads',(public.get_customer_account(t.id('b1'))->'balance'->>'open_balance')='0.00');
RESET ROLE;
SELECT t.as_user('a0740000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('shop A: shop B''s customer is not found',format('SELECT public.customer_statement(%L)',t.id('b1')),'CUSTOMER_NOT_FOUND');
SELECT t.error('shop A: an unknown customer',format('SELECT public.get_customer_account(%L)',gen_random_uuid()),'CUSTOMER_NOT_FOUND');
RESET ROLE;
SELECT t.as_user('a0740000-0000-0000-8000-000000000008',t.org('c'));
SET LOCAL ROLE authenticated;
SELECT t.error('starter plan: no account',format('SELECT public.get_customer_account(%L)',gen_random_uuid()),'MODULE_NOT_IN_PLAN');
RESET ROLE;
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a0740000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: the account, the schedule and the statement still read',
  public.get_customer_account(t.id('ob')) IS NOT NULL AND public.get_customer_contract_schedule(t.id('ob'),t.id('contract-k1')) IS NOT NULL
  AND public.customer_statement(t.id('ob')) IS NOT NULL);
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');

-- ================================================================ nothing is granted that should not be
SELECT t.as_user('a0740000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.errlike('grants: authenticated can not call the open balance helper',format('SELECT app.customer_open_balance(%L,%L)',t.org('a'),t.id('ob')),'permission denied%');
SELECT t.errlike('grants: authenticated can not call the statement rows helper',format('SELECT * FROM app.customer_statement_rows(%L,%L)',t.org('a'),t.id('ob')),'permission denied%');
RESET ROLE;
SELECT t.expect('grants: exactly the three public functions are executable by authenticated and none by anon',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
     AND p.proname IN ('get_customer_account','get_customer_contract_schedule','customer_statement')
     AND has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE'))=3);
SELECT t.expect('grants: no app function of R02 is executable by authenticated or anon',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='app'
     AND p.proname IN ('customer_contract_total','customer_open_balance','customer_overdue_json','customer_contract_json','customer_payment_json','customer_statement_rows','customer_account_head')
     AND (has_function_privilege('authenticated',p.oid,'EXECUTE') OR has_function_privilege('anon',p.oid,'EXECUTE')))=0);
SELECT t.expect('reads only: no R02 call wrote an audit row',
  NOT EXISTS (SELECT 1 FROM public.audit_log WHERE organization_id=t.org('a') AND entity_id IN (SELECT id FROM t.ids)));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
