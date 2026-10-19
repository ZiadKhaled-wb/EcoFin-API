import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { CashMovementType } from './cash.js';
import { CollectionBody } from './collections.js';
import { compareMoney } from './money.js';

/**
 * N06 collector wallets (D81). A collector takes installment payments in the field. The cash goes
 * into the collector's own wallet (a cash account of kind collector_wallet, made by the first field
 * collection) and stays there until a manager settles it into a safe; anything missing is a
 * shortage, recorded with a reason. There is no collection commission of any kind (collectors are
 * salaried) and nothing is deducted from anyone.
 * Words: wallet (عهدة المحصل), shortage (عجز), settlement (توريد). Never interest.
 */

/** `POST /api/collections/field` (Idempotency-Key): the same body as `POST /api/collections`. */
export const FieldCollectionBody = CollectionBody;
export type FieldCollectionBody = z.infer<typeof FieldCollectionBody>;

const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');
const Reason = z.string().trim().min(3).max(300);

export const WalletCollectorRef = z.object({ id: Uuid, name: z.string() });
export type WalletCollectorRef = z.infer<typeof WalletCollectorRef>;

/** The wallet's latest settlement. */
export const WalletLastSettlement = z.object({
  id: Uuid,
  number: z.string(),
  business_date: BusinessDate,
  handed: Money,
  shortage: Money,
  created_at: IsoTimestamp,
});
export type WalletLastSettlement = z.infer<typeof WalletLastSettlement>;

/** `GET /api/wallets/me`: the caller's own wallet; no collection yet means no wallet and zeros. */
export const MyWallet = z.object({
  wallet: z
    .object({ id: Uuid, name: z.string(), branch_id: Uuid, branch_name: z.string().nullable() })
    .nullable(),
  balance: Money,
  /** Today's field collections of the caller that were not reversed. */
  today: z.object({
    count: z.number().int().nonnegative(),
    /** Everything collected (cash and bank transfers). */
    amount: Money,
    /** The cash part, which went into the wallet. */
    cash: Money,
  }),
  /** Business date of the oldest cash still in the wallet; null when it is empty. */
  oldest_unsettled_date: BusinessDate.nullable(),
  last_settlement: WalletLastSettlement.nullable(),
});
export type MyWallet = z.infer<typeof MyWallet>;

export const WalletRow = z.object({
  id: Uuid,
  name: z.string(),
  is_active: z.boolean(),
  collector: WalletCollectorRef,
  branch_id: Uuid,
  branch_name: z.string().nullable(),
  balance: Money,
  oldest_unsettled_date: BusinessDate.nullable(),
  last_settlement: WalletLastSettlement.nullable(),
});
export type WalletRow = z.infer<typeof WalletRow>;

/** `GET /api/wallets`: `collector.settle` or `cash.view`; the caller's branches. */
export const WalletListQuery = z.object({ branch_id: Uuid.optional() }).strict();
export type WalletListQuery = z.infer<typeof WalletListQuery>;

export const WalletListResponse = z.object({ items: z.array(WalletRow) });
export type WalletListResponse = z.infer<typeof WalletListResponse>;

export const WalletIdParams = z.object({ id: Uuid }).strict();
export type WalletIdParams = z.infer<typeof WalletIdParams>;

