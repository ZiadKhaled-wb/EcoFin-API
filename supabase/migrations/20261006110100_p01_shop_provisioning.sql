-- P01: platform provisioning is atomic; only hashes of single-use invites are stored.
CREATE FUNCTION public.admin_provision_organization(
  p_name text, p_tenant_slug text, p_plan_key text,
  p_owner_full_name text, p_owner_email text, p_owner_phone text DEFAULT NULL,
  p_branch_name text DEFAULT 'الفرع الرئيسي',
  p_token_hash text DEFAULT NULL, p_expires_at timestamptz DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_slug text := lower(btrim(p_tenant_slug));
  v_org public.organizations%ROWTYPE;
  v_branch uuid;
  v_owner uuid;
  v_invite uuid;
BEGIN
  IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE = '42501'; END IF;
  IF v_slug IS NULL OR v_slug !~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$'
     OR v_slug = ANY(ARRAY['admin','api','app','www','support']) THEN
    RAISE EXCEPTION 'SLUG_INVALID' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS(SELECT 1 FROM public.organizations o WHERE o.tenant_slug=v_slug) THEN
    RAISE EXCEPTION 'SLUG_TAKEN' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.plans p WHERE p.key=p_plan_key AND p.is_active) THEN
    RAISE EXCEPTION 'PLAN_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF p_expires_at IS NULL OR p_expires_at<=now() OR p_expires_at>now()+interval '7 days' THEN
    RAISE EXCEPTION 'INVITE_EXPIRY_INVALID' USING ERRCODE = 'P0001';
  END IF;
  BEGIN
    INSERT INTO public.organizations(name,tenant_slug,plan_key,status,subscription_start,subscription_end)
    VALUES(p_name,v_slug,p_plan_key,'active',(now() AT TIME ZONE 'Africa/Cairo')::date,NULL) RETURNING * INTO v_org;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'SLUG_TAKEN' USING ERRCODE = 'P0001';
  END;
  INSERT INTO public.org_settings(organization_id) VALUES(v_org.id);
  INSERT INTO public.eta_settings(organization_id) VALUES(v_org.id);
  INSERT INTO public.branches(organization_id,code,name,is_main)
    VALUES(v_org.id,'MAIN',COALESCE(p_branch_name,'الفرع الرئيسي'),true) RETURNING id INTO v_branch;
  INSERT INTO public.cash_accounts(organization_id,branch_id,name,kind)
    VALUES(v_org.id,v_branch,'الخزنة الرئيسية','safe');
  INSERT INTO public.installment_policies(organization_id,version,max_months,markup_tiers)
    VALUES(v_org.id,1,12,'[{"up_to_months":12,"pct":0}]'::jsonb);
  -- Dev seeds add no other required per-shop settings; employee_branches is unnecessary for OWNER.
  INSERT INTO public.employees(organization_id,full_name,email,phone,role,default_branch_id,auth_user_id)
    VALUES(v_org.id,p_owner_full_name,lower(btrim(p_owner_email)),p_owner_phone,'OWNER',v_branch,NULL)
    RETURNING id INTO v_owner;
  INSERT INTO public.invites(organization_id,employee_id,email,token_hash,expires_at,invited_by)
    VALUES(v_org.id,v_owner,lower(btrim(p_owner_email)),p_token_hash,p_expires_at,NULL) RETURNING id INTO v_invite;
  PERFORM set_config('app.org_id',v_org.id::text,true);
  PERFORM app.write_audit('org.provisioned','organization',v_org.id,p_after=>to_jsonb(v_org),p_organization_id=>v_org.id);
  RETURN jsonb_build_object('organization_id',v_org.id,'branch_id',v_branch,'owner_employee_id',v_owner,'invite_id',v_invite);
