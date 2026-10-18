-- TEST-1 ledger invariants (EC-128). LOCAL / DEV ONLY.
-- Run after `npm run db:reset` (uses dev seed shop A):
--   npm run db:smoke -- supabase/tests/ledger_invariants_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
-- F10 (f10_ledger_test.sql) already covers single steps; this file checks the invariants after a
-- mixed sequence, over EVERY row in the database (not only the fixture), straight from the tables
-- (not through app.ledger_mismatches, so the check does not trust the code it checks):
--   1. after in / out / reversal on stock, cash and store credit: every cache = SUM of its ledger
--   2. UPDATE and DELETE on the append-only ledgers raise APPEND_ONLY, as postgres AND service_role
--   3. a stock movement, cash movement, payment or expense can be reversed once only
--   4. idempotency: replaying a key returns the same document and adds no row (payment, D33
--      pattern); every table with idempotency_key has a unique (organization_id, idempotency_key);
--      every function that takes an idempotency key has a replay test (list below)
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
SET TIME ZONE 'Africa/Cairo';

CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request. t.open_shift pairs a free device of the
-- branch (or the one named) and puts it in the request headers the way the API does once it has
-- resolved a device token: x-device-id with the hash of that token (x-device-token-hash). Then it
-- calls public.open_shift unchanged.
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
  -- Paired, as the pairing screens leave it: the device holds the hash of a token.
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
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text, p_vault uuid DEFAULT NULL, p_device uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(p_branch, p_device);
  RETURN public.open_shift(p_branch, p_float, p_key, p_vault, p_device);
END $$;
GRANT EXECUTE ON FUNCTION t.pos(uuid, uuid), t.open_shift(uuid, text, text, uuid, uuid) TO authenticated;
CREATE TABLE t.results (name text, ok boolean, detail text);

