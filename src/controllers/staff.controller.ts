import type { Request, Response } from 'express';
import {
  EmployeeCreateBody,
  EmployeeUpdateBody,
  EmployeeActiveBody,
  EmployeeIdParams,
  EmployeesQuery,
  PasswordResetLookupBody,
  PasswordResetCompleteBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import { requestMeta } from '../middleware/auth';
import * as staff from '../services/staff.service';
import * as resets from '../services/passwordResets.service';
const id = (req: Request) => EmployeeIdParams.parse(req.params).employeeId;
export async function list(req: Request, res: Response) {
  res.json(await staff.listEmployees(getCtx(req), EmployeesQuery.parse(req.query)));
}
export async function create(req: Request, res: Response) {
  res.status(201).json(await staff.createEmployee(getCtx(req), EmployeeCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(await staff.updateEmployee(getCtx(req), id(req), EmployeeUpdateBody.parse(req.body)));
}
export async function active(req: Request, res: Response) {
  res.json(await staff.setEmployeeActive(getCtx(req), id(req), EmployeeActiveBody.parse(req.body)));
}
export async function invite(req: Request, res: Response) {
  res.json(await staff.resendEmployeeInvite(getCtx(req), id(req)));
}
export async function reset(req: Request, res: Response) {
  res.json(await staff.resetEmployeePassword(getCtx(req), id(req)));
}
export async function lookupReset(req: Request, res: Response) {
  res.json(
    await resets.lookupPasswordReset(
      PasswordResetLookupBody.parse(req.body).token,
      requestMeta(req),
    ),
  );
}
export async function completeReset(req: Request, res: Response) {
  res.json(
    await resets.completePasswordReset(PasswordResetCompleteBody.parse(req.body), requestMeta(req)),
  );
}
