\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; RAISE EXCEPTION 'T_NO_ERROR'; EXCEPTION WHEN others THEN PERFORM t.expect(n,SQLERRM<>'T_NO_ERROR' AND split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.level(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE((SELECT on_hand FROM public.stock_levels WHERE product_id=t.id(p) AND branch_id=t.id(b) AND stock_state='sellable'),0) $$;
CREATE FUNCTION t.transit(p text,b text) RETURNS integer LANGUAGE sql AS $$
  SELECT COALESCE((SELECT in_transit FROM public.v_stock_in_transit WHERE product_id=t.id(p) AND branch_id=t.id(b)),0) $$;
-- Where every unit of a product is: on hand in any branch + in transit + written off by adjustments.
CREATE FUNCTION t.accounted(p text) RETURNS integer LANGUAGE sql AS $$
  SELECT (SELECT COALESCE(sum(on_hand),0) FROM public.stock_levels WHERE product_id=t.id(p) AND stock_state='sellable')::integer
       + (SELECT COALESCE(sum(in_transit),0) FROM public.v_stock_in_transit WHERE product_id=t.id(p))::integer
       - (SELECT COALESCE(sum(l.quantity),0) FROM public.stock_adjustment_lines l WHERE l.product_id=t.id(p))::integer $$;
CREATE FUNCTION t.move(p text,b text,q integer,u text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.stock_movements(organization_id,product_id,branch_id,unit_id,quantity,type,source_type,source_id)
  VALUES(t.org('a'),t.id(p),t.id(b),t.id(u),q,'opening','import',gen_random_uuid()) $$;
CREATE FUNCTION t.line(j jsonb,p text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT r FROM jsonb_array_elements(j->'lines') r WHERE r->>'product_id'=t.id(p)::text LIMIT 1 $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- setup: shop a (main, second), shop b
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('I03 '||s,'i03-'||s,'retail','Owner',s||'i03@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('r',64)),('b',repeat('s',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a3000000-0000-0000-8000-000000000001','ai03@example.com'),('a3000000-0000-0000-8000-000000000002','bi03@example.com'),('a3000000-0000-0000-8000-000000000003','i03sender@example.com'),('a3000000-0000-0000-8000-000000000004','i03receiver@example.com'),('a3000000-0000-0000-8000-000000000005','i03cashier@example.com');
SELECT public.accept_invite(repeat('r',64),'a3000000-0000-0000-8000-000000000001');
SELECT public.accept_invite(repeat('s',64),'a3000000-0000-0000-8000-000000000002');
INSERT INTO t.ids SELECT 'main',id FROM public.branches WHERE organization_id=t.org('a') AND is_main;
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
SELECT t.as_user('a3000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','I3',NULL,NULL,NULL,NULL,NULL));
INSERT INTO t.ids VALUES('cable',public.create_product('{"name_ar":"أ كابل","sku":"I03-CB","cash_price":"5"}'));
INSERT INTO t.ids VALUES('phone',public.create_product('{"name_ar":"ب موبايل","sku":"I03-PH","cash_price":"900","is_serialized":true}'));
RESET ROLE;
SELECT t.as_user('a3000000-0000-0000-8000-000000000002',t.org('b'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('cable_b',public.create_product('{"name_ar":"كابل ب","sku":"I03-CB","cash_price":"5"}'));
RESET ROLE;
-- The sender works in main, the receiver in second (both WAREHOUSE: transfer_send + transfer_receive);
-- the cashier (stock.view only) in main.
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a3000000-0000-0000-8000-000000000003','I03 Sender','WAREHOUSE',t.id('main')) RETURNING id AS sender_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'sender_id',t.id('main'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a3000000-0000-0000-8000-000000000004','I03 Receiver','WAREHOUSE',t.id('second')) RETURNING id AS receiver_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'receiver_id',t.id('second'));
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role,default_branch_id) VALUES(t.org('a'),'a3000000-0000-0000-8000-000000000005','I03 Cashier','CASHIER',t.id('main')) RETURNING id AS cashier_id \gset
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(t.org('a'),:'cashier_id',t.id('main'));
-- Opening stock (superuser; purchases are U02): cable 10 in main; phones SN-1, SN-2 in main, SN-3 in second.
UPDATE public.products SET avg_cost=3 WHERE id=t.id('cable');
INSERT INTO public.units(organization_id,product_id,serial,branch_id,cost)
SELECT t.org('a'),t.id('phone'),s,t.id(b),700 FROM (VALUES('I03-SN-1','main'),('I03-SN-2','main'),('I03-SN-3','second')) v(s,b);
INSERT INTO t.ids SELECT 'sn'||right(serial,1),id FROM public.units WHERE organization_id=t.org('a') AND product_id=t.id('phone');
SELECT t.move('cable','main',10),t.move('phone','main',1,'sn1'),t.move('phone','main',1,'sn2'),t.move('phone','second',1,'sn3');

-- ---------------------------------------------------------------- draft
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.create_stock_transfer(t.id('main'),t.id('second'),' Weekly refill ',
  jsonb_build_array(jsonb_build_object('product_id',t.id('cable'),'quantity',4)),'i03-transfer-1') AS d1 \gset
SELECT t.expect('a draft: TR number in the source branch, notes trimmed, nothing moved',
  :'d1'::jsonb->>'number' ~ '^MAIN-TR-\d{2}-000001$' AND :'d1'::jsonb->>'status'='draft' AND :'d1'::jsonb->>'notes'='Weekly refill'
  AND (:'d1'::jsonb->>'quantity_sent')::int=4 AND t.level('cable','main')=10 AND t.transit('cable','second')=0, :'d1'::text);
SELECT t.expect('same key again: the same transfer',
  (public.create_stock_transfer(t.id('main'),t.id('second'),NULL,'[{"product_id":"00000000-0000-0000-0000-000000000000","quantity":1}]','i03-transfer-1')->>'id')=(:'d1'::jsonb->>'id'));
SELECT t.error('to the same branch',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":1}]','i03-bad-1')$q$,t.id('main'),t.id('main'),t.id('cable')),'TRANSFER_SAME_BRANCH');
SELECT t.error('to another shop''s branch',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":1}]','i03-bad-2')$q$,t.id('main'),t.id('main_b'),t.id('cable')),'BRANCH_NOT_FOUND');
SELECT t.error('from a branch the sender doesn''t work in',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":1}]','i03-bad-3')$q$,t.id('second'),t.id('main'),t.id('cable')),'BRANCH_DENIED');
SELECT t.error('a serialized product needs its unit',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":1}]','i03-bad-4')$q$,t.id('main'),t.id('second'),t.id('phone')),'UNIT_REQUIRED');
SELECT t.error('a unit that is not in the source branch',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","unit_id":"%s","quantity":1}]','i03-bad-5')$q$,t.id('main'),t.id('second'),t.id('phone'),t.id('sn3')),'UNIT_NOT_AVAILABLE');
SELECT t.error('quantity zero',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":0}]','i03-bad-6')$q$,t.id('main'),t.id('second'),t.id('cable')),'VALIDATION_FAILED');
SELECT t.error('another shop''s product',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":1}]','i03-bad-7')$q$,t.id('main'),t.id('second'),t.id('cable_b')),'PRODUCT_NOT_FOUND');
SELECT public.update_stock_transfer((:'d1'::jsonb->>'id')::uuid,'Refill',
  jsonb_build_array(jsonb_build_object('product_id',t.id('cable'),'quantity',6),
                    jsonb_build_object('product_id',t.id('phone'),'unit_id',t.id('sn1'),'quantity',1))) AS u1 \gset
SELECT t.expect('a draft''s lines are replaced',
  (:'u1'::jsonb->>'lines_count')::int=2 AND (:'u1'::jsonb->>'quantity_sent')::int=7 AND :'u1'::jsonb->>'notes'='Refill'
  AND (t.line(:'u1'::jsonb,'phone')->>'serial')='I03-SN-1');

-- ---------------------------------------------------------------- send
SELECT public.send_stock_transfer((:'d1'::jsonb->>'id')::uuid) AS s1 \gset
SELECT t.expect('sent: the stock left main and is in transit to second; the unit is in transit',
  :'s1'::jsonb->>'status'='sent' AND :'s1'::jsonb->>'sent_by_name'='I03 Sender'
  AND t.level('cable','main')=4 AND t.level('cable','second')=0 AND t.transit('cable','second')=6
  AND t.level('phone','main')=1 AND t.transit('phone','second')=1
  AND (SELECT status='in_transit' FROM public.units WHERE id=t.id('sn1')));
RESET ROLE;
SELECT t.expect('Done when (in transit): every cable and phone is counted exactly once',
  t.accounted('cable')=10 AND t.accounted('phone')=3);
SELECT t.as_user('a3000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('I01 shows it in transit at the destination, not at the source (owner: every branch)',
  (SELECT r->>'in_transit'='6' AND r->>'on_hand'='0' FROM jsonb_array_elements(public.list_stock(p_limit=>100)->'items') r
   WHERE r->>'product_id'=t.id('cable')::text AND r->>'branch_id'=t.id('second')::text)
  AND (SELECT r->>'in_transit'='0' AND r->>'on_hand'='4' FROM jsonb_array_elements(public.list_stock(p_limit=>100)->'items') r
       WHERE r->>'product_id'=t.id('cable')::text AND r->>'branch_id'=t.id('main')::text));
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SELECT t.expect('sending again moves nothing',
  (public.send_stock_transfer((:'d1'::jsonb->>'id')::uuid)->>'status')='sent' AND t.level('cable','main')=4);
SELECT t.error('a sent transfer can''t be edited',format($q$SELECT public.update_stock_transfer(%L,NULL,'[{"product_id":"%s","quantity":1}]')$q$,:'d1'::jsonb->>'id',t.id('cable')),'TRANSFER_ALREADY_SENT');
SELECT t.error('a sent transfer can''t be cancelled',format('SELECT public.cancel_stock_transfer(%L)',:'d1'::jsonb->>'id'),'TRANSFER_ALREADY_SENT');
SELECT t.error('the sender can''t receive in a branch they don''t work in',format($q$SELECT public.receive_stock_transfer(%L,'[]')$q$,:'d1'::jsonb->>'id'),'BRANCH_DENIED');

-- ---------------------------------------------------------------- receive with a shortage
SELECT t.as_user('a3000000-0000-0000-8000-000000000004',t.org('a'));
SELECT t.error('received more than sent',format($q$SELECT public.receive_stock_transfer(%L,'[{"line_id":"%s","qty_received":6,"reason":"loss"}]')$q$,:'d1'::jsonb->>'id',t.line(:'s1'::jsonb,'cable')->>'id'),'VALIDATION_FAILED');
SELECT t.error('a line of another transfer',format($q$SELECT public.receive_stock_transfer(%L,'[{"line_id":"%s","qty_received":1,"reason":"loss"}]')$q$,:'d1'::jsonb->>'id',gen_random_uuid()),'VALIDATION_FAILED');
SELECT t.error('a shortage without a reason',format($q$SELECT public.receive_stock_transfer(%L,'[{"line_id":"%s","qty_received":5}]')$q$,:'d1'::jsonb->>'id',t.line(:'s1'::jsonb,'cable')->>'id'),'VALIDATION_FAILED');
SELECT public.receive_stock_transfer((:'d1'::jsonb->>'id')::uuid,
  jsonb_build_array(jsonb_build_object('line_id',t.line(:'s1'::jsonb,'cable')->>'id','qty_received',5,'reason','loss'))) AS r1 \gset
SELECT t.expect('received with 1 cable lost: partially received, 5 in second, the phone in stock there',
  :'r1'::jsonb->>'status'='partially_received' AND :'r1'::jsonb->>'received_by_name'='I03 Receiver'
  AND t.level('cable','second')=5 AND t.transit('cable','second')=0 AND t.level('phone','second')=2
  AND (SELECT status='in_stock' AND branch_id=t.id('second') FROM public.units WHERE id=t.id('sn1'))
  AND (t.line(:'r1'::jsonb,'cable')->>'qty_received')::int=5 AND t.line(:'r1'::jsonb,'cable')->>'discrepancy_reason'='loss', :'r1'::text);
SELECT t.expect('the shortage is an adjustment with its reason at the destination',
  jsonb_array_length(:'r1'::jsonb->'adjustments')=1 AND :'r1'::jsonb->'adjustments'->0->>'reason'='loss'
  AND (SELECT a.branch_id=t.id('second') AND a.note='Transfer '||(:'d1'::jsonb->>'number') AND l.quantity=-1
       FROM public.stock_adjustments a JOIN public.stock_adjustment_lines l ON l.adjustment_id=a.id
       WHERE a.id=(:'r1'::jsonb->'adjustments'->0->>'id')::uuid));
SELECT t.expect('receiving again moves nothing',
  (public.receive_stock_transfer((:'d1'::jsonb->>'id')::uuid,'[]')->>'status')='partially_received' AND t.level('cable','second')=5);
RESET ROLE;
SELECT t.expect('Done when (received): never in both branches or in neither (main 4 + second 5 + 1 written off = 10)',
  t.accounted('cable')=10 AND t.accounted('phone')=3 AND t.level('cable','main')+t.level('cable','second')=9);
SELECT t.expect('the receipt adjustment carries a system key nobody else can use',
  (SELECT idempotency_key='system:transfer/'||(:'d1'::jsonb->>'id')||'/loss' FROM public.stock_adjustments
   WHERE id=(:'r1'::jsonb->'adjustments'->0->>'id')::uuid));
SELECT t.expect('the ledger: transfer_out at the source, transfer_in at the destination, both pointing at the transfer',
  (SELECT count(*)=2 FROM public.stock_movements WHERE source_type='transfer' AND source_id=(:'d1'::jsonb->>'id')::uuid AND type='transfer_out')
  AND (SELECT sum(quantity)=7 FROM public.stock_movements WHERE source_type='transfer' AND source_id=(:'d1'::jsonb->>'id')::uuid AND type='transfer_in' AND branch_id=t.id('second'))
  AND (SELECT unit_cost=3 FROM public.stock_movements WHERE source_id=(:'d1'::jsonb->>'id')::uuid AND type='transfer_out' AND product_id=t.id('cable')));

-- ---------------------------------------------------------------- a damaged serial, a cancelled draft, out of stock
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.create_stock_transfer(t.id('main'),t.id('second'),NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.id('sn2'),'quantity',1)),'i03-transfer-2') AS d2 \gset
SELECT public.send_stock_transfer((:'d2'::jsonb->>'id')::uuid) AS s2 \gset
SELECT t.as_user('a3000000-0000-0000-8000-000000000004',t.org('a'));
SELECT public.receive_stock_transfer((:'d2'::jsonb->>'id')::uuid,
  jsonb_build_array(jsonb_build_object('line_id',:'s2'::jsonb->'lines'->0->>'id','qty_received',0,'reason','damage'))) AS r2 \gset
SELECT t.expect('a serial that arrived broken is written off at the destination (reason damage)',
  :'r2'::jsonb->'adjustments'->0->>'reason'='damage'
  AND (SELECT status='written_off' AND branch_id=t.id('second') FROM public.units WHERE id=t.id('sn2'))
  AND t.level('phone','main')=0 AND t.level('phone','second')=2);
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SELECT public.create_stock_transfer(t.id('main'),t.id('second'),NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('cable'),'quantity',99)),'i03-transfer-3') AS d3 \gset
SELECT t.error('sending more than on hand -> OUT_OF_STOCK',format('SELECT public.send_stock_transfer(%L)',:'d3'::jsonb->>'id'),'OUT_OF_STOCK');
SELECT t.expect('the failed send left the draft and the stock alone',
  (public.get_stock_transfer((:'d3'::jsonb->>'id')::uuid)->>'status')='draft' AND t.level('cable','main')=4);
SELECT t.as_user('a3000000-0000-0000-8000-000000000004',t.org('a'));
SELECT t.error('a draft can''t be received',format($q$SELECT public.receive_stock_transfer(%L,'[]')$q$,:'d3'::jsonb->>'id'),'TRANSFER_NOT_SENT');
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SELECT t.expect('a draft is cancelled (twice answers the same)',
  (public.cancel_stock_transfer((:'d3'::jsonb->>'id')::uuid)->>'status')='cancelled'
  AND (public.cancel_stock_transfer((:'d3'::jsonb->>'id')::uuid)->>'status')='cancelled');
-- Security review: a unit reserved after the draft was saved stays in the branch.
RESET ROLE;
INSERT INTO public.units(organization_id,product_id,serial,branch_id,cost) VALUES(t.org('a'),t.id('phone'),'I03-SN-4',t.id('main'),700) RETURNING id AS sn4 \gset
INSERT INTO t.ids VALUES('sn4',:'sn4');
SELECT t.move('phone','main',1,'sn4');
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.create_stock_transfer(t.id('main'),t.id('second'),NULL,
  jsonb_build_array(jsonb_build_object('product_id',t.id('phone'),'unit_id',t.id('sn4'),'quantity',1)),'i03-transfer-4') AS d4 \gset
RESET ROLE;
INSERT INTO public.customers(organization_id,full_name) VALUES(t.org('a'),'I03 customer') RETURNING id AS customer_id \gset
INSERT INTO public.sales_orders(organization_id,number,customer_id,branch_id,prices_include_vat,subtotal,total,idempotency_key)
VALUES(t.org('a'),'I03-SO-1',:'customer_id',t.id('main'),true,900,900,'i03-order-1') RETURNING id AS order_id \gset
INSERT INTO public.sales_order_lines(organization_id,order_id,line_no,product_id,quantity,unit_price,tax_class_id,tax_rate,line_total)
VALUES(t.org('a'),:'order_id',1,t.id('phone'),1,900,(SELECT default_tax_class_id FROM public.org_settings WHERE organization_id=t.org('a')),14,900) RETURNING id AS line_id \gset
INSERT INTO public.stock_reservations(organization_id,product_id,branch_id,unit_id,order_line_id,quantity) VALUES(t.org('a'),t.id('phone'),t.id('main'),t.id('sn4'),:'line_id',1);
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.error('a unit reserved after the draft can''t be sent',format('SELECT public.send_stock_transfer(%L)',:'d4'::jsonb->>'id'),'UNIT_NOT_AVAILABLE');
SELECT t.expect('the reserved unit stayed in main, reserved',
  (SELECT status='reserved' AND branch_id=t.id('main') FROM public.units WHERE id=t.id('sn4'))
  AND (public.get_stock_transfer((:'d4'::jsonb->>'id')::uuid)->>'status')='draft');
SELECT t.as_user('a3000000-0000-0000-8000-000000000001',t.org('a'));
SELECT t.error('a reserved unit can''t be written off either',format($q$SELECT public.post_stock_adjustment(%L,'loss',NULL,'[{"product_id":"%s","unit_id":"%s","quantity":-1}]','i03-adj-reserved')$q$,t.id('main'),t.id('phone'),t.id('sn4')),'UNIT_NOT_AVAILABLE');
SELECT t.error('system: idempotency keys are reserved',format($q$SELECT public.post_stock_adjustment(%L,'loss',NULL,'[{"product_id":"%s","quantity":-1}]','system:transfer/%s/loss')$q$,t.id('second'),t.id('cable'),:'d1'::jsonb->>'id'),'VALIDATION_FAILED');
SELECT t.as_user('a3000000-0000-0000-8000-000000000003',t.org('a'));
SELECT t.error('a cancelled transfer can''t be sent',format('SELECT public.send_stock_transfer(%L)',:'d3'::jsonb->>'id'),'DOCUMENT_FINAL');

-- ---------------------------------------------------------------- reads, scope, permissions
SELECT t.expect('lists: by status, by branch on either side, paging',
  (public.list_stock_transfers()->>'total')::int=4
  AND (public.list_stock_transfers(p_status=>'partially_received')->>'total')::int=2
  AND (public.list_stock_transfers(p_status=>'cancelled')->>'total')::int=1
  AND jsonb_array_length(public.list_stock_transfers(p_limit=>1)->'items')=1
  AND NOT (public.list_stock_transfers()->'items'->0 ? 'lines'));
RESET ROLE;
SELECT t.as_user('a3000000-0000-0000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('the receiver (second only) sees the transfers coming in',
  (public.list_stock_transfers()->>'total')::int=4 AND (public.list_stock_transfers(t.id('second'))->>'total')::int=4);
SELECT t.error('the receiver can''t send from main',format('SELECT public.send_stock_transfer(%L)',:'d1'::jsonb->>'id'),'BRANCH_DENIED');
SELECT t.as_user('a3000000-0000-0000-8000-000000000005',t.org('a'));
SELECT t.error('a cashier can''t create a transfer',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":1}]','i03-cashier')$q$,t.id('main'),t.id('second'),t.id('cable')),'PERMISSION_DENIED');
SELECT t.error('a cashier can''t receive',format($q$SELECT public.receive_stock_transfer(%L,'[]')$q$,:'d1'::jsonb->>'id'),'PERMISSION_DENIED');
SELECT t.expect('a cashier (stock.view) reads the transfers of their branch',(public.get_stock_transfer((:'d1'::jsonb->>'id')::uuid)->>'number')=(:'d1'::jsonb->>'number'));
SELECT t.as_user('a3000000-0000-0000-8000-000000000002',t.org('b'));
SELECT t.error('shop b: get shop a''s transfer',format('SELECT public.get_stock_transfer(%L)',:'d1'::jsonb->>'id'),'STOCK_TRANSFER_NOT_FOUND');
SELECT t.error('shop b: send shop a''s transfer',format('SELECT public.send_stock_transfer(%L)',:'d3'::jsonb->>'id'),'STOCK_TRANSFER_NOT_FOUND');
SELECT t.error('shop b: receive shop a''s transfer',format($q$SELECT public.receive_stock_transfer(%L,'[]')$q$,:'d1'::jsonb->>'id'),'STOCK_TRANSFER_NOT_FOUND');
SELECT t.expect('shop b: nothing listed',(public.list_stock_transfers()->>'total')::int=0);
RESET ROLE;
SELECT t.expect('audit: created 4, updated 1, sent 2, received 2, cancelled 1',
  (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_transfer.created')=4
  AND (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_transfer.updated')=1
  AND (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_transfer.sent')=2
  AND (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_transfer.received')=2
  AND (SELECT count(*) FROM public.audit_log WHERE organization_id=t.org('a') AND action='stock_transfer.cancelled')=1);
SELECT t.expect('ledger caches still match the ledger',NOT EXISTS(SELECT 1 FROM app.ledger_mismatches(t.org('a'))));
-- An expired shop reads but doesn't write.
UPDATE public.organizations SET subscription_start=current_date-60,subscription_end=current_date-30 WHERE id=t.org('a');
SELECT t.as_user('a3000000-0000-0000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('expired shop: transfers still read',(public.list_stock_transfers()->>'total')::int=4);
SELECT t.error('expired shop: no new transfer',format($q$SELECT public.create_stock_transfer(%L,%L,NULL,'[{"product_id":"%s","quantity":1}]','i03-expired')$q$,t.id('main'),t.id('second'),t.id('cable')),'SUBSCRIPTION_EXPIRED');
RESET ROLE;
UPDATE public.organizations SET subscription_end=current_date+30 WHERE id=t.org('a');
SELECT t.expect('no anon grants; authenticated may execute the public functions',
  NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
              AND p.proname IN ('create_stock_transfer','update_stock_transfer','send_stock_transfer','receive_stock_transfer',
                                'cancel_stock_transfer','list_stock_transfers','get_stock_transfer')
              AND (has_function_privilege('anon',p.oid,'EXECUTE') OR NOT has_function_privilege('authenticated',p.oid,'EXECUTE')))
  AND NOT has_function_privilege('authenticated','app.set_transfer_lines(uuid,uuid,public.stock_transfers,jsonb)','EXECUTE'));

SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
