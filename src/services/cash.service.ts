import {
  CashAccount,
  CashAccountList,
  CashLedger,
  CashTransfer,
  CashTransferList,
  type CashAccountCreateBody,
  type CashAccountListQuery,
  type CashLedgerQuery,
  type CashOpeningBody,
  type CashTransferCreateBody,
  type CashTransferListQuery,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'cash database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What the paged reads return before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

const paging = (q: { page: number; pageSize: number }) => ({
  p_limit: q.pageSize,
  p_offset: (q.page - 1) * q.pageSize,
});

/** K01: the safes and banks the caller may see (drawers and wallets are not listed). */
export async function listCashAccounts(
  ctx: RequestContext,
  query: CashAccountListQuery,
): Promise<CashAccountList> {
  const { data, error } = await ctx.db.rpc('list_cash_accounts', {
    p_status: query.status,
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.kind ? { p_kind: query.kind } : {}),
  });
  if (error) fail(error);
  return CashAccountList.parse(data);
}

export async function getCashAccount(ctx: RequestContext, id: string): Promise<CashAccount> {
  const { data, error } = await ctx.db.rpc('get_cash_account', { p_id: id });
  if (error) fail(error);
  return CashAccount.parse(data);
}

/** The account's ledger, newest first, with the running balance and the period's opening/closing. */
export async function getCashLedger(
  ctx: RequestContext,
  id: string,
  query: CashLedgerQuery,
): Promise<CashLedger> {
  const { data, error } = await ctx.db.rpc('list_cash_account_movements', {
    p_id: id,
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    ...paging(query),
  });
  if (error) fail(error);
  return CashLedger.parse({ ...(data as object), page: query.page, pageSize: query.pageSize });
}

export async function createCashAccount(
  ctx: RequestContext,
  body: CashAccountCreateBody,
): Promise<CashAccount> {
  const { data, error } = await ctx.db.rpc('create_cash_account', {
    p_name: body.name,
    p_kind: body.kind,
    ...(body.branch_id ? { p_branch_id: body.branch_id } : {}),
  });
  if (error) fail(error);
  return CashAccount.parse(data);
}

export async function renameCashAccount(
  ctx: RequestContext,
  id: string,
  name: string,
): Promise<CashAccount> {
  const { data, error } = await ctx.db.rpc('rename_cash_account', { p_id: id, p_name: name });
  if (error) fail(error);
  return CashAccount.parse(data);
}

/** Deactivate is refused with a balance or as a branch's default vault. */
export async function setCashAccountActive(
  ctx: RequestContext,
  id: string,
  active: boolean,
): Promise<CashAccount> {
  const { data, error } = await ctx.db.rpc('set_cash_account_active', {
    p_id: id,
    p_active: active,
  });
  if (error) fail(error);
  return CashAccount.parse(data);
}

/** One opening balance on an account with no movements; the same key again changes nothing. */
export async function postCashOpening(
  ctx: RequestContext,
  id: string,
  body: CashOpeningBody,
  idempotencyKey: string,
): Promise<CashAccount> {
  const { data, error } = await ctx.db.rpc('post_cash_opening', {
    p_id: id,
    p_amount: body.amount,
    p_note: body.note,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return CashAccount.parse(data);
}

export async function listCashTransfers(
  ctx: RequestContext,
  query: CashTransferListQuery,
): Promise<CashTransferList> {
  const { data, error } = await ctx.db.rpc('list_cash_transfers', {
    ...(query.account_id ? { p_account_id: query.account_id } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    ...paging(query),
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return CashTransferList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getCashTransfer(ctx: RequestContext, id: string): Promise<CashTransfer> {
  const { data, error } = await ctx.db.rpc('get_cash_transfer', { p_id: id });
  if (error) fail(error);
  return CashTransfer.parse(data);
}

/** Out of one account and into the other in one transaction; the same key returns the same transfer. */
export async function createCashTransfer(
  ctx: RequestContext,
  body: CashTransferCreateBody,
  idempotencyKey: string,
): Promise<CashTransfer> {
  const { data, error } = await ctx.db.rpc('create_cash_transfer', {
    p_from: body.from_account_id,
    p_to: body.to_account_id,
    p_amount: body.amount,
    // The generated types make p_note required; '' means no note (the function stores NULL).
    p_note: body.note ?? '',
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return CashTransfer.parse(data);
}
