import {
  BranchList,
  ManagedBranchList,
  BranchDetail,
  BranchDeactivationCheck,
  Uuid,
  type BranchCreateBody,
  type BranchUpdateBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { AppError, mapDbError, ServerError } from '../utils/errors';
function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}
export async function listBranches(ctx: RequestContext) {
  let query = ctx.db
    .from('branches')
    .select('id,code,name,is_main')
    .eq('organization_id', ctx.orgId)
    .eq('is_active', true)
    .is('archived_at', null);
  if (ctx.role !== 'OWNER') query = query.in('id', ctx.branchIds);
  const { data, error } = await query
    .order('is_main', { ascending: false })
    .order('name')
    .order('id');
  if (error) fail(error);
  return BranchList.parse(data);
}
export async function manageBranches(ctx: RequestContext) {
  const { data, error } = await ctx.db
    .from('branches')
    .select('*')
    .eq('organization_id', ctx.orgId)
    .is('archived_at', null)
    .order('is_main', { ascending: false })
    .order('name')
    .order('id');
  if (error) fail(error);
  const { data: vaults, error: vaultError } = await ctx.db
    .from('cash_accounts')
    .select('id,name')
    .eq('organization_id', ctx.orgId)
    .eq('kind', 'safe')
    .eq('is_active', true);
  if (vaultError) fail(vaultError);
  return ManagedBranchList.parse(
    (data ?? []).map((b) => ({
      ...b,
      default_vault: (vaults ?? []).find((v) => v.id === b.default_cash_account_id) ?? null,
    })),
  );
}
export async function branchDetail(ctx: RequestContext, id: string) {
  const rows = await manageBranches(ctx);
  const branch = rows.find((b) => b.id === id);
  if (!branch) throw new AppError('Branch not found.', 'BRANCH_NOT_FOUND');
  const { data, error } = await ctx.db
    .from('cash_accounts')
    .select('id,name')
    .eq('organization_id', ctx.orgId)
    .eq('branch_id', id)
    .eq('kind', 'safe')
    .eq('is_active', true)
    .order('name');
  if (error) fail(error);
  return BranchDetail.parse({ ...branch, vault_options: data });
}
const addressArgs = (body: BranchCreateBody | BranchUpdateBody) => ({
  p_name: body.name,
  p_address: body.address ?? null,
  p_city: body.city ?? null,
  p_governorate: body.governorate ?? null,
  p_phone: body.phone ?? null,
  p_eta_branch_code: body.eta_branch_code ?? null,
});
export async function createBranch(ctx: RequestContext, body: BranchCreateBody) {
  const { data, error } = await ctx.db.rpc('create_branch', {
    ...addressArgs(body),
    p_code: body.code,
  });
  if (error) fail(error);
  return { id: Uuid.parse(data) };
}
export async function updateBranch(ctx: RequestContext, id: string, body: BranchUpdateBody) {
  const existing = await branchDetail(ctx, id);
  const { error } = await ctx.db.rpc('update_branch', {
    ...addressArgs(body),
    p_branch_id: id,
    p_default_cash_account_id:
      body.default_cash_account_id === undefined
        ? existing.default_cash_account_id
        : body.default_cash_account_id,
  });
  if (error) fail(error);
  return branchDetail(ctx, id);
}
export async function deactivationCheck(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('branch_deactivation_check', { p_branch_id: id });
  if (error) fail(error);
  return BranchDeactivationCheck.parse(data);
}
export async function setBranchActive(
  ctx: RequestContext,
  id: string,
  active: boolean,
  reason: string | null = null,
  confirm = false,
) {
  const { error } = await ctx.db.rpc('set_branch_active', {
    p_branch_id: id,
    p_active: active,
    p_reason: reason,
    p_confirm: confirm,
  });
  if (error) fail(error);
  return { id, is_active: active };
}
