-- F11 document numbering (baseline app.next_document_number + document_counters; no F11 migration).
-- LOCAL / DEV ONLY. Run after `npm run db:reset`:  npm run db:smoke -- supabase/tests/f11_numbering_test.sql
-- db:smoke wraps the file in BEGIN ... ROLLBACK, so it leaves nothing behind.
-- The 1,000-concurrent proof is separate: npm run db:numbering (scripts/db-numbering-proof.mjs).
-- Expected last line: failed 0.
--   1. format <branch code>-<type prefix>-<yy>-<6 digits>, starting at 000001, +1 per call
--   2. separate sequences per shop, branch, document type and year; every type has its own prefix
--   3. a rolled-back number is handed out again (no gap); another shop's branch is refused
--   4. access: app users can't call the function or write the counters; reads are own-shop only
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

GRANT USAGE ON SCHEMA t TO authenticated, anon;
GRANT INSERT ON t.results TO authenticated, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated, anon;

-- ---------------------------------------------------------------- fixtures
--   shop A: owner a, branches A1 (BR1) and A2 (BR2)     shop B: owner b, branch B1 (BR1)
INSERT INTO auth.users (id, email) VALUES
  ('f1100000-0000-0000-0000-0000000000a1', 'f11-a@x'),
  ('f1100000-0000-0000-0000-0000000000b1', 'f11-b@x');
INSERT INTO organizations (id, tenant_slug, name, plan_key, status) VALUES
  ('f1110000-0000-0000-0000-00000000000a', 'f11-shop-a', 'F11 Shop A', 'retail', 'active'),
  ('f1110000-0000-0000-0000-00000000000b', 'f11-shop-b', 'F11 Shop B', 'retail', 'active');
INSERT INTO branches (id, organization_id, code, name, is_main) VALUES
  ('f1120000-0000-0000-0000-0000000000a1', 'f1110000-0000-0000-0000-00000000000a', 'BR1', 'A main', true),
  ('f1120000-0000-0000-0000-0000000000a2', 'f1110000-0000-0000-0000-00000000000a', 'BR2', 'A second', false),
  ('f1120000-0000-0000-0000-0000000000b1', 'f1110000-0000-0000-0000-00000000000b', 'BR1', 'B main', true);
INSERT INTO employees (id, organization_id, auth_user_id, full_name, role) VALUES
  ('f1130000-0000-0000-0000-0000000000a1', 'f1110000-0000-0000-0000-00000000000a', 'f1100000-0000-0000-0000-0000000000a1', 'Owner A', 'OWNER'),
  ('f1130000-0000-0000-0000-0000000000b1', 'f1110000-0000-0000-0000-00000000000b', 'f1100000-0000-0000-0000-0000000000b1', 'Owner B', 'OWNER');

CREATE FUNCTION t.next(p_org text, p_branch text, p_type public.doc_type) RETURNS text LANGUAGE sql AS $$
    SELECT app.next_document_number(p_org::uuid, p_branch::uuid, p_type)
$$;

CREATE FUNCTION t.yy(p_org text) RETURNS text LANGUAGE sql AS $$
    SELECT right(extract(year FROM app.org_today(p_org::uuid))::text, 2)
$$;

-- ---------------------------------------------------------------- 1. format and sequence
SELECT t.expect('1.1 first sale of branch A1 is BR1-SL-<yy>-000001',
  t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'sale')
    = 'BR1-SL-' || t.yy('f1110000-0000-0000-0000-00000000000a') || '-000001');
SELECT t.expect('1.2 the next one is 000002',
  t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'sale')
    = 'BR1-SL-' || t.yy('f1110000-0000-0000-0000-00000000000a') || '-000002');
SELECT t.expect('1.3 the shape is <code>-<2 letters>-<yy>-<6 digits>',
  t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'sale')
    ~ '^BR1-SL-[0-9]{2}-[0-9]{6}$');
SELECT t.expect('1.4 the counter row is for the shop''s current year and holds the next value',
  (SELECT period_year = extract(year FROM app.org_today(organization_id)) AND next_value = 4
     FROM document_counters
    WHERE branch_id = 'f1120000-0000-0000-0000-0000000000a1' AND doc_type = 'sale'));

-- ---------------------------------------------------------------- 2. separate sequences
SELECT t.expect('2.1 another document type in the same branch starts at 000001 with its own prefix',
  t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'payment')
    = 'BR1-PY-' || t.yy('f1110000-0000-0000-0000-00000000000a') || '-000001');
