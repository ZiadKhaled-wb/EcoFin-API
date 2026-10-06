import {
  EmployeeInviteResult,
  EmployeeResetResult,
  EmployeeRow,
  EmployeeUpdateResponse,
  EmployeesResponse,
  type EmployeeCreateBody,
  type EmployeeUpdateBody,
  type EmployeeActiveBody,
  type EmployeesQuery,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { AppError, mapDbError, ServerError } from '../utils/errors';
import { createInviteToken } from '../utils/inviteToken';
import { sendInviteEmail, sendPasswordResetEmail } from '../lib/mailer';
function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}
async function shopName(ctx: RequestContext) {
  const { data, error } = await ctx.db
    .from('organizations')
    .select('name')
    .eq('id', ctx.orgId)
    .single();
  if (error) fail(error);
  return data.name;
}
async function employee(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db
    .from('employees')
    .select(
      'id,full_name,phone,email,username,role,default_branch_id,is_active,created_at,auth_user_id',
    )
    .eq('id', id)
    .eq('organization_id', ctx.orgId)
    .is('archived_at', null)
    .maybeSingle();
  if (error) fail(error);
  if (!data) throw new AppError('Employee not found.', 'EMPLOYEE_NOT_FOUND');
  return data;
}
export async function listEmployees(ctx: RequestContext, q: EmployeesQuery) {
  const { data, error } = await ctx.db.rpc('list_employees', {
    p_search: q.search ?? null,
    p_role: q.role ?? null,
    p_status: q.status ?? null,
    p_limit: q.page_size,
    p_offset: (q.page - 1) * q.page_size,
  });
  if (error) fail(error);
  let total = data?.[0]?.total_count ?? 0;
  if (!data?.length && q.page > 1) {
    const first = await ctx.db.rpc('list_employees', {
      p_search: q.search ?? null,
      p_role: q.role ?? null,
      p_status: q.status ?? null,
      p_limit: 1,
      p_offset: 0,
    });
    if (first.error) fail(first.error);
    total = first.data?.[0]?.total_count ?? 0;
  }
  return EmployeesResponse.parse({ items: data ?? [], total });
}
async function deliverInvite(
  ctx: RequestContext,
  result: ReturnType<typeof EmployeeInviteResult.parse>,
  token: ReturnType<typeof createInviteToken>,
  fullName: string,
) {
  if (result.delivery === 'link') return { delivery: result.delivery, invite_link: token.link };
  let email_sent = false;
  try {
    email_sent = await sendInviteEmail({
      email: result.invite_email,
      fullName,
      shopName: await shopName(ctx),
      link: token.link,
      expiresAt: token.expiresAt,
    });
  } catch {
    /* Token and provider errors must not reach logs. Owner can resend. */
  }
  return { delivery: result.delivery, email_sent };
}
export async function createEmployee(ctx: RequestContext, body: EmployeeCreateBody) {
  const token = createInviteToken();
  const { data, error } = await ctx.db.rpc('create_employee', {
    p_full_name: body.full_name,
    p_phone: body.phone ?? null,
    p_email: body.email ?? null,
    p_username: body.username ?? null,
    p_role: body.role,
    p_branch_ids: body.branch_ids,
    p_default_branch_id: body.default_branch_id ?? null,
    p_overrides: body.overrides,
    p_token_hash: token.hash,
    p_expires_at: token.expiresAt,
  });
  if (error) fail(error);
  const result = EmployeeInviteResult.parse(data);
  return {
    employee_id: result.employee_id,
    ...(await deliverInvite(ctx, result, token, body.full_name)),
  };
}
export async function updateEmployee(ctx: RequestContext, id: string, body: EmployeeUpdateBody) {
  const old = await employee(ctx, id);
  const merged = { ...old, ...body };
  const { data, error } = await ctx.db.rpc('update_employee', {
    p_employee_id: id,
    p_full_name: body.full_name ?? old.full_name,
    p_phone: merged.phone ?? null,
    p_email: merged.email ?? null,
    p_username: merged.username ?? null,
    p_role: body.role ?? old.role,
    p_default_branch_id: merged.default_branch_id ?? null,
  });
  if (error) fail(error);
  const current = await employee(ctx, id);
  const branches = await ctx.db
    .from('employee_branches')
    .select('branch_id')
    .eq('organization_id', ctx.orgId)
    .eq('employee_id', id);
  if (branches.error) fail(branches.error);
  const overrides = await ctx.db
    .from('employee_permission_overrides')
    .select('permission_key')
    .eq('organization_id', ctx.orgId)
    .eq('employee_id', id);
  if (overrides.error) fail(overrides.error);
  const invites = await ctx.db
    .from('invites')
    .select('expires_at')
    .eq('organization_id', ctx.orgId)
    .eq('employee_id', id)
    .is('accepted_at', null)
    .is('revoked_at', null)
    .maybeSingle();
  if (invites.error) fail(invites.error);
  const row = EmployeeRow.parse({
    ...current,
    branch_ids: (branches.data ?? []).map((b) => b.branch_id),
    override_count: overrides.data?.length ?? 0,
    invite_status: current.auth_user_id
      ? 'accepted'
      : !invites.data
        ? 'none'
        : Date.parse(invites.data.expires_at) <= Date.now()
          ? 'expired'
          : 'pending',
  });
  return EmployeeUpdateResponse.parse({
    ...row,
    ...(typeof data === 'object' && data !== null ? data : {}),
  });
}
export async function setEmployeeActive(ctx: RequestContext, id: string, body: EmployeeActiveBody) {
  const { error } = await ctx.db.rpc('set_employee_active', {
    p_employee_id: id,
    p_active: body.active,
    p_reason: body.reason ?? null,
  });
  if (error) fail(error);
  return { id, is_active: body.active };
}
export async function resendEmployeeInvite(ctx: RequestContext, id: string) {
  const e = await employee(ctx, id);
  const token = createInviteToken();
  const { data, error } = await ctx.db.rpc('resend_employee_invite', {
    p_employee_id: id,
    p_token_hash: token.hash,
    p_expires_at: token.expiresAt,
  });
  if (error) fail(error);
  return {
    ...(await deliverInvite(ctx, EmployeeInviteResult.parse(data), token, e.full_name)),
    invite_expires_at: token.expiresAt,
  };
}
export async function resetEmployeePassword(ctx: RequestContext, id: string) {
  const token = createInviteToken();
  const expiresAt = new Date(Date.now() + 24 * 3600_000).toISOString();
  const link = token.link.replace('/invite/accept#', '/password/set#');
  const { data, error } = await ctx.db.rpc('create_password_reset', {
    p_employee_id: id,
    p_token_hash: token.hash,
    p_expires_at: expiresAt,
  });
  if (error) fail(error);
  const result = EmployeeResetResult.parse(data);
  if (result.delivery === 'link')
    return { delivery: result.delivery, reset_link: link, expires_at: expiresAt };
  let email_sent = false;
  try {
    const e = await employee(ctx, id);
    email_sent = await sendPasswordResetEmail({
      email: result.email,
      fullName: e.full_name,
      shopName: await shopName(ctx),
      link,
      expiresAt,
    });
  } catch {
    /* Never log a provider exception containing a link. */
  }
  return { delivery: result.delivery, email_sent, expires_at: expiresAt };
}
