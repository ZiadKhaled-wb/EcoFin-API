-- =============================================================================
-- Seed 02: dev shops for local work and cross-shop tests (F04-F07). LOCAL / DEV ONLY.
-- Runs as `postgres` after 01_super_admin.sql on `supabase db reset`.
-- Never run this against a real project: the password below is public.
--
-- Every dev login uses the password: LocalDev-Only-2026!
--
--   shop (tenant_slug)  plan        branches              employee (username / email)               role
--   dev-shop-one        retail_pro  BR1 (main), BR2       owner.one   / owner.one@ecotech.test      OWNER
--                                                         cashier.one / cashier.one@ecotech.test    CASHIER (BR1)
--   dev-shop-two        retail      BR1 (main)            owner.two   / owner.two@ecotech.test      OWNER
--                                                         cashier.two / cashier.two@ecotech.test    CASHIER (BR1)
--   both shops (F04)    one login   multi.shop  / multi.shop@ecotech.test     CASHIER (BR1) in dev-shop-one
--                                                                                         ACCOUNTANT in dev-shop-two
--
-- Fixed ids (prefix d...) so tests can refer to them. They don't overlap the ids or
-- slugs used by supabase/tests/smoke_test.sql.
--   orgs      d1000000-0000-0000-0000-00000000000{1,2}
--   branches  d2000000-0000-0000-0000-0000000000{11,12,21}   (shop, branch)
--   auth      d0000000-0000-0000-0000-0000000000{11,12,21,22} (shop, person), ...000099 (both shops)
--   employees d3000000-0000-0000-0000-0000000000{11,12,21,22} (shop, person), ...0000{19,29} (both shops)
-- =============================================================================

-- ------------------------------------------------------------- logins (GoTrue)
WITH u (id, email) AS (VALUES
    ('d0000000-0000-0000-0000-000000000011'::uuid, 'owner.one@ecotech.test'),
    ('d0000000-0000-0000-0000-000000000012'::uuid, 'cashier.one@ecotech.test'),
    ('d0000000-0000-0000-0000-000000000021'::uuid, 'owner.two@ecotech.test'),
    ('d0000000-0000-0000-0000-000000000022'::uuid, 'cashier.two@ecotech.test'),
    ('d0000000-0000-0000-0000-000000000099'::uuid, 'multi.shop@ecotech.test')
)
INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token
)
SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
       extensions.crypt('LocalDev-Only-2026!', extensions.gen_salt('bf')), now(),
       '{"provider": "email", "providers": ["email"]}', '{}', now(), now(),
       '', '', '', '', '', '', '', ''
FROM u;

INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
SELECT u.id::text, u.id,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
FROM auth.users u
WHERE u.id IN ('d0000000-0000-0000-0000-000000000011', 'd0000000-0000-0000-0000-000000000012',
               'd0000000-0000-0000-0000-000000000021', 'd0000000-0000-0000-0000-000000000022',
               'd0000000-0000-0000-0000-000000000099');

-- ------------------------------------------------------------- shops
INSERT INTO public.organizations (id, tenant_slug, name, plan_key, subscription_start, subscription_end) VALUES
    ('d1000000-0000-0000-0000-000000000001', 'dev-shop-one', 'Dev Shop One', 'retail_pro', current_date, current_date + 365),
    ('d1000000-0000-0000-0000-000000000002', 'dev-shop-two', 'Dev Shop Two', 'retail',     current_date, current_date + 365);

INSERT INTO public.org_settings (organization_id) VALUES
    ('d1000000-0000-0000-0000-000000000001'),
    ('d1000000-0000-0000-0000-000000000002');

INSERT INTO public.branches (id, organization_id, code, name, is_main) VALUES
    ('d2000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001', 'BR1', 'Shop One Main', true),
    ('d2000000-0000-0000-0000-000000000012', 'd1000000-0000-0000-0000-000000000001', 'BR2', 'Shop One Branch 2', false),
    ('d2000000-0000-0000-0000-000000000021', 'd1000000-0000-0000-0000-000000000002', 'BR1', 'Shop Two Main', true);

