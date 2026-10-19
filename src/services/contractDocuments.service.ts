import {
  ContractDocumentPrint,
  ContractDocuments,
  type ContractDocumentKind,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// N07 (D82). The printed contract and promissory notes: everything is read and logged in SQL
// (public.get_contract_documents / record_contract_document_print); the API only shapes the calls.
// The read carries full national IDs: it is never cached and never logged.

function fail(error: unknown): never {
  // The message and the Postgres code only: the answer (national IDs, addresses) is never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'contract documents database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/contracts/:id/documents: what the contract and the notes print. */
export async function getDocuments(ctx: RequestContext, id: string): Promise<ContractDocuments> {
  const { data, error } = await ctx.db.rpc('get_contract_documents', { p_id: id });
  if (error) fail(error);
  return ContractDocuments.parse(data);
}

/** POST /api/contracts/:id/document-prints: the print log (first print of a schedule version = original). */
export async function recordPrint(
  ctx: RequestContext,
  id: string,
  document: ContractDocumentKind,
): Promise<ContractDocumentPrint> {
  const { data, error } = await ctx.db.rpc('record_contract_document_print', {
    p_id: id,
    p_document: document,
  });
  if (error) fail(error);
  return ContractDocumentPrint.parse(data);
}
