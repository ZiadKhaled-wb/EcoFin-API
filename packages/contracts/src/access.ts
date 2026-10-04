import { z } from 'zod';
import { Uuid } from './common.js';
import { PermissionKey } from './permissions.js';

// F06 · GET /me/permissions
export const MePermissionsResponse = z.object({
  keys: z.array(PermissionKey),
  branchIds: z.array(Uuid),
  /** True for the owner: every branch (`branchIds` then lists every branch id too). */
  allBranches: z.boolean(),
});
export const MePermissions = { response: MePermissionsResponse };
export type MePermissionsResponse = z.infer<typeof MePermissionsResponse>;

// F06 · set one permission override (employee_permission_overrides). The reason goes to the audit row.
export const EmployeePermissionOverrideBody = z
  .object({
    employeeId: Uuid,
    permissionKey: PermissionKey,
    granted: z.boolean(),
    reason: z.string().trim().min(1).max(500),
  })
  .strict();
export const EmployeePermissionOverrideResponse = z.object({
  employeeId: Uuid,
  permissionKey: PermissionKey,
  granted: z.boolean(),
});
export const EmployeePermissionOverride = {
  body: EmployeePermissionOverrideBody,
  response: EmployeePermissionOverrideResponse,
};
export type EmployeePermissionOverrideBody = z.infer<typeof EmployeePermissionOverrideBody>;
export type EmployeePermissionOverrideResponse = z.infer<typeof EmployeePermissionOverrideResponse>;

// F06 · replace an employee's branch list (employee_branches)
export const EmployeeBranchesAssignBody = z
  .object({
    employeeId: Uuid,
    branchIds: z
      .array(Uuid)
      .max(100)
      .refine((ids) => new Set(ids).size === ids.length, 'Duplicate branch ids'),
  })
  .strict();
export const EmployeeBranchesAssignResponse = z.object({
  employeeId: Uuid,
  branchIds: z.array(Uuid),
});
export const EmployeeBranchesAssign = {
  body: EmployeeBranchesAssignBody,
  response: EmployeeBranchesAssignResponse,
};
export type EmployeeBranchesAssignBody = z.infer<typeof EmployeeBranchesAssignBody>;
export type EmployeeBranchesAssignResponse = z.infer<typeof EmployeeBranchesAssignResponse>;
