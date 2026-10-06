-- P01: local, transactional provisioning, invitations, access and usability.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE SCHEMA t;
CREATE TABLE t.results (name text, ok boolean, detail text);
CREATE TABLE t.shops (slug text PRIMARY KEY, result jsonb);
CREATE FUNCTION t.expect(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO t.results VALUES (p_name, p_ok, p_detail)
$$;
CREATE FUNCTION t.expect_error(p_name text, p_sql text, p_code text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql; INSERT INTO t.results VALUES (p_name, false, 'no error');
  EXCEPTION WHEN others THEN INSERT INTO t.results VALUES (p_name, SQLERRM = p_code OR split_part(SQLERRM,':',1)=p_code, SQLERRM); END;
END $$;
CREATE FUNCTION t.as_user(p_sub text, p_org text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', COALESCE(p_sub,''),false),
    set_config('app.org_id','',false),
    set_config('request.headers',CASE WHEN p_org IS NULL THEN '{}' ELSE json_build_object('x-org-id',p_org)::text END,false)
$$;
CREATE FUNCTION t.provision(p_slug text, p_hash text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.admin_provision_organization('P01 ' || p_slug,p_slug,'starter','P01 Owner',p_slug || '@example.com',NULL,'Main',p_hash,now()+interval '72 hours')
$$;
CREATE FUNCTION t.org(p_slug text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE slug=p_slug $$;
CREATE FUNCTION t.emp(p_slug text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'owner_employee_id')::uuid FROM t.shops WHERE slug=p_slug $$;
CREATE FUNCTION t.branch(p_slug text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'branch_id')::uuid FROM t.shops WHERE slug=p_slug $$;
GRANT USAGE ON SCHEMA t TO authenticated, anon, service_role;
GRANT INSERT ON t.results TO authenticated,anon,service_role;
GRANT INSERT ON t.shops TO authenticated;
GRANT SELECT ON t.shops TO authenticated,service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated,anon,service_role;

SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
INSERT INTO t.shops VALUES ('p01-main',t.provision('p01-main',repeat('1',64)));
RESET ROLE;
SELECT t.expect('1 organization active with Cairo start and no end',(SELECT count(*)=1 AND bool_and(status='active' AND subscription_start=(now() AT TIME ZONE 'Africa/Cairo')::date AND subscription_end IS NULL) FROM public.organizations WHERE id=t.org('p01-main')));
SELECT t.expect('2 org settings',(SELECT count(*)=1 FROM public.org_settings WHERE organization_id=t.org('p01-main')));
SELECT t.expect('3 ETA disabled defaults',(SELECT count(*)=1 AND bool_and(NOT is_enabled) FROM public.eta_settings WHERE organization_id=t.org('p01-main')));
SELECT t.expect('4 main branch MAIN',(SELECT count(*)=1 AND bool_and(is_main AND code='MAIN') FROM public.branches WHERE organization_id=t.org('p01-main')));
SELECT t.expect('5 one main safe',(SELECT count(*)=1 AND bool_and(kind='safe' AND branch_id=t.branch('p01-main')) FROM public.cash_accounts WHERE organization_id=t.org('p01-main')));
SELECT t.expect('6 safe starts at zero via balance view',(SELECT count(*)=1 AND bool_and(balance=0) FROM public.v_cash_balances WHERE organization_id=t.org('p01-main')));
SELECT t.expect('7 policy v1',(SELECT count(*)=1 AND bool_and(version=1 AND max_months=12 AND markup_tiers='[{"up_to_months":12,"pct":0}]'::jsonb) FROM public.installment_policies WHERE organization_id=t.org('p01-main')));
SELECT t.expect('8 unlinked owner',(SELECT count(*)=1 AND bool_and(role='OWNER' AND auth_user_id IS NULL AND default_branch_id=t.branch('p01-main')) FROM public.employees WHERE organization_id=t.org('p01-main')));
SELECT t.expect('9 one open platform invite',(SELECT count(*)=1 AND bool_and(accepted_at IS NULL AND revoked_at IS NULL AND invited_by IS NULL) FROM public.invites WHERE organization_id=t.org('p01-main')));
SELECT t.expect('10 audit lands in target shop with platform actor',(SELECT count(*)=1 AND bool_and(super_admin_id='f0000000-0000-0000-0000-000000000001' AND organization_id=t.org('p01-main')) FROM public.audit_log WHERE entity_id=t.org('p01-main') AND action='org.provisioned'));
SELECT t.expect('11 pending list',(SELECT owner_invite_status='pending' AND total_count>=1 FROM public.admin_list_organizations('p01-main',NULL,10,0) WHERE id=t.org('p01-main')));
SELECT t.expect_error('12 duplicate hash rolls back',$q$SELECT t.provision('p01-rollback',repeat('1',64))$q$,'duplicate key value violates unique constraint "invites_token_hash_key"');
SELECT t.expect('13 rollback leaves no org/branch/employee',(SELECT count(*)=0 FROM public.organizations WHERE tenant_slug='p01-rollback') AND NOT EXISTS(SELECT 1 FROM public.branches WHERE name='P01 p01-rollback') AND NOT EXISTS(SELECT 1 FROM public.employees WHERE email='p01-rollback@example.com'));
SELECT t.expect_error('14 duplicate slug',$q$SELECT t.provision('p01-main',repeat('2',64))$q$,'SLUG_TAKEN');
SELECT t.expect_error('15 reserved slug',$q$SELECT t.provision('admin',repeat('2',64))$q$,'SLUG_INVALID');
SELECT t.expect_error('16 malformed slug',$q$SELECT t.provision('-bad',repeat('2',64))$q$,'SLUG_INVALID');
SELECT t.expect_error('17 missing plan',$q$SELECT public.admin_provision_organization('x','p01-bad-plan','missing','Owner','x@example.com',NULL,'Main',repeat('2',64),now()+interval '1 hour')$q$,'PLAN_NOT_FOUND');
SELECT t.expect_error('18 excessive expiry',$q$SELECT public.admin_provision_organization('x','p01-bad-ttl','starter','Owner','x@example.com',NULL,'Main',repeat('2',64),now()+interval '8 days')$q$,'INVITE_EXPIRY_INVALID');

SELECT t.as_user('d0000000-0000-0000-0000-000000000011');
SET LOCAL ROLE authenticated;
SELECT t.expect_error('19 owner cannot provision',$q$SELECT t.provision('p01-denied',repeat('2',64))$q$,'SUPER_ADMIN_REQUIRED');
SELECT t.expect_error('20 owner cannot list',$q$SELECT * FROM public.admin_list_organizations(NULL,NULL,10,0)$q$,'SUPER_ADMIN_REQUIRED');
SELECT t.expect_error('21 owner cannot set status',format('SELECT public.admin_set_organization_status(%L,''suspended'',''reason'')',t.org('p01-main')),'SUPER_ADMIN_REQUIRED');
SELECT t.expect_error('22 owner cannot resend',format('SELECT public.admin_resend_owner_invite(%L,%L,now()+interval ''1 day'')',t.org('p01-main'),repeat('2',64)),'SUPER_ADMIN_REQUIRED');
RESET ROLE;
SELECT t.expect('23 invite functions service role only',NOT has_function_privilege('anon','public.invite_lookup(text)','EXECUTE') AND NOT has_function_privilege('authenticated','public.invite_lookup(text)','EXECUTE') AND NOT has_function_privilege('anon','public.accept_invite(text,uuid)','EXECUTE') AND NOT has_function_privilege('authenticated','public.accept_invite(text,uuid)','EXECUTE') AND has_function_privilege('service_role','public.accept_invite(text,uuid)','EXECUTE'));
INSERT INTO auth.users(id,email) VALUES ('a0100000-0000-4000-8000-000000000001','p01-main@example.com'),('a0100000-0000-4000-8000-000000000002','wrong@example.com');
SELECT t.as_user(NULL);
SET LOCAL ROLE service_role;
SELECT t.expect('24 lookup valid without existing account initially',public.invite_lookup(repeat('1',64))->>'status'='valid' AND (public.invite_lookup(repeat('1',64))->>'account_exists')::boolean);
SELECT t.expect_error('25 email mismatch',$q$SELECT public.accept_invite(repeat('1',64),'a0100000-0000-4000-8000-000000000002')$q$,'INVITE_EMAIL_MISMATCH');
SELECT t.expect('26 accepts valid owner',public.accept_invite(repeat('1',64),'a0100000-0000-4000-8000-000000000001')->>'tenant_slug'='p01-main');
SELECT t.expect_error('27 single use',$q$SELECT public.accept_invite(repeat('1',64),'a0100000-0000-4000-8000-000000000001')$q$,'INVITE_USED');
SELECT t.expect_error('28 unknown hash',$q$SELECT public.accept_invite(repeat('9',64),'a0100000-0000-4000-8000-000000000001')$q$,'INVITE_NOT_FOUND');
RESET ROLE;
SELECT t.expect('29 employee linked and flag clear',(SELECT auth_user_id='a0100000-0000-4000-8000-000000000001' AND NOT must_change_password FROM public.employees WHERE id=t.emp('p01-main')));
INSERT INTO public.employees(id,organization_id,full_name,role) VALUES ('a0100000-0000-4000-8000-000000000003',t.org('p01-main'),'Cashier','CASHIER');
SELECT t.as_user('a0100000-0000-4000-8000-000000000001',t.org('p01-main')::text);
SET LOCAL ROLE authenticated;
SELECT t.expect('30 current org resolves new shop',app.current_org_id()=t.org('p01-main'));
SELECT t.expect('31 sees only own main branch',(SELECT count(*)=1 AND bool_and(organization_id=t.org('p01-main')) FROM public.branches));
SELECT t.expect('32 sees only own safe',(SELECT count(*)=1 AND bool_and(organization_id=t.org('p01-main')) FROM public.cash_accounts));
SELECT t.expect('33 existing F06 write succeeds',(SELECT count(*)=1 FROM public.set_employee_branches('a0100000-0000-4000-8000-000000000003',ARRAY[t.branch('p01-main')],'P01 usability')));
RESET ROLE;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
SELECT public.admin_set_organization_status(t.org('p01-main'),'suspended','P01 test');
SELECT t.as_user('a0100000-0000-4000-8000-000000000001',t.org('p01-main')::text);
SET LOCAL ROLE authenticated;
SELECT t.expect_error('34 suspended writes blocked',$q$SELECT public.set_employee_branches('a0100000-0000-4000-8000-000000000003','{}','P01')$q$,'ORG_NOT_ACTIVE');
RESET ROLE;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
SELECT public.admin_set_organization_status(t.org('p01-main'),'active',NULL);
SELECT t.expect_error('35 cannot set expired',format('SELECT public.admin_set_organization_status(%L,''expired'',''reason'')',t.org('p01-main')),'STATUS_NOT_ALLOWED');
SELECT t.expect_error('36 cannot set closed',format('SELECT public.admin_set_organization_status(%L,''closed'',''reason'')',t.org('p01-main')),'STATUS_NOT_ALLOWED');
SELECT t.expect_error('37 suspension requires reason',format('SELECT public.admin_set_organization_status(%L,''suspended'','' '')',t.org('p01-main')),'REASON_REQUIRED');
SELECT t.expect_error('38 linked owner cannot resend',format('SELECT public.admin_resend_owner_invite(%L,%L,now()+interval ''1 day'')',t.org('p01-main'),repeat('2',64)),'OWNER_ALREADY_ACTIVE');
INSERT INTO t.shops VALUES ('p01-expired',t.provision('p01-expired',repeat('2',64))),('p01-resend',t.provision('p01-resend',repeat('3',64)));
UPDATE public.invites SET expires_at=now()-interval '1 second' WHERE employee_id=t.emp('p01-expired');
SELECT public.admin_resend_owner_invite(t.org('p01-resend'),repeat('4',64),now()+interval '1 day');
SELECT t.expect('39 exactly one open invite after resend',(SELECT count(*) FILTER(WHERE accepted_at IS NULL AND revoked_at IS NULL)=1 AND count(*) FILTER(WHERE revoked_at IS NOT NULL)=1 FROM public.invites WHERE employee_id=t.emp('p01-resend')));
SELECT t.expect('40 list expired',(SELECT owner_invite_status='expired' FROM public.admin_list_organizations('p01-expired',NULL,10,0) WHERE id=t.org('p01-expired')));
SELECT t.expect('41 list accepted',(SELECT owner_invite_status='accepted' FROM public.admin_list_organizations('p01-main',NULL,10,0) WHERE id=t.org('p01-main')));
SELECT t.as_user(NULL);
SET LOCAL ROLE service_role;
SELECT t.expect('42 expired lookup',public.invite_lookup(repeat('2',64))->>'status'='expired');
SELECT t.expect_error('43 expired acceptance',$q$SELECT public.accept_invite(repeat('2',64),'a0100000-0000-4000-8000-000000000001')$q$,'INVITE_EXPIRED');
SELECT t.expect('44 revoked lookup used',public.invite_lookup(repeat('3',64))->>'status'='used');
SELECT t.expect_error('45 revoked acceptance',$q$SELECT public.accept_invite(repeat('3',64),'a0100000-0000-4000-8000-000000000001')$q$,'INVITE_USED');
RESET ROLE;
SELECT t.as_user('a0100000-0000-4000-8000-000000000001',t.org('p01-main')::text);
SET LOCAL ROLE authenticated;
SELECT t.expect('46 reactivated write succeeds',(SELECT count(*)=1 FROM public.set_employee_branches('a0100000-0000-4000-8000-000000000003',ARRAY[t.branch('p01-main')],'P01 reactivated')));
RESET ROLE;
-- Acceptance is shared with O02 and must support non-owner employees.
INSERT INTO auth.users(id,email) VALUES ('a0100000-0000-4000-8000-000000000004','cashier-p01@example.com');
UPDATE public.employees SET email='cashier-p01@example.com',must_change_password=true WHERE id='a0100000-0000-4000-8000-000000000003';
INSERT INTO public.invites(organization_id,employee_id,email,token_hash,expires_at) VALUES (t.org('p01-main'),'a0100000-0000-4000-8000-000000000003','cashier-p01@example.com',repeat('5',64),now()+interval '1 day');
SELECT t.as_user(NULL);
SET LOCAL ROLE service_role;
SELECT t.expect('47 accepts non-owner invite',public.accept_invite(repeat('5',64),'a0100000-0000-4000-8000-000000000004')->>'tenant_slug'='p01-main');
RESET ROLE;
SELECT t.expect('48 non-owner linked and password flag cleared',(SELECT auth_user_id='a0100000-0000-4000-8000-000000000004' AND role='CASHIER' AND NOT must_change_password FROM public.employees WHERE id='a0100000-0000-4000-8000-000000000003'));
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) AS passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) AS failed FROM t.results;
