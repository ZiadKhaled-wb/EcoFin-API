import { InstallmentPreview, type InstallmentPreviewBody } from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
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
