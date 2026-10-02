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
--   Part B  behaviour checks as anon and as a real authenticated employee
--           (set local role + request.jwt.claims, as in Supabase's RLS
--           testing docs). Ends with one table: id | check | expected |
--           actual | result. Every row must say PASS.
--
-- Part B tells "permission denied" (a missing GRANT) from other 42501 errors
-- by the server's message text, so it assumes English server messages
-- (lc_messages = en / C, the Supabase default).
--
-- Part B impersonates the oldest active employee with a login (auth_id).
-- With no such employee, the authenticated rows that need one say SKIP.
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

-- A2. Relations in public that authenticated can write to.
-- Expected: 0 rows.
SELECT c.relkind, format('%I.%I', n.nspname, c.relname) AS relation
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND (   (c.relkind IN ('r', 'p', 'v', 'm', 'f')
           AND has_table_privilege('authenticated', c.oid,
                 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))
       OR (c.relkind = 'S'
           AND has_sequence_privilege('authenticated', c.oid, 'USAGE, UPDATE')))
ORDER BY 2;

-- A3. Tables and views authenticated can NOT read (SELECT must be kept).
-- Expected: 0 rows.
SELECT format('%I.%I', n.nspname, c.relname) AS relation
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'v', 'm')
  AND NOT has_table_privilege('authenticated', c.oid, 'SELECT')
ORDER BY 1;

-- A4. Balance views run with the caller's rights.
-- Expected: 4 rows, security_invoker = true on each.
SELECT c.relname AS view_name,
       'security_invoker=true' = ANY (COALESCE(c.reloptions, '{}')) AS security_invoker
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('vault_balances', 'wallet_balances',
                    'installment_balances', 'contract_balances')
ORDER BY 1;

-- A5. RLS on plans.
-- Expected: 1 row, rls_enabled = true.
SELECT relname, relrowsecurity AS rls_enabled
FROM pg_class WHERE oid = 'public.plans'::regclass;

-- A6. Policies left on organizations.
-- Expected: 1 row, organizations_tenant_read (SELECT). No organizations_tenant_update.
SELECT policyname, cmd FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'organizations'
ORDER BY 1;

-- A7. EXECUTE matrix for every non-extension function in public.
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

-- A8. Default privileges of postgres that still grant to anon / authenticated.
-- Expected: 0 rows.
SELECT d.defaclnamespace::regnamespace AS schema, d.defaclobjtype AS objtype,
       e.grantee::regrole AS grantee, e.privilege_type
FROM pg_default_acl d, aclexplode(d.defaclacl) e
WHERE d.defaclrole = 'postgres'::regrole
  AND e.grantee IN ('anon'::regrole::oid, 'authenticated'::regrole::oid);

-- A9. Do new functions created by postgres still get PUBLIC EXECUTE?
-- Expected: 1 row, false.
SELECT EXISTS (
    SELECT 1
    FROM aclexplode(COALESCE(
             (SELECT defaclacl FROM pg_default_acl
              WHERE defaclrole = 'postgres'::regrole
                AND defaclnamespace = 0 AND defaclobjtype = 'f'),
             acldefault('f', 'postgres'::regrole))) e
    WHERE e.grantee = 0) AS new_functions_public_execute;

-- A10. Rollback snapshot is in place and not readable by the API roles.
-- Expected: 1 row, rows > 0, anon_can_read = false, authenticated_can_read = false.
SELECT count(*) AS rows,
       has_table_privilege('anon', 'migration_backup.m0003_pre_lockdown', 'SELECT') AS anon_can_read,
       has_table_privilege('authenticated', 'migration_backup.m0003_pre_lockdown', 'SELECT') AS authenticated_can_read
FROM migration_backup.m0003_pre_lockdown;


-- =============================================================================
-- PART B — behaviour as anon and authenticated
-- =============================================================================
-- Results go into a transaction-local setting and are printed at the end.
--   expected "permission denied": blocked by a missing GRANT (what 0003 does)
--   actual   "blocked by RLS":    the GRANT is still there and only RLS saved
--                                it, so the lockdown did NOT apply (FAIL)
--   actual   "denied: <message>": refused for another reason (FAIL; read it)
--   actual   "allowed":           the statement ran (FAIL for a write)

