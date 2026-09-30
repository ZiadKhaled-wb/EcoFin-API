-- Migration 0002 — clear the temp-password flag during activation.
--
-- Applied to:
--   * dev — 2026-09-30

CREATE OR REPLACE FUNCTION public.activate_workspace(
    p_license_key text,
    p_owner_auth_id uuid,
    p_username text
)
RETURNS TABLE (tenant_slug text, tenant_name text, org_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_license       saaslicenses%ROWTYPE;
    v_owner_id      uuid;
    v_conflict_id   uuid;
    v_org           organizations%ROWTYPE;
BEGIN
    SELECT * INTO v_license
    FROM saaslicenses
    WHERE license_key = upper(btrim(p_license_key))
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'LICENSE_INVALID' USING ERRCODE = 'P0001';
    END IF;

    IF v_license.is_used THEN
        RAISE EXCEPTION 'LICENSE_USED' USING ERRCODE = 'P0001';
    END IF;

    IF NOT v_license.is_active OR v_license.is_revoked THEN
        RAISE EXCEPTION 'LICENSE_INVALID' USING ERRCODE = 'P0001';
    END IF;

    IF v_license.expires_at IS NOT NULL AND v_license.expires_at <= now() THEN
        RAISE EXCEPTION 'LICENSE_EXPIRED' USING ERRCODE = 'P0001';
    END IF;

    IF v_license.issued_to_org_id IS NULL THEN
        RAISE EXCEPTION 'LICENSE_NOT_PROVISIONED' USING ERRCODE = 'P0001';
    END IF;

    SELECT id INTO v_owner_id
    FROM employees
    WHERE organization_id = v_license.issued_to_org_id
      AND role            = 'OWNER'
      AND auth_id         = p_owner_auth_id
    FOR UPDATE;

    IF v_owner_id IS NULL THEN
        RAISE EXCEPTION 'OWNER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    SELECT id INTO v_conflict_id
    FROM employees
    WHERE organization_id = v_license.issued_to_org_id
      AND username        = btrim(p_username)
      AND id              <> v_owner_id;

    IF v_conflict_id IS NOT NULL THEN
        RAISE EXCEPTION 'USERNAME_TAKEN' USING ERRCODE = 'P0001';
    END IF;

    -- Only change from the previous version: also clear the temp-password flag.
    UPDATE employees
       SET username             = btrim(p_username),
           must_change_password = false
     WHERE id = v_owner_id;

    UPDATE saaslicenses
       SET is_used    = true,
           claimed_at = now()
     WHERE id = v_license.id;

    SELECT * INTO v_org FROM organizations WHERE id = v_license.issued_to_org_id;

    RETURN QUERY SELECT v_org.tenant_slug, v_org.name, v_org.id;
END;
$$;

REVOKE ALL ON FUNCTION public.activate_workspace(text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.activate_workspace(text, uuid, text) TO service_role;