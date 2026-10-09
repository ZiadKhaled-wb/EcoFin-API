import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';

/**
 * K01 vaults (D56). Safes (one branch each) and bank accounts (one branch or shop-wide, `branch_id`
 * null). Drawers (K02) and collector wallets (N06) are not managed or listed here. `balance` comes
 * from the cash ledger (`cash_balances`); `is_default` marks a branch's default vault (O01).
 */
export const CashAccountKind = z.enum(['safe', 'bank']);
export type CashAccountKind = z.infer<typeof CashAccountKind>;
export const CashAccountStatus = z.enum(['active', 'inactive', 'all']);
export type CashAccountStatus = z.infer<typeof CashAccountStatus>;

export const CashAccount = z.object({
  id: Uuid,
  name: z.string(),
  kind: CashAccountKind,
  branch_id: Uuid.nullable(),
  branch_name: z.string().nullable(),
  is_active: z.boolean(),
  archived_at: IsoTimestamp.nullable(),
  balance: Money,
  is_default: z.boolean(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
});
export type CashAccount = z.infer<typeof CashAccount>;
/** A shop has few accounts: no paging. */
export const CashAccountList = z.array(CashAccount);
export type CashAccountList = z.infer<typeof CashAccountList>;

export const CashAccountListQuery = z
  .object({
    status: CashAccountStatus.default('active'),
    branch_id: Uuid.optional(),
    kind: CashAccountKind.optional(),
  })
  .strict();
export type CashAccountListQuery = z.infer<typeof CashAccountListQuery>;

const accountName = z.string().trim().min(1).max(100);

/** A safe needs a branch; a bank may be shop-wide (`branch_id: null`). Kind and branch are fixed. */
export const CashAccountCreateBody = z
  .object({ name: accountName, kind: CashAccountKind, branch_id: Uuid.nullable() })
  .strict()
  .refine((b) => b.kind !== 'safe' || b.branch_id !== null, {
    message: 'A safe needs a branch',
    path: ['branch_id'],
  });
export type CashAccountCreateBody = z.infer<typeof CashAccountCreateBody>;

export const CashAccountUpdateBody = z.object({ name: accountName }).strict();
export type CashAccountUpdateBody = z.infer<typeof CashAccountUpdateBody>;

export const CashAccountIdParams = z.object({ id: Uuid }).strict();
export type CashAccountIdParams = z.infer<typeof CashAccountIdParams>;

/** An amount of money above zero. */
export const PositiveMoney = Money.refine(
  (v) => !v.startsWith('-') && /[1-9]/.test(v),
  'Must be more than 0',
);

/** One opening balance on an account with no movements yet (`Idempotency-Key` header). */
export const CashOpeningBody = z
  .object({ amount: PositiveMoney, note: z.string().trim().min(3).max(500) })
  .strict();
export type CashOpeningBody = z.infer<typeof CashOpeningBody>;

/** `Idempotency-Key` header. Both accounts active safes or banks of the shop. */
export const CashTransferCreateBody = z
  .object({
    from_account_id: Uuid,
    to_account_id: Uuid,
    amount: PositiveMoney,
    note: z
      .string()
      .trim()
      .max(500)
      .optional()
      .transform((v) => (v ? v : undefined)),
  })
  .strict()
  .refine((b) => b.from_account_id !== b.to_account_id, {
    message: 'Choose two different accounts',
    path: ['to_account_id'],
  });
export type CashTransferCreateBody = z.infer<typeof CashTransferCreateBody>;
export type CashTransferCreateInput = z.input<typeof CashTransferCreateBody>;

export const CashTransfer = z.object({
  id: Uuid,
  number: z.string(),
  from_account_id: Uuid,
  from_account_name: z.string(),
  to_account_id: Uuid,
  to_account_name: z.string(),
  amount: Money,
  note: z.string().nullable(),
  business_date: BusinessDate,
  created_by_name: z.string().nullable(),
  created_at: IsoTimestamp,
});
export type CashTransfer = z.infer<typeof CashTransfer>;
export const CashTransferList = paginated(CashTransfer);
export type CashTransferList = z.infer<typeof CashTransferList>;

const datesInOrder = (q: { from?: string | undefined; to?: string | undefined }) =>
  q.from === undefined || q.to === undefined || q.from <= q.to;
const datesMessage = { message: '`from` must not be after `to`', path: ['from'] };

export const CashTransferListQuery = PaginationQuery.extend({
  account_id: Uuid.optional(),
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
})
  .strict()
  .refine(datesInOrder, datesMessage);
export type CashTransferListQuery = z.infer<typeof CashTransferListQuery>;

/** The baseline `cash_movement_type` enum. */
export const CashMovementType = z.enum([
  'float_in',
  'float_out',
  'sale',
  'refund',
  'deposit',
  'collection',
  'supplier_payment',
  'supplier_refund',
  'expense',
  'transfer_in',
  'transfer_out',
  'settlement',
  'adjustment',
  'opening',
]);
export type CashMovementType = z.infer<typeof CashMovementType>;

/** One ledger row: `amount` is signed (+ in, − out); `balance_after` runs over the whole ledger. */
export const CashLedgerRow = z.object({
  id: Uuid,
  business_date: BusinessDate,
  created_at: IsoTimestamp,
  type: CashMovementType,
  amount: Money,
  balance_after: Money,
  source_type: z.string(),
  source_id: Uuid,
  source_number: z.string().nullable(),
  note: z.string().nullable(),
  created_by_name: z.string().nullable(),
});
export type CashLedgerRow = z.infer<typeof CashLedgerRow>;

/** Newest first. Without dates the closing balance equals the account's balance. */
export const CashLedger = z.object({
  account: CashAccount,
  from: BusinessDate.nullable(),
  to: BusinessDate.nullable(),
  opening_balance: Money,
  closing_balance: Money,
  items: z.array(CashLedgerRow),
  page: z.number().int().positive(),
  pageSize: z.number().int().positive(),
  total: z.number().int().nonnegative(),
});
export type CashLedger = z.infer<typeof CashLedger>;

export const CashLedgerQuery = PaginationQuery.extend({
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
})
  .strict()
  .refine(datesInOrder, datesMessage);
export type CashLedgerQuery = z.infer<typeof CashLedgerQuery>;
