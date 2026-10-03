-- F04 auth functions (migration 20261003060000_f04_auth.sql). LOCAL / DEV ONLY.
-- Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f04_auth_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
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

GRANT USAGE ON SCHEMA t TO authenticated, anon, service_role;
GRANT INSERT ON t.results TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION t.expect(text, boolean, text), t.expect_error(text, text, text) TO authenticated, anon, service_role;

-- ---------------------------------------------------------------- fixtures
--   shop A (active), shop B (active), shop C (suspended), shop D (subscription ended)
--   user a: OWNER in A            user b: OWNER in B          user m: CASHIER in A + ACCOUNTANT in B
--   user d: disabled CASHIER in A user s: OWNER in C          user e: OWNER in D
--   user x: a login with no employee row
INSERT INTO auth.users (id, email) VALUES
  ('f4000000-0000-0000-0000-0000000000a1', 'f4-a@x'),
  ('f4000000-0000-0000-0000-0000000000b1', 'f4-b@x'),
  ('f4000000-0000-0000-0000-0000000000c1', 'f4-m@x'),
  ('f4000000-0000-0000-0000-0000000000d1', 'f4-d@x'),
  ('f4000000-0000-0000-0000-0000000000e1', 'f4-s@x'),
  ('f4000000-0000-0000-0000-0000000000f1', 'f4-e@x'),
  ('f4000000-0000-0000-0000-000000000001', 'f4-x@x');

INSERT INTO organizations (id, tenant_slug, name, plan_key, status, subscription_end) VALUES
  ('f4100000-0000-0000-0000-00000000000a', 'f4-shop-a', 'F4 Shop A', 'retail', 'active', NULL),
  ('f4100000-0000-0000-0000-00000000000b', 'f4-shop-b', 'F4 Shop B', 'retail', 'active', current_date + 30),
  ('f4100000-0000-0000-0000-00000000000c', 'f4-shop-c', 'F4 Shop C', 'retail', 'suspended', NULL),
  ('f4100000-0000-0000-0000-00000000000d', 'f4-shop-d', 'F4 Shop D', 'retail', 'active', current_date - 10);

INSERT INTO employees (id, organization_id, auth_user_id, full_name, role, is_active, must_change_password) VALUES
  ('f4300000-0000-0000-0000-0000000000a1', 'f4100000-0000-0000-0000-00000000000a', 'f4000000-0000-0000-0000-0000000000a1', 'A owner', 'OWNER', true, false),
  ('f4300000-0000-0000-0000-0000000000b1', 'f4100000-0000-0000-0000-00000000000b', 'f4000000-0000-0000-0000-0000000000b1', 'B owner', 'OWNER', true, false),
  ('f4300000-0000-0000-0000-0000000000ca', 'f4100000-0000-0000-0000-00000000000a', 'f4000000-0000-0000-0000-0000000000c1', 'M in A', 'CASHIER', true, true),
  ('f4300000-0000-0000-0000-0000000000cb', 'f4100000-0000-0000-0000-00000000000b', 'f4000000-0000-0000-0000-0000000000c1', 'M in B', 'ACCOUNTANT', true, true),
  ('f4300000-0000-0000-0000-0000000000d1', 'f4100000-0000-0000-0000-00000000000a', 'f4000000-0000-0000-0000-0000000000d1', 'D disabled', 'CASHIER', false, false),
  ('f4300000-0000-0000-0000-0000000000e1', 'f4100000-0000-0000-0000-00000000000c', 'f4000000-0000-0000-0000-0000000000e1', 'S owner', 'OWNER', true, false),
  ('f4300000-0000-0000-0000-0000000000f1', 'f4100000-0000-0000-0000-00000000000d', 'f4000000-0000-0000-0000-0000000000f1', 'E owner', 'OWNER', true, false);

