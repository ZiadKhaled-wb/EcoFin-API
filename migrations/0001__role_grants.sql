-- =============================================================================
-- Migration 0001 — Grant runtime role privileges on all public tables
-- =============================================================================
--
-- Reason: Tables created via the Supabase SQL Editor are owned by `postgres`
--         and carry zero grants to the three Supabase runtime roles
--         (anon, authenticated, service_role). Without these, every query
--         through the Supabase client fails at the privilege check with
--         `permission denied for table X`, before RLS is even consulted.
--
-- Applied to:
--   * dev (jtmrrsiiqmemffyuasqd) — 2026-09-29
--
-- Idempotent. Safe to re-run.
--
-- NOTE: This content is also in Section 26 of docs/db/initialization-v2.1.sql.
--       Fresh installs get it from the bootstrap. This file exists so an
--       already-deployed database can be brought forward without a rebuild.
-- =============================================================================

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO anon', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
        EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    END LOOP;

    FOR t IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' LOOP
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO anon', t);
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO authenticated', t);
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO service_role', t);
    END LOOP;
END $$;

DO $$
DECLARE
    v text;
BEGIN
    FOR v IN SELECT viewname FROM pg_views WHERE schemaname = 'public' LOOP
        EXECUTE format('GRANT SELECT ON public.%I TO anon', v);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
        EXECUTE format('GRANT SELECT ON public.%I TO service_role', v);
    END LOOP;
END $$;

DO $$
DECLARE
    f record;
BEGIN
    FOR f IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname IN (
              'current_user_org_id', 'is_super_admin', 'current_employee_id',
              'current_role', 'is_owner', 'activate_workspace',
              'egp_to_piasters', 'piasters_to_egp', 'set_updated_at'
          )
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION public.%I(%s) TO anon, authenticated, service_role',
            f.proname, f.args
        );
    END LOOP;
END $$;