-- B0. Pick the employee to impersonate (still as postgres).
-- Expected: one row with a uuid in each column (empty if no active employee).
WITH pick AS (
    SELECT e.auth_id::text AS auth_id, e.organization_id::text AS org_id
    FROM public.employees e
    WHERE e.is_active AND e.auth_id IS NOT NULL
    ORDER BY e.created_at, e.id
    LIMIT 1
)
SELECT set_config('verify.auth_id', COALESCE((SELECT auth_id FROM pick), ''), true) AS auth_id,
       set_config('verify.org_id',  COALESCE((SELECT org_id  FROM pick), ''), true) AS org_id,
       set_config('verify.results', '', true)                                      AS results_reset;


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
            ('B1.07', 'anon: SELECT organizations',         'SELECT 1 FROM public.organizations LIMIT 1'),
            ('B1.08', 'anon: SELECT payments',              'SELECT 1 FROM public.payments LIMIT 1'),
            ('B1.09', 'anon: UPDATE plans (prices)',        'UPDATE public.plans SET monthly_price_egp = 0 WHERE false'),
            ('B1.10', 'anon: INSERT plans',                 'INSERT INTO public.plans DEFAULT VALUES'),
            ('B1.11', 'anon: EXECUTE activate_workspace',   'SELECT public.activate_workspace(''X'', ''00000000-0000-0000-0000-000000000000''::uuid, ''x'')'),
            ('B1.12', 'anon: EXECUTE current_user_org_id',  'SELECT public.current_user_org_id()'),
            ('B1.13', 'anon: EXECUTE egp_to_piasters',      'SELECT public.egp_to_piasters(1)')
        ) AS t(id, label, stmt)
    LOOP
        BEGIN
            EXECUTE c.stmt;
            v_actual := 'allowed';
        EXCEPTION
            WHEN insufficient_privilege THEN
                v_actual := CASE
                    WHEN SQLERRM LIKE 'permission denied%'      THEN 'permission denied'
                    WHEN SQLERRM LIKE '%row-level security%'    THEN 'blocked by RLS'
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
-- B2. As authenticated (a real employee's JWT, the way the Web app's token
--     reaches PostgREST). Literal form from the Supabase docs:
--       set local role authenticated;
--       set local request.jwt.claims to '{"sub":"<auth uuid>","role":"authenticated"}';
--     set_config(..., true) below is the same SET LOCAL, filled from B0.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
                  json_build_object('sub',  NULLIF(current_setting('verify.auth_id'), ''),
                                    'role', 'authenticated')::text,
                  true) AS jwt_claims;

-- B2a. Writes and RPCs that must be denied.
DO $$
DECLARE
    c        record;
    v_actual text;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            ('B2.01', 'auth: UPDATE employees (self-promote)',  'UPDATE public.employees SET role = ''OWNER'' WHERE false'),
            ('B2.02', 'auth: INSERT payments',                  'INSERT INTO public.payments DEFAULT VALUES'),
            ('B2.03', 'auth: DELETE payments',                  'DELETE FROM public.payments WHERE false'),
            ('B2.04', 'auth: DELETE vault_transactions',        'DELETE FROM public.vault_transactions WHERE false'),
            ('B2.05', 'auth: DELETE wallet_transactions',       'DELETE FROM public.wallet_transactions WHERE false'),
            ('B2.06', 'auth: DELETE inventory_transactions',    'DELETE FROM public.inventory_transactions WHERE false'),
            ('B2.07', 'auth: DELETE payment_installment_applications', 'DELETE FROM public.payment_installment_applications WHERE false'),
            ('B2.08', 'auth: DELETE installment_events',        'DELETE FROM public.installment_events WHERE false'),
            ('B2.09', 'auth: DELETE partner_transactions',      'DELETE FROM public.partner_transactions WHERE false'),
            ('B2.10', 'auth: DELETE product_cost_log',          'DELETE FROM public.product_cost_log WHERE false'),
            ('B2.11', 'auth: UPDATE organizations (unsuspend)', 'UPDATE public.organizations SET is_suspended = false WHERE false'),
            ('B2.12', 'auth: UPDATE plans',                     'UPDATE public.plans SET max_users = 9999 WHERE false'),
            ('B2.13', 'auth: INSERT audit_logs (forge)',        'INSERT INTO public.audit_logs DEFAULT VALUES'),
            ('B2.14', 'auth: EXECUTE activate_workspace',       'SELECT public.activate_workspace(''X'', ''00000000-0000-0000-0000-000000000000''::uuid, ''x'')'),
            ('B2.15', 'auth: EXECUTE is_owner',                 'SELECT public.is_owner()'),
            ('B2.16', 'auth: EXECUTE current_role',             'SELECT public."current_role"()'),
            ('B2.17', 'auth: EXECUTE current_employee_id',      'SELECT public.current_employee_id()')
        ) AS t(id, label, stmt)
    LOOP
        BEGIN
            EXECUTE c.stmt;
            v_actual := 'allowed';
        EXCEPTION
            WHEN insufficient_privilege THEN
                v_actual := CASE
                    WHEN SQLERRM LIKE 'permission denied%'      THEN 'permission denied'
                    WHEN SQLERRM LIKE '%row-level security%'    THEN 'blocked by RLS'
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

