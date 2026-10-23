import {
  Quotation,
  QuotationCreated,
  QuotationList,
  type CreateQuotationBody,
  type UpdateQuotationBody,
  type QuotationListQuery,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError, AppError } from '../utils/errors';
type RpcName =
  | 'list_quotations'
  | 'get_quotation'
  | 'create_quotation'
  | 'update_quotation_draft'
  | 'send_quotation'
  | 'accept_quotation'
  | 'reject_quotation'
  | 'cancel_quotation';
async function rpc(ctx: RequestContext, name: RpcName, args: Record<string, unknown>) {
  const { data, error } = await ctx.db.rpc(name, args);
  if (error) {
    const mapped = mapDbError(error);
    if (mapped?.code === 'REASON_REQUIRED') throw new AppError(mapped.message, mapped.code, 422);
    throw mapped ?? ServerError('Request failed.');
  }
  return data;
}
export async function list(ctx: RequestContext, q: QuotationListQuery) {
  return QuotationList.parse(
    await rpc(ctx, 'list_quotations', {
      p_status: q.status,
      p_branch_id: q.branch_id,
      p_customer_id: q.customer_id,
      p_from: q.from,
      p_to: q.to,
      p_search: q.search,
      p_limit: q.page_size,
      p_offset: (q.page - 1) * q.page_size,
    }),
  );
}
export async function get(ctx: RequestContext, id: string) {
  return Quotation.parse(await rpc(ctx, 'get_quotation', { p_id: id }));
}
const draftArgs = (b: UpdateQuotationBody | CreateQuotationBody) => ({
  p_customer_id: b.customer_id,
  p_valid_until: b.valid_until,
  p_notes: b.notes,
  p_lines: b.lines,
});
export async function create(ctx: RequestContext, b: CreateQuotationBody, key: string) {
  return QuotationCreated.parse(
    await rpc(ctx, 'create_quotation', {
      ...draftArgs(b),
      p_branch_id: b.branch_id,
      p_idempotency_key: key,
    }),
  );
}
export async function update(ctx: RequestContext, id: string, b: UpdateQuotationBody) {
  return Quotation.parse(
    await rpc(ctx, 'update_quotation_draft', {
      ...draftArgs(b),
      p_id: id,
      p_expected_updated_at: b.expected_updated_at,
    }),
  );
}
export async function move(
  ctx: RequestContext,
  id: string,
  action: 'send' | 'accept' | 'reject' | 'cancel',
  reason?: string,
) {
  return Quotation.parse(
    await rpc(ctx, `${action}_quotation`, {
      p_id: id,
      ...(reason === undefined ? {} : { p_reason: reason }),
    }),
  );
}
