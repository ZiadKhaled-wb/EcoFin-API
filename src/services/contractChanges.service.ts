import {
  ContractChangeHistory,
  ContractChangeListPage,
  ContractChangeResponse,
  ReschedulePreview,
  SettlementQuote,
  SettleResponse,
  type ContractChangeListQuery,
  type ReschedulePreviewBody,
  type RescheduleBody,
  type SettleBody,
  type WriteOffBody,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// N05 (D80). Early settlement, rescheduling, write-off: every rule and write lives in SQL
// (20261021090000_n05_contract_changes.sql, one transaction each); the API only shapes the calls.
// A reschedule never adds to what is owed (Islamic finance rule 5); a waiver is a manager's
// decision at settlement time (rule 6).

function fail(error: unknown): never {
  // The message and the Postgres code only: reasons and amounts are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'contract change database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/contracts/:id/settlement-quote: the payoff and the suggested waiver. */
export async function getSettlementQuote(
  ctx: RequestContext,
  contractId: string,
): Promise<SettlementQuote> {
  const { data, error } = await ctx.db.rpc('get_settlement_quote', { p_contract_id: contractId });
  if (error) fail(error);
  return SettlementQuote.parse(data);
}

/** POST /api/contracts/:id/settle: the payoff minus the waiver, collected; the contract closes. */
export async function settleEarly(
  ctx: RequestContext,
  contractId: string,
  body: SettleBody,
  idempotencyKey: string,
): Promise<SettleResponse> {
  const { data, error } = await ctx.db.rpc('settle_contract_early', {
    p_contract_id: contractId,
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return SettleResponse.parse(data);
}

/** POST /api/contracts/:id/reschedule/preview: the new lines, nothing written. */
export async function previewReschedule(
  ctx: RequestContext,
  contractId: string,
  body: ReschedulePreviewBody,
): Promise<ReschedulePreview> {
  const { data, error } = await ctx.db.rpc('preview_reschedule', {
    p_contract_id: contractId,
    p_body: body as Json,
  });
  if (error) fail(error);
  return ReschedulePreview.parse(data);
}

/** POST /api/contracts/:id/reschedule: what is left over a new schedule version. */
export async function reschedule(
  ctx: RequestContext,
  contractId: string,
  body: RescheduleBody,
  idempotencyKey: string,
): Promise<ContractChangeResponse> {
  const { data, error } = await ctx.db.rpc('reschedule_contract', {
    p_contract_id: contractId,
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return ContractChangeResponse.parse(data);
}

/** POST /api/contracts/:id/write-off (the owner). */
export async function writeOff(
  ctx: RequestContext,
  contractId: string,
  body: WriteOffBody,
  idempotencyKey: string,
): Promise<ContractChangeResponse> {
  const { data, error } = await ctx.db.rpc('write_off_contract', {
    p_contract_id: contractId,
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return ContractChangeResponse.parse(data);
}

/** GET /api/contracts/:id/changes: the changes and every schedule version. */
export async function getHistory(
  ctx: RequestContext,
  contractId: string,
): Promise<ContractChangeHistory> {
  const { data, error } = await ctx.db.rpc('list_contract_changes_for', {
    p_contract_id: contractId,
  });
  if (error) fail(error);
  return ContractChangeHistory.parse(data);
}

/** GET /api/contract-changes: the shop's changes, newest first, with totals by kind. */
export async function listChanges(
  ctx: RequestContext,
  query: ContractChangeListQuery,
): Promise<ContractChangeListPage> {
  const { data, error } = await ctx.db.rpc('list_contract_changes', { p_filters: query as Json });
  if (error) fail(error);
  return ContractChangeListPage.parse(data);
}
