-- =============================================================================
-- Migration 0004 — Drop the 0003 rollback snapshot (schema migration_backup)
-- =============================================================================
--
-- Purpose: remove the pre-lockdown snapshot that 0003 keeps for its rollback,
--          so no copy of the old (open) grants stays in the database.
--
-- Date: 2026-10-02
--
-- Applied to:
--
-- Apply ONLY after 0003 has been applied AND 0003_db_lockdown.verify.sql has
-- passed on EVERY database (dev, staging, prod). After this file runs,
-- 0003_db_lockdown.rollback.sql can no longer restore anything.
--
-- Idempotent. Safe to re-run. Refuses to run where 0003 is not in place.
-- Drops the schema with RESTRICT: if anything other than the 0003 snapshot
-- was put in migration_backup, it stops instead of deleting it.
-- =============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regnamespace('migration_backup') IS NULL THEN
        RAISE NOTICE '0004: schema migration_backup not found; nothing to drop';
        RETURN;
    END IF;

    -- 0003 must be in place: its policy changes are the easiest markers.
    IF EXISTS (SELECT 1 FROM pg_policy
               WHERE polrelid = to_regclass('public.organizations')
                 AND polname = 'organizations_tenant_update')
       OR NOT EXISTS (SELECT 1 FROM pg_policy
                      WHERE polrelid = to_regclass('public.employees')
                        AND polname = 'employees_self_read')
    THEN
        RAISE EXCEPTION '0004: 0003_db_lockdown is not applied on this database; apply and verify it first';
    END IF;
END $$;

DROP TABLE IF EXISTS migration_backup.m0003_pre_lockdown;
DROP SCHEMA IF EXISTS migration_backup RESTRICT;

COMMIT;
