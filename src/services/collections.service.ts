import {
  Collection,
  CollectionPreview,
  ContractListPage,
  type CollectionBody,
  type CollectionReverseBody,
  type ContractListQuery,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// N03 (D78). Collections: everything is checked and written in SQL (public.post_collection and
// friends, one transaction each); the API only shapes the calls. No late fees (Islamic finance
// rule 4), no overpayment, no store credit.

function fail(error: unknown): never {
  // The message and the Postgres code only: a request body (amounts, customer) is never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'collection database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/contracts: the shop's contracts; the collection keys see every branch. */
export async function listContracts(
  ctx: RequestContext,
  query: ContractListQuery,
): Promise<ContractListPage> {
  const { data, error } = await ctx.db.rpc('list_contracts', { p_filters: query as Json });
  if (error) fail(error);
  return ContractListPage.parse(data);
}

/** GET /api/contracts/:id/collection: what is due and, with an amount, what it would pay. */
export async function previewCollection(
  ctx: RequestContext,
  contractId: string,
  amount: string | undefined,
): Promise<CollectionPreview> {
  const { data, error } = await ctx.db.rpc('preview_collection', {
    p_contract_id: contractId,
    ...(amount === undefined ? {} : { p_amount_text: amount }),
  });
  if (error) fail(error);
  return CollectionPreview.parse(data);
}

/** POST /api/collections: one collection on one or several contracts; the same key again returns it. */
export async function postCollection(
  ctx: RequestContext,
  body: CollectionBody,
  idempotencyKey: string,
): Promise<Collection> {
  const { data, error } = await ctx.db.rpc('post_collection', {
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return Collection.parse(data);
}

/** GET /api/collections/:id: the receipt. */
export async function getCollection(ctx: RequestContext, id: string): Promise<Collection> {
  const { data, error } = await ctx.db.rpc('get_collection', { p_id: id });
  if (error) fail(error);
  return Collection.parse(data);
}

/** POST /api/collections/:id/prints: the print log (first print = original). */
export async function recordReceiptPrint(ctx: RequestContext, id: string): Promise<Collection> {
  const { data, error } = await ctx.db.rpc('record_collection_receipt_print', { p_id: id });
  if (error) fail(error);
  return Collection.parse(data);
}

/** POST /api/collections/:id/reverse: same business day, the latest collection of its contracts. */
export async function reverseCollection(
  ctx: RequestContext,
  id: string,
  body: CollectionReverseBody,
  idempotencyKey: string,
): Promise<Collection> {
  const { data, error } = await ctx.db.rpc('reverse_collection', {
    p_id: id,
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return Collection.parse(data);
}
