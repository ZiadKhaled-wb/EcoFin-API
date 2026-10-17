-- Origin: ecotech-agent-kit/smoke_test.sql (copied for F02, 3 Oct 2026). Two changes:
-- 1. the fixture insert names its columns, INSERT INTO auth.users (id, email), so it works on
--    real Supabase auth.users (which starts with instance_id).
-- 2. SET TIME ZONE line below (see F02 for details).
-- Run it with: npm run db:smoke
-- Smoke tests for the V1 baseline (79 checks). LOCAL / DEV ONLY: it inserts test shops.
-- Run after `supabase db reset`:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f smoke_test.sql
-- Expected last line: passed 79, failed 0.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
SET TIME ZONE 'Africa/Cairo';
-- business dates follow the shop timezone (fixture shops use the default); keeps current_date aligned

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

-- ---------------------------------------------------------------- fixtures
INSERT INTO auth.users (id, email) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'owner-a@x'),
  ('a0000000-0000-0000-0000-0000000000ca', 'cashier-a@x'),
  ('b0000000-0000-0000-0000-00000000000b', 'owner-b@x');

INSERT INTO organizations (id, tenant_slug, name, plan_key) VALUES
  ('10000000-0000-0000-0000-00000000000a', 'shop-a', 'Shop A', 'retail'),
  ('10000000-0000-0000-0000-00000000000b', 'shop-b', 'Shop B', 'retail');
INSERT INTO org_settings (organization_id) VALUES ('10000000-0000-0000-0000-00000000000a'), ('10000000-0000-0000-0000-00000000000b');

