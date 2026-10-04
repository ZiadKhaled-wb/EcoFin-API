import { z } from 'zod';

/** Exactly the values of `public.employee_role` in the API baseline. */
export const EMPLOYEE_ROLES = [
  'OWNER',
  'BRANCH_MANAGER',
  'CASHIER',
  'WAREHOUSE',
  'COLLECTOR',
  'ACCOUNTANT',
  'LAWYER',
] as const;

export const EmployeeRole = z.enum(EMPLOYEE_ROLES);
export type EmployeeRole = z.infer<typeof EmployeeRole>;

/**
 * Super Admin is not an `employee_role`. The baseline models it as a separate platform table
 * (`public.super_admins`, checked by `app.is_super_admin()`), so it is a separate constant here.
 */
export const PLATFORM_ROLE_SUPER_ADMIN = 'SUPER_ADMIN' as const;
export type PlatformRole = typeof PLATFORM_ROLE_SUPER_ADMIN;
