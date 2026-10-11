import type { Request, Response } from 'express';
import {
  DiscountApprovalDecideBody,
  DiscountApprovalIdParams,
  DiscountApprovalListQuery,
  DiscountApprovalRequestBody,
  IdempotencyKeyHeader,
  SaleCreateBody,
  SaleIdParams,
  SaleQuoteBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/sales.service';
export async function quote(req: Request, res: Response) {
  res.json(await service.quoteSale(getCtx(req), SaleQuoteBody.parse(req.body)));
}
export async function create(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res.status(201).json(await service.postSale(getCtx(req), SaleCreateBody.parse(req.body), key));
}
export async function paymentAccounts(req: Request, res: Response) {
  res.json(await service.listPaymentAccounts(getCtx(req)));
}

export async function get(req: Request, res: Response) {
  res.json(await service.getSale(getCtx(req), SaleIdParams.parse(req.params).id));
}

// S03 (D65): the over-cap discount approval.
export async function requestApproval(req: Request, res: Response) {
  res
    .status(201)
    .json(
      await service.requestDiscountApproval(
        getCtx(req),
        DiscountApprovalRequestBody.parse(req.body),
      ),
    );
}

export async function getApproval(req: Request, res: Response) {
  res.json(
    await service.getDiscountApproval(getCtx(req), DiscountApprovalIdParams.parse(req.params).id),
  );
}

export async function cancelApproval(req: Request, res: Response) {
  res.json(
    await service.cancelDiscountApproval(
      getCtx(req),
      DiscountApprovalIdParams.parse(req.params).id,
    ),
  );
}

export async function listApprovals(req: Request, res: Response) {
  res.json(
    await service.listDiscountApprovals(getCtx(req), DiscountApprovalListQuery.parse(req.query)),
  );
}

export async function decideApproval(req: Request, res: Response) {
  res.json(
    await service.decideDiscountApproval(
      getCtx(req),
      DiscountApprovalIdParams.parse(req.params).id,
      DiscountApprovalDecideBody.parse(req.body),
    ),
  );
}
