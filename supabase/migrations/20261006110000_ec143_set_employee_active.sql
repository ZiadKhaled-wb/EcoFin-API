-- EC-143: an owner (or anyone with employee.manage) deactivates or reactivates an employee.
-- Migration 20261006110000_ec143_set_employee_active.sql.
--   public.set_employee_active()   sets employees.is_active and writes one audit row
-- A deactivated employee is refused on their very next request (F05 session_context() re-reads
-- the employee each time: 403 ACCOUNT_DISABLED, even with a live token). Nothing is deleted.
-- Same rules as the F06 setters, through app.lock_managed_employee: a reason is required, another
-- shop's employee reads as NOT_FOUND, and neither the owner nor the caller themself can be changed.

CREATE FUNCTION public.set_employee_active(
    p_employee_id uuid,
    p_active      boolean,
    p_reason      text)
RETURNS TABLE (employee_id uuid, is_active boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp    uuid := app.require_permission('employee.manage');
    v_before boolean;
BEGIN
    IF p_active IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: active is required' USING ERRCODE = '22023';
    END IF;
    PERFORM app.lock_managed_employee(v_emp, p_employee_id, p_reason);

    SELECT e.is_active INTO v_before FROM public.employees e WHERE e.id = p_employee_id;
    UPDATE public.employees e SET is_active = p_active WHERE e.id = p_employee_id;

    PERFORM app.write_audit(
        'employee.active_set', 'employee', p_employee_id,
        jsonb_build_object('is_active', v_before),
        jsonb_build_object('is_active', p_active),
        btrim(p_reason));

    RETURN QUERY SELECT p_employee_id, p_active;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_employee_active(uuid, boolean, text) TO authenticated;
