import type { Request, Response } from 'express';
import {
  CategoryArchiveBody,
  CategoryCreateBody,
  CategoryIdParams,
  CategoryUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/categories.service';
const id = (req: Request) => CategoryIdParams.parse(req.params).id;
export async function list(req: Request, res: Response) {
  res.json(await service.listCategories(getCtx(req)));
}
export async function create(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.createCategory(getCtx(req), CategoryCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateCategory(getCtx(req), id(req), CategoryUpdateBody.parse(req.body)));
}
export async function archive(req: Request, res: Response) {
  res.json(
    await service.setCategoryArchived(
      getCtx(req),
      id(req),
      true,
      CategoryArchiveBody.parse(req.body),
    ),
  );
}
export async function restore(req: Request, res: Response) {
  res.json(await service.setCategoryArchived(getCtx(req), id(req), false));
}
