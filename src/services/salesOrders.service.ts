import {
  SalesOrder,
  SalesOrderList,
  type CancelSalesOrderBody,
  type CreateSalesOrderBody,
  type OrderDepositBody,
  type OrderFromQuotationBody,
  type SalesOrderListQuery,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { AppError, mapDbError, safeMessage, ServerError } from '../utils/errors';
type RpcName =
  | 'list_sales_orders'
  | 'get_sales_order'
  | 'create_sales_order'
  | 'create_order_from_quotation'
  | 'record_order_deposit'
  | 'reserve_order_line'
  | 'link_order_line_to_po'
  | 'cancel_sales_order';
async function rpc(ctx: RequestContext, name: RpcName, args: Record<string, unknown>) {
  const { data, error } = await ctx.db.rpc(name, args);
  if (error) {
    // The database names a missing purchase order line PO_NOT_FOUND; the contract code is
    // PURCHASE_ORDER_NOT_FOUND.
    if (/^PO_NOT_FOUND(?![A-Za-z0-9_])/.test(String(error.message)))
      throw new AppError(safeMessage('PURCHASE_ORDER_NOT_FOUND'), 'PURCHASE_ORDER_NOT_FOUND');
    throw mapDbError(error) ?? ServerError('Request failed.');
  }
  return data;
}
const order = async (ctx: RequestContext, name: RpcName, args: Record<string, unknown>) =>
  SalesOrder.parse(await rpc(ctx, name, args));
export async function list(ctx: RequestContext, q: SalesOrderListQuery) {
  return SalesOrderList.parse(
    await rpc(ctx, 'list_sales_orders', {
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
  return order(ctx, 'get_sales_order', { p_id: id });
}
export async function create(ctx: RequestContext, b: CreateSalesOrderBody, key: string) {
  return order(ctx, 'create_sales_order', {
    p_branch_id: b.branch_id,
    p_customer_id: b.customer_id,
    p_delivery_address: b.delivery_address,
    p_notes: b.notes,
    p_lines: b.lines,
    p_idempotency_key: key,
  });
}
export async function fromQuotation(
  ctx: RequestContext,
  quotationId: string,
  b: OrderFromQuotationBody,
  key: string,
) {
  return order(ctx, 'create_order_from_quotation', {
    p_quotation_id: quotationId,
    p_delivery_address: b.delivery_address,
    p_line_options: b.line_options,
    p_idempotency_key: key,
  });
}
export async function deposit(ctx: RequestContext, id: string, b: OrderDepositBody, key: string) {
  return order(ctx, 'record_order_deposit', {
    p_order_id: id,
    p_payments: b.payments,
    p_idempotency_key: key,
  });
}
export async function cancel(
  ctx: RequestContext,
  id: string,
  b: CancelSalesOrderBody,
  key: string,
) {
  return order(ctx, 'cancel_sales_order', {
    p_order_id: id,
    p_reason: b.reason,
    p_refund: b.refund,
    p_idempotency_key: key,
  });
}
/** The line RPCs take only the line id: the line must belong to the order in the path. */
async function requireLine(ctx: RequestContext, id: string, lineId: string) {
  const current = await get(ctx, id);
  if (!current.lines.some((l) => l.id === lineId))
    throw new AppError(safeMessage('ORDER_NOT_FOUND'), 'ORDER_NOT_FOUND');
}
export async function reserve(
  ctx: RequestContext,
  id: string,
  lineId: string,
  unitIds: string[] | undefined,
) {
  await requireLine(ctx, id, lineId);
  return order(ctx, 'reserve_order_line', {
    p_order_line_id: lineId,
    p_unit_ids: unitIds ?? null,
  });
}
export async function linkPo(ctx: RequestContext, id: string, lineId: string, poLineId: string) {
  await requireLine(ctx, id, lineId);
  return order(ctx, 'link_order_line_to_po', {
    p_order_line_id: lineId,
    p_po_line_id: poLineId,
  });
}
