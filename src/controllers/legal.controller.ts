import type { Request, Response } from 'express';
import {
  AddCaseNoteBody,
  AddHearingBody,
  IdempotencyKeyHeader,
  LegalCaseIdParams,
  LegalCaseListQuery,
  LegalHearingParams,
  OpenLegalCaseBody,
  SetLegalCaseStatusBody,
  UpdateHearingBody,
  UpdateLegalCaseBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/legal.service';

export async function list(req: Request, res: Response) {
  res.json(await service.listCases(getCtx(req), LegalCaseListQuery.parse(req.query)));
}

export async function open(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res.status(201).json(await service.openCase(getCtx(req), OpenLegalCaseBody.parse(req.body), key));
}

export async function get(req: Request, res: Response) {
  res.json(await service.getCase(getCtx(req), LegalCaseIdParams.parse(req.params).id));
}

export async function update(req: Request, res: Response) {
  const { id } = LegalCaseIdParams.parse(req.params);
  res.json(await service.updateCase(getCtx(req), id, UpdateLegalCaseBody.parse(req.body)));
}

export async function setStatus(req: Request, res: Response) {
  const { id } = LegalCaseIdParams.parse(req.params);
  res.json(await service.setStatus(getCtx(req), id, SetLegalCaseStatusBody.parse(req.body)));
}

export async function addHearing(req: Request, res: Response) {
  const { id } = LegalCaseIdParams.parse(req.params);
  res.json(await service.addHearing(getCtx(req), id, AddHearingBody.parse(req.body)));
}

export async function updateHearing(req: Request, res: Response) {
  const { id, hearingId } = LegalHearingParams.parse(req.params);
  res.json(
    await service.updateHearing(getCtx(req), id, hearingId, UpdateHearingBody.parse(req.body)),
  );
}

export async function addNote(req: Request, res: Response) {
  const { id } = LegalCaseIdParams.parse(req.params);
  res.json(await service.addNote(getCtx(req), id, AddCaseNoteBody.parse(req.body)));
}

export async function lawyers(req: Request, res: Response) {
  res.json(await service.listLawyers(getCtx(req)));
}