CREATE FUNCTION t.expect(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    INSERT INTO t.results VALUES (p_name, p_ok, p_detail);
$$;

CREATE FUNCTION t.expect_error(p_name text, p_sql text, p_pattern text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO t.results VALUES (p_name, false, 'no error raised');
    EXCEPTION WHEN others THEN
        INSERT INTO t.results VALUES (p_name, SQLERRM ~* p_pattern, SQLERRM);
    END;
END $$;

GRANT USAGE ON SCHEMA t TO service_role;
GRANT INSERT ON t.results TO service_role;

-- ---------------------------------------------------------------- fixtures (dev seed shop A)
--   shop d1000000-...-01, branch d2000000-...-11
INSERT INTO public.tax_classes (id, organization_id, name, rate)
VALUES ('e2010000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'VAT 14', 14);
INSERT INTO public.products (id, organization_id, name_ar, sku, cash_price, tax_class_id, is_serialized)
VALUES ('e2020000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'Table', 'T1-LEDGER', 100,
        'e2010000-0000-0000-0000-000000000001', false);
INSERT INTO public.cash_accounts (id, organization_id, branch_id, name, kind)
VALUES ('e2030000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000011', 'T1 drawer', 'drawer');
INSERT INTO public.customers (id, organization_id, full_name)
VALUES ('e2040000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'T1 customer');
INSERT INTO public.expense_categories (id, organization_id, name)
VALUES ('e2050000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'T1 rent');

CREATE TABLE t.ids (name text PRIMARY KEY, id uuid);

CREATE FUNCTION t.stock(p_qty integer, p_type public.stock_movement_type, p_source public.doc_type, p_reverses uuid DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $$
    INSERT INTO public.stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id, reverses_movement_id)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'e2020000-0000-0000-0000-000000000001',
            'd2000000-0000-0000-0000-000000000011', p_qty, p_type, p_source, gen_random_uuid(), p_reverses)
    RETURNING id
$$;
CREATE FUNCTION t.cash(p_amount numeric, p_type public.cash_movement_type, p_source public.doc_type, p_reverses uuid DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $$
    INSERT INTO public.cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id, reverses_movement_id)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'e2030000-0000-0000-0000-000000000001', p_amount, p_type, p_source,
            gen_random_uuid(), p_reverses)
    RETURNING id
$$;
CREATE FUNCTION t.credit(p_amount numeric) RETURNS uuid LANGUAGE sql AS $$
    INSERT INTO public.store_credit_movements (organization_id, customer_id, branch_id, amount, source_type, source_id)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'e2040000-0000-0000-0000-000000000001',
            'd2000000-0000-0000-0000-000000000011', p_amount, 'sales_return', gen_random_uuid())
    RETURNING id
$$;

-- Every cache row vs its ledger, over the WHOLE database, both directions (a ledger with no cache
-- row counts as a cache of 0, a cache with no ledger as a ledger of 0). Returns the mismatches.
CREATE FUNCTION t.stock_drift() RETURNS text LANGUAGE sql AS $$
    SELECT coalesce(string_agg(format('%s/%s/%s cache=%s ledger=%s', coalesce(l.product_id, m.product_id),
                                      coalesce(l.branch_id, m.branch_id), coalesce(l.stock_state, m.stock_state),
                                      coalesce(l.on_hand, 0), coalesce(m.total, 0)), '; '), '')
    FROM public.stock_levels l
    FULL JOIN (SELECT organization_id, product_id, branch_id, stock_state, sum(quantity) AS total
               FROM public.stock_movements GROUP BY 1, 2, 3, 4) m
      ON m.organization_id = l.organization_id AND m.product_id = l.product_id
     AND m.branch_id = l.branch_id AND m.stock_state = l.stock_state
    WHERE coalesce(l.on_hand, 0) <> coalesce(m.total, 0)
$$;
CREATE FUNCTION t.cash_drift() RETURNS text LANGUAGE sql AS $$
    SELECT coalesce(string_agg(format('%s cache=%s ledger=%s', coalesce(b.cash_account_id, m.cash_account_id),
                                      coalesce(b.balance, 0), coalesce(m.total, 0)), '; '), '')
    FROM public.cash_balances b
    FULL JOIN (SELECT organization_id, cash_account_id, sum(amount) AS total FROM public.cash_movements GROUP BY 1, 2) m
      ON m.organization_id = b.organization_id AND m.cash_account_id = b.cash_account_id
    WHERE coalesce(b.balance, 0) <> coalesce(m.total, 0)
$$;
CREATE FUNCTION t.credit_drift() RETURNS text LANGUAGE sql AS $$
    SELECT coalesce(string_agg(format('%s cache=%s ledger=%s', coalesce(b.customer_id, m.customer_id),
                                      coalesce(b.balance, 0), coalesce(m.total, 0)), '; '), '')
    FROM public.store_credit_balances b
    FULL JOIN (SELECT organization_id, customer_id, sum(amount) AS total FROM public.store_credit_movements GROUP BY 1, 2) m
      ON m.organization_id = b.organization_id AND m.customer_id = b.customer_id
    WHERE coalesce(b.balance, 0) <> coalesce(m.total, 0)
$$;

-- ---------------------------------------------------------------- 1. mixed sequence, then invariants
-- stock: in 10, out 3, the out reversed (+3), out 4  -> 6
SELECT t.stock(10, 'purchase_in', 'purchase_invoice');
INSERT INTO t.ids SELECT 'sale_out', t.stock(-3, 'sale_out', 'sale');
INSERT INTO t.ids SELECT 'sale_back', t.stock(3, 'sale_return_in', 'sales_return', (SELECT id FROM t.ids WHERE name = 'sale_out'));
SELECT t.stock(-4, 'sale_out', 'sale');
-- cash: in 500, out 200 (expense), the expense reversed (+200), out 50 -> 450
SELECT t.cash(500, 'sale', 'sale');
INSERT INTO t.ids SELECT 'expense_out', t.cash(-200, 'expense', 'expense');
INSERT INTO t.ids SELECT 'expense_back', t.cash(200, 'adjustment', 'expense', (SELECT id FROM t.ids WHERE name = 'expense_out'));
SELECT t.cash(-50, 'refund', 'sales_return');
-- store credit: +50, -20, +5 -> 35
SELECT t.credit(50); SELECT t.credit(-20); SELECT t.credit(5);

SELECT t.expect('1.1 the fixture ends where expected: on hand 6, drawer 450, store credit 35',
    (SELECT on_hand FROM stock_levels WHERE product_id = 'e2020000-0000-0000-0000-000000000001' AND stock_state = 'sellable') = 6
    AND (SELECT balance FROM cash_balances WHERE cash_account_id = 'e2030000-0000-0000-0000-000000000001') = 450
    AND (SELECT balance FROM store_credit_balances WHERE customer_id = 'e2040000-0000-0000-0000-000000000001') = 35);
SELECT t.expect('1.2 stock_levels.on_hand = SUM(stock_movements) for every product, branch and state (whole DB)',
    t.stock_drift() = '', t.stock_drift());
SELECT t.expect('1.3 cash_balances.balance = SUM(cash_movements) for every account (whole DB)',
    t.cash_drift() = '', t.cash_drift());
SELECT t.expect('1.4 store_credit_balances.balance = SUM(store_credit_movements) for every customer (whole DB)',
    t.credit_drift() = '', t.credit_drift());
SELECT t.expect('1.5 the invariants are not vacuous: the ledgers hold rows',
    (SELECT count(*) FROM stock_movements) >= 4 AND (SELECT count(*) FROM cash_movements) >= 4
    AND (SELECT count(*) FROM store_credit_movements) >= 3);

-- ---------------------------------------------------------------- 2. append-only, also for service_role
-- One payment with an allocation and an audit row, so every table below has a row to aim at.
INSERT INTO public.sales (id, organization_id, number, branch_id, customer_id, prices_include_vat, subtotal, total, idempotency_key)
VALUES ('e2060000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'BR1-SL-26-800001',
        'd2000000-0000-0000-0000-000000000011', 'e2040000-0000-0000-0000-000000000001', true, 100, 100, 'test1-ledger-sale');
INSERT INTO public.payments (id, organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id, idempotency_key)
VALUES ('e2070000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'BR1-PY-26-800001',
        'd2000000-0000-0000-0000-000000000011', 'in', 'cash', 100, 'e2040000-0000-0000-0000-000000000001',
        'e2030000-0000-0000-0000-000000000001', 'test1-ledger-pay-1');
INSERT INTO public.payment_allocations (organization_id, payment_id, amount, sale_id)
VALUES ('d1000000-0000-0000-0000-000000000001', 'e2070000-0000-0000-0000-000000000001', 100, 'e2060000-0000-0000-0000-000000000001');
SELECT app.write_audit('test1.ledger', 'payment', 'e2070000-0000-0000-0000-000000000001', NULL, NULL, NULL, NULL,
                       'info', 'd1000000-0000-0000-0000-000000000001');

CREATE TABLE t.append_only (tbl text PRIMARY KEY, upd text);
INSERT INTO t.append_only VALUES
  ('stock_movements',        'quantity = quantity'),
  ('cash_movements',         'amount = amount'),
  ('store_credit_movements', 'amount = amount'),
  ('payments',               'amount = amount'),
  ('payment_allocations',    'amount = amount'),
  ('audit_log',              'action = action');
-- The rows to aim at: shop A's (the fixture wrote at least one row in each).
CREATE FUNCTION t.append_only_checks(p_as text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM t.append_only ORDER BY tbl LOOP
        PERFORM t.expect_error(format('2 %s: UPDATE %s raises APPEND_ONLY', p_as, r.tbl),
            format('UPDATE public.%I SET %s WHERE organization_id = %L', r.tbl, r.upd, 'd1000000-0000-0000-0000-000000000001'),
            'APPEND_ONLY');
        PERFORM t.expect_error(format('2 %s: DELETE %s raises APPEND_ONLY', p_as, r.tbl),
            format('DELETE FROM public.%I WHERE organization_id = %L', r.tbl, 'd1000000-0000-0000-0000-000000000001'),
            'APPEND_ONLY');
    END LOOP;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO service_role;
GRANT SELECT ON t.append_only TO service_role;

SELECT t.expect('2.0 every append-only table has a shop A row to aim at',
    (SELECT bool_and(n > 0) FROM (
        SELECT (SELECT count(*) FROM stock_movements WHERE organization_id = 'd1000000-0000-0000-0000-000000000001')
        UNION ALL SELECT (SELECT count(*) FROM cash_movements WHERE organization_id = 'd1000000-0000-0000-0000-000000000001')
        UNION ALL SELECT (SELECT count(*) FROM store_credit_movements WHERE organization_id = 'd1000000-0000-0000-0000-000000000001')
        UNION ALL SELECT (SELECT count(*) FROM payments WHERE organization_id = 'd1000000-0000-0000-0000-000000000001')
        UNION ALL SELECT (SELECT count(*) FROM payment_allocations WHERE organization_id = 'd1000000-0000-0000-0000-000000000001')
        UNION ALL SELECT (SELECT count(*) FROM audit_log WHERE organization_id = 'd1000000-0000-0000-0000-000000000001')) c(n)));
SELECT t.append_only_checks('postgres');
SET ROLE service_role;
SELECT t.append_only_checks('service_role');
RESET ROLE;
SELECT t.expect('2.9 nothing was changed or deleted by the attempts above (invariants still hold)',
    t.stock_drift() = '' AND t.cash_drift() = '' AND t.credit_drift() = ''
    AND (SELECT count(*) FROM payments WHERE id = 'e2070000-0000-0000-0000-000000000001') = 1);

-- ---------------------------------------------------------------- 3. reversed once only
SELECT t.expect_error('3.1 the reversed stock movement can''t be reversed a second time',
    $$SELECT t.stock(3, 'sale_return_in', 'sales_return', (SELECT id FROM t.ids WHERE name = 'sale_out'))$$,
    'reversed_once');
SELECT t.expect_error('3.2 the reversed cash movement can''t be reversed a second time',
    $$SELECT t.cash(200, 'adjustment', 'expense', (SELECT id FROM t.ids WHERE name = 'expense_out'))$$,
    'reversed_once');
INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id,
                             reverses_payment_id, reason, idempotency_key)
VALUES ('d1000000-0000-0000-0000-000000000001', 'BR1-PY-26-800002', 'd2000000-0000-0000-0000-000000000011', 'out', 'cash', 100,
        'e2040000-0000-0000-0000-000000000001', 'e2030000-0000-0000-0000-000000000001',
        'e2070000-0000-0000-0000-000000000001', 'TEST-1 reversal', 'test1-ledger-rev-1');
SELECT t.expect_error('3.3 the reversed payment can''t be reversed a second time', $$
    INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id,
                                 reverses_payment_id, reason, idempotency_key)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'BR1-PY-26-800003', 'd2000000-0000-0000-0000-000000000011', 'out', 'cash', 100,
            'e2040000-0000-0000-0000-000000000001', 'e2030000-0000-0000-0000-000000000001',
            'e2070000-0000-0000-0000-000000000001', 'TEST-1 second reversal', 'test1-ledger-rev-2') $$,
    'reversed_once');
