-- F14 file storage (migration 20261005120000_f14_register_file.sql). LOCAL / DEV ONLY.
-- Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f14_files_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- Expected last line: failed 0.
-- Run on 5 Oct 2026 against local Supabase: passed 10, failed 0.
--   1. register_file for an own-shop path: one files row, one audit row, purpose check passes
--   2. refusals: another shop's path, '..' in the path, no permission for the purpose, no session
--   3. authenticated can't INSERT into files directly (no grant, no write policy)
--   Assumption: the CASHIER role default has no org.settings_manage (check against role_permissions).
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

-- Read as the test owner, whatever the session role.
CREATE FUNCTION t.audit_rows(p_entity uuid, p_action text) RETURNS integer
LANGUAGE sql SECURITY DEFINER AS $$
    SELECT count(*)::integer FROM public.audit_log WHERE entity_id = p_entity AND action = p_action
$$;
CREATE FUNCTION t.files_rows(p_id uuid) RETURNS integer
LANGUAGE sql SECURITY DEFINER AS $$
    SELECT count(*)::integer FROM public.files WHERE id = p_id
$$;

GRANT USAGE ON SCHEMA t TO authenticated, anon, service_role;
GRANT INSERT ON t.results TO authenticated, anon, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated, anon, service_role;

-- ---------------------------------------------------------------- fixtures
--   shop A: owner a (OWNER), cashier c (CASHIER); shop B: owner b (OWNER)
INSERT INTO auth.users (id, email) VALUES
  ('f1400000-0000-0000-0000-0000000000a1', 'f14-a@x'),
  ('f1400000-0000-0000-0000-0000000000b1', 'f14-b@x'),
  ('f1400000-0000-0000-0000-0000000000c1', 'f14-c@x');

INSERT INTO organizations (id, tenant_slug, name, plan_key, status) VALUES
  ('f1410000-0000-0000-0000-00000000000a', 'f14-shop-a', 'F14 Shop A', 'retail', 'active'),
  ('f1410000-0000-0000-0000-00000000000b', 'f14-shop-b', 'F14 Shop B', 'retail', 'active');

INSERT INTO employees (id, organization_id, auth_user_id, full_name, role) VALUES
  ('f1420000-0000-0000-0000-0000000000a1', 'f1410000-0000-0000-0000-00000000000a', 'f1400000-0000-0000-0000-0000000000a1', 'F14 owner A', 'OWNER'),
  ('f1420000-0000-0000-0000-0000000000b1', 'f1410000-0000-0000-0000-00000000000b', 'f1400000-0000-0000-0000-0000000000b1', 'F14 owner B', 'OWNER'),
  ('f1420000-0000-0000-0000-0000000000c1', 'f1410000-0000-0000-0000-00000000000a', 'f1400000-0000-0000-0000-0000000000c1', 'F14 cashier A', 'CASHIER');

-- ---------------------------------------------------------------- 1. own shop
SELECT t.as_user('f1400000-0000-0000-0000-0000000000a1', 'f1410000-0000-0000-0000-00000000000a');
SELECT t.expect('1.1 owner A registers a logo under the own shop: returns the id, one row',
  (SELECT public.register_file('f1430000-0000-0000-0000-000000000001',
        'f1410000-0000-0000-0000-00000000000a/logo/2026/10/f1430000-0000-0000-0000-000000000001.png',
        'logo.png', 'image/png', 1024, repeat('a', 64), 'logo', NULL, NULL)) = 'f1430000-0000-0000-0000-000000000001'
  AND t.files_rows('f1430000-0000-0000-0000-000000000001') = 1);
SELECT t.expect('1.2 exactly one audit row, file.upload, for the new file',
  t.audit_rows('f1430000-0000-0000-0000-000000000001', 'file.upload') = 1);

-- ---------------------------------------------------------------- 2. refusals
SELECT t.expect_error('2.1 a path under another shop is refused (FILE_PATH_INVALID)',
  $q$SELECT public.register_file('f1430000-0000-0000-0000-000000000002',
        'f1410000-0000-0000-0000-00000000000b/logo/2026/10/x.png', 'x.png', 'image/png', 1, NULL, 'logo', NULL, NULL)$q$,
  'FILE_PATH_INVALID');
SELECT t.expect_error('2.2 a path with .. escaping the shop is refused (FILE_PATH_INVALID)',
  $q$SELECT public.register_file('f1430000-0000-0000-0000-000000000003',
        'f1410000-0000-0000-0000-00000000000a/../f1410000-0000-0000-0000-00000000000b/x.png', 'x.png', 'image/png', 1, NULL, 'logo', NULL, NULL)$q$,
  'FILE_PATH_INVALID');
SELECT t.expect_error('2.3 a backslash in the path is refused (FILE_PATH_INVALID)',
  $q$SELECT public.register_file('f1430000-0000-0000-0000-000000000004',
        'f1410000-0000-0000-0000-00000000000a\logo.png', 'x.png', 'image/png', 1, NULL, 'logo', NULL, NULL)$q$,
  'FILE_PATH_INVALID');
SELECT t.expect('2.4 none of the refused calls left a row',
  t.files_rows('f1430000-0000-0000-0000-000000000002') + t.files_rows('f1430000-0000-0000-0000-000000000003')
  + t.files_rows('f1430000-0000-0000-0000-000000000004') = 0);

SELECT t.as_user('f1400000-0000-0000-0000-0000000000c1', 'f1410000-0000-0000-0000-00000000000a');
SELECT t.expect_error('2.5 a cashier without org.settings_manage can''t register a logo (PERMISSION_DENIED)',
  $q$SELECT public.register_file('f1430000-0000-0000-0000-000000000005',
        'f1410000-0000-0000-0000-00000000000a/logo/2026/10/y.png', 'y.png', 'image/png', 1, NULL, 'logo', NULL, NULL)$q$,
  'PERMISSION_DENIED');

SELECT t.as_user('f1400000-0000-0000-0000-0000000000b1', 'f1410000-0000-0000-0000-00000000000b');
SELECT t.expect_error('2.6 owner B can''t register under shop A''s prefix (FILE_PATH_INVALID)',
  $q$SELECT public.register_file('f1430000-0000-0000-0000-000000000006',
        'f1410000-0000-0000-0000-00000000000a/logo/2026/10/z.png', 'z.png', 'image/png', 1, NULL, 'logo', NULL, NULL)$q$,
  'FILE_PATH_INVALID');

SELECT t.as_user(NULL);
SELECT t.expect_error('2.7 no session is refused (NOT_AN_EMPLOYEE)',
  $q$SELECT public.register_file('f1430000-0000-0000-0000-000000000007',
        'f1410000-0000-0000-0000-00000000000a/logo/2026/10/n.png', 'n.png', 'image/png', 1, NULL, 'logo', NULL, NULL)$q$,
  'NOT_AN_EMPLOYEE');

-- ---------------------------------------------------------------- 3. direct writes
SET ROLE authenticated;
SELECT t.as_user('f1400000-0000-0000-0000-0000000000a1', 'f1410000-0000-0000-0000-00000000000a');
SELECT t.expect_error('3.1 authenticated can''t INSERT into files directly',
  $q$INSERT INTO public.files (organization_id, bucket, path, mime, size_bytes, purpose)
     VALUES ('f1410000-0000-0000-0000-00000000000a', 'tenant-files',
             'f1410000-0000-0000-0000-00000000000a/logo/d.png', 'image/png', 1, 'logo')$q$,
  'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------- result
SELECT name, ok, detail FROM t.results WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
