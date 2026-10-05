// server/src/routes/files.ts  (mounted at /api/files)
//
//   POST /            upload one file (multipart). Permission depends on the purpose, so the route
//                     marker is authenticatedOnly(); the service checks the purpose's key before
//                     anything is stored.
//   GET  /:id/url     signed link. Same: authenticatedOnly(), key depends on the file's purpose.
//   GET  /            metadata of one record's files. Filtered per purpose.
//
// Each route mounts authenticate, then authenticatedOnly(), then loadRequestContext (shop and
// status gate), then the body parser and validation, then the controller.
import { Router } from 'express';
import { FileList, FileUpload, FileUrl } from '@ziadkhaled-wb/contracts';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { authenticatedOnly } from '../middleware/permissions';
import { loadRequestContext } from '../middleware/requestContext';
import { validate } from '../middleware/validate';
import * as filesController from '../controllers/files.controller';

const router = Router();

router.post(
  '/',
  authenticate,
  authenticatedOnly(),
  loadRequestContext,
  filesController.parseFileUpload,
  validate({ body: FileUpload.body }),
  asyncHandler(filesController.upload),
);

router.get(
  '/',
  authenticate,
  authenticatedOnly(),
  loadRequestContext,
  validate({ query: FileList.query }),
  asyncHandler(filesController.list),
);

router.get(
  '/:id/url',
  authenticate,
  authenticatedOnly(),
  loadRequestContext,
  validate({ params: FileUrl.params }),
  asyncHandler(filesController.signedUrl),
);

export default router;
