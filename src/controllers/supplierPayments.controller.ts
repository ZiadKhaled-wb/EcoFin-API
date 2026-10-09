import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  OpenSupplierInvoiceQuery,
  SupplierPaymentCreateBody,
  SupplierPaymentIdParams,
  SupplierPaymentListQuery,
  SupplierPaymentReverseBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/supplierPayments.service';
const id = (req: Request) => SupplierPaymentIdParams.parse(req.params).id;
const keyOf = (req: Request) => IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
export async function list(req: Request, res: Response) {
  res.json(
    await service.listSupplierPayments(getCtx(req), SupplierPaymentListQuery.parse(req.query)),
  );
}
export async function openInvoices(req: Request, res: Response) {
  const { supplier_id } = OpenSupplierInvoiceQuery.parse(req.query);
  res.json(await service.listOpenSupplierInvoices(getCtx(req), supplier_id));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getSupplierPayment(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(
      await service.postSupplierPayment(
        getCtx(req),
        SupplierPaymentCreateBody.parse(req.body),
        key,
      ),
    );
}
export async function reverse(req: Request, res: Response) {
  const key = keyOf(req);
  const { reason } = SupplierPaymentReverseBody.parse(req.body);
  res.json(await service.reverseSupplierPayment(getCtx(req), id(req), reason, key));
}
