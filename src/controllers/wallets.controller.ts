import type { Request, Response } from 'express';
import {
  CollectorRouteQuery,
  CustomerIdParams,
  FieldCollectionBody,
  IdempotencyKeyHeader,
  SetCustomerCollectorBody,
  SettleWalletBody,
  WalletIdParams,
  WalletListQuery,
  WalletMovementQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/wallets.service';

export async function createFieldCollection(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res
    .status(201)
    .json(await service.postFieldCollection(getCtx(req), FieldCollectionBody.parse(req.body), key));
}

export async function myWallet(req: Request, res: Response) {
  res.json(await service.getMyWallet(getCtx(req)));
}

export async function list(req: Request, res: Response) {
  res.json(await service.listWallets(getCtx(req), WalletListQuery.parse(req.query)));
}

export async function movements(req: Request, res: Response) {
  const { id } = WalletIdParams.parse(req.params);
  res.json(
    await service.listWalletMovements(getCtx(req), id, WalletMovementQuery.parse(req.query)),
  );
}

export async function settle(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  const { id } = WalletIdParams.parse(req.params);
  res.json(await service.settleWallet(getCtx(req), id, SettleWalletBody.parse(req.body), key));
}

export async function setCustomerCollector(req: Request, res: Response) {
  const { id } = CustomerIdParams.parse(req.params);
  res.json(
    await service.setCustomerCollector(getCtx(req), id, SetCustomerCollectorBody.parse(req.body)),
  );
}

export async function route(req: Request, res: Response) {
  res.json(await service.getCollectorRoute(getCtx(req), CollectorRouteQuery.parse(req.query)));
}
