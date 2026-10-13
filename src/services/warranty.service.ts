import {
  WarrantyClaim,
  WarrantyClaimOpened,
  WarrantyClaimsResponse,
  WarrantyLookupResponse,
  type WarrantyLookupQuery,
  type WarrantyClaimsQuery,
  type OpenWarrantyClaimBody,
  type MoveWarrantyClaimBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}
export async function lookup(ctx: RequestContext, q: WarrantyLookupQuery) {
  const { data, error } = await ctx.db.rpc('warranty_lookup', {
    ...(q.serial ? { p_serial: q.serial } : {}),
    ...(q.phone ? { p_phone: q.phone } : {}),
    ...(q.sale_number ? { p_sale_number: q.sale_number } : {}),
  });
  if (error) fail(error);
  return WarrantyLookupResponse.parse(data);
}
export async function list(ctx: RequestContext, q: WarrantyClaimsQuery) {
  const { data, error } = await ctx.db.rpc('list_warranty_claims', {
    ...(q.status ? { p_status: q.status } : {}),
    ...(q.branch_id ? { p_branch_id: q.branch_id } : {}),
    ...(q.out_of_warranty !== undefined ? { p_out_of_warranty: q.out_of_warranty } : {}),
    p_limit: q.page_size,
    p_offset: (q.page - 1) * q.page_size,
  });
  if (error) fail(error);
  return WarrantyClaimsResponse.parse(data);
}
export async function get(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('get_warranty_claim', { p_claim_id: id });
  if (error) fail(error);
  return WarrantyClaim.parse(data);
}
export async function open(ctx: RequestContext, b: OpenWarrantyClaimBody, key: string) {
  const { data, error } = await ctx.db.rpc('open_warranty_claim', {
    p_sale_line_id: b.sale_line_id,
    p_unit_id: b.unit_id ?? null,
    p_issue: b.issue,
    p_condition: b.condition,
    p_idempotency_key: key,
  });
  if (error) fail(error);
  return WarrantyClaimOpened.parse(data);
}
export async function move(ctx: RequestContext, id: string, b: MoveWarrantyClaimBody) {
  const { data, error } = await ctx.db.rpc('move_warranty_claim', {
    p_claim_id: id,
    p_to: b.to,
    p_note: b.note ?? null,
    p_replacement_unit_id: b.replacement_unit_id ?? null,
  });
  if (error) fail(error);
  return WarrantyClaim.parse(data);
}
export async function refund(ctx: RequestContext, id: string) {
  const { error } = await ctx.db.rpc('request_claim_refund', { p_claim_id: id });
  if (error) fail(error);
  throw ServerError('Refund placeholder unexpectedly succeeded.');
}
