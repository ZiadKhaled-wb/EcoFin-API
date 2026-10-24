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
-- O03: a shift needs the paired POS device of the request. t.open_shift pairs a free device of the
-- branch (or the one named) and puts it in the request headers the way the API does once it has
-- resolved a device token: x-device-id with the hash of that token (x-device-token-hash). Then it
-- calls public.open_shift unchanged.
CREATE FUNCTION t.pos(p_branch uuid, p_device uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_org uuid := app.current_org_id(); v_id uuid := p_device; v_hash text;
BEGIN
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch AND b.organization_id = v_org) THEN
    RETURN NULL;
  END IF;
  IF v_id IS NULL THEN
    SELECT d.id INTO v_id FROM public.devices d
    WHERE d.organization_id = v_org AND d.branch_id = p_branch AND d.is_active AND d.archived_at IS NULL AND d.name LIKE 'Test POS %'
      AND NOT EXISTS (SELECT 1 FROM public.shifts s WHERE s.device_id = d.id AND s.status = 'open')
    ORDER BY d.name LIMIT 1;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.devices (organization_id, branch_id, name) VALUES (v_org, p_branch, 'Test POS ' || gen_random_uuid())
    RETURNING id INTO v_id;
  END IF;
  -- Paired, as the pairing screens leave it: the device holds the hash of a token.
  UPDATE public.devices d
     SET token_hash = COALESCE(d.token_hash, encode(sha256(convert_to(d.id::text, 'UTF8')), 'hex')),
         paired_at = COALESCE(d.paired_at, now())
   WHERE d.id = v_id AND d.organization_id = v_org
  RETURNING d.token_hash INTO v_hash;
  PERFORM set_config('request.headers',
    (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb
       || jsonb_build_object('x-device-id', v_id, 'x-device-token-hash', v_hash))::text, false);
  RETURN v_id;
END $$;
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text, p_vault uuid DEFAULT NULL, p_device uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.pos(p_branch, p_device);
  RETURN public.open_shift(p_branch, p_float, p_key, p_vault, p_device);
END $$;
GRANT EXECUTE ON FUNCTION t.pos(uuid, uuid), t.open_shift(uuid, text, text, uuid, uuid) TO authenticated;
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
                      CASE WHEN p_org IS NULL THEN '{}' ELSE (jsonb_build_object('x-org-id',p_org) || COALESCE((SELECT jsonb_build_object('x-device-id',d.id,'x-device-token-hash',d.token_hash) FROM public.shifts s JOIN public.employees e ON e.id=s.employee_id JOIN public.devices d ON d.id=s.device_id WHERE s.organization_id=p_org::uuid AND s.status='open' AND d.is_active AND d.archived_at IS NULL AND d.token_hash IS NOT NULL ORDER BY (e.auth_user_id::text=p_sub) DESC,s.opened_at DESC,s.id DESC LIMIT 1),'{}'::jsonb))::text END,
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
    WHERE NOT EXISTS (SELECT 1 FROM public.role_permissions rp WHERE rp.role = ru.role AND rp.permission_key = ANY(string_to_array(p_key,'|')))
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
FROM (VALUES ('logo', 'org.settings_manage'), ('product_image', 'catalog.manage'), ('customer_id', 'customer.create'),
             ('signature', 'installment.create'), ('contract_pdf', 'installment.create'),
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
 ('open_shift','shift_1_open','shift.operate',$$SELECT t.open_shift('d2000000-0000-0000-0000-000000000011','0','denial-shift-1')$$),
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
 ('open_shift','unit_5_sale_shift','shift.operate',$$SELECT t.open_shift('d2000000-0000-0000-0000-000000000011','0','denial-shift-sale')$$),
 ('quote_sale','unit_6_sale_quote','sale.create',$$SELECT public.quote_sale(jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),'quantity',1,'unit_id',(SELECT id FROM public.units WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND serial='DENIAL-SN-1'))))$$),
 ('post_sale','unit_7_sale_post','sale.create',$$SELECT public.post_sale(x.l,public.quote_sale(x.l)->>'total','denial-sale-1') FROM (SELECT jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),'quantity',1,'unit_id',(SELECT id FROM public.units WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND serial='DENIAL-SN-1'))) l) x$$),
 ('get_sale','unit_8_sale_get','sale.create',$$SELECT public.get_sale((SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-sale-1'))$$),
 ('list_sale_payment_accounts','unit_9_sale_accounts','sale.create',$$SELECT public.list_sale_payment_accounts()$$);
-- S03: two over-cap discount requests of the denial shop: one by a cashier (the owner decides it), one
-- by the owner (the owner cancels it). A request by the owner herself would be APPROVAL_NOT_NEEDED, so
-- that call is wrapped to accept this one answer: only the permission check is under test here.
INSERT INTO public.approvals (id, organization_id, branch_id, kind, entity_type, amount, payload, requested_by, reason) VALUES
 ('d4000000-0000-0000-0000-000000000031','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011','discount_above_cap','sale',8,
  '{"fingerprint":"denial","cap_pct":"5.00","lines":[]}',
  (SELECT e.id FROM public.employees e WHERE e.organization_id='d1000000-0000-0000-0000-000000000001' AND e.role='CASHIER' ORDER BY e.id LIMIT 1),'TEST-1 denial'),
 ('d4000000-0000-0000-0000-000000000032','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011','discount_above_cap','sale',8,
  '{"fingerprint":"denial","cap_pct":"5.00","lines":[]}',
  (SELECT e.id FROM public.employees e WHERE e.organization_id='d1000000-0000-0000-0000-000000000001' AND e.auth_user_id='d0000000-0000-0000-0000-000000000011'),'TEST-1 denial');
INSERT INTO t.denial VALUES
 ('decide_discount_approval','discount_1_decide','discount.above_cap',$$SELECT public.decide_discount_approval('d4000000-0000-0000-0000-000000000031',true,'Denial test')$$),
 ('cancel_discount_approval','discount_2_cancel','sale.create',$$SELECT public.cancel_discount_approval('d4000000-0000-0000-0000-000000000032')$$),
 ('get_discount_approval','discount_3_get','sale.create',$$SELECT public.get_discount_approval('d4000000-0000-0000-0000-000000000032')$$),
 ('list_discount_approvals','discount_4_list','discount.above_cap',$$SELECT public.list_discount_approvals('approved')$$),
 ('request_discount_approval','unit_6a_discount_request','sale.create',$c$DO $b$ BEGIN PERFORM public.request_discount_approval('d2000000-0000-0000-0000-000000000011',jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),'quantity',1,'unit_id',(SELECT id FROM public.units WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND serial='DENIAL-SN-1'),'discount',jsonb_build_object('type','percent','value','50'))),NULL,'Denial test'); EXCEPTION WHEN others THEN IF SQLERRM NOT LIKE 'APPROVAL_NOT_NEEDED%' THEN RAISE; END IF; END $b$$c$);
