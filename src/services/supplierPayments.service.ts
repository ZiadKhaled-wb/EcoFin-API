import {
  OpenSupplierInvoiceList,
  SupplierPayment,
  SupplierPaymentList,
  type SupplierPaymentCreateBody,
  type SupplierPaymentListQuery,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'supplier payment database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_supplier_payments returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

/** U03: payments of the caller's branches (any purchasing read key, D53), newest first. */
export async function listSupplierPayments(
  ctx: RequestContext,
  query: SupplierPaymentListQuery,
): Promise<SupplierPaymentList> {
  const { data, error } = await ctx.db.rpc('list_supplier_payments', {
    ...(query.supplier_id ? { p_supplier_id: query.supplier_id } : {}),
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    p_include_reversals: query.include_reversals,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return SupplierPaymentList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getSupplierPayment(
  ctx: RequestContext,
  id: string,
): Promise<SupplierPayment> {
  const { data, error } = await ctx.db.rpc('get_supplier_payment', { p_id: id });
  if (error) fail(error);
  return SupplierPayment.parse(data);
}

/** U03: what a supplier is still owed, invoice by invoice (supplier.payment_create). */
export async function listOpenSupplierInvoices(
  ctx: RequestContext,
  supplierId: string,
): Promise<OpenSupplierInvoiceList> {
  const { data, error } = await ctx.db.rpc('list_open_supplier_invoices', {
    p_supplier_id: supplierId,
  });
  if (error) fail(error);
  return OpenSupplierInvoiceList.parse(data);
}

/**
 * U03 (D58): pays a supplier from a safe or bank, fully allocated to approved invoices (the given
 * allocations, or oldest invoice first). The same idempotency key again returns the first payment.
 */
export async function postSupplierPayment(
  ctx: RequestContext,
  body: SupplierPaymentCreateBody,
  idempotencyKey: string,
): Promise<SupplierPayment> {
  const { data, error } = await ctx.db.rpc('post_supplier_payment', {
    p_supplier_id: body.supplier_id,
    p_branch_id: body.branch_id,
    p_cash_account_id: body.cash_account_id,
    p_amount: body.amount,
    p_idempotency_key: idempotencyKey,
    ...(body.reference ? { p_reference: body.reference } : {}),
    ...(body.allocations ? { p_allocations: body.allocations as Json } : {}),
  });
  if (error) fail(error);
  return SupplierPayment.parse(data);
}

/** The owner undoes a payment: a linked reversal and the money back in the account. */
export async function reverseSupplierPayment(
  ctx: RequestContext,
  id: string,
  reason: string,
  idempotencyKey: string,
): Promise<SupplierPayment> {
  const { data, error } = await ctx.db.rpc('reverse_supplier_payment', {
    p_id: id,
    p_reason: reason,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return SupplierPayment.parse(data);
}
