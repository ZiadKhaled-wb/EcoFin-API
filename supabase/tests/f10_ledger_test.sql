-- F10 ledger core (baseline ledgers + migration 20261003120000_f10_ledger.sql). LOCAL / DEV ONLY.
-- Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f10_ledger_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- The parallel proofs are separate: npm run db:ledger (scripts/db-ledger-proof.mjs).
-- Expected last line: failed 0.
--   1. stock: on hand = sum of movements; no overselling; reserved stock counts as taken
--   2. cash: balance = sum of movements; money out can't go below zero
--   3. append-only ledgers; a movement can be reversed once only
--   4. caches: app users can't write them; only the ledger triggers change them
--   5. reconciliation: clean = no rows; every kind of drift is found, per shop or all shops; internal only
--   6. idempotency: the same key twice changes things once, and takes no document number for nothing
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE SCHEMA t;
CREATE TABLE t.results (name text, ok boolean, detail text);

CREATE FUNCTION t.expect_error(p_name text, p_sql text, p_pattern text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO t.results VALUES (p_name, false, 'no error raised');
    EXCEPTION WHEN others THEN
        INSERT INTO t.results VALUES (p_name, SQLERRM ~* p_pattern, SQLERRM);
    END;
END $$;

CREATE FUNCTION t.expect(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    INSERT INTO t.results VALUES (p_name, p_ok, p_detail);
$$;

GRANT USAGE ON SCHEMA t TO authenticated, anon;
GRANT INSERT ON t.results TO authenticated, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated, anon;

-- ---------------------------------------------------------------- fixtures
--   shop A: owner a, branch A1, product P (not serialized), drawer D, customer C     shop B: owner b, branch B1, product Q
INSERT INTO auth.users (id, email) VALUES
  ('f1000000-0000-0000-0000-0000000000a1', 'f10-a@x'),
  ('f1000000-0000-0000-0000-0000000000b1', 'f10-b@x');
INSERT INTO organizations (id, tenant_slug, name, plan_key, status) VALUES
  ('f1010000-0000-0000-0000-00000000000a', 'f10-shop-a', 'F10 Shop A', 'retail', 'active'),
  ('f1010000-0000-0000-0000-00000000000b', 'f10-shop-b', 'F10 Shop B', 'retail', 'active');
INSERT INTO org_settings (organization_id) VALUES
  ('f1010000-0000-0000-0000-00000000000a'), ('f1010000-0000-0000-0000-00000000000b');
INSERT INTO branches (id, organization_id, code, name, is_main) VALUES
  ('f1020000-0000-0000-0000-0000000000a1', 'f1010000-0000-0000-0000-00000000000a', 'BR1', 'A main', true),
  ('f1020000-0000-0000-0000-0000000000b1', 'f1010000-0000-0000-0000-00000000000b', 'BR1', 'B main', true);
INSERT INTO employees (id, organization_id, auth_user_id, full_name, role) VALUES
  ('f1030000-0000-0000-0000-0000000000a1', 'f1010000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-0000000000a1', 'Owner A', 'OWNER'),
  ('f1030000-0000-0000-0000-0000000000b1', 'f1010000-0000-0000-0000-00000000000b', 'f1000000-0000-0000-0000-0000000000b1', 'Owner B', 'OWNER');
INSERT INTO tax_classes (id, organization_id, name, rate) VALUES
  ('f1040000-0000-0000-0000-00000000000a', 'f1010000-0000-0000-0000-00000000000a', 'VAT 14', 14),
  ('f1040000-0000-0000-0000-00000000000b', 'f1010000-0000-0000-0000-00000000000b', 'VAT 14', 14);
INSERT INTO products (id, organization_id, name_ar, sku, cash_price, tax_class_id, is_serialized) VALUES
  ('f1050000-0000-0000-0000-00000000000a', 'f1010000-0000-0000-0000-00000000000a', 'Chair', 'F10-P', 100, 'f1040000-0000-0000-0000-00000000000a', false),
  ('f1050000-0000-0000-0000-00000000000b', 'f1010000-0000-0000-0000-00000000000b', 'Desk', 'F10-Q', 100, 'f1040000-0000-0000-0000-00000000000b', false);
INSERT INTO cash_accounts (id, organization_id, branch_id, name, kind) VALUES
  ('f1060000-0000-0000-0000-0000000000da', 'f1010000-0000-0000-0000-00000000000a', 'f1020000-0000-0000-0000-0000000000a1', 'Drawer', 'drawer');
INSERT INTO customers (id, organization_id, full_name, credit_limit) VALUES
  ('f1070000-0000-0000-0000-00000000000a', 'f1010000-0000-0000-0000-00000000000a', 'Customer A', 0);

CREATE FUNCTION t.on_hand(p_product text) RETURNS integer LANGUAGE sql AS $$
    SELECT COALESCE((SELECT on_hand FROM stock_levels WHERE product_id = p_product::uuid AND stock_state = 'sellable'), 0)
$$;
CREATE FUNCTION t.moved(p_product text) RETURNS integer LANGUAGE sql AS $$
    SELECT COALESCE(SUM(quantity), 0)::integer FROM stock_movements WHERE product_id = p_product::uuid
$$;
CREATE FUNCTION t.stock(p_qty integer, p_type public.stock_movement_type, p_source public.doc_type DEFAULT 'stock_adjustment')
RETURNS uuid LANGUAGE sql AS $$
    INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
    VALUES ('f1010000-0000-0000-0000-00000000000a', 'f1050000-0000-0000-0000-00000000000a',
            'f1020000-0000-0000-0000-0000000000a1', p_qty, p_type, p_source, gen_random_uuid())
    RETURNING id
$$;
CREATE FUNCTION t.cash(p_amount numeric, p_type public.cash_movement_type, p_source public.doc_type DEFAULT 'shift')
RETURNS uuid LANGUAGE sql AS $$
    INSERT INTO cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
    VALUES ('f1010000-0000-0000-0000-00000000000a', 'f1060000-0000-0000-0000-0000000000da', p_amount, p_type, p_source, gen_random_uuid())
    RETURNING id
$$;
CREATE FUNCTION t.balance() RETURNS numeric LANGUAGE sql AS $$
    SELECT COALESCE((SELECT balance FROM cash_balances WHERE cash_account_id = 'f1060000-0000-0000-0000-0000000000da'), 0)
$$;
CREATE FUNCTION t.mismatches(p_org text DEFAULT NULL) RETURNS bigint LANGUAGE sql AS $$
    SELECT count(*) FROM app.ledger_mismatches(p_org::uuid)
$$;

-- ---------------------------------------------------------------- 1. stock
SELECT t.stock(10, 'purchase_in', 'purchase_invoice');
SELECT t.expect('1.1 a purchase of 10: on hand 10 = sum of movements', t.on_hand('f1050000-0000-0000-0000-00000000000a') = 10
  AND t.moved('f1050000-0000-0000-0000-00000000000a') = 10);
SELECT t.stock(-3, 'sale_out', 'sale');
SELECT t.expect('1.2 a sale of 3: on hand 7 = sum of movements', t.on_hand('f1050000-0000-0000-0000-00000000000a') = 7
  AND t.moved('f1050000-0000-0000-0000-00000000000a') = 7);
SELECT t.expect_error('1.3 selling 8 of 7 is refused', $$SELECT t.stock(-8, 'sale_out', 'sale')$$, 'OUT_OF_STOCK');
SELECT t.expect('1.4 the refused sale left no movement and no change', t.on_hand('f1050000-0000-0000-0000-00000000000a') = 7
  AND t.moved('f1050000-0000-0000-0000-00000000000a') = 7);

INSERT INTO sales_orders (id, organization_id, number, customer_id, branch_id, prices_include_vat, subtotal, total, idempotency_key)
VALUES ('f1080000-0000-0000-0000-00000000000a', 'f1010000-0000-0000-0000-00000000000a', 'BR1-SO-26-900001',
        'f1070000-0000-0000-0000-00000000000a', 'f1020000-0000-0000-0000-0000000000a1', true, 500, 500, 'f10-order-key-1');
INSERT INTO sales_order_lines (id, organization_id, order_id, line_no, product_id, quantity, unit_price, tax_class_id, tax_rate, line_total)
VALUES ('f1090000-0000-0000-0000-00000000000a', 'f1010000-0000-0000-0000-00000000000a', 'f1080000-0000-0000-0000-00000000000a', 1,
        'f1050000-0000-0000-0000-00000000000a', 5, 100, 'f1040000-0000-0000-0000-00000000000a', 14, 500);
INSERT INTO stock_reservations (id, organization_id, product_id, branch_id, order_line_id, quantity)
VALUES ('f10a0000-0000-0000-0000-00000000000a', 'f1010000-0000-0000-0000-00000000000a', 'f1050000-0000-0000-0000-00000000000a',
        'f1020000-0000-0000-0000-0000000000a1', 'f1090000-0000-0000-0000-00000000000a', 5);
SELECT t.expect_error('1.5 with 5 of 7 reserved, a walk-in sale of 3 is refused', $$SELECT t.stock(-3, 'sale_out', 'sale')$$, 'OUT_OF_STOCK');
SELECT t.stock(-2, 'sale_out', 'sale');
SELECT t.expect('1.6 a walk-in sale of the 2 free units works: on hand 5, reserved 5',
  (SELECT on_hand = 5 AND reserved = 5 FROM stock_levels WHERE product_id = 'f1050000-0000-0000-0000-00000000000a'));

-- ---------------------------------------------------------------- 2. cash
SELECT t.cash(100, 'float_in');
SELECT t.cash(50, 'sale', 'sale');
SELECT t.expect('2.1 float 100 + sale 50: balance 150 = sum of movements', t.balance() = 150
  AND (SELECT SUM(amount) FROM cash_movements WHERE cash_account_id = 'f1060000-0000-0000-0000-0000000000da') = 150);
SELECT t.expect_error('2.2 paying out 150.01 from a drawer holding 150 is refused', $$SELECT t.cash(-150.01, 'expense', 'expense')$$,
  'INSUFFICIENT_FUNDS');
SELECT t.cash(-150, 'expense', 'expense');
SELECT t.expect('2.3 paying out exactly 150 works: balance 0', t.balance() = 0);

-- ---------------------------------------------------------------- 3. append-only, reversals
SELECT t.expect_error('3.1 a stock movement can''t be edited',
  $$UPDATE stock_movements SET quantity = 100 WHERE product_id = 'f1050000-0000-0000-0000-00000000000a'$$, 'APPEND_ONLY');
SELECT t.expect_error('3.2 a stock movement can''t be deleted',
  $$DELETE FROM stock_movements WHERE product_id = 'f1050000-0000-0000-0000-00000000000a'$$, 'APPEND_ONLY');
SELECT t.expect_error('3.3 a cash movement can''t be edited',
  $$UPDATE cash_movements SET amount = 1 WHERE cash_account_id = 'f1060000-0000-0000-0000-0000000000da'$$, 'APPEND_ONLY');
SELECT t.expect_error('3.4 a cash movement can''t be deleted',
  $$DELETE FROM cash_movements WHERE cash_account_id = 'f1060000-0000-0000-0000-0000000000da'$$, 'APPEND_ONLY');

CREATE TABLE t.ids (name text PRIMARY KEY, id uuid);
SELECT t.stock(3, 'purchase_in', 'purchase_invoice');   -- on hand 8, 5 of them reserved
INSERT INTO t.ids SELECT 'sale', t.stock(-1, 'sale_out', 'sale');
INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id, reverses_movement_id)
SELECT 'f1010000-0000-0000-0000-00000000000a', 'f1050000-0000-0000-0000-00000000000a', 'f1020000-0000-0000-0000-0000000000a1',
       1, 'sale_return_in', 'sales_return', gen_random_uuid(), id FROM t.ids WHERE name = 'sale';
SELECT t.expect('3.5 a reversal points to the original and restores the stock: on hand 8',
  t.on_hand('f1050000-0000-0000-0000-00000000000a') = 8
  AND EXISTS (SELECT 1 FROM stock_movements WHERE reverses_movement_id = (SELECT id FROM t.ids WHERE name = 'sale')));
SELECT t.expect_error('3.6 the same stock movement can''t be reversed twice', $$
  INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id, reverses_movement_id)
  SELECT 'f1010000-0000-0000-0000-00000000000a', 'f1050000-0000-0000-0000-00000000000a', 'f1020000-0000-0000-0000-0000000000a1',
         1, 'sale_return_in', 'sales_return', gen_random_uuid(), id FROM t.ids WHERE name = 'sale' $$,
  'stock_movements_reversed_once_idx');
