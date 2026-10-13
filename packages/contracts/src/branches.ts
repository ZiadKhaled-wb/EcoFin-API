import { z } from 'zod';
import { Uuid, Money, IsoTimestamp } from './common.js';
export const BranchCode = z
  .string()
  .trim()
  .transform((s) => s.toUpperCase())
  .pipe(z.string().regex(/^[A-Z0-9]{1,6}$/));
const fields = {
  name: z.string().trim().min(1).max(100),
  address: z.string().nullable().optional(),
  city: z.string().nullable().optional(),
  governorate: z.string().nullable().optional(),
  phone: z.string().nullable().optional(),
  eta_branch_code: z.string().max(20).nullable().optional(),
  /** The ETA receipt's branch address needs it (T02). */
  building_number: z.string().trim().max(100).nullable().optional(),
};
export const BranchCreateBody = z.object({ ...fields, code: BranchCode }).strict();
export type BranchCreateBody = z.infer<typeof BranchCreateBody>;
export const BranchUpdateBody = z
  .object({ ...fields, default_cash_account_id: Uuid.nullable().optional() })
  .strict();
export type BranchUpdateBody = z.infer<typeof BranchUpdateBody>;
export const BranchIdParams = z.object({ id: Uuid }).strict();
export const BranchIdResponse = z.object({ id: Uuid });
export const BranchActiveResponse = z.object({ id: Uuid, is_active: z.boolean() });
export const BranchDeactivateBody = z
  .object({ reason: z.string().trim().min(1), confirm: z.boolean().default(false) })
  .strict();
export type BranchDeactivateBody = z.infer<typeof BranchDeactivateBody>;
export const BranchDeactivationCheck = z
  .object({
    open_shifts: z.number().int().nonnegative(),
    stock_units: z.number().int().nonnegative(),
    cash_balance: Money,
  })
  .strict();
export type BranchDeactivationCheck = z.infer<typeof BranchDeactivationCheck>;
export const BranchSummary = z.object({
  id: Uuid,
  code: z.string(),
  name: z.string(),
  is_main: z.boolean(),
});
export type BranchSummary = z.infer<typeof BranchSummary>;
export const BranchList = z.array(BranchSummary);
export const BranchVault = z.object({ id: Uuid, name: z.string() });
export const ManagedBranch = BranchSummary.extend({
  organization_id: Uuid,
  address: z.string().nullable(),
  city: z.string().nullable(),
  governorate: z.string().nullable(),
  phone: z.string().nullable(),
  eta_branch_code: z.string().nullable(),
  building_number: z.string().nullable(),
  is_active: z.boolean(),
  default_cash_account_id: Uuid.nullable(),
  default_vault: BranchVault.nullable(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
  created_by: Uuid.nullable(),
  updated_by: Uuid.nullable(),
  archived_at: IsoTimestamp.nullable(),
});
export type ManagedBranch = z.infer<typeof ManagedBranch>;
export const ManagedBranchList = z.array(ManagedBranch);
export const BranchDetail = ManagedBranch.extend({ vault_options: z.array(BranchVault) });
export type BranchDetail = z.infer<typeof BranchDetail>;
