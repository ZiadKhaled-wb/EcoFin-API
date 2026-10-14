\ir helpers/test4_setup.sql
\ir helpers/test4_snapshot.sql

SELECT t.as_user('a7050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids VALUES('third',public.create_product('{"name_ar":"ثالث","sku":"TEST4-THIRD","cash_price":"200"}'));
SELECT public.post_stock_adjustment(t.id('main'),'found',NULL,t.lines(t.items('third',10)),'test4-third-stock');

INSERT INTO t.ids VALUES('serial',public.create_product('{"name_ar":"مسلسل","sku":"TEST4-SERIAL","cash_price":"100","is_serialized":true,"warranty_months":12}'));
SELECT public.register_units(t.id('serial'),t.id('main'),'50.00','["TEST4-SERIAL-1","TEST4-SERIAL-2"]',NULL,'test4-serial-stock');
RESET ROLE;
INSERT INTO t.ids SELECT 'unit',id FROM public.units WHERE organization_id=t.org('a') AND serial='TEST4-SERIAL-1';
INSERT INTO t.ids SELECT 'otherunit',id FROM public.units WHERE organization_id=t.org('a') AND serial='TEST4-SERIAL-2';
SET ROLE authenticated;
RESET ROLE;
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
INSERT INTO t.ids SELECT 'shift',(t.open_shift(t.id('main'),'0','test4-shift')->>'id')::uuid;

-- BUG TEST4-B2: a cashier's client unit_price is rejected instead of ignored in favor of the server price.
-- KNOWN BUG: the desired server-priced sale must succeed when this is fixed.
DO $$
DECLARE before jsonb := t.snapshot(t.org('a'));
BEGIN
  BEGIN
    PERFORM public.post_sale(t.lines(t.items('chair',1)||'{"unit_price":"1.00"}'::jsonb),'100.00','test4-price-ignore');
    RAISE EXCEPTION 'TEST4_B2_FIXED';
  EXCEPTION WHEN others THEN
    IF split_part(SQLERRM,':',1)<>'PRICE_OVERRIDE_DENIED' THEN RAISE EXCEPTION 'TEST4-B2 changed behavior: %',SQLERRM; END IF;
  END;
  PERFORM t.expect('TEST4-B2 client price rejected rather than ignored (known failure)',t.snapshot(t.org('a'))=before);
END $$;

SELECT t.unchanged('line 3 out of stock',t.sell(t.lines(t.items('chair',1),t.items('sofa',1),t.items('third',11)),'2680.00'),'OUT_OF_STOCK');
SELECT t.unchanged('underpaid three-line sale',t.sell(t.lines(t.items('chair',1),t.items('sofa',1),t.items('third',1)),'680.00',t.lines(t.pcash('679.99'))),'PAYMENT_TOTAL_MISMATCH');
SELECT t.unchanged('store credit above balance',t.sell(t.lines(t.items('chair',1),t.items('sofa',1),t.items('third',1)),'680.00',t.lines(t.pcredit('680.00')),'mona'),'INSUFFICIENT_STORE_CREDIT');
SELECT t.unchanged('line 3 discount beyond cashier cap',format('SELECT public.post_sale(%L,%L,%L,NULL,NULL,NULL,%L)',t.lines(t.items('chair',1),t.items('sofa',1),t.items('third',1)||'{"discount":{"type":"percent","value":"5.01"}}'::jsonb),'669.98','test4-cap','Reason'),'DISCOUNT_ABOVE_CAP');
SELECT t.unchanged('stacking line and sale beyond cap',format('SELECT public.post_sale(%L,%L,%L,NULL,NULL,%L,%L)',t.lines(t.items('chair',1)||'{"discount":{"type":"percent","value":"4"}}'::jsonb),'94.08','test4-stack','{"type":"percent","value":"2"}','Reason'),'DISCOUNT_ABOVE_CAP');
SELECT t.unchanged('negative payment',t.sell(t.lines(t.items('chair',1)),'100.00',t.lines(t.pcash('-1.00'))),'VALIDATION_FAILED');
SELECT t.unchanged('non-cash above total',t.sell(t.lines(t.items('chair',1)),'100.00',t.lines(t.pbank('100.01','nbe','REF'))),'PAYMENT_TOTAL_MISMATCH');
SELECT t.unchanged('transfer without reference',t.sell(t.lines(t.items('chair',1)),'100.00',t.lines(t.pbank('100.00','nbe',NULL))),'VALIDATION_FAILED');
SELECT t.unchanged('credit for walk-in',t.sell(t.lines(t.items('chair',1)),'100.00',t.lines(t.pcredit('100.00'))),'VALIDATION_FAILED');
SELECT t.unchanged('other shop account',t.sell(t.lines(t.items('chair',1)),'100.00',t.lines(t.pbank('100.00','bank_b','REF'))),'VAULT_INVALID');
SELECT t.unchanged('other branch account',t.sell(t.lines(t.items('chair',1)),'100.00',t.lines(t.pbank('100.00','ahli','REF'))),'VAULT_INVALID');

INSERT INTO t.docs SELECT 'serialsale',public.post_sale(t.lines(jsonb_build_object('product_id',t.id('serial'),'quantity',1,'unit_id',t.id('unit'))),'100.00','test4-sold-serial');
SELECT t.unchanged('line 2 serial already sold',t.sell(t.lines(t.items('chair',1),jsonb_build_object('product_id',t.id('serial'),'quantity',1,'unit_id',t.id('unit')),t.items('third',1)),'400.00'),'UNIT_NOT_AVAILABLE');
RESET ROLE;
-- Simulate revocation between quote and payment; no app code changed.
CREATE TABLE t.device_before AS SELECT id,token_hash FROM public.devices WHERE id=(current_setting('request.headers')::jsonb->>'x-device-id')::uuid;
GRANT SELECT ON t.device_before TO authenticated;
UPDATE public.devices SET token_hash=NULL WHERE id=(SELECT id FROM t.device_before);
SET ROLE authenticated;

-- BUG TEST4-B1: a direct authenticated post_sale accepts a revoked device after quote.
-- KNOWN BUG: must fail visibly if the vulnerability is fixed; successful writes are rolled back.
DO $$
DECLARE before jsonb := t.snapshot(t.org('a')); result jsonb;
BEGIN
  BEGIN
    result := public.post_sale(t.lines(t.items('chair',1),t.items('sofa',1),t.items('third',1)),'680.00','test4-revoked-known-bug');
    IF result->>'id' IS NULL OR t.snapshot(t.org('a'))=before THEN RAISE EXCEPTION 'unexpected result'; END IF;
    RAISE EXCEPTION 'TEST4_EXPECTED_BUG';
  EXCEPTION WHEN others THEN
    IF SQLERRM<>'TEST4_EXPECTED_BUG' THEN RAISE EXCEPTION 'TEST4-B1 changed behavior: %',SQLERRM; END IF;
  END;
  PERFORM t.expect('TEST4-B1 revoked direct device still accepted (known failure)',t.snapshot(t.org('a'))=before);
END $$;
RESET ROLE;
UPDATE public.devices SET token_hash=(SELECT token_hash FROM t.device_before) WHERE id=(SELECT id FROM t.device_before);
SET ROLE authenticated;


RESET ROLE;
CREATE FUNCTION t.fail_late() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.action IN ('sale.voided','warranty_claim.moved') THEN RAISE EXCEPTION 'TEST4_LATE_FAILURE'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER test4_fail_late BEFORE INSERT ON public.audit_log FOR EACH ROW EXECUTE FUNCTION t.fail_late();
SELECT t.as_user('a7050000-0000-0000-8000-000000000001',t.org('a'));
SET ROLE authenticated;
SELECT t.unchanged('void fails at final audit insert',format('SELECT public.void_sale(%L,%L,%L)',t.doc('serialsale')->>'id','TEST4 void','test4-late-void'),'TEST4_LATE_FAILURE');
INSERT INTO t.docs SELECT 'claim',public.open_warranty_claim((t.doc('serialsale')->'lines'->0->>'id')::uuid,t.id('unit'),'Failed screen','Clean case','test4-late-claim');
SELECT t.unchanged('replacement fails at final audit insert',format('SELECT public.move_warranty_claim(%L,%L,%L,%L)',t.doc('claim')->>'claim_id','replaced','TEST4 replacement',t.id('otherunit')),'TEST4_LATE_FAILURE');
RESET ROLE;
DROP TRIGGER test4_fail_late ON public.audit_log;
SELECT t.as_user('a7050000-0000-0000-8000-000000000003',t.org('a'));
SET ROLE authenticated;
SELECT t.pos(t.id('main'),(SELECT id FROM t.device_before));

-- Build a valid cart before the shift closes, then attempt its sale.
SELECT public.quote_sale(t.lines(t.items('chair',1),t.items('sofa',1),t.items('third',1)));
SELECT public.close_shift(t.id('shift'),'{}',p_difference_reason=>'TEST4 close before paying');
SELECT t.unchanged('shift closed after cart built',t.sell(t.lines(t.items('chair',1),t.items('sofa',1),t.items('third',1)),'680.00'),'SHIFT_REQUIRED');

RESET ROLE;
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
