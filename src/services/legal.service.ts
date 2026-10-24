import {
  LawyerListResponse,
  LegalCaseDetail,
  LegalCaseListResponse,
  type AddCaseNoteBody,
  type AddHearingBody,
  type LegalCaseListQuery,
  type OpenLegalCaseBody,
  type SetLegalCaseStatusBody,
  type UpdateHearingBody,
  type UpdateLegalCaseBody,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// L01 + N09 (D92). The legal module: every rule (who sees which case, the status chain, the claim
// limit, the customer block) lives in SQL (20261103090000_l01_legal_module.sql); the API only shapes
// the calls. It never adds to what a customer owes (Islamic finance rule 4).

function fail(error: unknown): never {
  // The message and the Postgres code only: notes, outcomes and claim details are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'legal database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/legal/cases. */
export async function listCases(
  ctx: RequestContext,
  query: LegalCaseListQuery,
): Promise<LegalCaseListResponse> {
  const { data, error } = await ctx.db.rpc('list_legal_cases', { p_filters: query as Json });
  if (error) fail(error);
  return LegalCaseListResponse.parse(data);
}

/** GET /api/legal/cases/:id. */
export async function getCase(ctx: RequestContext, id: string): Promise<LegalCaseDetail> {
  const { data, error } = await ctx.db.rpc('get_legal_case', { p_id: id });
  if (error) fail(error);
  return LegalCaseDetail.parse(data);
}

/** POST /api/legal/cases (the owner). */
export async function openCase(
  ctx: RequestContext,
  body: OpenLegalCaseBody,
  idempotencyKey: string,
): Promise<LegalCaseDetail> {
  const { data, error } = await ctx.db.rpc('open_legal_case', {
    p_body: body as Json,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return LegalCaseDetail.parse(data);
}

/** PATCH /api/legal/cases/:id. */
export async function updateCase(
  ctx: RequestContext,
  id: string,
  body: UpdateLegalCaseBody,
): Promise<LegalCaseDetail> {
  const { data, error } = await ctx.db.rpc('update_legal_case', { p_id: id, p_body: body as Json });
  if (error) fail(error);
  return LegalCaseDetail.parse(data);
}

/** POST /api/legal/cases/:id/status. */
export async function setStatus(
  ctx: RequestContext,
  id: string,
  body: SetLegalCaseStatusBody,
): Promise<LegalCaseDetail> {
  const { data, error } = await ctx.db.rpc('set_legal_case_status', {
    p_id: id,
    p_body: body as Json,
  });
  if (error) fail(error);
  return LegalCaseDetail.parse(data);
}

/** POST /api/legal/cases/:id/hearings. */
export async function addHearing(
  ctx: RequestContext,
  id: string,
  body: AddHearingBody,
): Promise<LegalCaseDetail> {
  const { data, error } = await ctx.db.rpc('add_legal_hearing', {
    p_case_id: id,
    p_body: body as Json,
  });
  if (error) fail(error);
  return LegalCaseDetail.parse(data);
}

/** PATCH /api/legal/cases/:id/hearings/:hearingId. */
export async function updateHearing(
  ctx: RequestContext,
  id: string,
  hearingId: string,
  body: UpdateHearingBody,
): Promise<LegalCaseDetail> {
  const { data, error } = await ctx.db.rpc('update_legal_hearing', {
    p_case_id: id,
    p_hearing_id: hearingId,
    p_body: body as Json,
  });
  if (error) fail(error);
  return LegalCaseDetail.parse(data);
}

/** POST /api/legal/cases/:id/notes (append-only). */
export async function addNote(
  ctx: RequestContext,
  id: string,
  body: AddCaseNoteBody,
): Promise<LegalCaseDetail> {
  const { data, error } = await ctx.db.rpc('add_legal_case_note', {
    p_case_id: id,
    p_body: body as Json,
  });
  if (error) fail(error);
  return LegalCaseDetail.parse(data);
}

/** GET /api/legal/lawyers (the owner). */
export async function listLawyers(ctx: RequestContext): Promise<LawyerListResponse> {
  const { data, error } = await ctx.db.rpc('list_lawyers');
  if (error) fail(error);
  return LawyerListResponse.parse(data);
}
