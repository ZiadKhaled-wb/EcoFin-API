// server/src/controllers/employees.controller.ts
//
// Thin handlers: validate() already parsed params and body with the contract schemas.
import type { Request, Response } from 'express';
import type {
  EmployeeActiveSetBody,
  EmployeeBranchesAssignBody,
  EmployeeIdParams,
  EmployeePermissionOverrideBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as employeesService from '../services/employees.service';

/** PUT /api/employees/:employeeId/permissions */
export async function setPermission(req: Request, res: Response) {
  const { employeeId } = req.params as EmployeeIdParams;
  const body = req.body as EmployeePermissionOverrideBody;
  res.json(await employeesService.setEmployeePermission(getCtx(req), employeeId, body));
}

/** PUT /api/employees/:employeeId/branches */
export async function setBranches(req: Request, res: Response) {
  const { employeeId } = req.params as EmployeeIdParams;
  const body = req.body as EmployeeBranchesAssignBody;
  res.json(await employeesService.setEmployeeBranches(getCtx(req), employeeId, body));
}

/** PUT /api/employees/:employeeId/active */
export async function setActive(req: Request, res: Response) {
  const { employeeId } = req.params as EmployeeIdParams;
  const body = req.body as EmployeeActiveSetBody;
  res.json(await employeesService.setEmployeeActive(getCtx(req), employeeId, body));
}