-- ------------------------------------------------------------- employees
INSERT INTO public.employees (id, organization_id, auth_user_id, full_name, email, username, role, default_branch_id) VALUES
    ('d3000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000011',
     'Owner One', 'owner.one@ecotech.test', 'owner.one', 'OWNER', 'd2000000-0000-0000-0000-000000000011'),
    ('d3000000-0000-0000-0000-000000000012', 'd1000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000012',
     'Cashier One', 'cashier.one@ecotech.test', 'cashier.one', 'CASHIER', 'd2000000-0000-0000-0000-000000000011'),
    ('d3000000-0000-0000-0000-000000000021', 'd1000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000021',
     'Owner Two', 'owner.two@ecotech.test', 'owner.two', 'OWNER', 'd2000000-0000-0000-0000-000000000021'),
    ('d3000000-0000-0000-0000-000000000022', 'd1000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000022',
     'Cashier Two', 'cashier.two@ecotech.test', 'cashier.two', 'CASHIER', 'd2000000-0000-0000-0000-000000000021'),
    -- F04: one login in both shops (same username in each shop is allowed: unique per shop).
    ('d3000000-0000-0000-0000-000000000019', 'd1000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000099',
     'Multi Shop', 'multi.shop@ecotech.test', 'multi.shop', 'CASHIER', 'd2000000-0000-0000-0000-000000000011'),
    ('d3000000-0000-0000-0000-000000000029', 'd1000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000099',
     'Multi Shop', 'multi.shop@ecotech.test', 'multi.shop', 'ACCOUNTANT', 'd2000000-0000-0000-0000-000000000021');

-- Branch scope. OWNER sees every branch without rows here; cashiers get their branch.
INSERT INTO public.employee_branches (organization_id, employee_id, branch_id) VALUES
    ('d1000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000012', 'd2000000-0000-0000-0000-000000000011'),
    ('d1000000-0000-0000-0000-000000000002', 'd3000000-0000-0000-0000-000000000022', 'd2000000-0000-0000-0000-000000000021'),
    ('d1000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000019', 'd2000000-0000-0000-0000-000000000011'),
    ('d1000000-0000-0000-0000-000000000002', 'd3000000-0000-0000-0000-000000000029', 'd2000000-0000-0000-0000-000000000021');

-- =============================================================================
-- INT-4 (EC-133): cash sale end to end. LOCAL / DEV ONLY. Same dev password as above.
-- Logins: docs/testing/int-4/LOGINS.md. No POS devices: pairing is part of the INT-4 flow.
--   shop (tenant_slug)  plan        ETA                          employees
--   int4-shop-a         retail_pro  on, preprod, fake creds      owner.a, manager.a (BRANCH_MANAGER), cashier.a1, cashier.a2
--   int4-shop-b         retail_pro  off                          owner.b, cashier.b
-- Shop A: caps CASHIER 5 / BRANCH_MANAGER 15, a safe with 5000.00, an org bank account, and
-- products INT4-CHAIR (ETA code, 20 in stock), INT4-PHONE (serialized, 12 months warranty,
-- serials INT4-SN-001..003), INT4-LAMP (no ETA code, 10), INT4-LAST (ETA code, 1: the last unit).
--   orgs  e4100000-0000-0000-0000-00000000000{1,2}   branches  e4200000-...-0000000000{11,21}
--   auth  e4000000-0000-0000-0000-0000000000{11..14,21,22}   employees  e4300000-... (same suffixes)
-- =============================================================================
WITH u (id, email) AS (VALUES
    ('e4000000-0000-0000-0000-000000000011'::uuid, 'owner.a@int4.test'),
    ('e4000000-0000-0000-0000-000000000012'::uuid, 'manager.a@int4.test'),
    ('e4000000-0000-0000-0000-000000000013'::uuid, 'cashier.a1@int4.test'),
    ('e4000000-0000-0000-0000-000000000014'::uuid, 'cashier.a2@int4.test'),
    ('e4000000-0000-0000-0000-000000000021'::uuid, 'owner.b@int4.test'),
    ('e4000000-0000-0000-0000-000000000022'::uuid, 'cashier.b@int4.test')
)
INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token
)
SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
       extensions.crypt('LocalDev-Only-2026!', extensions.gen_salt('bf')), now(),
       '{"provider": "email", "providers": ["email"]}', '{}', now(), now(),
       '', '', '', '', '', '', '', ''
FROM u;

INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
SELECT u.id::text, u.id,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
FROM auth.users u
WHERE u.email LIKE '%@int4.test';