-- ---------------------------------------------------------------- grants
SELECT t.expect('grant: anon cannot execute my_shops', NOT has_function_privilege('anon', 'public.my_shops()', 'EXECUTE'));
SELECT t.expect('grant: anon cannot execute auth_record_login', NOT has_function_privilege('anon', 'public.auth_record_login()', 'EXECUTE'));
SELECT t.expect('grant: anon cannot execute auth_record_logout', NOT has_function_privilege('anon', 'public.auth_record_logout()', 'EXECUTE'));
SELECT t.expect('grant: anon cannot execute auth_record_password_change', NOT has_function_privilege('anon', 'public.auth_record_password_change()', 'EXECUTE'));
SELECT t.expect('grant: authenticated can execute the four session functions',
    has_function_privilege('authenticated', 'public.my_shops()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.auth_record_login()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.auth_record_logout()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.auth_record_password_change()', 'EXECUTE'));
SELECT t.expect('grant (D24): only service_role can execute auth_clear_must_change_password',
    NOT has_function_privilege('authenticated', 'public.auth_clear_must_change_password(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.auth_clear_must_change_password(uuid)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.auth_clear_must_change_password(uuid)', 'EXECUTE'));
SELECT t.expect('grant: the old auth_password_changed() no longer exists',
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'auth_password_changed'));
SELECT t.expect('grant: authenticated cannot call app.require_session_employee directly',
    NOT has_function_privilege('authenticated', 'app.require_session_employee()', 'EXECUTE'));
SELECT t.expect('definer: every F04 function is SECURITY DEFINER with search_path pinned',
    (SELECT bool_and(p.prosecdef AND p.proconfig @> ARRAY['search_path=""'])
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE (n.nspname, p.proname) IN (('app', 'require_session_employee'), ('public', 'my_shops'),
           ('public', 'auth_record_login'), ('public', 'auth_record_logout'),
           ('public', 'auth_record_password_change'), ('public', 'auth_clear_must_change_password'))),
    (SELECT string_agg(p.proname || ':' || coalesce(array_to_string(p.proconfig, ','), 'null'), ' ')
     FROM pg_proc p WHERE p.proname IN ('require_session_employee', 'my_shops', 'auth_record_login')));

