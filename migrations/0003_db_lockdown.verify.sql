-- =============================================================================
-- Verify 0003 — checks to run AFTER applying 0003_db_lockdown.sql
-- =============================================================================
--
-- Purpose: prove the lockdown holds and the API's own access still works.
-- Date: 2026-10-02
--
-- Read-only. Everything runs inside BEGIN ... ROLLBACK, and every write it
-- tries is either denied or matches no rows (WHERE false).
--
-- How to run (as postgres):
--   psql "$DATABASE_URL" -f migrations/0003_db_lockdown.verify.sql
-- psql prints every result. The Supabase SQL editor shows only the last
-- result set (the Part B table); run Part A queries one by one there.
--
--   Part A  catalog checks: each query lists its expected result.
--   Part B  behaviour checks as anon, as a real employee and as a super admin
--           (set local role + request.jwt.claims, as in Supabase's RLS
--           testing docs). Ends with one table: id | check | expected |
--           actual | result. Every row must say PASS.
--
-- Part B tells "permission denied" (a missing GRANT) from other 42501 errors
-- by the server's message text, so it assumes English server messages
-- (lc_messages = en / C, the Supabase default).
--
-- Part B impersonates an active employee with a login (auth_id), preferring
-- the org with the most employees so "another employee in my org" can be
-- tested. Rows that need data the database doesn't have say SKIP.
-- =============================================================================

BEGIN;

-- =============================================================================
-- PART A — catalog checks (as postgres)
-- =============================================================================

-- A1. Relations in public that anon can touch in any way.
-- Expected: 0 rows.
SELECT c.relkind, format('%I.%I', n.nspname, c.relname) AS relation
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND (   (c.relkind IN ('r', 'p', 'v', 'm', 'f')
           AND has_table_privilege('anon', c.oid,
                 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))
       OR (c.relkind = 'S'
           AND has_sequence_privilege('anon', c.oid, 'USAGE, SELECT, UPDATE')))
ORDER BY 2;

-- A2. Relations in public where authenticated has any TABLE-level privilege
--     (SELECT included).
-- Expected: 0 rows.
SELECT c.relkind, format('%I.%I', n.nspname, c.relname) AS relation
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND (   (c.relkind IN ('r', 'p', 'v', 'm', 'f')
           AND has_table_privilege('authenticated', c.oid,
                 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))
       OR (c.relkind = 'S'
           AND has_sequence_privilege('authenticated', c.oid, 'USAGE, SELECT, UPDATE')))
ORDER BY 2;

-- A3. Columns authenticated can SELECT.
-- Expected: exactly these 15 rows (the columns the API reads):
--   employees: auth_id, branch_id, email, id, is_active, must_change_password,
--              organization_id, permissions, role, username
--   super_admins: auth_user_id, email, full_name, id, is_active
-- In particular NOT employees.national_id, base_salary_piasters, phone,
-- full_name, address, and nothing from any other table or view.
SELECT c.relname AS table_name, a.attname AS column_name
FROM pg_attribute a
JOIN pg_class c     ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND has_column_privilege('authenticated', c.oid, a.attnum, 'SELECT')
ORDER BY 1, 2;

-- A4. Columns authenticated can write.
-- Expected: 0 rows.
SELECT c.relname AS table_name, a.attname AS column_name
FROM pg_attribute a
JOIN pg_class c     ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND has_column_privilege('authenticated', c.oid, a.attnum, 'INSERT, UPDATE, REFERENCES')
ORDER BY 1, 2;

-- A5. Balance views run with the caller's rights.
-- Expected: 4 rows, security_invoker = true on each.
SELECT c.relname AS view_name,
       'security_invoker=true' = ANY (COALESCE(c.reloptions, '{}')) AS security_invoker
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('vault_balances', 'wallet_balances',
                    'installment_balances', 'contract_balances')
ORDER BY 1;

