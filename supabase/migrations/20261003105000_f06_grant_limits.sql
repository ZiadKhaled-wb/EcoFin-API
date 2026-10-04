-- =============================================================================
-- F06 follow-up · limits on who can grant what (user decision, D29 option 3, 4 Oct).
-- Replaces the two setters from 20261003100000_f06_permissions.sql (same signatures and grants;
-- that migration is applied and is never edited). New rules, for callers who are NOT the owner:
--   * employee.manage itself can only be granted or removed by the owner
--   * a permission can only be granted or removed by someone who holds it
--   * a branch can only be added to or removed from an employee's list by someone who works in it
--     (branches left unchanged in the list are fine)
-- The owner can still change everything except the owner's own access. Refusals are
-- FORBIDDEN (403) and write no audit row.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.set_employee_permission(
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

    -- D29 option 3: a non-owner can't hand out (or take away) more than they hold.
    IF app.current_role() <> 'OWNER' THEN
        IF p_permission_key = 'employee.manage' THEN
            RAISE EXCEPTION 'FORBIDDEN: only the owner can grant or remove employee.manage'
                USING ERRCODE = '42501';
        END IF;
        IF NOT app.has_permission(p_permission_key) THEN
            RAISE EXCEPTION 'FORBIDDEN: you can only grant or remove a permission you hold'
                USING ERRCODE = '42501';
        END IF;
    END IF;

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

CREATE OR REPLACE FUNCTION public.set_employee_branches(
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

    -- D29 option 3: a non-owner can only add or remove branches they work in themselves.
    IF app.current_role() <> 'OWNER' AND EXISTS (
        SELECT 1
        FROM ((SELECT unnest(v_wanted) EXCEPT SELECT unnest(v_before))       -- added
              UNION
              (SELECT unnest(v_before) EXCEPT SELECT unnest(v_wanted))) AS changed(id)  -- removed
        WHERE NOT app.has_branch_access(changed.id)) THEN
        RAISE EXCEPTION 'FORBIDDEN: you can only add or remove branches you work in'
            USING ERRCODE = '42501';
    END IF;

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
