-- EC-143 deactivate / reactivate an employee (migration 20261006110000_ec143_set_employee_active.sql).
-- LOCAL / DEV ONLY. Run after `npm run db:reset` (uses the dev seed shop A):
--   npm run db:smoke -- supabase/tests/ec143_employee_active_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
-- Permission denial and the cross-shop case are in tenant_and_permission_test.sql (4.x, 3.10).
--   1. refusals: no reason, the owner as target, the caller themself (a manager), active = NULL
--   2. deactivate: is_active false, exactly one audit row with before/after and the reason;
--      the employee's session is refused at once (session_context: disabled)
--   3. reactivate: is_active true, a second audit row, the session works again
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE SCHEMA t;
CREATE TABLE t.results (name text, ok boolean, detail text);

CREATE FUNCTION t.expect(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
    INSERT INTO t.results VALUES (p_name, p_ok, p_detail);
$$;

CREATE FUNCTION t.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN '';
EXCEPTION WHEN others THEN
    RETURN SQLERRM;
END $$;

CREATE FUNCTION t.as_user(p_sub text) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.sub', COALESCE(p_sub, ''), false),
           set_config('request.headers', '{}', false);
$$;

-- session_context() as text: the refusal, or the role when the session is fine.
CREATE FUNCTION t.ctx() RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE('refusal=' || c.refusal, 'role=' || c.role) FROM public.session_context() c
$$;

CREATE TABLE t.r (name text PRIMARY KEY, val text);

GRANT USAGE ON SCHEMA t TO authenticated;
GRANT INSERT, SELECT ON t.results, t.r TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- Shop A (dev seed): owner auth d0..11 / emp d3..11; cashier auth d0..12 / emp d3..12.
-- A manager of shop A granted employee.manage, to test "not yourself".
INSERT INTO auth.users (id, email) VALUES ('e1430000-0000-0000-0000-0000000000a1', 'ec143.manager@x');
INSERT INTO public.employees (id, organization_id, auth_user_id, full_name, role, default_branch_id)
VALUES ('e1430000-0000-0000-0000-0000000000e1', 'd1000000-0000-0000-0000-000000000001',
        'e1430000-0000-0000-0000-0000000000a1', 'EC-143 manager', 'BRANCH_MANAGER', 'd2000000-0000-0000-0000-000000000011');
INSERT INTO public.employee_branches (organization_id, employee_id, branch_id)
VALUES ('d1000000-0000-0000-0000-000000000001', 'e1430000-0000-0000-0000-0000000000e1', 'd2000000-0000-0000-0000-000000000011');
-- BRANCH_MANAGER doesn't hold employee.manage by default: grant it, so "not yourself" is what refuses.
INSERT INTO public.employee_permission_overrides (organization_id, employee_id, permission_key, granted)
VALUES ('d1000000-0000-0000-0000-000000000001', 'e1430000-0000-0000-0000-0000000000e1', 'employee.manage', true);

SET ROLE authenticated;

-- ---------------------------------------------------------------- 1. refusals
SELECT t.as_user('d0000000-0000-0000-0000-000000000011');
INSERT INTO t.r VALUES ('no_reason', t.try($$SELECT public.set_employee_active('d3000000-0000-0000-0000-000000000012', false, ' ')$$));
INSERT INTO t.r VALUES ('owner_target', t.try($$SELECT public.set_employee_active('d3000000-0000-0000-0000-000000000011', false, 'x')$$));
INSERT INTO t.r VALUES ('null_active', t.try($$SELECT public.set_employee_active('d3000000-0000-0000-0000-000000000012', NULL, 'x')$$));
SELECT t.as_user('e1430000-0000-0000-0000-0000000000a1');
INSERT INTO t.r VALUES ('self', t.try($$SELECT public.set_employee_active('e1430000-0000-0000-0000-0000000000e1', false, 'x')$$));

-- ---------------------------------------------------------------- 2. deactivate
SELECT t.as_user('d0000000-0000-0000-0000-000000000011');
INSERT INTO t.r VALUES ('off', t.try($$SELECT public.set_employee_active('d3000000-0000-0000-0000-000000000012', false, 'left the company')$$));
SELECT t.as_user('d0000000-0000-0000-0000-000000000012');
INSERT INTO t.r VALUES ('ctx_off', t.ctx());

-- ---------------------------------------------------------------- 3. reactivate
SELECT t.as_user('d0000000-0000-0000-0000-000000000011');
INSERT INTO t.r VALUES ('on', t.try($$SELECT public.set_employee_active('d3000000-0000-0000-0000-000000000012', true, 'came back')$$));
SELECT t.as_user('d0000000-0000-0000-0000-000000000012');
INSERT INTO t.r VALUES ('ctx_on', t.ctx());
SELECT t.as_user(NULL);
RESET ROLE;

SELECT t.expect('1.1 no reason -> VALIDATION_FAILED', (SELECT val FROM t.r WHERE name = 'no_reason') ~ 'VALIDATION_FAILED',
    (SELECT val FROM t.r WHERE name = 'no_reason'));
SELECT t.expect('1.2 the owner as target -> FORBIDDEN', (SELECT val FROM t.r WHERE name = 'owner_target') ~ 'FORBIDDEN',
    (SELECT val FROM t.r WHERE name = 'owner_target'));
SELECT t.expect('1.3 active = NULL -> VALIDATION_FAILED', (SELECT val FROM t.r WHERE name = 'null_active') ~ 'VALIDATION_FAILED',
    (SELECT val FROM t.r WHERE name = 'null_active'));
SELECT t.expect('1.4 a manager deactivating themself -> FORBIDDEN', (SELECT val FROM t.r WHERE name = 'self') ~ 'FORBIDDEN',
    (SELECT val FROM t.r WHERE name = 'self'));
SELECT t.expect('1.5 the refusals wrote no audit row and changed nobody',
    NOT EXISTS (SELECT 1 FROM audit_log WHERE action = 'employee.active_set' AND reason = 'x')
    AND (SELECT is_active FROM employees WHERE id = 'd3000000-0000-0000-0000-000000000011')
    AND (SELECT is_active FROM employees WHERE id = 'e1430000-0000-0000-0000-0000000000e1'));

SELECT t.expect('2.1 deactivate works', (SELECT val FROM t.r WHERE name = 'off') = '', (SELECT val FROM t.r WHERE name = 'off'));
SELECT t.expect('2.2 exactly one audit row: by the owner, before true / after false, with the reason',
    (SELECT count(*) FROM audit_log WHERE action = 'employee.active_set' AND entity_id = 'd3000000-0000-0000-0000-000000000012'
       AND reason = 'left the company' AND employee_id = 'd3000000-0000-0000-0000-000000000011'
       AND organization_id = 'd1000000-0000-0000-0000-000000000001'
       AND before = '{"is_active": true}'::jsonb AND after = '{"is_active": false}'::jsonb) = 1);
SELECT t.expect('2.3 the deactivated employee''s session is refused at once',
    (SELECT val FROM t.r WHERE name = 'ctx_off') ~ '^refusal=', (SELECT val FROM t.r WHERE name = 'ctx_off'));

SELECT t.expect('3.1 reactivate works and the employee is active again',
    (SELECT val FROM t.r WHERE name = 'on') = ''
    AND (SELECT is_active FROM employees WHERE id = 'd3000000-0000-0000-0000-000000000012'),
    (SELECT val FROM t.r WHERE name = 'on'));
SELECT t.expect('3.2 a second audit row (before false / after true)',
    (SELECT count(*) FROM audit_log WHERE action = 'employee.active_set' AND entity_id = 'd3000000-0000-0000-0000-000000000012'
       AND before = '{"is_active": false}'::jsonb AND after = '{"is_active": true}'::jsonb AND reason = 'came back') = 1);
SELECT t.expect('3.3 the session works again (CASHIER)', (SELECT val FROM t.r WHERE name = 'ctx_on') = 'role=CASHIER',
    (SELECT val FROM t.r WHERE name = 'ctx_on'));

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
