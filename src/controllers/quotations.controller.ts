import type { Request, Response } from 'express';
import type { ZodError } from 'zod';
import {
  CreateQuotationBody,
  UpdateQuotationBody,
  QuotationListQuery,
  QuotationIdParams,
  QuotationReasonBody,
  IdempotencyKeyHeader,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import { AppError } from '../utils/errors';
import * as service from '../services/quotations.service';
const id = (req: Request) => QuotationIdParams.parse(req.params).id;
function invalidDraft(error: ZodError): never {
  if (error.issues.some((i) => i.path[0] === 'lines'))
    throw new AppError('Invalid quotation lines.', 'QUOTATION_LINES_INVALID', 422);
  if (error.issues.some((i) => i.path[0] === 'valid_until'))
    throw new AppError('Invalid quotation validity.', 'QUOTATION_VALIDITY_INVALID', 422);
  throw error;
}
function createBody(req: Request) {
  const result = CreateQuotationBody.safeParse(req.body);
  if (!result.success) invalidDraft(result.error);
  return result.data;
}
function updateBody(req: Request) {
  const result = UpdateQuotationBody.safeParse(req.body);
  if (!result.success) invalidDraft(result.error);
  return result.data;
}
function reason(req: Request) {
  const result = QuotationReasonBody.safeParse(req.body);
  if (!result.success) throw new AppError('A reason is required.', 'REASON_REQUIRED', 422);
  return result.data.reason;
}
export async function list(req: Request, res: Response) {
  res.json(await service.list(getCtx(req), QuotationListQuery.parse(req.query)));
}
export async function get(req: Request, res: Response) {
  res.json(await service.get(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  res
    .status(201)
    .json(
      await service.create(
        getCtx(req),
        createBody(req),
        IdempotencyKeyHeader.parse(req.headers)['idempotency-key'],
      ),
    );
}
export async function update(req: Request, res: Response) {
  res.json(await service.update(getCtx(req), id(req), updateBody(req)));
}
export async function send(req: Request, res: Response) {
  res.json(await service.move(getCtx(req), id(req), 'send'));
}
export async function accept(req: Request, res: Response) {
  res.json(await service.move(getCtx(req), id(req), 'accept'));
}
export async function reject(req: Request, res: Response) {
  res.json(await service.move(getCtx(req), id(req), 'reject', reason(req)));
}
export async function cancel(req: Request, res: Response) {
  res.json(await service.move(getCtx(req), id(req), 'cancel', reason(req)));
}
