-- =============================================================================
-- F06 · Roles and permissions (task B10). New objects only; the baseline is never edited.
--
--   public.my_permissions()            the caller's effective permission keys (role defaults
--                                      +/- overrides, OWNER = all) and branch scope, for
--                                      GET /api/me/permissions and the API's requirePermission
--   public.set_employee_permission()   add or remove one permission for one employee
--   public.set_employee_branches()     replace one employee's branch list
--
-- Org and employee always come from the session (app.current_org_id(), app.require_permission),
-- never from a parameter. The two setters are settings, not money or stock documents: they have
-- set semantics (calling one twice with the same input leaves the same state), so they take no
-- idempotency key. Each successful call writes exactly one audit row with before/after and the
-- required reason.
-- =============================================================================

-- One row. Same rule as app.has_permission(): OWNER has every key; anyone else has the role
-- default unless an override says otherwise. branch_ids: every branch of the shop for the owner
-- (all_branches = true), else the employee_branches rows.
CREATE FUNCTION public.my_permissions()
RETURNS TABLE (keys text[], branch_ids uuid[], all_branches boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp  uuid := app.current_employee_id();
    v_role public.employee_role;
    v_org  uuid;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    SELECT e.role, e.organization_id INTO v_role, v_org
    FROM public.employees e WHERE e.id = v_emp;

    RETURN QUERY SELECT
        ARRAY(
            SELECT p.key FROM public.permissions p
            WHERE v_role = 'OWNER'
               OR COALESCE(
                    (SELECT o.granted FROM public.employee_permission_overrides o
                     WHERE o.employee_id = v_emp AND o.permission_key = p.key),
                    EXISTS (SELECT 1 FROM public.role_permissions rp
                            WHERE rp.role = v_role AND rp.permission_key = p.key))
            ORDER BY p.key),
        CASE WHEN v_role = 'OWNER'
            THEN ARRAY(SELECT b.id FROM public.branches b
                       WHERE b.organization_id = v_org ORDER BY b.id)
            ELSE ARRAY(SELECT eb.branch_id FROM public.employee_branches eb
                       WHERE eb.employee_id = v_emp ORDER BY eb.branch_id)
        END,
        v_role = 'OWNER';
END;
$$;

-- Shared checks for the two setters: a non-empty reason (<= 500 chars, as in the contract) and
-- a target employee in the caller's shop that isn't the owner and isn't the caller. Locks the
-- target row so concurrent changes to one employee run one after the other. Returns the role.
CREATE FUNCTION app.lock_managed_employee(p_caller uuid, p_employee_id uuid, p_reason text)
RETURNS public.employee_role
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_role public.employee_role;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' OR length(btrim(p_reason)) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason is required (1-500 characters)'
            USING ERRCODE = '22023';
    END IF;
    SELECT e.role INTO v_role
    FROM public.employees e
    WHERE e.id = p_employee_id AND e.organization_id = app.current_org_id()
    FOR UPDATE;
    IF NOT FOUND THEN
        -- Another shop's employee looks exactly like one that doesn't exist.
        RAISE EXCEPTION 'NOT_FOUND: employee' USING ERRCODE = 'P0002';
    END IF;
    IF v_role = 'OWNER' THEN
        RAISE EXCEPTION 'FORBIDDEN: the owner''s access can''t be changed' USING ERRCODE = '42501';
    END IF;
    IF p_employee_id = p_caller THEN
        RAISE EXCEPTION 'FORBIDDEN: you can''t change your own access' USING ERRCODE = '42501';
    END IF;
    RETURN v_role;
END;
$$;
REVOKE ALL ON FUNCTION app.lock_managed_employee(uuid, uuid, text) FROM PUBLIC;

-- Granting a key the role already has by default (or removing one it doesn't) deletes the
-- override instead of storing a redundant row, so overrides only ever hold real differences.
CREATE FUNCTION public.set_employee_permission(
    p_employee_id    uuid,
    p_permission_key text,
    p_granted        boolean,
    p_reason         text)
RETURNS TABLE (employee_id uuid, permission_key text, granted boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp      uuid := app.require_permission('employee.manage');
    v_org      uuid := app.current_org_id();
    v_role     public.employee_role;
    v_default  boolean;
    v_override boolean;
BEGIN
    IF p_granted IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: granted is required' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.key = p_permission_key) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: unknown permission key' USING ERRCODE = '22023';
    END IF;
    v_role := app.lock_managed_employee(v_emp, p_employee_id, p_reason);

    v_default := EXISTS (SELECT 1 FROM public.role_permissions rp
                         WHERE rp.role = v_role AND rp.permission_key = p_permission_key);
    SELECT o.granted INTO v_override
    FROM public.employee_permission_overrides o
    WHERE o.employee_id = p_employee_id AND o.permission_key = p_permission_key
    FOR UPDATE;

    IF p_granted = v_default THEN
        DELETE FROM public.employee_permission_overrides o
        WHERE o.employee_id = p_employee_id AND o.permission_key = p_permission_key;
    ELSE
        INSERT INTO public.employee_permission_overrides
            (organization_id, employee_id, permission_key, granted, created_by)
        VALUES (v_org, p_employee_id, p_permission_key, p_granted, v_emp)
        ON CONFLICT ON CONSTRAINT employee_permission_overrides_pkey
        DO UPDATE SET granted = EXCLUDED.granted, created_by = EXCLUDED.created_by,
                      created_at = now();
    END IF;

    PERFORM app.write_audit(
        'employee.permission_set', 'employee', p_employee_id,
        jsonb_build_object('permission_key', p_permission_key, 'role_default', v_default,
                           'override', v_override,
                           'effective', COALESCE(v_override, v_default)),
        jsonb_build_object('permission_key', p_permission_key, 'role_default', v_default,
                           'override', CASE WHEN p_granted = v_default THEN NULL ELSE p_granted END,
                           'effective', p_granted),
        btrim(p_reason));

    RETURN QUERY SELECT p_employee_id, p_permission_key, p_granted;
END;
$$;

-- Replaces the whole list (set semantics). Every branch must belong to the caller's shop.
-- An empty list is allowed: the employee then works in no branch until one is assigned.
CREATE FUNCTION public.set_employee_branches(
    p_employee_id uuid,
    p_branch_ids  uuid[],
    p_reason      text)
RETURNS TABLE (employee_id uuid, branch_ids uuid[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp    uuid := app.require_permission('employee.manage');
    v_org    uuid := app.current_org_id();
    v_wanted uuid[];
    v_before uuid[];
BEGIN
    IF p_branch_ids IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: branch_ids is required' USING ERRCODE = '22023';
    END IF;
    PERFORM app.lock_managed_employee(v_emp, p_employee_id, p_reason);

    v_wanted := ARRAY(SELECT DISTINCT u FROM unnest(p_branch_ids) AS u WHERE u IS NOT NULL ORDER BY u);
    IF EXISTS (SELECT 1 FROM unnest(v_wanted) AS w(id)
               WHERE NOT EXISTS (SELECT 1 FROM public.branches b
                                 WHERE b.id = w.id AND b.organization_id = v_org)) THEN
        RAISE EXCEPTION 'BRANCH_NOT_IN_ORG' USING ERRCODE = '23503';
    END IF;

    v_before := ARRAY(SELECT eb.branch_id FROM public.employee_branches eb
                      WHERE eb.employee_id = p_employee_id ORDER BY eb.branch_id);

    DELETE FROM public.employee_branches eb
    WHERE eb.employee_id = p_employee_id AND NOT (eb.branch_id = ANY (v_wanted));
    INSERT INTO public.employee_branches (organization_id, employee_id, branch_id, created_by)
    SELECT v_org, p_employee_id, w, v_emp FROM unnest(v_wanted) AS w
    ON CONFLICT ON CONSTRAINT employee_branches_pkey DO NOTHING;

    PERFORM app.write_audit(
        'employee.branches_set', 'employee', p_employee_id,
        jsonb_build_object('branch_ids', to_jsonb(v_before)),
        jsonb_build_object('branch_ids', to_jsonb(v_wanted)),
        btrim(p_reason));

    RETURN QUERY SELECT p_employee_id, v_wanted;
END;
$$;

REVOKE ALL ON FUNCTION public.my_permissions() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_employee_permission(uuid, text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_employee_branches(uuid, uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_permissions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_employee_permission(uuid, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_employee_branches(uuid, uuid[], text) TO authenticated;