INSERT INTO branches (id, organization_id, code, name, is_main) VALUES
  ('20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'BR1', 'Main A', true),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'BR1', 'Main B', true);

INSERT INTO employees (id, organization_id, auth_user_id, full_name, role, national_id, username) VALUES
  ('30000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-00000000000a', 'Owner A', 'OWNER', '29001011234567', 'owner.a'),
  ('30000000-0000-0000-0000-0000000000ca', '10000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-0000000000ca', 'Cashier A', 'CASHIER', NULL, 'cashier.a'),
  ('30000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'b0000000-0000-0000-0000-00000000000b', 'Owner B', 'OWNER', NULL, 'owner.b');
INSERT INTO employee_branches (organization_id, employee_id, branch_id) VALUES
  ('10000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-0000000000ca', '20000000-0000-0000-0000-00000000000a');

INSERT INTO tax_classes (id, organization_id, name, rate) VALUES
  ('40000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'VAT 14', 14),
  ('40000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'VAT 14', 14);

INSERT INTO products (id, organization_id, name_ar, sku, cash_price, tax_class_id, is_serialized) VALUES
  ('50000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'Sofa', 'SOFA-1', 10000, '40000000-0000-0000-0000-00000000000a', false),
  ('50000000-0000-0000-0000-0000000000aa', '10000000-0000-0000-0000-00000000000a', 'Phone', 'PH-1', 8000, '40000000-0000-0000-0000-00000000000a', true),
  ('50000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'Table', 'TB-1', 3000, '40000000-0000-0000-0000-00000000000b', false);

INSERT INTO cash_accounts (id, organization_id, branch_id, name, kind) VALUES
  ('60000000-0000-0000-0000-0000000000da', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', 'Drawer 1', 'drawer'),
  ('60000000-0000-0000-0000-0000000000ba', '10000000-0000-0000-0000-00000000000a', NULL, 'Bank', 'bank');

INSERT INTO customers (id, organization_id, full_name, national_id, credit_limit) VALUES
  ('70000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'Customer A', '28001011234567', 20000);

INSERT INTO installment_policies (id, organization_id, version, max_months, markup_tiers) VALUES
  ('80000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 1, 24, '[{"up_to_months": 24, "pct": 20}]');

-- ---------------------------------------------------------------- stock
INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, unit_cost, source_type, source_id)
VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
        5, 'purchase_in', 6000, 'purchase_invoice', gen_random_uuid());
SELECT t.expect('stock: level after purchase = 5',
    (SELECT on_hand = 5 FROM stock_levels WHERE product_id = '50000000-0000-0000-0000-00000000000a'));

SELECT t.expect_error('stock: oversell blocked', $$
    INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
    VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
            -6, 'sale_out', 'sale', gen_random_uuid()) $$, 'OUT_OF_STOCK');

INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
        -1, 'sale_out', 'sale', gen_random_uuid()),
       ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
        1, 'sale_return_in', 'sales_return', gen_random_uuid());
SELECT t.expect('stock: normal sale and return work', (SELECT on_hand = 5 FROM stock_levels WHERE product_id = '50000000-0000-0000-0000-00000000000a'));

SELECT t.expect_error('stock: ledger is append-only', $$
    UPDATE stock_movements SET quantity = 50 $$, 'APPEND_ONLY');

SELECT t.expect_error('stock: stock_levels cannot be re-keyed', $$
    UPDATE stock_levels SET product_id = '50000000-0000-0000-0000-0000000000aa' $$, 'FROZEN_ROW');

SELECT t.expect_error('stock: serialized product needs a unit', $$
    INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
    VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-00000000000a',
            1, 'purchase_in', 'purchase_invoice', gen_random_uuid()) $$, 'UNIT_REQUIRED');

SELECT t.expect_error('stock: future business date refused', $$
    INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id, business_date)
    VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
            1, 'adjustment', 'stock_adjustment', gen_random_uuid(), current_date + 5) $$, 'FUTURE_BUSINESS_DATE');

-- reservations: reserve 3 of 5, then selling 3 must fail (only 2 free)
INSERT INTO sales_orders (id, organization_id, number, customer_id, branch_id, prices_include_vat, subtotal, total, idempotency_key)
VALUES ('90000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'BR1-SO-26-000001',
        '70000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', true, 30000, 30000, 'order-key-0001');
INSERT INTO sales_order_lines (id, organization_id, order_id, line_no, product_id, quantity, unit_price, tax_class_id, tax_rate, line_total)
VALUES ('91000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', '90000000-0000-0000-0000-00000000000a', 1,
        '50000000-0000-0000-0000-00000000000a', 3, 10000, '40000000-0000-0000-0000-00000000000a', 14, 30000);
INSERT INTO stock_reservations (id, organization_id, product_id, branch_id, order_line_id, quantity)
VALUES ('92000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a',
        '20000000-0000-0000-0000-00000000000a', '91000000-0000-0000-0000-00000000000a', 3);
SELECT t.expect('reserve: reserved = 3', (SELECT reserved = 3 FROM stock_levels WHERE product_id = '50000000-0000-0000-0000-00000000000a'));
SELECT t.expect_error('reserve: cannot sell reserved stock', $$
    INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
    VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
            -3, 'sale_out', 'sale', gen_random_uuid()) $$, 'OUT_OF_STOCK');
SELECT t.expect_error('reserve: cannot reserve more than free stock', $$
    INSERT INTO stock_reservations (organization_id, product_id, branch_id, order_line_id, quantity)
    VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', '91000000-0000-0000-0000-00000000000a', 3) $$, 'NOT_ENOUGH_STOCK');
UPDATE stock_reservations SET status = 'released', released_at = now() WHERE id = '92000000-0000-0000-0000-00000000000a';
SELECT t.expect('reserve: release frees stock', (SELECT reserved = 0 FROM stock_levels WHERE product_id = '50000000-0000-0000-0000-00000000000a'));

-- ---------------------------------------------------------------- cross-tenant
SELECT t.expect_error('tenant: sale line cannot point at another shop''s product', $$
    INSERT INTO sales_order_lines (organization_id, order_id, line_no, product_id, quantity, unit_price, tax_class_id, tax_rate, line_total)
    VALUES ('10000000-0000-0000-0000-00000000000a', '90000000-0000-0000-0000-00000000000a', 2,
            '50000000-0000-0000-0000-00000000000b', 1, 3000, '40000000-0000-0000-0000-00000000000a', 14, 3000) $$, 'foreign key');
SELECT t.expect_error('tenant: who-column must be same-shop employee', $$
    INSERT INTO categories (organization_id, name, created_by)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'X', '30000000-0000-0000-0000-00000000000b') $$, 'foreign key');