INSERT INTO public.organizations (id, tenant_slug, name, plan_key, subscription_start, subscription_end,
                                  tax_registration_no, legal_name) VALUES
    ('e4100000-0000-0000-0000-000000000001', 'int4-shop-a', 'INT4 Shop A', 'retail_pro', current_date, current_date + 365,
     '674859545', 'INT4 Furniture LLC'),
    ('e4100000-0000-0000-0000-000000000002', 'int4-shop-b', 'INT4 Shop B', 'retail_pro', current_date, current_date + 365,
     NULL, NULL);
INSERT INTO public.org_settings (organization_id) VALUES
    ('e4100000-0000-0000-0000-000000000001'), ('e4100000-0000-0000-0000-000000000002');
INSERT INTO public.eta_settings (organization_id) VALUES
    ('e4100000-0000-0000-0000-000000000001'), ('e4100000-0000-0000-0000-000000000002');
INSERT INTO public.installment_policies (organization_id, version, max_months, markup_tiers) VALUES
    ('e4100000-0000-0000-0000-000000000001', 1, 12, '[{"up_to_months":12,"pct":0}]'),
    ('e4100000-0000-0000-0000-000000000002', 1, 12, '[{"up_to_months":12,"pct":0}]');
INSERT INTO public.branches (id, organization_id, code, name, is_main) VALUES
    ('e4200000-0000-0000-0000-000000000011', 'e4100000-0000-0000-0000-000000000001', 'MAIN', 'INT4 A Main', true),
    ('e4200000-0000-0000-0000-000000000021', 'e4100000-0000-0000-0000-000000000002', 'MAIN', 'INT4 B Main', true);
INSERT INTO public.cash_accounts (organization_id, branch_id, name, kind) VALUES
    ('e4100000-0000-0000-0000-000000000001', 'e4200000-0000-0000-0000-000000000011', 'الخزنة الرئيسية', 'safe'),
    ('e4100000-0000-0000-0000-000000000002', 'e4200000-0000-0000-0000-000000000021', 'الخزنة الرئيسية', 'safe');

INSERT INTO public.employees (id, organization_id, auth_user_id, full_name, email, username, role, default_branch_id)
SELECT ('e4300000-0000-0000-0000-0000000000' || s)::uuid, o::uuid, ('e4000000-0000-0000-0000-0000000000' || s)::uuid,
       n, lower(replace(n, ' ', '.')) || '@int4.test', lower(replace(n, ' ', '.')), r::public.employee_role, b::uuid
FROM (VALUES
    ('11', 'e4100000-0000-0000-0000-000000000001', 'Owner A',    'OWNER',          'e4200000-0000-0000-0000-000000000011'),
    ('12', 'e4100000-0000-0000-0000-000000000001', 'Manager A',  'BRANCH_MANAGER', 'e4200000-0000-0000-0000-000000000011'),
    ('13', 'e4100000-0000-0000-0000-000000000001', 'Cashier A1', 'CASHIER',        'e4200000-0000-0000-0000-000000000011'),
    ('14', 'e4100000-0000-0000-0000-000000000001', 'Cashier A2', 'CASHIER',        'e4200000-0000-0000-0000-000000000011'),
    ('21', 'e4100000-0000-0000-0000-000000000002', 'Owner B',    'OWNER',          'e4200000-0000-0000-0000-000000000021'),
    ('22', 'e4100000-0000-0000-0000-000000000002', 'Cashier B',  'CASHIER',        'e4200000-0000-0000-0000-000000000021')
) AS e (s, o, n, r, b);
INSERT INTO public.employee_branches (organization_id, employee_id, branch_id) VALUES
    ('e4100000-0000-0000-0000-000000000001', 'e4300000-0000-0000-0000-000000000012', 'e4200000-0000-0000-0000-000000000011'),
    ('e4100000-0000-0000-0000-000000000001', 'e4300000-0000-0000-0000-000000000013', 'e4200000-0000-0000-0000-000000000011'),
    ('e4100000-0000-0000-0000-000000000001', 'e4300000-0000-0000-0000-000000000014', 'e4200000-0000-0000-0000-000000000011'),
    ('e4100000-0000-0000-0000-000000000002', 'e4300000-0000-0000-0000-000000000022', 'e4200000-0000-0000-0000-000000000021');

