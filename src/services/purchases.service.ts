import {
  PayableCashAccountList,
  PurchaseApprovalList,
  PurchaseInvoice,
  PurchaseInvoiceList,
  PurchaseOrder,
  PurchaseOrderList,
  PurchaseReturn,
  PurchaseReturnList,
  ReturnableInvoice,
  type PurchaseApprovalListQuery,
  type PurchaseInvoiceCreateBody,
  type PurchaseInvoiceListQuery,
  type PurchaseInvoiceUpdateBody,
  type PurchaseOrderCreateBody,
  type PurchaseOrderInvoiceBody,
  type PurchaseOrderListQuery,
  type PurchaseOrderUpdateBody,
  type PurchaseReturnCreateBody,
  type PurchaseReturnListQuery,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'purchase database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_purchase_invoices returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

/** Lines as the SQL functions take them (optional keys left out). */
const sqlLines = (lines: PurchaseInvoiceCreateBody['lines']) =>
  lines.map((l) => ({
    product_id: l.product_id,
    quantity: l.quantity,
    unit_cost: l.unit_cost,
    ...(l.tax_class_id ? { tax_class_id: l.tax_class_id } : {}),
    ...(l.serials ? { serials: l.serials } : {}),
    ...(l.po_line_id ? { po_line_id: l.po_line_id } : {}),
  }));

/** U02: invoices of the caller's branches (any purchasing read key, D53). */
export async function listPurchaseInvoices(
  ctx: RequestContext,
  query: PurchaseInvoiceListQuery,
): Promise<PurchaseInvoiceList> {
  const { data, error } = await ctx.db.rpc('list_purchase_invoices', {
    ...(query.supplier_id ? { p_supplier_id: query.supplier_id } : {}),
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.status ? { p_status: query.status } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    ...(query.search ? { p_search: query.search } : {}),
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return PurchaseInvoiceList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getPurchaseInvoice(
  ctx: RequestContext,
  id: string,
): Promise<PurchaseInvoice> {
  const { data, error } = await ctx.db.rpc('get_purchase_invoice', { p_id: id });
  if (error) fail(error);
  return PurchaseInvoice.parse(data);
}

/** A draft; the same idempotency key again returns the same invoice. */
export async function createPurchaseInvoice(
  ctx: RequestContext,
  body: PurchaseInvoiceCreateBody,
  idempotencyKey: string,
): Promise<PurchaseInvoice> {
  const { data, error } = await ctx.db.rpc('create_purchase_invoice', {
    p_supplier_id: body.supplier_id,
    p_branch_id: body.branch_id,
    // The SQL trims and turns '' into NULL (no supplier invoice number).
    p_supplier_invoice_no: body.supplier_invoice_no ?? '',
    p_invoice_date: body.invoice_date,
    p_lines: sqlLines(body.lines) as Json,
    p_idempotency_key: idempotencyKey,
    // U05: the purchase order this invoice receives.
    ...(body.po_id ? { p_po_id: body.po_id } : {}),
  });
  if (error) fail(error);
  return PurchaseInvoice.parse(data);
}

/** Drafts only: the supplier's invoice no, the date and/or all lines. */
export async function updatePurchaseInvoice(
  ctx: RequestContext,
  id: string,
  body: PurchaseInvoiceUpdateBody,
): Promise<PurchaseInvoice> {
  const changes = {
    ...('supplier_invoice_no' in body
      ? { supplier_invoice_no: body.supplier_invoice_no ?? null }
      : {}),
    ...(body.invoice_date ? { invoice_date: body.invoice_date } : {}),
    ...(body.lines ? { lines: sqlLines(body.lines) } : {}),
  };
  const { data, error } = await ctx.db.rpc('update_purchase_invoice', {
    p_id: id,
    p_changes: changes as Json,
  });
  if (error) fail(error);
  return PurchaseInvoice.parse(data);
}

/**
 * Stock in once, serial units, moving-average cost, supplier balance up. A repeat changes nothing.
 * U06: above the threshold a non-owner's approve answers `pending_approval` (nothing posted); the
 * owner decides a pending invoice with a note.
 */
export async function approvePurchaseInvoice(
  ctx: RequestContext,
  id: string,
  note?: string,
): Promise<PurchaseInvoice> {
  const { data, error } = await ctx.db.rpc('approve_purchase_invoice', {
    p_id: id,
    ...(note ? { p_note: note } : {}),
  });
  if (error) fail(error);
  return PurchaseInvoice.parse(data);
}

export async function rejectPurchaseInvoice(
  ctx: RequestContext,
  id: string,
  reason: string,
): Promise<PurchaseInvoice> {
  const { data, error } = await ctx.db.rpc('reject_purchase_invoice', {
    p_id: id,
    p_reason: reason,
  });
  if (error) fail(error);
  return PurchaseInvoice.parse(data);
}

/** U06: approvals of the caller's branches (purchase.invoice_approve), newest first. */
export async function listPurchaseApprovals(
  ctx: RequestContext,
  query: PurchaseApprovalListQuery,
): Promise<PurchaseApprovalList> {
  const { data, error } = await ctx.db.rpc('list_purchase_approvals', {
    p_status: query.status,
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return PurchaseApprovalList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

/** U04: returns of the caller's branches (any purchasing read key, D53), newest first. */
export async function listPurchaseReturns(
  ctx: RequestContext,
  query: PurchaseReturnListQuery,
): Promise<PurchaseReturnList> {
  const { data, error } = await ctx.db.rpc('list_purchase_returns', {
    ...(query.supplier_id ? { p_supplier_id: query.supplier_id } : {}),
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.purchase_invoice_id ? { p_purchase_invoice_id: query.purchase_invoice_id } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return PurchaseReturnList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getPurchaseReturn(ctx: RequestContext, id: string): Promise<PurchaseReturn> {
  const { data, error } = await ctx.db.rpc('get_purchase_return', { p_id: id });
  if (error) fail(error);
  return PurchaseReturn.parse(data);
}

/**
 * U04 (D57): goods back to the supplier against an approved invoice. Stock out once at the
 * invoice's cost, the moving average recomputed, supplier credit or a cash refund into a safe or
 * bank. The same idempotency key again returns the first return.
 */
export async function postPurchaseReturn(
  ctx: RequestContext,
  body: PurchaseReturnCreateBody,
  idempotencyKey: string,
): Promise<PurchaseReturn> {
  const { data, error } = await ctx.db.rpc('post_purchase_return', {
    p_invoice_id: body.purchase_invoice_id,
    p_refund_mode: body.refund_mode,
    p_reason: body.reason,
    p_lines: body.lines.map((l) => ({
      invoice_line_id: l.invoice_line_id,
      ...(l.unit_ids ? { unit_ids: l.unit_ids } : { quantity: l.quantity }),
    })) as Json,
    p_idempotency_key: idempotencyKey,
    ...(body.cash_account_id ? { p_cash_account_id: body.cash_account_id } : {}),
  });
  if (error) fail(error);
  return PurchaseReturn.parse(data);
}

/** U04: what can still go back from an invoice (purchase.return_create). */
export async function getReturnableInvoice(
  ctx: RequestContext,
  invoiceId: string,
): Promise<ReturnableInvoice> {
  const { data, error } = await ctx.db.rpc('get_returnable_invoice', { p_invoice_id: invoiceId });
  if (error) fail(error);
  return ReturnableInvoice.parse(data);
}

/** U04 decision 8 (also U03): the active safes and banks usable for a branch, with balances. */
export async function listPayableCashAccounts(
  ctx: RequestContext,
  branchId: string,
): Promise<PayableCashAccountList> {
  const { data, error } = await ctx.db.rpc('list_payable_cash_accounts', {
    p_branch_id: branchId,
  });
  if (error) fail(error);
  return PayableCashAccountList.parse(data);
}

/** Order lines as the SQL functions take them (optional keys left out). */
const sqlOrderLines = (lines: PurchaseOrderCreateBody['lines']) =>
  lines.map((l) => ({
    product_id: l.product_id,
    quantity: l.quantity,
    ...(l.expected_unit_cost ? { expected_unit_cost: l.expected_unit_cost } : {}),
    ...(l.sales_order_line_id ? { sales_order_line_id: l.sales_order_line_id } : {}),
  }));

/** U05: orders of the caller's branches (any purchasing read key, D53), newest first. */
export async function listPurchaseOrders(
  ctx: RequestContext,
  query: PurchaseOrderListQuery,
): Promise<PurchaseOrderList> {
  const { data, error } = await ctx.db.rpc('list_purchase_orders', {
    ...(query.supplier_id ? { p_supplier_id: query.supplier_id } : {}),
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.status ? { p_status: query.status } : {}),
    ...(query.search ? { p_search: query.search } : {}),
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return PurchaseOrderList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getPurchaseOrder(ctx: RequestContext, id: string): Promise<PurchaseOrder> {
  const { data, error } = await ctx.db.rpc('get_purchase_order', { p_id: id });
  if (error) fail(error);
  return PurchaseOrder.parse(data);
}

/** A draft order; the same idempotency key again returns the same order. */
export async function createPurchaseOrder(
  ctx: RequestContext,
  body: PurchaseOrderCreateBody,
  idempotencyKey: string,
): Promise<PurchaseOrder> {
  const { data, error } = await ctx.db.rpc('create_purchase_order', {
    p_supplier_id: body.supplier_id,
    p_branch_id: body.branch_id,
    p_lines: sqlOrderLines(body.lines) as Json,
    p_idempotency_key: idempotencyKey,
    ...(body.expected_date ? { p_expected_date: body.expected_date } : {}),
    ...(body.notes ? { p_notes: body.notes } : {}),
  });
  if (error) fail(error);
  return PurchaseOrder.parse(data);
}

/** Drafts only: the expected date, the notes and/or all lines. */
export async function updatePurchaseOrder(
  ctx: RequestContext,
  id: string,
  body: PurchaseOrderUpdateBody,
): Promise<PurchaseOrder> {
  const changes = {
    ...('expected_date' in body ? { expected_date: body.expected_date ?? null } : {}),
    ...('notes' in body ? { notes: body.notes ?? null } : {}),
    ...(body.lines ? { lines: sqlOrderLines(body.lines) } : {}),
  };
  const { data, error } = await ctx.db.rpc('update_purchase_order', {
    p_id: id,
    p_changes: changes as Json,
  });
  if (error) fail(error);
  return PurchaseOrder.parse(data);
}

/** draft → sent; a repeat changes nothing. */
export async function sendPurchaseOrder(ctx: RequestContext, id: string): Promise<PurchaseOrder> {
  const { data, error } = await ctx.db.rpc('send_purchase_order', { p_id: id });
  if (error) fail(error);
  return PurchaseOrder.parse(data);
}

/** Closes what is left of a draft, sent or partly received order. */
export async function cancelPurchaseOrder(
  ctx: RequestContext,
  id: string,
  reason: string,
): Promise<PurchaseOrder> {
  const { data, error } = await ctx.db.rpc('cancel_purchase_order', {
    p_id: id,
    p_reason: reason,
  });
  if (error) fail(error);
  return PurchaseOrder.parse(data);
}

/**
 * U05 "Receive": a draft purchase invoice from a sent or partly received order (never more than
 * is still to come). The same idempotency key again returns the same invoice.
 */
export async function createInvoiceFromPurchaseOrder(
  ctx: RequestContext,
  id: string,
  body: PurchaseOrderInvoiceBody,
  idempotencyKey: string,
): Promise<PurchaseInvoice> {
  const { data, error } = await ctx.db.rpc('create_invoice_from_po', {
    p_po_id: id,
    p_idempotency_key: idempotencyKey,
    ...(body.lines
      ? {
          p_lines: body.lines.map((l) => ({
            po_line_id: l.po_line_id,
            quantity: l.quantity,
            ...(l.unit_cost ? { unit_cost: l.unit_cost } : {}),
          })) as Json,
        }
      : {}),
  });
  if (error) fail(error);
  return PurchaseInvoice.parse(data);
}