SET ROLE anon;
SELECT t.expect_error('no permission: anon calling my_shops is refused', 'SELECT * FROM public.my_shops()', 'permission denied');
SELECT t.expect_error('no permission: anon calling auth_record_login is refused', 'SELECT public.auth_record_login()', 'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------- my_shops
SET ROLE authenticated;
SELECT set_config('request.headers', '{}', false);

SELECT set_config('request.jwt.claim.sub', '', false);
SELECT t.expect('my_shops: no session returns nothing', (SELECT count(*) = 0 FROM public.my_shops()));

SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000a1', false);
SELECT t.expect('my_shops: user a sees only shop A',
    (SELECT array_agg(tenant_slug) = ARRAY['f4-shop-a'] FROM public.my_shops()));

SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000b1', false);
SELECT t.expect('my_shops: user b never sees shop A (another user''s data)',
    (SELECT count(*) = 1 AND bool_and(org_id = 'f4100000-0000-0000-0000-00000000000b') FROM public.my_shops()));

SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000c1', false);
SELECT t.expect('my_shops: user m sees both shops with the role in each',
    (SELECT array_agg(tenant_slug || ':' || role ORDER BY tenant_slug) = ARRAY['f4-shop-a:CASHIER', 'f4-shop-b:ACCOUNTANT'] FROM public.my_shops()));
SELECT set_config('request.headers', '{"x-org-id": "f4100000-0000-0000-0000-00000000000b"}', false);
SELECT t.expect('my_shops: x-org-id does not narrow or widen the list', (SELECT count(*) = 2 FROM public.my_shops()));
SELECT set_config('request.headers', '{}', false);

SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000d1', false);
SELECT t.expect('my_shops: a disabled employee gets nothing', (SELECT count(*) = 0 FROM public.my_shops()));
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000e1', false);
SELECT t.expect('my_shops: a suspended shop is not listed', (SELECT count(*) = 0 FROM public.my_shops()));
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000f1', false);
SELECT t.expect('my_shops: a shop with an ended subscription is not listed', (SELECT count(*) = 0 FROM public.my_shops()));
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-000000000001', false);
SELECT t.expect('my_shops: a login without employee rows gets nothing', (SELECT count(*) = 0 FROM public.my_shops()));

-- ---------------------------------------------------------------- auth_record_login
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000a1', false);
SELECT set_config('request.headers', '{"user-agent": "f4-test", "x-request-id": "f4-req-1", "x-forwarded-for": "203.0.113.7"}', false);
SELECT public.auth_record_login();
RESET ROLE;
SELECT t.expect('login: writes one auth.login audit row in shop A for employee a',
    (SELECT count(*) = 1 FROM audit_log WHERE action = 'auth.login'
       AND organization_id = 'f4100000-0000-0000-0000-00000000000a'
       AND employee_id = 'f4300000-0000-0000-0000-0000000000a1'
       AND entity_type = 'employee' AND entity_id = 'f4300000-0000-0000-0000-0000000000a1'));
SELECT t.expect('login: audit row carries ip, user agent and request id from the request headers',
    (SELECT count(*) = 1 FROM audit_log WHERE action = 'auth.login'
       AND employee_id = 'f4300000-0000-0000-0000-0000000000a1'
       AND ip = '203.0.113.7'::inet AND user_agent = 'f4-test' AND request_id = 'f4-req-1'));
SELECT t.expect('login: sets last_login_at',
    (SELECT last_login_at IS NOT NULL FROM employees WHERE id = 'f4300000-0000-0000-0000-0000000000a1'));
SELECT t.expect('login: other employees untouched',
    (SELECT count(*) = 0 FROM employees WHERE id <> 'f4300000-0000-0000-0000-0000000000a1'
       AND id::text LIKE 'f43%' AND last_login_at IS NOT NULL));
SET ROLE authenticated;

SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000c1', false);
SELECT set_config('request.headers', '{}', false);
SELECT t.expect_error('login: two shops and no x-org-id needs a shop selection',
    'SELECT public.auth_record_login()', '^SHOP_SELECTION_REQUIRED');
SELECT set_config('request.headers', '{"x-org-id": "f4100000-0000-0000-0000-00000000000b"}', false);
SELECT public.auth_record_login();
RESET ROLE;
SELECT t.expect('login: x-org-id of shop B writes the row in shop B for m''s shop-B employee',
    (SELECT count(*) = 1 FROM audit_log WHERE action = 'auth.login'
       AND organization_id = 'f4100000-0000-0000-0000-00000000000b'
       AND employee_id = 'f4300000-0000-0000-0000-0000000000cb'));
SELECT t.expect('login: nothing written to shop A for m',
    (SELECT count(*) = 0 FROM audit_log WHERE employee_id = 'f4300000-0000-0000-0000-0000000000ca'));
SET ROLE authenticated;

SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000a1', false);
SELECT set_config('request.headers', '{"x-org-id": "f4100000-0000-0000-0000-00000000000b"}', false);
SELECT t.expect_error('cross-shop: user a with x-org-id of shop B is refused',
    'SELECT public.auth_record_login()', '^SHOP_NOT_ALLOWED');
SELECT set_config('request.headers', '{"x-org-id": "not-a-uuid"}', false);
SELECT public.auth_record_login();   -- a malformed header is ignored: one membership, so shop A
SELECT set_config('request.headers', '{}', false);

SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000d1', false);
SELECT t.expect_error('login: a disabled employee is not an employee', 'SELECT public.auth_record_login()', '^NOT_AN_EMPLOYEE');
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-000000000001', false);
SELECT t.expect_error('login: a login without employee rows is refused', 'SELECT public.auth_record_login()', '^NOT_AN_EMPLOYEE');
SELECT set_config('request.jwt.claim.sub', '', false);
SELECT t.expect_error('login: no session is refused', 'SELECT public.auth_record_login()', '^NOT_AN_EMPLOYEE');
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000e1', false);
SELECT t.expect_error('login: a suspended shop is refused', 'SELECT public.auth_record_login()', '^SHOP_INACTIVE');
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000f1', false);
SELECT t.expect_error('login: an ended subscription is refused', 'SELECT public.auth_record_login()', '^SUBSCRIPTION_EXPIRED');
RESET ROLE;
SELECT t.expect('login: refused calls write no audit rows',
    (SELECT count(*) = 0 FROM audit_log WHERE organization_id IN
       ('f4100000-0000-0000-0000-00000000000c', 'f4100000-0000-0000-0000-00000000000d')));
SELECT t.expect('login: user a has two auth.login rows (normal + malformed header)',
    (SELECT count(*) = 2 FROM audit_log WHERE action = 'auth.login' AND employee_id = 'f4300000-0000-0000-0000-0000000000a1'));

-- ---------------------------------------------------------------- auth_record_logout
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000a1', false);
SELECT public.auth_record_logout();
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000e1', false);
SELECT public.auth_record_logout();   -- logout works even when the shop is suspended
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000c1', false);
SELECT t.expect_error('logout: two shops and no x-org-id needs a shop selection',
    'SELECT public.auth_record_logout()', '^SHOP_SELECTION_REQUIRED');
RESET ROLE;
SELECT t.expect('logout: writes one auth.logout row for user a in shop A',
    (SELECT count(*) = 1 FROM audit_log WHERE action = 'auth.logout'
       AND organization_id = 'f4100000-0000-0000-0000-00000000000a'
       AND employee_id = 'f4300000-0000-0000-0000-0000000000a1'));
SELECT t.expect('logout: works in a suspended shop',
    (SELECT count(*) = 1 FROM audit_log WHERE action = 'auth.logout'
       AND employee_id = 'f4300000-0000-0000-0000-0000000000e1'));

-- ---------------------------------------------------------------- password change
-- auth_record_password_change: the audit row, from the session
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-0000000000c1', false);
SELECT set_config('request.headers', '{"x-org-id": "f4100000-0000-0000-0000-00000000000a"}', false);
SELECT public.auth_record_password_change();
-- D24: a logged-in user cannot clear the flag through PostgREST
SELECT t.expect_error('password: authenticated calling auth_clear_must_change_password is refused',
    'SELECT public.auth_clear_must_change_password(''f4000000-0000-0000-0000-0000000000c1'')', 'permission denied');
SELECT set_config('request.headers', '{}', false);
RESET ROLE;
SELECT t.expect('password: the audit function does not touch the flag',
    (SELECT bool_and(must_change_password) FROM employees WHERE auth_user_id = 'f4000000-0000-0000-0000-0000000000c1'));
SELECT t.expect('password: writes one auth.password_change row in the active shop only',
    (SELECT count(*) = 1 FROM audit_log WHERE action = 'auth.password_change'
       AND organization_id = 'f4100000-0000-0000-0000-00000000000a'
       AND employee_id = 'f4300000-0000-0000-0000-0000000000ca')
    AND (SELECT count(*) = 0 FROM audit_log WHERE action = 'auth.password_change'
       AND organization_id = 'f4100000-0000-0000-0000-00000000000b'));

-- auth_clear_must_change_password: service role, by verified auth user id
SET ROLE service_role;
SELECT t.expect('password: service role clears the flag on both rows of the login (returns 2)',
    public.auth_clear_must_change_password('f4000000-0000-0000-0000-0000000000c1') = 2);
SELECT t.expect('password: a second call changes nothing (returns 0)',
    public.auth_clear_must_change_password('f4000000-0000-0000-0000-0000000000c1') = 0);
SELECT t.expect_error('password: a NULL user id is refused',
    'SELECT public.auth_clear_must_change_password(NULL)', '^BAD_REQUEST');
RESET ROLE;
SELECT t.expect('password: flag cleared on every row of that login',
    (SELECT bool_and(NOT must_change_password) FROM employees WHERE auth_user_id = 'f4000000-0000-0000-0000-0000000000c1'));

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-000000000001', false);
SELECT t.expect_error('password: a login without employee rows cannot write the audit row', 'SELECT public.auth_record_password_change()', '^NOT_AN_EMPLOYEE');
SELECT set_config('request.jwt.claim.sub', '', false);
RESET ROLE;

-- ---------------------------------------------------------------- tables stay closed
SELECT t.expect('tables: authenticated still has no write grant on employees',
    NOT has_table_privilege('authenticated', 'public.employees', 'UPDATE'));
SELECT t.expect('tables: authenticated still cannot read login_attempts',
    NOT has_table_privilege('authenticated', 'public.login_attempts', 'SELECT'));

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