-- The rest goes through the real write functions, signed in as each shop's owner (as the API does).
CREATE FUNCTION pg_temp.int4_sign_in(p_user uuid, p_org uuid) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.sub', p_user::text, true),
           set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true),
           set_config('app.org_id', '', true),
           set_config('request.headers', json_build_object('x-org-id', p_org)::text, true);
$$;

DO $$
DECLARE
    a constant uuid := 'e4100000-0000-0000-0000-000000000001';
    br constant uuid := 'e4200000-0000-0000-0000-000000000011';
    v_safe uuid; v_chair uuid; v_phone uuid; v_lamp uuid; v_last uuid;
BEGIN
    PERFORM pg_temp.int4_sign_in('e4000000-0000-0000-0000-000000000011', a);
    SELECT id INTO v_safe FROM public.cash_accounts WHERE organization_id = a AND kind = 'safe';
    PERFORM public.update_branch(br, 'INT4 A Main', '16 Abbas El Akkad', 'Nasr City', 'Cairo', NULL, '0', v_safe, '14');
    PERFORM public.create_cash_account('INT4 Bank', 'bank', NULL);
    PERFORM public.post_cash_opening(v_safe, '5000.00', 'INT-4 opening', 'int4-seed-safe');
    PERFORM public.update_org_settings('{"discount_caps": {"CASHIER": 5, "BRANCH_MANAGER": 15}}');
    -- Fake credentials: they only work against the local fake ETA (npm run fake-eta).
    PERFORM public.set_eta_settings('preprod', 'int4-fake-client', 'int4-fake-secret', '4753', true);
    v_chair := public.create_product('{"name_ar":"كرسي INT4","name_en":"INT4 Chair","sku":"INT4-CHAIR","barcode":"6221000000011","cash_price":"1000.00","eta_item_code":"EG-674859545-1001","eta_item_type":"EGS"}');
    v_phone := public.create_product('{"name_ar":"هاتف INT4","name_en":"INT4 Phone","sku":"INT4-PHONE","barcode":"6221000000028","cash_price":"5000.00","is_serialized":true,"warranty_months":12,"eta_item_code":"EG-674859545-1002","eta_item_type":"EGS"}');
    v_lamp := public.create_product('{"name_ar":"مصباح INT4","name_en":"INT4 Lamp","sku":"INT4-LAMP","barcode":"6221000000035","cash_price":"200.00"}');
    v_last := public.create_product('{"name_ar":"آخر قطعة INT4","name_en":"INT4 Last Unit","sku":"INT4-LAST","barcode":"6221000000042","cash_price":"300.00","eta_item_code":"EG-674859545-1004","eta_item_type":"EGS"}');
    PERFORM public.post_stock_adjustment(br, 'found', 'INT-4 seed', jsonb_build_array(
        jsonb_build_object('product_id', v_chair, 'quantity', 20),
        jsonb_build_object('product_id', v_lamp, 'quantity', 10),
        jsonb_build_object('product_id', v_last, 'quantity', 1)), 'int4-seed-stock');
    PERFORM public.register_units(v_phone, br, '3000.00', '["INT4-SN-001","INT4-SN-002","INT4-SN-003"]', 'INT-4 seed', 'int4-seed-units');
END $$;

DO $$
DECLARE
    b constant uuid := 'e4100000-0000-0000-0000-000000000002';
    br constant uuid := 'e4200000-0000-0000-0000-000000000021';
    v_safe uuid; v_p uuid;
BEGIN
    PERFORM pg_temp.int4_sign_in('e4000000-0000-0000-0000-000000000021', b);
    SELECT id INTO v_safe FROM public.cash_accounts WHERE organization_id = b AND kind = 'safe';
    PERFORM public.update_branch(br, 'INT4 B Main', NULL, NULL, NULL, NULL, NULL, v_safe, NULL);
    PERFORM public.post_cash_opening(v_safe, '5000.00', 'INT-4 opening', 'int4-seed-safe-b');
    v_p := public.create_product('{"name_ar":"طاولة INT4","name_en":"INT4 Table","sku":"INT4-TABLE","barcode":"6221000000059","cash_price":"300.00"}');
    PERFORM public.post_stock_adjustment(br, 'found', 'INT-4 seed', jsonb_build_array(
        jsonb_build_object('product_id', v_p, 'quantity', 10)), 'int4-seed-stock-b');
END $$;
