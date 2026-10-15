import { Router } from 'express';
import {
  SurveyAnswersBody,
  SurveyCancelBody,
  SurveyCreateBody,
  SurveyDecisionBody,
  SurveyIdParams,
  SurveyListQuery,
  SurveyReassignBody,
  SurveySubmitBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/surveys.controller';
const router = Router();
// R05 (D75). Reads: any customer read key (D63 rule 6) and the plan module, both checked in SQL, so
// they are authenticatedOnly() here; a collector (survey.submit only) sees only their own surveys.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: SurveyListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: SurveyIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('survey.assign'),
  validate({ body: SurveyCreateBody }),
  asyncHandler(controller.assign),
);
router.post(
  '/:id/reassign',
  authenticate,
  loadRequestContext,
  requirePermission('survey.assign'),
  validate({ params: SurveyIdParams, body: SurveyReassignBody }),
  asyncHandler(controller.reassign),
);
router.post(
  '/:id/cancel',
  authenticate,
  loadRequestContext,
  requirePermission('survey.assign'),
  validate({ params: SurveyIdParams, body: SurveyCancelBody }),
  asyncHandler(controller.cancel),
);
// Save and submit: survey.submit here; being the assignee is checked in SQL (SURVEY_NOT_ASSIGNEE).
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('survey.submit'),
  validate({ params: SurveyIdParams, body: SurveyAnswersBody }),
  asyncHandler(controller.save),
);
router.post(
  '/:id/submit',
  authenticate,
  loadRequestContext,
  requirePermission('survey.submit'),
  validate({ params: SurveyIdParams, body: SurveySubmitBody }),
  asyncHandler(controller.submit),
);
router.post(
  '/:id/decide',
  authenticate,
  loadRequestContext,
  requirePermission('survey.decide'),
  validate({ params: SurveyIdParams, body: SurveyDecisionBody }),
  asyncHandler(controller.decide),
);
export default router;