SELECT t.expect('2.2 another branch of the same shop starts at 000001 with its own code',
  t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a2', 'sale')
    = 'BR2-SL-' || t.yy('f1110000-0000-0000-0000-00000000000a') || '-000001');
SELECT t.expect('2.3 another shop''s branch with the same code starts at 000001',
  t.next('f1110000-0000-0000-0000-00000000000b', 'f1120000-0000-0000-0000-0000000000b1', 'sale')
    = 'BR1-SL-' || t.yy('f1110000-0000-0000-0000-00000000000b') || '-000001');

-- A counter left over from last year doesn't carry into this year (yearly reset, D32).
INSERT INTO document_counters (organization_id, branch_id, doc_type, period_year, next_value)
VALUES ('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'quotation',
        extract(year FROM app.org_today('f1110000-0000-0000-0000-00000000000a'))::integer - 1, 500);
SELECT t.expect('2.4 last year''s counter at 499 doesn''t carry over: this year starts at 000001',
  t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'quotation')
    = 'BR1-QT-' || t.yy('f1110000-0000-0000-0000-00000000000a') || '-000001');

SELECT t.expect('2.5 every document type has a distinct 2-letter prefix',
  (SELECT count(DISTINCT split_part(t.next('f1110000-0000-0000-0000-00000000000a',
                                           'f1120000-0000-0000-0000-0000000000a2', d), '-', 2))
          = count(*)
      AND bool_and(split_part(t.next('f1110000-0000-0000-0000-00000000000a',
                                     'f1120000-0000-0000-0000-0000000000a2', d), '-', 2) ~ '^[A-Z]{2}$')
     FROM unnest(enum_range(NULL::public.doc_type)) d),
  (SELECT string_agg(d::text, ',') FROM unnest(enum_range(NULL::public.doc_type)) d));

-- ---------------------------------------------------------------- 3. rollback, other shop
SAVEPOINT before_failed_document;
SELECT t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'contract');
SELECT t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'contract');
ROLLBACK TO SAVEPOINT before_failed_document;
SELECT t.expect('3.1 numbers taken in a rolled-back transaction are handed out again (no gap)',
  t.next('f1110000-0000-0000-0000-00000000000a', 'f1120000-0000-0000-0000-0000000000a1', 'contract')
    = 'BR1-CT-' || t.yy('f1110000-0000-0000-0000-00000000000a') || '-000001');

SELECT t.expect_error('3.2 shop A asking for a number on shop B''s branch is refused',
  $$SELECT app.next_document_number('f1110000-0000-0000-0000-00000000000a',
                                    'f1120000-0000-0000-0000-0000000000b1', 'sale')$$,
  'BRANCH_NOT_IN_ORG');
SELECT t.expect('3.3 the refusal created no counter for shop A on shop B''s branch',
  NOT EXISTS (SELECT 1 FROM document_counters
               WHERE organization_id = 'f1110000-0000-0000-0000-00000000000a'
                 AND branch_id = 'f1120000-0000-0000-0000-0000000000b1'));

-- ---------------------------------------------------------------- 4. access
SELECT t.expect('4.1 authenticated and anon can''t call app.next_document_number directly',
  NOT has_function_privilege('authenticated', 'app.next_document_number(uuid,uuid,public.doc_type)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'app.next_document_number(uuid,uuid,public.doc_type)', 'EXECUTE'));
SELECT t.expect('4.2 nobody but the functions can write document_counters',
  NOT has_table_privilege('authenticated', 'public.document_counters', 'INSERT,UPDATE,DELETE,TRUNCATE')
  AND NOT has_table_privilege('anon', 'public.document_counters', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'));

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'f1100000-0000-0000-0000-0000000000a1', true);
SELECT t.expect('4.3 owner A reads only shop A''s counters',
  (SELECT count(*) > 0 AND bool_and(organization_id = 'f1110000-0000-0000-0000-00000000000a')
     FROM document_counters
    WHERE organization_id IN ('f1110000-0000-0000-0000-00000000000a', 'f1110000-0000-0000-0000-00000000000b')));
SELECT t.expect_error('4.4 owner A can''t move a counter back by hand',
  $$UPDATE document_counters SET next_value = 1
     WHERE organization_id = 'f1110000-0000-0000-0000-00000000000a'$$,
  'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------- result
SELECT name, ok, detail FROM t.results WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM t.results;