-- R01: case names order the calls (the owner's create makes the customer the others use). The reads
-- need any customer read key (D63 rule 6); the role picked for customer.create (WAREHOUSE) has none.
INSERT INTO t.denial VALUES
 ('create_customer','customer_1_create','customer.create',$$SELECT public.create_customer('{"full_name":"TEST-1 denial customer","phones":["01000000001"]}')$$),
 ('update_customer','customer_2_update','customer.edit',$$SELECT public.update_customer((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial customer'),'{"notes":"Denied"}')$$),
 ('set_customer_status','customer_3_status','customer.edit',$$SELECT public.set_customer_status((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial customer'),'blocked','Denial test')$$),
 ('list_customers','customer_4_list','customer.create',$$SELECT public.list_customers()$$),
 ('get_customer','customer_5_get','customer.create',$$SELECT public.get_customer((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial customer'))$$);
-- R04: a customer of the denial shop that no other case touches (customer_3_status blocks the first
-- one), then the guarantor calls in order. Owner and role both call the same text: the owner's call must
-- work, so the case names order create, update, link, relation, reads, unlink, archive.
INSERT INTO public.customers (organization_id, full_name, phones)
VALUES ('d1000000-0000-0000-0000-000000000001', 'TEST-1 denial R04 customer', ARRAY['01000000003']);
INSERT INTO t.denial VALUES
 ('create_guarantor','zz_r04_1_create','guarantor.manage|customer.create',$$SELECT public.create_guarantor('{"full_name":"TEST-1 denial guarantor","phone":"01000000002","national_id":"29001010100015"}')$$),
 ('update_guarantor','zz_r04_2_update','guarantor.manage',$$SELECT public.update_guarantor((SELECT id FROM public.guarantors WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial guarantor'),'{"job":"Denied"}')$$),
 ('link_customer_guarantor','zz_r04_3_link','guarantor.manage|customer.create',$$SELECT public.link_customer_guarantor((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R04 customer'),(SELECT id FROM public.guarantors WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial guarantor'),'friend')$$),
 ('set_customer_guarantor_relation','zz_r04_4_relation','guarantor.manage',$$SELECT public.set_customer_guarantor_relation((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R04 customer'),(SELECT id FROM public.guarantors WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial guarantor'),'brother')$$),
 ('list_guarantors','zz_r04_5_list','customer.create',$$SELECT public.list_guarantors()$$),
 ('get_guarantor','zz_r04_6_get','customer.create',$$SELECT public.get_guarantor((SELECT id FROM public.guarantors WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial guarantor'))$$),
 ('list_customer_guarantors','zz_r04_7_customer_list','customer.create',$$SELECT public.list_customer_guarantors((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R04 customer'))$$),
 ('get_guarantor_requirement','zz_r04_8_requirement','customer.create',$$SELECT public.get_guarantor_requirement((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R04 customer'),'1000.00')$$),
 ('unlink_customer_guarantor','zz_r04_9_unlink','guarantor.manage',$$SELECT public.unlink_customer_guarantor((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R04 customer'),(SELECT id FROM public.guarantors WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial guarantor'))$$),
 ('set_guarantor_archived','zz_r04_a_archive','guarantor.manage',$$SELECT public.set_guarantor_archived((SELECT id FROM public.guarantors WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial guarantor'),true)$$);
-- R05: survey photos need an assigned survey of the caller (the owner here): one made as the database owner
-- for the register_file(survey_photo) case, then the survey calls in the order the case names sort: assign
-- (to the owner), the reads, reassign (to the owner again: no change), save, submit (with a photo), decide,
-- and cancel of the photo survey.
INSERT INTO public.customers (id, organization_id, full_name, phones)
VALUES ('d9050000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'TEST-1 denial R05 photo customer', ARRAY['01000000005']),
       ('d9050000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'TEST-1 denial R05 customer', ARRAY['01000000006']);
INSERT INTO public.field_surveys (id, organization_id, customer_id, assigned_to)
VALUES ('d9050000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001', 'd9050000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000011');
INSERT INTO t.denial VALUES
 ('register_file','register_file(survey_photo)','survey.submit',$$SELECT public.register_file(gen_random_uuid(), 'd1000000-0000-0000-0000-000000000001/survey_photo/2026/10/' || gen_random_uuid() || '.png', 'd.png', 'image/png', 10, NULL, 'survey_photo', 'field_survey', 'd9050000-0000-0000-0000-000000000011')$$),
 ('assign_field_survey','zz_r05_1_assign','survey.assign',$$SELECT public.assign_field_survey('{"customer_id":"d9050000-0000-0000-0000-000000000002","assigned_to":"d3000000-0000-0000-0000-000000000011"}')$$),
 ('list_field_surveys','zz_r05_2_list','customer.create',$$SELECT public.list_field_surveys()$$),
 ('get_field_survey','zz_r05_3_get','customer.create',$$SELECT public.get_field_survey((SELECT id FROM public.field_surveys WHERE customer_id='d9050000-0000-0000-0000-000000000002'))$$),
 ('list_customer_surveys','zz_r05_4_customer_list','customer.create',$$SELECT public.list_customer_surveys('d9050000-0000-0000-0000-000000000002')$$),
 ('get_survey_requirement','zz_r05_5_requirement','customer.create',$$SELECT public.get_survey_requirement('d9050000-0000-0000-0000-000000000002','1000.00')$$),
 ('reassign_field_survey','zz_r05_6_reassign','survey.assign',$$SELECT public.reassign_field_survey((SELECT id FROM public.field_surveys WHERE customer_id='d9050000-0000-0000-0000-000000000002'),'d3000000-0000-0000-0000-000000000011')$$),
 ('save_field_survey','zz_r05_7_save','survey.submit',$$SELECT public.save_field_survey((SELECT id FROM public.field_surveys WHERE customer_id='d9050000-0000-0000-0000-000000000002'),'{"notes":"Denial test"}')$$),
 ('submit_field_survey','zz_r05_8_submit','survey.submit',$$SELECT public.register_file(gen_random_uuid(), 'd1000000-0000-0000-0000-000000000001/r05/' || gen_random_uuid() || '.png', 'd.png', 'image/png', 10, NULL, 'survey_photo', 'field_survey', (SELECT id FROM public.field_surveys WHERE customer_id='d9050000-0000-0000-0000-000000000002')), public.submit_field_survey((SELECT id FROM public.field_surveys WHERE customer_id='d9050000-0000-0000-0000-000000000002'), jsonb_build_object('scores','{"housing_quality":5,"neighbourhood":5,"income_stability":5,"job_status":5,"property_ownership":5,"overall_impression":5}'::jsonb,'checklist','{"met_customer":true,"address_matches":true,"id_original_seen":true,"neighbours_confirm":true,"utility_bill_seen":true,"workplace_confirmed":true}'::jsonb,'gps',jsonb_build_object('lat',30,'lng',31,'gps_accuracy_m',10,'client_captured_at',now())))$$),
 ('decide_field_survey','zz_r05_9_decide','survey.decide',$$SELECT public.decide_field_survey((SELECT id FROM public.field_surveys WHERE customer_id='d9050000-0000-0000-0000-000000000002'),'approve')$$),
 ('cancel_field_survey','zz_r05_a_cancel','survey.assign',$$SELECT public.cancel_field_survey('d9050000-0000-0000-0000-000000000011','Denial test')$$);
-- R03: a customer of the denial shop for the credit calls, in the order the case names sort: set the limit,
-- ask for two exceptions (5 000 and 6 000: the owner decides the first and cancels the second), then the reads.
INSERT INTO public.customers (organization_id, full_name, phones)
VALUES ('d1000000-0000-0000-0000-000000000001', 'TEST-1 denial R03 customer', ARRAY['01000000004']);
INSERT INTO t.denial VALUES
 ('set_customer_credit_limit','zz_r03_1_limit','credit.approve',$$SELECT public.set_customer_credit_limit((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'),'1000.00','Denial test')$$),
 ('request_credit_exception','zz_r03_2_request','sale.create|credit.approve',$$SELECT public.request_credit_exception((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'),'5000.00','Denial test'), public.request_credit_exception((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'),'6000.00','Denial test 2')$$),
 ('get_credit_exception','zz_r03_3_get','customer.create',$$SELECT public.get_credit_exception((SELECT id FROM public.approvals WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND kind='credit_exception' AND amount=5000))$$),
 ('list_credit_exceptions','zz_r03_4_list','customer.create',$$SELECT public.list_credit_exceptions()$$),
 ('get_customer_credit_profile','zz_r03_5_profile','customer.create',$$SELECT public.get_customer_credit_profile((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'))$$),
 ('get_customer_credit_check','zz_r03_6_check','customer.create',$$SELECT public.get_customer_credit_check((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'),'100.00')$$),
 ('decide_credit_exception','zz_r03_7_decide','credit.approve',$$SELECT public.decide_credit_exception((SELECT id FROM public.approvals WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND kind='credit_exception' AND amount=5000),true,NULL)$$),
 ('cancel_credit_exception','zz_r03_8_cancel','sale.create|credit.approve',$$SELECT public.cancel_credit_exception((SELECT id FROM public.approvals WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND kind='credit_exception' AND amount=6000))$$);
-- R02: the three account reads on the R03 denial customer, which gets one migrated contract (a policy
-- row first: the denial shop has none until publish_installment_policy runs).
INSERT INTO public.installment_policies (organization_id, version, max_months, markup_tiers)
VALUES ('d1000000-0000-0000-0000-000000000001', 1, 12, '[{"pct": 0, "up_to_months": 12}]');
INSERT INTO public.contracts (organization_id, number, customer_id, branch_id, policy_id, creditor, cash_price, financed_amount,
    markup_pct, markup_amount, total_payable, installments_count, frequency, first_due_date, is_migrated, idempotency_key)
SELECT 'd1000000-0000-0000-0000-000000000001', 'TEST-1-R02-C1', c.id, 'd2000000-0000-0000-0000-000000000011', p.id, 'in_house',
       1000, 1000, 0, 0, 1000, 1, 'monthly', current_date + 30, true, 'test-1-r02-contract'
FROM public.customers c, public.installment_policies p
WHERE c.organization_id = 'd1000000-0000-0000-0000-000000000001' AND c.full_name = 'TEST-1 denial R03 customer'
  AND p.organization_id = c.organization_id AND p.version = 1;
-- N01: the installment terms preview of the denial shop (its policy version 1 above), without a customer.
INSERT INTO t.denial VALUES ('preview_installment_terms','zz_n01_1_preview','installment.create',$$SELECT public.preview_installment_terms('{"cash_price":"1000.00","down_payment":"0.00","installments_count":2,"frequency":"monthly"}')$$);
-- N02: an installment sale of the denial shop (its policy version 1 above, no profit) by the owner in
-- the shift unit_5 opened: a stocked product and a customer with a national ID and a limit; then the
-- contract read.
SELECT t.as_user('d0000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT public.create_product('{"name_ar":"Denial installment chair","sku":"DENIAL-N02","cash_price":"100"}');
SELECT public.post_stock_adjustment('d2000000-0000-0000-0000-000000000011','found',NULL,
  jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-N02'),'quantity',2)),'denial-n02-stock');
RESET ROLE;
SELECT t.as_user(NULL);
UPDATE public.org_settings SET credit_min_score = 0 WHERE organization_id = 'd1000000-0000-0000-0000-000000000001';
-- The shop's current policy version when the case runs (an earlier case publishes a newer one).
CREATE FUNCTION t.n02_policy_version() RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT max(version) FROM public.installment_policies WHERE organization_id = 'd1000000-0000-0000-0000-000000000001' $$;
INSERT INTO public.customers (id, organization_id, full_name, phones, national_id, credit_limit)
VALUES ('d9020000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'TEST-1 denial N02 customer', ARRAY['01000000002'], '29001010100999', 100000);
INSERT INTO t.denial VALUES
 ('post_installment_sale','zz_n02_1_sale','installment.create',$$SELECT public.post_installment_sale(jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-N02'),'quantity',1)),'expected_total','100.00','customer_id','d9020000-0000-0000-0000-000000000001','terms',jsonb_build_object('down_payment','50.00','installments_count',1,'frequency','monthly','policy_version',t.n02_policy_version())),'denial-n02-sale')$$),
 ('get_contract','zz_n02_2_contract','customer.create',$$SELECT public.get_contract((SELECT id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale'))$$);
-- N03: a collection of 10.00 on the N02 contract by the owner in its shift, then the reads, the
-- receipt print and the same-day reversal (the cases run in name order).
INSERT INTO t.denial VALUES
 ('post_collection','zz_n03_1_collect','collection.create',$$SELECT public.post_collection(jsonb_build_object('customer_id','d9020000-0000-0000-0000-000000000001','contracts',jsonb_build_array(jsonb_build_object('contract_id',(SELECT id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale'),'amount','10.00')),'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','10.00'))),'denial-n03-collect')$$),
 ('preview_collection','zz_n03_2_preview','collection.create',$$SELECT public.preview_collection((SELECT id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale'),'5.00')$$),
 ('list_contracts','zz_n03_3_list','customer.create',$$SELECT public.list_contracts('{}')$$),
 ('get_collection','zz_n03_4_get','collection.create',$$SELECT public.get_collection((SELECT id FROM public.payments WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n03-collect'))$$),
 ('record_collection_receipt_print','zz_n03_5_print','collection.create',$$SELECT public.record_collection_receipt_print((SELECT id FROM public.payments WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n03-collect'))$$),
 ('reverse_collection','zz_n03_6_reverse','collection.reverse',$$SELECT public.reverse_collection((SELECT id FROM public.payments WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n03-collect'),'{"reason":"denial test"}','denial-n03-reverse')$$);
INSERT INTO t.denial VALUES ('get_customer_account','zz_r02_1_account','customer.create',$$SELECT public.get_customer_account((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'))$$),
 ('get_customer_contract_schedule','zz_r02_2_schedule','customer.create',$$SELECT public.get_customer_contract_schedule((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'),(SELECT id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND number='TEST-1-R02-C1'))$$),
 ('customer_statement','zz_r02_3_statement','customer.create',$$SELECT public.customer_statement((SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND full_name='TEST-1 denial R03 customer'))$$);
INSERT INTO t.denial VALUES
 ('search_sales','zz_s07_1_history','sale.create|report.view',$$SELECT public.search_sales()$$),
 ('get_sale_details','zz_s07_2_details','sale.create|report.view',$$SELECT public.get_sale_details((SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-sale-1'))$$),
 ('void_sale','zz_s07_3_void','sale.void',$$SELECT public.void_sale((SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-sale-1'),'S07 denial test','denial-s07-void')$$),
 ('record_sale_receipt_print','zz_s07_4_receipt_print','sale.create|report.view',$$SELECT public.record_sale_receipt_print((SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-sale-1'))$$);
INSERT INTO t.denial VALUES
 ('post_sale','zz_s12_0_sale','sale.create',$$SELECT public.post_sale(x.l,public.quote_sale(x.l)->>'total','denial-s12-sale') FROM (SELECT jsonb_build_array(jsonb_build_object('product_id',(SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),'quantity',1,'unit_id',(SELECT id FROM public.units WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND serial='DENIAL-SN-1'))) l) x$$),
 ('warranty_lookup','zz_s12_1_lookup','warranty.manage',$$SELECT public.warranty_lookup(NULL,NULL,(SELECT number FROM public.sales WHERE id=(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale')))$$),
 ('list_warranty_claims','zz_s12_2_list','warranty.manage',$$SELECT public.list_warranty_claims()$$),
 ('open_warranty_claim','zz_s12_3_open','warranty.manage',$$SELECT public.open_warranty_claim((SELECT id FROM public.sale_lines WHERE sale_id=(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale') LIMIT 1),(SELECT unit_id FROM public.sale_lines WHERE sale_id=(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale') LIMIT 1),'Broken item','Used item','denial-s12-open')$$),
 ('get_warranty_claim','zz_s12_4_get','warranty.manage',$$SELECT public.get_warranty_claim((SELECT id FROM public.warranty_claims WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-open'))$$),
 ('move_warranty_claim','zz_s12_5_move','warranty.manage',$$SELECT public.move_warranty_claim((SELECT id FROM public.warranty_claims WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-open'),'in_repair','Manager decision')$$),
 ('request_claim_refund','zz_s12_6_refund','warranty.manage',$$SELECT public.request_claim_refund((SELECT id FROM public.warranty_claims WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-open'))$$);
-- S05: returns of the S12 sale (cases sort after zz_s12_*; the owner's run posts the return the later cases read).
INSERT INTO t.denial VALUES
 ('get_sale_returnable','zz_s13_1_returnable','refund.create',$q$SELECT public.get_sale_returnable((SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale'))$q$),
 ('quote_sales_return','zz_s13_2_quote','refund.create',$q$SELECT public.quote_sales_return(jsonb_build_object('sale_id',(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale'),'lines',jsonb_build_array(jsonb_build_object('sale_line_id',(SELECT id FROM public.sale_lines WHERE sale_id=(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale') LIMIT 1),'unit_id',(SELECT unit_id FROM public.sale_lines WHERE sale_id=(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale') LIMIT 1),'quantity',1))))$q$),
 ('post_sales_return','zz_s13_3_post','refund.create',$q$SELECT public.post_sales_return(y.b || jsonb_build_object('expected_total',y.q->>'total','refunds',jsonb_build_array(jsonb_build_object('method','cash','amount',y.q->>'total')),'reason','TEST-1 denial'),'denial-s05-return') FROM (SELECT x.b, public.quote_sales_return(x.b) q FROM (SELECT jsonb_build_object('sale_id',(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale'),'lines',jsonb_build_array(jsonb_build_object('sale_line_id',(SELECT id FROM public.sale_lines WHERE sale_id=(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale') LIMIT 1),'unit_id',(SELECT unit_id FROM public.sale_lines WHERE sale_id=(SELECT id FROM public.sales WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s12-sale') LIMIT 1),'quantity',1))) b) x) y$q$),
 ('list_sales_returns','zz_s13_4_list','refund.create|sale.create|report.view|cash.view',$q$SELECT public.list_sales_returns('{}')$q$),
 ('get_sales_return','zz_s13_5_get','refund.create|sale.create|report.view|cash.view',$q$SELECT public.get_sales_return((SELECT id FROM public.sales_returns WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s05-return'))$q$),
 ('record_return_receipt_print','zz_s13_6_print','refund.create|sale.create|report.view',$q$SELECT public.record_return_receipt_print((SELECT id FROM public.sales_returns WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-s05-return'))$q$);


-- T02: a POS of shop one, and a blocked receipt of one of its sales, for the device and retry cases
-- (rows made as the database owner; ETA is off in shop one, so the sale gets no receipt of its own).
-- list_devices takes device.manage or org.settings_manage: the role without the first has neither.
INSERT INTO public.devices(id,organization_id,branch_id,name)
  VALUES('d5000000-0000-0000-0000-0000000000e1','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011','Denial POS');
INSERT INTO public.sales(id,organization_id,number,branch_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key)
  VALUES('d5000000-0000-0000-0000-0000000000e2','d1000000-0000-0000-0000-000000000001','DENIAL-ETA-1','d2000000-0000-0000-0000-000000000011','pos',false,true,100,100,current_date,'denial-eta-sale-1');
INSERT INTO public.fiscal_submissions(id,organization_id,branch_id,doc_type,sale_id,environment,internal_id,status,last_error)
  VALUES('d5000000-0000-0000-0000-0000000000e3','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011','b2c_receipt','d5000000-0000-0000-0000-0000000000e2','preprod','DENIAL-ETA-1','failed','BLOCKED:NO_DEVICE: TEST-1 denial');
INSERT INTO t.denial VALUES
 ('get_eta_settings','eta_1_settings_get','org.settings_manage',$$SELECT public.get_eta_settings()$$),
 ('set_eta_settings','eta_2_settings_set','org.settings_manage',$$SELECT public.set_eta_settings('preprod','denial-client',NULL,'4753',false)$$),
 ('list_devices','eta_3_devices_list','device.manage',$$SELECT public.list_devices()$$),
 ('set_device_eta','eta_4_device_set','device.manage',$$SELECT public.set_device_eta('d5000000-0000-0000-0000-0000000000e1','DENIAL-POS','os','1',NULL,'pending')$$),
 ('retry_fiscal_submission','eta_5_retry','fiscal.retry',$$SELECT public.retry_fiscal_submission('d5000000-0000-0000-0000-0000000000e3')$$);
-- O03: the device of the T02 cases is renamed, given a code, paired, unpaired and deactivated, in
-- that order (case names). pair_device takes shift.operate or device.manage: the role without the
-- first is denied on the second. resolve_device asks for no key (any employee of the shop).
INSERT INTO t.denial VALUES
 ('create_device','dev_1_create','device.manage',$$SELECT public.create_device('d2000000-0000-0000-0000-000000000011','Denial POS two')$$),
 ('update_device','dev_2_update','device.manage',$$SELECT public.update_device('d5000000-0000-0000-0000-0000000000e1','Denial POS renamed')$$),
 ('create_device_pairing_code','dev_3_code','device.manage',$$SELECT public.create_device_pairing_code('d5000000-0000-0000-0000-0000000000e1',repeat('a',64),now()+interval '10 minutes')$$),
 ('pair_device','dev_4_pair','shift.operate',$$SELECT public.pair_device(repeat('a',64),repeat('b',64))$$),
 ('unpair_device','dev_5_unpair','device.manage',$$SELECT public.unpair_device('d5000000-0000-0000-0000-0000000000e1')$$),
 ('set_device_active','dev_6_active','device.manage',$$SELECT public.set_device_active('d5000000-0000-0000-0000-0000000000e1',false,'TEST-1 denial')$$);
-- T03: more receipts of those sales' shop: a rejected one, a submitted one and a blocked one without a POS.
-- The fiscal trigger only fires on a shop with ETA on, so the rows are made by hand like the one above.
INSERT INTO public.sales(id,organization_id,number,branch_id,kind,is_b2b,prices_include_vat,subtotal,total,business_date,idempotency_key) VALUES
 ('d5000000-0000-0000-0000-0000000000f2','d1000000-0000-0000-0000-000000000001','DENIAL-ETA-2','d2000000-0000-0000-0000-000000000011','pos',false,true,100,100,current_date,'denial-eta-sale-2'),
 ('d5000000-0000-0000-0000-0000000000f4','d1000000-0000-0000-0000-000000000001','DENIAL-ETA-3','d2000000-0000-0000-0000-000000000011','pos',false,true,100,100,current_date,'denial-eta-sale-3'),
 ('d5000000-0000-0000-0000-0000000000f6','d1000000-0000-0000-0000-000000000001','DENIAL-ETA-4','d2000000-0000-0000-0000-000000000011','pos',false,true,100,100,current_date,'denial-eta-sale-4');
INSERT INTO public.devices(id,organization_id,branch_id,name)
  VALUES('d5000000-0000-0000-0000-0000000000e8','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011','Denial POS assign');
INSERT INTO public.fiscal_submissions(id,organization_id,branch_id,device_id,doc_type,sale_id,environment,internal_id,status,eta_uuid,eta_submission_uuid,last_error) VALUES
 ('d5000000-0000-0000-0000-0000000000f3','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011','d5000000-0000-0000-0000-0000000000e1','b2c_receipt','d5000000-0000-0000-0000-0000000000f2','preprod','DENIAL-ETA-2','rejected',repeat('a',64),NULL,'ETA_INVALID: TEST-1 denial'),
 ('d5000000-0000-0000-0000-0000000000f5','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011','d5000000-0000-0000-0000-0000000000e1','b2c_receipt','d5000000-0000-0000-0000-0000000000f4','preprod','DENIAL-ETA-3','submitted',repeat('b',64),'DENIAL-SUB',NULL),
 ('d5000000-0000-0000-0000-0000000000f7','d1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000011',NULL,'b2c_receipt','d5000000-0000-0000-0000-0000000000f6','preprod','DENIAL-ETA-4','failed',NULL,NULL,'BLOCKED:NO_DEVICE: TEST-1 denial');
-- T03: the ETA monitor. The reads take fiscal.view, the writes fiscal.retry (the role without the key is denied).
INSERT INTO t.denial VALUES
 ('fiscal_list','fis_1_list','fiscal.view',$$SELECT public.fiscal_list()$$),
 ('fiscal_details','fis_2_details','fiscal.view',$$SELECT public.fiscal_details('d5000000-0000-0000-0000-0000000000e3')$$),
 ('fiscal_diagnose','fis_3_diagnose','fiscal.view',$$SELECT public.fiscal_diagnose('d5000000-0000-0000-0000-0000000000e3')$$),
 ('fiscal_alert_summary','fis_4_alert','fiscal.view',$$SELECT public.fiscal_alert_summary()$$),
 ('fiscal_day_summary','fis_5_day','fiscal.view',$$SELECT public.fiscal_day_summary('d2000000-0000-0000-0000-000000000011',current_date)$$),
 ('fiscal_request_correction','fis_6_correct','fiscal.retry',$$SELECT public.fiscal_request_correction('d5000000-0000-0000-0000-0000000000f3')$$),
 ('fiscal_assign_device','fis_7_assign','fiscal.retry',$$SELECT public.fiscal_assign_device('d5000000-0000-0000-0000-0000000000f7','d5000000-0000-0000-0000-0000000000e8')$$),
 ('fiscal_check_now','fis_8_check','fiscal.retry',$$SELECT public.fiscal_check_now('d5000000-0000-0000-0000-0000000000f5')$$),
 ('fiscal_retry_many','fis_9_many','fiscal.retry',$$SELECT public.fiscal_retry_many(ARRAY['d5000000-0000-0000-0000-0000000000e3']::uuid[])$$);
-- N04: an open warning and an open legal referral on the N02 denial contract, made on first use
-- (the contract exists once zz_n02_1_sale ran); the denied role's call makes it, the owner's handles it.
CREATE FUNCTION t.n04_action(p_kind public.overdue_action_kind) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid; c public.contracts;
BEGIN
    SELECT * INTO c FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale';
    SELECT id INTO v_id FROM public.overdue_actions WHERE contract_id=c.id AND kind=p_kind;
    IF v_id IS NULL THEN
        INSERT INTO public.overdue_actions(organization_id,kind,contract_id,customer_id,branch_id,schedule_line_id,business_date,days_late,overdue_amount,status)
        SELECT c.organization_id,p_kind,c.id,c.customer_id,c.branch_id,(SELECT id FROM public.schedule_lines WHERE contract_id=c.id ORDER BY seq LIMIT 1),
               current_date,1,1,'open'
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $f$;
INSERT INTO t.denial VALUES
 ('list_overdue_contracts','zz_n04_1_list','overdue.view',$$SELECT public.list_overdue_contracts('{}')$$),
 ('list_overdue_warnings','zz_n04_2_warnings','overdue.view',$$SELECT public.list_overdue_warnings('{}')$$),
 ('list_legal_referrals','zz_n04_3_referrals','overdue.view',$$SELECT public.list_legal_referrals('{}')$$),
 ('handle_overdue_warning','zz_n04_4_handle','overdue.handle',$$SELECT public.handle_overdue_warning(t.n04_action('warning'),'contacted')$$),
 ('dismiss_legal_referral','zz_n04_5_dismiss','overdue.view',$$SELECT public.dismiss_legal_referral(t.n04_action('legal_referral'),'TEST-1 denial')$$),
 ('run_overdue_check','zz_n04_6_run','overdue.view',$$SELECT public.run_overdue_check()$$);
-- N05: each change works on its own copy of the N02 denial contract (made on first use, as a
-- migrated contract with fresh lines; the commit-time checks never run in this rolled-back test).
-- The reads use the reschedule's copy: they are STABLE and can't see a copy made by their own call.
CREATE FUNCTION t.n05_contract(p_tag text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid; c public.contracts;
BEGIN
    SELECT id INTO v_id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n05-'||p_tag;
    IF v_id IS NULL THEN
        SELECT * INTO c FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale';
        v_id := gen_random_uuid();
        INSERT INTO public.contracts(id,organization_id,number,customer_id,branch_id,policy_id,creditor,cash_price,down_payment,financed_amount,
                                     markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,is_migrated,idempotency_key)
        VALUES (v_id,c.organization_id,c.number||'-'||p_tag,c.customer_id,c.branch_id,c.policy_id,c.creditor,c.cash_price,c.down_payment,c.financed_amount,
                c.markup_pct,c.markup_amount,c.total_payable,c.installments_count,c.frequency,c.first_due_date,true,'denial-n05-'||p_tag);
        INSERT INTO public.schedule_lines(organization_id,contract_id,version,seq,due_date,principal,profit)
        SELECT organization_id,v_id,1,seq,due_date,principal,profit FROM public.schedule_lines WHERE contract_id=c.id AND version=1;
    END IF;
    RETURN v_id;
END $f$;
CREATE FUNCTION t.n05_left(p_tag text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $f$
    SELECT app.contract_remaining('d1000000-0000-0000-0000-000000000001',t.n05_contract(p_tag))::numeric(18,2)::text $f$;
INSERT INTO t.denial VALUES
 ('reschedule_contract','zz_n05_1_reschedule','schedule.change',$$SELECT public.reschedule_contract(t.n05_contract('r'),jsonb_build_object('installments_count',2,'frequency','monthly','first_due_date',(current_date+20)::text,'reason','TEST-1 denial','expected_remaining',t.n05_left('r')),'denial-n05-reschedule')$$),
 ('settle_contract_early','zz_n05_2_settle','contract.settle_early',$$SELECT public.settle_contract_early(t.n05_contract('s'),jsonb_build_object('waiver','0.00','expected_remaining',t.n05_left('s'),'payments',jsonb_build_array(jsonb_build_object('method','cash','amount',t.n05_left('s')))),'denial-n05-settle')$$),
 ('write_off_contract','zz_n05_3_write_off','contract.write_off',$$SELECT public.write_off_contract(t.n05_contract('w'),jsonb_build_object('reason','TEST-1 denial','expected_remaining',t.n05_left('w')),'denial-n05-write-off')$$),
 ('get_settlement_quote','zz_n05_4_quote','contract.settle_early',$$SELECT public.get_settlement_quote(t.n05_contract('r'))$$),
 ('preview_reschedule','zz_n05_5_preview','schedule.change',$$SELECT public.preview_reschedule(t.n05_contract('r'),jsonb_build_object('installments_count',2,'frequency','monthly','first_due_date',(current_date+20)::text))$$),
 ('list_contract_changes_for','zz_n05_6_history','contract.settle_early|schedule.change|contract.write_off|collection.create|report.view',$$SELECT public.list_contract_changes_for(t.n05_contract('r'))$$),
 ('list_contract_changes','zz_n05_7_list','report.financial|contract.settle_early|schedule.change|contract.write_off',$$SELECT public.list_contract_changes('{}')$$);
-- N06: the owner's calls run on the N02 denial customer and contract; settling needs a wallet of
-- someone else, so a funded one is made on first use (a SECURITY DEFINER helper, rolled back with the test).
CREATE FUNCTION t.n06_wallet() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid; v_safe public.cash_accounts; v_emp uuid;
BEGIN
    SELECT id INTO v_id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND name='TEST-1 denial N06 wallet';
    IF v_id IS NULL THEN
        SELECT * INTO v_safe FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND kind='safe' AND is_active ORDER BY created_at, id LIMIT 1;
        SELECT id INTO v_emp FROM public.employees WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND role<>'OWNER' AND is_active ORDER BY created_at, id LIMIT 1;
        v_id := gen_random_uuid();
        INSERT INTO public.cash_accounts(id,organization_id,branch_id,name,kind,employee_id)
        VALUES (v_id,v_safe.organization_id,v_safe.branch_id,'TEST-1 denial N06 wallet','collector_wallet',v_emp);
        INSERT INTO public.cash_movements(organization_id,cash_account_id,branch_id,amount,type,source_type,source_id,business_date)
        VALUES (v_safe.organization_id,v_id,v_safe.branch_id,50,'collection','payment',gen_random_uuid(),current_date);
    END IF;
    RETURN v_id;
END $f$;
CREATE FUNCTION t.n06_safe() RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $f$
    SELECT id FROM public.cash_accounts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND kind='safe' AND is_active ORDER BY created_at, id LIMIT 1 $f$;
CREATE FUNCTION t.n06_owner() RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $f$
    SELECT id FROM public.employees WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND role='OWNER' $f$;
INSERT INTO t.denial VALUES
 ('set_customer_collector','zz_n06_1_assign','customer.edit',$$SELECT public.set_customer_collector('d9020000-0000-0000-0000-000000000001',t.n06_owner(),'TEST-1 denial')$$),
 ('post_field_collection','zz_n06_2_field','collection.create',$$SELECT public.post_field_collection(jsonb_build_object('customer_id','d9020000-0000-0000-0000-000000000001','contracts',jsonb_build_array(jsonb_build_object('contract_id',(SELECT id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale'),'amount','10.00')),'payments',jsonb_build_array(jsonb_build_object('method','cash','amount','10.00'))),'denial-n06-field')$$),
 ('get_my_wallet','zz_n06_3_mine','collection.create',$$SELECT public.get_my_wallet()$$),
 ('list_collector_wallets','zz_n06_4_wallets','collector.settle|cash.view',$$SELECT public.list_collector_wallets('{}')$$),
 ('list_wallet_movements','zz_n06_6_ledger','collector.settle|cash.view|collection.create',$$SELECT public.list_wallet_movements(t.n06_wallet(),'{}')$$),
 ('settle_collector_wallet','zz_n06_5_settle','collector.settle',$$SELECT public.settle_collector_wallet(t.n06_wallet(),jsonb_build_object('to_account_id',t.n06_safe(),'handed','10.00','expected_balance','50.00'),'denial-n06-settle')$$),
 ('get_collector_route','zz_n06_7_route','collection.create',$$SELECT public.get_collector_route('{}')$$);
-- N07: the printed contract and notes of the denial shop's N02 contract (any of the two keys allows it).
INSERT INTO t.denial VALUES
 ('get_contract_documents','zz_n07_1_documents','installment.create|customer.view_pii',$$SELECT public.get_contract_documents((SELECT id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale'))$$),
 ('record_contract_document_print','zz_n07_2_print','installment.create|customer.view_pii',$$SELECT public.record_contract_document_print((SELECT id FROM public.contracts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-n02-sale'),'contract')$$);
-- M01: an import file and validated import jobs of the denial shop (made once per tag, superuser).
CREATE FUNCTION t.m01_file() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid;
BEGIN
    SELECT id INTO v_id FROM public.files WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND path LIKE '%/import/denial-m01.csv';
    IF v_id IS NULL THEN
        INSERT INTO public.files(organization_id,path,original_name,mime,size_bytes,sha256,purpose)
        VALUES ('d1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001/import/denial-m01.csv','denial-m01.csv','text/csv',10,repeat('a',64),'import')
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $f$;
CREATE FUNCTION t.m01_job(p_tag text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid;
BEGIN
    SELECT id INTO v_id FROM public.import_jobs WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND report->>'idempotency_key'='denial-m01-'||p_tag;
    IF v_id IS NULL THEN
        INSERT INTO public.import_jobs(organization_id,kind,status,file_id,rows_total,rows_ok,report)
        VALUES ('d1000000-0000-0000-0000-000000000001','suppliers','validated',t.m01_file(),1,1,
                jsonb_build_object('columns',jsonb_build_object('mapping','{}'::jsonb,'unmapped_headers','[]'::jsonb),'idempotency_key','denial-m01-'||p_tag))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $f$;
-- A STABLE read does not see a row made in its own statement, so the job it reads is made first.
SELECT t.m01_job('get');
INSERT INTO t.denial VALUES
 ('create_import','zz_m01_1_create','import.data',$$SELECT public.create_import('suppliers',t.m01_file(),NULL,'[{"row":2,"values":{"name":"TEST-1 denial import supplier"}}]'::jsonb,'{}','denial-m01-create')$$),
 ('get_import_job','zz_m01_2_get','import.data|export.data',$$SELECT public.get_import_job(t.m01_job('get'))$$),
 ('list_import_jobs','zz_m01_3_list','import.data|export.data',$$SELECT public.list_import_jobs('{}')$$),
 ('queue_import','zz_m01_4_queue','import.data',$$SELECT public.queue_import(t.m01_job('queue'),'denial-m01-queue-run')$$),
 ('cancel_import_job','zz_m01_5_cancel','import.data',$$SELECT public.cancel_import_job(t.m01_job('cancel'))$$),
 ('attach_import_result','zz_m01_6_attach','import.data',$$SELECT public.attach_import_result(t.m01_job('attach'),gen_random_uuid(),'d1000000-0000-0000-0000-000000000001/export/denial-m01.csv','denial-m01.csv','text/csv',1,repeat('a',64))$$);
-- EC-147: register the new RPC without changing the completeness/denial assertions.
INSERT INTO t.denial VALUES ('force_close_shift','shift_4_force_close','cash.adjust',$q$SELECT public.force_close_shift((SELECT id FROM public.shifts WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-shift-1'),'5.00','Lost POS')$q$);
-- M02: a completed batch of the denial shop (no contracts), for the sign-off and the reversal.
CREATE FUNCTION t.m02_job(p_kind text,p_tag text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid;
BEGIN
    SELECT id INTO v_id FROM public.import_jobs WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND report->>'idempotency_key'='denial-m02-'||p_tag;
    IF v_id IS NULL THEN
        INSERT INTO public.import_jobs(organization_id,kind,status,file_id,rows_total,rows_ok,report,finished_at)
        VALUES ('d1000000-0000-0000-0000-000000000001',p_kind::public.import_kind,'completed',t.m01_file(),1,1,
                jsonb_build_object('columns',jsonb_build_object('mapping','{}'::jsonb,'unmapped_headers','[]'::jsonb),'idempotency_key','denial-m02-'||p_tag),now())
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $f$;
-- M03: a completed export of the denial shop (finished three hours ago, so a new one may start).
CREATE FUNCTION t.m03_job() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid;
BEGIN
    SELECT id INTO v_id FROM public.import_jobs WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND report->>'idempotency_key'='denial-m03';
    IF v_id IS NULL THEN
        INSERT INTO public.import_jobs(organization_id,kind,status,dry_run,report,finished_at)
        VALUES ('d1000000-0000-0000-0000-000000000001','full_export','completed',false,
                jsonb_build_object('pii','masked','idempotency_key','denial-m03'),now()-interval '3 hours')
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $f$;
INSERT INTO t.denial VALUES
 ('start_full_export','zz_m03_1_start','export.data',$q$SELECT public.start_full_export('{}','denial-m03-start-key')$q$),
 ('list_exports','zz_m03_2_list','export.data',$q$SELECT public.list_exports()$q$),
 ('get_export','zz_m03_3_get','export.data',$q$SELECT public.get_export(t.m03_job())$q$),
 ('cancel_export','zz_m03_4_cancel','export.data',$q$SELECT public.cancel_export(t.m03_job())$q$),
 ('record_export_download','zz_m03_5_download','export.data',$q$SELECT public.record_export_download(gen_random_uuid())$q$);
-- The job exists before the cases run: the STABLE get_export would not see a row made inside its own statement.
SELECT t.m03_job();
-- K04: an old day of the denial shop's branch, closed (case 1) then reopened (case 2) by the owner.
INSERT INTO t.denial VALUES
 ('close_day','zz_k04_1_close','day.close',$q$SELECT public.close_day('d2000000-0000-0000-0000-000000000011','2020-01-01',(public.get_day_close_preview('d2000000-0000-0000-0000-000000000011','2020-01-01')->>'hash'),'TEST-1 denial close')$q$),
 ('reopen_day','zz_k04_2_reopen','day.reopen',$q$SELECT public.reopen_day((SELECT id FROM public.day_closes WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND business_date='2020-01-01'),'TEST-1 denial reopen')$q$),
 ('get_day_close','zz_k04_3_get','day.close|cash.view',$q$SELECT public.get_day_close((SELECT id FROM public.day_closes WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND business_date='2020-01-01'))$q$),
 ('get_day_close_preview','zz_k04_4_preview','day.close|cash.view',$q$SELECT public.get_day_close_preview('d2000000-0000-0000-0000-000000000011','2020-01-02')$q$),
 ('list_day_closes','zz_k04_5_list','day.close|cash.view',$q$SELECT public.list_day_closes()$q$),
 ('day_close_alerts','zz_k04_6_alerts','day.close|cash.view',$q$SELECT public.day_close_alerts()$q$),
 ('get_migration_report','zz_m02_1_report','import.data|report.financial',$q$SELECT public.get_migration_report('{}')$q$),
 ('list_migration_signoffs','zz_m02_2_list','import.data|report.financial',$q$SELECT public.list_migration_signoffs()$q$),
 ('sign_off_migration','zz_m02_3_sign','import.data',$q$SELECT public.sign_off_migration(jsonb_build_object('expected_open_total','0','batch_ids',jsonb_build_array(t.m02_job('opening_cash','sign')),'note','TEST-1 denial'))$q$),
 ('reverse_migration_batch','zz_m02_4_reverse','import.data',$q$SELECT public.reverse_migration_batch(t.m02_job('opening_contracts','rev'),'TEST-1 denial')$q$),
 -- D02: the sales report needs report.view (a cashier has no such key).
 ('report_sales','zz_d02_1_report','report.view',$q$SELECT public.report_sales(DATE '2026-09-01',DATE '2026-09-30','month')$q$);
-- S08: offline sales. The settings first (offline on); the owner's lease and sync come from the device
-- of the owner's open shift (ETA is off for the denial shop by then); an unreadable item is answered
-- item by item; a stored conflict of the denial shop is listed, read and accepted.
INSERT INTO public.offline_sales (organization_id, branch_id, device_id, seq, number, idempotency_key, issued_at,
                                  content, content_hash, signature, total, source, status, conflict_code)
SELECT 'd1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000011', d.id, 1, 'OFF-D9-000001',
       'denial-s08-offline', now(), x.c, encode(sha256(convert_to(x.c, 'UTF8')), 'hex'), repeat('A', 86) || '==',
       1.00, 'sync', 'conflict', 'PRICE_MISMATCH'
FROM (SELECT d.id FROM public.devices d WHERE d.organization_id = 'd1000000-0000-0000-0000-000000000001'
      ORDER BY d.created_at, d.id LIMIT 1) d,
     (SELECT jsonb_build_object('lines', jsonb_build_array(jsonb_build_object(
                 'product_id', (SELECT id FROM public.products WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND sku='DENIAL-PH'),
                 'unit_id', NULL, 'quantity', 1, 'unit_price', '1.00', 'tax_rate', '14.00', 'tax_amount', '0.12', 'line_total', '1.00')),
             'subtotal', '1.00', 'tax_total', '0.12', 'total', '1.00',
             'payments', jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', '1.00', 'tendered', '1.00', 'change', '0.00')))::text AS c) x;
INSERT INTO t.denial VALUES
 ('set_offline_settings','zz_s08_1_settings_set','org.settings_manage',$q$SELECT public.set_offline_settings(true,'20000.00',12,100,'200000.00')$q$),
 ('get_offline_settings','zz_s08_2_settings_get','org.settings_manage',$q$SELECT public.get_offline_settings()$q$),
 ('issue_offline_lease','zz_s08_3_lease','sale.create',$q$SELECT public.issue_offline_lease('MFkw'||repeat('M',120),NULL)$q$),
 ('sync_offline_sales','zz_s08_4_sync','sale.create',$q$SELECT public.sync_offline_sales(jsonb_build_array(jsonb_build_object('content','{}','signature',repeat('A',86)||'==')))$q$),
 ('list_offline_sales','zz_s08_5_list','offline.resolve',$q$SELECT public.list_offline_sales(NULL,NULL)$q$),
 ('get_offline_sale','zz_s08_6_get','offline.resolve',$q$SELECT public.get_offline_sale((SELECT id FROM public.offline_sales WHERE idempotency_key='denial-s08-offline'))$q$),
 ('resolve_offline_sale','zz_s08_7_resolve','offline.resolve',$q$SELECT public.resolve_offline_sale((SELECT id FROM public.offline_sales WHERE idempotency_key='denial-s08-offline'),'accept','TEST-1 denial')$q$),
 ('import_offline_sales','zz_s08_8_import','offline.resolve',$q$SELECT public.import_offline_sales((SELECT device_id FROM public.offline_sales WHERE idempotency_key='denial-s08-offline'),jsonb_build_array(jsonb_build_object('content','{}','signature',repeat('A',86)||'==')))$q$);
-- S09: valid fixtures for the generic denial/owner-success matrix.
CREATE TABLE t.s09_docs(tag text PRIMARY KEY,id uuid);
GRANT SELECT ON t.s09_docs TO authenticated;
SELECT t.as_user('d0000000-0000-0000-0000-000000000011','d1000000-0000-0000-0000-000000000001');
INSERT INTO t.s09_docs SELECT tag,(public.create_quotation('d2000000-0000-0000-0000-000000000011',
  (SELECT id FROM public.customers WHERE organization_id='d1000000-0000-0000-0000-000000000001' LIMIT 1),NULL,NULL,
  '[{"description":"Custom quotation item","quantity":1,"unit_price":"114"}]','denial-s09-'||tag)->>'id')::uuid
  FROM (VALUES('main'),('reject'),('cancel')) tags(tag);
SELECT public.send_quotation(id) FROM t.s09_docs WHERE tag='reject';
INSERT INTO t.denial VALUES
 ('create_quotation','zz_s09_01_create','quotation.manage',$q$SELECT public.create_quotation('d2000000-0000-0000-0000-000000000011',NULL,NULL,NULL,'[{"description":"Item","quantity":1,"unit_price":"114"}]','denial-s09-main')$q$),
 ('list_quotations','zz_s09_02_list','quotation.manage',$q$SELECT public.list_quotations()$q$),
 ('get_quotation','zz_s09_03_get','quotation.manage',$q$SELECT public.get_quotation((SELECT id FROM t.s09_docs WHERE tag='main'))$q$),
 ('update_quotation_draft','zz_s09_04_update','quotation.manage',$q$SELECT public.update_quotation_draft((SELECT id FROM t.s09_docs WHERE tag='main'),(public.get_quotation((SELECT id FROM t.s09_docs WHERE tag='main'))->>'customer_id')::uuid,NULL,NULL,'[{"description":"Updated","quantity":1,"unit_price":"114"}]',(public.get_quotation((SELECT id FROM t.s09_docs WHERE tag='main'))->>'updated_at')::timestamptz)$q$),
 ('send_quotation','zz_s09_05_send','quotation.manage',$q$SELECT public.send_quotation((SELECT id FROM t.s09_docs WHERE tag='main'))$q$),
 ('accept_quotation','zz_s09_06_accept','quotation.manage',$q$SELECT public.accept_quotation((SELECT id FROM t.s09_docs WHERE tag='main'))$q$),
 ('reject_quotation','zz_s09_07_reject','quotation.manage',$q$SELECT public.reject_quotation((SELECT id FROM t.s09_docs WHERE tag='reject'),'Customer declined')$q$),
 ('cancel_quotation','zz_s09_08_cancel','quotation.manage',$q$SELECT public.cancel_quotation((SELECT id FROM t.s09_docs WHERE tag='cancel'),'Customer cancelled')$q$),
 -- D03: the receivables aging needs report.financial (a cashier has no such key).
 ('report_receivables','zz_d03_1_report','report.financial',$q$SELECT public.report_receivables('customer')$q$);
-- L01: a legal case of shop A, on its own copy of the N02 denial contract (made on first use, like the
-- N05 copies). The writes take legal.manage, the reads legal.view; opening is owner only, so a role
-- with legal.manage but not the owner is refused too (see supabase/tests/l01_legal_module_test.sql).
-- The status case closes the case, so it sorts after the hearing and note cases. The case names sort after zz_n02 (the contract copies need the denial contract) and the reads run after
-- the writes, because a STABLE read can't see a row made by its own call.
CREATE FUNCTION t.l01_referral(p_tag text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid; c uuid := t.n05_contract(p_tag);
BEGIN
    SELECT id INTO v_id FROM public.overdue_actions WHERE contract_id=c AND kind='legal_referral';
    IF v_id IS NULL THEN
        INSERT INTO public.overdue_actions(organization_id,kind,contract_id,customer_id,branch_id,schedule_line_id,business_date,days_late,overdue_amount,status)
        SELECT k.organization_id,'legal_referral',k.id,k.customer_id,k.branch_id,(SELECT id FROM public.schedule_lines WHERE contract_id=k.id ORDER BY seq LIMIT 1),
               current_date,70,1,'open' FROM public.contracts k WHERE k.id=c
        RETURNING id INTO v_id;
    END IF;
    RETURN c;
END $f$;
CREATE FUNCTION t.l01_case() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid; v_cid uuid; c public.contracts;
BEGIN
    SELECT id INTO v_id FROM public.legal_cases WHERE organization_id='d1000000-0000-0000-0000-000000000001' AND idempotency_key='denial-l01-case';
    IF v_id IS NULL THEN
        v_cid := t.n05_contract('l01c');          -- a separate statement: it must see the copy it just made
        SELECT * INTO c FROM public.contracts WHERE id=v_cid;
        INSERT INTO public.legal_cases(organization_id,number,contract_id,customer_id,status,claim_amount,opened_on,idempotency_key)
        VALUES (c.organization_id,'DENIAL-LC-1',c.id,c.customer_id,'preparing',1,current_date,'denial-l01-case') RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $f$;
CREATE FUNCTION t.l01_hearing() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v_id uuid; v_case uuid := t.l01_case();
BEGIN
    SELECT id INTO v_id FROM public.legal_hearings WHERE case_id=v_case;
    IF v_id IS NULL THEN
        INSERT INTO public.legal_hearings(organization_id,case_id,hearing_date)
        VALUES ('d1000000-0000-0000-0000-000000000001',v_case,current_date+30) RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $f$;
INSERT INTO t.denial VALUES
 ('open_legal_case','zz_n9_l01_1_open','legal.manage',$q$SELECT public.open_legal_case(jsonb_build_object('contract_id',t.l01_referral('l01o')),'denial-l01-open')$q$),
 ('update_legal_case','zz_n9_l01_2_update','legal.manage',$q$SELECT public.update_legal_case(t.l01_case(),'{"court":"Denial court"}')$q$),
 ('set_legal_case_status','zz_n9_l01_6_status','legal.manage',$q$SELECT public.set_legal_case_status(t.l01_case(),'{"status":"closed","outcome_kind":"withdrawn"}')$q$),
 ('add_legal_hearing','zz_n9_l01_3_hearing','legal.manage',$q$SELECT public.add_legal_hearing(t.l01_case(),'{"hearing_date":"2030-01-01"}')$q$),
 ('update_legal_hearing','zz_n9_l01_4_hearing_update','legal.manage',$q$SELECT public.update_legal_hearing(t.l01_case(),t.l01_hearing(),'{"notes":"Denial note"}')$q$),
 ('add_legal_case_note','zz_n9_l01_5_note','legal.manage',$q$SELECT public.add_legal_case_note(t.l01_case(),'{"note":"Denial note"}')$q$),
 ('get_legal_case','zz_n9_l01_7_get','legal.view',$q$SELECT public.get_legal_case(t.l01_case())$q$),
 ('list_legal_cases','zz_n9_l01_8_list','legal.view',$q$SELECT public.list_legal_cases('{"status":"all"}')$q$),
 ('list_lawyers','zz_n9_l01_9_lawyers','legal.view',$q$SELECT public.list_lawyers()$q$);
CREATE TABLE t.write_functions AS
SELECT p.proname::text AS fn FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
  AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  AND p.proname NOT IN ('session_context', 'get_owner_dashboard', 'my_shops', 'my_permissions',
                        'auth_record_login', 'auth_record_logout', 'auth_record_password_change', 'get_subscription_status','require_module','get_shop_settings','list_tax_classes','get_shop_profile','list_categories','list_products','get_product','lookup_product','list_product_units','resolve_device');

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