-- ---------------------------------------------------------------- cash
SELECT t.expect_error('cash: drawer cannot go negative', $$
    INSERT INTO cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
    VALUES ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000da', -100, 'expense', 'expense', gen_random_uuid()) $$,
    'INSUFFICIENT_FUNDS');
INSERT INTO cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
VALUES ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000da', 500, 'float_in', 'shift', gen_random_uuid());
SELECT t.expect('cash: balance and branch copied',
    (SELECT b.balance = 500 FROM cash_balances b WHERE b.cash_account_id = '60000000-0000-0000-0000-0000000000da')
    AND (SELECT branch_id = '20000000-0000-0000-0000-00000000000a' FROM cash_movements WHERE cash_account_id = '60000000-0000-0000-0000-0000000000da' LIMIT 1));

-- ---------------------------------------------------------------- numbering
SELECT t.expect('numbering: sequential per branch/type/year',
    app.next_document_number('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', 'sale')
      = 'BR1-SL-' || to_char(current_date, 'YY') || '-000001'
    AND app.next_document_number('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', 'sale')
      = 'BR1-SL-' || to_char(current_date, 'YY') || '-000002');
SELECT t.expect_error('numbering: branch must belong to org', $$
    SELECT app.next_document_number('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000b', 'sale') $$,
    'BRANCH_NOT_IN_ORG');

-- ---------------------------------------------------------------- sale + contract + collection
INSERT INTO sales (id, organization_id, number, branch_id, customer_id, prices_include_vat, subtotal, tax_total, total, idempotency_key)
VALUES ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'BR1-SL-26-000010',
        '20000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a', true, 10000, 1228.07, 10000, 'sale-key-00001');
SELECT t.expect_error('sale: totals must add up', $$
    INSERT INTO sales (organization_id, number, branch_id, prices_include_vat, subtotal, tax_total, total, idempotency_key)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'BR1-SL-26-000011', '20000000-0000-0000-0000-00000000000a',
            false, 1000, 140, 1000, 'sale-key-00002') $$, 'check constraint');
SELECT t.expect_error('sale: idempotency key unique', $$
    INSERT INTO sales (organization_id, number, branch_id, prices_include_vat, subtotal, total, idempotency_key)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'BR1-SL-26-000012', '20000000-0000-0000-0000-00000000000a',
            true, 10, 10, 'sale-key-00001') $$, 'sales_idem_key');
SELECT t.expect_error('sale: issued sale cannot change', $$
    UPDATE sales SET total = 1 $$, 'APPEND_ONLY');

INSERT INTO contracts (id, organization_id, number, customer_id, branch_id, sale_id, policy_id, creditor, cash_price,
                       down_payment, financed_amount, markup_pct, markup_amount, total_payable, installments_count,
                       frequency, first_due_date, idempotency_key)
VALUES ('a2000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'BR1-CT-26-000001',
        '70000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-00000000000a',
        '80000000-0000-0000-0000-00000000000a', 'in_house', 10000, 2000, 8000, 20, 1600, 9600, 2, 'monthly',
        current_date - 40, 'contract-key-01');
INSERT INTO schedule_lines (id, organization_id, contract_id, version, seq, due_date, principal, profit) VALUES
  ('a3000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-00000000000a', 1, 1, current_date - 40, 4000, 800),
  ('a3000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-00000000000a', 1, 2, current_date + 20, 4000, 800);

SELECT t.expect_error('contract: terms frozen', $$
    UPDATE contracts SET cash_price = 1 $$, 'FROZEN_ROW');
SELECT t.expect_error('contract: totals must add up', $$
    INSERT INTO contracts (organization_id, number, customer_id, branch_id, sale_id, policy_id, creditor, cash_price,
                           down_payment, financed_amount, markup_pct, markup_amount, total_payable, installments_count,
                           frequency, first_due_date, idempotency_key)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'BR1-CT-26-000002', '70000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', NULL, '80000000-0000-0000-0000-00000000000a', 'in_house',
            10000, 2000, 8000, 20, 1600, 9999, 2, 'monthly', current_date, 'contract-key-02') $$, 'check constraint');
SELECT t.expect_error('schedule: amounts frozen', $$
    UPDATE schedule_lines SET principal = 1 $$, 'FROZEN_ROW');