-- B2b. Reads the API (and RLS) still need. Each returns one value.
DO $$
DECLARE
    c        record;
    v_actual text;
    v_has_employee boolean := current_setting('verify.auth_id') <> '';
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            ('B3.01', 'auth: SELECT own employees row (attachEmployee)', true,
             'SELECT count(*)::text FROM public.employees WHERE auth_id = auth.uid()', '1'),
            ('B3.02', 'auth: current_user_org_id() = own org', true,
             'SELECT (public.current_user_org_id()::text = current_setting(''verify.org_id''))::text', 'true'),
            ('B3.03', 'auth: other orgs'' employees visible', true,
             'SELECT count(*)::text FROM public.employees WHERE organization_id::text <> current_setting(''verify.org_id'')', '0'),
            ('B3.04', 'auth: other orgs'' rows in vault_balances', true,
             'SELECT count(*)::text FROM public.vault_balances WHERE organization_id::text <> current_setting(''verify.org_id'')', '0'),
            ('B3.05', 'auth: other orgs'' rows in wallet_balances', true,
             'SELECT count(*)::text FROM public.wallet_balances WHERE organization_id::text <> current_setting(''verify.org_id'')', '0'),
            ('B3.06', 'auth: other orgs'' rows in installment_balances', true,
             'SELECT count(*)::text FROM public.installment_balances WHERE organization_id::text <> current_setting(''verify.org_id'')', '0'),
            ('B3.07', 'auth: other orgs'' rows in contract_balances', true,
             'SELECT count(*)::text FROM public.contract_balances WHERE organization_id::text <> current_setting(''verify.org_id'')', '0'),
            ('B3.08', 'auth: other orgs visible in organizations', true,
             'SELECT count(*)::text FROM public.organizations WHERE id::text <> current_setting(''verify.org_id'')', '0'),
            ('B3.09', 'auth: SELECT super_admins (loadSuperAdmin query runs)', false,
             'SELECT (count(*) >= 0)::text FROM public.super_admins WHERE auth_user_id = auth.uid()', 'true'),
            ('B3.10', 'auth: EXECUTE is_super_admin() (policy helper)', false,
             'SELECT (public.is_super_admin() IS NOT NULL)::text', 'true'),
            ('B3.11', 'auth: SELECT plans (plans_read policy)', false,
             'SELECT (count(*) >= 0)::text FROM public.plans', 'true')
        ) AS t(id, label, needs_employee, stmt, expected)
    LOOP
        IF c.needs_employee AND NOT v_has_employee THEN
            v_actual := 'SKIP (no active employee to impersonate)';
        ELSE
            BEGIN
                EXECUTE c.stmt INTO v_actual;
            EXCEPTION
                WHEN insufficient_privilege THEN
                    v_actual := CASE
                        WHEN SQLERRM LIKE 'permission denied%'   THEN 'permission denied'
                        WHEN SQLERRM LIKE '%row-level security%' THEN 'blocked by RLS'
                        ELSE 'denied: ' || SQLERRM END;
                WHEN OTHERS THEN
                    v_actual := 'error ' || SQLSTATE || ': ' || SQLERRM;
            END;
        END IF;
        PERFORM set_config('verify.results',
            current_setting('verify.results')
            || format(E'%s\t%s\t%s\t%s\n', c.id, c.label, c.expected, v_actual),
            true);
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- Results. Expected: every row PASS (SKIP only when no employee exists).
-- -----------------------------------------------------------------------------
RESET ROLE;

SELECT split_part(line, E'\t', 1) AS id,
       split_part(line, E'\t', 2) AS check_name,
       split_part(line, E'\t', 3) AS expected,
       split_part(line, E'\t', 4) AS actual,
       CASE
           WHEN split_part(line, E'\t', 4) LIKE 'SKIP%'                          THEN 'SKIP'
           WHEN split_part(line, E'\t', 3) = split_part(line, E'\t', 4)          THEN 'PASS'
           ELSE 'FAIL'
       END AS result
FROM unnest(string_to_array(rtrim(current_setting('verify.results'), E'\n'), E'\n')) AS line
ORDER BY 1;

ROLLBACK;
