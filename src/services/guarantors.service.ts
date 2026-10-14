import {
  CustomerGuarantorList,
  Guarantor,
  GuarantorDetails,
  GuarantorList,
  GuarantorRequirement,
  type CustomerGuarantorLinkBody,
  type CustomerGuarantorRelationBody,
  type GuarantorCreateBody,
  type GuarantorListQuery,
  type GuarantorRequirementQuery,
  type GuarantorUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// R04 (D71). The database decides what the caller may see and do: `national_id` comes back only
// with customer.view_pii (otherwise null next to `national_id_masked`), and every rule (limits,
// archived or blocked, active contracts, who may) is enforced in SQL. Nothing here adds PII.

function fail(error: unknown): never {
  // The message and the Postgres code only. Not the whole error: the DETAIL of a duplicate
  // national ID names the guarantor who has it, and a request body is never logged either.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'guarantor database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_guarantors returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

export async function listGuarantors(
  ctx: RequestContext,
  query: GuarantorListQuery,
): Promise<GuarantorList> {
  const { data, error } = await ctx.db.rpc('list_guarantors', {
    ...(query.search ? { p_search: query.search } : {}),
    p_status: query.status,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return GuarantorList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getGuarantor(ctx: RequestContext, id: string): Promise<GuarantorDetails> {
  const { data, error } = await ctx.db.rpc('get_guarantor', { p_id: id });
  if (error) fail(error);
  return GuarantorDetails.parse(data);
}

/** With `link` the guarantor is created and linked in one transaction. */
export async function createGuarantor(
  ctx: RequestContext,
  body: GuarantorCreateBody,
): Promise<Guarantor> {
  const { data, error } = await ctx.db.rpc('create_guarantor', { p_body: body as Json });
  if (error) fail(error);
  return Guarantor.parse(data);
}

/** `national_id` also needs customer.view_pii (checked in SQL). */
export async function updateGuarantor(
  ctx: RequestContext,
  id: string,
  body: GuarantorUpdateBody,
): Promise<Guarantor> {
  const { data, error } = await ctx.db.rpc('update_guarantor', {
    p_id: id,
    p_body: body as Json,
  });
  if (error) fail(error);
  return Guarantor.parse(data);
}

/** Refused while the guarantor is on an active contract. The same state again changes nothing. */
export async function setGuarantorArchived(
  ctx: RequestContext,
  id: string,
  archived: boolean,
): Promise<Guarantor> {
  const { data, error } = await ctx.db.rpc('set_guarantor_archived', {
    p_id: id,
    p_archived: archived,
  });
  if (error) fail(error);
  return Guarantor.parse(data);
}

export async function listCustomerGuarantors(
  ctx: RequestContext,
  customerId: string,
): Promise<CustomerGuarantorList> {
  const { data, error } = await ctx.db.rpc('list_customer_guarantors', {
    p_customer_id: customerId,
  });
  if (error) fail(error);
  return CustomerGuarantorList.parse(data);
}

export async function linkCustomerGuarantor(
  ctx: RequestContext,
  customerId: string,
  body: CustomerGuarantorLinkBody,
): Promise<CustomerGuarantorList> {
  const { data, error } = await ctx.db.rpc('link_customer_guarantor', {
    p_customer_id: customerId,
    p_guarantor_id: body.guarantor_id,
    p_relation: body.relation,
  });
  if (error) fail(error);
  return CustomerGuarantorList.parse(data);
}

export async function setCustomerGuarantorRelation(
  ctx: RequestContext,
  customerId: string,
  guarantorId: string,
  body: CustomerGuarantorRelationBody,
): Promise<CustomerGuarantorList> {
  const { data, error } = await ctx.db.rpc('set_customer_guarantor_relation', {
    p_customer_id: customerId,
    p_guarantor_id: guarantorId,
    p_relation: body.relation,
  });
  if (error) fail(error);
  return CustomerGuarantorList.parse(data);
}

export async function unlinkCustomerGuarantor(
  ctx: RequestContext,
  customerId: string,
  guarantorId: string,
): Promise<CustomerGuarantorList> {
  const { data, error } = await ctx.db.rpc('unlink_customer_guarantor', {
    p_customer_id: customerId,
    p_guarantor_id: guarantorId,
  });
  if (error) fail(error);
  return CustomerGuarantorList.parse(data);
}

/** Against the shop's current policy version; `financed_amount` = cash price - down payment. */
export async function getGuarantorRequirement(
  ctx: RequestContext,
  customerId: string,
  query: GuarantorRequirementQuery,
): Promise<GuarantorRequirement> {
  const { data, error } = await ctx.db.rpc('get_guarantor_requirement', {
    p_customer_id: customerId,
    p_financed_amount: query.financed_amount,
  });
  if (error) fail(error);
  return GuarantorRequirement.parse(data);
}