END $$;
REVOKE ALL ON FUNCTION public.admin_provision_organization(text,text,text,text,text,text,text,text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_provision_organization(text,text,text,text,text,text,text,text,timestamptz) TO authenticated;

CREATE FUNCTION public.admin_list_organizations(p_search text DEFAULT NULL,p_status public.org_status DEFAULT NULL,p_limit integer DEFAULT 50,p_offset integer DEFAULT 0)
RETURNS TABLE(id uuid,name text,tenant_slug text,plan_key text,status public.org_status,created_at timestamptz,
  owner_full_name text,owner_email text,owner_invite_status text,total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE = '42501'; END IF;
  RETURN QUERY SELECT o.id,o.name,o.tenant_slug,o.plan_key,o.status,o.created_at,e.full_name,e.email::text,
    CASE WHEN e.auth_user_id IS NOT NULL THEN 'accepted'
         WHEN i.id IS NULL THEN 'none'
         WHEN i.expires_at<=now() THEN 'expired' ELSE 'pending' END,
    count(*) OVER()
  FROM public.organizations o
  LEFT JOIN public.employees e ON e.organization_id=o.id AND e.role='OWNER' AND e.archived_at IS NULL
  LEFT JOIN LATERAL(SELECT iv.id,iv.expires_at FROM public.invites iv
    WHERE iv.employee_id=e.id AND iv.accepted_at IS NULL AND iv.revoked_at IS NULL
    ORDER BY iv.created_at DESC,iv.id LIMIT 1) i ON true
  WHERE (p_search IS NULL OR o.name ILIKE '%'||p_search||'%' OR o.tenant_slug ILIKE '%'||p_search||'%')
    AND (p_status IS NULL OR o.status=p_status)
  ORDER BY o.created_at DESC,o.id DESC LIMIT greatest(1,least(COALESCE(p_limit,50),100)) OFFSET greatest(COALESCE(p_offset,0),0);
END $$;
REVOKE ALL ON FUNCTION public.admin_list_organizations(text,public.org_status,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_organizations(text,public.org_status,integer,integer) TO authenticated;

CREATE FUNCTION public.admin_set_organization_status(p_organization_id uuid,p_status public.org_status,p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_old public.org_status;
BEGIN
  IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE = '42501'; END IF;
  SELECT o.status INTO v_old FROM public.organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_old NOT IN ('active','suspended') OR p_status IS NULL OR p_status NOT IN ('active','suspended') OR v_old=p_status THEN
    RAISE EXCEPTION 'STATUS_NOT_ALLOWED' USING ERRCODE = 'P0001';
  END IF;
  IF p_status='suspended' AND NULLIF(btrim(p_reason),'') IS NULL THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.organizations SET status=p_status WHERE id=p_organization_id;
  PERFORM set_config('app.org_id',p_organization_id::text,true);
  PERFORM app.write_audit(CASE WHEN p_status='suspended' THEN 'org.suspended' ELSE 'org.reactivated' END,
    'organization',p_organization_id,p_before=>jsonb_build_object('status',v_old),p_after=>jsonb_build_object('status',p_status),
    p_reason=>p_reason,p_severity=>'warning',p_organization_id=>p_organization_id);
END $$;
REVOKE ALL ON FUNCTION public.admin_set_organization_status(uuid,public.org_status,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_organization_status(uuid,public.org_status,text) TO authenticated;

CREATE FUNCTION public.admin_resend_owner_invite(p_organization_id uuid,p_token_hash text,p_expires_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org public.organizations%ROWTYPE; v_owner public.employees%ROWTYPE; v_invite uuid;
BEGIN
  IF NOT app.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_org FROM public.organizations WHERE id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_org.status<>'active' THEN RAISE EXCEPTION 'ORG_NOT_ACTIVE' USING ERRCODE = 'P0001'; END IF;
  IF p_expires_at IS NULL OR p_expires_at<=now() OR p_expires_at>now()+interval '7 days' THEN
    RAISE EXCEPTION 'INVITE_EXPIRY_INVALID' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_owner FROM public.employees WHERE organization_id=p_organization_id AND role='OWNER' AND archived_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_owner.auth_user_id IS NOT NULL THEN RAISE EXCEPTION 'OWNER_ALREADY_ACTIVE' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.invites SET revoked_at=now() WHERE employee_id=v_owner.id AND accepted_at IS NULL AND revoked_at IS NULL;
  -- Recheck after the invite lock; concurrent acceptance must never produce a new linked-owner invite.
  SELECT * INTO v_owner FROM public.employees WHERE id=v_owner.id FOR UPDATE;
  IF v_owner.auth_user_id IS NOT NULL THEN RAISE EXCEPTION 'OWNER_ALREADY_ACTIVE' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO public.invites(organization_id,employee_id,email,token_hash,expires_at,invited_by)
    VALUES(p_organization_id,v_owner.id,v_owner.email,p_token_hash,p_expires_at,NULL) RETURNING id INTO v_invite;
  PERFORM set_config('app.org_id',p_organization_id::text,true);
  PERFORM app.write_audit('invite.resent','invite',v_invite,p_after=>jsonb_build_object('employee_id',v_owner.id,'expires_at',p_expires_at),p_organization_id=>p_organization_id);
  RETURN jsonb_build_object('email',v_owner.email,'owner_full_name',v_owner.full_name,'shop_name',v_org.name,'expires_at',p_expires_at);
END $$;
REVOKE ALL ON FUNCTION public.admin_resend_owner_invite(uuid,text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resend_owner_invite(uuid,text,timestamptz) TO authenticated;

CREATE FUNCTION public.invite_lookup(p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_invite public.invites%ROWTYPE; v_org public.organizations%ROWTYPE; v_name text; v_status text;
BEGIN
  SELECT * INTO v_invite FROM public.invites WHERE token_hash=p_token_hash;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO v_org FROM public.organizations WHERE id=v_invite.organization_id;
  IF v_org.status IS DISTINCT FROM 'active' THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT full_name INTO v_name FROM public.employees WHERE id=v_invite.employee_id;
  v_status:=CASE WHEN v_invite.accepted_at IS NOT NULL OR v_invite.revoked_at IS NOT NULL THEN 'used'
    WHEN v_invite.expires_at<=now() THEN 'expired' ELSE 'valid' END;
  RETURN jsonb_build_object('status',v_status,'shop_name',v_org.name,'tenant_slug',v_org.tenant_slug,'full_name',v_name,
    'email',v_invite.email,'account_exists',EXISTS(SELECT 1 FROM auth.users u WHERE lower(u.email)=lower(v_invite.email::text)));
END $$;
REVOKE ALL ON FUNCTION public.invite_lookup(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.invite_lookup(text) TO service_role;

CREATE FUNCTION public.accept_invite(p_token_hash text,p_auth_user_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_invite public.invites%ROWTYPE; v_slug text; v_email text;
BEGIN
  SELECT * INTO v_invite FROM public.invites WHERE token_hash=p_token_hash FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVITE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_invite.accepted_at IS NOT NULL OR v_invite.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'INVITE_USED' USING ERRCODE = 'P0001'; END IF;
  IF v_invite.expires_at<=now() THEN RAISE EXCEPTION 'INVITE_EXPIRED' USING ERRCODE = 'P0001'; END IF;
  SELECT tenant_slug INTO v_slug FROM public.organizations WHERE id=v_invite.organization_id AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'INVITE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT email INTO v_email FROM auth.users WHERE id=p_auth_user_id;
  IF v_email IS NULL OR lower(v_email)<>lower(v_invite.email::text) THEN RAISE EXCEPTION 'INVITE_EMAIL_MISMATCH' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.employees SET auth_user_id=p_auth_user_id,must_change_password=false
    WHERE id=v_invite.employee_id AND auth_user_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVITE_USED' USING ERRCODE = 'P0001'; END IF;
  UPDATE public.invites SET accepted_at=now() WHERE id=v_invite.id;
  PERFORM set_config('app.org_id',v_invite.organization_id::text,true);
  PERFORM app.write_audit('invite.accepted','invite',v_invite.id,p_after=>jsonb_build_object('employee_id',v_invite.employee_id),p_organization_id=>v_invite.organization_id);
  RETURN jsonb_build_object('organization_id',v_invite.organization_id,'employee_id',v_invite.employee_id,'tenant_slug',v_slug,'email',v_invite.email);
END $$;
REVOKE ALL ON FUNCTION public.accept_invite(text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.accept_invite(text,uuid) TO service_role;
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
    IF v_end IS NOT NULL AND v_end < app.org_today(v_org) THEN
        RAISE EXCEPTION 'SUBSCRIPTION_EXPIRED' USING ERRCODE = '42501';
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
               WHEN v_end IS NOT NULL AND v_end < app.org_today(v_emp.organization_id)
                   THEN 'SUBSCRIPTION_EXPIRED'
           END;
END;
$$;
REVOKE ALL ON FUNCTION public.auth_record_login(), public.session_context() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auth_record_login(), public.session_context() TO authenticated;