-- down payment 2000 cash + collection of 3000 on line 1 (800 profit first, then 2200 principal)
INSERT INTO payments (id, organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id, idempotency_key)
VALUES ('a4000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'BR1-PY-26-000001',
        '20000000-0000-0000-0000-00000000000a', 'in', 'cash', 2000, '70000000-0000-0000-0000-00000000000a',
        '60000000-0000-0000-0000-0000000000da', 'pay-key-000001'),
       ('a4000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', 'BR1-PY-26-000002',
        '20000000-0000-0000-0000-00000000000a', 'in', 'cash', 3000, '70000000-0000-0000-0000-00000000000a',
        '60000000-0000-0000-0000-0000000000da', 'pay-key-000002');
INSERT INTO payment_allocations (organization_id, payment_id, amount, sale_id) VALUES
  ('10000000-0000-0000-0000-00000000000a', 'a4000000-0000-0000-0000-000000000001', 2000, 'a1000000-0000-0000-0000-00000000000a');
INSERT INTO payment_allocations (organization_id, payment_id, amount, schedule_line_id, contract_id, principal_amount, profit_amount) VALUES
  ('10000000-0000-0000-0000-00000000000a', 'a4000000-0000-0000-0000-000000000002', 3000,
   'a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000a', 2200, 800);

SELECT t.expect_error('allocation: exactly one target', $$
    INSERT INTO payment_allocations (organization_id, payment_id, amount, sale_id, order_id)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'a4000000-0000-0000-0000-000000000001', 1,
            'a1000000-0000-0000-0000-00000000000a', '90000000-0000-0000-0000-00000000000a') $$, 'one_target');
SELECT t.expect_error('allocation: line must belong to the stated contract', $$
    INSERT INTO payment_allocations (organization_id, payment_id, amount, schedule_line_id, contract_id, principal_amount, profit_amount)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'a4000000-0000-0000-0000-000000000002', 1,
            'a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-0000000000ff', 1, 0) $$, 'foreign key');

SELECT t.expect('view: sale fully settled (paid 2000 + financed 8000)',
    (SELECT unpaid = 0 AND paid = 2000 AND financed = 8000 FROM v_sale_balances WHERE sale_id = 'a1000000-0000-0000-0000-00000000000a'));
SELECT t.expect('view: line 1 overdue with 1800 left',
    (SELECT status = 'overdue' AND remaining = 1800 AND principal_remaining = 1800
     FROM v_schedule_line_status WHERE schedule_line_id = 'a3000000-0000-0000-0000-000000000001'));
SELECT t.expect('view: contract paid 3000, remaining 6600, principal 5800',
    (SELECT paid = 3000 AND remaining = 6600 AND principal_outstanding = 5800 AND overdue_lines = 1
     FROM v_contract_balances WHERE contract_id = 'a2000000-0000-0000-0000-00000000000a'));
SELECT t.expect('view: exposure 5800, available 14200',
    (SELECT exposure = 5800 AND available_credit = 14200 FROM v_customer_exposure WHERE customer_id = '70000000-0000-0000-0000-00000000000a'));
SELECT t.expect('view: aging puts 1800 in 31-60',
    (SELECT late_31_60 = 1800 AND not_yet_due = 4800 FROM v_receivables_aging WHERE contract_id = 'a2000000-0000-0000-0000-00000000000a'));

-- reversing the collection removes it from every balance
INSERT INTO payments (organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id,
                      reverses_payment_id, reason, idempotency_key)
VALUES ('10000000-0000-0000-0000-00000000000a', 'BR1-PY-26-000003', '20000000-0000-0000-0000-00000000000a', 'out', 'cash', 3000,
        '70000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000da', 'a4000000-0000-0000-0000-000000000002',
        'Wrong customer', 'pay-key-000003');
SELECT t.expect('view: reversed payment ignored',
    (SELECT paid = 0 AND principal_outstanding = 8000 FROM v_contract_balances WHERE contract_id = 'a2000000-0000-0000-0000-00000000000a'));
