// server/src/services/employees.service.ts
//
// F06: an owner (or anyone granted employee.manage) changes one employee's access. The database
// functions do the real work and the real checks (permission, same shop, not the owner, not
// yourself, reason, one audit row); this layer adds the F05 same-shop check up front and turns
// DB errors into contract codes.

import type {
  EmployeeActiveSetBody,
  EmployeeActiveSetResponse,
  EmployeeBranchesAssignBody,
  EmployeeBranchesAssignResponse,
  EmployeePermissionOverrideBody,
  EmployeePermissionOverrideResponse,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { ServerError, mapDbError } from '../utils/errors';
import { logger } from '../utils/logger';
import { assertSameOrg } from '../utils/tenant';

function fail(err: unknown, what: string): never {
  const mapped = mapDbError(err);
  if (mapped) throw mapped;
  logger.error({ err }, `${what} failed`);
  throw ServerError('Request failed.');
}

export async function setEmployeePermission(
  ctx: RequestContext,
  employeeId: string,
  body: EmployeePermissionOverrideBody,
): Promise<EmployeePermissionOverrideResponse> {
  await assertSameOrg(ctx, 'employees', [employeeId]);
  const { data, error } = await ctx.db
    .rpc('set_employee_permission', {
      p_employee_id: employeeId,
      p_permission_key: body.permissionKey,
      p_granted: body.granted,
      p_reason: body.reason,
    })
    .single();
  if (error) fail(error, 'set_employee_permission');
  return { employeeId: data.employee_id, permissionKey: body.permissionKey, granted: data.granted };
}

export async function setEmployeeBranches(
  ctx: RequestContext,
  employeeId: string,
  body: EmployeeBranchesAssignBody,
): Promise<EmployeeBranchesAssignResponse> {
  await assertSameOrg(ctx, 'employees', [employeeId]);
  const { data, error } = await ctx.db
    .rpc('set_employee_branches', {
      p_employee_id: employeeId,
      p_branch_ids: body.branchIds,
      p_reason: body.reason,
    })
    .single();
  if (error) fail(error, 'set_employee_branches');
  return { employeeId: data.employee_id, branchIds: data.branch_ids };
}

/** EC-143: deactivate or reactivate an employee (refused on their next request when off). */
export async function setEmployeeActive(
  ctx: RequestContext,
  employeeId: string,
  body: EmployeeActiveSetBody,
): Promise<EmployeeActiveSetResponse> {
  await assertSameOrg(ctx, 'employees', [employeeId]);
  const { data, error } = await ctx.db
    .rpc('set_employee_active', {
      p_employee_id: employeeId,
      p_active: body.active,
      p_reason: body.reason,
    })
    .single();
  if (error) fail(error, 'set_employee_active');
  return { employeeId: data.employee_id, active: data.is_active };
}