INSERT INTO t.ids SELECT 'cash', t.cash(20, 'sale', 'sale');
INSERT INTO cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id, reverses_movement_id)
SELECT 'f1010000-0000-0000-0000-00000000000a', 'f1060000-0000-0000-0000-0000000000da', -20, 'refund', 'sales_return',
       gen_random_uuid(), id FROM t.ids WHERE name = 'cash';
SELECT t.expect_error('3.7 the same cash movement can''t be reversed twice', $$
  INSERT INTO cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id, reverses_movement_id)
  SELECT 'f1010000-0000-0000-0000-00000000000a', 'f1060000-0000-0000-0000-0000000000da', -20, 'refund', 'sales_return',
         gen_random_uuid(), id FROM t.ids WHERE name = 'cash' $$,
  'cash_movements_reversed_once_idx');

-- ---------------------------------------------------------------- 4. caches
SELECT t.expect('4.1 app users have no write privilege on the caches or the ledgers',
  NOT has_table_privilege('authenticated', 'public.stock_levels', 'INSERT,UPDATE,DELETE,TRUNCATE')
  AND NOT has_table_privilege('authenticated', 'public.cash_balances', 'INSERT,UPDATE,DELETE,TRUNCATE')
  AND NOT has_table_privilege('authenticated', 'public.store_credit_balances', 'INSERT,UPDATE,DELETE,TRUNCATE')
  AND NOT has_table_privilege('authenticated', 'public.stock_movements', 'INSERT,UPDATE,DELETE,TRUNCATE')
  AND NOT has_table_privilege('authenticated', 'public.cash_movements', 'INSERT,UPDATE,DELETE,TRUNCATE'));
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'f1000000-0000-0000-0000-0000000000a1', true);
SELECT t.expect_error('4.2 the owner can''t set stock by hand',
  $$UPDATE stock_levels SET on_hand = 999 WHERE product_id = 'f1050000-0000-0000-0000-00000000000a'$$, 'permission denied');
