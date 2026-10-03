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
--
-- Fixed ids (prefix d...) so tests can refer to them. They don't overlap the ids or
-- slugs used by supabase/tests/smoke_test.sql.
--   orgs      d1000000-0000-0000-0000-00000000000{1,2}
--   branches  d2000000-0000-0000-0000-0000000000{11,12,21}   (shop, branch)
--   auth      d0000000-0000-0000-0000-0000000000{11,12,21,22} (shop, person)
--   employees d3000000-0000-0000-0000-0000000000{11,12,21,22} (shop, person)
-- =============================================================================

-- ------------------------------------------------------------- logins (GoTrue)
WITH u (id, email) AS (VALUES
    ('d0000000-0000-0000-0000-000000000011'::uuid, 'owner.one@ecotech.test'),
    ('d0000000-0000-0000-0000-000000000012'::uuid, 'cashier.one@ecotech.test'),
    ('d0000000-0000-0000-0000-000000000021'::uuid, 'owner.two@ecotech.test'),
    ('d0000000-0000-0000-0000-000000000022'::uuid, 'cashier.two@ecotech.test')
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
               'd0000000-0000-0000-0000-000000000021', 'd0000000-0000-0000-0000-000000000022');

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
     'Cashier Two', 'cashier.two@ecotech.test', 'cashier.two', 'CASHIER', 'd2000000-0000-0000-0000-000000000021');

-- Branch scope. OWNER sees every branch without rows here; cashiers get their branch.
INSERT INTO public.employee_branches (organization_id, employee_id, branch_id) VALUES
    ('d1000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000012', 'd2000000-0000-0000-0000-000000000011'),
    ('d1000000-0000-0000-0000-000000000002', 'd3000000-0000-0000-0000-000000000022', 'd2000000-0000-0000-0000-000000000021');
