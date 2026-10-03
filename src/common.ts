import { z } from 'zod';

export const Uuid = z.string().uuid();
export type Uuid = z.infer<typeof Uuid>;

/** Decimal string for a `numeric(18,2)` column. Never a JS number. */
export const MONEY_PATTERN = /^-?\d{1,16}(\.\d{1,2})?$/;
export const Money = z
  .string()
  .regex(MONEY_PATTERN, 'Money must be a decimal string with at most 2 decimals');
export type Money = z.infer<typeof Money>;

/** ISO 8601 timestamp, e.g. 2026-10-03T08:00:00.000Z. */
export const IsoTimestamp = z.string().datetime({ offset: true });
export type IsoTimestamp = z.infer<typeof IsoTimestamp>;

/** Business date (no time): YYYY-MM-DD, must be a real calendar date. */
export const BusinessDate = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/)
  .refine((v) => {
    const d = new Date(`${v}T00:00:00Z`);
    return !Number.isNaN(d.getTime()) && d.toISOString().startsWith(v);
  }, 'Not a valid calendar date');
export type BusinessDate = z.infer<typeof BusinessDate>;

export const MAX_PAGE_SIZE = 100;
export const DEFAULT_PAGE_SIZE = 50;

/** Query strings arrive as text, so numbers are coerced. */
export const PaginationQuery = z.object({
  page: z.coerce.number().int().min(1).default(1),
  pageSize: z.coerce.number().int().min(1).max(MAX_PAGE_SIZE).default(DEFAULT_PAGE_SIZE),
});
export type PaginationQuery = z.infer<typeof PaginationQuery>;

export const paginated = <T extends z.ZodTypeAny>(item: T) =>
  z.object({
    items: z.array(item),
    page: z.number().int().min(1),
    pageSize: z.number().int().min(1).max(MAX_PAGE_SIZE),
    total: z.number().int().min(0),
  });

/** `Idempotency-Key` request header (Node lower-cases header names). */
export const IdempotencyKey = z.string().min(8).max(128);
export type IdempotencyKey = z.infer<typeof IdempotencyKey>;
export const IdempotencyKeyHeader = z.object({ 'idempotency-key': IdempotencyKey });
export type IdempotencyKeyHeader = z.infer<typeof IdempotencyKeyHeader>;

/** Plain success reply for endpoints with nothing to return. */
export const Ack = z.object({ ok: z.literal(true) });
export type Ack = z.infer<typeof Ack>;