-- A6. RLS flags.
-- Expected: 3 rows, rls_enabled = true and rls_forced = false on each.
SELECT relname, relrowsecurity AS rls_enabled, relforcerowsecurity AS rls_forced
FROM pg_class
WHERE oid IN ('public.plans'::regclass, 'public.employees'::regclass,
              'public.super_admins'::regclass)
ORDER BY 1;

-- A7. Policies on organizations, employees, super_admins.
-- Expected: exactly 3 rows:
--   employees     employees_self_read        SELECT {authenticated}  (auth_id = (SELECT auth.uid()))
--   organizations organizations_tenant_read  SELECT {public}
--   super_admins  super_admins_self_read     SELECT {authenticated}  (auth_user_id = (SELECT auth.uid()))
-- No organizations_tenant_update, employees_tenant_all or super_admins_self.
SELECT tablename, policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('organizations', 'employees', 'super_admins')
ORDER BY 1, 2;

-- A8. EXECUTE matrix for every non-extension function in public.
-- Expected (9 rows on the documented schema):
--   function                                   public anon  authenticated service_role
--   activate_workspace(text,uuid,text)         f      f     f             t
--   current_employee_id()                      f      f     f             t
--   "current_role"()                           f      f     f             t
--   current_user_org_id()                      f      f     t             t
--   egp_to_piasters(numeric)                   f      f     f             t
--   is_owner()                                 f      f     f             t
--   is_super_admin()                           f      f     t             t
--   piasters_to_egp(bigint)                    f      f     f             t
--   set_updated_at()                           f      f     f             t
-- Any extra row must also be f / f / f / t.
SELECT p.oid::regprocedure AS function,
       EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) e
               WHERE e.grantee = 0 AND e.privilege_type = 'EXECUTE') AS public,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS anon,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated,
       has_function_privilege('service_role',  p.oid, 'EXECUTE') AS service_role
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_catalog.pg_proc'::regclass
                    AND d.objid = p.oid AND d.deptype = 'e')
ORDER BY p.proname;

-- A9. auth.uid() is callable by authenticated (the own-row policies use it).
-- Expected: 1 row, true.
SELECT has_function_privilege('authenticated', 'auth.uid()', 'EXECUTE') AS auth_uid_executable;

-- A10. Default privileges of postgres that still grant to anon / authenticated.
-- Expected: 0 rows.
SELECT d.defaclnamespace::regnamespace AS schema, d.defaclobjtype AS objtype,
       e.grantee::regrole AS grantee, e.privilege_type
FROM pg_default_acl d, aclexplode(d.defaclacl) e
WHERE d.defaclrole = 'postgres'::regrole
  AND e.grantee IN ('anon'::regrole::oid, 'authenticated'::regrole::oid);

-- A11. Do new functions created by postgres still get PUBLIC EXECUTE?
-- Expected: 1 row, false.
SELECT EXISTS (
    SELECT 1
    FROM aclexplode(COALESCE(
             (SELECT defaclacl FROM pg_default_acl
              WHERE defaclrole = 'postgres'::regrole
                AND defaclnamespace = 0 AND defaclobjtype = 'f'),
             acldefault('f', 'postgres'::regrole))) e
    WHERE e.grantee = 0) AS new_functions_public_execute;

-- A12. Rollback snapshot is in place and locked (until 0004 drops it).
-- Expected: 1 row: rows > 0, every other column false.
SELECT (SELECT count(*) FROM migration_backup.m0003_pre_lockdown) AS rows,
       EXISTS (SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) e
               WHERE n.nspname = 'migration_backup' AND e.grantee = 0)               AS public_on_schema,
       has_schema_privilege('anon', 'migration_backup', 'USAGE, CREATE')          AS anon_schema,
       has_schema_privilege('authenticated', 'migration_backup', 'USAGE, CREATE') AS authenticated_schema,
       EXISTS (SELECT 1 FROM pg_class c
               WHERE c.relnamespace = 'migration_backup'::regnamespace
                 AND (   has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
                      OR has_table_privilege('authenticated', c.oid, 'SELECT, INSERT, UPDATE, DELETE')))
                                                                                  AS api_roles_on_tables;


