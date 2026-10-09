import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  PurchaseApprovalListQuery,
  PurchaseInvoiceApproveBody,
  PurchaseInvoiceCreateBody,
  PurchaseInvoiceIdParams,
  PurchaseInvoiceListQuery,
  PurchaseInvoiceRejectBody,
  PurchaseInvoiceUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/purchases.service';
const id = (req: Request) => PurchaseInvoiceIdParams.parse(req.params).id;
const keyOf = (req: Request) => IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
export async function list(req: Request, res: Response) {
  res.json(
    await service.listPurchaseInvoices(getCtx(req), PurchaseInvoiceListQuery.parse(req.query)),
  );
}
export async function get(req: Request, res: Response) {
  res.json(await service.getPurchaseInvoice(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(
      await service.createPurchaseInvoice(
        getCtx(req),
        PurchaseInvoiceCreateBody.parse(req.body),
        key,
      ),
    );
}
export async function update(req: Request, res: Response) {
  res.json(
    await service.updatePurchaseInvoice(
      getCtx(req),
      id(req),
      PurchaseInvoiceUpdateBody.parse(req.body),
    ),
  );
}
export async function approve(req: Request, res: Response) {
  const { note } = PurchaseInvoiceApproveBody.parse(req.body ?? {});
  res.json(await service.approvePurchaseInvoice(getCtx(req), id(req), note));
}
export async function reject(req: Request, res: Response) {
  const { reason } = PurchaseInvoiceRejectBody.parse(req.body);
  res.json(await service.rejectPurchaseInvoice(getCtx(req), id(req), reason));
}
export async function approvals(req: Request, res: Response) {
  res.json(
    await service.listPurchaseApprovals(getCtx(req), PurchaseApprovalListQuery.parse(req.query)),
  );
}
