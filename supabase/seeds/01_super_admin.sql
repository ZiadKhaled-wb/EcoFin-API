-- =============================================================================
-- Seed 01: first platform super admin. LOCAL / DEV ONLY.
-- Runs as `postgres` after the migrations on `supabase db reset` ([db.seed] in config.toml).
-- Never run this against a real project: the password below is public.
--
--   email:    superadmin@ecotech.test
--   password: LocalDev-Only-2026!
--
-- The baseline models platform admins as rows in public.super_admins
-- (auth_user_id -> auth.users.id); app.is_super_admin() checks that table for auth.uid().
-- GoTrue needs the auth.users row (bcrypt password, confirmed email, '' tokens) and an
-- 'email' auth.identities row for password login.
-- =============================================================================

INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token
) VALUES (
    '00000000-0000-0000-0000-000000000000', 'f0000000-0000-0000-0000-000000000001',
    'authenticated', 'authenticated', 'superadmin@ecotech.test',
    extensions.crypt('LocalDev-Only-2026!', extensions.gen_salt('bf')), now(),
    '{"provider": "email", "providers": ["email"]}', '{"full_name": "Local Super Admin"}', now(), now(),
    '', '', '', '', '', '', '', ''
);

INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
VALUES (
    'f0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001',
    '{"sub": "f0000000-0000-0000-0000-000000000001", "email": "superadmin@ecotech.test", "email_verified": true}',
    'email', now(), now(), now()
);

INSERT INTO public.super_admins (auth_user_id, full_name, email)
VALUES ('f0000000-0000-0000-0000-000000000001', 'Local Super Admin', 'superadmin@ecotech.test');