SELECT t.expect('3.4 every reversal column in the schema has a reversed-once unique index',
    NOT EXISTS (
        SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND a.attname LIKE 'reverses\_%' AND NOT a.attisdropped
          AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisunique AND i.indnatts = 1
                          AND i.indkey[0] = a.attnum)),
    (SELECT string_agg(c.relname || '.' || a.attname, ', ')
     FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND a.attname LIKE 'reverses\_%' AND NOT a.attisdropped
       AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisunique AND i.indnatts = 1 AND i.indkey[0] = a.attnum)));

-- ---------------------------------------------------------------- 4. idempotency
-- A payment the way every write function must post one (D33): lock the key, return the existing
-- document on a repeat, only then take the number and post the cash ledger.
CREATE FUNCTION t.receive(p_key text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_org uuid := 'd1000000-0000-0000-0000-000000000001';
    v_branch uuid := 'd2000000-0000-0000-0000-000000000011';
    v_id uuid;
BEGIN
    PERFORM app.lock_idempotency_key(v_org, p_key);
    SELECT id INTO v_id FROM public.payments WHERE organization_id = v_org AND idempotency_key = p_key;
    IF FOUND THEN RETURN v_id; END IF;
    INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id, idempotency_key)
    VALUES (v_org, app.next_document_number(v_org, v_branch, 'payment'), v_branch, 'in', 'cash', 75,
            'e2040000-0000-0000-0000-000000000001', 'e2030000-0000-0000-0000-000000000001', p_key)
    RETURNING id INTO v_id;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
    VALUES (v_org, 'e2030000-0000-0000-0000-000000000001', 75, 'collection', 'payment', v_id);
    RETURN v_id;
