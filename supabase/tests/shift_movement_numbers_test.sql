-- Live review 19 Oct, bug 3: the shift detail shows each drawer movement's document number.
-- Run by: node scripts/db-smoke.mjs supabase/tests/shift_movement_numbers_test.sql (inside BEGIN ... ROLLBACK).
-- A cash sale, a drawer expense, a cash move to the safe and a counter collection each come back
-- with their own number in source_number; a note that only repeats that number comes back NULL,
-- any other note stays; a movement that points at another shop's document gets no number.
\ir helpers/test4_setup.sql

-- ---------------------------------------------------------------- the owner works one shift in shop a
SELECT t.as_user('a7050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'0','sn-shift-open')->>'id')::uuid;
INSERT INTO t.docs SELECT 'sale',public.post_sale(t.lines(t.items('chair',1)),'100.00','sn-cash-sale');
INSERT INTO t.ids SELECT 'category',(public.create_expense_category('SN drawer expense')->>'id')::uuid;
INSERT INTO t.docs SELECT 'expense',public.post_expense(t.id('category'),'20.00','sn-drawer-expense',NULL,NULL,true);
SELECT public.move_shift_cash(t.id('shift'),'out','30.00',t.id('safe'),'To the safe','sn-move-out');
RESET ROLE;
INSERT INTO t.ids SELECT 'transfer',id FROM public.cash_transfers WHERE organization_id=t.org('a') AND idempotency_key='sn-move-out';

-- A counter collection (N03 posts one payment per method) and two rows that point at shop b's payment.
INSERT INTO t.ids SELECT 'drawer',drawer_account_id FROM public.shifts WHERE id=t.id('shift');
INSERT INTO t.ids SELECT 'main_b',id FROM public.branches WHERE organization_id=t.org('b') AND is_main;
INSERT INTO public.payments(id,organization_id,number,branch_id,direction,method,amount,cash_account_id,shift_id,reference,business_date,idempotency_key)
  VALUES('a7050000-0000-0000-8000-0000000000a1',t.org('a'),'SN-PAY-A1',t.id('main'),'in','cash',10.00,t.id('drawer'),t.id('shift'),NULL,app.org_today(t.org('a')),'sn-pay-a1'),
        ('a7050000-0000-0000-8000-0000000000b1',t.org('b'),'SN-PAY-B1',t.id('main_b'),'in','bank_transfer',10.00,t.id('bank_b'),NULL,'SN-REF-B1',app.org_today(t.org('b')),'sn-pay-b1');
INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,shift_id,amount,type,source_type,source_id,note,business_date,created_at)
  VALUES(t.org('a'),t.id('drawer'),t.id('main'),t.id('shift'),10.00,'collection','payment','a7050000-0000-0000-8000-0000000000a1','SN-PAY-A1 INST-7',app.org_today(t.org('a')),clock_timestamp()),
        (t.org('a'),t.id('drawer'),t.id('main'),t.id('shift'),1.00,'collection','payment','a7050000-0000-0000-8000-0000000000b1','SN-PAY-B1',app.org_today(t.org('a')),clock_timestamp()),
        (t.org('a'),t.id('drawer'),t.id('main'),t.id('shift'),1.00,'sale','sale','a7050000-0000-0000-8000-0000000000b1',NULL,app.org_today(t.org('a')),clock_timestamp());

SELECT t.as_user('a7050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.docs SELECT 'shift',public.get_shift(t.id('shift'));
RESET ROLE;
CREATE FUNCTION t.mv(p_type text,p_source uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT m FROM jsonb_array_elements(t.doc('shift')->'movements') m
  WHERE m->>'source_type'=p_type AND m->>'id' IN (SELECT c.id::text FROM public.cash_movements c WHERE c.source_id=p_source) $$;

SELECT t.expect('cash sale: the sale number is the document, the repeated note is gone',
  t.mv('sale',(t.doc('sale')->>'id')::uuid)->>'source_number'=t.doc('sale')->>'number'
  AND t.mv('sale',(t.doc('sale')->>'id')::uuid)->'note'='null'::jsonb,t.mv('sale',(t.doc('sale')->>'id')::uuid)::text);
SELECT t.expect('drawer expense: the expense number is the document, the repeated note is gone',
  t.mv('expense',(t.doc('expense')->>'id')::uuid)->>'source_number'=t.doc('expense')->>'number'
  AND t.mv('expense',(t.doc('expense')->>'id')::uuid)->'note'='null'::jsonb,t.mv('expense',(t.doc('expense')->>'id')::uuid)::text);
SELECT t.expect('cash move: the transfer number stays and so does its own note',
  t.mv('cash_transfer',t.id('transfer'))->>'source_number'=(SELECT number FROM public.cash_transfers WHERE id=t.id('transfer'))
  AND t.mv('cash_transfer',t.id('transfer'))->>'note'='To the safe',t.mv('cash_transfer',t.id('transfer'))::text);
SELECT t.expect('collection: the payment number is the document, a longer note stays',
  t.mv('payment','a7050000-0000-0000-8000-0000000000a1')->>'source_number'='SN-PAY-A1'
  AND t.mv('payment','a7050000-0000-0000-8000-0000000000a1')->>'note'='SN-PAY-A1 INST-7',t.mv('payment','a7050000-0000-0000-8000-0000000000a1')::text);
SELECT t.expect('rows pointing at shop b''s payment get no number and keep their note',
  (SELECT bool_and(m->'source_number'='null'::jsonb) AND count(*)=2 FROM jsonb_array_elements(t.doc('shift')->'movements') m
   WHERE m->>'id' IN (SELECT c.id::text FROM public.cash_movements c WHERE c.source_id='a7050000-0000-0000-8000-0000000000b1'))
  AND t.mv('payment','a7050000-0000-0000-8000-0000000000b1')->>'note'='SN-PAY-B1',t.doc('shift')->>'movements');
SELECT t.expect('shop b''s number only shows in the note typed on shop a''s own row',
  (SELECT count(*) FROM jsonb_array_elements(t.doc('shift')->'movements') m WHERE m::text LIKE '%SN-PAY-B1%')=1
  AND (SELECT count(*) FROM jsonb_array_elements(t.doc('shift')->'movements') m WHERE m->>'source_number'='SN-PAY-B1')=0,t.doc('shift')->>'movements');

-- Shop b's owner cannot read shop a's shift at all.
SELECT t.as_user('a7050000-0000-0000-8000-000000000002',t.org('b'));
SET ROLE authenticated;
SELECT t.error('shop b cannot open shop a''s shift',format('SELECT public.get_shift(%L)',t.id('shift')),'SHIFT_NOT_FOUND');
RESET ROLE;

SELECT t.expect('all cash ledgers reconcile',t.bad_cash() IS NULL);
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
