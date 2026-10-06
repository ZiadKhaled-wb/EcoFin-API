-- O02: tenant staff management and service-only single-use password reset tokens.
CREATE TABLE public.password_resets (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, employee_id uuid NOT NULL,
 token_hash text NOT NULL UNIQUE, expires_at timestamptz NOT NULL, used_at timestamptz, revoked_at timestamptz,
 created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(employee_id,organization_id) REFERENCES public.employees(id,organization_id),
 CHECK(used_at IS NULL OR revoked_at IS NULL)
);
CREATE UNIQUE INDEX password_resets_one_open_idx ON public.password_resets(employee_id) WHERE used_at IS NULL AND revoked_at IS NULL;
ALTER TABLE public.password_resets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.password_resets FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.password_resets TO service_role;

CREATE FUNCTION app.assert_can_grant(p_role public.employee_role,p_keys text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE k text;
BEGIN
 IF app.current_role()='OWNER' THEN RETURN; END IF;
 FOR k IN SELECT permission_key FROM public.role_permissions WHERE role=p_role UNION SELECT unnest(p_keys) ORDER BY 1 LOOP
  IF NOT app.has_permission(k) THEN RAISE EXCEPTION 'PERMISSION_ESCALATION: %',k USING ERRCODE='42501'; END IF;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION app.assert_can_grant(public.employee_role,text[]) FROM PUBLIC,anon,authenticated;

-- Serialize management with subscription limits; token locks precede employee locks like acceptance/consumption.
CREATE FUNCTION app.lock_staff(p_employee_id uuid,p_protect boolean) RETURNS public.employees
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e public.employees%ROWTYPE; o uuid:=app.current_org_id();
BEGIN
 PERFORM 1 FROM public.organizations WHERE id=o FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.employees WHERE id=p_employee_id AND organization_id=o AND archived_at IS NULL) THEN
  RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 PERFORM 1 FROM public.invites WHERE employee_id=p_employee_id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.password_resets WHERE employee_id=p_employee_id ORDER BY id FOR UPDATE;
 SELECT * INTO e FROM public.employees WHERE id=p_employee_id AND organization_id=o AND archived_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 IF p_protect AND (e.role='OWNER' OR e.id=app.current_employee_id()) THEN RAISE EXCEPTION 'TARGET_NOT_ALLOWED' USING ERRCODE='42501'; END IF;
 RETURN e;
