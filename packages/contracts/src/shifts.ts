import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import { PositiveMoney } from './cash.js';

/**
 * K02 shifts / cash drawer (D60). A cashier opens a shift with a float taken from a safe of the
 * branch; every cash movement of the shift is on the shift's drawer, so expected cash is the
 * shift's drawer ledger sum. Closing counts the cash by denomination; a difference needs a reason.
 */
export const ShiftStatus = z.enum(['open', 'closed']);
export type ShiftStatus = z.infer<typeof ShiftStatus>;

/** Egyptian notes and coins a count is made of. */
export const SHIFT_DENOMINATIONS = [
  '200',
  '100',
  '50',
  '20',
  '10',
  '5',
  '1',
  '0.5',
  '0.25',
] as const;
export const ShiftDenomination = z.enum(SHIFT_DENOMINATIONS);
export type ShiftDenomination = z.infer<typeof ShiftDenomination>;

/** How many of each note or coin: {"200": 5, "100": 3}. Missing ones count as 0. */
export const ShiftCounts = z.record(ShiftDenomination, z.number().int().min(0).max(100_000));
export type ShiftCounts = z.infer<typeof ShiftCounts>;

const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');
const hasMoney = (v: string) => /[1-9]/.test(v);

/** `Idempotency-Key` header. A float above 0 leaves `vault_id` (a safe of the branch). */
export const ShiftOpenBody = z
  .object({
    branch_id: Uuid,
    opening_float: NonNegativeMoney,
    vault_id: Uuid.optional(),
    device_id: Uuid.optional(),
  })
  .strict()
  .refine((b) => hasMoney(b.opening_float) === (b.vault_id !== undefined), {
    message: 'A float needs the safe it comes from; no float, no safe',
    path: ['vault_id'],
  });
export type ShiftOpenBody = z.infer<typeof ShiftOpenBody>;

/** `Idempotency-Key` header. `in`: from the safe into the drawer; `out`: from the drawer into the safe. */
export const ShiftCashBody = z
  .object({
    direction: z.enum(['in', 'out']),
    amount: PositiveMoney,
    vault_id: Uuid,
    note: z.string().trim().min(3).max(500),
  })
  .strict();
export type ShiftCashBody = z.infer<typeof ShiftCashBody>;

/** The counted cash goes to `vault_id` (needed when anything was counted). */
export const ShiftCloseBody = z
  .object({
    counts: ShiftCounts,
    vault_id: Uuid.optional(),
    /** Required by the server when counted ≠ expected. */
    difference_reason: z.string().trim().max(500).optional(),
  })
  .strict();
export type ShiftCloseBody = z.infer<typeof ShiftCloseBody>;

export const ShiftIdParams = z.object({ id: Uuid }).strict();
export type ShiftIdParams = z.infer<typeof ShiftIdParams>;

/** One row of the shift's drawer ledger. */
export const ShiftMovement = z.object({
  id: Uuid,
  created_at: IsoTimestamp,
  type: z.string(),
  /** Signed: money in is positive. */
  amount: Money,
  source_type: z.string(),
  /** The cash transfer number (CX) for floats, pay-ins, pay-outs and the closing. */
  source_number: z.string().nullable(),
  note: z.string().nullable(),
});
export type ShiftMovement = z.infer<typeof ShiftMovement>;

const shiftHeader = {
  id: Uuid,
  number: z.string(),
  branch_id: Uuid,
  device_id: Uuid.nullable(),
  device_name: z.string().nullable(),
  employee_id: Uuid,
  employee_name: z.string(),
  drawer_account_id: Uuid,
  status: ShiftStatus,
  opening_float: Money,
  opened_at: IsoTimestamp,
  closed_at: IsoTimestamp.nullable(),
  closed_by_name: z.string().nullable(),
  /** Open: the drawer ledger sum now. Closed: what it was at closing. */
  expected_cash: Money,
  counted_cash: Money.nullable(),
  /** counted − expected (closed shifts). */
  difference: Money.nullable(),
  count_breakdown: z.record(z.string(), z.number()).nullable(),
  difference_reason: z.string().nullable(),
};
export const Shift = z.object({ ...shiftHeader, movements: z.array(ShiftMovement) });
export type Shift = z.infer<typeof Shift>;
export const ShiftSummary = z.object(shiftHeader);
export type ShiftSummary = z.infer<typeof ShiftSummary>;
export const ShiftList = paginated(ShiftSummary);
export type ShiftList = z.infer<typeof ShiftList>;
/** `GET /api/shifts/current`: the caller's open shift, or null. */
export const CurrentShift = z.object({ shift: Shift.nullable() });
export type CurrentShift = z.infer<typeof CurrentShift>;

export const ShiftListQuery = PaginationQuery.extend({
  branch_id: Uuid.optional(),
  employee_id: Uuid.optional(),
  status: ShiftStatus.optional(),
  /** The shop day the shift was opened on. */
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
})
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['from'],
  });
export type ShiftListQuery = z.infer<typeof ShiftListQuery>;

/** A safe of the branch a float can come from or cash can go to (no balance: cashiers see it). */
export const ShiftVault = z.object({ id: Uuid, name: z.string() });
export type ShiftVault = z.infer<typeof ShiftVault>;
export const ShiftVaultList = z.object({ items: z.array(ShiftVault) });
export type ShiftVaultList = z.infer<typeof ShiftVaultList>;
export const ShiftVaultQuery = z.object({ branch_id: Uuid }).strict();
export type ShiftVaultQuery = z.infer<typeof ShiftVaultQuery>;

/** Details of SHIFT_DIFFERENCE_REASON_REQUIRED. */
export const ShiftDifferenceDetail = z.object({
  expected: Money,
  counted: Money,
  difference: Money,
});
export type ShiftDifferenceDetail = z.infer<typeof ShiftDifferenceDetail>;

/** The cash a count adds up to, as money ("640.00"). Exact: works in quarter pounds. */
export function shiftCountTotal(counts: ShiftCounts): string {
  let quarters = 0;
  for (const d of SHIFT_DENOMINATIONS) quarters += Math.round(Number(d) * 4) * (counts[d] ?? 0);
  const whole = Math.floor(quarters / 4);
  return `${whole}.${['00', '25', '50', '75'][quarters % 4]}`;
}