SELECT t.expect_error('payment: reversed only once', $$
    INSERT INTO payments (organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id,
                          reverses_payment_id, reason, idempotency_key)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'BR1-PY-26-000004', '20000000-0000-0000-0000-00000000000a', 'out', 'cash', 3000,
            '70000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000da', 'a4000000-0000-0000-0000-000000000002',
            'again', 'pay-key-000004') $$, 'reversed_once');

-- no late fees (N04, D79, Islamic finance rule 4): a charge row can't be written at all
SELECT t.expect_error('charges: no late fee can be written', $$
    INSERT INTO charges (organization_id, contract_id, schedule_line_id, assessed_on, amount)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-00000000000a', 'a3000000-0000-0000-0000-000000000001', current_date, 50) $$,
    'LATE_FEES_NOT_ALLOWED');

-- store credit can't go negative
SELECT t.expect_error('store credit: cannot go negative', $$
    INSERT INTO store_credit_movements (organization_id, customer_id, amount, source_type, source_id, branch_id)
    VALUES ('10000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a', -10, 'payment', gen_random_uuid(),
            '20000000-0000-0000-0000-00000000000a') $$,
    'INSUFFICIENT_STORE_CREDIT');

-- ---------------------------------------------------------------- purchase invoice freeze
INSERT INTO suppliers (id, organization_id, name) VALUES ('b1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'Supplier');
INSERT INTO purchase_invoices (id, organization_id, number, supplier_id, branch_id, invoice_date, status, subtotal, tax_total, total,
                               approved_by, approved_at, idempotency_key)
VALUES ('b2000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'BR1-PI-26-000001',
        'b1000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', current_date, 'approved', 1000, 140, 1140,
        '30000000-0000-0000-0000-00000000000a', now(), 'pi-key-000001');
SELECT t.expect_error('purchase: approved invoice frozen', $$
    UPDATE purchase_invoices SET total = 1, subtotal = 1, tax_total = 0 $$, 'DOCUMENT_FINAL');
SELECT t.expect_error('purchase: no new lines on approved invoice', $$
    INSERT INTO purchase_invoice_lines (organization_id, invoice_id, product_id, quantity, unit_cost, tax_class_id, line_total)
    VALUES ('10000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a',
            1, 100, '40000000-0000-0000-0000-00000000000a', 100) $$, 'DOCUMENT_FINAL');
SELECT t.expect('view: supplier owes 1140', (SELECT balance = 1140 FROM v_supplier_balances WHERE supplier_id = 'b1000000-0000-0000-0000-00000000000a'));


-- ---------------------------------------------------------------- review fixes
-- reschedule: old lines can be superseded, new version allowed for return adjustments
UPDATE schedule_lines SET superseded = true WHERE id = 'a3000000-0000-0000-0000-000000000002';
SELECT t.expect('schedule: superseded can be set', (SELECT superseded FROM schedule_lines WHERE id = 'a3000000-0000-0000-0000-000000000002'));
INSERT INTO sales_returns (id, organization_id, number, sale_id, branch_id, kind, refund_method, subtotal, total, reason, business_date, idempotency_key)
VALUES ('a5000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'BR1-RT-26-000001', 'a1000000-0000-0000-0000-00000000000a',
        '20000000-0000-0000-0000-00000000000a', 'return', 'contract_adjustment', 1000, 1000, 'Scratched', current_date - 1, 'ret-key-00001');
INSERT INTO contract_changes (organization_id, contract_id, kind, old_version, new_version, amount, reason, sales_return_id, idempotency_key)
VALUES ('10000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-00000000000a', 'return_adjustment', 1, 2, 1000, 'Partial return',
        'a5000000-0000-0000-0000-00000000000a', 'chg-key-00001');
SELECT t.expect('contract change: return adjustment with new version allowed', true);

-- IMEI: one unit, one place
INSERT INTO units (id, organization_id, product_id, serial, branch_id, cost)
VALUES ('c1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa',
        '356938035643809', '20000000-0000-0000-0000-00000000000a', 7000),
       ('c1000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa',
        '356938035643810', '20000000-0000-0000-0000-00000000000a', 7000);
INSERT INTO stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, source_type, source_id, business_date) VALUES
  ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-00000000000a',
   'c1000000-0000-0000-0000-00000000000a', 1, 'purchase_in', 'purchase_invoice', gen_random_uuid(), current_date - 1),
  ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-00000000000a',
   'c1000000-0000-0000-0000-00000000000b', 1, 'purchase_in', 'purchase_invoice', gen_random_uuid(), current_date - 1);
