import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  PayableCashAccountQuery,
  PurchaseApprovalListQuery,
  PurchaseInvoiceApproveBody,
  PurchaseInvoiceCreateBody,
  PurchaseInvoiceIdParams,
  PurchaseInvoiceListQuery,
  PurchaseInvoiceRejectBody,
  PurchaseInvoiceUpdateBody,
  PurchaseOrderCancelBody,
  PurchaseOrderCreateBody,
  PurchaseOrderInvoiceBody,
  PurchaseOrderListQuery,
  PurchaseOrderUpdateBody,
  PurchaseReturnCreateBody,
  PurchaseReturnListQuery,
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
export async function returnable(req: Request, res: Response) {
  res.json(await service.getReturnableInvoice(getCtx(req), id(req)));
}
export async function listReturns(req: Request, res: Response) {
  res.json(
    await service.listPurchaseReturns(getCtx(req), PurchaseReturnListQuery.parse(req.query)),
  );
}
export async function getReturn(req: Request, res: Response) {
  res.json(await service.getPurchaseReturn(getCtx(req), id(req)));
}
export async function postReturn(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(
      await service.postPurchaseReturn(getCtx(req), PurchaseReturnCreateBody.parse(req.body), key),
    );
}
export async function cashAccounts(req: Request, res: Response) {
  const { branch_id } = PayableCashAccountQuery.parse(req.query);
  res.json(await service.listPayableCashAccounts(getCtx(req), branch_id));
}
export async function listOrders(req: Request, res: Response) {
  res.json(await service.listPurchaseOrders(getCtx(req), PurchaseOrderListQuery.parse(req.query)));
}
export async function getOrder(req: Request, res: Response) {
  res.json(await service.getPurchaseOrder(getCtx(req), id(req)));
}
export async function createOrder(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(
      await service.createPurchaseOrder(getCtx(req), PurchaseOrderCreateBody.parse(req.body), key),
    );
}
export async function updateOrder(req: Request, res: Response) {
  res.json(
    await service.updatePurchaseOrder(
      getCtx(req),
      id(req),
      PurchaseOrderUpdateBody.parse(req.body),
    ),
  );
}
export async function sendOrder(req: Request, res: Response) {
  res.json(await service.sendPurchaseOrder(getCtx(req), id(req)));
}
export async function cancelOrder(req: Request, res: Response) {
  const { reason } = PurchaseOrderCancelBody.parse(req.body);
  res.json(await service.cancelPurchaseOrder(getCtx(req), id(req), reason));
}
export async function invoiceOrder(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(
      await service.createInvoiceFromPurchaseOrder(
        getCtx(req),
        id(req),
        PurchaseOrderInvoiceBody.parse(req.body ?? {}),
        key,
      ),
    );
}
