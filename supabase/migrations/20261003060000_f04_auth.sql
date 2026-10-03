-- =============================================================================
-- F04 · Auth and sessions (task B6). New objects only; the baseline is never edited.
--
--   app.require_session_employee()  the caller's employee in the active shop, or a clear error
--   public.my_shops()               the caller's usable shop memberships (login, shop picker)
--   public.auth_record_login()      sets last_login_at and writes audit 'auth.login'
--   public.auth_record_logout()     writes audit 'auth.logout'
--   public.auth_password_changed()  clears must_change_password and writes audit 'auth.password_change'
--
-- Called by the API with the user's JWT (and the `x-org-id` header for the active shop).
-- Org and employee always come from the session (app.current_employee_id()), never from a
-- parameter, and app.write_audit is never given p_organization_id.
--
-- Why not app.require_permission(key): logging in, logging out and changing your own password
-- need no permission key (every employee may do them), and logout must still work when the
-- shop is no longer active. These functions use app.require_session_employee() instead, which
-- resolves the employee the same way (active, not archived, only among the caller's own rows).
-- =============================================================================

-- The caller's employee row in the active shop. Raises a contract error code when there is none:
--   SHOP_NOT_ALLOWED         x-org-id names a shop where the caller has no active employee row
--   SHOP_SELECTION_REQUIRED  no x-org-id and the caller has several active employee rows
--   NOT_AN_EMPLOYEE          no session, or no active employee row at all
CREATE FUNCTION app.require_session_employee()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp   uuid := app.current_employee_id();
    v_count integer;
BEGIN
    IF v_emp IS NOT NULL THEN
        RETURN v_emp;
    END IF;
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF app.requested_org_id() IS NOT NULL THEN
        RAISE EXCEPTION 'SHOP_NOT_ALLOWED' USING ERRCODE = '42501';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.employees e
    WHERE e.auth_user_id = auth.uid() AND e.is_active AND e.archived_at IS NULL;
    IF v_count > 1 THEN
        RAISE EXCEPTION 'SHOP_SELECTION_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
END;
$$;

-- The caller's usable memberships: an active, non-archived employee row in a shop whose status
-- is 'active' and whose subscription has not ended (P05: expired = subscription_end < org_today).
-- Only rows of auth.uid(); no session returns nothing.
CREATE FUNCTION public.my_shops()
RETURNS TABLE (org_id uuid, org_name text, tenant_slug text, role public.employee_role)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT o.id, o.name, o.tenant_slug, e.role
    FROM public.employees e
    JOIN public.organizations o ON o.id = e.organization_id
    WHERE e.auth_user_id = auth.uid()
      AND e.is_active
      AND e.archived_at IS NULL
      AND o.status = 'active'
      AND (o.subscription_end IS NULL OR o.subscription_end >= app.org_today(o.id))
    ORDER BY o.name, o.id
$$;

-- Successful login in the active shop. The API checks the shop before issuing tokens; this
-- re-checks it so the audit row is never written for a shop that can't be used.
CREATE FUNCTION public.auth_record_login()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp    uuid := app.require_session_employee();
    v_org    uuid;
    v_status public.org_status;
    v_end    date;
BEGIN
    SELECT o.id, o.status, o.subscription_end INTO v_org, v_status, v_end
    FROM public.organizations o
    JOIN public.employees e ON e.organization_id = o.id
    WHERE e.id = v_emp;
    IF v_status <> 'active' THEN
        RAISE EXCEPTION 'SHOP_INACTIVE' USING ERRCODE = '42501';
    END IF;
    IF v_end IS NOT NULL AND v_end < app.org_today(v_org) THEN
        RAISE EXCEPTION 'SUBSCRIPTION_EXPIRED' USING ERRCODE = '42501';
    END IF;

    UPDATE public.employees SET last_login_at = now() WHERE id = v_emp;
    PERFORM app.write_audit('auth.login', 'employee', v_emp);
END;
$$;

-- Logout in the active shop. No shop-status check: logging out must always work.
CREATE FUNCTION public.auth_record_logout()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.require_session_employee();
BEGIN
    PERFORM app.write_audit('auth.logout', 'employee', v_emp);
END;
$$;

-- Called by the API right after Supabase Auth accepted the new password. The password belongs to
-- the login, not to one shop, so the flag is cleared on every employee row of the caller.
-- The audit row goes to the active shop.
CREATE FUNCTION public.auth_password_changed()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.require_session_employee();
BEGIN
    UPDATE public.employees
    SET must_change_password = false
    WHERE auth_user_id = auth.uid() AND must_change_password;

    PERFORM app.write_audit('auth.password_change', 'employee', v_emp,
                            p_after => jsonb_build_object('must_change_password', false));
END;
$$;

-- Grants: nothing by default (baseline default privileges); grant exactly what the API calls.
REVOKE ALL ON FUNCTION app.require_session_employee() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.my_shops(), public.auth_record_login(), public.auth_record_logout(),
                       public.auth_password_changed() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_shops(), public.auth_record_login(), public.auth_record_logout(),
                          public.auth_password_changed() TO authenticated;
GRANT EXECUTE ON FUNCTION app.require_session_employee(), public.my_shops(), public.auth_record_login(),
                          public.auth_record_logout(), public.auth_password_changed() TO service_role;
