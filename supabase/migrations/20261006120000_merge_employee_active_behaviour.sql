-- Combine EC-143's returned activation state and audit action with O02's locking,
-- token revocation, subscription limits, optional reactivation reason and no-op handling.
CREATE OR REPLACE FUNCTION public.set_employee_active(
    p_employee_id uuid, p_active boolean, p_reason text)
RETURNS TABLE (employee_id uuid, is_active boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_emp uuid := app.require_permission('employee.manage');
    e public.employees%ROWTYPE;
BEGIN
    IF p_active IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: active is required' USING ERRCODE = '22023';
    END IF;
    BEGIN
        e := app.lock_staff(p_employee_id, true);
    EXCEPTION
        WHEN SQLSTATE 'P0001' THEN
            IF SQLERRM = 'EMPLOYEE_NOT_FOUND' THEN
                RAISE EXCEPTION 'NOT_FOUND: employee' USING ERRCODE = 'P0001';
            END IF;
            RAISE;
        WHEN SQLSTATE '42501' THEN
            IF SQLERRM = 'TARGET_NOT_ALLOWED' THEN
                RAISE EXCEPTION 'FORBIDDEN: owner or self target' USING ERRCODE = '42501';
            END IF;
            RAISE;
    END;
    IF e.is_active = p_active THEN
        RETURN QUERY SELECT e.id, e.is_active;
        RETURN;
    END IF;
    IF NOT p_active AND NULLIF(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason is required' USING ERRCODE = '22023';
    END IF;
    UPDATE public.employees SET is_active = p_active, updated_by = v_emp WHERE id = e.id;
    IF NOT p_active THEN
        UPDATE public.invites i SET revoked_at = now()
        WHERE i.employee_id = e.id AND i.accepted_at IS NULL AND i.revoked_at IS NULL;
        UPDATE public.password_resets r SET revoked_at = now()
        WHERE r.employee_id = e.id AND r.used_at IS NULL AND r.revoked_at IS NULL;
    END IF;
    PERFORM app.write_audit('employee.active_set', 'employee', e.id,
        p_before => jsonb_build_object('is_active', e.is_active),
        p_after => jsonb_build_object('is_active', p_active),
        p_reason => btrim(p_reason), p_severity => 'warning');
    RETURN QUERY SELECT e.id, p_active;
END;
$$;
REVOKE ALL ON FUNCTION public.set_employee_active(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_employee_active(uuid, boolean, text) TO authenticated;