INSERT INTO stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, source_type, source_id, business_date) VALUES
  ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-00000000000a',
   'c1000000-0000-0000-0000-00000000000a', -1, 'sale_out', 'sale', gen_random_uuid(), current_date - 1);
SELECT t.expect('imei: unit marked sold by the trigger', (SELECT status = 'sold' FROM units WHERE id = 'c1000000-0000-0000-0000-00000000000a'));
SELECT t.expect_error('imei: same unit cannot be sold twice (other stock exists)', $$
    INSERT INTO stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, source_type, source_id, business_date)
    VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-00000000000a',
            'c1000000-0000-0000-0000-00000000000a', -1, 'sale_out', 'sale', gen_random_uuid(), current_date - 1) $$, 'UNIT_NOT_AVAILABLE');
SELECT t.expect_error('imei: unit already in stock cannot come in again', $$
    INSERT INTO stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, source_type, source_id, business_date)
    VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000aa', '20000000-0000-0000-0000-00000000000a',
            'c1000000-0000-0000-0000-00000000000b', 1, 'adjustment', 'stock_adjustment', gen_random_uuid(), current_date - 1) $$, 'UNIT_ALREADY_IN_STOCK');

-- damaged returns are kept apart from sellable stock
INSERT INTO stock_movements (organization_id, product_id, branch_id, quantity, type, stock_state, source_type, source_id, business_date)
VALUES ('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
        1, 'sale_return_in', 'damaged', 'sales_return', gen_random_uuid(), current_date - 1);
SELECT t.expect('damaged: separate bucket', (SELECT available = 5 AND damaged = 1 FROM v_stock_available WHERE product_id = '50000000-0000-0000-0000-00000000000a'));

-- bank: org-wide account needs the paying branch; deposits always accepted
SELECT t.expect_error('bank: needs paying branch', $$
    INSERT INTO cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id, business_date)
    VALUES ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000ba', 100, 'deposit', 'payment', gen_random_uuid(), current_date - 1) $$,
    'BRANCH_REQUIRED');
INSERT INTO cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type, source_id, business_date)
VALUES ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-00000000000a', 100, 'deposit', 'payment', gen_random_uuid(), current_date - 1);
SELECT t.expect_error('bank: no overdraft unless allowed', $$
    INSERT INTO cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type, source_id, business_date)
    VALUES ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-00000000000a', -500, 'expense', 'expense', gen_random_uuid(), current_date - 1) $$,
    'INSUFFICIENT_FUNDS');

-- shift expected cash counts only this shift's movements
INSERT INTO shifts (id, organization_id, number, branch_id, employee_id, drawer_account_id, opening_float, idempotency_key)
VALUES ('d1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'BR1-SH-26-000001',
        '20000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-0000000000ca', '60000000-0000-0000-0000-0000000000da', 200, 'shift-key-0001');
INSERT INTO cash_movements (organization_id, cash_account_id, shift_id, amount, type, source_type, source_id, business_date) VALUES
  ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000da', 'd1000000-0000-0000-0000-00000000000a', 200, 'float_in', 'shift', gen_random_uuid(), current_date - 1),
  ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000da', 'd1000000-0000-0000-0000-00000000000a', 1000, 'sale', 'sale', gen_random_uuid(), current_date - 1);
SELECT t.expect('shift: expected = float + sales (not old drawer cash)',
    (SELECT expected_cash = 1200 FROM v_shift_expected_cash WHERE shift_id = 'd1000000-0000-0000-0000-00000000000a'));

-- written-off contracts don't show overdue lines
INSERT INTO contracts (id, organization_id, number, customer_id, branch_id, order_id, policy_id, creditor, cash_price,
                       down_payment, financed_amount, markup_pct, markup_amount, total_payable, installments_count,
                       frequency, first_due_date, idempotency_key, status, closed_at)
