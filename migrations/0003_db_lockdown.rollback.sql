-- =============================================================================
-- Rollback 0003 — restore the grants and policies from before 0003_db_lockdown
-- =============================================================================
--
-- Purpose: undo 0003 exactly, using the snapshot 0003 took on its first run
--          (migration_backup.m0003_pre_lockdown). Restores:
--            * table / view / sequence / column grants for anon, authenticated
--            * EXECUTE grants for PUBLIC, anon, authenticated, service_role
--            * default privileges of role postgres (global + IN SCHEMA public)
--              for PUBLIC, anon, authenticated
--            * security_invoker on the four balance views
--            * RLS flag on plans
--            * policy organizations_tenant_update
--          Then compares every restored item with the snapshot and aborts if
--          anything differs. On success it drops the snapshot.
--
-- WARNING: this re-opens the Critical findings in REPO_AUDIT.md §4.2/§4.3.
--          Use it only to recover from a broken API after applying 0003.
--
-- Date: 2026-10-02
--
-- Applied to:
--
-- Run as postgres, in one transaction. Safe to re-run: a second run finds no
-- snapshot and the pre-0003 state, and does nothing. If the lockdown is in
-- place but the snapshot is missing, it stops with an error instead of
-- guessing.
--
-- Scope: every object in the snapshot gets its anon / authenticated (and, for
-- functions, PUBLIC / service_role) grants reset to the snapshot, so a grant
-- a LATER migration (0004+) made on one of those objects is undone too.
-- Re-check later migrations' grants after running this. Objects created
-- after 0003's first run are not in the snapshot and are left untouched.
--
-- "Exact" means the same grantee / privilege / grant-option set as the
-- snapshot for every role 0003 touched. Two catalog-level differences can
-- remain, with no effect on access: the grantor is recorded as the role
-- running this script, and a function whose ACL was NULL (built-in default)
-- comes back with the same privileges written out explicitly.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    v_old_path     text := current_setting('search_path');
    v_anon         oid  := 'anon'::regrole;
    v_auth         oid  := 'authenticated'::regrole;
    v_service      oid  := 'service_role'::regrole;
    v_postgres     oid  := 'postgres'::regrole;
    v_rel_grantees oid[];
    v_fn_grantees  oid[];
    v_def_grantees oid[];
    r              record;
    g              record;
    v_kind         text;
    v_in           text;
    v_on           text;
    v_val          text;
    v_bad          text;
    v_pol          jsonb;
