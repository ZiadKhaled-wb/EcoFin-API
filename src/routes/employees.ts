// server/src/routes/employees.ts  (mounted at /api/employees)
//
//   employee.manage   PUT /:employeeId/permissions   add or remove one permission (F06)
//                     PUT /:employeeId/branches      replace the branch list (F06)
//                     PUT /:employeeId/active        deactivate or reactivate (EC-143)
// The database functions repeat every check (app.require_permission first), so the route
// marker is the early answer, not the only one.
import { Router } from 'express';
import {
  EmployeeActiveSet,
  EmployeeBranchesAssign,
  EmployeePermissionOverride,
} from '@ziadkhaled-wb/contracts';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { requirePermission } from '../middleware/permissions';
import { loadRequestContext } from '../middleware/requestContext';
import { validate } from '../middleware/validate';
import * as employeesController from '../controllers/employees.controller';

const router = Router();

router.put(
  '/:employeeId/permissions',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ params: EmployeePermissionOverride.params, body: EmployeePermissionOverride.body }),
  asyncHandler(employeesController.setPermission),
);

router.put(
  '/:employeeId/branches',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ params: EmployeeBranchesAssign.params, body: EmployeeBranchesAssign.body }),
  asyncHandler(employeesController.setBranches),
);

router.put(
  '/:employeeId/active',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ params: EmployeeActiveSet.params, body: EmployeeActiveSet.body }),
  asyncHandler(employeesController.setActive),
);

export default router;
