import {
  PurchaseInvoice,
  PurchaseInvoiceList,
  type PurchaseInvoiceCreateBody,
  type PurchaseInvoiceListQuery,
  type PurchaseInvoiceUpdateBody,
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

/** Stock in once, serial units, moving-average cost, supplier balance up. A repeat changes nothing. */
export async function approvePurchaseInvoice(
  ctx: RequestContext,
  id: string,
): Promise<PurchaseInvoice> {
  const { data, error } = await ctx.db.rpc('approve_purchase_invoice', { p_id: id });
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
