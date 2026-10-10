import {
  Customer,
  CustomerList,
  type CustomerCreateBody,
  type CustomerListQuery,
  type CustomerStatusBody,
  type CustomerUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// R01 (D63). The database decides what the caller may see: `national_id` comes back only with
// customer.view_pii, otherwise null next to `national_id_masked`. Nothing here adds or removes PII.

function fail(error: unknown): never {
  // The message and the Postgres code only. Not the whole error: the DETAIL of a duplicate
  // national ID names the customer who has it, and a request body is never logged either.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'customer database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_customers returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

export async function listCustomers(
  ctx: RequestContext,
  query: CustomerListQuery,
): Promise<CustomerList> {
  const { data, error } = await ctx.db.rpc('list_customers', {
    ...(query.search ? { p_search: query.search } : {}),
    p_status: query.status,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return CustomerList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getCustomer(ctx: RequestContext, id: string): Promise<Customer> {
  const { data, error } = await ctx.db.rpc('get_customer', { p_id: id });
  if (error) fail(error);
  return Customer.parse(data);
}

/** A national ID another customer of the shop has is CUSTOMER_NATIONAL_ID_TAKEN (with details). */
export async function createCustomer(
  ctx: RequestContext,
  body: CustomerCreateBody,
): Promise<Customer> {
  const { data, error } = await ctx.db.rpc('create_customer', { p: body as Json });
  if (error) fail(error);
  return Customer.parse(data);
}

/** `national_id` for a customer who already has one also needs customer.view_pii (checked in SQL). */
export async function updateCustomer(
  ctx: RequestContext,
  id: string,
  body: CustomerUpdateBody,
): Promise<Customer> {
  const { data, error } = await ctx.db.rpc('update_customer', {
    p_id: id,
    p_changes: body as Json,
  });
  if (error) fail(error);
  return Customer.parse(data);
}

/** Block (with a reason) or unblock; the reason is kept in the audit row. */
export async function setCustomerStatus(
  ctx: RequestContext,
  id: string,
  body: CustomerStatusBody,
): Promise<Customer> {
  const { data, error } = await ctx.db.rpc('set_customer_status', {
    p_id: id,
    p_status: body.status,
    ...(body.reason ? { p_reason: body.reason } : {}),
  });
  if (error) fail(error);
  return Customer.parse(data);
}