SELECT t.expect_error('4.3 the owner can''t set a cash balance by hand',
  $$UPDATE cash_balances SET balance = 999 WHERE cash_account_id = 'f1060000-0000-0000-0000-0000000000da'$$, 'permission denied');
SELECT t.expect_error('4.4 the owner can''t post a stock movement directly (only write functions can)', $$
  INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
  VALUES ('f1010000-0000-0000-0000-00000000000a', 'f1050000-0000-0000-0000-00000000000a',
          'f1020000-0000-0000-0000-0000000000a1', 100, 'adjustment', 'stock_adjustment', gen_random_uuid()) $$,
  'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------- 5. reconciliation
INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
VALUES ('f1010000-0000-0000-0000-00000000000b', 'f1050000-0000-0000-0000-00000000000b', 'f1020000-0000-0000-0000-0000000000b1',
        4, 'purchase_in', 'purchase_invoice', gen_random_uuid());
INSERT INTO store_credit_movements (organization_id, customer_id, amount, source_type, source_id, branch_id)
VALUES ('f1010000-0000-0000-0000-00000000000a', 'f1070000-0000-0000-0000-00000000000a', 75, 'sales_return', gen_random_uuid(),
        'f1020000-0000-0000-0000-0000000000a1');
SELECT t.expect('5.1 after all of the above, shop A and shop B reconcile (no rows)',
  t.mismatches('f1010000-0000-0000-0000-00000000000a') = 0 AND t.mismatches('f1010000-0000-0000-0000-00000000000b') = 0);
SELECT t.expect('5.2 the whole database reconciles (every shop, incl. the seed)', t.mismatches() = 0,
  (SELECT string_agg(ledger || ' ' || subject_id || ' ' || cached || '<>' || from_ledger, '; ') FROM app.ledger_mismatches()));

-- Drift can only come from outside the triggers (a bug or a manual fix). Simulate it as postgres.
SAVEPOINT drift;
UPDATE stock_levels SET on_hand = on_hand + 1 WHERE product_id = 'f1050000-0000-0000-0000-00000000000a';
UPDATE stock_levels SET reserved = reserved - 1 WHERE product_id = 'f1050000-0000-0000-0000-00000000000a';
UPDATE cash_balances SET balance = balance + 0.01 WHERE cash_account_id = 'f1060000-0000-0000-0000-0000000000da';
UPDATE store_credit_balances SET balance = balance - 5 WHERE customer_id = 'f1070000-0000-0000-0000-00000000000a';
SELECT t.expect('5.3 a stock cache 1 above its ledger is reported with both values',
  EXISTS (SELECT 1 FROM app.ledger_mismatches('f1010000-0000-0000-0000-00000000000a')
           WHERE ledger = 'stock_on_hand' AND subject_id = 'f1050000-0000-0000-0000-00000000000a'
             AND branch_id = 'f1020000-0000-0000-0000-0000000000a1' AND detail = 'sellable'
             AND cached = 9 AND from_ledger = 8));
SELECT t.expect('5.4 a reserved count that doesn''t match the active reservations is reported',
  EXISTS (SELECT 1 FROM app.ledger_mismatches('f1010000-0000-0000-0000-00000000000a')
           WHERE ledger = 'stock_reserved' AND cached = 4 AND from_ledger = 5));
SELECT t.expect('5.5 a cash balance off by 0.01 is reported',
  EXISTS (SELECT 1 FROM app.ledger_mismatches('f1010000-0000-0000-0000-00000000000a')
           WHERE ledger = 'cash' AND subject_id = 'f1060000-0000-0000-0000-0000000000da'
             AND cached = 0.01 AND from_ledger = 0));
SELECT t.expect('5.6 a store credit balance that doesn''t match is reported',
  EXISTS (SELECT 1 FROM app.ledger_mismatches('f1010000-0000-0000-0000-00000000000a')
           WHERE ledger = 'store_credit' AND cached = 70 AND from_ledger = 75));
SELECT t.expect('5.7 exactly those 4, and shop B stays clean',
  t.mismatches('f1010000-0000-0000-0000-00000000000a') = 4 AND t.mismatches('f1010000-0000-0000-0000-00000000000b') = 0);
SELECT t.expect('5.8 the all-shops run finds them too', t.mismatches() = 4);
ROLLBACK TO SAVEPOINT drift;

SAVEPOINT missing_cache;
SET LOCAL session_replication_role = replica;   -- a movement that bypassed its trigger: ledger without cache
INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, stock_state, source_type, source_id, business_date)
VALUES ('f1010000-0000-0000-0000-00000000000a', 'f1050000-0000-0000-0000-00000000000a', 'f1020000-0000-0000-0000-0000000000a1',
        2, 'claim_in', 'damaged', 'warranty_claim', gen_random_uuid(), current_date);
