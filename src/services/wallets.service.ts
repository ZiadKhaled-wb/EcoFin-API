import {
  Collection,
  CollectorRoute,
  Customer,
  MyWallet,
  WalletListResponse,
  WalletMovementPage,
  WalletSettlement,
  type CollectorRouteQuery,
  type FieldCollectionBody,
  type SetCustomerCollectorBody,
  type SettleWalletBody,
  type WalletListQuery,
  type WalletMovementQuery,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// N06 (D81). Collector wallets: every rule and write lives in SQL
// (20261022090000_n06_collector_wallets.sql, one transaction each); the API only shapes the calls.
// There is no collector commission (collectors are salaried) and no deduction of a shortage.

function fail(error: unknown): never {
  // The message and the Postgres code only: amounts, reasons and customers are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'wallet database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** POST /api/collections/field: N03's collection taken in the field, into the caller's wallet. */
export async function postFieldCollection(
  ctx: RequestContext,
  body: FieldCollectionBody,
  idempotencyKey: string,
): Promise<Collection> {
  const { data, error } = await ctx.db.rpc('post_field_collection', {
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return Collection.parse(data);
}

/** GET /api/wallets/me */
export async function getMyWallet(ctx: RequestContext): Promise<MyWallet> {
  const { data, error } = await ctx.db.rpc('get_my_wallet');
  if (error) fail(error);
  return MyWallet.parse(data);
}

/** GET /api/wallets */
export async function listWallets(
  ctx: RequestContext,
  query: WalletListQuery,
): Promise<WalletListResponse> {
  const { data, error } = await ctx.db.rpc('list_collector_wallets', { p_filters: query as Json });
  if (error) fail(error);
  return WalletListResponse.parse(data);
}

/** GET /api/wallets/:id/movements */
export async function listWalletMovements(
  ctx: RequestContext,
  id: string,
  query: WalletMovementQuery,
): Promise<WalletMovementPage> {
  const { data, error } = await ctx.db.rpc('list_wallet_movements', {
    p_id: id,
    p_filters: query as Json,
  });
  if (error) fail(error);
  return WalletMovementPage.parse(data);
}

/** POST /api/wallets/:id/settle: hand the cash in; a shortage is recorded, never deducted. */
export async function settleWallet(
  ctx: RequestContext,
  id: string,
  body: SettleWalletBody,
  idempotencyKey: string,
): Promise<WalletSettlement> {
  const { data, error } = await ctx.db.rpc('settle_collector_wallet', {
    p_id: id,
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return WalletSettlement.parse(data);
}

/** PUT /api/customers/:id/collector */
export async function setCustomerCollector(
  ctx: RequestContext,
  customerId: string,
  body: SetCustomerCollectorBody,
): Promise<Customer> {
  const { data, error } = await ctx.db.rpc('set_customer_collector', {
    p_customer_id: customerId,
    p_employee_id: body.employee_id as string,
    ...(body.reason === undefined ? {} : { p_reason: body.reason }),
  });
  if (error) fail(error);
  return Customer.parse(data);
}

/** GET /api/collectors/route */
export async function getCollectorRoute(
  ctx: RequestContext,
  query: CollectorRouteQuery,
): Promise<CollectorRoute> {
  const { data, error } = await ctx.db.rpc('get_collector_route', { p_filters: query as Json });
  if (error) fail(error);
  return CollectorRoute.parse(data);
}
