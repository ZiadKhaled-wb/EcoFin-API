-- TEST-1 security guards (EC-128). LOCAL / DEV ONLY. Catalog checks only: no fixtures.
-- Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/security_guards_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
-- GENERIC: every check loops over the catalog, so a future migration is checked automatically.
--   1. anon has no privilege on any table, view or sequence in public
--   2. authenticated has no INSERT / UPDATE / DELETE / TRUNCATE on any table in public
--   3. every table with organization_id has RLS on and at least one SELECT policy
--   4. every SECURITY DEFINER function in public and app pins search_path = ''
--   5. every public function authenticated can EXECUTE calls app.require_permission
--   6. anon can EXECUTE nothing in public or app
-- Exceptions live in the two allowlists below, each with a one-line reason. An entry that no
-- longer matches anything fails too, so the lists can't go stale.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE SCHEMA t;
CREATE TABLE t.results (name text, ok boolean, detail text);

CREATE FUNCTION t.expect(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    INSERT INTO t.results VALUES (p_name, p_ok, p_detail);
$$;

-- ---------------------------------------------------------------- allowlists
-- 3. tables with organization_id that have RLS on but deliberately no SELECT policy (no app access).
CREATE TABLE t.no_select_policy_ok (table_name text PRIMARY KEY, reason text NOT NULL);
INSERT INTO t.no_select_policy_ok VALUES
  ('password_resets','O02: service-only pre-session reset tokens; no app table access'),
  ('jobs', 'platform job queue (D34): service role only; no policy = app users see nothing');

-- 5. public functions authenticated may EXECUTE without app.require_permission.
CREATE TABLE t.no_permission_ok (function_name text PRIMARY KEY, reason text NOT NULL);
INSERT INTO t.no_permission_ok VALUES
  ('resolve_device',              'O03: read-only lookup of the caller''s own shop device by token hash'),
  ('session_context',             'session helper: resolves the caller''s own shop/role, writes nothing'),
  ('my_shops',                    'session helper: lists the caller''s own shops (shop picker), writes nothing'),
  ('my_permissions',              'session helper: the caller''s own permission keys, writes nothing'),
  ('auth_record_login',           'login helper: audits the caller''s own login (any employee may log in)'),
  ('auth_record_logout',          'login helper: audits the caller''s own logout'),
  ('auth_record_password_change', 'login helper: audits the caller''s own password change'),
  ('admin_provision_organization', 'platform super admin; checks app.is_super_admin()'),
  ('admin_list_organizations', 'platform super admin; checks app.is_super_admin()'),
  ('admin_set_organization_status', 'platform super admin; checks app.is_super_admin()'),
  ('admin_resend_owner_invite', 'platform super admin; checks app.is_super_admin()'),
  ('admin_change_plan', 'platform super admin; checks app.is_super_admin()'),
  ('admin_set_subscription_dates', 'platform super admin; checks app.is_super_admin()'),
  ('admin_record_subscription_payment', 'platform super admin; checks app.is_super_admin()'),
  ('admin_get_subscription', 'platform super admin; checks app.is_super_admin()'),
  ('get_subscription_status', 'read-only status for the session''s own shop'),
  ('require_module', 'read-only module check for the session''s own shop'),
  ('get_shop_settings', 'P03: read-only settings of the session''s own shop; any employee (POS needs receipt, VAT, discount rules)'),
  ('list_installment_policies', 'P03: read-only; checks app.has_permission so an expired (read-only) shop can still read'),
  ('get_shop_profile', 'P04: read-only legal and financing profile of the session''s own shop; any employee'),
  ('list_tax_classes', 'T01: read-only tax classes of the session''s own shop; any employee (POS, product forms)'),
  ('list_categories', 'C01: read-only categories of the session''s own shop; any employee (catalog, POS, reports)'),
  ('list_products', 'C02: read-only catalog search of the session''s own shop; any employee (catalog screen, POS)'),
  ('get_product', 'C02: read-only product of the session''s own shop, archived included (old documents); any employee'),
  ('lookup_product', 'C02: read-only POS lookup by barcode or SKU, active products of the session''s own shop; any employee'),
  ('list_product_units', 'C03: read-only serials of a product''s units in the caller''s accessible branches (labels); any employee'),
  ('list_stock', 'I01: read-only stock view; checks app.has_permission(stock.view) so an expired (read-only) shop can still read'),
  ('list_stock_movements', 'I01: read-only movement drill-down; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('list_branch_min_levels', 'I06: read-only min levels of a product in the caller''s branches; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('low_stock_summary', 'I06: read-only dashboard low-stock card; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('list_stock_adjustments', 'I02: read-only adjustments list; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('get_stock_adjustment', 'I02: read-only adjustment with lines; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('list_stock_counts', 'I02: read-only counts list; checks app.has_permission(stock.count) so an expired shop can still read'),
  ('get_stock_count', 'I02: read-only count with its lines; checks app.has_permission(stock.count) so an expired shop can still read'),
  ('list_stock_transfers', 'I03: read-only transfers list; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('get_stock_transfer', 'I03: read-only transfer with its lines; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('list_transfer_destinations', 'I03: read-only names of the shop''s active branches; checks app.has_permission(stock.transfer_send)'),
  ('get_unit', 'I04: read-only unit with its history; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('find_unit', 'I04: read-only unit by exact serial; checks app.has_permission(stock.view) so an expired shop can still read'),
  ('search_units', 'I04: read-only serial search in the caller''s branches; checks app.has_permission(stock.view)'),
  ('list_suppliers', 'U01: read-only supplier list; checks app.has_permission on any purchasing read key (D53) so an expired shop can still read'),
  ('get_supplier', 'U01: read-only supplier, archived included; checks app.has_permission on any purchasing read key (D53)'),
  ('supplier_statement', 'U01: read-only supplier statement; checks app.has_permission on any purchasing read key (D53) so an expired shop can still read'),
  ('list_customers', 'R01: read-only customer list, national IDs masked without customer.view_pii; checks app.has_permission on any customer read key (D63) and the customers module, so an expired shop can still read'),
  ('get_customer', 'R01: read-only customer, national ID masked without customer.view_pii; checks app.has_permission on any customer read key (D63) and the customers module'),
  ('list_guarantors', 'R04: read-only guarantor list, national IDs masked without customer.view_pii; checks app.has_permission on any customer read key (D63) and the customers module, so an expired shop can still read'),
  ('get_guarantor', 'R04: read-only guarantor with their customers and contracts, national ID masked without customer.view_pii; any customer read key (D63) and the customers module'),
  ('list_customer_guarantors', 'R04: read-only guarantors of one customer, national IDs masked without customer.view_pii; any customer read key (D63) and the customers module'),
  ('get_guarantor_requirement', 'R04: read-only check of a customer against the current installment policy; any customer read key (D63) and the customers module'),
  ('get_customer_credit_profile', 'R03: read-only credit profile of a customer (limit, exposure, score, behaviour); checks app.customer_read_guard (any customer read key, D63) and the customers module, so an expired shop can still read'),
  ('get_customer_credit_check', 'R03: read-only preview of the installment credit check for a financed amount; any customer read key (D63) and the customers module'),
  ('get_credit_exception', 'R03: read-only credit exception (an approval of kind credit_exception); any customer read key (D63) and the customers module'),
  ('list_credit_exceptions', 'R03: read-only list of credit exceptions, pending first; any customer read key (D63) and the customers module, works in an expired shop'),
  ('get_customer_account', 'R02: read-only customer account (open balance, overdue, contracts, payments, returns); checks app.customer_read_guard (any customer read key, D63) and the customers module, so an expired shop can still read'),
  ('get_customer_contract_schedule', 'R02: read-only schedule of one contract of the customer; any customer read key (D63) and the customers module'),
  ('customer_statement', 'R02: read-only customer statement with a running balance for a date range; any customer read key (D63) and the customers module'),
  ('list_purchase_invoices', 'U02: read-only purchase invoices of the caller''s branches; any purchasing read key (D53), works in an expired shop'),
  ('get_purchase_invoice', 'U02: read-only purchase invoice of the caller''s branches; any purchasing read key (D53)'),
  ('list_purchase_approvals', 'U06: read-only purchase approvals of the caller''s branches; checks app.has_permission(purchase.invoice_approve) so an expired shop can still read'),
  ('quote_sale', 'S01: read-only price quote of a cart; checks app.has_permission(sale.create); works in an expired shop'),
  ('get_sale', 'S01: read-only sale; own sales with sale.create, the caller''s branches with report.view or cash.view'),
  ('list_sale_payment_accounts', 'S02: read-only names of the active banks the caller''s open shift can take a transfer into; checks app.has_permission(sale.create)'),
  ('get_discount_approval', 'S03: read-only approval; checks app.has_permission(sale.create or discount.above_cap), then only the requester''s own or a branch the caller can access with discount.above_cap'),
  ('list_expense_categories', 'K03: read-only expense categories; checks app.has_permission(expense.create, cash.view or report.financial)'),
  ('list_expenses', 'K03: read-only expenses of the caller''s branches; same three keys; works in an expired shop'),
  ('get_expense', 'K03: read-only expense of the caller''s branches; same three keys'),
  ('expense_report', 'K03: read-only totals per category of the caller''s branches; same three keys'),
  ('get_current_shift', 'K02: read-only, the caller''s open shift; checks app.has_permission(shift.operate or cash.view)'),
  ('get_shift', 'K02: read-only shift, the caller''s own or (cash.view) of the caller''s branches'),
  ('list_shifts', 'K02: read-only shifts, the caller''s own or (cash.view) of the caller''s branches; works in an expired shop'),
  ('list_shift_vaults', 'K02: read-only names of the branch''s active safes; checks app.has_permission(shift.operate or cash.view)'),
  ('list_purchase_orders', 'U05: read-only purchase orders of the caller''s branches; any purchasing read key (D53), works in an expired shop'),
  ('get_purchase_order', 'U05: read-only purchase order of the caller''s branches; any purchasing read key (D53)'),
  ('list_supplier_payments', 'U03: read-only supplier payments of the caller''s branches; any purchasing read key (D53), works in an expired shop'),
  ('get_supplier_payment', 'U03: read-only supplier payment of the caller''s branches; any purchasing read key (D53)'),
  ('list_open_supplier_invoices', 'U03: read-only open invoices of a supplier; checks app.has_permission(supplier.payment_create)'),
  ('list_purchase_returns', 'U04: read-only purchase returns of the caller''s branches; any purchasing read key (D53), works in an expired shop'),
  ('get_purchase_return', 'U04: read-only purchase return of the caller''s branches; any purchasing read key (D53)'),
  ('get_returnable_invoice', 'U04: read-only returnable lines of an invoice; checks app.has_permission(purchase.return_create)'),
  ('list_payable_cash_accounts', 'U04: read-only safes and banks usable for a branch; checks app.has_permission(purchase.return_create or supplier.payment_create)'),
  ('list_cash_accounts', 'K01: read-only safes and banks the caller may see; checks app.has_permission(cash.view) so an expired shop can still read'),
  ('get_cash_account', 'K01: read-only safe or bank; checks app.has_permission(cash.view) so an expired shop can still read'),
  ('list_cash_account_movements', 'K01: read-only ledger of a safe or bank with running balance; checks app.has_permission(cash.view)'),
  ('list_cash_transfers', 'K01: read-only cash transfers with a visible side; checks app.has_permission(cash.view) so an expired shop can still read'),
  ('get_cash_transfer', 'K01: read-only cash transfer with a visible side; checks app.has_permission(cash.view)'),
  ('fiscal_list', 'T03: read-only, checks fiscal.view (app.require_fiscal_view); branch-scoped; works in an expired shop'),
  ('fiscal_details', 'T03: read-only, checks fiscal.view (app.require_fiscal_view); branch-scoped; no payload, no national ID'),
  ('fiscal_diagnose', 'T03: read-only, checks fiscal.view (app.require_fiscal_view); branch-scoped; no national ID'),
  ('fiscal_alert_summary', 'T03: read-only, checks fiscal.view (app.require_fiscal_view); counts of the caller''s branches'),
  ('fiscal_day_summary', 'T03: read-only, checks fiscal.view (app.require_fiscal_view) and branch access; for the day close');

-- ---------------------------------------------------------------- catalog helpers (plpgsql, so a
-- privilege function never runs on rows of another kind or schema before the filter)
CREATE FUNCTION t.public_relations() RETURNS TABLE (rel oid, name text, kind "char") LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY SELECT c.oid, c.relname::text, c.relkind FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
    ORDER BY c.relname;
END $$;

CREATE FUNCTION t.anon_privileged_relations() RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE r record; v_out text := '';
BEGIN
    FOR r IN SELECT * FROM t.public_relations() LOOP
        IF r.kind = 'S' THEN
            IF has_sequence_privilege('anon', r.rel, 'USAGE,SELECT,UPDATE') THEN v_out := v_out || r.name || ' '; END IF;
        ELSIF has_table_privilege('anon', r.rel, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
           OR has_any_column_privilege('anon', r.rel, 'SELECT,INSERT,UPDATE,REFERENCES') THEN
            v_out := v_out || r.name || ' ';
        END IF;
    END LOOP;
    RETURN v_out;
END $$;

CREATE FUNCTION t.authenticated_writable_tables() RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE r record; v_out text := '';
BEGIN
    FOR r IN SELECT * FROM t.public_relations() WHERE kind IN ('r', 'p') LOOP
        IF has_table_privilege('authenticated', r.rel, 'INSERT,UPDATE,DELETE,TRUNCATE')
           OR has_any_column_privilege('authenticated', r.rel, 'INSERT,UPDATE') THEN
            v_out := v_out || r.name || ' ';
        END IF;
    END LOOP;
    RETURN v_out;
END $$;

-- Functions in public/app that belong to us (not to an extension).
CREATE FUNCTION t.own_functions() RETURNS TABLE (fn oid, schema_name text, name text, sig text, secdef boolean, config text[], body text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT p.oid, n.nspname::text, p.proname::text, format('%s.%s(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)),
           p.prosecdef, p.proconfig, p.prosrc
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'app') AND p.prokind IN ('f', 'p')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
    ORDER BY 2, 3;
END $$;

CREATE FUNCTION t.functions_executable_by(p_role text, p_schema text) RETURNS TABLE (name text, sig text, body text)
LANGUAGE plpgsql STABLE AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM t.own_functions() f WHERE p_schema IS NULL OR f.schema_name = p_schema LOOP
        IF has_function_privilege(p_role, r.fn, 'EXECUTE') THEN
            name := r.name; sig := r.sig; body := r.body; RETURN NEXT;
        END IF;
    END LOOP;
END $$;

-- ---------------------------------------------------------------- 1. anon: no privilege on any relation
SELECT t.expect('1.1 there are relations to check (tables, views, sequences)',
    (SELECT count(*) FROM t.public_relations()) >= 50, (SELECT count(*)::text FROM t.public_relations()));
SELECT t.expect('1.2 anon has no privilege on any table, view or sequence in public',
    t.anon_privileged_relations() = '', t.anon_privileged_relations());

-- ---------------------------------------------------------------- 2. authenticated: no table writes
SELECT t.expect('2.1 authenticated has no INSERT/UPDATE/DELETE/TRUNCATE on any table in public',
    t.authenticated_writable_tables() = '', t.authenticated_writable_tables());

-- ---------------------------------------------------------------- 3. RLS on every tenant table
CREATE TABLE t.tenant_tables AS
SELECT c.relname::text AS name, c.relrowsecurity AS rls,
       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid AND p.polcmd IN ('r', '*')) AS select_policies
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'organization_id' AND NOT a.attisdropped
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p');

SELECT t.expect('3.1 there are tenant tables to check', (SELECT count(*) FROM t.tenant_tables) >= 20,
    (SELECT count(*)::text FROM t.tenant_tables));
SELECT t.expect('3.2 every table with organization_id has RLS enabled',
    NOT EXISTS (SELECT 1 FROM t.tenant_tables WHERE NOT rls),
    (SELECT string_agg(name, ', ') FROM t.tenant_tables WHERE NOT rls));
SELECT t.expect('3.3 every table with organization_id has a SELECT policy (or is allowlisted)',
    NOT EXISTS (SELECT 1 FROM t.tenant_tables tt WHERE tt.select_policies = 0
                AND tt.name NOT IN (SELECT table_name FROM t.no_select_policy_ok)),
    (SELECT string_agg(name, ', ') FROM t.tenant_tables tt WHERE tt.select_policies = 0
     AND tt.name NOT IN (SELECT table_name FROM t.no_select_policy_ok)));
SELECT t.expect('3.4 every no-policy allowlist entry is a tenant table with RLS on and still no policy',
    NOT EXISTS (SELECT 1 FROM t.no_select_policy_ok o
                WHERE NOT EXISTS (SELECT 1 FROM t.tenant_tables tt
                                  WHERE tt.name = o.table_name AND tt.rls AND tt.select_policies = 0)),
    (SELECT string_agg(table_name, ', ') FROM t.no_select_policy_ok o
     WHERE NOT EXISTS (SELECT 1 FROM t.tenant_tables tt WHERE tt.name = o.table_name AND tt.rls AND tt.select_policies = 0)));

-- ---------------------------------------------------------------- 4. definer functions pin search_path
SELECT t.expect('4.1 there are SECURITY DEFINER functions to check',
    (SELECT count(*) FROM t.own_functions() WHERE secdef) >= 20);
SELECT t.expect('4.2 every SECURITY DEFINER function in public and app has SET search_path = ''''',
    NOT EXISTS (SELECT 1 FROM t.own_functions() WHERE secdef AND NOT coalesce(config @> ARRAY['search_path=""'], false)),
    (SELECT string_agg(sig, ', ') FROM t.own_functions()
     WHERE secdef AND NOT coalesce(config @> ARRAY['search_path=""'], false)));

-- ---------------------------------------------------------------- 5. callable = permission-checked
CREATE TABLE t.callable AS SELECT * FROM t.functions_executable_by('authenticated', 'public');
SELECT t.expect('5.1 authenticated can execute some public functions (the check is not empty)',
    (SELECT count(*) FROM t.callable) >= 3, (SELECT string_agg(name, ', ') FROM t.callable));
SELECT t.expect('5.2 every public function authenticated can execute calls app.require_permission (or is allowlisted)',
    NOT EXISTS (SELECT 1 FROM t.callable c WHERE c.body !~* 'app\.require_permission\s*\('
                AND c.name NOT IN (SELECT function_name FROM t.no_permission_ok)),
    (SELECT string_agg(sig, ', ') FROM t.callable c WHERE c.body !~* 'app\.require_permission\s*\('
     AND c.name NOT IN (SELECT function_name FROM t.no_permission_ok)));
SELECT t.expect('5.3 every permission allowlist entry is still a public function authenticated can execute',
    NOT EXISTS (SELECT 1 FROM t.no_permission_ok o WHERE o.function_name NOT IN (SELECT name FROM t.callable)),
    (SELECT string_agg(function_name, ', ') FROM t.no_permission_ok o WHERE o.function_name NOT IN (SELECT name FROM t.callable)));

-- ---------------------------------------------------------------- 6. anon executes nothing
SELECT t.expect('6.1 anon can execute no function in public',
    NOT EXISTS (SELECT 1 FROM t.functions_executable_by('anon', 'public')),
    (SELECT string_agg(sig, ', ') FROM t.functions_executable_by('anon', 'public')));
SELECT t.expect('6.2 anon can execute no function in app',
    NOT EXISTS (SELECT 1 FROM t.functions_executable_by('anon', 'app')),
    (SELECT string_agg(sig, ', ') FROM t.functions_executable_by('anon', 'app')));

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