BEGIN
    v_rel_grantees := ARRAY[v_anon, v_auth];
    v_fn_grantees  := ARRAY[0::oid, v_anon, v_auth, v_service];
    v_def_grantees := ARRAY[0::oid, v_anon, v_auth];

    -- -------------------------------------------------------------------------
    -- No snapshot: either 0003 was never applied, or this already ran.
    -- -------------------------------------------------------------------------
    IF to_regclass('migration_backup.m0003_pre_lockdown') IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM pg_policy
                       WHERE polrelid = to_regclass('public.organizations')
                         AND polname = 'organizations_tenant_update')
           AND NOT COALESCE(has_table_privilege('anon', to_regclass('public.vault_balances'), 'SELECT'), true)
        THEN
            RAISE EXCEPTION 'rollback 0003: the lockdown is in place but the snapshot migration_backup.m0003_pre_lockdown is missing. Cannot restore exactly; restore from migrations/0001__role_grants.sql and the policy in docs/db/initialization-v2.1.sql section 21 by hand.';
        END IF;
        RAISE NOTICE 'rollback 0003: no snapshot and no lockdown found; nothing to do';
        RETURN;
    END IF;

    -- Snapshot names are schema-qualified; keep deparsing consistent with it.
    PERFORM set_config('search_path', 'pg_catalog', true);

    -- -------------------------------------------------------------------------
    -- 1. Relations: anon + authenticated grants
    -- -------------------------------------------------------------------------
    FOR r IN SELECT * FROM migration_backup.m0003_pre_lockdown
             WHERE kind = 'relation' ORDER BY object_identity
    LOOP
        IF to_regclass(r.object_identity) IS NULL THEN
            RAISE NOTICE 'rollback 0003: % no longer exists, skipped', r.object_identity;
            CONTINUE;
        END IF;
        v_kind := CASE WHEN r.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END;

        EXECUTE format('REVOKE ALL ON %s %s FROM anon, authenticated', v_kind, r.object_identity);

        FOR g IN
            SELECT e.grantee, e.is_grantable,
                   string_agg(e.privilege_type, ', ' ORDER BY e.privilege_type) AS privs
            FROM aclexplode(r.acl) e
            WHERE e.grantee = ANY (v_rel_grantees)
            GROUP BY e.grantee, e.is_grantable
        LOOP
            EXECUTE format('GRANT %s ON %s %s TO %I%s',
                           g.privs, v_kind, r.object_identity, pg_get_userbyid(g.grantee),
                           CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 2. Column-level grants (the table-level REVOKE in 0003 removed them)
    -- -------------------------------------------------------------------------
    FOR r IN SELECT * FROM migration_backup.m0003_pre_lockdown
             WHERE kind = 'column' ORDER BY object_identity
    LOOP
        IF to_regclass(r.detail->>'table') IS NULL THEN
            CONTINUE;
        END IF;
        FOR g IN
            SELECT e.grantee, e.is_grantable,
                   string_agg(e.privilege_type, ', ' ORDER BY e.privilege_type) AS privs
            FROM aclexplode(r.acl) e
            WHERE e.grantee = ANY (v_rel_grantees)
            GROUP BY e.grantee, e.is_grantable
        LOOP
            EXECUTE format('GRANT %s (%I) ON TABLE %s TO %I%s',
                           g.privs, r.detail->>'column', r.detail->>'table',
                           pg_get_userbyid(g.grantee),
                           CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 3. Functions: PUBLIC, anon, authenticated, service_role
    -- -------------------------------------------------------------------------
    FOR r IN SELECT * FROM migration_backup.m0003_pre_lockdown
             WHERE kind = 'function' ORDER BY object_identity
    LOOP
        IF to_regprocedure(r.object_identity) IS NULL THEN
            RAISE NOTICE 'rollback 0003: % no longer exists, skipped', r.object_identity;
            CONTINUE;
        END IF;

        EXECUTE format('REVOKE ALL ON ROUTINE %s FROM PUBLIC, anon, authenticated, service_role',
                       r.object_identity);

        FOR g IN
            SELECT e.grantee, bool_or(e.is_grantable) AS is_grantable
            FROM aclexplode(r.acl) e
            WHERE e.grantee = ANY (v_fn_grantees)
              AND e.privilege_type = 'EXECUTE'
            GROUP BY e.grantee
        LOOP
            EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO %s%s',
                           r.object_identity,
                           CASE WHEN g.grantee = 0 THEN 'PUBLIC'
                                ELSE quote_ident(pg_get_userbyid(g.grantee)) END,
                           CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 4. Default privileges of role postgres
    -- -------------------------------------------------------------------------
    FOR r IN SELECT * FROM migration_backup.m0003_pre_lockdown
             WHERE kind = 'default_acl' ORDER BY object_identity
    LOOP
        v_in := CASE WHEN r.detail->>'scope' = 'public' THEN ' IN SCHEMA public' ELSE '' END;
        v_on := CASE r.detail->>'objtype' WHEN 'r' THEN 'TABLES'
                                         WHEN 'S' THEN 'SEQUENCES'
                                         ELSE 'FUNCTIONS' END;

        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres%s REVOKE ALL ON %s FROM PUBLIC, anon, authenticated',
                       v_in, v_on);

        FOR g IN
            SELECT e.grantee, e.is_grantable,
                   string_agg(e.privilege_type, ', ' ORDER BY e.privilege_type) AS privs
            FROM aclexplode(r.acl) e
            WHERE e.grantee = ANY (v_def_grantees)
            GROUP BY e.grantee, e.is_grantable
        LOOP
            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres%s GRANT %s ON %s TO %s%s',
                           v_in, g.privs, v_on,
                           CASE WHEN g.grantee = 0 THEN 'PUBLIC'
                                ELSE quote_ident(pg_get_userbyid(g.grantee)) END,
                           CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 5. security_invoker on the balance views
    -- -------------------------------------------------------------------------
    FOR r IN SELECT * FROM migration_backup.m0003_pre_lockdown
             WHERE kind = 'relation'
               AND object_identity IN ('public.vault_balances', 'public.wallet_balances',
                                       'public.installment_balances', 'public.contract_balances')
    LOOP
        IF to_regclass(r.object_identity) IS NULL THEN
            CONTINUE;
        END IF;
        SELECT substring(o FROM '^security_invoker=(.*)$') INTO v_val
        FROM jsonb_array_elements_text(r.detail->'reloptions') AS o
        WHERE o LIKE 'security_invoker=%';

        IF v_val IS NULL THEN
            EXECUTE format('ALTER VIEW %s RESET (security_invoker)', r.object_identity);
        ELSE
            EXECUTE format('ALTER VIEW %s SET (security_invoker = %L)', r.object_identity, v_val);
        END IF;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- 6. RLS on plans (0003 only ever enabled it)
    -- -------------------------------------------------------------------------
    IF to_regclass('public.plans') IS NOT NULL
       AND (SELECT (detail->>'relrowsecurity')::boolean
            FROM migration_backup.m0003_pre_lockdown
            WHERE kind = 'relation' AND object_identity = 'public.plans') IS FALSE
    THEN
        ALTER TABLE public.plans DISABLE ROW LEVEL SECURITY;
    END IF;

    -- -------------------------------------------------------------------------
    -- 7. Policy organizations_tenant_update
    -- -------------------------------------------------------------------------
    SELECT detail INTO v_pol
    FROM migration_backup.m0003_pre_lockdown
    WHERE kind = 'policy' AND object_identity = 'public.organizations.organizations_tenant_update';

    IF v_pol IS NOT NULL
       AND to_regclass(v_pol->>'table') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_policy
                       WHERE polrelid = to_regclass(v_pol->>'table')
                         AND polname = v_pol->>'name')
    THEN
        EXECUTE format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s',
            v_pol->>'name',
            v_pol->>'table',
            CASE WHEN (v_pol->>'permissive')::boolean THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
            v_pol->>'cmd',
            (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_pol->'roles') AS x),
            CASE WHEN v_pol->>'using' IS NOT NULL
                 THEN ' USING (' || (v_pol->>'using') || ')' ELSE '' END,
            CASE WHEN v_pol->>'with_check' IS NOT NULL
                 THEN ' WITH CHECK (' || (v_pol->>'with_check') || ')' ELSE '' END);
    END IF;

    -- -------------------------------------------------------------------------
    -- 8. Self-check: everything matches the snapshot
    -- -------------------------------------------------------------------------
    -- Relations
    SELECT string_agg(s.object_identity, ', ') INTO v_bad
    FROM migration_backup.m0003_pre_lockdown s
    JOIN pg_class c ON c.oid = to_regclass(s.object_identity)
    WHERE s.kind = 'relation'
      AND (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(s.acl) e WHERE e.grantee = ANY (v_rel_grantees)) q)
          IS DISTINCT FROM
          (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(c.relacl) e WHERE e.grantee = ANY (v_rel_grantees)) q);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'rollback 0003 self-check: grants differ from snapshot on %', v_bad;
    END IF;

    -- Columns
    SELECT string_agg(s.object_identity, ', ') INTO v_bad
    FROM migration_backup.m0003_pre_lockdown s
    JOIN pg_attribute a ON a.attrelid = to_regclass(s.detail->>'table')
                       AND a.attname = s.detail->>'column'
    WHERE s.kind = 'column'
      AND (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(s.acl) e WHERE e.grantee = ANY (v_rel_grantees)) q)
          IS DISTINCT FROM
          (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(a.attacl) e WHERE e.grantee = ANY (v_rel_grantees)) q);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'rollback 0003 self-check: column grants differ from snapshot on %', v_bad;
    END IF;

    -- Functions
    SELECT string_agg(s.object_identity, ', ') INTO v_bad
    FROM migration_backup.m0003_pre_lockdown s
    JOIN pg_proc p ON p.oid = to_regprocedure(s.object_identity)
    WHERE s.kind = 'function'
      AND (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(s.acl) e WHERE e.grantee = ANY (v_fn_grantees)) q)
          IS DISTINCT FROM
          (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) e
              WHERE e.grantee = ANY (v_fn_grantees)) q);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'rollback 0003 self-check: EXECUTE grants differ from snapshot on %', v_bad;
    END IF;

    -- Default privileges
    SELECT string_agg(s.object_identity, ', ') INTO v_bad
    FROM migration_backup.m0003_pre_lockdown s
    LEFT JOIN pg_default_acl d
           ON d.defaclrole = v_postgres
          AND d.defaclobjtype = (s.detail->>'objtype')::"char"
          AND d.defaclnamespace = CASE WHEN s.detail->>'scope' = 'global' THEN 0::oid
                                       ELSE 'public'::regnamespace::oid END
    WHERE s.kind = 'default_acl'
      AND (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(s.acl) e WHERE e.grantee = ANY (v_def_grantees)) q)
          IS DISTINCT FROM
          (SELECT array_agg(x ORDER BY x) FROM (
              SELECT format('%s:%s:%s', e.grantee, e.privilege_type, e.is_grantable) AS x
              FROM aclexplode(COALESCE(
                       d.defaclacl,
                       CASE WHEN s.detail->>'scope' = 'global'
                            THEN acldefault(CASE s.detail->>'objtype' WHEN 'S' THEN 's'
                                                                      ELSE s.detail->>'objtype' END::"char",
                                            v_postgres) END)) e
              WHERE e.grantee = ANY (v_def_grantees)) q);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'rollback 0003 self-check: default privileges differ from snapshot on %', v_bad;
    END IF;

    -- View options, plans RLS
    SELECT string_agg(s.object_identity, ', ') INTO v_bad
    FROM migration_backup.m0003_pre_lockdown s
    JOIN pg_class c ON c.oid = to_regclass(s.object_identity)
    WHERE s.kind = 'relation'
      AND (   (s.object_identity IN ('public.vault_balances', 'public.wallet_balances',
                                     'public.installment_balances', 'public.contract_balances')
               AND COALESCE(to_jsonb(c.reloptions), '[]'::jsonb) <> s.detail->'reloptions')
           OR (s.object_identity = 'public.plans'
               AND c.relrowsecurity <> (s.detail->>'relrowsecurity')::boolean));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'rollback 0003 self-check: view options / RLS flag differ from snapshot on %', v_bad;
    END IF;

    -- Policy
    IF v_pol IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pg_policy pol
        WHERE pol.polrelid = to_regclass(v_pol->>'table')
          AND pol.polname = v_pol->>'name'
          AND pol.polpermissive = (v_pol->>'permissive')::boolean
          AND pg_get_expr(pol.polqual, pol.polrelid) IS NOT DISTINCT FROM v_pol->>'using'
          AND pg_get_expr(pol.polwithcheck, pol.polrelid) IS NOT DISTINCT FROM v_pol->>'with_check')
    THEN
        RAISE EXCEPTION 'rollback 0003 self-check: policy % was not restored as it was', v_pol->>'name';
    END IF;

    PERFORM set_config('search_path', v_old_path, true);
    RAISE NOTICE 'rollback 0003: pre-lockdown state restored and matches the snapshot';
END $$;

-- Drop the snapshot (and the backup schema if nothing else lives there).
DROP TABLE IF EXISTS migration_backup.m0003_pre_lockdown;

DO $$
BEGIN
    IF to_regnamespace('migration_backup') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_class
                       WHERE relnamespace = to_regnamespace('migration_backup'))
       AND NOT EXISTS (SELECT 1 FROM pg_proc
                       WHERE pronamespace = to_regnamespace('migration_backup'))
    THEN
        DROP SCHEMA migration_backup;
    END IF;
END $$;

COMMIT;
