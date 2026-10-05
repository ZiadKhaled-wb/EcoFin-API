// server/src/controllers/files.controller.ts
//
// Thin handlers for /api/files. validate() has already parsed the body, query and params with the
// contract schemas. parseFileUpload reads the one `file` part into memory and turns multer's
// errors into contract codes.
import type { NextFunction, Request, Response } from 'express';
import multer from 'multer';
import type { FileIdParams, ListFilesQuery, UploadFileRequest } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as filesService from '../services/files.service';
import { AppError, BadRequest, safeMessage } from '../utils/errors';
import { getEnv } from '../utils/env';

const settings = () => {
  const env = getEnv();
  return { maxBytes: env.FILE_MAX_BYTES, urlTtlSeconds: env.FILE_URL_TTL_SECONDS };
};

/**
 * The one `file` part, held in memory and capped at FILE_MAX_BYTES (multer stops reading past it).
 * Too big is 413 FILE_TOO_LARGE; any other multipart problem is 400 VALIDATION_FAILED.
 */
export function parseFileUpload(req: Request, res: Response, next: NextFunction): void {
  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: getEnv().FILE_MAX_BYTES, files: 1 },
  }).single('file');
  upload(req, res, (err: unknown) => {
    if (!err) {
      next();
      return;
    }
    if (err instanceof multer.MulterError) {
      next(
        err.code === 'LIMIT_FILE_SIZE'
          ? new AppError(safeMessage('FILE_TOO_LARGE'), 'FILE_TOO_LARGE')
          : BadRequest('The upload is not valid.', 'VALIDATION_FAILED'),
      );
      return;
    }
    next(err);
  });
}

/** POST /api/files */
export async function upload(req: Request, res: Response) {
  const body = req.body as UploadFileRequest;
  const file = (req as Request & { file?: { buffer: Buffer; originalname: string } }).file;
  res.status(201).json(await filesService.uploadFile(getCtx(req), file, body, settings()));
}

/** GET /api/files/:id/url */
export async function signedUrl(req: Request, res: Response) {
  const { id } = req.params as FileIdParams;
  res.json(await filesService.getFileUrl(getCtx(req), id, settings()));
}

/** GET /api/files?entityType=&entityId= */
export async function list(req: Request, res: Response) {
  res.json(await filesService.listFiles(getCtx(req), req.query as ListFilesQuery));
}
