// P03 shop settings (D40). Refactored from FinTech-Pro's settings service: no service-role
// upsert of a config_data blob; reads and writes go through the caller's own client and the
// P03 database functions, which check the permission, validate and audit.
import {
  InstallmentPolicyList,
  ShopSettings,
  ShopProfile,
  type ShopProfileUpdateBody,
  Uuid,
  type InstallmentPolicy,
  type InstallmentPolicyBody,
  type ShopSettingsUpdateBody,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';

function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

export async function getSettings(ctx: RequestContext): Promise<ShopSettings> {
  const { data, error } = await ctx.db.rpc('get_shop_settings');
  if (error) fail(error);
  return ShopSettings.parse(data);
}

export async function getProfile(ctx: RequestContext): Promise<ShopProfile> {
  const { data, error } = await ctx.db.rpc('get_shop_profile');
  if (error) fail(error);
  return ShopProfile.parse(data);
}

export async function updateProfile(
  ctx: RequestContext,
  body: ShopProfileUpdateBody,
): Promise<ShopProfile> {
  const { error } = await ctx.db.rpc('update_org_profile', { p_changes: body as Json });
  if (error) fail(error);
  return getProfile(ctx);
}

/** Changes only the fields in the body, then returns the full settings. */
export async function updateSettings(
  ctx: RequestContext,
  body: ShopSettingsUpdateBody,
): Promise<ShopSettings> {
  const { error } = await ctx.db.rpc('update_org_settings', { p_changes: body as Json });
  if (error) fail(error);
  return getSettings(ctx);
}

export async function listPolicies(ctx: RequestContext): Promise<InstallmentPolicy[]> {
  const { data, error } = await ctx.db.rpc('list_installment_policies');
  if (error) fail(error);
  return InstallmentPolicyList.parse(data);
}

/** Publishes a new version (or returns the current one when nothing changed). */
export async function publishPolicy(
  ctx: RequestContext,
  body: InstallmentPolicyBody,
): Promise<InstallmentPolicy> {
  const { data, error } = await ctx.db.rpc('publish_installment_policy', {
    p_policy: body as Json,
  });
  if (error) fail(error);
  const id = Uuid.parse(data);
  const policy = (await listPolicies(ctx)).find((p) => p.id === id);
  if (!policy) throw ServerError('Request failed.');
  return policy;
}
