import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { Sale } from './sales.js';
import { ErrorCode } from './errors.js';

export const SaleStatus = z.enum(['completed', 'voided', 'returned', 'partially_returned']);
export type SaleStatus = z.infer<typeof SaleStatus>;
export const SalesHistoryQuery = z
  .object({
    q: z.string().trim().max(200).optional(),
    branch_id: Uuid.optional(),
    customer_id: Uuid.optional(),
    cashier_id: Uuid.optional(),
    from: BusinessDate.optional(),
    to: BusinessDate.optional(),
    status: SaleStatus.optional(),
    page: z.coerce.number().int().min(1).default(1),
    page_size: z.coerce.number().int().min(1).max(100).default(20),
  })
  .strict()
  .refine((q) => !q.from || !q.to || q.from <= q.to, {
    message: 'Invalid date range',
    path: ['to'],
  });
export type SalesHistoryQuery = z.infer<typeof SalesHistoryQuery>;
const Person = z.object({ id: Uuid.nullable(), name: z.string().nullable() });
export const SaleHistoryRow = z.object({
  id: Uuid,
  number: z.string(),
  issued_at: IsoTimestamp,
  business_date: BusinessDate,
  branch: z.object({ id: Uuid, name: z.string() }),
  cashier: Person,
  customer: Person.nullable(),
  total: Money,
  status: SaleStatus,
  items_count: z.number().int().nonnegative(),
});
export type SaleHistoryRow = z.infer<typeof SaleHistoryRow>;
export const SalesHistoryResponse = z.object({
  items: z.array(SaleHistoryRow),
  total: z.number().int().nonnegative(),
});
export type SalesHistoryResponse = z.infer<typeof SalesHistoryResponse>;
export const SaleReturnSummary = z.object({
  id: Uuid,
  number: z.string(),
  kind: z.enum(['void', 'return', 'exchange']),
  total: Money,
  reason: z.string(),
  by: z.string().nullable(),
  at: IsoTimestamp,
});
export const SaleHistoryDetails = Sale.extend({
  branch: z.object({ id: Uuid, name: z.string() }),
  cashier: Person.nullable(),
  customer: Person.nullable(),
  status: SaleStatus,
  voidable: z.boolean(),
  void_block_reason: ErrorCode.nullable(),
  returns: z.array(SaleReturnSummary),
});
export type SaleHistoryDetails = z.infer<typeof SaleHistoryDetails>;
export const SaleVoidBody = z.object({ reason: z.string().trim().min(3).max(200) }).strict();
export type SaleVoidBody = z.infer<typeof SaleVoidBody>;
export const SaleVoidResponse = z.object({ return_id: Uuid, number: z.string() });
export type SaleVoidResponse = z.infer<typeof SaleVoidResponse>;