END $$;
REVOKE ALL ON FUNCTION app.lock_staff(uuid,boolean) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app.check_staff_login(p_email text,p_username text,p_employee_id uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o uuid:=app.current_org_id();
BEGIN
 IF p_email IS NULL AND p_username IS NULL THEN RAISE EXCEPTION 'LOGIN_REQUIRED' USING ERRCODE='P0001'; END IF;
 IF p_username IS NOT NULL AND p_username !~ '^[a-z0-9._-]{3,32}$' THEN RAISE EXCEPTION 'USERNAME_INVALID' USING ERRCODE='P0001'; END IF;
 IF EXISTS(SELECT 1 FROM public.employees WHERE organization_id=o AND email=p_email::extensions.citext AND id IS DISTINCT FROM p_employee_id) THEN RAISE EXCEPTION 'EMAIL_TAKEN' USING ERRCODE='P0001'; END IF;
 IF EXISTS(SELECT 1 FROM public.employees WHERE organization_id=o AND username=p_username::extensions.citext AND id IS DISTINCT FROM p_employee_id) THEN RAISE EXCEPTION 'USERNAME_TAKEN' USING ERRCODE='P0001'; END IF;
END $$;
REVOKE ALL ON FUNCTION app.check_staff_login(text,text,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.create_employee(p_full_name text,p_phone text,p_email text,p_username text,p_role public.employee_role,
 p_branch_ids uuid[],p_default_branch_id uuid,p_overrides jsonb,p_token_hash text,p_expires_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid:=app.require_permission('employee.manage'); o uuid:=app.current_org_id(); e uuid; b uuid; k record;
 mail text:=NULLIF(lower(btrim(p_email)),''); usr text:=NULLIF(lower(btrim(p_username)),''); def uuid; invite_email text;
BEGIN
 PERFORM 1 FROM public.organizations WHERE id=o FOR UPDATE;
 IF NULLIF(btrim(p_full_name),'') IS NULL THEN RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE='P0001'; END IF;
 PERFORM app.check_staff_login(mail,usr);
 IF p_role IS NULL OR p_role='OWNER' THEN RAISE EXCEPTION 'ROLE_NOT_ALLOWED' USING ERRCODE='42501'; END IF;
 IF COALESCE(cardinality(p_branch_ids),0)=0 THEN RAISE EXCEPTION 'BRANCH_REQUIRED' USING ERRCODE='P0001'; END IF;
 FOREACH b IN ARRAY p_branch_ids LOOP IF NOT EXISTS(SELECT 1 FROM public.branches WHERE id=b AND organization_id=o) THEN RAISE EXCEPTION 'BRANCH_NOT_IN_ORG' USING ERRCODE='P0001'; END IF; PERFORM app.require_branch_access(b); END LOOP;
 def:=COALESCE(p_default_branch_id,p_branch_ids[1]);
 IF NOT def=ANY(p_branch_ids) THEN RAISE EXCEPTION 'BRANCH_NOT_IN_ORG' USING ERRCODE='P0001'; END IF;
 IF jsonb_typeof(p_overrides) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 FOR k IN SELECT * FROM jsonb_to_recordset(p_overrides) AS x(key text,granted boolean) LOOP
  IF NOT EXISTS(SELECT 1 FROM public.permissions WHERE key=k.key) THEN RAISE EXCEPTION 'UNKNOWN_PERMISSION' USING ERRCODE='P0001'; END IF;
  IF k.granted IS NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 END LOOP;
 PERFORM app.assert_can_grant(p_role,ARRAY(SELECT x->>'key' FROM jsonb_array_elements(p_overrides)x WHERE (x->>'granted')::boolean));
 IF p_expires_at IS NULL OR p_expires_at<=now() OR p_expires_at>now()+interval '7 days' THEN RAISE EXCEPTION 'INVITE_EXPIRY_INVALID' USING ERRCODE='P0001'; END IF;
 INSERT INTO public.employees(organization_id,full_name,phone,email,username,role,default_branch_id,created_by)
 VALUES(o,btrim(p_full_name),p_phone,mail,usr,p_role,def,v_emp) RETURNING id INTO e;
 INSERT INTO public.employee_branches(organization_id,employee_id,branch_id,created_by) SELECT o,e,x,v_emp FROM (SELECT DISTINCT unnest(p_branch_ids)x)bs;
 INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted,created_by)
 SELECT o,e,x.key,x.granted,v_emp FROM jsonb_to_recordset(p_overrides) AS x(key text,granted boolean);
 invite_email:=COALESCE(mail,usr||'@'||o::text||'.ecofin.invalid');
 INSERT INTO public.invites(organization_id,employee_id,email,token_hash,expires_at,invited_by) VALUES(o,e,invite_email,p_token_hash,p_expires_at,v_emp);
 PERFORM app.write_audit('employee.created','employee',e,p_after=>jsonb_build_object('full_name',btrim(p_full_name),'role',p_role,'branch_ids',p_branch_ids));
 RETURN jsonb_build_object('employee_id',e,'invite_email',invite_email,'delivery',CASE WHEN mail IS NULL THEN 'link' ELSE 'email' END);
END $$;
REVOKE ALL ON FUNCTION public.create_employee(text,text,text,text,public.employee_role,uuid[],uuid,jsonb,text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_employee(text,text,text,text,public.employee_role,uuid[],uuid,jsonb,text,timestamptz) TO authenticated;

CREATE FUNCTION public.update_employee(p_employee_id uuid,p_full_name text,p_phone text,p_email text,p_username text,p_role public.employee_role,p_default_branch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid:=app.require_permission('employee.manage'); o uuid:=app.current_org_id(); e public.employees%ROWTYPE;
 mail text:=NULLIF(lower(btrim(p_email)),''); usr text:=NULLIF(lower(btrim(p_username)),''); revoked boolean;
BEGIN
 e:=app.lock_staff(p_employee_id,true);
 IF NULLIF(btrim(p_full_name),'') IS NULL THEN RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE='P0001'; END IF;
 IF p_role IS NULL OR p_role='OWNER' THEN RAISE EXCEPTION 'ROLE_NOT_ALLOWED' USING ERRCODE='42501'; END IF;
 revoked:=e.email::text IS DISTINCT FROM mail OR e.username::text IS DISTINCT FROM usr;
 IF revoked AND e.auth_user_id IS NOT NULL THEN RAISE EXCEPTION 'LOGIN_LOCKED' USING ERRCODE='P0001'; END IF;
 PERFORM app.check_staff_login(mail,usr,p_employee_id);
 IF e.role IS DISTINCT FROM p_role THEN PERFORM app.assert_can_grant(p_role,'{}'); END IF;
 IF p_default_branch_id IS NOT NULL THEN
  IF NOT EXISTS(SELECT 1 FROM public.employee_branches WHERE employee_id=e.id AND branch_id=p_default_branch_id) THEN RAISE EXCEPTION 'BRANCH_NOT_IN_ORG' USING ERRCODE='P0001'; END IF;
  PERFORM app.require_branch_access(p_default_branch_id);
 END IF;
 IF revoked THEN UPDATE public.invites SET revoked_at=now() WHERE employee_id=e.id AND accepted_at IS NULL AND revoked_at IS NULL; END IF;
 UPDATE public.employees SET full_name=btrim(p_full_name),phone=p_phone,email=mail,username=usr,role=p_role,default_branch_id=p_default_branch_id,updated_by=v_emp WHERE id=e.id;
 PERFORM app.write_audit('employee.updated','employee',e.id,p_before=>to_jsonb(e),p_after=>(SELECT to_jsonb(x) FROM public.employees x WHERE x.id=e.id));
 RETURN jsonb_build_object('invite_revoked',revoked);
END $$;
REVOKE ALL ON FUNCTION public.update_employee(uuid,text,text,text,text,public.employee_role,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.update_employee(uuid,text,text,text,text,public.employee_role,uuid) TO authenticated;

CREATE FUNCTION public.set_employee_active(p_employee_id uuid,p_active boolean,p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid:=app.require_permission('employee.manage'); o uuid:=app.current_org_id(); e public.employees%ROWTYPE;
BEGIN
 e:=app.lock_staff(p_employee_id,true);
 IF p_active IS NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 IF e.is_active=p_active THEN RETURN; END IF;
 IF NOT p_active AND NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='P0001'; END IF;
 UPDATE public.employees SET is_active=p_active,updated_by=v_emp WHERE id=e.id;
 IF NOT p_active THEN
  UPDATE public.invites SET revoked_at=now() WHERE employee_id=e.id AND accepted_at IS NULL AND revoked_at IS NULL;
  UPDATE public.password_resets SET revoked_at=now() WHERE employee_id=e.id AND used_at IS NULL AND revoked_at IS NULL;
 END IF;
 PERFORM app.write_audit(CASE WHEN p_active THEN 'employee.reactivate' ELSE 'employee.deactivate' END,'employee',e.id,
 p_before=>jsonb_build_object('is_active',e.is_active),p_after=>jsonb_build_object('is_active',p_active),p_reason=>p_reason,p_severity=>'warning');
END $$;
REVOKE ALL ON FUNCTION public.set_employee_active(uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_employee_active(uuid,boolean,text) TO authenticated;

CREATE FUNCTION public.resend_employee_invite(p_employee_id uuid,p_token_hash text,p_expires_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid:=app.require_permission('employee.manage'); o uuid:=app.current_org_id(); e public.employees%ROWTYPE; i uuid; mail text;
BEGIN
 e:=app.lock_staff(p_employee_id,false);
 IF e.auth_user_id IS NOT NULL THEN RAISE EXCEPTION 'INVITE_ALREADY_ACCEPTED' USING ERRCODE='P0001'; END IF;
 IF NOT e.is_active THEN RAISE EXCEPTION 'EMPLOYEE_INACTIVE' USING ERRCODE='P0001'; END IF;
 IF p_expires_at IS NULL OR p_expires_at<=now() OR p_expires_at>now()+interval '7 days' THEN RAISE EXCEPTION 'INVITE_EXPIRY_INVALID' USING ERRCODE='P0001'; END IF;
 UPDATE public.invites SET revoked_at=now() WHERE employee_id=e.id AND accepted_at IS NULL AND revoked_at IS NULL;
 mail:=COALESCE(e.email::text,e.username::text||'@'||o::text||'.ecofin.invalid');
 INSERT INTO public.invites(organization_id,employee_id,email,token_hash,expires_at,invited_by) VALUES(o,e.id,mail,p_token_hash,p_expires_at,v_emp) RETURNING id INTO i;
 PERFORM app.write_audit('invite.resent','invite',i,p_after=>jsonb_build_object('employee_id',e.id,'expires_at',p_expires_at));
 RETURN jsonb_build_object('employee_id',e.id,'invite_email',mail,'delivery',CASE WHEN e.email IS NULL THEN 'link' ELSE 'email' END);
END $$;
REVOKE ALL ON FUNCTION public.resend_employee_invite(uuid,text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.resend_employee_invite(uuid,text,timestamptz) TO authenticated;

CREATE FUNCTION public.create_password_reset(p_employee_id uuid,p_token_hash text,p_expires_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid:=app.require_permission('employee.manage'); o uuid:=app.current_org_id(); e public.employees%ROWTYPE;
BEGIN
 e:=app.lock_staff(p_employee_id,true);
 IF e.auth_user_id IS NULL THEN RAISE EXCEPTION 'EMPLOYEE_NOT_LINKED' USING ERRCODE='P0001'; END IF;
 IF NOT e.is_active THEN RAISE EXCEPTION 'EMPLOYEE_INACTIVE' USING ERRCODE='P0001'; END IF;
 IF p_expires_at IS NULL OR p_expires_at<=now() OR p_expires_at>now()+interval '24 hours' THEN RAISE EXCEPTION 'INVITE_EXPIRY_INVALID' USING ERRCODE='P0001'; END IF;
 UPDATE public.password_resets SET revoked_at=now() WHERE employee_id=e.id AND used_at IS NULL AND revoked_at IS NULL;
 INSERT INTO public.password_resets(organization_id,employee_id,token_hash,expires_at,created_by) VALUES(o,e.id,p_token_hash,p_expires_at,v_emp);
 PERFORM app.write_audit('employee.password_reset_requested','employee',e.id,p_after=>jsonb_build_object('expires_at',p_expires_at));
 RETURN jsonb_build_object('delivery',CASE WHEN e.email IS NULL THEN 'link' ELSE 'email' END,'email',COALESCE(e.email::text,e.username::text||'@'||o::text||'.ecofin.invalid'));
END $$;
REVOKE ALL ON FUNCTION public.create_password_reset(uuid,text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_password_reset(uuid,text,timestamptz) TO authenticated;

CREATE FUNCTION public.list_employees(p_search text,p_role public.employee_role,p_status text,p_limit int,p_offset int)
RETURNS TABLE(id uuid,full_name text,phone text,email text,username text,role public.employee_role,is_active boolean,default_branch_id uuid,branch_ids uuid[],invite_status text,override_count bigint,created_at timestamptz,total_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid:=app.require_permission('employee.manage'); o uuid:=app.current_org_id();
BEGIN
 IF p_status IS NOT NULL AND p_status NOT IN ('active','inactive','pending','expired') THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 RETURN QUERY WITH rows AS (
 SELECT e.id,e.full_name,e.phone,e.email::text,e.username::text,e.role,e.is_active,e.default_branch_id,
 COALESCE((SELECT array_agg(eb.branch_id ORDER BY eb.branch_id) FROM public.employee_branches eb WHERE eb.employee_id=e.id),'{}'::uuid[]) branch_ids,
 CASE WHEN e.auth_user_id IS NOT NULL THEN 'accepted' WHEN i.id IS NULL THEN 'none' WHEN i.expires_at<=now() THEN 'expired' ELSE 'pending' END invite_status,
 (SELECT count(*) FROM public.employee_permission_overrides ep WHERE ep.employee_id=e.id) override_count,e.created_at
 FROM public.employees e LEFT JOIN LATERAL(SELECT iv.id,iv.expires_at FROM public.invites iv WHERE iv.employee_id=e.id AND iv.accepted_at IS NULL AND iv.revoked_at IS NULL ORDER BY iv.created_at DESC,iv.id LIMIT 1)i ON true
 WHERE e.organization_id=o AND e.archived_at IS NULL AND (p_role IS NULL OR e.role=p_role)
 AND (p_search IS NULL OR e.full_name ILIKE '%'||p_search||'%' OR e.email ILIKE '%'||p_search||'%' OR e.username ILIKE '%'||p_search||'%'))
 SELECT r.*,count(*) OVER() FROM rows r WHERE p_status IS NULL OR
 (p_status='active' AND r.is_active) OR (p_status='inactive' AND NOT r.is_active) OR (p_status IN ('pending','expired') AND r.is_active AND r.invite_status=p_status)
 ORDER BY (r.role='OWNER') DESC,r.full_name,r.id LIMIT greatest(1,least(COALESCE(p_limit,50),100)) OFFSET greatest(COALESCE(p_offset,0),0);
END $$;
REVOKE ALL ON FUNCTION public.list_employees(text,public.employee_role,text,int,int) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.list_employees(text,public.employee_role,text,int,int) TO authenticated;

CREATE FUNCTION public.password_reset_lookup(p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.password_resets%ROWTYPE; e public.employees%ROWTYPE; o public.organizations%ROWTYPE;
BEGIN
 SELECT * INTO r FROM public.password_resets WHERE token_hash=p_token_hash;
 IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
 SELECT * INTO e FROM public.employees WHERE id=r.employee_id AND organization_id=r.organization_id;
 SELECT * INTO o FROM public.organizations WHERE id=r.organization_id;
 IF NOT e.is_active OR e.archived_at IS NOT NULL OR o.status IS DISTINCT FROM 'active' THEN RETURN jsonb_build_object('status','not_found'); END IF;
 IF r.used_at IS NOT NULL OR r.revoked_at IS NOT NULL THEN RETURN jsonb_build_object('status','used'); END IF;
 IF r.expires_at<=now() THEN RETURN jsonb_build_object('status','expired'); END IF;
 RETURN jsonb_build_object('status','valid','full_name',e.full_name,'login',COALESCE(e.username::text,e.email::text),'shop_name',o.name,'tenant_slug',o.tenant_slug);
END $$;
REVOKE ALL ON FUNCTION public.password_reset_lookup(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.password_reset_lookup(text) TO service_role;

CREATE FUNCTION public.consume_password_reset(p_token_hash text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.password_resets%ROWTYPE; e public.employees%ROWTYPE;
BEGIN
 SELECT * INTO r FROM public.password_resets WHERE token_hash=p_token_hash FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'RESET_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 SELECT * INTO e FROM public.employees WHERE id=r.employee_id AND organization_id=r.organization_id FOR UPDATE;
 IF NOT e.is_active OR e.archived_at IS NOT NULL OR NOT EXISTS(SELECT 1 FROM public.organizations WHERE id=r.organization_id AND status='active') THEN RAISE EXCEPTION 'RESET_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 IF r.used_at IS NOT NULL OR r.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'RESET_USED' USING ERRCODE='P0001'; END IF;
 IF r.expires_at<=now() THEN RAISE EXCEPTION 'RESET_EXPIRED' USING ERRCODE='P0001'; END IF;
 UPDATE public.password_resets SET used_at=now() WHERE id=r.id;
 UPDATE public.employees SET must_change_password=false WHERE id=e.id;
 PERFORM set_config('app.org_id',r.organization_id::text,true);
 PERFORM app.write_audit('employee.password_reset_completed','employee',e.id,p_organization_id=>r.organization_id);
 RETURN e.auth_user_id;
END $$;
REVOKE ALL ON FUNCTION public.consume_password_reset(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.consume_password_reset(text) TO service_role;
CREATE OR REPLACE FUNCTION public.invite_lookup(p_token_hash text) RETURNS jsonb
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
    'login',(SELECT COALESCE(username::text,email::text) FROM public.employees WHERE id=v_invite.employee_id),'email',v_invite.email,'account_exists',EXISTS(SELECT 1 FROM auth.users u WHERE lower(u.email)=lower(v_invite.email::text)));
END $$;
REVOKE ALL ON FUNCTION public.invite_lookup(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.invite_lookup(text) TO service_role;
CREATE OR REPLACE FUNCTION public.accept_invite(p_token_hash text,p_auth_user_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_invite public.invites%ROWTYPE; v_slug text; v_email text;
BEGIN
  SELECT * INTO v_invite FROM public.invites WHERE token_hash=p_token_hash FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVITE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_invite.accepted_at IS NOT NULL OR v_invite.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'INVITE_USED' USING ERRCODE = 'P0001'; END IF;
  IF v_invite.expires_at<=now() THEN RAISE EXCEPTION 'INVITE_EXPIRED' USING ERRCODE = 'P0001'; END IF;
  SELECT tenant_slug INTO v_slug FROM public.organizations WHERE id=v_invite.organization_id AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'INVITE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.employees WHERE id=v_invite.employee_id AND is_active AND archived_at IS NULL) THEN RAISE EXCEPTION 'INVITE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
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
