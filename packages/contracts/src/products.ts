import { z } from 'zod';
import { IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';

/**
 * C02 products. Money is a decimal string; `avg_cost` (a numeric(18,4) string) is read-only:
 * only purchase approval sets it. `archived_at` is how archiving shows (`is_active` moves with it
 * and is not part of the contract). Archived products can't be sold (the POS lookup skips them)
 * but stay readable everywhere they were used.
 */
export const EtaItemType = z.enum(['EGS', 'GS1']);
export type EtaItemType = z.infer<typeof EtaItemType>;

export const ProductStatus = z.enum(['active', 'archived', 'all']);
export type ProductStatus = z.infer<typeof ProductStatus>;

/** Decimal string with up to 4 decimals (the average cost). */
export const CostDecimal = z.string().regex(/^\d{1,14}(\.\d{1,4})?$/);

export const Product = z.object({
  id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  barcode: z.string().nullable(),
  category_id: Uuid.nullable(),
  unit_of_measure: z.string(),
  cash_price: Money,
  installment_price: Money.nullable(),
  avg_cost: CostDecimal,
  tax_class_id: Uuid,
  warranty_months: z.number().int().nonnegative(),
  is_serialized: z.boolean(),
  min_stock: z.number().int().nonnegative(),
  image_file_id: Uuid.nullable(),
  eta_item_code: z.string().nullable(),
  eta_item_type: EtaItemType.nullable(),
  archived_at: IsoTimestamp.nullable(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
});
export type Product = z.infer<typeof Product>;
export const ProductList = paginated(Product);
export type ProductList = z.infer<typeof ProductList>;

/** Query strings arrive as text: 'true' / 'false' for the flag. */
const QueryFlag = z.enum(['true', 'false']).transform((v) => v === 'true');

export const ProductListQuery = PaginationQuery.extend({
  search: z
    .string()
    .trim()
    .max(100)
    .optional()
    .transform((v) => (v ? v : undefined)),
  category_id: Uuid.optional(),
  include_subcategories: QueryFlag.default('true'),
  status: ProductStatus.default('active'),
}).strict();
export type ProductListQuery = z.infer<typeof ProductListQuery>;

export const ProductLookupQuery = z.object({ code: z.string().trim().min(1).max(64) }).strict();
export type ProductLookupQuery = z.infer<typeof ProductLookupQuery>;

export const SKU_PATTERN = /^[A-Za-z0-9._/-]+$/;
export const BARCODE_PATTERN = /^[0-9A-Za-z-]+$/;

const PriceMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');
const nullIfEmpty = (v: string | null | undefined) => (v === '' ? null : v);

const fields = {
  name_ar: z.string().trim().min(1).max(150),
  name_en: z.string().trim().max(150).nullable().transform(nullIfEmpty),
  sku: z
    .string()
    .trim()
    .min(1)
    .max(40)
    .regex(SKU_PATTERN)
    .transform((v) => v.toUpperCase()),
  /** Empty or null: the server generates an in-store EAN-13. */
  barcode: z
    .string()
    .trim()
    .refine((v) => v === '' || (v.length >= 4 && v.length <= 32 && BARCODE_PATTERN.test(v)), {
      message: 'Barcode must be 4-32 letters, digits or dashes',
    })
    .nullable()
    .transform(nullIfEmpty),
  category_id: Uuid.nullable(),
  unit_of_measure: z.string().trim().min(1).max(20),
  cash_price: PriceMoney,
  installment_price: PriceMoney.nullable(),
  tax_class_id: Uuid,
  warranty_months: z.number().int().min(0).max(120),
  is_serialized: z.boolean(),
  min_stock: z.number().int().min(0).max(1_000_000),
  image_file_id: Uuid.nullable(),
  eta_item_code: z.string().trim().min(1).max(40).nullable(),
  eta_item_type: EtaItemType.nullable(),
};

const etaPair = (b: {
  eta_item_code?: string | null | undefined;
  eta_item_type?: string | null | undefined;
}) =>
  (b.eta_item_code ?? null) === null
    ? (b.eta_item_type ?? null) === null
    : (b.eta_item_type ?? null) !== null;
const etaMessage = {
  message: 'eta_item_code and eta_item_type go together',
  path: ['eta_item_type'],
};

export const ProductCreateBody = z
  .object({
    name_ar: fields.name_ar,
    sku: fields.sku,
    cash_price: fields.cash_price,
    name_en: fields.name_en.optional(),
    barcode: fields.barcode.optional(),
    category_id: fields.category_id.optional(),
    unit_of_measure: fields.unit_of_measure.optional(),
    installment_price: fields.installment_price.optional(),
    tax_class_id: fields.tax_class_id.optional(),
    warranty_months: fields.warranty_months.optional(),
    is_serialized: fields.is_serialized.optional(),
    min_stock: fields.min_stock.optional(),
    image_file_id: fields.image_file_id.optional(),
    eta_item_code: fields.eta_item_code.optional(),
    eta_item_type: fields.eta_item_type.optional(),
  })
  .strict()
  .refine(etaPair, etaMessage);
export type ProductCreateBody = z.infer<typeof ProductCreateBody>;
export type ProductCreateInput = z.input<typeof ProductCreateBody>;

/** Any create field; at least one. The ETA pair rule applies when both keys are sent. */
export const ProductUpdateBody = z
  .object(fields)
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' })
  .refine((b) => !('eta_item_code' in b && 'eta_item_type' in b) || etaPair(b), etaMessage);
export type ProductUpdateBody = z.infer<typeof ProductUpdateBody>;
export type ProductUpdateInput = z.input<typeof ProductUpdateBody>;

export const ProductIdParams = z.object({ id: Uuid }).strict();
export type ProductIdParams = z.infer<typeof ProductIdParams>;
