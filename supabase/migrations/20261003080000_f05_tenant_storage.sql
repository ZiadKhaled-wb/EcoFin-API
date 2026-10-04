-- =============================================================================
-- F05 · Tenant isolation (task B8). New objects only; the baseline is never edited.
--
--   public.session_context()   the caller's employee, shop and status in ONE round trip, for the
--                              API's per-request context and status gate (loadRequestContext)
--   storage.objects policy     `authenticated` may only SELECT objects of bucket tenant-files
--                              whose first folder is its own shop id; no writes (F14 uploads go
--                              through the API with the service role)
--
-- Org and employee come from the session (auth.uid() + x-org-id), never from a parameter.
-- =============================================================================

-- Returns exactly one row. `refusal` is NULL when the request may go on; otherwise it is the
-- contract error code the API answers with (no exception, so the API keeps one code path):
--   NOT_AN_EMPLOYEE          no session, or the login has no employee row at all
--   SHOP_NOT_ALLOWED         x-org-id names a shop where the login has no employee row
--   SHOP_SELECTION_REQUIRED  no x-org-id and the login has several active employee rows
--   ACCOUNT_DISABLED         the employee row is inactive or archived
--   SHOP_INACTIVE            organizations.status is not 'active'
--   SUBSCRIPTION_EXPIRED     subscription_end is before today in the shop's timezone (P05)
-- The employee is chosen exactly like app.current_employee_id(), so a context that passes has
-- the same organization_id that RLS (app.current_org_id()) scopes every query to.
-- must_change_password is returned, not refused: the API decides per route (me, change-password
-- and logout stay allowed).
CREATE FUNCTION public.session_context()
RETURNS TABLE (
    employee_id          uuid,
    organization_id      uuid,
    role                 public.employee_role,
    default_branch_id    uuid,
    branch_ids           uuid[],
    must_change_password boolean,
    refusal              text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_uid    uuid := auth.uid();
    v_org    uuid := app.requested_org_id();
    v_emp    public.employees%ROWTYPE;
    v_active integer;
    v_status public.org_status;
    v_end    date;
BEGIN
    IF v_uid IS NULL THEN
        RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::public.employee_role, NULL::uuid,
                            NULL::uuid[], NULL::boolean, 'NOT_AN_EMPLOYEE'::text;
        RETURN;
    END IF;

    IF v_org IS NOT NULL THEN
        SELECT * INTO v_emp FROM public.employees e
        WHERE e.auth_user_id = v_uid AND e.organization_id = v_org;
        IF NOT FOUND THEN
            RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::public.employee_role, NULL::uuid,
                                NULL::uuid[], NULL::boolean, 'SHOP_NOT_ALLOWED'::text;
            RETURN;
        END IF;
    ELSE
        SELECT count(*) INTO v_active FROM public.employees e
        WHERE e.auth_user_id = v_uid AND e.is_active AND e.archived_at IS NULL;
        IF v_active > 1 THEN
            RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::public.employee_role, NULL::uuid,
                                NULL::uuid[], NULL::boolean, 'SHOP_SELECTION_REQUIRED'::text;
            RETURN;
        END IF;
        -- The single active row; with none, any (disabled) row so the refusal says why.
        SELECT * INTO v_emp FROM public.employees e
        WHERE e.auth_user_id = v_uid
        ORDER BY (e.is_active AND e.archived_at IS NULL) DESC, e.created_at, e.id
        LIMIT 1;
        IF NOT FOUND THEN
            RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::public.employee_role, NULL::uuid,
                                NULL::uuid[], NULL::boolean, 'NOT_AN_EMPLOYEE'::text;
            RETURN;
        END IF;
    END IF;

    SELECT o.status, o.subscription_end INTO v_status, v_end
    FROM public.organizations o WHERE o.id = v_emp.organization_id;

    RETURN QUERY
    SELECT v_emp.id, v_emp.organization_id, v_emp.role, v_emp.default_branch_id,
           COALESCE((SELECT array_agg(eb.branch_id ORDER BY eb.branch_id)
                     FROM public.employee_branches eb WHERE eb.employee_id = v_emp.id),
                    ARRAY[]::uuid[]),
           v_emp.must_change_password,
           CASE
               WHEN NOT v_emp.is_active OR v_emp.archived_at IS NOT NULL THEN 'ACCOUNT_DISABLED'
               WHEN v_status IS DISTINCT FROM 'active' THEN 'SHOP_INACTIVE'
               WHEN v_end IS NOT NULL AND v_end < app.org_today(v_emp.organization_id)
                   THEN 'SUBSCRIPTION_EXPIRED'
           END;
END;
$$;

REVOKE ALL ON FUNCTION public.session_context() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.session_context() TO authenticated;

-- Storage: read-only access to the caller's own shop folder in tenant-files. No INSERT, UPDATE
-- or DELETE policy for authenticated, so only the service role (the API) writes there.
-- Guarded like the baseline bucket: plain Postgres has no storage schema.
DO $$
BEGIN
    IF to_regclass('storage.objects') IS NOT NULL THEN
        CREATE POLICY tenant_files_read_own_org ON storage.objects
            FOR SELECT TO authenticated
            USING (bucket_id = 'tenant-files'
                   AND app.current_org_id() IS NOT NULL
                   AND (storage.foldername(name))[1] = app.current_org_id()::text);
    END IF;
END $$;
