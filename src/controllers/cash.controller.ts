import type { Request, Response } from 'express';
import {
  CashAccountCreateBody,
  CashAccountIdParams,
  CashAccountUpdateBody,
  CashLedgerQuery,
  CashOpeningBody,
  CashTransferCreateBody,
  IdempotencyKeyHeader,
  type CashAccountListQuery,
  type CashTransferListQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/cash.service';
const id = (req: Request) => CashAccountIdParams.parse(req.params).id;
/** Money writes take the `Idempotency-Key` header (8-128 characters); missing = 400. */
const keyOf = (req: Request) => IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
/** validate() already parsed the query with the contract (defaults filled). */
export async function listAccounts(req: Request, res: Response) {
  res.json(
    await service.listCashAccounts(getCtx(req), req.query as unknown as CashAccountListQuery),
  );
}
export async function getAccount(req: Request, res: Response) {
  res.json(await service.getCashAccount(getCtx(req), id(req)));
}
export async function ledger(req: Request, res: Response) {
  res.json(await service.getCashLedger(getCtx(req), id(req), CashLedgerQuery.parse(req.query)));
}
export async function createAccount(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.createCashAccount(getCtx(req), CashAccountCreateBody.parse(req.body)));
}
export async function renameAccount(req: Request, res: Response) {
  const { name } = CashAccountUpdateBody.parse(req.body);
  res.json(await service.renameCashAccount(getCtx(req), id(req), name));
}
export async function deactivate(req: Request, res: Response) {
  res.json(await service.setCashAccountActive(getCtx(req), id(req), false));
}
export async function reactivate(req: Request, res: Response) {
  res.json(await service.setCashAccountActive(getCtx(req), id(req), true));
}
export async function opening(req: Request, res: Response) {
  res.json(
    await service.postCashOpening(
      getCtx(req),
      id(req),
      CashOpeningBody.parse(req.body),
      keyOf(req),
    ),
  );
}
export async function listTransfers(req: Request, res: Response) {
  res.json(
    await service.listCashTransfers(getCtx(req), req.query as unknown as CashTransferListQuery),
  );
}
export async function getTransfer(req: Request, res: Response) {
  res.json(await service.getCashTransfer(getCtx(req), id(req)));
}
export async function createTransfer(req: Request, res: Response) {
  res
    .status(201)
    .json(
      await service.createCashTransfer(
        getCtx(req),
        CashTransferCreateBody.parse(req.body),
        keyOf(req),
      ),
    );
}
