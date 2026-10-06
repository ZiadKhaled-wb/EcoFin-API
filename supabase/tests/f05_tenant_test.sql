-- F05 tenant isolation (migration 20261003080000_f05_tenant_storage.sql). LOCAL / DEV ONLY.
-- Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f05_tenant_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
--   1. grants: anon / authenticated can't write any tenant table; anon can't read one
--   2. RLS: a shop A user sees zero shop B rows in EVERY tenant table, even with x-org-id = B
--   3. public.session_context(): every refusal, and agreement with app.current_org_id()
--   4. storage: tenant-files is readable only in the caller's own org folder; no writes
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

-- session_context() as one comparable text: refusal, or org/role/branches/must_change_password.
CREATE FUNCTION t.ctx() RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE('refusal=' || c.refusal,
                    format('org=%s role=%s branches=%s mcp=%s', c.organization_id, c.role,
                           c.branch_ids, c.must_change_password::text))
    FROM public.session_context() c
$$;

CREATE FUNCTION t.as_user(p_sub text, p_org text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.sub', COALESCE(p_sub, ''), false),
           set_config('request.headers',
                      CASE WHEN p_org IS NULL THEN '{}' ELSE json_build_object('x-org-id', p_org)::text END,
                      false);
$$;

-- Every table in public with an organization_id column (by OID, so privilege checks never see
-- a name from another schema).
-- plpgsql, not sql: an inlined sql function lets the planner run a caller's privilege check on
-- rows of other schemas before this filter.
CREATE FUNCTION t.tenant_tables() RETURNS TABLE (rel regclass, name text) LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT c.oid::regclass, c.relname::text
    FROM pg_class c
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'organization_id' AND NOT a.attisdropped
    WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
    ORDER BY c.relname;
END $$;

CREATE FUNCTION t.check_no_b_rows(p_label text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    r record;
    v integer;
    v_leaks text := '';
    v_checked integer := 0;
BEGIN
    FOR r IN SELECT tt.rel, tt.name FROM t.tenant_tables() tt
             WHERE has_column_privilege(tt.rel, 'organization_id', 'SELECT')
    LOOP
        EXECUTE format('SELECT count(*) FROM %s WHERE organization_id = %L', r.rel,
                       'f5100000-0000-0000-0000-00000000000b') INTO v;
        v_checked := v_checked + 1;
        IF v > 0 THEN v_leaks := v_leaks || r.name || '=' || v || ' '; END IF;
    END LOOP;
    PERFORM t.expect(p_label || ': zero shop B rows in every readable tenant table',
                     v_leaks = '' AND v_checked >= 20, format('checked %s, leaks: %s', v_checked, v_leaks));
    PERFORM t.expect(p_label || ': the shop B organizations row is invisible',
                     NOT EXISTS (SELECT 1 FROM public.organizations
                                 WHERE id = 'f5100000-0000-0000-0000-00000000000b'));
END $$;

CREATE FUNCTION t.rows_changed(p_sql text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v integer;
BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    RETURN v;
END $$;

GRANT USAGE ON SCHEMA t TO authenticated, anon, service_role;
GRANT INSERT ON t.results TO authenticated, anon, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated, anon, service_role;

-- ---------------------------------------------------------------- fixtures
--   shop A (active)  shop B (active)  shop C (suspended)  shop D (subscription ended)
--   a: OWNER A        b: OWNER B       m: CASHIER A (must_change_password, branch A1) + ACCOUNTANT B
--   d: disabled A     z: archived A    k: CASHIER A + disabled in B
--   s: OWNER C        e: OWNER D       x: a login with no employee row
INSERT INTO auth.users (id, email) VALUES
  ('f5000000-0000-0000-0000-0000000000a1', 'f5-a@x'),
  ('f5000000-0000-0000-0000-0000000000b1', 'f5-b@x'),
  ('f5000000-0000-0000-0000-0000000000c1', 'f5-m@x'),
  ('f5000000-0000-0000-0000-0000000000d1', 'f5-d@x'),
  ('f5000000-0000-0000-0000-0000000000d2', 'f5-z@x'),
  ('f5000000-0000-0000-0000-0000000000d3', 'f5-k@x'),
  ('f5000000-0000-0000-0000-0000000000e1', 'f5-s@x'),
  ('f5000000-0000-0000-0000-0000000000f1', 'f5-e@x'),
  ('f5000000-0000-0000-0000-000000000001', 'f5-x@x');

INSERT INTO organizations (id, tenant_slug, name, plan_key, status, subscription_end) VALUES
  ('f5100000-0000-0000-0000-00000000000a', 'f5-shop-a', 'F5 Shop A', 'retail', 'active', NULL),
  ('f5100000-0000-0000-0000-00000000000b', 'f5-shop-b', 'F5 Shop B', 'retail', 'active', current_date + 30),
  ('f5100000-0000-0000-0000-00000000000c', 'f5-shop-c', 'F5 Shop C', 'retail', 'suspended', NULL),
  ('f5100000-0000-0000-0000-00000000000d', 'f5-shop-d', 'F5 Shop D', 'retail', 'active', current_date - 10);
INSERT INTO org_settings (organization_id) VALUES
  ('f5100000-0000-0000-0000-00000000000a'), ('f5100000-0000-0000-0000-00000000000b');

INSERT INTO branches (id, organization_id, code, name, is_main) VALUES
  ('f5200000-0000-0000-0000-0000000000a1', 'f5100000-0000-0000-0000-00000000000a', 'BR1', 'A main', true),
  ('f5200000-0000-0000-0000-0000000000b1', 'f5100000-0000-0000-0000-00000000000b', 'BR1', 'B main', true);

INSERT INTO employees (id, organization_id, auth_user_id, full_name, role, is_active, must_change_password, archived_at) VALUES
  ('f5300000-0000-0000-0000-0000000000a1', 'f5100000-0000-0000-0000-00000000000a', 'f5000000-0000-0000-0000-0000000000a1', 'A owner', 'OWNER', true, false, NULL),
  ('f5300000-0000-0000-0000-0000000000b1', 'f5100000-0000-0000-0000-00000000000b', 'f5000000-0000-0000-0000-0000000000b1', 'B owner', 'OWNER', true, false, NULL),
  ('f5300000-0000-0000-0000-0000000000ca', 'f5100000-0000-0000-0000-00000000000a', 'f5000000-0000-0000-0000-0000000000c1', 'M in A', 'CASHIER', true, true, NULL),
  ('f5300000-0000-0000-0000-0000000000cb', 'f5100000-0000-0000-0000-00000000000b', 'f5000000-0000-0000-0000-0000000000c1', 'M in B', 'ACCOUNTANT', true, false, NULL),
  ('f5300000-0000-0000-0000-0000000000d1', 'f5100000-0000-0000-0000-00000000000a', 'f5000000-0000-0000-0000-0000000000d1', 'D disabled', 'CASHIER', false, false, NULL),
  ('f5300000-0000-0000-0000-0000000000d2', 'f5100000-0000-0000-0000-00000000000a', 'f5000000-0000-0000-0000-0000000000d2', 'Z archived', 'CASHIER', true, false, now()),
  ('f5300000-0000-0000-0000-0000000000da', 'f5100000-0000-0000-0000-00000000000a', 'f5000000-0000-0000-0000-0000000000d3', 'K in A', 'CASHIER', true, false, NULL),
  ('f5300000-0000-0000-0000-0000000000db', 'f5100000-0000-0000-0000-00000000000b', 'f5000000-0000-0000-0000-0000000000d3', 'K in B', 'CASHIER', false, false, NULL),
  ('f5300000-0000-0000-0000-0000000000e1', 'f5100000-0000-0000-0000-00000000000c', 'f5000000-0000-0000-0000-0000000000e1', 'S owner', 'OWNER', true, false, NULL),
  ('f5300000-0000-0000-0000-0000000000f1', 'f5100000-0000-0000-0000-00000000000d', 'f5000000-0000-0000-0000-0000000000f1', 'E owner', 'OWNER', true, false, NULL);
INSERT INTO employee_branches (organization_id, employee_id, branch_id) VALUES
  ('f5100000-0000-0000-0000-00000000000a', 'f5300000-0000-0000-0000-0000000000ca', 'f5200000-0000-0000-0000-0000000000a1');

-- Shop B data in a few more tenant tables, so the RLS loop below has real rows to miss.
INSERT INTO tax_classes (id, organization_id, name, rate) VALUES
  ('f5400000-0000-0000-0000-00000000000a', 'f5100000-0000-0000-0000-00000000000a', 'VAT 14', 14),
  ('f5400000-0000-0000-0000-00000000000b', 'f5100000-0000-0000-0000-00000000000b', 'VAT 14', 14);
INSERT INTO products (id, organization_id, name_ar, sku, cash_price, tax_class_id, is_serialized) VALUES
  ('f5500000-0000-0000-0000-00000000000a', 'f5100000-0000-0000-0000-00000000000a', 'Sofa A', 'F5-A', 100, 'f5400000-0000-0000-0000-00000000000a', false),
  ('f5500000-0000-0000-0000-00000000000b', 'f5100000-0000-0000-0000-00000000000b', 'Sofa B', 'F5-B', 100, 'f5400000-0000-0000-0000-00000000000b', false);
INSERT INTO customers (id, organization_id, full_name) VALUES
  ('f5600000-0000-0000-0000-00000000000a', 'f5100000-0000-0000-0000-00000000000a', 'Customer A'),
  ('f5600000-0000-0000-0000-00000000000b', 'f5100000-0000-0000-0000-00000000000b', 'Customer B');

-- ---------------------------------------------------------------- 1. grants on tenant tables
-- has_any_column_privilege also catches column-level grants (e.g. employees without PII columns).
SELECT t.expect('grants: there are tenant tables to check', (SELECT count(*) FROM t.tenant_tables()) >= 20);

SELECT t.expect('grants: authenticated has no INSERT/UPDATE/DELETE on any tenant table',
    NOT EXISTS (SELECT 1 FROM t.tenant_tables() tt
                WHERE has_any_column_privilege('authenticated', tt.rel, 'INSERT')
                   OR has_any_column_privilege('authenticated', tt.rel, 'UPDATE')
                   OR has_table_privilege('authenticated', tt.rel, 'DELETE')),
    (SELECT string_agg(tt.name, ', ') FROM t.tenant_tables() tt
     WHERE has_any_column_privilege('authenticated', tt.rel, 'INSERT')
        OR has_any_column_privilege('authenticated', tt.rel, 'UPDATE')
        OR has_table_privilege('authenticated', tt.rel, 'DELETE')));

SELECT t.expect('grants: anon has no privilege at all on any tenant table',
    NOT EXISTS (SELECT 1 FROM t.tenant_tables() tt
                WHERE has_any_column_privilege('anon', tt.rel, 'SELECT')
                   OR has_any_column_privilege('anon', tt.rel, 'INSERT')
                   OR has_any_column_privilege('anon', tt.rel, 'UPDATE')
                   OR has_table_privilege('anon', tt.rel, 'DELETE')),
    (SELECT string_agg(tt.name, ', ') FROM t.tenant_tables() tt
     WHERE has_any_column_privilege('anon', tt.rel, 'SELECT')
        OR has_any_column_privilege('anon', tt.rel, 'INSERT')
        OR has_any_column_privilege('anon', tt.rel, 'UPDATE')
        OR has_table_privilege('anon', tt.rel, 'DELETE')));

SELECT t.expect('grants: authenticated and anon cannot write organizations',
    NOT has_any_column_privilege('authenticated', 'public.organizations', 'UPDATE')
    AND NOT has_any_column_privilege('authenticated', 'public.organizations', 'INSERT')
    AND NOT has_any_column_privilege('anon', 'public.organizations', 'SELECT'));

SELECT t.expect('grants: anon cannot execute session_context; authenticated can',
    NOT has_function_privilege('anon', 'public.session_context()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.session_context()', 'EXECUTE'));

SELECT t.expect('definer: session_context is SECURITY DEFINER with search_path pinned',
    (SELECT p.prosecdef AND p.proconfig @> ARRAY['search_path=""']
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'session_context'));

-- How many tenant tables hold a shop B row (checked as postgres, before switching role).
CREATE TABLE t.b_tables AS
SELECT 0 AS n WHERE false;
DO $$
DECLARE
    r record;
    v integer;
    v_total integer := 0;
BEGIN
    FOR r IN SELECT tt.rel FROM t.tenant_tables() tt
    LOOP
        EXECUTE format('SELECT count(*) FROM %s WHERE organization_id = %L', r.rel,
                       'f5100000-0000-0000-0000-00000000000b') INTO v;
        IF v > 0 THEN v_total := v_total + 1; END IF;
    END LOOP;
    INSERT INTO t.b_tables VALUES (v_total);
END $$;
SELECT t.expect('rls: the fixture puts shop B rows in at least 6 tenant tables',
    (SELECT n FROM t.b_tables) >= 6, (SELECT n::text FROM t.b_tables));

-- ---------------------------------------------------------------- 2. RLS: shop A sees no shop B row
SET ROLE authenticated;

SELECT t.as_user('f5000000-0000-0000-0000-0000000000a1');
SELECT t.check_no_b_rows('rls (owner A)');
SELECT t.expect('rls (owner A): sanity, sees its own shop A product',
    EXISTS (SELECT 1 FROM public.products WHERE id = 'f5500000-0000-0000-0000-00000000000a'));

SELECT t.as_user('f5000000-0000-0000-0000-0000000000a1', 'f5100000-0000-0000-0000-00000000000b');
SELECT t.check_no_b_rows('rls (owner A forging x-org-id = B)');

SELECT t.as_user('f5000000-0000-0000-0000-0000000000c1', 'f5100000-0000-0000-0000-00000000000a');
SELECT t.check_no_b_rows('rls (multi-shop user, shop A selected)');

-- ---------------------------------------------------------------- 3. session_context()
SELECT t.as_user(NULL);
SELECT t.expect('ctx: no session -> NOT_AN_EMPLOYEE', t.ctx() = 'refusal=NOT_AN_EMPLOYEE', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-000000000001');
SELECT t.expect('ctx: login with no employee row -> NOT_AN_EMPLOYEE', t.ctx() = 'refusal=NOT_AN_EMPLOYEE', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000a1');
SELECT t.expect('ctx: single-shop owner, no x-org-id -> shop A, OWNER, no branch rows',
    t.ctx() = 'org=f5100000-0000-0000-0000-00000000000a role=OWNER branches={} mcp=false', t.ctx());
SELECT t.expect('ctx: org equals app.current_org_id() (what RLS uses)',
    (SELECT organization_id FROM public.session_context()) = app.current_org_id());
-- app.current_employee_id() is not granted to authenticated; same session settings, as postgres.
RESET ROLE;
SELECT t.expect('ctx: employee equals app.current_employee_id()',
    (SELECT employee_id FROM public.session_context()) = app.current_employee_id());
SET ROLE authenticated;

SELECT t.as_user('f5000000-0000-0000-0000-0000000000a1', 'f5100000-0000-0000-0000-00000000000b');
SELECT t.expect('ctx: x-org-id of a shop the login is not in -> SHOP_NOT_ALLOWED',
    t.ctx() = 'refusal=SHOP_NOT_ALLOWED', t.ctx());

SELECT set_config('request.headers', '{"x-org-id": "not-a-uuid"}', false);
SELECT t.expect('ctx: a malformed x-org-id counts as no selection (single shop still works)',
    t.ctx() LIKE 'org=f5100000-0000-0000-0000-00000000000a %', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000c1');
SELECT t.expect('ctx: multi-shop login without x-org-id -> SHOP_SELECTION_REQUIRED',
    t.ctx() = 'refusal=SHOP_SELECTION_REQUIRED', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000c1', 'f5100000-0000-0000-0000-00000000000a');
SELECT t.expect('ctx: multi-shop login, shop A -> CASHIER, its branch, must_change_password returned (not refused)',
    t.ctx() = 'org=f5100000-0000-0000-0000-00000000000a role=CASHIER branches={f5200000-0000-0000-0000-0000000000a1} mcp=true',
    t.ctx());
SELECT t.expect('ctx: multi-shop shop A agrees with app.current_org_id()',
    (SELECT organization_id FROM public.session_context()) = app.current_org_id());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000c1', 'f5100000-0000-0000-0000-00000000000b');
SELECT t.expect('ctx: multi-shop login, shop B -> ACCOUNTANT in B',
    t.ctx() = 'org=f5100000-0000-0000-0000-00000000000b role=ACCOUNTANT branches={} mcp=false', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000d1');
SELECT t.expect('ctx: only row disabled -> ACCOUNT_DISABLED', t.ctx() = 'refusal=ACCOUNT_DISABLED', t.ctx());
SELECT t.as_user('f5000000-0000-0000-0000-0000000000d1', 'f5100000-0000-0000-0000-00000000000a');
SELECT t.expect('ctx: disabled row selected by x-org-id -> ACCOUNT_DISABLED', t.ctx() = 'refusal=ACCOUNT_DISABLED', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000d2');
SELECT t.expect('ctx: archived employee -> ACCOUNT_DISABLED', t.ctx() = 'refusal=ACCOUNT_DISABLED', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000d3');
SELECT t.expect('ctx: active in A + disabled in B, no x-org-id -> the active shop A',
    t.ctx() LIKE 'org=f5100000-0000-0000-0000-00000000000a role=CASHIER %', t.ctx());
SELECT t.as_user('f5000000-0000-0000-0000-0000000000d3', 'f5100000-0000-0000-0000-00000000000b');
SELECT t.expect('ctx: same login choosing the shop where it is disabled -> ACCOUNT_DISABLED',
    t.ctx() = 'refusal=ACCOUNT_DISABLED', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000e1');
SELECT t.expect('ctx: suspended shop -> ORG_SUSPENDED', t.ctx() = 'refusal=ORG_SUSPENDED', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000f1');
SELECT t.expect('ctx: subscription ended remains available for read-only access', t.ctx() LIKE 'org=f5100000-0000-0000-0000-00000000000d role=OWNER %', t.ctx());

SELECT t.as_user('f5000000-0000-0000-0000-0000000000b1');
SELECT t.expect('ctx: subscription ending in the future is fine',
    t.ctx() LIKE 'org=f5100000-0000-0000-0000-00000000000b role=OWNER %', t.ctx());

SELECT t.as_user(NULL);
RESET ROLE;

-- ---------------------------------------------------------------- 4. storage: tenant-files
DO $$
BEGIN
    IF to_regclass('storage.objects') IS NULL THEN
        PERFORM t.expect('storage: n.a. (no storage schema)', true);
        RETURN;
    END IF;
    INSERT INTO storage.objects (bucket_id, name) VALUES
      ('tenant-files', 'f5100000-0000-0000-0000-00000000000a/invoices/a.pdf'),
      ('tenant-files', 'f5100000-0000-0000-0000-00000000000b/invoices/b.pdf');
END $$;

SELECT t.expect('storage: the only authenticated policy on storage.objects is the SELECT one',
    (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'storage' AND tablename = 'objects' AND 'authenticated' = ANY (roles)) = 1
    AND (SELECT cmd FROM pg_policies
         WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'tenant_files_read_own_org') = 'SELECT');

SET ROLE authenticated;
SELECT t.as_user('f5000000-0000-0000-0000-0000000000a1');
SELECT t.expect('storage: owner A sees its own file',
    EXISTS (SELECT 1 FROM storage.objects
            WHERE bucket_id = 'tenant-files' AND name = 'f5100000-0000-0000-0000-00000000000a/invoices/a.pdf'));
SELECT t.expect('storage: owner A does not see shop B''s file',
    NOT EXISTS (SELECT 1 FROM storage.objects
                WHERE bucket_id = 'tenant-files' AND name LIKE 'f5100000-0000-0000-0000-00000000000b/%'));
SELECT t.expect_error('storage: owner A cannot upload, even into its own folder',
    $q$INSERT INTO storage.objects (bucket_id, name) VALUES ('tenant-files', 'f5100000-0000-0000-0000-00000000000a/x.pdf')$q$,
    'row-level security');

-- The Storage API sets storage.allow_delete_query before its DELETE (storage.protect_delete
-- trigger); do the same so RLS is what decides.
SELECT set_config('storage.allow_delete_query', 'true', false);
SELECT t.expect('storage: owner A cannot rename or delete its own file (no UPDATE/DELETE policy)',
    t.rows_changed($q$UPDATE storage.objects SET name = name || '.x' WHERE bucket_id = 'tenant-files'$q$) = 0
    AND t.rows_changed($q$DELETE FROM storage.objects WHERE bucket_id = 'tenant-files'$q$) = 0);

SELECT t.as_user('f5000000-0000-0000-0000-0000000000c1');
SELECT t.expect('storage: multi-shop login without a selected shop sees no file',
    NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'tenant-files'));

SELECT t.as_user('f5000000-0000-0000-0000-0000000000c1', 'f5100000-0000-0000-0000-00000000000b');
SELECT t.expect('storage: the same login with shop B selected sees only shop B''s file',
    (SELECT array_agg(name) FROM storage.objects WHERE bucket_id = 'tenant-files')
    = ARRAY['f5100000-0000-0000-0000-00000000000b/invoices/b.pdf']);

SELECT t.as_user(NULL);
RESET ROLE;

SET ROLE anon;
SELECT t.expect('storage: anon sees no tenant file',
    NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'tenant-files'));
RESET ROLE;

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
