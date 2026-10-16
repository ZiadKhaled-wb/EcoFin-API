\ir helpers/test4_setup.sql
\ir helpers/test4_snapshot.sql
CREATE TABLE t.key_functions(signature text PRIMARY KEY);
INSERT INTO t.key_functions VALUES ('public.post_purchase_return(uuid,text,text,jsonb,text,uuid)'),
('public.admin_record_subscription_payment(uuid,numeric,date,date,text,boolean,uuid)'),
('public.post_stock_adjustment(uuid,text,text,jsonb,text)'),
('public.create_stock_count(uuid,uuid,text)'),
('public.post_stock_count(uuid,boolean,text)'),
('public.create_stock_transfer(uuid,uuid,text,jsonb,text)'),
('public.register_units(uuid,uuid,text,jsonb,text,text)'),
('public.post_cash_opening(uuid,text,text,text)'),
('public.create_cash_transfer(uuid,uuid,text,text,text)'),
('public.post_supplier_payment(uuid,uuid,uuid,text,text,text,jsonb)'),
('public.reverse_supplier_payment(uuid,text,text)'),
('public.create_purchase_order(uuid,uuid,jsonb,text,date,text)'),
('public.create_purchase_invoice(uuid,uuid,text,date,jsonb,text,uuid)'),
('public.create_invoice_from_po(uuid,text,jsonb)'),
('public.open_shift(uuid,text,text,uuid,uuid)'),
('public.move_shift_cash(uuid,text,text,uuid,text,text)'),
('public.reverse_expense(uuid,text,text,uuid)'),
('public.post_expense(uuid,text,text,uuid,uuid,boolean,text,uuid)'),
('public.post_sale(jsonb,text,text,uuid,jsonb,jsonb,text,uuid)'),
('public.post_installment_sale(jsonb,text)'),
('public.void_sale(uuid,text,text)'),
('public.open_warranty_claim(uuid,uuid,text,text,text)');
SELECT t.expect('generic completeness: every authenticated public definer with an idempotency argument is explicitly registered',
 NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prosecdef AND has_function_privilege('authenticated',p.oid,'EXECUTE')
 AND EXISTS(SELECT 1 FROM unnest(p.proargnames) a WHERE a LIKE '%idempotency%')
 AND NOT EXISTS(SELECT 1 FROM t.key_functions k WHERE to_regprocedure(k.signature)=p.oid)));
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',t.open_shift(t.id('main'),'0','test4-idem-shift');
INSERT INTO t.docs SELECT 'sale',public.post_sale(t.lines(t.items('chair',1)),'100.00','test4-idem-sale');
RESET ROLE;
CREATE TABLE t.before AS SELECT t.snapshot(t.org('a')) j;
GRANT SELECT ON t.before TO authenticated;
SET ROLE authenticated;
SELECT t.expect('sale repeats same id',public.post_sale(t.lines(t.items('chair',1)),'100.00','test4-idem-sale')->>'id'=t.doc('sale')->>'id');
SELECT t.expect('sale different arguments returns original unchanged',public.post_sale(t.lines(t.items('sofa',1)),'380.00','test4-idem-sale')=t.doc('sale'));
SELECT t.expect('shift repeats same id',public.open_shift(t.id('main'),'0','test4-idem-shift')->>'id'=t.doc('shift')->>'id');
SELECT t.expect('repeat sale and shift take no rows, balances or document counters',t.snapshot(t.org('a'))=(SELECT j FROM t.before));

RESET ROLE;
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
