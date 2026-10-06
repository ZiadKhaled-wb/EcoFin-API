-- P05: date-based read-only subscriptions, serialized limits and platform billing.
ALTER TABLE public.subscription_payments ADD COLUMN idempotency_key uuid;
CREATE UNIQUE INDEX subscription_payments_idempotency_key ON public.subscription_payments(organization_id,idempotency_key);

CREATE FUNCTION app.org_is_expired(p_org uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT COALESCE((SELECT subscription_end IS NOT NULL AND app.org_today(id)>subscription_end FROM public.organizations WHERE id=p_org),false)
$$;
CREATE FUNCTION app.plan_usage(p_org uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object(
 'branches',jsonb_build_object('used',(SELECT count(*) FROM public.branches WHERE organization_id=p_org AND is_active AND archived_at IS NULL),'limit',p.max_branches),
 'users',jsonb_build_object('used',(SELECT count(*) FROM public.employees WHERE organization_id=p_org AND is_active AND archived_at IS NULL),'limit',p.max_users),
 'devices',jsonb_build_object('used',(SELECT count(*) FROM public.devices WHERE organization_id=p_org AND is_active AND archived_at IS NULL),'limit',p.max_devices),
 'modules',p.modules)
 FROM public.organizations o JOIN public.plans p ON p.key=o.plan_key WHERE o.id=p_org
$$;
CREATE FUNCTION app.org_has_module(p_org uuid,p_module text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT COALESCE((SELECT p_module=ANY(p.modules) FROM public.organizations o JOIN public.plans p ON p.key=o.plan_key WHERE o.id=p_org),false)
$$;
CREATE FUNCTION app.require_module(p_module text) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF app.current_org_id() IS NULL THEN RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE='42501'; END IF;
 IF NOT app.org_has_module(app.current_org_id(),p_module) THEN RAISE EXCEPTION 'MODULE_NOT_IN_PLAN: %',p_module USING ERRCODE='42501'; END IF;
END $$;
REVOKE ALL ON FUNCTION app.org_is_expired(uuid),app.plan_usage(uuid),app.org_has_module(uuid,text),app.require_module(text) FROM PUBLIC,anon,authenticated;

-- Only the public wrapper is exposed to PostgREST; private app helpers retain no grants.
CREATE FUNCTION public.require_module(p_module text) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN PERFORM app.require_session_employee(); PERFORM app.require_module(p_module); END $$;
REVOKE ALL ON FUNCTION public.require_module(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.require_module(text) TO authenticated;

CREATE OR REPLACE FUNCTION app.require_permission(p_key text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp    uuid := app.current_employee_id();
    v_status public.org_status;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    SELECT o.status INTO v_status
    FROM public.organizations o JOIN public.employees e ON e.organization_id = o.id
    WHERE e.id = v_emp;
    IF v_status <> 'active' THEN
        RAISE EXCEPTION 'ORG_NOT_ACTIVE: %', v_status USING ERRCODE = '42501';
    END IF;
    IF app.org_is_expired(app.current_org_id()) AND p_key <> ALL (ARRAY['export.data']) THEN
        RAISE EXCEPTION 'SUBSCRIPTION_EXPIRED' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.key = p_key) THEN
        RAISE EXCEPTION 'UNKNOWN_PERMISSION: %', p_key USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission(p_key) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: %', p_key USING ERRCODE = '42501';
    END IF;
    RETURN v_emp;
END;
$$;

CREATE FUNCTION app.enforce_plan_limit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_plan public.plans%ROWTYPE; v_limit integer; v_used bigint; v_resource text;
BEGIN
 IF NOT NEW.is_active OR NEW.archived_at IS NOT NULL THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' THEN IF OLD.is_active AND OLD.archived_at IS NULL THEN RETURN NEW; END IF; END IF;
 PERFORM 1 FROM public.organizations WHERE id=NEW.organization_id FOR UPDATE;
 SELECT p.* INTO v_plan FROM public.plans p JOIN public.organizations o ON o.plan_key=p.key WHERE o.id=NEW.organization_id;
 CASE TG_TABLE_NAME
 WHEN 'branches' THEN v_limit:=v_plan.max_branches; v_resource:='branches'; SELECT count(*) INTO v_used FROM public.branches WHERE organization_id=NEW.organization_id AND is_active AND archived_at IS NULL;
 WHEN 'employees' THEN v_limit:=v_plan.max_users; v_resource:='users'; SELECT count(*) INTO v_used FROM public.employees WHERE organization_id=NEW.organization_id AND is_active AND archived_at IS NULL;
 WHEN 'devices' THEN v_limit:=v_plan.max_devices; v_resource:='devices'; SELECT count(*) INTO v_used FROM public.devices WHERE organization_id=NEW.organization_id AND is_active AND archived_at IS NULL;
 END CASE;
 IF v_limit IS NOT NULL AND v_used>=v_limit THEN RAISE EXCEPTION 'PLAN_LIMIT_REACHED' USING ERRCODE='P0001',DETAIL=jsonb_build_object('resource',v_resource,'limit',v_limit,'used',v_used)::text; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION app.enforce_plan_limit() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER branches_plan_limit BEFORE INSERT OR UPDATE OF is_active,archived_at ON public.branches FOR EACH ROW EXECUTE FUNCTION app.enforce_plan_limit();
CREATE TRIGGER employees_plan_limit BEFORE INSERT OR UPDATE OF is_active,archived_at ON public.employees FOR EACH ROW EXECUTE FUNCTION app.enforce_plan_limit();
CREATE TRIGGER devices_plan_limit BEFORE INSERT OR UPDATE OF is_active,archived_at ON public.devices FOR EACH ROW EXECUTE FUNCTION app.enforce_plan_limit();

CREATE FUNCTION app.subscription_snapshot(p_org uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('plan_key',p.key,'plan_name',p.name,'plan',jsonb_build_object('key',p.key,'name',p.name,'max_branches',p.max_branches,'max_users',p.max_users,'max_devices',p.max_devices,'modules',p.modules),
 'subscription_start',o.subscription_start,'subscription_end',o.subscription_end,'days_left',o.subscription_end-app.org_today(o.id),
 'state',CASE WHEN o.subscription_end IS NULL THEN 'no_end' WHEN app.org_is_expired(o.id) THEN 'expired' WHEN o.subscription_end-app.org_today(o.id)<=14 THEN 'expiring' ELSE 'active' END,
 'read_only',app.org_is_expired(o.id),'usage',app.plan_usage(o.id),'modules',p.modules)
 FROM public.organizations o JOIN public.plans p ON p.key=o.plan_key WHERE o.id=p_org
$$;
REVOKE ALL ON FUNCTION app.subscription_snapshot(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.admin_change_plan(p_organization_id uuid,p_plan_key text,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org public.organizations%ROWTYPE; v_plan public.plans%ROWTYPE; v_usage jsonb; v_exceeded jsonb;
BEGIN
 IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE='42501'; END IF;
 IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='P0001'; END IF;
 SELECT * INTO v_org FROM public.organizations WHERE id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 SELECT * INTO v_plan FROM public.plans WHERE key=p_plan_key AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'PLAN_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 v_usage:=app.plan_usage(p_organization_id);
 SELECT COALESCE(jsonb_agg(jsonb_build_object('resource',r,'limit',l,'used',(v_usage#>>ARRAY[r,'used'])::bigint)),'[]'::jsonb) INTO v_exceeded
 FROM (VALUES('branches',v_plan.max_branches),('users',v_plan.max_users),('devices',v_plan.max_devices)) x(r,l)
 WHERE l IS NOT NULL AND (v_usage#>>ARRAY[r,'used'])::bigint>l;
 IF jsonb_array_length(v_exceeded)>0 THEN RAISE EXCEPTION 'PLAN_DOWNGRADE_BLOCKED' USING ERRCODE='P0001',DETAIL=v_exceeded::text; END IF;
 UPDATE public.organizations SET plan_key=p_plan_key WHERE id=p_organization_id;
 PERFORM set_config('app.org_id',p_organization_id::text,true);
 PERFORM app.write_audit('subscription.plan_changed','organization',p_organization_id,p_before=>jsonb_build_object('plan_key',v_org.plan_key),p_after=>jsonb_build_object('plan_key',p_plan_key),p_reason=>p_reason,p_organization_id=>p_organization_id);
END $$;

CREATE FUNCTION public.admin_set_subscription_dates(p_organization_id uuid,p_start date,p_end date,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org public.organizations%ROWTYPE;
BEGIN
 IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE='42501'; END IF;
 IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='P0001'; END IF;
 IF p_start IS NULL OR (p_end IS NOT NULL AND p_end<p_start) THEN RAISE EXCEPTION 'DATES_INVALID' USING ERRCODE='P0001'; END IF;
 SELECT * INTO v_org FROM public.organizations WHERE id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 UPDATE public.organizations SET subscription_start=p_start,subscription_end=p_end WHERE id=p_organization_id;
 PERFORM set_config('app.org_id',p_organization_id::text,true);
 PERFORM app.write_audit('subscription.dates_changed','organization',p_organization_id,p_before=>jsonb_build_object('subscription_start',v_org.subscription_start,'subscription_end',v_org.subscription_end),p_after=>jsonb_build_object('subscription_start',p_start,'subscription_end',p_end),p_reason=>p_reason,p_organization_id=>p_organization_id);
END $$;

CREATE FUNCTION public.admin_record_subscription_payment(p_organization_id uuid,p_amount numeric,p_period_start date,p_period_end date,p_reference text,p_extend boolean DEFAULT true,p_idempotency_key uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org public.organizations%ROWTYPE; v_id uuid;
BEGIN
 IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_org FROM public.organizations WHERE id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 SELECT id INTO v_id FROM public.subscription_payments WHERE organization_id=p_organization_id AND idempotency_key=p_idempotency_key;
 IF FOUND THEN RETURN v_id; END IF;
 IF p_amount IS NULL OR p_amount::text IN ('NaN','Infinity','-Infinity') OR p_amount<=0 OR p_amount<>round(p_amount,2) THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end<p_period_start THEN RAISE EXCEPTION 'DATES_INVALID' USING ERRCODE='P0001'; END IF;
 INSERT INTO public.subscription_payments(organization_id,plan_key,amount,period_start,period_end,reference,recorded_by_admin,idempotency_key)
 VALUES(p_organization_id,v_org.plan_key,p_amount,p_period_start,p_period_end,p_reference,auth.uid(),p_idempotency_key) RETURNING id INTO v_id;
 IF COALESCE(p_extend,true) THEN UPDATE public.organizations SET subscription_end=GREATEST(COALESCE(subscription_end,p_period_end),p_period_end),subscription_start=COALESCE(subscription_start,p_period_start) WHERE id=p_organization_id; END IF;
 PERFORM set_config('app.org_id',p_organization_id::text,true);
 PERFORM app.write_audit('subscription.payment_recorded','subscription_payment',v_id,p_after=>jsonb_build_object('plan_key',v_org.plan_key,'amount',p_amount::text,'period_start',p_period_start,'period_end',p_period_end),p_organization_id=>p_organization_id);
 RETURN v_id;
END $$;

CREATE FUNCTION public.admin_get_subscription(p_organization_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_result jsonb; v_payments jsonb;
BEGIN
 IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE='42501'; END IF;
 v_result:=app.subscription_snapshot(p_organization_id);
 IF v_result IS NULL THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'plan_key',plan_key,'amount',amount::text,'period_start',period_start,'period_end',period_end,'paid_at',paid_at,'reference',reference) ORDER BY paid_at DESC,id DESC),'[]'::jsonb) INTO v_payments FROM public.subscription_payments WHERE organization_id=p_organization_id;
 RETURN v_result||jsonb_build_object('payments',v_payments);
END $$;
CREATE FUNCTION public.get_subscription_status() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid;
BEGIN
 PERFORM app.require_session_employee(); v_org:=app.current_org_id();
 IF v_org IS NULL THEN RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE='42501'; END IF;
 RETURN app.subscription_snapshot(v_org);
END $$;
REVOKE ALL ON FUNCTION public.admin_change_plan(uuid,text,text),public.admin_set_subscription_dates(uuid,date,date,text),public.admin_record_subscription_payment(uuid,numeric,date,date,text,boolean,uuid),public.admin_get_subscription(uuid),public.get_subscription_status() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_change_plan(uuid,text,text),public.admin_set_subscription_dates(uuid,date,date,text),public.admin_record_subscription_payment(uuid,numeric,date,date,text,boolean,uuid),public.admin_get_subscription(uuid),public.get_subscription_status() TO authenticated;

DROP FUNCTION public.admin_list_organizations(text,public.org_status,integer,integer);
CREATE FUNCTION public.admin_list_organizations(p_search text DEFAULT NULL,p_status public.org_status DEFAULT NULL,p_limit integer DEFAULT 50,p_offset integer DEFAULT 0)
RETURNS TABLE(id uuid,name text,tenant_slug text,plan_key text,status public.org_status,created_at timestamptz,
 owner_full_name text,owner_email text,owner_invite_status text,total_count bigint,subscription_end date,subscription_state text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT o.id,o.name,o.tenant_slug,o.plan_key,o.status,o.created_at,e.full_name,e.email::text,
 CASE WHEN e.auth_user_id IS NOT NULL THEN 'accepted' WHEN i.id IS NULL THEN 'none' WHEN i.expires_at<=now() THEN 'expired' ELSE 'pending' END,count(*) OVER(),o.subscription_end,
 CASE WHEN o.subscription_end IS NULL THEN 'no_end' WHEN app.org_is_expired(o.id) THEN 'expired' WHEN o.subscription_end-app.org_today(o.id)<=14 THEN 'expiring' ELSE 'active' END
 FROM public.organizations o
 LEFT JOIN public.employees e ON e.organization_id=o.id AND e.role='OWNER' AND e.archived_at IS NULL
 LEFT JOIN LATERAL(SELECT iv.id,iv.expires_at FROM public.invites iv WHERE iv.employee_id=e.id AND iv.accepted_at IS NULL AND iv.revoked_at IS NULL ORDER BY iv.created_at DESC,iv.id LIMIT 1)i ON true
 WHERE (p_search IS NULL OR o.name ILIKE '%'||p_search||'%' OR o.tenant_slug ILIKE '%'||p_search||'%') AND (p_status IS NULL OR o.status=p_status)
 ORDER BY o.created_at DESC,o.id DESC LIMIT greatest(1,least(COALESCE(p_limit,50),100)) OFFSET greatest(COALESCE(p_offset,0),0);
END $$;
REVOKE ALL ON FUNCTION public.admin_list_organizations(text,public.org_status,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_organizations(text,public.org_status,integer,integer) TO authenticated;


CREATE OR REPLACE FUNCTION public.auth_record_login()
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
        RAISE EXCEPTION 'ORG_SUSPENDED' USING ERRCODE = '42501';
    END IF;


    UPDATE public.employees SET last_login_at = now() WHERE id = v_emp;
    PERFORM app.write_audit('auth.login', 'employee', v_emp);
END;
$$;
CREATE OR REPLACE FUNCTION public.session_context()
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
               WHEN v_status IS DISTINCT FROM 'active' THEN 'ORG_SUSPENDED'
           END;
END;
$$;
REVOKE ALL ON FUNCTION public.auth_record_login(), public.session_context() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auth_record_login(), public.session_context() TO authenticated;


CREATE OR REPLACE FUNCTION public.my_shops()
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
    ORDER BY o.name, o.id
$$;
