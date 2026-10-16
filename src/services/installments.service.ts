import {
  Contract,
  InstallmentPreview,
  InstallmentSale,
  type InstallmentPreviewBody,
  type InstallmentSaleBody,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { withFreshEta } from './eta.service';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// N01 (D76). The terms are calculated in SQL (app.installment_terms, the source of truth; the
// contracts' computeInstallmentTerms is its copy for screens). The API only shapes the call.

function fail(error: unknown): never {
  // The message and the Postgres code only: a request body (prices, customer) is never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'installment database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** POST /api/installments/preview: read only, nothing is written. */
export async function previewInstallmentTerms(
  ctx: RequestContext,
  body: InstallmentPreviewBody,
): Promise<InstallmentPreview> {
  const { data, error } = await ctx.db.rpc('preview_installment_terms', { p_body: body as Json });
  if (error) fail(error);
  return InstallmentPreview.parse(data);
}

/**
 * N02 (D77). POST /api/installments/sales: the sale, its down payment and the contract in one
 * database transaction (public.post_installment_sale). The same key again returns the same answer.
 */
export async function postInstallmentSale(
  ctx: RequestContext,
  body: InstallmentSaleBody,
  idempotencyKey: string,
): Promise<InstallmentSale> {
  const { data, error } = await ctx.db.rpc('post_installment_sale', {
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  const answer = InstallmentSale.parse(data);
  return { ...answer, sale: await withFreshEta(ctx, answer.sale) };
}

/** GET /api/contracts/:id: any customer read key and the contract's branch (checked in SQL). */
export async function getContract(ctx: RequestContext, id: string): Promise<Contract> {
  const { data, error } = await ctx.db.rpc('get_contract', { p_id: id });
  if (error) fail(error);
  return Contract.parse(data);
}
