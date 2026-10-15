import {
  Survey,
  SurveyArray,
  SurveyList,
  SurveyRequirement,
  type SurveyAnswersBody,
  type SurveyCancelBody,
  type SurveyCreateBody,
  type SurveyDecisionBody,
  type SurveyListQuery,
  type SurveyReassignBody,
  type SurveyRequirementQuery,
  type SurveySubmitBody,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// R05 (D75). Every rule is in SQL: who may assign, fill and decide, the assignee check, one open
// survey per customer, the answers' validation, the photo rule, the collector who sees only their
// own surveys (others answer SURVEY_NOT_FOUND). The API only shapes the calls.

function fail(error: unknown): never {
  // The message and the Postgres code only: a request body (GPS, notes) is never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'survey database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_field_surveys returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

export async function listSurveys(
  ctx: RequestContext,
  query: SurveyListQuery,
): Promise<SurveyList> {
  const { data, error } = await ctx.db.rpc('list_field_surveys', {
    ...(query.status ? { p_status: query.status } : {}),
    ...(query.customer_id ? { p_customer_id: query.customer_id } : {}),
    ...(query.assigned_to ? { p_assigned_to: query.assigned_to } : {}),
    p_mine: query.mine,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return SurveyList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getSurvey(ctx: RequestContext, id: string): Promise<Survey> {
  const { data, error } = await ctx.db.rpc('get_field_survey', { p_id: id });
  if (error) fail(error);
  return Survey.parse(data);
}

export async function assignSurvey(ctx: RequestContext, body: SurveyCreateBody): Promise<Survey> {
  const { data, error } = await ctx.db.rpc('assign_field_survey', { p_body: body as Json });
  if (error) fail(error);
  return Survey.parse(data);
}

export async function reassignSurvey(
  ctx: RequestContext,
  id: string,
  body: SurveyReassignBody,
): Promise<Survey> {
  const { data, error } = await ctx.db.rpc('reassign_field_survey', {
    p_id: id,
    p_assigned_to: body.assigned_to,
  });
  if (error) fail(error);
  return Survey.parse(data);
}

export async function cancelSurvey(
  ctx: RequestContext,
  id: string,
  body: SurveyCancelBody,
): Promise<Survey> {
  const { data, error } = await ctx.db.rpc('cancel_field_survey', {
    p_id: id,
    p_reason: body.reason,
  });
  if (error) fail(error);
  return Survey.parse(data);
}

/** The assignee saves part of the answers; the same values again change nothing. */
export async function saveSurvey(
  ctx: RequestContext,
  id: string,
  body: SurveyAnswersBody,
): Promise<Survey> {
  const { data, error } = await ctx.db.rpc('save_field_survey', { p_id: id, p_body: body as Json });
  if (error) fail(error);
  return Survey.parse(data);
}

export async function submitSurvey(
  ctx: RequestContext,
  id: string,
  body: SurveySubmitBody,
): Promise<Survey> {
  const { data, error } = await ctx.db.rpc('submit_field_survey', {
    p_id: id,
    p_body: body as Json,
  });
  if (error) fail(error);
  return Survey.parse(data);
}

export async function decideSurvey(
  ctx: RequestContext,
  id: string,
  body: SurveyDecisionBody,
): Promise<Survey> {
  const { data, error } = await ctx.db.rpc('decide_field_survey', {
    p_id: id,
    p_decision: body.decision,
    ...(body.note ? { p_note: body.note } : {}),
  });
  if (error) fail(error);
  return Survey.parse(data);
}

export async function listCustomerSurveys(
  ctx: RequestContext,
  customerId: string,
): Promise<SurveyArray> {
  const { data, error } = await ctx.db.rpc('list_customer_surveys', { p_customer_id: customerId });
  if (error) fail(error);
  return SurveyArray.parse(data);
}

/** Against the shop's current policy version; `financed_amount` = cash price - down payment. */
export async function getSurveyRequirement(
  ctx: RequestContext,
  customerId: string,
  query: SurveyRequirementQuery,
): Promise<SurveyRequirement> {
  const { data, error } = await ctx.db.rpc('get_survey_requirement', {
    p_customer_id: customerId,
    p_financed_amount: query.financed_amount,
  });
  if (error) fail(error);
  return SurveyRequirement.parse(data);
}