-- =============================================================================
-- PART B — behaviour as anon, an employee and a super admin
-- =============================================================================
-- Results go into a transaction-local setting and are printed at the end.
--   "permission denied"  blocked by a missing GRANT (what 0003 does)
--   "blocked by RLS"     the GRANT is still there and only RLS stopped it
--   "denied: <message>"  refused for another reason (read it)
--   "allowed"            the statement ran
--   a number / true      the value a read returned
-- A row passes only when actual = expected.

-- B0. Pick who and what to test with (still as postgres).
-- Expected: one row; empty values mean "no such data", and the rows that
-- need it say SKIP.
WITH me AS (
    SELECT e.id, e.auth_id, e.organization_id
    FROM public.employees e
    WHERE e.is_active AND e.auth_id IS NOT NULL
    ORDER BY (SELECT count(*) FROM public.employees o
              WHERE o.organization_id = e.organization_id) DESC,
             e.created_at, e.id
    LIMIT 1
),
other_same_org AS (
    SELECT o.id FROM public.employees o, me
    WHERE o.organization_id = me.organization_id AND o.id <> me.id
    ORDER BY o.created_at, o.id LIMIT 1
),
other_org AS (
    SELECT o.id FROM public.employees o, me
    WHERE o.organization_id <> me.organization_id
    ORDER BY o.created_at, o.id LIMIT 1
),
sa AS (
    SELECT s.auth_user_id FROM public.super_admins s
    ORDER BY s.created_at, s.id LIMIT 1
)
SELECT set_config('verify.auth_id',          COALESCE((SELECT auth_id::text         FROM me), ''), true)             AS auth_id,
       set_config('verify.org_id',           COALESCE((SELECT organization_id::text FROM me), ''), true)             AS org_id,
       set_config('verify.emp_id',           COALESCE((SELECT id::text              FROM me), ''), true)             AS emp_id,
       set_config('verify.other_emp_id',     COALESCE((SELECT id::text FROM other_same_org), ''), true)             AS other_emp_id,
       set_config('verify.other_org_emp_id', COALESCE((SELECT id::text FROM other_org), ''), true)                  AS other_org_emp_id,
       set_config('verify.sa_auth_id',       COALESCE((SELECT auth_user_id::text FROM sa), ''), true)               AS sa_auth_id,
       set_config('verify.results', '', true)                                                                       AS results_reset;


-- -----------------------------------------------------------------------------
-- B1. As anon (the public anon key, no user)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE anon;
SET LOCAL request.jwt.claims TO '{"role":"anon"}';

