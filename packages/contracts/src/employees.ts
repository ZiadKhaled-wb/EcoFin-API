import { z } from 'zod';
import { Uuid, IsoTimestamp } from './common.js';
import { EmployeeRole } from './roles.js';
import { PermissionKey } from './permissions.js';
import { Password, TenantSlug, Username } from './auth.js';
const username = z
  .string()
  .trim()
  .transform((s) => s.toLowerCase())
  .pipe(Username)
  .nullable()
  .optional();
const email = z.string().trim().toLowerCase().email().nullable().optional();
const fields = {
  full_name: z.string().trim().min(1).max(100),
  phone: z.string().nullable().optional(),
  email,
  username,
  role: EmployeeRole,
  default_branch_id: Uuid.nullable().optional(),
};
export const EmployeeOverride = z.object({ key: PermissionKey, granted: z.boolean() }).strict();
export const EmployeeCreateBody = z
  .object({
    ...fields,
    branch_ids: z.array(Uuid).min(1),
    overrides: z.array(EmployeeOverride).default([]),
  })
  .strict()
  .refine((v) => !!v.email || !!v.username, { message: 'Login required', path: ['email'] });
export type EmployeeCreateBody = z.infer<typeof EmployeeCreateBody>;
export const EmployeeUpdateBody = z.object(fields).partial().strict();
export type EmployeeUpdateBody = z.infer<typeof EmployeeUpdateBody>;
export const EmployeeActiveBody = z
  .object({ active: z.boolean(), reason: z.string().trim().min(1).optional() })
  .strict()
  .refine((v) => v.active || !!v.reason, { message: 'Reason required', path: ['reason'] });
export type EmployeeActiveBody = z.infer<typeof EmployeeActiveBody>;
export const EmployeeStatus = z.enum(['active', 'inactive', 'pending', 'expired']);
export const EmployeesQuery = z
  .object({
    search: z.string().trim().optional(),
    role: EmployeeRole.optional(),
    status: EmployeeStatus.optional(),
    page: z.coerce.number().int().min(1).default(1),
    page_size: z.coerce.number().int().min(1).max(100).default(50),
  })
  .strict();
export type EmployeesQuery = z.infer<typeof EmployeesQuery>;
export const EmployeeRow = z.object({
  id: Uuid,
  full_name: z.string(),
  phone: z.string().nullable(),
  email: z.string().email().nullable(),
  username: z.string().nullable(),
  role: EmployeeRole,
  is_active: z.boolean(),
  default_branch_id: Uuid.nullable(),
  branch_ids: z.array(Uuid),
  invite_status: z.enum(['accepted', 'pending', 'expired', 'none']),
  override_count: z.number().int().nonnegative(),
  created_at: IsoTimestamp,
});
export type EmployeeRow = z.infer<typeof EmployeeRow>;
export const EmployeesResponse = z.object({
  items: z.array(EmployeeRow),
  total: z.number().int().nonnegative(),
});
export const EmployeeUpdateResponse = EmployeeRow.extend({ invite_revoked: z.boolean() });
export const EmployeeActiveResponse = z.object({ id: Uuid, is_active: z.boolean() });
const Delivery = z.enum(['email', 'link']);
export const EmployeeInviteResult = z.object({
  employee_id: Uuid,
  invite_email: z.string().email(),
  delivery: Delivery,
});
export const EmployeeCreateResponse = z.object({
  employee_id: Uuid,
  delivery: Delivery,
  invite_link: z.string().url().optional(),
  email_sent: z.boolean().optional(),
});
export const EmployeeInviteResponse = z.object({
  delivery: Delivery,
  invite_link: z.string().url().optional(),
  invite_expires_at: IsoTimestamp,
  email_sent: z.boolean().optional(),
});
export const EmployeeResetResult = z.object({ delivery: Delivery, email: z.string().email() });
export const EmployeeResetResponse = z.object({
  delivery: Delivery,
  reset_link: z.string().url().optional(),
  expires_at: IsoTimestamp,
  email_sent: z.boolean().optional(),
});
export const PasswordResetLookupBody = z.object({ token: z.string().min(1).max(128) }).strict();
export const PasswordResetCompleteBody = PasswordResetLookupBody.extend({
  password: Password,
}).strict();
export type PasswordResetCompleteBody = z.infer<typeof PasswordResetCompleteBody>;
export const PasswordResetLookupResponse = z.object({
  full_name: z.string(),
  login: z.string(),
  shop_name: z.string(),
});
export const PasswordResetLookupResult = z.union([
  PasswordResetLookupResponse.extend({ status: z.literal('valid'), tenant_slug: TenantSlug }),
  z.object({ status: z.enum(['not_found', 'expired', 'used']) }),
]);
export const PasswordResetCompleteResponse = z.object({
  login: z.string(),
  tenant_slug: TenantSlug,
});

export type EmployeesResponse = z.infer<typeof EmployeesResponse>;
export type EmployeeUpdateResponse = z.infer<typeof EmployeeUpdateResponse>;
export type EmployeeActiveResponse = z.infer<typeof EmployeeActiveResponse>;
export type EmployeeCreateResponse = z.infer<typeof EmployeeCreateResponse>;
export type EmployeeInviteResponse = z.infer<typeof EmployeeInviteResponse>;
export type EmployeeResetResponse = z.infer<typeof EmployeeResetResponse>;
export type PasswordResetLookupResponse = z.infer<typeof PasswordResetLookupResponse>;
export type PasswordResetCompleteResponse = z.infer<typeof PasswordResetCompleteResponse>;
