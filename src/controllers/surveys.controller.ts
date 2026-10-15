import type { Request, Response } from 'express';
import {
  CustomerIdParams,
  SurveyAnswersBody,
  SurveyCancelBody,
  SurveyCreateBody,
  SurveyDecisionBody,
  SurveyIdParams,
  type SurveyListQuery,
  SurveyReassignBody,
  SurveyRequirementQuery,
  SurveySubmitBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/surveys.service';

const id = (req: Request) => SurveyIdParams.parse(req.params).id;
const customerId = (req: Request) => CustomerIdParams.parse({ id: req.params.id }).id;

/** validate() already parsed the query with the contract (defaults filled). */
export async function list(req: Request, res: Response) {
  res.json(await service.listSurveys(getCtx(req), req.query as unknown as SurveyListQuery));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getSurvey(getCtx(req), id(req)));
}
export async function assign(req: Request, res: Response) {
  res.status(201).json(await service.assignSurvey(getCtx(req), SurveyCreateBody.parse(req.body)));
}
export async function reassign(req: Request, res: Response) {
  res.json(await service.reassignSurvey(getCtx(req), id(req), SurveyReassignBody.parse(req.body)));
}
export async function cancel(req: Request, res: Response) {
  res.json(await service.cancelSurvey(getCtx(req), id(req), SurveyCancelBody.parse(req.body)));
}
export async function save(req: Request, res: Response) {
  res.json(await service.saveSurvey(getCtx(req), id(req), SurveyAnswersBody.parse(req.body)));
}
export async function submit(req: Request, res: Response) {
  res.json(
    await service.submitSurvey(getCtx(req), id(req), SurveySubmitBody.parse(req.body ?? {})),
  );
}
export async function decide(req: Request, res: Response) {
  res.json(await service.decideSurvey(getCtx(req), id(req), SurveyDecisionBody.parse(req.body)));
}

export async function listForCustomer(req: Request, res: Response) {
  res.json(await service.listCustomerSurveys(getCtx(req), customerId(req)));
}
export async function requirement(req: Request, res: Response) {
  res.json(
    await service.getSurveyRequirement(
      getCtx(req),
      customerId(req),
      SurveyRequirementQuery.parse(req.query),
    ),
  );
}
