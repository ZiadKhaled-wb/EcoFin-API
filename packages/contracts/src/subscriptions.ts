import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { compareMoney } from './money.js';
export const SUBSCRIPTION_WARNING_DAYS = 14;
export const MODULE_KEYS = [
  'pos',
  'inventory',
  'purchasing',
  'cash',
  'eta',
  'installments',
  'customers',
  'serials',
  'delivery',
  'legal',
  'reports',
  'import_export',
] as const;
export const ModuleKey = z.enum(MODULE_KEYS);
export type ModuleKey = z.infer<typeof ModuleKey>;
export const SubscriptionState = z.enum(['no_end', 'active', 'expiring', 'expired']);
export type SubscriptionState = z.infer<typeof SubscriptionState>;
export const PlanResource = z.enum(['branches', 'users', 'devices']);
export type PlanResource = z.infer<typeof PlanResource>;
export const PlanLimitDetail = z
  .object({
    resource: PlanResource,
    limit: z.number().int().nonnegative(),
    used: z.number().int().nonnegative(),
  })
  .strict();
export const PlanDowngradeDetail = z.array(PlanLimitDetail);
export const ResourceUsage = z.object({
  used: z.number().int().nonnegative(),
  limit: z.number().int().nonnegative().nullable(),
});
export const SubscriptionUsage = z.object({
  branches: ResourceUsage,
  users: ResourceUsage,
  devices: ResourceUsage,
  modules: z.array(ModuleKey),
});
export type SubscriptionUsage = z.infer<typeof SubscriptionUsage>;
export const SubscriptionStatus = z.object({
  plan_key: z.string(),
  plan_name: z.string(),
  subscription_end: BusinessDate.nullable(),
  days_left: z.number().int().nullable(),
  state: SubscriptionState,
  read_only: z.boolean(),
  usage: SubscriptionUsage,
  modules: z.array(ModuleKey),
});
export type SubscriptionStatus = z.infer<typeof SubscriptionStatus>;
export const SubscriptionPayment = z.object({
  id: Uuid,
  plan_key: z.string(),
  amount: Money,
  period_start: BusinessDate,
  period_end: BusinessDate,
  paid_at: IsoTimestamp,
  reference: z.string().nullable(),
});
export const AdminSubscription = SubscriptionStatus.extend({
  subscription_start: BusinessDate.nullable(),
  plan: z.object({
    key: z.string(),
    name: z.string(),
    max_branches: z.number().int().nullable(),
    max_users: z.number().int().nullable(),
    max_devices: z.number().int().nullable(),
    modules: z.array(ModuleKey),
  }),
  payments: z.array(SubscriptionPayment),
});
export type AdminSubscription = z.infer<typeof AdminSubscription>;
const Reason = z.string().trim().min(1).max(1000);
export const SubscriptionPlanBody = z
  .object({ plan_key: z.string().min(1).max(64), reason: Reason })
  .strict();
export type SubscriptionPlanBody = z.infer<typeof SubscriptionPlanBody>;
export const SubscriptionPlanResponse = z.object({ plan_key: z.string() });
export const SubscriptionDatesBody = z
  .object({ start: BusinessDate, end: BusinessDate.nullable(), reason: Reason })
  .strict()
  .refine((v) => v.end === null || v.end >= v.start, {
    path: ['end'],
    message: 'End precedes start',
  });
export type SubscriptionDatesBody = z.infer<typeof SubscriptionDatesBody>;
export const SubscriptionDatesResponse = z.object({
  start: BusinessDate,
  end: BusinessDate.nullable(),
});
export const SubscriptionPaymentBody = z
  .object({
    amount: Money.pipe(
      z.string().refine((v) => compareMoney(v, '0') > 0, 'Amount must be positive'),
    ),
    period_start: BusinessDate,
    period_end: BusinessDate,
    reference: z.string().trim().max(200).optional(),
    extend: z.boolean().default(true),
  })
  .strict()
  .refine((v) => v.period_end >= v.period_start, {
    path: ['period_end'],
    message: 'End precedes start',
  });
export type SubscriptionPaymentBody = z.infer<typeof SubscriptionPaymentBody>;
export const SubscriptionPaymentResponse = z.object({
  payment_id: Uuid,
  subscription_end: BusinessDate.nullable(),
});
export const SubscriptionPaymentHeader = z.object({ 'idempotency-key': Uuid });