/** `GET /api/wallets/:id/movements`: newest first. */
export const WalletMovementQuery = z
  .object({
    from: BusinessDate.optional(),
    to: BusinessDate.optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict();
export type WalletMovementQuery = z.infer<typeof WalletMovementQuery>;

export const WalletMovement = z.object({
  id: Uuid,
  business_date: BusinessDate,
  created_at: IsoTimestamp,
  type: CashMovementType,
  /** + in, - out. */
  amount: Money,
  balance_after: Money,
  source_type: z.string(),
  source_id: Uuid,
  /** The receipt (payment) or settlement (CX) number. */
  source_number: z.string().nullable(),
  note: z.string().nullable(),
  created_by_name: z.string().nullable(),
  /** The settlement this movement belongs to, with its shortage. */
  settlement: z
    .object({ handed: Money, shortage: Money, reason: z.string().nullable() })
    .nullable(),
});
export type WalletMovement = z.infer<typeof WalletMovement>;

export const WalletMovementPage = z.object({
  wallet: WalletRow,
  items: z.array(WalletMovement),
  next_cursor: z.string().nullable(),
});
export type WalletMovementPage = z.infer<typeof WalletMovementPage>;

/**
 * `POST /api/wallets/:id/settle` (Idempotency-Key). `handed` moves from the wallet to a safe of the
 * wallet's branch; `shortage` is only recorded (no deduction). `expected_balance` is the wallet's
 * balance the manager saw; a change since then is WALLET_BALANCE_CHANGED. Partial settlement is
 * allowed (`handed > 0`, `handed + shortage <= balance`); a shortage needs a reason.
 */
export const SettleWalletBody = z
  .object({
    to_account_id: Uuid,
    handed: NonNegativeMoney,
    shortage: NonNegativeMoney.optional(),
    reason: Reason.optional(),
    expected_balance: NonNegativeMoney,
  })
  .strict()
  .superRefine((body, ctx) => {
    if (!Money.safeParse(body.handed).success || compareMoney(body.handed, '0') <= 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['handed'],
        message: 'Hand in something',
      });
    }
    if (
      body.shortage !== undefined &&
      Money.safeParse(body.shortage).success &&
      compareMoney(body.shortage, '0') > 0 &&
      !body.reason
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['reason'],
        message: 'A shortage needs a reason',
      });
    }
  });
export type SettleWalletBody = z.infer<typeof SettleWalletBody>;

export const WalletSettlement = z.object({
  id: Uuid,
  number: z.string(),
  business_date: BusinessDate,
  wallet_id: Uuid,
  wallet_name: z.string(),
  collector: WalletCollectorRef,
  to_account_id: Uuid,
  to_account_name: z.string(),
  handed: Money,
  shortage: Money,
  reason: z.string().nullable(),
  /** The wallet's balance after this settlement. */
  balance_after: Money,
  created_by_name: z.string().nullable(),
  created_at: IsoTimestamp,
});
export type WalletSettlement = z.infer<typeof WalletSettlement>;

/** Details of `WALLET_BALANCE_CHANGED` and of `INSUFFICIENT_FUNDS` on a settlement. */
export const WalletBalanceDetail = z.object({ balance: Money });
export type WalletBalanceDetail = z.infer<typeof WalletBalanceDetail>;

/** `PUT /api/customers/:id/collector`: assign, change or clear (null) the customer's collector. */
export const SetCustomerCollectorBody = z
  .object({ employee_id: Uuid.nullable(), reason: Reason.optional() })
  .strict();
export type SetCustomerCollectorBody = z.infer<typeof SetCustomerCollectorBody>;

/** `GET /api/collectors/route`: a collector only reads their own; `collector.settle` any. */
export const CollectorRouteQuery = z
  .object({ employee_id: Uuid.optional(), date: BusinessDate.optional() })
  .strict();
export type CollectorRouteQuery = z.infer<typeof CollectorRouteQuery>;

export const CollectorRouteContract = z.object({
  id: Uuid,
  number: z.string(),
  amount_due: Money,
  amount_overdue: Money,
});
export type CollectorRouteContract = z.infer<typeof CollectorRouteContract>;

export const CollectorRouteStop = z.object({
  customer: z.object({
    id: Uuid,
    name: z.string(),
    phone: z.string().nullable(),
    address: z.string().nullable(),
    city: z.string().nullable(),
  }),
  /** Due on or before the date (the overdue part included). */
  amount_due: Money,
  amount_overdue: Money,
  max_days_late: z.number().int().nonnegative(),
  next_due_date: BusinessDate.nullable(),
  contracts: z.array(CollectorRouteContract),
});
export type CollectorRouteStop = z.infer<typeof CollectorRouteStop>;

export const CollectorRoute = z.object({
  employee_id: Uuid,
  employee_name: z.string().nullable(),
  date: BusinessDate,
  /** Sorted by city, address, name. */
  stops: z.array(CollectorRouteStop),
  totals: z.object({
    customers: z.number().int().nonnegative(),
    amount_due: Money,
    amount_overdue: Money,
  }),
});
export type CollectorRoute = z.infer<typeof CollectorRoute>;
