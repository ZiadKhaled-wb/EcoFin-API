import type { Request, Response } from 'express';
import {
  CreateImportBody,
  ImportIdParams,
  ImportKindParams,
  ImportTemplateQuery,
  InspectImportBody,
  RunImportBody,
  type ImportListQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/imports.service';
import { buildImportTemplate } from '../services/imports/files';

const id = (req: Request) => ImportIdParams.parse(req.params).id;

/** GET /api/imports/templates/:kind?format= : the empty file to fill. */
export async function template(req: Request, res: Response) {
  const { kind } = ImportKindParams.parse(req.params);
  const { format } = ImportTemplateQuery.parse(req.query);
  const file = await buildImportTemplate(kind, format);
  res.setHeader('Content-Type', file.contentType);
  res.setHeader('Content-Disposition', `attachment; filename="${file.filename}"`);
  res.setHeader('Cache-Control', 'no-store');
  res.send(file.body);
}
export async function inspect(req: Request, res: Response) {
  res.json(await service.inspectImport(getCtx(req), InspectImportBody.parse(req.body)));
}
export async function create(req: Request, res: Response) {
  res.status(201).json(await service.createImport(getCtx(req), CreateImportBody.parse(req.body)));
}
/** validate() already parsed the query with the contract (defaults filled). */
export async function list(req: Request, res: Response) {
  res.json(await service.listImports(getCtx(req), req.query as unknown as ImportListQuery));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getImport(getCtx(req), id(req)));
}
export async function run(req: Request, res: Response) {
  res
    .status(202)
    .json(await service.runImport(getCtx(req), id(req), RunImportBody.parse(req.body)));
}
export async function cancel(req: Request, res: Response) {
  res.json(await service.cancelImport(getCtx(req), id(req)));
}
