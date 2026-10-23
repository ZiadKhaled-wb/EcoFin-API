import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
export const QuotationStatus = z.enum([
  'draft',
  'sent',
  'accepted',
  'expired',
  'rejected',
  'cancelled',
]);
export type QuotationStatus = z.infer<typeof QuotationStatus>;
export const QuotationLineInput = z.object({
  product_id: Uuid.nullable().default(null),
  description: z.string().trim().max(200).nullable().optional(),
  custom_notes: z.string().max(500).nullable().optional(),
  quantity: z.number().int().positive(),
  unit_price: Money.refine((v) => !v.startsWith('-')),
  discount_amount: Money.refine((v) => !v.startsWith('-')).default('0'),
});
export type QuotationLineInput = z.infer<typeof QuotationLineInput>;
export const QuotationDraftBody = z.object({
  customer_id: Uuid.nullable().default(null),
  valid_until: BusinessDate.nullable().default(null),
  notes: z.string().nullable().default(null),
  lines: z.array(QuotationLineInput).min(1).max(200),
});
export type QuotationDraftBody = z.infer<typeof QuotationDraftBody>;
export const CreateQuotationBody = QuotationDraftBody.extend({ branch_id: Uuid });
export type CreateQuotationBody = z.infer<typeof CreateQuotationBody>;
export const UpdateQuotationBody = QuotationDraftBody.extend({ expected_updated_at: IsoTimestamp });
export type UpdateQuotationBody = z.infer<typeof UpdateQuotationBody>;
export const QuotationReasonBody = z.object({ reason: z.string().trim().min(3).max(500) });
export const QuotationIdParams = z.object({ id: Uuid });
export const QuotationCreated = z.object({ id: Uuid, number: z.string() });
export const QuotationLine = QuotationLineInput.extend({
  id: Uuid,
  line_no: z.number().int(),
  tax_class_id: Uuid,
  tax_rate: Money,
  tax_amount: Money,
  line_total: Money,
});
export type QuotationLine = z.infer<typeof QuotationLine>;
export const Quotation = z.object({
  id: Uuid,
  number: z.string(),
  branch_id: Uuid,
  customer_id: Uuid.nullable(),
  status: QuotationStatus,
  effective_status: QuotationStatus,
  valid_until: BusinessDate,
  prices_include_vat: z.boolean(),
  subtotal: Money,
  discount_total: Money,
  tax_total: Money,
  total: Money,
  notes: z.string().nullable(),
  status_reason: z.string().nullable(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
  sent_at: IsoTimestamp.nullable(),
  accepted_at: IsoTimestamp.nullable(),
  customer: z.object({ id: Uuid, name: z.string(), phone: z.string().nullable() }).nullable(),
  branch: z.object({ id: Uuid, name: z.string(), address: z.string().nullable() }),
  shop: z.object({ legal_name: z.string().nullable() }),
  lines: z.array(QuotationLine),
});
export type Quotation = z.infer<typeof Quotation>;
export const QuotationListQuery = z.object({
  status: QuotationStatus.optional(),
  branch_id: Uuid.optional(),
  customer_id: Uuid.optional(),
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
  search: z.string().max(200).optional(),
  page: z.coerce.number().int().min(1).default(1),
  page_size: z.coerce.number().int().min(1).max(100).default(20),
});
export type QuotationListQuery = z.infer<typeof QuotationListQuery>;
export const QuotationList = z.object({ items: z.array(Quotation), total: z.number().int() });