DO $$
DECLARE
    c        record;
    v_actual text;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            ('B1.01', 'anon: SELECT vault_balances',        'SELECT 1 FROM public.vault_balances LIMIT 1'),
            ('B1.02', 'anon: SELECT wallet_balances',       'SELECT 1 FROM public.wallet_balances LIMIT 1'),
            ('B1.03', 'anon: SELECT installment_balances',  'SELECT 1 FROM public.installment_balances LIMIT 1'),
            ('B1.04', 'anon: SELECT contract_balances',     'SELECT 1 FROM public.contract_balances LIMIT 1'),
            ('B1.05', 'anon: SELECT plans',                 'SELECT 1 FROM public.plans LIMIT 1'),
            ('B1.06', 'anon: SELECT employees',             'SELECT 1 FROM public.employees LIMIT 1'),
            ('B1.07', 'anon: SELECT employees.id',          'SELECT id FROM public.employees LIMIT 1'),
            ('B1.08', 'anon: SELECT super_admins.id',       'SELECT id FROM public.super_admins LIMIT 1'),
            ('B1.09', 'anon: SELECT organizations',         'SELECT 1 FROM public.organizations LIMIT 1'),
            ('B1.10', 'anon: SELECT payments',              'SELECT 1 FROM public.payments LIMIT 1'),
            ('B1.11', 'anon: UPDATE plans (prices)',        'UPDATE public.plans SET monthly_price_egp = 0 WHERE false'),
            ('B1.12', 'anon: INSERT plans',                 'INSERT INTO public.plans DEFAULT VALUES'),
            ('B1.13', 'anon: SELECT migration_backup',      'SELECT 1 FROM migration_backup.m0003_pre_lockdown LIMIT 1'),
            ('B1.14', 'anon: EXECUTE activate_workspace',   'SELECT public.activate_workspace(''X'', ''00000000-0000-0000-0000-000000000000''::uuid, ''x'')'),
            ('B1.15', 'anon: EXECUTE current_user_org_id',  'SELECT public.current_user_org_id()'),
            ('B1.16', 'anon: EXECUTE egp_to_piasters',      'SELECT public.egp_to_piasters(1)')
        ) AS t(id, label, stmt)
    LOOP
        BEGIN
            EXECUTE c.stmt;
            v_actual := 'allowed';
        EXCEPTION
            WHEN insufficient_privilege THEN
                v_actual := CASE
                    WHEN SQLERRM LIKE 'permission denied%'   THEN 'permission denied'
                    WHEN SQLERRM LIKE '%row-level security%' THEN 'blocked by RLS'
                    ELSE 'denied: ' || SQLERRM END;
            WHEN OTHERS THEN
                v_actual := 'allowed (then failed: ' || SQLSTATE || ')';
        END;
        PERFORM set_config('verify.results',
            current_setting('verify.results')
            || format(E'%s\t%s\t%s\t%s\n', c.id, c.label, 'permission denied', v_actual),
            true);
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- B2. As authenticated: a real employee's JWT (the token the Web app holds).
--     Literal form from the Supabase docs:
--       set local role authenticated;
--       set local request.jwt.claims to '{"sub":"<auth uuid>","role":"authenticated"}';
--     set_config(..., true) below is the same SET LOCAL, filled from B0.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
                  json_build_object('sub',  NULLIF(current_setting('verify.auth_id'), ''),
                                    'role', 'authenticated')::text,
                  true) AS jwt_claims;

