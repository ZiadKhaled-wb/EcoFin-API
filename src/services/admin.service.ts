import {
  AdminShop,
  ProvisionOrganizationResult,
  ResendOwnerInviteResult,
  type AdminPlansResponse,
  type AdminShopsQuery,
  type AdminShopsResponse,
  type AdminCreateShopBody,
  type AdminCreateShopResponse,
  type AdminShopStatusBody,
  type AdminShopStatusResponse,
  type AdminInviteResponse,
} from '@ziadkhaled-wb/contracts';
import type { DbClient } from '../utils/supabase';
import { mapDbError, ServerError } from '../utils/errors';
import { createInviteToken } from '../utils/inviteToken';
import { sendInviteEmail } from '../lib/mailer';
import { logger } from '../utils/logger';

export function adminError(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

async function deliver(message: Parameters<typeof sendInviteEmail>[0]): Promise<boolean> {
  try {
    return await sendInviteEmail(message);
  } catch {
    logger.warn('invite email failed');
    return false;
  }
}
export async function listPlans(db: DbClient): Promise<AdminPlansResponse> {
  const { data, error } = await db
    .from('plans')
    .select('key,name,price_monthly')
    .eq('is_active', true)
    .order('display_order');
  if (error) adminError(error);
  return (data ?? []).map((p) => ({
    key: p.key,
    name: p.name,
    price_monthly: String(p.price_monthly),
  }));
}
export async function listShops(db: DbClient, query: AdminShopsQuery): Promise<AdminShopsResponse> {
  const args = {
    ...(query.search ? { p_search: query.search } : {}),
    ...(query.status ? { p_status: query.status } : {}),
    p_limit: query.page_size,
    p_offset: (query.page - 1) * query.page_size,
  };
  const { data, error } = await db.rpc('admin_list_organizations', args);
  if (error) adminError(error);
  let total = data?.[0]?.total_count ?? 0;
  if (!data?.length && args.p_offset > 0) {
    const first = await db.rpc('admin_list_organizations', { ...args, p_limit: 1, p_offset: 0 });
    if (first.error) adminError(first.error);
    total = first.data?.[0]?.total_count ?? 0;
  }
  return { items: (data ?? []).map((row) => AdminShop.parse(row)), total };
}
export async function provisionShop(
  db: DbClient,
  body: AdminCreateShopBody,
): Promise<AdminCreateShopResponse> {
  const invite = createInviteToken();
  const { data, error } = await db.rpc('admin_provision_organization', {
    p_name: body.name,
    p_tenant_slug: body.tenant_slug,
    p_plan_key: body.plan_key,
    p_owner_full_name: body.owner.full_name,
    p_owner_email: body.owner.email,
    ...(body.owner.phone ? { p_owner_phone: body.owner.phone } : {}),
    ...(body.branch_name ? { p_branch_name: body.branch_name } : {}),
    p_token_hash: invite.hash,
    p_expires_at: invite.expiresAt,
  });
  if (error) adminError(error);
  const result = ProvisionOrganizationResult.parse(data);
  const sent = await deliver({
    email: body.owner.email,
    fullName: body.owner.full_name,
    shopName: body.name,
    link: invite.link,
    expiresAt: invite.expiresAt,
  });
  return {
    organization_id: result.organization_id,
    tenant_slug: body.tenant_slug,
    owner_employee_id: result.owner_employee_id,
    invite_expires_at: invite.expiresAt,
    invite_email_sent: sent,
  };
}
export async function setShopStatus(
  db: DbClient,
  id: string,
  body: AdminShopStatusBody,
): Promise<AdminShopStatusResponse> {
  const { error } = await db.rpc('admin_set_organization_status', {
    p_organization_id: id,
    p_status: body.status,
    ...(body.reason ? { p_reason: body.reason } : {}),
  });
  if (error) adminError(error);
  return { id, status: body.status };
}
export async function resendOwnerInvite(db: DbClient, id: string): Promise<AdminInviteResponse> {
  const invite = createInviteToken();
  const { data, error } = await db.rpc('admin_resend_owner_invite', {
    p_organization_id: id,
    p_token_hash: invite.hash,
    p_expires_at: invite.expiresAt,
  });
  if (error) adminError(error);
  const result = ResendOwnerInviteResult.parse(data);
  const sent = await deliver({
    email: result.email,
    fullName: result.owner_full_name,
    shopName: result.shop_name,
    link: invite.link,
    expiresAt: result.expires_at,
  });
  return { invite_expires_at: result.expires_at, invite_email_sent: sent };
}
