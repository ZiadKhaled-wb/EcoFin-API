-- F06 roles and permissions (migration 20261003100000_f06_permissions.sql). LOCAL / DEV ONLY.
-- Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f06_permissions_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
--   1. every one of the 61 keys: a role without it (no override) -> PERMISSION_DENIED from
--      app.require_permission; an override granted=true gives it; an override granted=false
--      removes a role default; OWNER always has it
--   2. set_employee_permission / set_employee_branches: no employee.manage, other shop, empty
--      reason, owner and self targets refused; each successful call writes exactly one audit row
--   3. public.my_permissions()
--   4. grants
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

CREATE FUNCTION t.as_user(p_sub text, p_org text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.sub', COALESCE(p_sub, ''), false),
           set_config('request.headers',
                      CASE WHEN p_org IS NULL THEN '{}' ELSE json_build_object('x-org-id', p_org)::text END,
                      false);
$$;

-- Read as the test owner (postgres), callable while the session runs as authenticated.
CREATE FUNCTION t.audit_rows(p_entity uuid, p_action text) RETURNS integer
LANGUAGE sql SECURITY DEFINER AS $$
    SELECT count(*)::integer FROM public.audit_log WHERE entity_id = p_entity AND action = p_action
$$;
CREATE FUNCTION t.last_audit(p_entity uuid, p_action text) RETURNS public.audit_log
LANGUAGE sql SECURITY DEFINER AS $$
    SELECT * FROM public.audit_log WHERE entity_id = p_entity AND action = p_action ORDER BY id DESC LIMIT 1
$$;
CREATE FUNCTION t.override(p_employee uuid, p_key text) RETURNS boolean
LANGUAGE sql SECURITY DEFINER AS $$
    SELECT granted FROM public.employee_permission_overrides WHERE employee_id = p_employee AND permission_key = p_key
$$;
CREATE FUNCTION t.branches_of(p_employee uuid) RETURNS uuid[]
LANGUAGE sql SECURITY DEFINER AS $$
    SELECT COALESCE(array_agg(branch_id ORDER BY branch_id), '{}') FROM public.employee_branches WHERE employee_id = p_employee
$$;

GRANT USAGE ON SCHEMA t TO authenticated, anon, service_role;
GRANT INSERT ON t.results TO authenticated, anon, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated, anon, service_role;

-- ---------------------------------------------------------------- fixtures
--   shop A: owner a; one employee per non-owner role (r_<role>); cashier c (setter target);
--           branch manager g with an employee.manage override (a non-owner manager)
--   shop B: owner b, cashier y (another shop's target)
INSERT INTO auth.users (id, email) VALUES
  ('f6000000-0000-0000-0000-0000000000a1', 'f6-a@x'),
  ('f6000000-0000-0000-0000-0000000000b1', 'f6-b@x'),
  ('f6000000-0000-0000-0000-0000000000c1', 'f6-c@x'),
  ('f6000000-0000-0000-0000-0000000000c2', 'f6-g@x'),
  ('f6000000-0000-0000-0000-0000000000c3', 'f6-y@x'),
  ('f6000000-0000-0000-0000-000000000011', 'f6-bm@x'),
  ('f6000000-0000-0000-0000-000000000012', 'f6-ca@x'),
  ('f6000000-0000-0000-0000-000000000013', 'f6-wh@x'),
  ('f6000000-0000-0000-0000-000000000014', 'f6-co@x'),
  ('f6000000-0000-0000-0000-000000000015', 'f6-ac@x'),
  ('f6000000-0000-0000-0000-000000000016', 'f6-la@x');

INSERT INTO organizations (id, tenant_slug, name, plan_key, status) VALUES
  ('f6100000-0000-0000-0000-00000000000a', 'f6-shop-a', 'F6 Shop A', 'retail', 'active'),
  ('f6100000-0000-0000-0000-00000000000b', 'f6-shop-b', 'F6 Shop B', 'retail', 'active');

INSERT INTO branches (id, organization_id, code, name, is_main) VALUES
  ('f6200000-0000-0000-0000-0000000000a1', 'f6100000-0000-0000-0000-00000000000a', 'BR1', 'A main', true),
  ('f6200000-0000-0000-0000-0000000000a2', 'f6100000-0000-0000-0000-00000000000a', 'BR2', 'A second', false),
  ('f6200000-0000-0000-0000-0000000000b1', 'f6100000-0000-0000-0000-00000000000b', 'BR1', 'B main', true);

INSERT INTO employees (id, organization_id, auth_user_id, full_name, role) VALUES
  ('f6300000-0000-0000-0000-0000000000a1', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-0000000000a1', 'A owner', 'OWNER'),
  ('f6300000-0000-0000-0000-0000000000b1', 'f6100000-0000-0000-0000-00000000000b', 'f6000000-0000-0000-0000-0000000000b1', 'B owner', 'OWNER'),
  ('f6300000-0000-0000-0000-0000000000c1', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-0000000000c1', 'A cashier', 'CASHIER'),
  ('f6300000-0000-0000-0000-0000000000c2', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-0000000000c2', 'A manager', 'BRANCH_MANAGER'),
  ('f6300000-0000-0000-0000-0000000000c3', 'f6100000-0000-0000-0000-00000000000b', 'f6000000-0000-0000-0000-0000000000c3', 'B cashier', 'CASHIER'),
  ('f6300000-0000-0000-0000-000000000011', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-000000000011', 'r BRANCH_MANAGER', 'BRANCH_MANAGER'),
  ('f6300000-0000-0000-0000-000000000012', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-000000000012', 'r CASHIER', 'CASHIER'),
  ('f6300000-0000-0000-0000-000000000013', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-000000000013', 'r WAREHOUSE', 'WAREHOUSE'),
  ('f6300000-0000-0000-0000-000000000014', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-000000000014', 'r COLLECTOR', 'COLLECTOR'),
  ('f6300000-0000-0000-0000-000000000015', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-000000000015', 'r ACCOUNTANT', 'ACCOUNTANT'),
  ('f6300000-0000-0000-0000-000000000016', 'f6100000-0000-0000-0000-00000000000a', 'f6000000-0000-0000-0000-000000000016', 'r LAWYER', 'LAWYER');

INSERT INTO employee_permission_overrides (organization_id, employee_id, permission_key, granted) VALUES
  ('f6100000-0000-0000-0000-00000000000a', 'f6300000-0000-0000-0000-0000000000c2', 'employee.manage', true);
INSERT INTO employee_branches (organization_id, employee_id, branch_id) VALUES
  ('f6100000-0000-0000-0000-00000000000a', 'f6300000-0000-0000-0000-0000000000c1', 'f6200000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------- 1. every key (as postgres)
-- app.require_permission is only called from inside SECURITY DEFINER functions, so it isn't
-- granted to authenticated; the JWT claims alone decide who the caller is.
SELECT t.expect('there are 61 permission keys', (SELECT count(*) FROM public.permissions) = 61,
                (SELECT count(*)::text FROM public.permissions));

DO $$
DECLARE
    k record;
    v_lacking uuid;     -- an employee whose role lacks the key
    v_having  uuid;     -- a non-owner employee whose role has it by default
    v_sub     text;
    v_denied  int := 0; v_granted int := 0; v_removed int := 0; v_owner int := 0;
    v_no_default int := 0;
    v_fail    text := '';
BEGIN
    FOR k IN SELECT p.key FROM public.permissions p ORDER BY p.key LOOP
        SELECT e.id INTO v_lacking FROM public.employees e
        WHERE e.organization_id = 'f6100000-0000-0000-0000-00000000000a'
          AND e.full_name LIKE 'r %'
          AND NOT EXISTS (SELECT 1 FROM public.role_permissions rp WHERE rp.role = e.role AND rp.permission_key = k.key)
        ORDER BY e.id LIMIT 1;
        SELECT e.id INTO v_having FROM public.employees e
        WHERE e.organization_id = 'f6100000-0000-0000-0000-00000000000a' AND e.full_name LIKE 'r %'
          AND EXISTS (SELECT 1 FROM public.role_permissions rp WHERE rp.role = e.role AND rp.permission_key = k.key)
        ORDER BY e.id LIMIT 1;

        -- a) lacking role, no override -> PERMISSION_DENIED
        IF v_lacking IS NULL THEN
            v_fail := v_fail || k.key || ' (every role has it) ';
        ELSE
            SELECT auth_user_id::text INTO v_sub FROM public.employees WHERE id = v_lacking;
            PERFORM t.as_user(v_sub);
            BEGIN
                PERFORM app.require_permission(k.key);
                v_fail := v_fail || k.key || ' (not denied) ';
            EXCEPTION WHEN others THEN
                IF SQLERRM = 'PERMISSION_DENIED: ' || k.key THEN v_denied := v_denied + 1;
                ELSE v_fail := v_fail || k.key || ' (' || SQLERRM || ') '; END IF;
            END;
            -- b) override granted=true gives it
            INSERT INTO public.employee_permission_overrides (organization_id, employee_id, permission_key, granted)
            VALUES ('f6100000-0000-0000-0000-00000000000a', v_lacking, k.key, true);
            BEGIN
                IF app.require_permission(k.key) = v_lacking THEN v_granted := v_granted + 1; END IF;
            EXCEPTION WHEN others THEN
                v_fail := v_fail || k.key || ' (override true: ' || SQLERRM || ') ';
            END;
            DELETE FROM public.employee_permission_overrides WHERE employee_id = v_lacking AND permission_key = k.key;
        END IF;

        -- c) override granted=false removes a role default
        IF v_having IS NULL THEN
            v_no_default := v_no_default + 1;      -- only the owner has this key
        ELSE
            SELECT auth_user_id::text INTO v_sub FROM public.employees WHERE id = v_having;
            PERFORM t.as_user(v_sub);
            INSERT INTO public.employee_permission_overrides (organization_id, employee_id, permission_key, granted)
            VALUES ('f6100000-0000-0000-0000-00000000000a', v_having, k.key, false);
            BEGIN
                PERFORM app.require_permission(k.key);
                v_fail := v_fail || k.key || ' (default not removed) ';
            EXCEPTION WHEN others THEN
                IF SQLERRM = 'PERMISSION_DENIED: ' || k.key THEN v_removed := v_removed + 1;
                ELSE v_fail := v_fail || k.key || ' (' || SQLERRM || ') '; END IF;
            END;
            DELETE FROM public.employee_permission_overrides WHERE employee_id = v_having AND permission_key = k.key;
        END IF;

        -- d) OWNER always has it, even with an override saying no
        PERFORM t.as_user('f6000000-0000-0000-0000-0000000000a1');
        INSERT INTO public.employee_permission_overrides (organization_id, employee_id, permission_key, granted)
        VALUES ('f6100000-0000-0000-0000-00000000000a', 'f6300000-0000-0000-0000-0000000000a1', k.key, false);
        BEGIN
            IF app.require_permission(k.key) = 'f6300000-0000-0000-0000-0000000000a1' THEN v_owner := v_owner + 1; END IF;
        EXCEPTION WHEN others THEN
            v_fail := v_fail || k.key || ' (owner: ' || SQLERRM || ') ';
        END;
        DELETE FROM public.employee_permission_overrides
        WHERE employee_id = 'f6300000-0000-0000-0000-0000000000a1' AND permission_key = k.key;
    END LOOP;

    PERFORM t.expect('keys: a role without the key (no override) gets PERMISSION_DENIED, all 61', v_denied = 61, format('%s, failures: %s', v_denied, v_fail));
    PERFORM t.expect('keys: an override granted=true gives the key, all 61', v_granted = 61, format('%s', v_granted));
    PERFORM t.expect('keys: an override granted=false removes every non-owner role default',
                     v_removed + v_no_default = 61 AND v_removed > 0, format('removed %s, owner-only keys %s', v_removed, v_no_default));
    PERFORM t.expect('keys: OWNER has all 61, whatever the overrides say', v_owner = 61, format('%s', v_owner));
    PERFORM t.expect('keys: no unexpected error', v_fail = '', v_fail);
END $$;

-- ---------------------------------------------------------------- 2. setters (as authenticated)
SET ROLE authenticated;

-- 2a. without employee.manage
SELECT t.as_user('f6000000-0000-0000-0000-0000000000c1');   -- cashier
SELECT t.expect_error('set_employee_permission without employee.manage -> PERMISSION_DENIED',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-000000000012', 'sale.void', true, 'x')$q$,
    '^PERMISSION_DENIED: employee\.manage$');
SELECT t.expect_error('set_employee_branches without employee.manage -> PERMISSION_DENIED',
    $q$SELECT public.set_employee_branches('f6300000-0000-0000-0000-000000000012', ARRAY['f6200000-0000-0000-0000-0000000000a1']::uuid[], 'x')$q$,
    '^PERMISSION_DENIED: employee\.manage$');

-- 2b. the owner grants a key the cashier role lacks
SELECT t.as_user('f6000000-0000-0000-0000-0000000000a1');
SELECT t.expect('setup: CASHIER lacks sale.void by default',
    NOT EXISTS (SELECT 1 FROM public.role_permissions WHERE role = 'CASHIER' AND permission_key = 'sale.void'));
SELECT t.expect('owner grants sale.void: returns the effective value',
    (SELECT granted FROM public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.void', true, '  cover the evening shift  ')) = true);
SELECT t.expect('grant: an override row granted=true', t.override('f6300000-0000-0000-0000-0000000000c1', 'sale.void') = true);
SELECT t.expect('grant: exactly one audit row', t.audit_rows('f6300000-0000-0000-0000-0000000000c1', 'employee.permission_set') = 1);
SELECT t.expect('grant: audit before/after, trimmed reason, actor, org',
    (SELECT a.before ->> 'effective' = 'false' AND a.after ->> 'effective' = 'true'
            AND a.after ->> 'override' = 'true' AND a.reason = 'cover the evening shift'
            AND a.employee_id = 'f6300000-0000-0000-0000-0000000000a1'
            AND a.organization_id = 'f6100000-0000-0000-0000-00000000000a'
     FROM t.last_audit('f6300000-0000-0000-0000-0000000000c1', 'employee.permission_set') a));

-- 2c. setting it back to the role default removes the override row (no redundant row)
SELECT t.expect('revoke back to the default: returns false',
    (SELECT granted FROM public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.void', false, 'shift over')) = false);
SELECT t.expect('revoke to default: the override row is gone', t.override('f6300000-0000-0000-0000-0000000000c1', 'sale.void') IS NULL);
SELECT t.expect('revoke to default: second audit row', t.audit_rows('f6300000-0000-0000-0000-0000000000c1', 'employee.permission_set') = 2);

-- 2d. removing a role default stores granted=false; granting it again deletes the row
SELECT t.expect('setup: CASHIER has sale.create by default',
    EXISTS (SELECT 1 FROM public.role_permissions WHERE role = 'CASHIER' AND permission_key = 'sale.create'));
SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.create', false, 'training');
SELECT t.expect('remove a default: override granted=false', t.override('f6300000-0000-0000-0000-0000000000c1', 'sale.create') = false);
SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.create', true, 'trained');
SELECT t.expect('give the default back: no override row', t.override('f6300000-0000-0000-0000-0000000000c1', 'sale.create') IS NULL);
SELECT t.expect('four successful calls, four audit rows', t.audit_rows('f6300000-0000-0000-0000-0000000000c1', 'employee.permission_set') = 4);

-- 2e. refusals (and none of them writes an audit row)
SELECT t.expect_error('empty reason -> VALIDATION_FAILED',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.void', true, '')$q$, '^VALIDATION_FAILED');
SELECT t.expect_error('blank reason -> VALIDATION_FAILED',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.void', true, '   ')$q$, '^VALIDATION_FAILED');
SELECT t.expect_error('null reason -> VALIDATION_FAILED',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.void', true, NULL)$q$, '^VALIDATION_FAILED');
SELECT t.expect_error('a reason over 500 characters -> VALIDATION_FAILED',
    format($q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.void', true, %L)$q$, repeat('x', 501)), '^VALIDATION_FAILED');
SELECT t.expect_error('unknown key -> VALIDATION_FAILED',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'sale.nope', true, 'x')$q$, '^VALIDATION_FAILED');
SELECT t.expect_error('another shop''s employee -> NOT_FOUND',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c3', 'sale.void', true, 'x')$q$, '^NOT_FOUND');
SELECT t.expect_error('a non-existent employee -> NOT_FOUND',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000ff', 'sale.void', true, 'x')$q$, '^NOT_FOUND');
SELECT t.expect_error('the owner''s permissions -> FORBIDDEN',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000a1', 'sale.void', false, 'x')$q$, '^FORBIDDEN');
SELECT t.expect('refusals wrote no audit row', t.audit_rows('f6300000-0000-0000-0000-0000000000c1', 'employee.permission_set') = 4);

-- 2f. a non-owner with an employee.manage override can manage others, not themselves
SELECT t.as_user('f6000000-0000-0000-0000-0000000000c2');
SELECT t.expect('manager with employee.manage changes the cashier',
    (SELECT granted FROM public.set_employee_permission('f6300000-0000-0000-0000-0000000000c1', 'refund.create', true, 'returns desk')) = true);
SELECT t.expect_error('own permissions -> FORBIDDEN',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c2', 'cash.adjust', true, 'x')$q$, '^FORBIDDEN');
SELECT t.expect_error('own branches -> FORBIDDEN',
    $q$SELECT public.set_employee_branches('f6300000-0000-0000-0000-0000000000c2', ARRAY['f6200000-0000-0000-0000-0000000000a2']::uuid[], 'x')$q$, '^FORBIDDEN');
SELECT t.expect_error('the owner''s branches -> FORBIDDEN',
    $q$SELECT public.set_employee_branches('f6300000-0000-0000-0000-0000000000a1', ARRAY['f6200000-0000-0000-0000-0000000000a2']::uuid[], 'x')$q$, '^FORBIDDEN');

-- 2g. branches
SELECT t.as_user('f6000000-0000-0000-0000-0000000000a1');
SELECT t.expect('owner sets the cashier to A1 + A2 (duplicates collapse)',
    (SELECT branch_ids FROM public.set_employee_branches('f6300000-0000-0000-0000-0000000000c1',
        ARRAY['f6200000-0000-0000-0000-0000000000a2', 'f6200000-0000-0000-0000-0000000000a1', 'f6200000-0000-0000-0000-0000000000a2']::uuid[], 'opening BR2'))
    = ARRAY['f6200000-0000-0000-0000-0000000000a1', 'f6200000-0000-0000-0000-0000000000a2']::uuid[]);
SELECT t.expect('branches: rows replaced',
    t.branches_of('f6300000-0000-0000-0000-0000000000c1') = ARRAY['f6200000-0000-0000-0000-0000000000a1', 'f6200000-0000-0000-0000-0000000000a2']::uuid[]);
SELECT t.expect('branches: one audit row with before/after and the reason',
    t.audit_rows('f6300000-0000-0000-0000-0000000000c1', 'employee.branches_set') = 1
    AND (SELECT a.before -> 'branch_ids' = '["f6200000-0000-0000-0000-0000000000a1"]'::jsonb
                AND a.after -> 'branch_ids' = '["f6200000-0000-0000-0000-0000000000a1", "f6200000-0000-0000-0000-0000000000a2"]'::jsonb
                AND a.reason = 'opening BR2'
         FROM t.last_audit('f6300000-0000-0000-0000-0000000000c1', 'employee.branches_set') a));
SELECT t.expect_error('another shop''s branch -> BRANCH_NOT_IN_ORG',
    $q$SELECT public.set_employee_branches('f6300000-0000-0000-0000-0000000000c1', ARRAY['f6200000-0000-0000-0000-0000000000a1', 'f6200000-0000-0000-0000-0000000000b1']::uuid[], 'x')$q$,
    '^BRANCH_NOT_IN_ORG');
SELECT t.expect_error('a non-existent branch -> BRANCH_NOT_IN_ORG',
    $q$SELECT public.set_employee_branches('f6300000-0000-0000-0000-0000000000c1', ARRAY['f6200000-0000-0000-0000-0000000000ff']::uuid[], 'x')$q$,
    '^BRANCH_NOT_IN_ORG');
SELECT t.expect_error('branches: another shop''s employee -> NOT_FOUND',
    $q$SELECT public.set_employee_branches('f6300000-0000-0000-0000-0000000000c3', ARRAY[]::uuid[], 'x')$q$, '^NOT_FOUND');
SELECT t.expect_error('branches: empty reason -> VALIDATION_FAILED',
    $q$SELECT public.set_employee_branches('f6300000-0000-0000-0000-0000000000c1', ARRAY[]::uuid[], ' ')$q$, '^VALIDATION_FAILED');
SELECT t.expect('branches: refusals left the rows and wrote no audit row',
    t.branches_of('f6300000-0000-0000-0000-0000000000c1') = ARRAY['f6200000-0000-0000-0000-0000000000a1', 'f6200000-0000-0000-0000-0000000000a2']::uuid[]
    AND t.audit_rows('f6300000-0000-0000-0000-0000000000c1', 'employee.branches_set') = 1);
SELECT public.set_employee_branches('f6300000-0000-0000-0000-0000000000c1', ARRAY[]::uuid[], 'moved to the warehouse');
SELECT t.expect('branches: an empty list removes every branch', t.branches_of('f6300000-0000-0000-0000-0000000000c1') = '{}'::uuid[]);
SELECT t.expect('branches: second audit row', t.audit_rows('f6300000-0000-0000-0000-0000000000c1', 'employee.branches_set') = 2);

-- 2h. the owner of shop A pointing at shop B (x-org-id) is not an employee there
SELECT t.as_user('f6000000-0000-0000-0000-0000000000a1', 'f6100000-0000-0000-0000-00000000000b');
SELECT t.expect_error('owner A with x-org-id = B -> NOT_AN_EMPLOYEE',
    $q$SELECT public.set_employee_permission('f6300000-0000-0000-0000-0000000000c3', 'sale.void', true, 'x')$q$, '^NOT_AN_EMPLOYEE');

-- ---------------------------------------------------------------- 3. my_permissions()
SELECT t.as_user('f6000000-0000-0000-0000-0000000000a1');
SELECT t.expect('my_permissions: owner has all 61 keys and all branches',
    (SELECT cardinality(m.keys) = 61 AND m.all_branches
            AND m.branch_ids = ARRAY['f6200000-0000-0000-0000-0000000000a1', 'f6200000-0000-0000-0000-0000000000a2']::uuid[]
     FROM public.my_permissions() m));

SELECT t.as_user('f6000000-0000-0000-0000-0000000000c1');   -- cashier: default + refund.create, no branches now
SELECT t.expect('my_permissions: cashier = role defaults + the refund.create override',
    (SELECT m.keys = ARRAY(SELECT k FROM (SELECT rp.permission_key AS k FROM public.role_permissions rp WHERE rp.role = 'CASHIER'
                                          UNION SELECT 'refund.create') s ORDER BY k)
            AND NOT m.all_branches AND m.branch_ids = '{}'::uuid[]
     FROM public.my_permissions() m));
SELECT t.as_user('f6000000-0000-0000-0000-000000000016');   -- lawyer, nothing changed
SELECT t.expect('my_permissions: lawyer = exactly the role defaults',
    (SELECT m.keys = ARRAY(SELECT rp.permission_key FROM public.role_permissions rp WHERE rp.role = 'LAWYER' ORDER BY 1)
     FROM public.my_permissions() m));
SELECT t.as_user('f6000000-0000-0000-0000-0000000000a1', 'f6100000-0000-0000-0000-00000000000b');
SELECT t.expect_error('my_permissions: not an employee of the requested shop -> NOT_AN_EMPLOYEE',
    $q$SELECT * FROM public.my_permissions()$q$, '^NOT_AN_EMPLOYEE');
SELECT t.as_user(NULL);
RESET ROLE;

-- ---------------------------------------------------------------- 4. grants
SELECT t.expect('grants: authenticated may execute the three functions',
    has_function_privilege('authenticated', 'public.my_permissions()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.set_employee_permission(uuid, text, boolean, text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.set_employee_branches(uuid, uuid[], text)', 'EXECUTE'));
SELECT t.expect('grants: anon may execute none of them',
    NOT has_function_privilege('anon', 'public.my_permissions()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.set_employee_permission(uuid, text, boolean, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.set_employee_branches(uuid, uuid[], text)', 'EXECUTE'));
SELECT t.expect('grants: the internal helper is not callable by authenticated or anon',
    NOT has_function_privilege('authenticated', 'app.lock_managed_employee(uuid, uuid, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'app.lock_managed_employee(uuid, uuid, text)', 'EXECUTE'));
SELECT t.expect('grants: still no table writes for authenticated on the access tables',
    NOT has_table_privilege('authenticated', 'public.employee_permission_overrides', 'INSERT, UPDATE, DELETE')
    AND NOT has_table_privilege('authenticated', 'public.employee_branches', 'INSERT, UPDATE, DELETE'));

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