-- mode "deny":  run it; expected "permission denied"
-- mode "value": run it INTO a value; expected that value
-- needs:        the B0 setting that must be non-empty, or '' for none
DO $$
DECLARE
    c        record;
    v_actual text;
    -- the exact select list attachEmployee sends (src/middleware/auth.ts:81-83)
    v_api_cols text := 'id, organization_id, auth_id, branch_id, role, permissions, '
                       || 'is_active, username, email, must_change_password';
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            -- own row, API columns: must WORK
            ('B2.01', 'auth: own employees row, API columns (attachEmployee)', 'auth_id', 'value',
             format('SELECT count(*)::text FROM (SELECT %s FROM public.employees WHERE auth_id = auth.uid()) s', v_api_cols), '1'),
            ('B2.02', 'auth: own row is the impersonated employee', 'auth_id', 'value',
             'SELECT (id::text = current_setting(''verify.emp_id''))::text FROM public.employees WHERE auth_id = auth.uid()', 'true'),
            ('B2.03', 'auth: current_user_org_id() = own org (RLS helper kept)', 'auth_id', 'value',
             'SELECT (public.current_user_org_id()::text = current_setting(''verify.org_id''))::text', 'true'),

            -- other employees' rows: hidden by RLS (0 rows), even same org
            ('B2.04', 'auth: another employee in my org (by id) -> 0 rows', 'other_emp_id', 'value',
             'SELECT count(*)::text FROM (SELECT id FROM public.employees WHERE id::text = current_setting(''verify.other_emp_id'')) s', '0'),
            ('B2.05', 'auth: an employee in another org (by id) -> 0 rows', 'other_org_emp_id', 'value',
             'SELECT count(*)::text FROM (SELECT id FROM public.employees WHERE id::text = current_setting(''verify.other_org_emp_id'')) s', '0'),
            ('B2.06', 'auth: all rows not mine -> 0 rows', 'auth_id', 'value',
             'SELECT count(*)::text FROM (SELECT id FROM public.employees WHERE auth_id IS DISTINCT FROM auth.uid()) s', '0'),

            -- columns outside the API list, even on my own row: DENIED
            ('B2.07', 'auth: own row, national_id',          '', 'deny', 'SELECT national_id FROM public.employees WHERE auth_id = auth.uid()', 'permission denied'),
            ('B2.08', 'auth: own row, base_salary_piasters', '', 'deny', 'SELECT base_salary_piasters FROM public.employees WHERE auth_id = auth.uid()', 'permission denied'),
            ('B2.09', 'auth: own row, phone',                '', 'deny', 'SELECT phone FROM public.employees WHERE auth_id = auth.uid()', 'permission denied'),
            ('B2.10', 'auth: own row, SELECT *',             '', 'deny', 'SELECT * FROM public.employees WHERE auth_id = auth.uid()', 'permission denied'),
            ('B2.11', 'auth: super_admins.phone',            '', 'deny', 'SELECT phone FROM public.super_admins', 'permission denied'),

            -- every other table / view: DENIED
            ('B2.12', 'auth: SELECT payments',                         '', 'deny', 'SELECT 1 FROM public.payments LIMIT 1', 'permission denied'),
            ('B2.13', 'auth: SELECT vault_transactions',               '', 'deny', 'SELECT 1 FROM public.vault_transactions LIMIT 1', 'permission denied'),
            ('B2.14', 'auth: SELECT wallet_transactions',              '', 'deny', 'SELECT 1 FROM public.wallet_transactions LIMIT 1', 'permission denied'),
            ('B2.15', 'auth: SELECT inventory_transactions',           '', 'deny', 'SELECT 1 FROM public.inventory_transactions LIMIT 1', 'permission denied'),
            ('B2.16', 'auth: SELECT payment_installment_applications', '', 'deny', 'SELECT 1 FROM public.payment_installment_applications LIMIT 1', 'permission denied'),
            ('B2.17', 'auth: SELECT installment_events',               '', 'deny', 'SELECT 1 FROM public.installment_events LIMIT 1', 'permission denied'),
            ('B2.18', 'auth: SELECT partner_transactions',             '', 'deny', 'SELECT 1 FROM public.partner_transactions LIMIT 1', 'permission denied'),
            ('B2.19', 'auth: SELECT product_cost_log',                 '', 'deny', 'SELECT 1 FROM public.product_cost_log LIMIT 1', 'permission denied'),
            ('B2.20', 'auth: SELECT vault_balances',                   '', 'deny', 'SELECT 1 FROM public.vault_balances LIMIT 1', 'permission denied'),
            ('B2.21', 'auth: SELECT wallet_balances',                  '', 'deny', 'SELECT 1 FROM public.wallet_balances LIMIT 1', 'permission denied'),
            ('B2.22', 'auth: SELECT installment_balances',             '', 'deny', 'SELECT 1 FROM public.installment_balances LIMIT 1', 'permission denied'),
            ('B2.23', 'auth: SELECT contract_balances',                '', 'deny', 'SELECT 1 FROM public.contract_balances LIMIT 1', 'permission denied'),
            ('B2.24', 'auth: SELECT customers',                        '', 'deny', 'SELECT 1 FROM public.customers LIMIT 1', 'permission denied'),
            ('B2.25', 'auth: SELECT hr_contracts',                     '', 'deny', 'SELECT 1 FROM public.hr_contracts LIMIT 1', 'permission denied'),
            ('B2.26', 'auth: SELECT audit_logs',                       '', 'deny', 'SELECT 1 FROM public.audit_logs LIMIT 1', 'permission denied'),
            ('B2.27', 'auth: SELECT organizations',                    '', 'deny', 'SELECT 1 FROM public.organizations LIMIT 1', 'permission denied'),
            ('B2.28', 'auth: SELECT plans',                            '', 'deny', 'SELECT 1 FROM public.plans LIMIT 1', 'permission denied'),
            ('B2.29', 'auth: SELECT migration_backup',                 '', 'deny', 'SELECT 1 FROM migration_backup.m0003_pre_lockdown LIMIT 1', 'permission denied'),

            -- writes: DENIED
            ('B2.30', 'auth: UPDATE employees (self-promote)',  '', 'deny', 'UPDATE public.employees SET role = ''OWNER'' WHERE false', 'permission denied'),
            ('B2.31', 'auth: INSERT payments',                  '', 'deny', 'INSERT INTO public.payments DEFAULT VALUES', 'permission denied'),
            ('B2.32', 'auth: DELETE payments',                  '', 'deny', 'DELETE FROM public.payments WHERE false', 'permission denied'),
            ('B2.33', 'auth: DELETE vault_transactions',        '', 'deny', 'DELETE FROM public.vault_transactions WHERE false', 'permission denied'),
            ('B2.34', 'auth: DELETE wallet_transactions',       '', 'deny', 'DELETE FROM public.wallet_transactions WHERE false', 'permission denied'),
            ('B2.35', 'auth: DELETE inventory_transactions',    '', 'deny', 'DELETE FROM public.inventory_transactions WHERE false', 'permission denied'),
            ('B2.36', 'auth: DELETE payment_installment_applications', '', 'deny', 'DELETE FROM public.payment_installment_applications WHERE false', 'permission denied'),
            ('B2.37', 'auth: DELETE installment_events',        '', 'deny', 'DELETE FROM public.installment_events WHERE false', 'permission denied'),
            ('B2.38', 'auth: DELETE partner_transactions',      '', 'deny', 'DELETE FROM public.partner_transactions WHERE false', 'permission denied'),
            ('B2.39', 'auth: DELETE product_cost_log',          '', 'deny', 'DELETE FROM public.product_cost_log WHERE false', 'permission denied'),
            ('B2.40', 'auth: UPDATE organizations (unsuspend)', '', 'deny', 'UPDATE public.organizations SET is_suspended = false WHERE false', 'permission denied'),
            ('B2.41', 'auth: UPDATE plans',                     '', 'deny', 'UPDATE public.plans SET max_users = 9999 WHERE false', 'permission denied'),
            ('B2.42', 'auth: INSERT audit_logs (forge)',        '', 'deny', 'INSERT INTO public.audit_logs DEFAULT VALUES', 'permission denied'),

            -- RPCs: DENIED
            ('B2.43', 'auth: EXECUTE activate_workspace',  '', 'deny', 'SELECT public.activate_workspace(''X'', ''00000000-0000-0000-0000-000000000000''::uuid, ''x'')', 'permission denied'),
            ('B2.44', 'auth: EXECUTE is_owner',            '', 'deny', 'SELECT public.is_owner()', 'permission denied'),
            ('B2.45', 'auth: EXECUTE current_role',        '', 'deny', 'SELECT public."current_role"()', 'permission denied'),
            ('B2.46', 'auth: EXECUTE current_employee_id', '', 'deny', 'SELECT public.current_employee_id()', 'permission denied')
        ) AS t(id, label, needs, mode, stmt, expected)
    LOOP
        IF c.needs <> '' AND current_setting('verify.' || c.needs) = '' THEN
            v_actual := 'SKIP (no ' || c.needs || ' in this database)';
        ELSE
            BEGIN
                IF c.mode = 'value' THEN
                    EXECUTE c.stmt INTO v_actual;
                ELSE
                    EXECUTE c.stmt;
                    v_actual := 'allowed';
                END IF;
            EXCEPTION
                WHEN insufficient_privilege THEN
                    v_actual := CASE
                        WHEN SQLERRM LIKE 'permission denied%'   THEN 'permission denied'
                        WHEN SQLERRM LIKE '%row-level security%' THEN 'blocked by RLS'
                        ELSE 'denied: ' || SQLERRM END;
                WHEN OTHERS THEN
                    v_actual := CASE WHEN c.mode = 'value'
                                     THEN 'error ' || SQLSTATE || ': ' || SQLERRM
                                     ELSE 'allowed (then failed: ' || SQLSTATE || ')' END;
            END;
        END IF;
        PERFORM set_config('verify.results',
            current_setting('verify.results')
            || format(E'%s\t%s\t%s\t%s\n', c.id, c.label, c.expected, COALESCE(v_actual, 'NULL')),
            true);
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- B3. As authenticated: a super admin's JWT (loadSuperAdmin, login step 5)
-- -----------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  json_build_object('sub',  NULLIF(current_setting('verify.sa_auth_id'), ''),
                                    'role', 'authenticated')::text,
                  true) AS jwt_claims;