VALUES ('a2000000-0000-0000-0000-0000000000bb', '10000000-0000-0000-0000-00000000000a', 'BR1-CT-26-000003',
        '70000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', '90000000-0000-0000-0000-00000000000a',
        '80000000-0000-0000-0000-00000000000a', 'in_house', 1000, 0, 1000, 0, 0, 1000, 1, 'monthly', current_date - 90,
        'contract-key-03', 'written_off', now());
INSERT INTO schedule_lines (organization_id, contract_id, version, seq, due_date, principal, profit)
VALUES ('10000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-0000000000bb', 1, 1, current_date - 90, 1000, 0);
SELECT t.expect('schedule: written-off contract lines are closed, not overdue',
    (SELECT status = 'closed' FROM v_schedule_line_status WHERE contract_id = 'a2000000-0000-0000-0000-0000000000bb'));
SELECT t.expect('order: financed by order contract', (SELECT financed = 1000 AND unpaid = 29000 FROM v_order_balances WHERE order_id = '90000000-0000-0000-0000-00000000000a'));

-- jobs: stuck jobs come back, exhausted jobs die
INSERT INTO jobs (id, job_type, status, locked_at, attempts) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'eta.submit', 'running', now() - interval '1 hour', 1),
  ('e1000000-0000-0000-0000-000000000002', 'eta.submit', 'queued', NULL, 5);
SELECT t.expect('jobs: stale job reclaimed', (SELECT count(*) = 1 FROM app.claim_jobs('w1')));
SELECT t.expect('jobs: exhausted job dead', (SELECT status = 'dead' FROM jobs WHERE id = 'e1000000-0000-0000-0000-000000000002'));


-- ---------------------------------------------------------------- deletes, closed day
SELECT t.expect_error('delete: master data never deleted', $$ DELETE FROM products $$, 'NO_DELETE');
SELECT t.expect_error('delete: policy versions immutable', $$ DELETE FROM installment_policies $$, 'APPEND_ONLY');
INSERT INTO day_closes (organization_id, branch_id, business_date, closed_by)
VALUES ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', current_date, '30000000-0000-0000-0000-00000000000a');
SELECT t.expect_error('day close: no ledger rows into a closed day', $$
    INSERT INTO cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
    VALUES ('10000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000da', 10, 'adjustment', 'expense', gen_random_uuid()) $$,
    'DAY_CLOSED');

-- ---------------------------------------------------------------- permissions (as postgres, impersonating via JWT sub)
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-0000000000ca', false);
SELECT t.expect('perm: cashier can sell, cannot reopen a day',
    app.has_permission('sale.create') AND NOT app.has_permission('day.reopen'));
SELECT t.expect_error('perm: require_permission denies', $$ SELECT app.require_permission('day.reopen') $$, 'PERMISSION_DENIED');
SELECT t.expect_error('perm: unknown key is an error, not a silent false', $$ SELECT app.require_permission('sale.creat') $$, 'UNKNOWN_PERMISSION');
INSERT INTO employee_permission_overrides (organization_id, employee_id, permission_key, granted) VALUES
  ('10000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-0000000000ca', 'sale.void', true),
  ('10000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-0000000000ca', 'sale.create', false);
SELECT t.expect('perm: overrides add and remove', app.has_permission('sale.void') AND NOT app.has_permission('sale.create'));
SELECT t.expect('perm: branch scope', app.has_branch_access('20000000-0000-0000-0000-00000000000a')
                                    AND NOT app.has_branch_access('20000000-0000-0000-0000-00000000000b'));
SELECT set_config('request.headers', '{"x-forwarded-for": "41.33.1.2, 10.0.0.1", "user-agent": "pos/1.0", "x-request-id": "req-1"}', false);
SELECT app.write_audit('sale.create', 'sale', 'a1000000-0000-0000-0000-00000000000a', NULL, '{"total": 10000}');
SELECT t.expect('audit: org, employee, ip from session',
    (SELECT organization_id = '10000000-0000-0000-0000-00000000000a' AND employee_id = '30000000-0000-0000-0000-0000000000ca'
            AND ip = '41.33.1.2'::inet AND request_id = 'req-1' FROM audit_log ORDER BY id DESC LIMIT 1));
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-00000000000a', false);
SELECT t.expect('perm: owner has everything', app.has_permission('day.reopen') AND app.has_permission('contract.write_off'));
UPDATE organizations SET status = 'suspended' WHERE id = '10000000-0000-0000-0000-00000000000a';
SELECT t.expect_error('perm: suspended org blocked', $$ SELECT app.require_permission('sale.create') $$, 'ORG_NOT_ACTIVE');
UPDATE organizations SET status = 'active' WHERE id = '10000000-0000-0000-0000-00000000000a';
SELECT set_config('request.jwt.claim.sub', '', false);

