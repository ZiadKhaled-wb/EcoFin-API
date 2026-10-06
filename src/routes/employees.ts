// server/src/routes/employees.ts  (mounted at /api/employees)
//
//   employee.manage   PUT /:employeeId/permissions   add or remove one permission (F06)
//                     PUT /:employeeId/branches      replace the branch list (F06)
// The database functions repeat every check (app.require_permission first), so the route
// marker is the early answer, not the only one.
import { Router } from 'express';
import {
  EmployeeBranchesAssign,
  EmployeePermissionOverride,
  EmployeeCreateBody,
  EmployeeUpdateBody,
  EmployeeActiveBody,
  EmployeeIdParams,
  EmployeesQuery,
} from '@ziadkhaled-wb/contracts';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { requirePermission } from '../middleware/permissions';
import { loadRequestContext } from '../middleware/requestContext';
import { validate } from '../middleware/validate';
import * as employeesController from '../controllers/employees.controller';

import * as staff from '../controllers/staff.controller';
const router = Router();
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ query: EmployeesQuery }),
  asyncHandler(staff.list),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ body: EmployeeCreateBody }),
  asyncHandler(staff.create),
);
router.patch(
  '/:employeeId',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ params: EmployeeIdParams, body: EmployeeUpdateBody }),
  asyncHandler(staff.update),
);
router.put(
  '/:employeeId/active',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ params: EmployeeIdParams, body: EmployeeActiveBody }),
  asyncHandler(staff.active),
);
router.post(
  '/:employeeId/invite',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ params: EmployeeIdParams }),
  asyncHandler(staff.invite),
);
router.post(
  '/:employeeId/password-reset',
  authenticate,
  loadRequestContext,
  requirePermission('employee.manage'),
  validate({ params: EmployeeIdParams }),
  asyncHandler(staff.reset),
);

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

export default router;