DO $$
DECLARE
    c        record;
    v_actual text;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            -- the exact select list loadSuperAdmin sends (src/middleware/auth.ts:130)
            ('B3.01', 'super admin: own row, API columns (loadSuperAdmin)', 'sa_auth_id', 'value',
             'SELECT count(*)::text FROM (SELECT id, auth_user_id, email, full_name, is_active FROM public.super_admins WHERE auth_user_id = auth.uid()) s', '1'),
            ('B3.02', 'super admin: other super admins -> 0 rows', 'sa_auth_id', 'value',
             'SELECT count(*)::text FROM (SELECT id FROM public.super_admins WHERE auth_user_id IS DISTINCT FROM auth.uid()) s', '0'),
            ('B3.03', 'super admin: own row, phone', '', 'deny',
             'SELECT phone FROM public.super_admins WHERE auth_user_id = auth.uid()', 'permission denied'),
            ('B3.04', 'super admin: SELECT organizations', '', 'deny',
             'SELECT 1 FROM public.organizations LIMIT 1', 'permission denied'),
            ('B3.05', 'super admin: SELECT saaslicenses', '', 'deny',
             'SELECT 1 FROM public.saaslicenses LIMIT 1', 'permission denied')
        ) AS t(id, label, needs, mode, stmt, expected)
    LOOP
        IF c.needs <> '' AND current_setting('verify.' || c.needs) = '' THEN
            v_actual := 'SKIP (no ' || c.needs || ' in this database)';
        ELSE
            BEGIN
                IF c.mode = 'value' THEN
                    EXECUTE c.stmt INTO v_actual;
                ELSE
                    EXECUTE c.stmt;
                    v_actual := 'allowed';
                END IF;
            EXCEPTION
                WHEN insufficient_privilege THEN
                    v_actual := CASE
                        WHEN SQLERRM LIKE 'permission denied%'   THEN 'permission denied'
                        WHEN SQLERRM LIKE '%row-level security%' THEN 'blocked by RLS'
                        ELSE 'denied: ' || SQLERRM END;
                WHEN OTHERS THEN
                    v_actual := CASE WHEN c.mode = 'value'
                                     THEN 'error ' || SQLSTATE || ': ' || SQLERRM
                                     ELSE 'allowed (then failed: ' || SQLSTATE || ')' END;
            END;
        END IF;
        PERFORM set_config('verify.results',
            current_setting('verify.results')
            || format(E'%s\t%s\t%s\t%s\n', c.id, c.label, c.expected, COALESCE(v_actual, 'NULL')),
            true);
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- Results. Expected: every row PASS (SKIP only where B0 found no data).
-- -----------------------------------------------------------------------------
RESET ROLE;

SELECT split_part(line, E'\t', 1) AS id,
       split_part(line, E'\t', 2) AS check_name,
       split_part(line, E'\t', 3) AS expected,
       split_part(line, E'\t', 4) AS actual,
       CASE
           WHEN split_part(line, E'\t', 4) LIKE 'SKIP%'                 THEN 'SKIP'
           WHEN split_part(line, E'\t', 3) = split_part(line, E'\t', 4) THEN 'PASS'
           ELSE 'FAIL'
       END AS result
FROM unnest(string_to_array(rtrim(current_setting('verify.results'), E'\n'), E'\n')) AS line
ORDER BY 1;

ROLLBACK;