-- ---------------------------------------------------------------- RLS and grants as the API role
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT INSERT ON t.results TO authenticated;
GRANT EXECUTE ON FUNCTION t.expect(text, boolean, text), t.expect_error(text, text, text) TO authenticated;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-0000000000ca', false);
SELECT t.expect('rls: cashier A sees only shop A products', (SELECT count(*) = 2 FROM products));
SELECT t.expect('rls: cashier A sees only own org', (SELECT count(*) = 1 FROM organizations));
SELECT t.expect('rls: views respect RLS', (SELECT count(*) = 2 FROM v_contract_balances));
SELECT t.expect('rls: cashier reads employees of own shop only', (SELECT count(*) = 2 FROM employees));
SELECT t.expect_error('grant: national_id hidden', $$ SELECT national_id FROM customers $$, 'permission denied');
SELECT t.expect_error('grant: no direct inserts', $$
    INSERT INTO categories (organization_id, name) VALUES ('10000000-0000-0000-0000-00000000000a', 'Hack') $$, 'permission denied');
SELECT t.expect_error('grant: no direct updates', $$ UPDATE products SET cash_price = 1 $$, 'permission denied');
SELECT t.expect_error('grant: no helper calls', $$ SELECT app.next_document_number(NULL, NULL, 'sale') $$, 'permission denied');
SELECT t.expect_error('grant: jobs hidden', $$ SELECT * FROM jobs $$, 'permission denied');
SELECT t.expect('rls: cashier cannot read audit log without audit.view', (SELECT count(*) = 0 FROM audit_log));
SELECT t.expect_error('grant: ETA payload hidden', $$ SELECT payload FROM fiscal_submissions $$, 'permission denied');
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-00000000000a', false);
SELECT t.expect('rls: owner A reads audit log', (SELECT count(*) >= 1 FROM audit_log));
SELECT set_config('request.jwt.claim.sub', 'b0000000-0000-0000-0000-00000000000b', false);
SELECT t.expect('rls: owner B sees only shop B', (SELECT count(*) = 1 FROM products) AND (SELECT count(*) = 0 FROM contracts));
SELECT set_config('request.jwt.claim.sub', '', false);
SELECT t.expect('rls: no session sees nothing', (SELECT count(*) = 0 FROM products));
RESET ROLE;

SET ROLE anon;
SELECT 1 FROM pg_class LIMIT 1;
RESET ROLE;
SELECT t.expect('anon: no table access', NOT has_table_privilege('anon', 'public.products', 'SELECT'));

-- one login, two shops
INSERT INTO employees (organization_id, auth_user_id, full_name, role)
VALUES ('10000000-0000-0000-0000-00000000000b', 'a0000000-0000-0000-0000-00000000000a', 'Owner A as accountant in B', 'ACCOUNTANT');
SELECT set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-00000000000a', false);
SELECT set_config('request.headers', '{}', false);
SELECT t.expect('multi-shop: no shop chosen = no access', app.current_org_id() IS NULL);
SELECT set_config('request.headers', '{"x-org-id": "10000000-0000-0000-0000-00000000000b"}', false);
SELECT t.expect('multi-shop: header picks shop B, role there', app.current_org_id() = '10000000-0000-0000-0000-00000000000b' AND app.current_role() = 'ACCOUNTANT');
SELECT set_config('request.headers', '{"x-org-id": "10000000-0000-0000-0000-0000000000ff"}', false);
SELECT t.expect('multi-shop: unknown shop = no access', app.current_org_id() IS NULL);
SELECT set_config('request.headers', '', false);
SELECT set_config('request.jwt.claim.sub', '', false);

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