SET LOCAL session_replication_role = origin;
SELECT t.expect('5.9 ledger rows with no cache row at all are reported (cached 0)',
  EXISTS (SELECT 1 FROM app.ledger_mismatches('f1010000-0000-0000-0000-00000000000a')
           WHERE ledger = 'stock_on_hand' AND detail = 'damaged' AND cached = 0 AND from_ledger = 2));
ROLLBACK TO SAVEPOINT missing_cache;
SELECT t.expect('5.10 back to clean after the rollback', t.mismatches() = 0);

SELECT t.expect('5.11 the check is internal: app users and anon can''t run it; the service role can',
  NOT has_function_privilege('authenticated', 'app.ledger_mismatches(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'app.ledger_mismatches(uuid)', 'EXECUTE')
  AND has_function_privilege('service_role', 'app.ledger_mismatches(uuid)', 'EXECUTE'));

-- ---------------------------------------------------------------- 6. idempotency
-- A sale written the way every write function must (D33): lock the key, return the existing
-- document on a repeat, only then take the number and post the ledgers, all in one transaction.
CREATE FUNCTION t.sell(p_key text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_org    uuid := 'f1010000-0000-0000-0000-00000000000a';
    v_branch uuid := 'f1020000-0000-0000-0000-0000000000a1';
    v_id     uuid;
BEGIN
    PERFORM app.lock_idempotency_key(v_org, p_key);
    SELECT id INTO v_id FROM public.sales WHERE organization_id = v_org AND idempotency_key = p_key;
    IF FOUND THEN
        RETURN v_id;
    END IF;
    INSERT INTO public.sales (organization_id, number, branch_id, prices_include_vat, subtotal, total, idempotency_key)
    VALUES (v_org, app.next_document_number(v_org, v_branch, 'sale'), v_branch, true, 100, 100, p_key)
    RETURNING id INTO v_id;
    INSERT INTO public.stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
    VALUES (v_org, 'f1050000-0000-0000-0000-00000000000a', v_branch, -1, 'sale_out', 'sale', v_id);
    INSERT INTO public.cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
    VALUES (v_org, 'f1060000-0000-0000-0000-0000000000da', 100, 'sale', 'sale', v_id);
    RETURN v_id;
END $$;

SELECT set_config('t.first', t.sell('f10-repeat-key-1')::text, true);
SELECT set_config('t.second', t.sell('f10-repeat-key-1')::text, true);
SELECT t.expect('6.1 the same key twice returns the same sale', current_setting('t.first') = current_setting('t.second'));
SELECT t.expect('6.2 and changes things once: 1 sale, 1 stock movement (on hand 7), 1 cash movement (balance 100)',
  (SELECT count(*) FROM sales WHERE idempotency_key = 'f10-repeat-key-1') = 1
  AND (SELECT count(*) FROM stock_movements WHERE source_id = current_setting('t.first')::uuid) = 1
  AND (SELECT count(*) FROM cash_movements WHERE source_id = current_setting('t.first')::uuid) = 1
  AND t.on_hand('f1050000-0000-0000-0000-00000000000a') = 7 AND t.balance() = 100);
SELECT t.sell('f10-repeat-key-2');
SELECT t.expect('6.3 the repeat took no document number: the next sale is the very next number',
  (SELECT right(number, 6) FROM sales WHERE idempotency_key = 'f10-repeat-key-2')::integer
  = (SELECT right(number, 6) FROM sales WHERE idempotency_key = 'f10-repeat-key-1')::integer + 1);
SELECT t.expect_error('6.4 an idempotency key shorter than 8 characters is refused',
  $$SELECT app.lock_idempotency_key('f1010000-0000-0000-0000-00000000000a', 'short')$$, 'VALIDATION_FAILED');
SELECT t.expect_error('6.5 a missing idempotency key is refused',
  $$SELECT app.lock_idempotency_key('f1010000-0000-0000-0000-00000000000a', NULL)$$, 'VALIDATION_FAILED');
SELECT t.expect('6.6 still reconciles after the sales', t.mismatches() = 0);

-- ---------------------------------------------------------------- result
SELECT name, ok, detail FROM t.results WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
