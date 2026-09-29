-- =============================================================================
-- Seed the first Super Admin
-- =============================================================================
--
-- BEFORE RUNNING:
--   1. In Supabase Dashboard -> Authentication -> Users, create the auth user
--      with the email and password you want.
--   2. Replace the email and name below.
--   3. Run this file in the SQL Editor.
--
-- Idempotent — re-running upserts the super_admins row.
-- =============================================================================

DO $$
DECLARE
    v_admin_email text := 'admin@ecofinpro.com';   -- <-- CHANGE THIS
    v_admin_name  text := 'Super Admin';
    v_admin_phone text := '+201000000000';
    v_auth_id     uuid;
BEGIN
    SELECT id INTO v_auth_id
    FROM auth.users
    WHERE email = v_admin_email
    LIMIT 1;

    IF v_auth_id IS NULL THEN
        RAISE EXCEPTION
            'No auth.users row found for email %. Create the user in Supabase Auth first, then re-run.',
            v_admin_email;
    END IF;

    INSERT INTO public.super_admins (auth_user_id, full_name, email, phone)
    VALUES (v_auth_id, v_admin_name, v_admin_email, v_admin_phone)
    ON CONFLICT (auth_user_id) DO UPDATE
        SET full_name = EXCLUDED.full_name,
            email     = EXCLUDED.email,
            phone     = EXCLUDED.phone,
            is_active = true;

    RAISE NOTICE 'Super admin seeded: % (auth_user_id = %)', v_admin_email, v_auth_id;
END $$;