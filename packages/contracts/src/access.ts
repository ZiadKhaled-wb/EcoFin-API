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

/** Reason stored on the audit row of an access change (required). */
const AuditReason = z.string().trim().min(1).max(500);

// F06 · path params of /employees/:employeeId/... (0.2.0: the id lives in the path, not the body)
export const EmployeeIdParams = z.object({ employeeId: Uuid }).strict();
export type EmployeeIdParams = z.infer<typeof EmployeeIdParams>;

// F06 · PUT /employees/:employeeId/permissions: set one permission override
// (employee_permission_overrides). The reason goes to the audit row.
export const EmployeePermissionOverrideBody = z
  .object({
    permissionKey: PermissionKey,
    granted: z.boolean(),
    reason: AuditReason,
  })
  .strict();
export const EmployeePermissionOverrideResponse = z.object({
  employeeId: Uuid,
  permissionKey: PermissionKey,
  granted: z.boolean(),
});
export const EmployeePermissionOverride = {
  params: EmployeeIdParams,
  body: EmployeePermissionOverrideBody,
  response: EmployeePermissionOverrideResponse,
};
export type EmployeePermissionOverrideBody = z.infer<typeof EmployeePermissionOverrideBody>;
export type EmployeePermissionOverrideResponse = z.infer<typeof EmployeePermissionOverrideResponse>;

// F06 · PUT /employees/:employeeId/branches: replace an employee's branch list (employee_branches)
export const EmployeeBranchesAssignBody = z
  .object({
    branchIds: z
      .array(Uuid)
      .max(100)
      .refine((ids) => new Set(ids).size === ids.length, 'Duplicate branch ids'),
    reason: AuditReason,
  })
  .strict();
export const EmployeeBranchesAssignResponse = z.object({
  employeeId: Uuid,
  branchIds: z.array(Uuid),
});
export const EmployeeBranchesAssign = {
  params: EmployeeIdParams,
  body: EmployeeBranchesAssignBody,
  response: EmployeeBranchesAssignResponse,
};
export type EmployeeBranchesAssignBody = z.infer<typeof EmployeeBranchesAssignBody>;
export type EmployeeBranchesAssignResponse = z.infer<typeof EmployeeBranchesAssignResponse>;
