-- =============================================================================
-- Migration 0003 — Lock down direct database access (anon / authenticated)
-- =============================================================================
--
-- Purpose: close the direct-PostgREST holes found in REPO_AUDIT.md
--          (§4.2 Critical balance views, §4.2 High `plans`, §4.3 Critical
--          tenant DML and reads, §4.3 Critical `organizations_tenant_update`,
--          §4.3 Medium `activate_workspace`; §6 point 1). The browser must
--          never read or write the database directly (F05). The API keeps
--          working: service_role is untouched, and the two reads the API makes
--          with the user's JWT still pass (see "Who uses what" below).
--
-- Date: 2026-10-02
--
-- Applied to:
--
-- Idempotent. Safe to re-run. Runs in one transaction (BEGIN ... COMMIT) and
-- checks its own result at the end; if any check fails, nothing is applied.
-- Re-running it after 0004 recreates migration_backup with a snapshot of the
-- already-locked state (harmless: a rollback from it changes nothing); run
-- 0004 again afterwards.
-- Requires Postgres 15+ (security_invoker views) and Supabase's auth.uid().
-- Run as `postgres`.
--
-- Companion files:
--   0003_db_lockdown.verify.sql    run after applying; every row must say PASS
--   0003_db_lockdown.rollback.sql  restores the pre-0003 grants and policies
--                                  from the snapshot taken in step 0. Valid
--                                  only right after 0003, before any later
--                                  migration, and before 0004 drops the
--                                  snapshot.
--
-- -----------------------------------------------------------------------------
-- Who uses what (grep of src/ for .from( / .rpc( / supabaseUser / supabaseAnon)
-- -----------------------------------------------------------------------------
--   supabaseUser(jwt)  -> role `authenticated`, RLS applies
--     employees     SELECT  src/middleware/auth.ts:78-85 (attachEmployee)
--                           columns: id, organization_id, auth_id, branch_id,
--                           role, permissions, is_active, username, email,
--                           must_change_password; filter auth_id = caller
--     super_admins  SELECT  src/middleware/auth.ts:127-131 (loadSuperAdmin)
--                           src/services/auth.service.ts:176-179 (login step 5)
--                           columns: id, auth_user_id, email, full_name,
--                           is_active; filter auth_user_id = caller
--   supabaseAnon       -> only GoTrue calls (auth.getUser, signInWithPassword,
--                         resetPasswordForEmail, refreshSession). No .from()
--                         or .rpc(), so it needs no table or function grant.
--   supabaseAdmin      -> service_role (bypasses RLS; grants not changed here)
--     organizations, employees, saaslicenses (SELECT/UPDATE),
--     rpc('activate_workspace')            src/services/auth.service.ts
--   EcoFin-Web         -> supabase.auth.* only (ResetPasswordPage). No tables.
--
-- So after this migration `authenticated` gets exactly:
--   * column SELECT on those 10 employees columns and 5 super_admins columns
--     (no table-level SELECT anywhere, so salary, national_id, phone, every
--     other table, the balance views and every ledger are denied);
--   * RLS on both tables limited to the caller's own row
--     (employees.auth_id / super_admins.auth_user_id = auth.uid()); all other
--     policies on those two tables are dropped;
--   * EXECUTE on auth.uid() (Supabase default, checked, not changed).
-- `anon` gets nothing.
--
-- Side effect, intended: an inactive employee can now read their own row, so
-- attachEmployee returns ACCOUNT_DISABLED (as its code intends) instead of
-- "no employee". The old org policy hid the row via current_user_org_id(),
-- which filters is_active. Super admins: same result as before; the code
-- checks is_active itself.
--
-- -----------------------------------------------------------------------------
-- Function inventory: every function in schema public
-- (bootstrap initialization-v2.1.sql + 0001 + 0002)
-- -----------------------------------------------------------------------------
--   function                          decision  reason
--   current_user_org_id()             KEEP      used inside the tenant RLS
--                                               policies (org-scoped tables,
--                                               organizations, audit_logs).
--                                               No live API path needs it any
--                                               more (authenticated has no
--                                               SELECT on those tables), but the
--                                               policies must keep working if a
--                                               later migration grants a table.
--                                               EXECUTE kept for authenticated,
--                                               service_role; revoked from
--                                               PUBLIC, anon.
--   is_super_admin()                  KEEP      used inside policies on
--                                               organizations, saaslicenses,
--                                               organization_plans/addons,
--                                               audit_logs. Same grants as above.
--   current_employee_id()             REVOKE    not used in any policy; not called
--                                               by the API.
--   current_role()                    REVOKE    not used in any policy; only
--                                               called inside is_owner(), which
--                                               is SECURITY DEFINER (runs as
--                                               owner), so no caller grant needed.
--   is_owner()                        REVOKE    not used in any policy; not called.
--   activate_workspace(text,uuid,text) REVOKE   SECURITY DEFINER; called only via
--                                               supabaseAdmin (service_role).
--                                               Audit §4.3: 0001 re-granted it
--                                               to anon/authenticated.
--   egp_to_piasters(numeric)          REVOKE    pure helper; not used by any
--                                               policy, view, default or API call.
--   piasters_to_egp(bigint)           REVOKE    same.
--   set_updated_at()                  REVOKE    trigger function. EXECUTE is
--                                               checked when a trigger is
--                                               created, not when it fires;
--                                               service_role keeps it anyway.
--
--   "REVOKE" = EXECUTE revoked from PUBLIC, anon and authenticated.
--   Every function keeps (or gets) an explicit EXECUTE grant to service_role,
--   so removing the PUBLIC grant can't break the API.
--   Any other non-extension function found in public at apply time is also
--   REVOKEd and named in a NOTICE. Functions owned by an extension (e.g. citext,
--   if it was installed into public) are left alone.
--
-- -----------------------------------------------------------------------------
-- Effects on future objects (ALTER DEFAULT PRIVILEGES, role postgres)
-- -----------------------------------------------------------------------------
--   New tables, sequences and functions created by `postgres` are no longer
--   granted to anon/authenticated. New functions created by `postgres` in ANY
--   schema no longer get the built-in PUBLIC EXECUTE (Postgres only lets you
--   remove that globally, not per schema). A later migration that needs the
--   API's user client to read a new table, or a new RLS helper, must GRANT
--   SELECT / EXECUTE to authenticated explicitly.
--   Outside `public` this also affects service_role: Supabase's per-schema
--   default grants service_role EXECUTE only in `public`, so a function that
--   `postgres` creates in another schema needs an explicit GRANT to any role
--   that calls it, service_role included.
--   Objects created by `supabase_admin` still follow Supabase's own defaults;
--   `postgres` can't change those.
--
--   Fail-closed: if any object in public is owned by a role other than
--   postgres (e.g. supabase_admin), postgres's REVOKE can't remove its grants
--   and the self-check in step 7 aborts the whole migration, naming it.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Preconditions
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF current_setting('server_version_num')::int < 150000 THEN
        RAISE EXCEPTION '0003: needs Postgres 15+ for security_invoker views (found %)',
            current_setting('server_version');
    END IF;
    IF to_regrole('anon') IS NULL
       OR to_regrole('authenticated') IS NULL
       OR to_regrole('service_role') IS NULL THEN
        RAISE EXCEPTION '0003: Supabase roles anon / authenticated / service_role not found';
    END IF;
    IF to_regprocedure('auth.uid()') IS NULL THEN
        RAISE EXCEPTION '0003: auth.uid() not found (the own-row policies need it)';
    END IF;
    IF NOT pg_has_role('postgres', 'MEMBER') THEN
        RAISE EXCEPTION '0003: run as postgres (needed for ALTER DEFAULT PRIVILEGES FOR ROLE postgres), not %',
            current_user;
    END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 0. Snapshot the pre-lockdown state (once) for the rollback
-- -----------------------------------------------------------------------------
-- Stored in a schema PostgREST does not expose and no API role can read.
-- On a re-run the existing snapshot is kept, so it always holds the state
-- from before the FIRST run. The rollback drops it.

CREATE SCHEMA IF NOT EXISTS migration_backup;
REVOKE ALL ON SCHEMA migration_backup FROM PUBLIC, anon, authenticated;
COMMENT ON SCHEMA migration_backup IS
    'Pre-migration snapshots used by rollback scripts. Not exposed to the API.';

CREATE TABLE IF NOT EXISTS migration_backup.m0003_pre_lockdown (
    kind            text        NOT NULL
        CHECK (kind IN ('relation', 'column', 'function', 'default_acl', 'policy')),
    object_identity text        NOT NULL,
    relkind         "char",
    acl             aclitem[],
    detail          jsonb       NOT NULL DEFAULT '{}'::jsonb,
    taken_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (kind, object_identity)
);
-- Lock the whole schema, not just this table.
REVOKE ALL ON ALL TABLES    IN SCHEMA migration_backup FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA migration_backup FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA migration_backup FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
    v_old_path text := current_setting('search_path');
    v_postgres oid  := 'postgres'::regrole;
BEGIN
    IF EXISTS (SELECT 1 FROM migration_backup.m0003_pre_lockdown) THEN
        RAISE NOTICE '0003: snapshot already present (taken %), keeping it',
            (SELECT min(taken_at) FROM migration_backup.m0003_pre_lockdown);
        RETURN;
    END IF;

    -- With only pg_catalog on the path, deparsed policy expressions come out
    -- schema-qualified, so the rollback can recreate them verbatim.
    PERFORM set_config('search_path', 'pg_catalog', true);

    -- Tables, partitioned tables, views, matviews, foreign tables, sequences.
    -- detail keeps the RLS flag (plans) and reloptions (security_invoker).
    INSERT INTO migration_backup.m0003_pre_lockdown (kind, object_identity, relkind, acl, detail)
    SELECT 'relation',
           format('%I.%I', n.nspname, c.relname),
           c.relkind,
           c.relacl,
           jsonb_build_object(
               'relrowsecurity', c.relrowsecurity,
               'reloptions', COALESCE(to_jsonb(c.reloptions), '[]'::jsonb))
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S');

    -- Column-level grants: a table-level REVOKE removes these too.
    INSERT INTO migration_backup.m0003_pre_lockdown (kind, object_identity, relkind, acl, detail)
    SELECT 'column',
           format('%I.%I.%I', n.nspname, c.relname, a.attname),
           c.relkind,
           a.attacl,
           jsonb_build_object('table', format('%I.%I', n.nspname, c.relname),
                              'column', a.attname)
    FROM pg_attribute a
    JOIN pg_class c     ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND a.attacl IS NOT NULL;

    -- Functions not owned by an extension. A NULL acl means "built-in
    -- default" (PUBLIC EXECUTE); store it explicitly so restore is literal.
    INSERT INTO migration_backup.m0003_pre_lockdown (kind, object_identity, acl, detail)
    SELECT 'function',
           format('%I.%I(%s)', n.nspname, p.proname, oidvectortypes(p.proargtypes)),
           COALESCE(p.proacl, acldefault('f', p.proowner)),
           jsonb_build_object('proacl_was_null', p.proacl IS NULL)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_catalog.pg_proc'::regclass
            AND d.objid = p.oid
            AND d.deptype = 'e');

    -- Default privileges of role postgres, global and IN SCHEMA public.
    -- A missing global row means the built-in default (acldefault); a missing
    -- per-schema row means "adds nothing" (NULL).
    INSERT INTO migration_backup.m0003_pre_lockdown (kind, object_identity, acl, detail)
    SELECT 'default_acl',
           t.scope || ':' || t.objtype,
           COALESCE(d.defaclacl,
                    CASE WHEN t.scope = 'global'
                         THEN acldefault(t.acl_kind::"char", v_postgres) END),
           jsonb_build_object('scope', t.scope, 'objtype', t.objtype,
                              'row_existed', d.oid IS NOT NULL)
    FROM (VALUES ('global', 'r', 'r'), ('global', 'S', 's'), ('global', 'f', 'f'),
                 ('public', 'r', 'r'), ('public', 'S', 's'), ('public', 'f', 'f'))
         AS t(scope, objtype, acl_kind)
    LEFT JOIN pg_default_acl d
           ON d.defaclrole = v_postgres
          AND d.defaclobjtype = t.objtype::"char"
          AND d.defaclnamespace = CASE WHEN t.scope = 'global' THEN 0::oid
                                       ELSE 'public'::regnamespace::oid END;

    -- Every policy 0003 drops: organizations_tenant_update (step 4) and all
    -- policies on employees and super_admins (step 4b).
    INSERT INTO migration_backup.m0003_pre_lockdown (kind, object_identity, detail)
    SELECT 'policy',
           format('%I.%I.%I', n.nspname, c.relname, pol.polname),
           jsonb_build_object(
               'table',      format('%I.%I', n.nspname, c.relname),
               'name',       pol.polname,
               'permissive', pol.polpermissive,
               'cmd',        CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT'
                                             WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE'
                                             ELSE 'ALL' END,
               'roles',      (SELECT jsonb_agg(CASE WHEN r = 0 THEN 'PUBLIC'
                                                    ELSE quote_ident(pg_get_userbyid(r)) END)
                              FROM unnest(pol.polroles) AS r),
               'using',      pg_get_expr(pol.polqual, pol.polrelid),
               'with_check', pg_get_expr(pol.polwithcheck, pol.polrelid))
    FROM pg_policy pol
    JOIN pg_class c     ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE (pol.polrelid = to_regclass('public.organizations')
           AND pol.polname = 'organizations_tenant_update')
       OR pol.polrelid = to_regclass('public.employees')
       OR pol.polrelid = to_regclass('public.super_admins');

    PERFORM set_config('search_path', v_old_path, true);

    RAISE NOTICE '0003: snapshot taken (% rows)',
        (SELECT count(*) FROM migration_backup.m0003_pre_lockdown);
END $$;


-- -----------------------------------------------------------------------------
-- 1. Table, view and sequence grants
-- -----------------------------------------------------------------------------
-- ALL TABLES covers tables, views, materialized views and foreign tables.

-- anon and authenticated: nothing at table level. A table-level REVOKE also
-- removes every column-level grant, so the GRANTs below start from zero on
-- every run (idempotent). ALL also covers MAINTAIN on Postgres 17+.
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;

-- authenticated: only the columns the API reads with the user's JWT.
-- attachEmployee (src/middleware/auth.ts:81-83)
GRANT SELECT (id, organization_id, auth_id, branch_id, role, permissions,
              is_active, username, email, must_change_password)
    ON TABLE public.employees TO authenticated;
-- loadSuperAdmin (src/middleware/auth.ts:130), login step 5 (auth.service.ts:178)
GRANT SELECT (id, auth_user_id, email, full_name, is_active)
    ON TABLE public.super_admins TO authenticated;


-- -----------------------------------------------------------------------------
-- 2. Balance views: run with the caller's rights so RLS applies
-- -----------------------------------------------------------------------------
-- anon and authenticated lost SELECT on the views in step 1. security_invoker
-- is defence in depth: if a later migration grants a view again, it runs
-- with the caller's rights, so the base tables' RLS applies instead of the
-- owner's. The explicit revoke below just documents step 1.

ALTER VIEW IF EXISTS public.vault_balances       SET (security_invoker = true);
ALTER VIEW IF EXISTS public.wallet_balances      SET (security_invoker = true);
ALTER VIEW IF EXISTS public.installment_balances SET (security_invoker = true);
ALTER VIEW IF EXISTS public.contract_balances    SET (security_invoker = true);

DO $$
DECLARE
    v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['public.vault_balances', 'public.wallet_balances',
                             'public.installment_balances', 'public.contract_balances']
    LOOP
        IF to_regclass(v) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON TABLE %s FROM anon, authenticated', v);
        END IF;
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- 3. plans: turn RLS on (anon and authenticated lost every grant in step 1;
--    RLS is the backstop if one comes back)
-- -----------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.plans ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- 4. organizations: tenants may no longer update their own org row
--    (is_suspended, plan_key, subscription_end_date, ...). Service role only.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS organizations_tenant_update ON public.organizations;


-- -----------------------------------------------------------------------------
-- 4b. employees / super_admins: a user reads only their own row
-- -----------------------------------------------------------------------------
-- Drops every other policy on the two tables (permissive policies are OR-ed,
-- so any wider one left behind would re-open other rows). Writes have no
-- policy at all, so RLS also denies them if a write grant ever comes back.
-- service_role bypasses RLS; the SECURITY DEFINER helpers run as the table
-- owner and bypass it too (the self-check asserts RLS is not FORCEd).

DO $$
DECLARE
    pol record;
BEGIN
    FOR pol IN
        SELECT p.polname, p.polrelid::regclass::text AS tbl
        FROM pg_policy p
        WHERE p.polrelid IN (to_regclass('public.employees'), to_regclass('public.super_admins'))
          AND p.polname NOT IN ('employees_self_read', 'super_admins_self_read')
    LOOP
        EXECUTE format('DROP POLICY %I ON %s', pol.polname, pol.tbl);
        RAISE NOTICE '0003: dropped policy % on %', pol.polname, pol.tbl;
    END LOOP;
END $$;

ALTER TABLE public.employees    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employees_self_read ON public.employees;
CREATE POLICY employees_self_read ON public.employees
    FOR SELECT TO authenticated
    USING (auth_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS super_admins_self_read ON public.super_admins;
CREATE POLICY super_admins_self_read ON public.super_admins
    FOR SELECT TO authenticated
    USING (auth_user_id = (SELECT auth.uid()));


-- -----------------------------------------------------------------------------
-- 5. Functions (see the inventory in the header)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    f       record;
    v_keep  oid[] := ARRAY[
        to_regprocedure('public.current_user_org_id()')::oid,
        to_regprocedure('public.is_super_admin()')::oid
    ];
    v_known text[] := ARRAY[
        'current_user_org_id', 'is_super_admin', 'current_employee_id',
        'current_role', 'is_owner', 'activate_workspace',
        'egp_to_piasters', 'piasters_to_egp', 'set_updated_at'
    ];
BEGIN
    FOR f IN
        SELECT p.oid, p.proname, p.oid::regprocedure::text AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_catalog.pg_proc'::regclass
                AND d.objid = p.oid
                AND d.deptype = 'e')
        ORDER BY p.proname
    LOOP
        EXECUTE format('REVOKE EXECUTE ON ROUTINE %s FROM PUBLIC, anon', f.sig);
        IF f.oid = ANY (v_keep) THEN
            EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO authenticated', f.sig);
        ELSE
            EXECUTE format('REVOKE EXECUTE ON ROUTINE %s FROM authenticated', f.sig);
        END IF;
        EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO service_role', f.sig);

        IF NOT (f.proname = ANY (v_known)) THEN
            RAISE NOTICE '0003: % is not in the inventory; EXECUTE revoked from PUBLIC, anon, authenticated',
                f.sig;
        END IF;
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- 6. Default privileges: nothing new is auto-granted to anon / authenticated
-- -----------------------------------------------------------------------------
-- Supabase sets these per schema (IN SCHEMA public). The global lines catch
-- any global grants, and the global PUBLIC line is the only way to stop new
-- functions getting PUBLIC EXECUTE (per-schema REVOKE can't remove it).

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON FUNCTIONS FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres
    REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
    REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
    REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 7. Self-check: abort the whole migration if anything is still open
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_bad      text;
    v_postgres oid := 'postgres'::regrole;
BEGIN
    -- anon: no privilege on any relation in public
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND (   (c.relkind IN ('r', 'p', 'v', 'm', 'f')
               AND has_table_privilege('anon', c.oid,
                     'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))
           OR (c.relkind = 'S'
               AND has_sequence_privilege('anon', c.oid, 'USAGE, SELECT, UPDATE')));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: anon still has privileges on %', v_bad;
    END IF;

    -- authenticated: no table-level privilege of any kind (SELECT included)
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND (   (c.relkind IN ('r', 'p', 'v', 'm', 'f')
               AND has_table_privilege('authenticated', c.oid,
                     'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'))
           OR (c.relkind = 'S'
               AND has_sequence_privilege('authenticated', c.oid, 'USAGE, SELECT, UPDATE')));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: authenticated still has table-level privileges on %', v_bad;
    END IF;

    -- authenticated: column SELECT on exactly the columns the API reads.
    -- "missing" breaks the API; "extra" leaks data.
    WITH expected(tbl, col) AS (VALUES
        ('employees', 'id'), ('employees', 'organization_id'), ('employees', 'auth_id'),
        ('employees', 'branch_id'), ('employees', 'role'), ('employees', 'permissions'),
        ('employees', 'is_active'), ('employees', 'username'), ('employees', 'email'),
        ('employees', 'must_change_password'),
        ('super_admins', 'id'), ('super_admins', 'auth_user_id'), ('super_admins', 'email'),
        ('super_admins', 'full_name'), ('super_admins', 'is_active')),
    actual AS (
        SELECT c.relname::text AS tbl, a.attname::text AS col
        FROM pg_attribute a
        JOIN pg_class c     ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND has_column_privilege('authenticated', c.oid, a.attnum, 'SELECT'))
    SELECT string_agg(COALESCE(e.tbl, x.tbl) || '.' || COALESCE(e.col, x.col)
                      || CASE WHEN x.col IS NULL THEN ' (missing)' ELSE ' (extra)' END, ', ')
    INTO v_bad
    FROM expected e
    FULL JOIN actual x ON x.tbl = e.tbl AND x.col = e.col
    WHERE e.col IS NULL OR x.col IS NULL;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: authenticated column SELECT is not exactly the API columns: %', v_bad;
    END IF;

    -- authenticated: no column-level write
    SELECT string_agg(format('%I.%I.%I', n.nspname, c.relname, a.attname), ', ') INTO v_bad
    FROM pg_attribute a
    JOIN pg_class c     ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND has_column_privilege('authenticated', c.oid, a.attnum, 'INSERT, UPDATE, REFERENCES');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: authenticated can still write columns %', v_bad;
    END IF;

    -- own-row policies: the only policies on employees / super_admins, RLS on
    -- and not FORCEd (FORCE would make the SECURITY DEFINER helpers see nothing)
    IF EXISTS (SELECT 1 FROM pg_policy
               WHERE polrelid = to_regclass('public.employees')
                 AND polname <> 'employees_self_read')
       OR EXISTS (SELECT 1 FROM pg_policy
                  WHERE polrelid = to_regclass('public.super_admins')
                    AND polname <> 'super_admins_self_read')
       OR NOT EXISTS (SELECT 1 FROM pg_policy
                      WHERE polrelid = to_regclass('public.employees')
                        AND polname = 'employees_self_read' AND polcmd = 'r'
                        AND polpermissive
                        AND polroles = ARRAY['authenticated'::regrole::oid])
       OR NOT EXISTS (SELECT 1 FROM pg_policy
                      WHERE polrelid = to_regclass('public.super_admins')
                        AND polname = 'super_admins_self_read' AND polcmd = 'r'
                        AND polpermissive
                        AND polroles = ARRAY['authenticated'::regrole::oid]) THEN
        RAISE EXCEPTION '0003 self-check: employees / super_admins policies are not exactly the own-row SELECT policies';
    END IF;
    SELECT string_agg(relname, ', ') INTO v_bad
    FROM pg_class
    WHERE oid IN (to_regclass('public.employees'), to_regclass('public.super_admins'))
      AND (NOT relrowsecurity OR relforcerowsecurity);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: RLS must be enabled and not forced on %', v_bad;
    END IF;

    -- the own-row policies call auth.uid(); policy expressions run with the
    -- caller's rights, so authenticated needs USAGE on schema auth as well
    IF NOT has_schema_privilege('authenticated', 'auth', 'USAGE')
       OR NOT has_function_privilege('authenticated', to_regprocedure('auth.uid()')::oid, 'EXECUTE') THEN
        RAISE EXCEPTION '0003 self-check: authenticated cannot use auth.uid() (needs USAGE on schema auth and EXECUTE)';
    END IF;

    -- RLS helpers kept (header: KEEP)
    IF NOT COALESCE(has_function_privilege('authenticated',
                        to_regprocedure('public.current_user_org_id()')::oid, 'EXECUTE'), true) THEN
        RAISE EXCEPTION '0003 self-check: authenticated lost EXECUTE on current_user_org_id()';
    END IF;
    IF NOT COALESCE(has_function_privilege('authenticated',
                        to_regprocedure('public.is_super_admin()')::oid, 'EXECUTE'), true) THEN
        RAISE EXCEPTION '0003 self-check: authenticated lost EXECUTE on is_super_admin()';
    END IF;

    -- balance views run as invoker
    SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('vault_balances', 'wallet_balances',
                        'installment_balances', 'contract_balances')
      AND NOT ('security_invoker=true' = ANY (COALESCE(c.reloptions, '{}')));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: security_invoker not set on %', v_bad;
    END IF;

    -- plans RLS on
    IF NOT COALESCE((SELECT relrowsecurity FROM pg_class
                     WHERE oid = to_regclass('public.plans')), true) THEN
        RAISE EXCEPTION '0003 self-check: RLS is not enabled on plans';
    END IF;

    -- policy gone
    IF EXISTS (SELECT 1 FROM pg_policy
               WHERE polrelid = to_regclass('public.organizations')
                 AND polname = 'organizations_tenant_update') THEN
        RAISE EXCEPTION '0003 self-check: organizations_tenant_update still exists';
    END IF;

    -- functions: anon executes nothing; authenticated only the two RLS helpers;
    -- service_role everything
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_catalog.pg_proc'::regclass
                        AND d.objid = p.oid AND d.deptype = 'e')
      AND (   has_function_privilege('anon', p.oid, 'EXECUTE')
           OR (has_function_privilege('authenticated', p.oid, 'EXECUTE')
               AND p.oid NOT IN (
                   COALESCE(to_regprocedure('public.current_user_org_id()')::oid, 0),
                   COALESCE(to_regprocedure('public.is_super_admin()')::oid, 0)))
           OR NOT has_function_privilege('service_role', p.oid, 'EXECUTE'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: wrong EXECUTE grants on %', v_bad;
    END IF;

    -- default privileges of postgres: no anon/authenticated grantee left,
    -- and no global PUBLIC EXECUTE on new functions
    SELECT string_agg(d.defaclobjtype::text || '@' || d.defaclnamespace::regnamespace::text, ', ') INTO v_bad
    FROM pg_default_acl d, aclexplode(d.defaclacl) e
    WHERE d.defaclrole = v_postgres
      AND d.defaclnamespace IN (0::oid, 'public'::regnamespace::oid)
      AND e.grantee IN ('anon'::regrole::oid, 'authenticated'::regrole::oid);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: default privileges still grant to anon/authenticated (%)', v_bad;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM aclexplode(COALESCE(
                 (SELECT defaclacl FROM pg_default_acl
                  WHERE defaclrole = v_postgres AND defaclnamespace = 0 AND defaclobjtype = 'f'),
                 acldefault('f', v_postgres))) e
        WHERE e.grantee = 0::oid) THEN
        RAISE EXCEPTION '0003 self-check: new functions would still get PUBLIC EXECUTE';
    END IF;

    -- migration_backup: no access for PUBLIC, anon, authenticated
    IF has_schema_privilege('anon', 'migration_backup', 'USAGE, CREATE')
       OR has_schema_privilege('authenticated', 'migration_backup', 'USAGE, CREATE') THEN
        RAISE EXCEPTION '0003 self-check: anon/authenticated can use schema migration_backup';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c
    WHERE c.relnamespace = 'migration_backup'::regnamespace
      AND (   has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
           OR has_table_privilege('authenticated', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '0003 self-check: anon/authenticated can access migration_backup.%', v_bad;
    END IF;

    RAISE NOTICE '0003: lockdown applied and self-check passed';
END $$;

COMMIT;