END $$;
SELECT set_config('t.first', t.receive('test1-replay-key-1')::text, true);
SELECT set_config('t.second', t.receive('test1-replay-key-1')::text, true);
SELECT t.expect('4.1 replaying a payment key returns the same payment id',
    current_setting('t.first') = current_setting('t.second'));
SELECT t.expect('4.2 and adds no second row: 1 payment, 1 cash movement, invariants hold',
    (SELECT count(*) FROM payments WHERE idempotency_key = 'test1-replay-key-1') = 1
    AND (SELECT count(*) FROM cash_movements WHERE source_id = current_setting('t.first')::uuid) = 1
    AND t.cash_drift() = '');
SELECT t.expect_error('4.3 a second payment with the same key straight into the table is refused',
    $$INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id, idempotency_key)
      VALUES ('d1000000-0000-0000-0000-000000000001', 'BR1-PY-26-800009', 'd2000000-0000-0000-0000-000000000011', 'in', 'cash', 75,
              'e2040000-0000-0000-0000-000000000001', 'e2030000-0000-0000-0000-000000000001', 'test1-replay-key-1')$$,
    'payments_idem_key');

-- Generic: every table with idempotency_key has a unique index on exactly (organization_id, idempotency_key).
CREATE TABLE t.idem_tables AS
SELECT c.relname::text AS tbl,
       EXISTS (SELECT 1 FROM pg_index i
               WHERE i.indrelid = c.oid AND i.indisunique AND i.indpred IS NULL AND i.indnatts = 2
                 AND (SELECT array_agg(att.attname::text ORDER BY att.attname) FROM pg_attribute att
                      WHERE att.attrelid = c.oid AND att.attnum = ANY (i.indkey))
                     = ARRAY['idempotency_key', 'organization_id']) AS has_unique
FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'idempotency_key' AND NOT a.attisdropped
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r';
SELECT t.expect('4.4 every table with idempotency_key has UNIQUE (organization_id, idempotency_key)',
    (SELECT count(*) FROM t.idem_tables) >= 15 AND NOT EXISTS (SELECT 1 FROM t.idem_tables WHERE NOT has_unique),
    (SELECT format('%s tables; missing: %s', count(*), string_agg(tbl, ', ') FILTER (WHERE NOT has_unique)) FROM t.idem_tables));

-- Generic: every function that takes an idempotency key must have a replay test. Today only the D33
-- helper app.lock_idempotency_key does (replays: 4.1 here, f10 6.1-6.5). A new F10/F11 write
-- function with a key fails 4.5 until its replay test is added and it is listed here.
CREATE TABLE t.replay_tested (fn text PRIMARY KEY, where_tested text);
INSERT INTO t.replay_tested VALUES ('app.lock_idempotency_key', 'ledger_invariants 4.1-4.3, f10_ledger 6.1-6.5');
INSERT INTO t.replay_tested VALUES ('public.admin_record_subscription_payment','p05_subscription_test.sql: replay same id, one payment and one audit');
INSERT INTO t.replay_tested VALUES
 ('public.post_stock_adjustment','i02_stock_adjustments_test.sql: same key -> same adjustment, stock unchanged'),
 ('public.create_stock_count','i02_stock_adjustments_test.sql: same key -> same count'),
 ('public.register_units','i04_units_test.sql: same key -> same batch, nothing created twice'),
 ('public.create_stock_transfer','i03_transfers_test.sql: same key -> same transfer'),
 ('public.create_purchase_invoice','u02_purchase_invoices_test.sql: same key -> same invoice, no second row or audit'),
 ('app.post_sale_core','s01_sale_core_test.sql: only reached through public.post_sale, which answers a repeated key before calling it'),
 ('public.open_warranty_claim','s12_warranty_test.sql: same key returns the same claim; conflict rejected'),
 ('public.void_sale','s07_sales_history_test.sql: same key returns the same reversal'),
   ('public.post_sale','s01_sale_core_test.sql: same key -> same sale; no second document, movement, payment or number'),
   ('public.post_collection','n03_collections_test.sql: same key -> same receipt, nothing written twice; a sale''s key -> IDEMPOTENCY_CONFLICT'),
   ('public.reverse_collection','n03_collections_test.sql: same key -> same reversal; another key -> already_reversed'),
   ('public.settle_contract_early','n05_contract_changes_test.sql: same key -> same change and receipt, no second payment'),
   ('public.reschedule_contract','n05_contract_changes_test.sql: same key -> same change; another contract''s or a sale''s key -> IDEMPOTENCY_CONFLICT'),
   ('public.write_off_contract','n05_contract_changes_test.sql: same key -> same change, one row'),
   ('public.post_installment_sale','n02_installment_sale_test.sql: same key -> same sale and contract; nothing written twice; a cash sale''s key -> IDEMPOTENCY_CONFLICT'),
 ('public.post_expense','k03_expenses_test.sql: same key -> same expense, nothing spent twice'),
 ('public.reverse_expense','k03_expenses_test.sql: same key -> same reversal; the key of another expense -> IDEMPOTENCY_CONFLICT'),
 ('public.open_shift','k02_shifts_test.sql: same key -> same shift, nothing moves'),
 ('public.move_shift_cash','k02_shifts_test.sql: same key -> nothing moves, one audit row'),
 ('public.create_purchase_order','u05_purchase_orders_test.sql: same key -> same order, one row, one audit'),
 ('public.create_invoice_from_po','u05_purchase_orders_test.sql: same key -> same invoice, one invoice on the order'),
 ('public.post_supplier_payment','u03_supplier_payments_test.sql: same key -> same payment, the safe, the balances and the movement count unchanged'),
 ('public.reverse_supplier_payment','u03_supplier_payments_test.sql: same key -> same reversal, nothing moves; the key of another payment -> IDEMPOTENCY_CONFLICT'),
 ('public.post_purchase_return','u04_purchase_returns_test.sql: same key -> same return, stock and balance unchanged'),
 ('public.create_cash_transfer','k01_vaults_test.sql: same key -> same transfer, nothing new'),
 ('public.post_cash_opening','k01_vaults_test.sql: same key -> nothing new; the key used for another account -> VALIDATION_FAILED'),
 ('public.post_stock_count','i02_stock_adjustments_test.sql: same key -> same adjustment, nothing posted twice; key reused for another count -> IDEMPOTENCY_CONFLICT');
CREATE TABLE t.key_functions AS
SELECT n.nspname || '.' || p.proname AS fn
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('public', 'app')
  AND (p.proname ~* 'idempot' OR EXISTS (SELECT 1 FROM unnest(p.proargnames) an WHERE an ~* 'idempot'));
SELECT t.expect('4.5 every function that takes an idempotency key has a replay test',
    (SELECT count(*) FROM t.key_functions) >= 1
    AND NOT EXISTS (SELECT 1 FROM t.key_functions k WHERE k.fn NOT IN (SELECT fn FROM t.replay_tested)),
    (SELECT 'no replay test for: ' || string_agg(fn, ', ') FROM t.key_functions k WHERE k.fn NOT IN (SELECT fn FROM t.replay_tested)));

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
