-- TEST-1 cross-tenant and permission tests (EC-128). LOCAL / DEV ONLY.
-- Run after `npm run db:reset` (needs the dev seed shops):
--   npm run db:smoke -- supabase/tests/tenant_and_permission_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
--   1. setup: the two dev seed shops (A = dev-shop-one, B = dev-shop-two) get the same rows in as
--      many tenant tables as plain inserts can fill (count reported in 1.1)
--   2. cross-tenant read (GENERIC): acting as A, then as B, every public table AND view with
--      organization_id shows zero rows of another shop; also when the header aims at the other shop
--   3. cross-tenant write: every write function that takes a record id, called by A with B's id,
--      fails and changes nothing
--   4. permission denial (GENERIC): every public function authenticated can execute (except the
--      session helpers allowlisted in security_guards_test.sql) has a denial case here; a role
--      without the permission gets PERMISSION_DENIED. A new function without a case fails 4.0.
-- Known bugs are recorded with t.known_bug(): they PASS while the bug is still there and FAIL once
-- it is fixed, so the marker is removed then (like vitest's .fails).
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE SCHEMA t;
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

-- A known bug: the check is expected to FAIL today. Recorded as a pass while it still fails; once
-- the app is fixed the check passes and this row fails, telling you to remove the marker.
CREATE FUNCTION t.known_bug(p_name text, p_ok boolean, p_bug text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO t.results VALUES ('KNOWN BUG ' || p_name, NOT p_ok,
        CASE WHEN p_ok THEN 'fixed now: turn this known_bug() back into expect()' ELSE p_bug END);
$$;

CREATE FUNCTION t.as_user(p_sub text, p_org text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.sub', COALESCE(p_sub, ''), false),
           set_config('request.headers',
                      CASE WHEN p_org IS NULL THEN '{}' ELSE json_build_object('x-org-id', p_org)::text END,
                      false);
$$;

-- Runs p_sql, returns the error text ('' when it worked). For "fails AND changes nothing" checks.
CREATE FUNCTION t.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN '';
EXCEPTION WHEN others THEN
    RETURN SQLERRM;
END $$;

GRANT USAGE ON SCHEMA t TO authenticated;
GRANT INSERT ON t.results TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- ---------------------------------------------------------------- 1. setup (dev seed shops)
--   A d1000000-...-01: owner auth d0..11 / emp d3..11, cashier auth d0..12 / emp d3..12, branch d2..11
--   B d1000000-...-02: owner auth d0..21 / emp d3..21, cashier auth d0..22 / emp d3..22, branch d2..21
CREATE TABLE t.shop (tag text PRIMARY KEY, org uuid, branch uuid, owner_sub text, owner_emp uuid, cashier_sub text, cashier_emp uuid);
INSERT INTO t.shop VALUES
  ('a', 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000011',
        'd0000000-0000-0000-0000-000000000011', 'd3000000-0000-0000-0000-000000000011',
        'd0000000-0000-0000-0000-000000000012', 'd3000000-0000-0000-0000-000000000012'),
  ('b', 'd1000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000021',
        'd0000000-0000-0000-0000-000000000021', 'd3000000-0000-0000-0000-000000000021',
        'd0000000-0000-0000-0000-000000000022', 'd3000000-0000-0000-0000-000000000022');
SELECT t.expect('1.0 the dev seed shops are there (run after db reset)',
    (SELECT count(*) FROM public.organizations WHERE id IN (SELECT org FROM t.shop)) = 2
    AND (SELECT count(*) FROM public.employees WHERE id IN (SELECT owner_emp FROM t.shop UNION SELECT cashier_emp FROM t.shop)) = 4);

-- Fixed ids per shop: e1<nn>0000-...-00000000000<tag>, so tests can name B's rows.
CREATE FUNCTION t.id(p_kind text, p_tag text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT ('e1' || p_kind || '0000-0000-0000-0000-00000000000' || CASE p_tag WHEN 'a' THEN 'a' ELSE 'b' END)::uuid
$$;

CREATE FUNCTION t.fill(p_tag text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    s t.shop;
    up text := upper(p_tag);
BEGIN
    SELECT * INTO s FROM t.shop WHERE tag = p_tag;
    INSERT INTO public.tax_classes (id, organization_id, name, rate) VALUES (t.id('01', p_tag), s.org, 'VAT 14', 14);
    INSERT INTO public.categories (id, organization_id, name) VALUES (t.id('02', p_tag), s.org, 'Cat ' || up);
    INSERT INTO public.products (id, organization_id, name_ar, sku, cash_price, tax_class_id, is_serialized)
    VALUES (t.id('03', p_tag), s.org, 'Sofa ' || up, 'T1-' || up, 100, t.id('01', p_tag), false);
    INSERT INTO public.customers (id, organization_id, full_name) VALUES (t.id('04', p_tag), s.org, 'Customer ' || up);
    INSERT INTO public.suppliers (id, organization_id, name) VALUES (t.id('05', p_tag), s.org, 'Supplier ' || up);
    INSERT INTO public.guarantors (id, organization_id, full_name) VALUES (t.id('06', p_tag), s.org, 'Guarantor ' || up);
    INSERT INTO public.customer_guarantors (organization_id, customer_id, guarantor_id) VALUES (s.org, t.id('04', p_tag), t.id('06', p_tag));
    INSERT INTO public.cash_accounts (id, organization_id, branch_id, name, kind) VALUES (t.id('07', p_tag), s.org, s.branch, 'Drawer ' || up, 'drawer');
    INSERT INTO public.expense_categories (id, organization_id, name) VALUES (t.id('08', p_tag), s.org, 'Rent ' || up);
    INSERT INTO public.devices (id, organization_id, branch_id, name) VALUES (t.id('09', p_tag), s.org, s.branch, 'POS ' || up);
    INSERT INTO public.employee_permission_overrides (organization_id, employee_id, permission_key, granted)
    VALUES (s.org, s.cashier_emp, 'stock.view', true)
    ON CONFLICT DO NOTHING;
    -- ledgers (their triggers fill stock_levels, cash_balances and store_credit_balances)
    INSERT INTO public.stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
    VALUES (s.org, t.id('03', p_tag), s.branch, 10, 'purchase_in', 'purchase_invoice', gen_random_uuid());
    INSERT INTO public.cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
    VALUES (s.org, t.id('07', p_tag), 500, 'sale', 'sale', gen_random_uuid());
    INSERT INTO public.store_credit_movements (organization_id, customer_id, branch_id, amount, source_type, source_id)
    VALUES (s.org, t.id('04', p_tag), s.branch, 50, 'sales_return', gen_random_uuid());
    -- documents
    INSERT INTO public.sales (id, organization_id, number, branch_id, customer_id, prices_include_vat, subtotal, total, idempotency_key)
    VALUES (t.id('10', p_tag), s.org, 'BR1-SL-26-9000' || CASE p_tag WHEN 'a' THEN '01' ELSE '02' END, s.branch,
            t.id('04', p_tag), true, 100, 100, 'test1-sale-' || p_tag);
    INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, quantity, unit_price, tax_class_id, tax_rate, line_total)
    VALUES (s.org, t.id('10', p_tag), 1, t.id('03', p_tag), 1, 100, t.id('01', p_tag), 14, 100);
    INSERT INTO public.payments (id, organization_id, number, branch_id, direction, method, amount, customer_id, cash_account_id, idempotency_key)
    VALUES (t.id('11', p_tag), s.org, 'BR1-PY-26-9000' || CASE p_tag WHEN 'a' THEN '01' ELSE '02' END, s.branch,
            'in', 'cash', 100, t.id('04', p_tag), t.id('07', p_tag), 'test1-pay-' || p_tag);
    INSERT INTO public.payment_allocations (organization_id, payment_id, amount, sale_id) VALUES (s.org, t.id('11', p_tag), 100, t.id('10', p_tag));
    INSERT INTO public.quotations (id, organization_id, number, branch_id, idempotency_key)
    VALUES (t.id('12', p_tag), s.org, 'BR1-QT-26-9000' || CASE p_tag WHEN 'a' THEN '01' ELSE '02' END, s.branch, 'test1-quote-' || p_tag);
    INSERT INTO public.files (id, organization_id, path, mime, size_bytes, purpose, entity_type, entity_id)
    VALUES (t.id('13', p_tag), s.org, s.org || '/customer_id/2026/10/' || t.id('13', p_tag) || '.png', 'image/png', 10,
            'customer_id', 'customer', t.id('04', p_tag));
    PERFORM app.write_audit('test1.fixture', 'customer', t.id('04', p_tag), NULL, NULL, NULL, NULL, 'info', s.org);
END $$;

SELECT t.fill('a');
SELECT t.fill('b');

-- Every public table AND view with organization_id (by OID; plpgsql so privilege checks only run
-- on these rows).
CREATE FUNCTION t.tenant_relations() RETURNS TABLE (rel regclass, name text, kind "char") LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT c.oid::regclass, c.relname::text, c.relkind
    FROM pg_class c
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'organization_id' AND NOT a.attisdropped
    WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm')
    ORDER BY c.relname;
END $$;

-- As postgres: how many tenant tables / views hold a row of each shop.
CREATE TABLE t.coverage AS
SELECT 0::int AS tables_with_b, 0::int AS relations_with_b, 0::int AS total WHERE false;
DO $$
DECLARE r record; v integer; v_t integer := 0; v_r integer := 0; v_total integer := 0;
BEGIN
    FOR r IN SELECT * FROM t.tenant_relations() LOOP
        v_total := v_total + 1;
        EXECUTE format('SELECT count(*) FROM %s WHERE organization_id = %L', r.rel, 'd1000000-0000-0000-0000-000000000002') INTO v;
        IF v > 0 THEN
            v_r := v_r + 1;
            IF r.kind IN ('r', 'p') THEN v_t := v_t + 1; END IF;
        END IF;
    END LOOP;
    INSERT INTO t.coverage VALUES (v_t, v_r, v_total);
END $$;
SELECT t.expect('1.1 shop B has rows in at least 25 tenant tables and views (reported: with rows / all)',
    (SELECT relations_with_b FROM t.coverage) >= 25,
    (SELECT format('%s tables, %s tables+views of %s', tables_with_b, relations_with_b, total) FROM t.coverage));

-- ---------------------------------------------------------------- 2. cross-tenant read (generic)
-- Counts rows of any other shop in every readable tenant table and view, as the current session.
CREATE FUNCTION t.foreign_rows(p_own uuid) RETURNS TABLE (checked integer, own_rows integer, leaks text) LANGUAGE plpgsql AS $$
DECLARE r record; v integer; v_own integer;
BEGIN
    checked := 0; own_rows := 0; leaks := '';
    FOR r IN SELECT * FROM t.tenant_relations() LOOP
        CONTINUE WHEN NOT has_column_privilege(r.rel, 'organization_id', 'SELECT');
        EXECUTE format('SELECT count(*) FILTER (WHERE organization_id IS DISTINCT FROM %L), count(*) FILTER (WHERE organization_id = %L) FROM %s',
                       p_own, p_own, r.rel) INTO v, v_own;
        checked := checked + 1;
        own_rows := own_rows + v_own;
        IF v > 0 THEN leaks := leaks || r.name || '=' || v || ' '; END IF;
    END LOOP;
    RETURN NEXT;
END $$;

CREATE FUNCTION t.read_check(p_label text, p_tag text, p_header_tag text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s t.shop; h t.shop; r record;
BEGIN
    SELECT * INTO s FROM t.shop WHERE tag = p_tag;
    SELECT * INTO h FROM t.shop WHERE tag = p_header_tag;
    PERFORM t.as_user(s.owner_sub, h.org::text);
    SET LOCAL ROLE authenticated;
    SELECT * INTO r FROM t.foreign_rows(s.org);
    RESET ROLE;
    PERFORM t.as_user(NULL);
    IF p_tag = p_header_tag THEN
        PERFORM t.expect(p_label || ': zero rows of another shop in every readable tenant table and view',
            r.leaks = '' AND r.checked >= 60, format('checked %s, leaks: %s', r.checked, r.leaks));
        PERFORM t.expect(p_label || ': and the own shop''s rows are visible (the loop is not vacuous)',
            r.own_rows >= 20, format('own rows seen: %s', r.own_rows));
    ELSE
        PERFORM t.expect(p_label || ': aimed at the other shop, still zero foreign rows anywhere',
            r.leaks = '' AND r.checked >= 60, format('checked %s, leaks: %s', r.checked, r.leaks));
    END IF;
END $$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

SELECT t.read_check('2.1 owner A', 'a', 'a');
SELECT t.read_check('2.2 owner B', 'b', 'b');
SELECT t.read_check('2.3 owner A with x-org-id = B', 'a', 'b');
SELECT t.read_check('2.4 owner B with x-org-id = A', 'b', 'a');

-- ---------------------------------------------------------------- 3. cross-tenant write
-- Owner A holds every permission, so only the shop check can stop these calls.
CREATE TABLE t.w (name text PRIMARY KEY, err text);
GRANT INSERT, SELECT ON t.w TO authenticated;

SELECT t.as_user('d0000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001');
SET ROLE authenticated;
INSERT INTO t.w VALUES ('perm_b_emp', t.try($$SELECT public.set_employee_permission(
    'd3000000-0000-0000-0000-000000000022', 'sale.void', true, 'TEST-1 cross-shop')$$));
INSERT INTO t.w VALUES ('branches_b_emp', t.try($$SELECT public.set_employee_branches(
    'd3000000-0000-0000-0000-000000000022', ARRAY['d2000000-0000-0000-0000-000000000021']::uuid[], 'TEST-1 cross-shop')$$));
INSERT INTO t.w VALUES ('branches_b_branch', t.try($$SELECT public.set_employee_branches(
    'd3000000-0000-0000-0000-000000000012', ARRAY['d2000000-0000-0000-0000-000000000021']::uuid[], 'TEST-1 cross-shop')$$));
INSERT INTO t.w VALUES ('file_b_path', t.try($$SELECT public.register_file(
    'e1990000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002/logo/2026/10/x.png', 'x.png',
    'image/png', 10, NULL, 'logo', NULL, NULL)$$));
INSERT INTO t.w VALUES ('file_b_id', t.try($$SELECT public.register_file(
    'e1130000-0000-0000-0000-00000000000b', 'd1000000-0000-0000-0000-000000000001/logo/2026/10/y.png', 'y.png',
    'image/png', 10, NULL, 'logo', NULL, NULL)$$));
INSERT INTO t.w VALUES ('file_b_entity', t.try($$SELECT public.register_file(
    'e1990000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001/customer_id/2026/10/z.png', 'z.png',
    'image/png', 10, NULL, 'customer_id', 'customer', 'e1040000-0000-0000-0000-00000000000b')$$));
INSERT INTO t.w VALUES ('active_b_emp', t.try($$SELECT public.set_employee_active(
    'd3000000-0000-0000-0000-000000000022', false, 'TEST-1 cross-shop')$$));
-- EC-142: the other entity rules, and the own shop's customer still works.
INSERT INTO t.w VALUES ('file_bad_type', t.try($$SELECT public.register_file(
    'e1990000-0000-0000-0000-000000000003', 'd1000000-0000-0000-0000-000000000001/other/2026/10/t.png', 't.png',
    'image/png', 10, NULL, 'other', 'branch', 'd2000000-0000-0000-0000-000000000011')$$));
INSERT INTO t.w VALUES ('file_id_no_type', t.try($$SELECT public.register_file(
    'e1990000-0000-0000-0000-000000000004', 'd1000000-0000-0000-0000-000000000001/other/2026/10/u.png', 'u.png',
    'image/png', 10, NULL, 'other', NULL, 'e1040000-0000-0000-0000-00000000000a')$$));
INSERT INTO t.w VALUES ('file_own_entity', t.try($$SELECT public.register_file(
    'e1990000-0000-0000-0000-000000000005', 'd1000000-0000-0000-0000-000000000001/customer_id/2026/10/v.png', 'v.png',
    'image/png', 10, NULL, 'customer_id', 'customer', 'e1040000-0000-0000-0000-00000000000a')$$));
RESET ROLE;
SELECT t.as_user(NULL);

SELECT t.expect('3.1 set_employee_permission on a shop B employee fails and writes no override',
    (SELECT err FROM t.w WHERE name = 'perm_b_emp') <> ''
    AND NOT EXISTS (SELECT 1 FROM employee_permission_overrides
                    WHERE employee_id = 'd3000000-0000-0000-0000-000000000022' AND permission_key = 'sale.void'),
    (SELECT err FROM t.w WHERE name = 'perm_b_emp'));
SELECT t.expect('3.2 set_employee_branches on a shop B employee fails and changes nothing',
    (SELECT err FROM t.w WHERE name = 'branches_b_emp') <> ''
    AND (SELECT array_agg(branch_id) FROM employee_branches WHERE employee_id = 'd3000000-0000-0000-0000-000000000022')
        = ARRAY['d2000000-0000-0000-0000-000000000021']::uuid[],
    (SELECT err FROM t.w WHERE name = 'branches_b_emp'));
SELECT t.expect('3.3 set_employee_branches giving an own employee a shop B branch fails and changes nothing',
    (SELECT err FROM t.w WHERE name = 'branches_b_branch') <> ''
    AND (SELECT array_agg(branch_id) FROM employee_branches WHERE employee_id = 'd3000000-0000-0000-0000-000000000012')
        = ARRAY['d2000000-0000-0000-0000-000000000011']::uuid[],
    (SELECT err FROM t.w WHERE name = 'branches_b_branch'));
SELECT t.expect('3.4 register_file with a path in shop B''s folder fails and writes no row',
    (SELECT err FROM t.w WHERE name = 'file_b_path') ~ 'FILE_PATH_INVALID'
    AND NOT EXISTS (SELECT 1 FROM files WHERE id = 'e1990000-0000-0000-0000-000000000001'),
    (SELECT err FROM t.w WHERE name = 'file_b_path'));
SELECT t.expect('3.5 register_file reusing shop B''s file id fails and leaves B''s file as it was',
    (SELECT err FROM t.w WHERE name = 'file_b_id') <> ''
    AND (SELECT organization_id = 'd1000000-0000-0000-0000-000000000002' AND path LIKE 'd1000000-0000-0000-0000-000000000002/%'
         FROM files WHERE id = 'e1130000-0000-0000-0000-00000000000b'),
    (SELECT err FROM t.w WHERE name = 'file_b_id'));
-- 3.6 was a known bug until EC-142 (register_file didn't check the entity's shop).
SELECT t.expect('3.6 register_file pointing at a shop B customer (entity_id) fails with NOT_FOUND and writes no row',
    (SELECT err FROM t.w WHERE name = 'file_b_entity') ~ 'NOT_FOUND'
    AND NOT EXISTS (SELECT 1 FROM files WHERE id = 'e1990000-0000-0000-0000-000000000002'),
    (SELECT err FROM t.w WHERE name = 'file_b_entity'));
SELECT t.expect('3.7 register_file with an unknown entity type fails (VALIDATION_FAILED) and writes no row',
    (SELECT err FROM t.w WHERE name = 'file_bad_type') ~ 'VALIDATION_FAILED'
    AND NOT EXISTS (SELECT 1 FROM files WHERE id = 'e1990000-0000-0000-0000-000000000003'),
    (SELECT err FROM t.w WHERE name = 'file_bad_type'));
SELECT t.expect('3.8 register_file with an entity id but no entity type fails (VALIDATION_FAILED) and writes no row',
    (SELECT err FROM t.w WHERE name = 'file_id_no_type') ~ 'VALIDATION_FAILED'
    AND NOT EXISTS (SELECT 1 FROM files WHERE id = 'e1990000-0000-0000-0000-000000000004'),
    (SELECT err FROM t.w WHERE name = 'file_id_no_type'));
SELECT t.expect('3.9 register_file pointing at the own shop''s customer still works',
    (SELECT err FROM t.w WHERE name = 'file_own_entity') = ''
    AND EXISTS (SELECT 1 FROM files WHERE id = 'e1990000-0000-0000-0000-000000000005'
                AND entity_id = 'e1040000-0000-0000-0000-00000000000a'),
    (SELECT err FROM t.w WHERE name = 'file_own_entity'));

SELECT t.expect('3.10 set_employee_active on a shop B employee fails (NOT_FOUND) and B''s employee stays active',
    (SELECT err FROM t.w WHERE name = 'active_b_emp') ~ 'NOT_FOUND'
    AND (SELECT is_active FROM employees WHERE id = 'd3000000-0000-0000-0000-000000000022'),
    (SELECT err FROM t.w WHERE name = 'active_b_emp'));

-- ---------------------------------------------------------------- 4. permission denial (generic)
-- One employee per non-owner role in shop A, so every permission key has a role without it.
CREATE TABLE t.role_user (role public.employee_role PRIMARY KEY, sub uuid, emp uuid);
INSERT INTO t.role_user
SELECT r, ('e1f0' || lpad(ord::text, 4, '0') || '-0000-0000-0000-000000000001')::uuid,
          ('e1f1' || lpad(ord::text, 4, '0') || '-0000-0000-0000-000000000001')::uuid
FROM unnest(enum_range(NULL::public.employee_role)) WITH ORDINALITY AS e(r, ord) WHERE r <> 'OWNER';
INSERT INTO auth.users (id, email) SELECT sub, lower(role::text) || '.test1@x' FROM t.role_user;
INSERT INTO public.employees (id, organization_id, auth_user_id, full_name, role, default_branch_id)
SELECT emp, 'd1000000-0000-0000-0000-000000000001', sub, 'TEST-1 ' || role, role, 'd2000000-0000-0000-0000-000000000011' FROM t.role_user;
INSERT INTO public.employee_branches (organization_id, employee_id, branch_id)
SELECT 'd1000000-0000-0000-0000-000000000001', emp, 'd2000000-0000-0000-0000-000000000011' FROM t.role_user;

-- A role (not OWNER) whose defaults lack p_key.
CREATE FUNCTION t.role_without(p_key text) RETURNS public.employee_role LANGUAGE sql STABLE AS $$
    SELECT ru.role FROM t.role_user ru
    WHERE NOT EXISTS (SELECT 1 FROM public.role_permissions rp WHERE rp.role = ru.role AND rp.permission_key = p_key)
    ORDER BY ru.role LIMIT 1
$$;

-- The denial cases: function, case name, the key it needs, the call (valid arguments).
CREATE TABLE t.denial (fn text, case_name text, key text, call text);
INSERT INTO t.denial VALUES
  ('set_employee_permission', 'set_employee_permission', 'employee.manage',
   $$SELECT public.set_employee_permission('d3000000-0000-0000-0000-000000000019', 'sale.void', true, 'TEST-1 denial')$$),
  ('set_employee_branches', 'set_employee_branches', 'employee.manage',
   $$SELECT public.set_employee_branches('d3000000-0000-0000-0000-000000000019', ARRAY['d2000000-0000-0000-0000-000000000011']::uuid[], 'TEST-1 denial')$$);
-- register_file: one case per purpose, with the key the function's own CASE asks for.
INSERT INTO t.denial
SELECT 'register_file', 'register_file(' || p || ')', k,
       format($f$SELECT public.register_file(gen_random_uuid(), 'd1000000-0000-0000-0000-000000000001/%s/2026/10/' || gen_random_uuid() || '.png', 'd.png', 'image/png', 10, NULL, %L, NULL, NULL)$f$, p, p)
FROM (VALUES ('logo', 'org.settings_manage'), ('product_image', 'catalog.manage'), ('customer_id', 'customer.edit'),
             ('survey_photo', 'survey.submit'), ('signature', 'installment.create'), ('contract_pdf', 'installment.create'),
             ('promissory_note', 'installment.create'), ('delivery_proof', 'delivery.manage'), ('expense_receipt', 'expense.create'),
             ('legal_document', 'legal.manage'), ('import', 'import.data'), ('export', 'export.data'), ('other', 'org.settings_manage')) v(p, k);

-- The functions that need a case: callable by authenticated, minus the session helpers.
-- P01 platform functions require a super admin rather than a tenant permission.
INSERT INTO t.denial VALUES
  ('admin_list_organizations','admin_list_organizations','org.settings_manage',
   $$SELECT public.admin_list_organizations(NULL,NULL,10,0)$$),
  ('admin_provision_organization','admin_provision_organization','org.settings_manage',
   $$SELECT public.admin_provision_organization('Denied','test1-denied','starter','Owner','denied@example.com',NULL,'Main',repeat('a',64),now()+interval '1 day')$$),
  ('admin_set_organization_status','admin_set_organization_status','org.settings_manage',
   $$SELECT public.admin_set_organization_status('d1000000-0000-0000-0000-000000000001','suspended','denial')$$),
  ('admin_resend_owner_invite','admin_resend_owner_invite','org.settings_manage',
   $$SELECT public.admin_resend_owner_invite('d1000000-0000-0000-0000-000000000001',repeat('b',64),now()+interval '1 day')$$);
-- P05 platform operations use SUPER_ADMIN_REQUIRED; read-only functions are excluded below.
INSERT INTO t.denial VALUES
 ('admin_change_plan','admin_change_plan','org.settings_manage',$$SELECT public.admin_change_plan('d1000000-0000-0000-0000-000000000001','retail','denial')$$),
 ('admin_set_subscription_dates','admin_set_subscription_dates','org.settings_manage',$$SELECT public.admin_set_subscription_dates('d1000000-0000-0000-0000-000000000001',CURRENT_DATE,NULL,'denial')$$),
 ('admin_record_subscription_payment','admin_record_subscription_payment','org.settings_manage',$$SELECT public.admin_record_subscription_payment('d1000000-0000-0000-0000-000000000001',500,CURRENT_DATE,CURRENT_DATE,NULL,true,gen_random_uuid())$$),
 ('admin_get_subscription','admin_get_subscription','org.settings_manage',$$SELECT public.admin_get_subscription('d1000000-0000-0000-0000-000000000001')$$);
INSERT INTO t.denial VALUES
 ('create_branch','create_branch','branch.manage',$$SELECT public.create_branch('Denial branch','DEN',NULL,NULL,NULL,NULL,NULL)$$),
 ('update_branch','update_branch','branch.manage',$$SELECT public.update_branch('d2000000-0000-0000-0000-000000000011','Updated',NULL,NULL,NULL,NULL,NULL,NULL)$$),
 ('branch_deactivation_check','branch_deactivation_check','branch.manage',$$SELECT public.branch_deactivation_check('d2000000-0000-0000-0000-000000000012')$$),
 ('set_branch_active','set_branch_active','branch.manage',$$SELECT public.set_branch_active('d2000000-0000-0000-0000-000000000012',false,'denial',true)$$);
INSERT INTO auth.users(id,email) VALUES ('a0200000-0000-4000-8000-000000000012','o02-reset@test.local');
INSERT INTO public.employees(id,organization_id,full_name,email,role,default_branch_id,auth_user_id) VALUES
 ('a0200000-0000-4000-8000-000000000010','d1000000-0000-0000-0000-000000000001','Reset target','o02-reset@test.local','CASHIER','d2000000-0000-0000-0000-000000000011','a0200000-0000-4000-8000-000000000012'),
 ('a0200000-0000-4000-8000-000000000011','d1000000-0000-0000-0000-000000000001','Pending target','o02-pending@test.local','CASHIER','d2000000-0000-0000-0000-000000000011',NULL);
INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES ('d1000000-0000-0000-0000-000000000001','a0200000-0000-4000-8000-000000000011','d2000000-0000-0000-0000-000000000011');
INSERT INTO t.denial VALUES
 ('create_employee','create_employee','employee.manage',$$SELECT public.create_employee('Denial staff',NULL,'o02-create@test.local',NULL,'CASHIER',ARRAY['d2000000-0000-0000-0000-000000000011']::uuid[],NULL,'[]',repeat('c',64),now()+interval '1 day')$$),
 ('update_employee','update_employee','employee.manage',$$SELECT public.update_employee('a0200000-0000-4000-8000-000000000011','Edited',NULL,'o02-pending@test.local',NULL,'CASHIER','d2000000-0000-0000-0000-000000000011')$$),
 ('set_employee_active','set_employee_active','employee.manage',$$SELECT public.set_employee_active('a0200000-0000-4000-8000-000000000011',false,'Denial')$$),
 ('resend_employee_invite','resend_employee_invite','employee.manage',$$SELECT public.resend_employee_invite('a0200000-0000-4000-8000-000000000011',repeat('d',64),now()+interval '1 day')$$),
 ('create_password_reset','create_password_reset','employee.manage',$$SELECT public.create_password_reset('a0200000-0000-4000-8000-000000000010',repeat('e',64),now()+interval '1 hour')$$),
 ('list_employees','list_employees','employee.manage',$$SELECT public.list_employees(NULL,NULL,NULL,10,0)$$);
INSERT INTO t.denial VALUES
 ('update_org_settings','update_org_settings','org.settings_manage',$$SELECT public.update_org_settings('{"theme_color":"#000000"}')$$),
 ('publish_installment_policy','publish_installment_policy','org.settings_manage',$$SELECT public.publish_installment_policy('{"grace_days":2}')$$),
 ('list_installment_policies','list_installment_policies','org.settings_manage',$$SELECT public.list_installment_policies()$$);
INSERT INTO t.denial VALUES
 ('create_tax_class','create_tax_class','catalog.manage',$$SELECT public.create_tax_class('Denial class','standard',1,'T1','V009')$$),
 ('update_tax_class','update_tax_class','catalog.manage',$$SELECT public.update_tax_class((SELECT id FROM public.tax_classes WHERE organization_id='d1000000-0000-0000-0000-000000000001' LIMIT 1),'{"name":"Denied"}')$$),
 ('set_tax_class_archived','set_tax_class_archived','catalog.manage',$$SELECT public.set_tax_class_archived((SELECT id FROM public.tax_classes WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND kind='exempt' LIMIT 1),true)$$);
INSERT INTO t.denial VALUES
 ('create_category','create_category','catalog.manage',$$SELECT public.create_category('Denial category',NULL)$$),
 ('update_category','update_category','catalog.manage',$$SELECT public.update_category((SELECT id FROM public.categories WHERE organization_id='d1000000-0000-0000-0000-000000000001' LIMIT 1),'{"name":"Denied"}')$$),
 ('set_category_archived','set_category_archived','catalog.manage',$$SELECT public.set_category_archived((SELECT id FROM public.categories WHERE organization_id='d1000000-0000-0000-0000-000000000001' LIMIT 1),false)$$);
INSERT INTO t.denial VALUES
 ('create_product','create_product','catalog.manage',$$SELECT public.create_product('{"name_ar":"Denied","sku":"DENIED-1","cash_price":"1"}')$$),
 ('update_product','update_product','catalog.manage',$$SELECT public.update_product((SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND archived_at IS NULL ORDER BY id LIMIT 1),'{"name_en":"Denied"}')$$),
 ('set_product_archived','set_product_archived','catalog.manage',$$SELECT public.set_product_archived((SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND archived_at IS NULL ORDER BY id LIMIT 1),false)$$);
INSERT INTO t.denial VALUES
 ('list_stock','list_stock','stock.view',$$SELECT public.list_stock()$$),
 ('list_stock_movements','list_stock_movements','stock.view',$$SELECT public.list_stock_movements((SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' ORDER BY id LIMIT 1))$$),
 ('list_branch_min_levels','list_branch_min_levels','stock.view',$$SELECT public.list_branch_min_levels((SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' ORDER BY id LIMIT 1))$$),
 ('set_branch_min_level','set_branch_min_level','catalog.manage',$$SELECT public.set_branch_min_level((SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' ORDER BY id LIMIT 1),'d2000000-0000-0000-0000-000000000011',4)$$),
 ('low_stock_summary','low_stock_summary','stock.view',$$SELECT public.low_stock_summary()$$),
 ('export_stock_movements','export_stock_movements','export.data',$$SELECT public.export_stock_movements((SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' ORDER BY id LIMIT 1))$$);
-- I03: a third branch of shop one as the destination (the set_branch_active case deactivates 012);
-- the I02 adjustment case gave the product stock in 011 before these run.
INSERT INTO public.branches(id,organization_id,code,name) VALUES('d2000000-0000-0000-0000-0000000001f3','d1000000-0000-0000-0000-000000000001','T3F','Transfer target');
INSERT INTO t.denial VALUES
 ('cancel_stock_transfer','stock_transfer_0_cancel','stock.transfer_send',$$SELECT public.cancel_stock_transfer((public.create_stock_transfer('d2000000-0000-0000-0000-000000000011','d2000000-0000-0000-0000-0000000001f3',NULL,jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'quantity',1)),'denial-transfer-cancel')->>'id')::uuid)$$),
 ('create_stock_transfer','stock_transfer_1_create','stock.transfer_send',$$SELECT public.create_stock_transfer('d2000000-0000-0000-0000-000000000011','d2000000-0000-0000-0000-0000000001f3',NULL,jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'quantity',1)),'denial-transfer-1')$$),
 ('update_stock_transfer','stock_transfer_2_update','stock.transfer_send',$$SELECT public.update_stock_transfer((SELECT id FROM public.stock_transfers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-transfer-1'),'Denial',jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'quantity',1)))$$),
 ('send_stock_transfer','stock_transfer_3_send','stock.transfer_send',$$SELECT public.send_stock_transfer((SELECT id FROM public.stock_transfers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-transfer-1'))$$),
 ('receive_stock_transfer','stock_transfer_4_receive','stock.transfer_receive',$$SELECT public.receive_stock_transfer((SELECT id FROM public.stock_transfers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-transfer-1'),'[]')$$),
 ('get_stock_transfer','stock_transfer_5_get','stock.view',$$SELECT public.get_stock_transfer((SELECT id FROM public.stock_transfers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-transfer-1'))$$),
 ('list_stock_transfers','stock_transfer_6_list','stock.view',$$SELECT public.list_stock_transfers()$$),
 ('list_transfer_destinations','stock_transfer_7_destinations','stock.transfer_send',$$SELECT public.list_transfer_destinations()$$);
-- I04: a serialized product of shop one (made as its owner) whose serial the cases register and read.
SELECT t.as_user('d0000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT public.create_product('{"name_ar":"Denial phone","sku":"DENIAL-PH","cash_price":"1","is_serialized":true}');
RESET ROLE;
SELECT t.as_user(NULL);
INSERT INTO t.denial VALUES
 ('register_units','unit_1_register','stock.adjust',$$SELECT public.register_units((SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),'d2000000-0000-0000-0000-000000000011','100','["DENIAL-SN-1"]',NULL,'denial-units-1')$$),
 ('get_unit','unit_2_get','stock.view',$$SELECT public.get_unit((SELECT id FROM public.units WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND serial='DENIAL-SN-1'))$$),
 ('find_unit','unit_3_find','stock.view',$$SELECT public.find_unit('DENIAL-SN-1')$$),
 ('search_units','unit_4_search','stock.view',$$SELECT public.search_units()$$);
-- A local database may hold open counts from the integration tests; this file rolls back anyway.
UPDATE public.stock_counts SET status = 'cancelled' WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' AND status = 'open';
-- I02: case names order the calls (a count is created, counted, posted with every other line counted
-- as expected; cancel uses its own count).
INSERT INTO t.denial VALUES
 ('post_stock_adjustment','stock_adjustment_1_post','stock.adjust',$$SELECT public.post_stock_adjustment('d2000000-0000-0000-0000-000000000011','found',NULL,jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'quantity',1)),'denial-adjustment-1')$$),
 ('get_stock_adjustment','stock_adjustment_2_get','stock.view',$$SELECT public.get_stock_adjustment((SELECT id FROM public.stock_adjustments WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-adjustment-1'))$$),
 ('list_stock_adjustments','stock_adjustment_3_list','stock.view',$$SELECT public.list_stock_adjustments()$$),
 ('cancel_stock_count','stock_count_0_cancel','stock.count',$$SELECT public.cancel_stock_count((public.create_stock_count('d2000000-0000-0000-0000-000000000011',NULL,'denial-count-cancel')->>'id')::uuid)$$),
 ('create_stock_count','stock_count_1_create','stock.count',$$SELECT public.create_stock_count('d2000000-0000-0000-0000-000000000011',NULL,'denial-count-main')$$),
 ('save_stock_count_lines','stock_count_2_save','stock.count',$$SELECT public.save_stock_count_lines((SELECT id FROM public.stock_counts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-count-main'),jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'counted_qty',1)))$$),
 ('scan_stock_count','stock_count_3_scan','stock.count',$$SELECT public.scan_stock_count((SELECT id FROM public.stock_counts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-count-main'),(SELECT sku FROM public.products WHERE id=(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1)))$$),
 ('get_stock_count','stock_count_4_get','stock.count',$$SELECT public.get_stock_count((SELECT id FROM public.stock_counts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-count-main'))$$),
 ('list_stock_counts','stock_count_5_list','stock.count',$$SELECT public.list_stock_counts()$$),
 ('post_stock_count','stock_count_6_post','stock.count',$$SELECT public.save_stock_count_lines((SELECT id FROM public.stock_counts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-count-main'),(SELECT jsonb_agg(jsonb_build_object('product_id',l.product_id,'unit_id',l.unit_id,'counted_qty',l.expected_qty)) FROM public.stock_count_lines l WHERE l.count_id=(SELECT id FROM public.stock_counts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-count-main') AND l.counted_qty IS NULL)),public.post_stock_count((SELECT id FROM public.stock_counts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-count-main'),false,'denial-count-post')$$);
INSERT INTO t.denial VALUES
 ('update_org_profile','update_org_profile','org.profile_manage',$$SELECT public.update_org_profile('{"legal_name":"Denied"}')$$);
-- U01: case names order the calls (the owner's create makes the supplier the others use). The reads
-- need any purchasing read key (D53); the role picked for supplier.manage (CASHIER) has none of them.
INSERT INTO t.denial VALUES
 ('create_supplier','supplier_1_create','supplier.manage',$$SELECT public.create_supplier('{"name":"TEST-1 denial supplier"}')$$),
 ('update_supplier','supplier_2_update','supplier.manage',$$SELECT public.update_supplier((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial supplier'),'{"notes":"Denied"}')$$),
 ('set_supplier_archived','supplier_3_archive','supplier.manage',$$SELECT public.set_supplier_archived((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial supplier'),false)$$),
 ('list_suppliers','supplier_4_list','supplier.manage',$$SELECT public.list_suppliers()$$),
 ('get_supplier','supplier_5_get','supplier.manage',$$SELECT public.get_supplier((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial supplier'))$$),
 ('supplier_statement','supplier_6_statement','supplier.manage',$$SELECT public.supplier_statement((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial supplier'))$$);
-- U02: a supplier of shop one (made as its owner) for the purchase invoice cases; case names order
-- the calls (the owner's create makes the draft the others use; reject uses its own draft).
SELECT t.as_user('d0000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT public.create_supplier('{"name":"TEST-1 denial PI supplier"}');
RESET ROLE;
SELECT t.as_user(NULL);
INSERT INTO t.denial VALUES
 ('create_purchase_invoice','purchase_invoice_1_create','purchase.invoice_create',$$SELECT public.create_purchase_invoice((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial PI supplier'),'d2000000-0000-0000-0000-000000000011',NULL,current_date,jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'quantity',1,'unit_cost','10.00')),'denial-pi-1')$$),
 ('update_purchase_invoice','purchase_invoice_2_update','purchase.invoice_create',$$SELECT public.update_purchase_invoice((SELECT id FROM public.purchase_invoices WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-pi-1'),'{"supplier_invoice_no":"DEN-1"}')$$),
 ('get_purchase_invoice','purchase_invoice_3_get','supplier.manage',$$SELECT public.get_purchase_invoice((SELECT id FROM public.purchase_invoices WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-pi-1'))$$),
 ('list_purchase_invoices','purchase_invoice_4_list','supplier.manage',$$SELECT public.list_purchase_invoices()$$),
 ('reject_purchase_invoice','purchase_invoice_5_reject','purchase.invoice_approve',$$SELECT public.reject_purchase_invoice((public.create_purchase_invoice((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial PI supplier'),'d2000000-0000-0000-0000-000000000011',NULL,current_date,jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'quantity',1,'unit_cost','10.00')),'denial-pi-rej')->>'id')::uuid,'Denial test')$$),
 ('approve_purchase_invoice','purchase_invoice_6_approve','purchase.invoice_approve',$$SELECT public.approve_purchase_invoice((SELECT id FROM public.purchase_invoices WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-pi-1'))$$),
 ('list_purchase_approvals','purchase_invoice_7_approvals','purchase.invoice_approve',$$SELECT public.list_purchase_approvals()$$);
-- U04: after the U02 cases approved denial-pi-1 (case names order the calls): one unit goes back.
INSERT INTO t.denial VALUES
 ('post_purchase_return','purchase_return_1_post','purchase.return_create',$$SELECT public.post_purchase_return((SELECT id FROM public.purchase_invoices WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-pi-1'),'supplier_credit','Denial return',jsonb_build_array(jsonb_build_object('invoice_line_id',(SELECT id FROM public.purchase_invoice_lines WHERE invoice_id=(SELECT id FROM public.purchase_invoices WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-pi-1') LIMIT 1),'quantity',1)),'denial-return-1')$$),
 ('get_purchase_return','purchase_return_2_get','supplier.manage',$$SELECT public.get_purchase_return((SELECT id FROM public.purchase_returns WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-return-1'))$$),
 ('list_purchase_returns','purchase_return_3_list','supplier.manage',$$SELECT public.list_purchase_returns()$$),
 ('get_returnable_invoice','purchase_return_4_returnable','purchase.return_create',$$SELECT public.get_returnable_invoice((SELECT id FROM public.purchase_invoices WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-pi-1'))$$),
 ('list_payable_cash_accounts','purchase_return_5_accounts','supplier.payment_create',$$SELECT public.list_payable_cash_accounts('d2000000-0000-0000-0000-000000000011')$$);
-- K02: after the K01 cases made the denial safe (10.00 in it): the owner opens a shift, takes 5.00
-- of change from the safe and closes with exactly that (case names order the calls).
INSERT INTO t.denial VALUES
 ('open_shift','shift_1_open','shift.operate',$$SELECT public.open_shift('d2000000-0000-0000-0000-000000000011','0','denial-shift-1')$$),
 ('move_shift_cash','shift_2_cash','shift.operate',$$SELECT public.move_shift_cash((SELECT id FROM public.shifts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-shift-1'),'in','5.00',(SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial safe'),'Denial change','denial-shift-cash')$$),
 ('get_current_shift','shift_2a_current','shift.operate',$$SELECT public.get_current_shift()$$),
 ('get_shift','shift_2b_get','shift.operate',$$SELECT public.get_shift((SELECT id FROM public.shifts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-shift-1'))$$),
 ('list_shifts','shift_2c_list','shift.operate',$$SELECT public.list_shifts()$$),
 ('list_shift_vaults','shift_2d_vaults','shift.operate',$$SELECT public.list_shift_vaults('d2000000-0000-0000-0000-000000000011')$$),
 ('close_shift','shift_3_close','shift.operate',$$SELECT public.close_shift((SELECT id FROM public.shifts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-shift-1'),'{"5":1}',(SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial safe'))$$);
-- U05: an order for the denial supplier is created, edited, sent, received as a draft invoice and
-- cancelled (case names order the calls).
INSERT INTO t.denial VALUES
 ('create_purchase_order','purchase_order_1_create','purchase.order_manage',$$SELECT public.create_purchase_order((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial PI supplier'),'d2000000-0000-0000-0000-000000000011',jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND NOT is_serialized AND archived_at IS NULL ORDER BY id LIMIT 1),'quantity',2,'expected_unit_cost','10.00')),'denial-po-1')$$),
 ('update_purchase_order','purchase_order_2_update','purchase.order_manage',$$SELECT public.update_purchase_order((SELECT id FROM public.purchase_orders WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-po-1'),'{"notes":"Denial note"}')$$),
 ('send_purchase_order','purchase_order_3_send','purchase.order_manage',$$SELECT public.send_purchase_order((SELECT id FROM public.purchase_orders WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-po-1'))$$),
 ('create_invoice_from_po','purchase_order_4_invoice','purchase.invoice_create',$$SELECT public.create_invoice_from_po((SELECT id FROM public.purchase_orders WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-po-1'),'denial-po-invoice')$$),
 ('get_purchase_order','purchase_order_5_get','supplier.manage',$$SELECT public.get_purchase_order((SELECT id FROM public.purchase_orders WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-po-1'))$$),
 ('list_purchase_orders','purchase_order_6_list','supplier.manage',$$SELECT public.list_purchase_orders()$$),
 ('cancel_purchase_order','purchase_order_7_cancel','purchase.order_manage',$$SELECT public.cancel_purchase_order((SELECT id FROM public.purchase_orders WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-po-1'),'Denial cancel')$$);
-- U03: after the K01 cases funded the denial bank and the U02 cases approved denial-pi-1, and
-- before U04's return uses up what is owed (case names order the calls): 1.00 is paid from the
-- bank, read, and reversed by the owner.
INSERT INTO t.denial VALUES
 ('post_supplier_payment','purchase_invoice_8a_pay','supplier.payment_create',$$SELECT public.post_supplier_payment((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial PI supplier'),'d2000000-0000-0000-0000-000000000011',(SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'),'1.00','denial-sp-1')$$),
 ('get_supplier_payment','purchase_invoice_8b_payment','supplier.manage',$$SELECT public.get_supplier_payment((SELECT id FROM public.supplier_payments WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-sp-1'))$$),
 ('list_supplier_payments','purchase_invoice_8c_payments','supplier.manage',$$SELECT public.list_supplier_payments()$$),
 ('list_open_supplier_invoices','purchase_invoice_8d_open','supplier.payment_create',$$SELECT public.list_open_supplier_invoices((SELECT id FROM public.suppliers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial PI supplier'))$$),
 ('reverse_supplier_payment','purchase_invoice_8e_reverse','supplier.payment_create',$$SELECT public.reverse_supplier_payment((SELECT id FROM public.supplier_payments WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-sp-1'),'Denial reversal','denial-sp-1-rev')$$);
-- K01: case names order the calls (the owner's create makes the bank the others use; the opening
-- funds it, the transfer moves 10.00 into a new safe (the seed shop has no cash accounts)).
INSERT INTO t.denial VALUES
 ('create_cash_account','cash_01_create','cash.account_manage',$$SELECT public.create_cash_account('TEST-1 denial bank','bank',NULL)$$),
 ('rename_cash_account','cash_02_rename','cash.account_manage',$$SELECT public.rename_cash_account((SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'),'TEST-1 denial bank')$$),
 ('post_cash_opening','cash_03_opening','cash.adjust',$$SELECT public.post_cash_opening((SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'),'100.00','Denial opening','denial-cash-opening')$$),
 ('create_cash_transfer','cash_04_transfer','cash.transfer',$$SELECT public.create_cash_transfer((SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'),(public.create_cash_account('TEST-1 denial safe','safe','d2000000-0000-0000-0000-000000000011')->>'id')::uuid,'10.00',NULL,'denial-cash-transfer')$$),
 ('set_cash_account_active','cash_05_active','cash.account_manage',$$SELECT public.set_cash_account_active((SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'),true)$$),
 ('list_cash_accounts','cash_06_list','cash.view',$$SELECT public.list_cash_accounts()$$),
 ('get_cash_account','cash_07_get','cash.view',$$SELECT public.get_cash_account((SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'))$$),
 ('list_cash_account_movements','cash_08_movements','cash.view',$$SELECT public.list_cash_account_movements((SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'))$$),
 ('list_cash_transfers','cash_09_transfers','cash.view',$$SELECT public.list_cash_transfers()$$),
 ('get_cash_transfer','cash_10_transfer_get','cash.view',$$SELECT public.get_cash_transfer((SELECT id FROM public.cash_transfers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-cash-transfer'))$$);
-- K03: after the K01 cases funded the denial bank: a category is made, an expense of 2.00 is paid
-- from the bank and the owner reverses it (case names order the calls; the readers' role has none
-- of expense.create, cash.view and report.financial).
INSERT INTO t.denial VALUES
 ('create_expense_category','expense_1_category','expense.create',$$SELECT public.create_expense_category('TEST-1 denial category')$$),
 ('rename_expense_category','expense_2_rename','expense.create',$$SELECT public.rename_expense_category((SELECT id FROM public.expense_categories WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial category'),'TEST-1 denial category')$$),
 ('set_expense_category_archived','expense_3_archive','expense.create',$$SELECT public.set_expense_category_archived((SELECT id FROM public.expense_categories WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial category'),false)$$),
 ('list_expense_categories','expense_4_categories','expense.create',$$SELECT public.list_expense_categories()$$),
 ('post_expense','expense_5_post','expense.create',$$SELECT public.post_expense((SELECT id FROM public.expense_categories WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial category'),'2.00','denial-expense-1','d2000000-0000-0000-0000-000000000011',(SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial bank'))$$),
 ('get_expense','expense_6_get','expense.create',$$SELECT public.get_expense((SELECT id FROM public.expenses WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-expense-1'))$$),
 ('list_expenses','expense_7_list','expense.create',$$SELECT public.list_expenses()$$),
 ('expense_report','expense_8_report','expense.create',$$SELECT public.expense_report(current_date - 1, current_date + 1)$$),
 ('reverse_expense','expense_9_reverse','expense.create',$$SELECT public.reverse_expense((SELECT id FROM public.expenses WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-expense-1'),'Denial reversal','denial-expense-rev')$$);
-- S01: after the unit cases registered DENIAL-SN-1 (price 1): the owner opens a second shift,
-- quotes the unit, sells it at the quoted total and reads the sale (case names order the calls).
INSERT INTO t.denial VALUES
 ('open_shift','unit_5_sale_shift','shift.operate',$$SELECT public.open_shift('d2000000-0000-0000-0000-000000000011','0','denial-shift-sale')$$),
 ('quote_sale','unit_6_sale_quote','sale.create',$$SELECT public.quote_sale(jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),'quantity',1,'unit_id',(SELECT id FROM public.units WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND serial='DENIAL-SN-1'))))$$),
 ('post_sale','unit_7_sale_post','sale.create',$$SELECT public.post_sale(x.l,public.quote_sale(x.l)->>'total','denial-sale-1') FROM (SELECT jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),'quantity',1,'unit_id',(SELECT id FROM public.units WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND serial='DENIAL-SN-1'))) l) x$$),
 ('get_sale','unit_8_sale_get','sale.create',$$SELECT public.get_sale((SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-sale-1'))$$);
-- R01: case names order the calls (the owner's create makes the customer the others use). The reads
-- need any customer read key (D63 rule 6); the role picked for customer.create (WAREHOUSE) has none.
INSERT INTO t.denial VALUES
 ('create_customer','customer_1_create','customer.create',$$SELECT public.create_customer('{"full_name":"TEST-1 denial customer","phones":["01000000001"]}')$$),
 ('update_customer','customer_2_update','customer.edit',$$SELECT public.update_customer((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial customer'),'{"notes":"Denied"}')$$),
 ('set_customer_status','customer_3_status','customer.edit',$$SELECT public.set_customer_status((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial customer'),'blocked','Denial test')$$),
 ('list_customers','customer_4_list','customer.create',$$SELECT public.list_customers()$$),
 ('get_customer','customer_5_get','customer.create',$$SELECT public.get_customer((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial customer'))$$);
CREATE TABLE t.write_functions AS
SELECT p.proname::text AS fn FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
  AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  AND p.proname NOT IN ('session_context', 'my_shops', 'my_permissions',
                        'auth_record_login', 'auth_record_logout', 'auth_record_password_change', 'get_subscription_status','require_module','get_shop_settings','list_tax_classes','get_shop_profile','list_categories','list_products','get_product','lookup_product','list_product_units');

SELECT t.expect('4.0 every callable write function has a permission-denial case here',
    NOT EXISTS (SELECT 1 FROM t.write_functions w WHERE w.fn NOT IN (SELECT fn FROM t.denial)),
    (SELECT 'no case for: ' || string_agg(fn, ', ') FROM t.write_functions w WHERE w.fn NOT IN (SELECT fn FROM t.denial)));
SELECT t.expect('4.0b every register_file purpose has a case',
    (SELECT count(*) FROM t.denial WHERE fn = 'register_file') = (SELECT count(*) FROM unnest(enum_range(NULL::public.file_purpose))));

CREATE FUNCTION t.run_denials() RETURNS void LANGUAGE plpgsql AS $$
DECLARE d record; v_role public.employee_role; v_sub uuid; v_err text; v_owner_err text;
BEGIN
    FOR d IN SELECT * FROM t.denial ORDER BY case_name LOOP
        v_role := t.role_without(d.key);
        SELECT sub INTO v_sub FROM t.role_user WHERE role = v_role;
        PERFORM t.as_user(v_sub::text, 'd1000000-0000-0000-0000-000000000001');
        SET LOCAL ROLE authenticated;
        v_err := t.try(d.call);
        RESET ROLE;
        PERFORM t.expect(format('4.1 %s: %s (lacks %s) gets required denial', d.case_name, v_role, d.key),
                         v_role IS NOT NULL AND v_err ~ CASE WHEN d.fn LIKE 'admin_%' THEN '^SUPER_ADMIN_REQUIRED$' ELSE 'PERMISSION_DENIED' END, coalesce(v_err, '') || ' role=' || coalesce(v_role::text, 'none'));
        -- Same call as the owner works, so the arguments were valid and only the permission was missing.
        PERFORM t.as_user('d0000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001');
        SET LOCAL ROLE authenticated;
        v_owner_err := t.try(d.call);
        RESET ROLE;
        IF d.fn LIKE 'admin_%' THEN
            PERFORM t.expect(format('4.2 %s: tenant OWNER also cannot act as platform admin', d.case_name),
                             v_owner_err = 'SUPER_ADMIN_REQUIRED', v_owner_err);
        ELSE
            PERFORM t.expect(format('4.2 %s: the same call works for the owner (valid arguments)', d.case_name),
                             v_owner_err = '', v_owner_err);
        END IF;
    END LOOP;
    PERFORM t.as_user(NULL);
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
SELECT t.run_denials();

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT tables_with_b, relations_with_b, total AS tenant_relations FROM t.coverage;
SELECT name, detail AS known_bug FROM t.results WHERE name LIKE 'KNOWN BUG%';
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
