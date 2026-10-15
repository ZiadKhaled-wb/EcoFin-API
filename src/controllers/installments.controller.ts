import type { Request, Response } from 'express';
import { InstallmentPreviewBody } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/installments.service';

export async function preview(req: Request, res: Response) {
  res.json(
    await service.previewInstallmentTerms(getCtx(req), InstallmentPreviewBody.parse(req.body)),
  );
}
