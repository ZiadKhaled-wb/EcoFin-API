-- F07 audit log (baseline audit_log + app.write_audit; no F07 migration). LOCAL / DEV ONLY.
-- Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f07_audit_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
--   1. write_audit stores request id, IP (first x-forwarded-for entry), user agent and a device of
--      the same shop from request.headers; another shop's device and bad headers are dropped,
--      the row is still written; PII keys are stripped
--   2. append-only: UPDATE / DELETE refused for the owner (authenticated) and for postgres
--   3. reads: the owner sees only their shop; a cashier without audit.view sees nothing; an
--      audit.view override opens it; anon has no access
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

-- Caller + PostgREST-style request headers, as the API sends them (supabaseForRequest).
CREATE FUNCTION t.as_user(p_sub text, p_headers jsonb DEFAULT '{}') RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.sub', COALESCE(p_sub, ''), false),
           set_config('request.headers', p_headers::text, false);
$$;

CREATE FUNCTION t.row_for(p_request_id text) RETURNS public.audit_log LANGUAGE sql SECURITY DEFINER AS $$
    SELECT * FROM public.audit_log WHERE request_id = p_request_id
$$;

GRANT USAGE ON SCHEMA t TO authenticated, anon;
GRANT INSERT ON t.results TO authenticated, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated, anon;

-- ---------------------------------------------------------------- fixtures
--   shop A: owner a, cashier c, branch A1, device dA     shop B: owner b, branch B1, device dB
INSERT INTO auth.users (id, email) VALUES
  ('f7000000-0000-0000-0000-0000000000a1', 'f7-a@x'),
  ('f7000000-0000-0000-0000-0000000000c1', 'f7-c@x'),
  ('f7000000-0000-0000-0000-0000000000b1', 'f7-b@x');
INSERT INTO organizations (id, tenant_slug, name, plan_key, status) VALUES
  ('f7100000-0000-0000-0000-00000000000a', 'f7-shop-a', 'F7 Shop A', 'retail', 'active'),
  ('f7100000-0000-0000-0000-00000000000b', 'f7-shop-b', 'F7 Shop B', 'retail', 'active');
INSERT INTO branches (id, organization_id, code, name, is_main) VALUES
  ('f7200000-0000-0000-0000-0000000000a1', 'f7100000-0000-0000-0000-00000000000a', 'BR1', 'A main', true),
  ('f7200000-0000-0000-0000-0000000000b1', 'f7100000-0000-0000-0000-00000000000b', 'BR1', 'B main', true);
INSERT INTO devices (id, organization_id, branch_id, name) VALUES
  ('f7400000-0000-0000-0000-0000000000a1', 'f7100000-0000-0000-0000-00000000000a', 'f7200000-0000-0000-0000-0000000000a1', 'A till'),
  ('f7400000-0000-0000-0000-0000000000b1', 'f7100000-0000-0000-0000-00000000000b', 'f7200000-0000-0000-0000-0000000000b1', 'B till');
INSERT INTO employees (id, organization_id, auth_user_id, full_name, role) VALUES
  ('f7300000-0000-0000-0000-0000000000a1', 'f7100000-0000-0000-0000-00000000000a', 'f7000000-0000-0000-0000-0000000000a1', 'A owner', 'OWNER'),
  ('f7300000-0000-0000-0000-0000000000c1', 'f7100000-0000-0000-0000-00000000000a', 'f7000000-0000-0000-0000-0000000000c1', 'A cashier', 'CASHIER'),
  ('f7300000-0000-0000-0000-0000000000b1', 'f7100000-0000-0000-0000-00000000000b', 'f7000000-0000-0000-0000-0000000000b1', 'B owner', 'OWNER');
SELECT t.expect('setup: CASHIER lacks audit.view by default',
    NOT EXISTS (SELECT 1 FROM role_permissions WHERE role = 'CASHIER' AND permission_key = 'audit.view'));

-- ---------------------------------------------------------------- 1. what write_audit stores (as postgres)
-- app.write_audit is only called from SECURITY DEFINER functions; the claims and headers decide.
SELECT t.as_user('f7000000-0000-0000-0000-0000000000a1', jsonb_build_object(
    'x-forwarded-for', '203.0.113.7, 10.0.0.1',
    'user-agent', 'EcoFin-POS/1.0',
    'x-request-id', 'f7-req-1',
    'x-device-id', 'f7400000-0000-0000-0000-0000000000a1'));
SELECT app.write_audit('test.action', 'employee', 'f7300000-0000-0000-0000-0000000000c1',
    '{"a": 1, "national_id": "29901011234567"}'::jsonb, '{"a": 2, "password": "x"}'::jsonb,
    'because', 'f7200000-0000-0000-0000-0000000000a1');
SELECT t.expect('write_audit: request id, first x-forwarded-for entry, user agent, same-shop device',
    (SELECT r.request_id = 'f7-req-1' AND host(r.ip) = '203.0.113.7' AND r.user_agent = 'EcoFin-POS/1.0'
            AND r.device_id = 'f7400000-0000-0000-0000-0000000000a1'
     FROM t.row_for('f7-req-1') r));
SELECT t.expect('write_audit: actor, shop, branch, action, entity and reason from the session and call',
    (SELECT r.employee_id = 'f7300000-0000-0000-0000-0000000000a1'
            AND r.organization_id = 'f7100000-0000-0000-0000-00000000000a'
            AND r.branch_id = 'f7200000-0000-0000-0000-0000000000a1'
            AND r.action = 'test.action' AND r.entity_type = 'employee'
            AND r.entity_id = 'f7300000-0000-0000-0000-0000000000c1' AND r.reason = 'because'
     FROM t.row_for('f7-req-1') r));
