import type { Request, Response } from 'express';
import {
  MigrationBatchParams,
  MigrationReportQuery,
  MigrationSignOffBody,
  ReverseMigrationBatchBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/migration.service';

/** GET /api/migration/report?format=json|csv (CSV answers as a download). */
export async function report(req: Request, res: Response) {
  const query = MigrationReportQuery.parse(req.query);
  const data = await service.getReport(getCtx(req), query);
  if (query.format === 'csv') {
    const file = service.buildReportCsv(data, data.as_of);
    res.setHeader('Content-Type', file.contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${file.filename}"`);
    res.setHeader('Cache-Control', 'no-store');
    res.send(file.body);
    return;
  }
  res.json(data);
}

export async function signOff(req: Request, res: Response) {
  res.status(201).json(await service.signOff(getCtx(req), MigrationSignOffBody.parse(req.body)));
}

export async function listSignOffs(req: Request, res: Response) {
  res.json(await service.listSignOffs(getCtx(req)));
}

export async function reverse(req: Request, res: Response) {
  const { id } = MigrationBatchParams.parse(req.params);
  res.json(await service.reverseBatch(getCtx(req), id, ReverseMigrationBatchBody.parse(req.body)));
}
