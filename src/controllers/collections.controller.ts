import type { Request, Response } from 'express';
import {
  CollectionBody,
  CollectionIdParams,
  CollectionPreviewQuery,
  CollectionReverseBody,
  ContractIdParams,
  ContractListQuery,
  IdempotencyKeyHeader,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/collections.service';

export async function listContracts(req: Request, res: Response) {
  res.json(await service.listContracts(getCtx(req), ContractListQuery.parse(req.query)));
}

export async function preview(req: Request, res: Response) {
  const { id } = ContractIdParams.parse(req.params);
  const { amount } = CollectionPreviewQuery.parse(req.query);
  res.json(await service.previewCollection(getCtx(req), id, amount));
}

export async function create(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res
    .status(201)
    .json(await service.postCollection(getCtx(req), CollectionBody.parse(req.body), key));
}

export async function get(req: Request, res: Response) {
  res.json(await service.getCollection(getCtx(req), CollectionIdParams.parse(req.params).id));
}

export async function print(req: Request, res: Response) {
  res.json(await service.recordReceiptPrint(getCtx(req), CollectionIdParams.parse(req.params).id));
}

export async function reverse(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res.json(
    await service.reverseCollection(
      getCtx(req),
      CollectionIdParams.parse(req.params).id,
      CollectionReverseBody.parse(req.body),
      key,
    ),
  );
}