SELECT t.expect('write_audit: PII keys stripped from before/after',
    (SELECT r.before = '{"a": 1}'::jsonb AND r.after = '{"a": 2}'::jsonb FROM t.row_for('f7-req-1') r));

SELECT t.as_user('f7000000-0000-0000-0000-0000000000a1', jsonb_build_object(
    'x-forwarded-for', '203.0.113.8', 'x-request-id', 'f7-req-2',
    'x-device-id', 'f7400000-0000-0000-0000-0000000000b1'));            -- shop B's device
SELECT app.write_audit('test.action', NULL, NULL);
SELECT t.expect('write_audit: another shop''s device id is dropped, the row is still written',
    (SELECT r.device_id IS NULL AND host(r.ip) = '203.0.113.8' FROM t.row_for('f7-req-2') r));

SELECT t.as_user('f7000000-0000-0000-0000-0000000000a1', jsonb_build_object(
    'x-forwarded-for', 'not-an-ip', 'x-request-id', 'f7-req-3', 'x-device-id', 'not-a-uuid'));
SELECT app.write_audit('test.action', NULL, NULL);
SELECT t.expect('write_audit: a bad IP or device header never blocks the write',
    (SELECT r.ip IS NULL AND r.device_id IS NULL FROM t.row_for('f7-req-3') r));

SELECT t.as_user('f7000000-0000-0000-0000-0000000000b1', jsonb_build_object('x-request-id', 'f7-req-b'));
SELECT app.write_audit('test.action', NULL, NULL);
SELECT t.expect('write_audit: shop B''s owner writes into shop B',
    (SELECT r.organization_id = 'f7100000-0000-0000-0000-00000000000b' FROM t.row_for('f7-req-b') r));

-- ---------------------------------------------------------------- 2. append-only
SELECT t.expect_error('append-only: postgres UPDATE -> APPEND_ONLY',
    $q$UPDATE public.audit_log SET reason = 'edited' WHERE request_id = 'f7-req-1'$q$, '^APPEND_ONLY');
SELECT t.expect_error('append-only: postgres DELETE -> APPEND_ONLY',
    $q$DELETE FROM public.audit_log WHERE request_id = 'f7-req-1'$q$, '^APPEND_ONLY');
SELECT t.expect('append-only: authenticated and anon hold no write or truncate privilege',
    NOT has_table_privilege('authenticated', 'public.audit_log', 'INSERT, UPDATE, DELETE, TRUNCATE')
    AND NOT has_table_privilege('anon', 'public.audit_log', 'INSERT, UPDATE, DELETE, TRUNCATE'));

SET ROLE authenticated;
SELECT t.as_user('f7000000-0000-0000-0000-0000000000a1');
SELECT t.expect_error('append-only: the owner can''t UPDATE',
    $q$UPDATE public.audit_log SET reason = 'edited' WHERE request_id = 'f7-req-1'$q$, 'permission denied|APPEND_ONLY');
SELECT t.expect_error('append-only: the owner can''t DELETE',
    $q$DELETE FROM public.audit_log WHERE request_id = 'f7-req-1'$q$, 'permission denied|APPEND_ONLY');
SELECT t.expect_error('append-only: the owner can''t INSERT directly',
    $q$INSERT INTO public.audit_log (organization_id, action) VALUES ('f7100000-0000-0000-0000-00000000000a', 'forged')$q$,
    'permission denied');

-- ---------------------------------------------------------------- 3. reads (as authenticated)
SELECT t.expect('read: the owner sees their shop''s rows',
    (SELECT count(*) FROM public.audit_log WHERE request_id IN ('f7-req-1', 'f7-req-2', 'f7-req-3')) = 3);
SELECT t.expect('read: the owner sees no shop B row, even by id',
    NOT EXISTS (SELECT 1 FROM public.audit_log WHERE organization_id = 'f7100000-0000-0000-0000-00000000000b'));
SELECT t.as_user('f7000000-0000-0000-0000-0000000000a1', '{"x-org-id": "f7100000-0000-0000-0000-00000000000b"}');
SELECT t.expect('read: the owner aiming x-org-id at shop B sees nothing',
    NOT EXISTS (SELECT 1 FROM public.audit_log WHERE request_id IN ('f7-req-1', 'f7-req-b')));

SELECT t.as_user('f7000000-0000-0000-0000-0000000000c1');
SELECT t.expect('read: a cashier without audit.view sees zero rows',
    NOT EXISTS (SELECT 1 FROM public.audit_log));
RESET ROLE;
INSERT INTO employee_permission_overrides (organization_id, employee_id, permission_key, granted) VALUES
  ('f7100000-0000-0000-0000-00000000000a', 'f7300000-0000-0000-0000-0000000000c1', 'audit.view', true);
SET ROLE authenticated;
SELECT t.expect('read: an audit.view override lets the cashier read their shop only',
    (SELECT count(*) FROM public.audit_log WHERE request_id IN ('f7-req-1', 'f7-req-2', 'f7-req-3')) = 3
    AND NOT EXISTS (SELECT 1 FROM public.audit_log WHERE request_id = 'f7-req-b'));
SELECT t.as_user(NULL);
RESET ROLE;

SELECT t.expect('read: anon can''t read the audit log at all (no SELECT grant)',
    NOT has_table_privilege('anon', 'public.audit_log', 'SELECT'));
SET ROLE anon;
SELECT t.expect_error('read: anon SELECT -> permission denied',
    $q$SELECT 1 FROM public.audit_log$q$, 'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------- report
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM t.results ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
