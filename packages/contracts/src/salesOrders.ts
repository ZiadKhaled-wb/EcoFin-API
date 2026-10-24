import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { SalePaymentInput, SalePayments } from './sales.js';
import { QuotationIdParams } from './quotations.js';

export const SalesOrderStatus = z.enum(['open', 'partially_delivered', 'delivered', 'cancelled']);
export type SalesOrderStatus = z.infer<typeof SalesOrderStatus>;
export const FulfilmentMode = z.enum(['from_stock', 'to_order']);
export type FulfilmentMode = z.infer<typeof FulfilmentMode>;
const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'));

/** How one line is filled: held from stock (serialized: the units) or bought on a PO line. */
export const OrderLineFulfilmentInput = z.object({
  fulfilment: FulfilmentMode.default('from_stock'),
  unit_ids: z.array(Uuid).max(200).optional(),
  po_line_id: Uuid.nullable().optional(),
});
export const SalesOrderLineInput = OrderLineFulfilmentInput.extend({
  product_id: Uuid,
  custom_notes: z.string().max(500).nullable().optional(),
  quantity: z.number().int().positive(),
  unit_price: NonNegativeMoney,
  discount_amount: NonNegativeMoney.default('0'),
});
export type SalesOrderLineInput = z.infer<typeof SalesOrderLineInput>;
export const CreateSalesOrderBody = z.object({
  branch_id: Uuid,
  customer_id: Uuid,
  delivery_address: z.string().max(500).nullable().default(null),
  notes: z.string().max(1000).nullable().default(null),
  lines: z.array(SalesOrderLineInput).min(1).max(200),
});
export type CreateSalesOrderBody = z.infer<typeof CreateSalesOrderBody>;
/** Keyed by the quotation's line_no. `product_id` only for a custom (product-less) quote line. */
export const QuotationOrderLineOption = OrderLineFulfilmentInput.extend({
  product_id: Uuid.optional(),
});
export const OrderFromQuotationBody = z.object({
  delivery_address: z.string().max(500).nullable().default(null),
  line_options: z.record(z.string().regex(/^[1-9][0-9]*$/), QuotationOrderLineOption).default({}),
});
export type OrderFromQuotationBody = z.infer<typeof OrderFromQuotationBody>;
export const OrderFromQuotationParams = QuotationIdParams;
/** A deposit takes S02's payment lines. */
export const OrderDepositBody = z.object({ payments: SalePayments });
export type OrderDepositBody = z.infer<typeof OrderDepositBody>;
/** Refund lines must add up to the deposits exactly; `[]` when there are none. */
export const CancelSalesOrderBody = z.object({
  reason: z.string().trim().min(3).max(500),
  refund: z.array(SalePaymentInput).max(5).default([]),
});
export type CancelSalesOrderBody = z.infer<typeof CancelSalesOrderBody>;
export const LinkOrderLineBody = z.object({ po_line_id: Uuid });
export type LinkOrderLineBody = z.infer<typeof LinkOrderLineBody>;
export const ReserveOrderLineBody = z.object({
  unit_ids: z.array(Uuid).min(1).max(200).optional(),
});
export type ReserveOrderLineBody = z.infer<typeof ReserveOrderLineBody>;
export const SalesOrderIdParams = z.object({ id: Uuid });
export const SalesOrderLineParams = z.object({ id: Uuid, lineId: Uuid });

export const SalesOrderLinePurchaseOrder = z.object({
  po_id: Uuid,
  number: z.string(),
  status: z.enum(['draft', 'sent', 'partially_received', 'received', 'cancelled']),
  ordered: z.number(),
  received: z.number(),
  remaining: z.number(),
});
export const SalesOrderLine = z.object({
  id: Uuid,
  order_id: Uuid,
  line_no: z.number().int(),
  product_id: Uuid,
  custom_notes: z.string().nullable(),
  quantity: z.number().int(),
  unit_price: Money,
  discount_amount: Money,
  tax_class_id: Uuid,
  tax_rate: Money,
  tax_amount: Money,
  line_total: Money,
  fulfilment: FulfilmentMode,
  po_line_id: Uuid.nullable(),
  created_at: IsoTimestamp,
  created_by: Uuid.nullable(),
  product: z.object({
    id: Uuid,
    sku: z.string(),
    name_ar: z.string(),
    name_en: z.string().nullable(),
    is_serialized: z.boolean(),
  }),
  delivered: z.number(),
  reserved: z.number(),
  remaining: z.number(),
  purchase_order: SalesOrderLinePurchaseOrder.nullable(),
  reserved_units: z.array(z.object({ id: Uuid, serial: z.string() })),
});
export type SalesOrderLine = z.infer<typeof SalesOrderLine>;
export const SalesOrderPayment = z.object({
  id: Uuid,
  number: z.string(),
  direction: z.enum(['in', 'out']),
  method: z.enum(['cash', 'bank_transfer', 'store_credit']),
  amount: Money,
  reference: z.string().nullable(),
  paid_at: IsoTimestamp,
});
export type SalesOrderPayment = z.infer<typeof SalesOrderPayment>;
export const SalesOrderBalances = z.object({
  deposits_paid: Money,
  financed: Money,
  delivered_value: Money,
  unpaid: Money,
});
export type SalesOrderBalances = z.infer<typeof SalesOrderBalances>;
export const SalesOrder = z.object({
  id: Uuid,
  number: z.string(),
  customer_id: Uuid,
  branch_id: Uuid,
  quotation_id: Uuid.nullable(),
  status: SalesOrderStatus,
  prices_include_vat: z.boolean(),
  subtotal: Money,
  discount_total: Money,
  tax_total: Money,
  total: Money,
  delivery_address: z.string().nullable(),
  notes: z.string().nullable(),
  cancelled_reason: z.string().nullable(),
  created_at: IsoTimestamp,
  created_by: Uuid.nullable(),
  updated_at: IsoTimestamp,
  updated_by: Uuid.nullable(),
  customer: z.object({ id: Uuid, name: z.string(), phone: z.string().nullable() }),
  branch: z.object({ id: Uuid, name: z.string(), address: z.string().nullable() }),
  quotation: z.object({ id: Uuid, number: z.string() }).nullable(),
  lines: z.array(SalesOrderLine),
  payments: z.array(SalesOrderPayment),
  balances: SalesOrderBalances,
});
export type SalesOrder = z.infer<typeof SalesOrder>;
export const SalesOrderListQuery = z.object({
  status: SalesOrderStatus.optional(),
  branch_id: Uuid.optional(),
  customer_id: Uuid.optional(),
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
  search: z.string().max(200).optional(),
  page: z.coerce.number().int().min(1).default(1),
  page_size: z.coerce.number().int().min(1).max(100).default(20),
});
export type SalesOrderListQuery = z.infer<typeof SalesOrderListQuery>;
export const SalesOrderList = z.object({ items: z.array(SalesOrder), total: z.number().int() });
export type SalesOrderList = z.infer<typeof SalesOrderList>;

/** DETAIL of DEPOSIT_EXCEEDS_BALANCE: the most this order can still take. */
export const DepositExceedsBalanceDetail = z.object({ max: Money });
/** DETAIL of REFUND_MUST_EQUAL_DEPOSITS. */
export const RefundMustEqualDepositsDetail = z.object({ deposits: Money, refund: Money });
