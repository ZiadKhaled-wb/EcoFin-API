import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import {
  EGYPT_GOVERNORATE_CODES,
  isValidNationalId,
  normalizeNationalId,
  toAsciiDigits,
} from './nationalId.js';

/**
 * R01 customers (D63).
 *
 * Birth date, gender and governorate are never inputs: the server reads them from the national ID.
 *
 * PII: `national_id` is the full number only for a caller with `customer.view_pii`; everyone else
 * gets null there and `national_id_masked` (ten stars + the last four digits). ID photos are
 * `files` rows (purpose `customer_id`, entity `customer`): `id_photos_count` is always shown, the
 * photos themselves need `customer.view_pii` (F14 `GET /api/files`).
 *
 * `status`: `blocked` customers can't buy on installments (enforced by the installment sale);
 * `watch` is set by the system (collections), never by this API.
 */
export const CustomerStatus = z.enum(['active', 'watch', 'blocked']);
export type CustomerStatus = z.infer<typeof CustomerStatus>;

export const CustomerGender = z.enum(['male', 'female']);
export type CustomerGender = z.infer<typeof CustomerGender>;

export const CUSTOMER_MAX_PHONES = 5;

/** An Egyptian mobile in any usual spelling: +20 / 0020 / 20 / 0 / nothing, then 1[0125] and 8 digits. */
const EGYPT_MOBILE = /^(?:\+20|0020|20|0)?(1[0125][0-9]{8})$/;
/** Anything else (a landline, a foreign number): an optional `+`, then 7-15 digits. */
export const CUSTOMER_PHONE_PATTERN = /^\+?[0-9]{7,15}$/;
export const CUSTOMER_TAX_NO_PATTERN = /^[0-9-]{9,20}$/;

/**
 * As the server stores phones: ASCII digits, no spaces, dashes or brackets; an Egyptian mobile
 * always as `01XXXXXXXXX` (so `+20 100 123 4567` and `0100-1234567` are the same phone).
 */
export function normalizeCustomerPhone(value: string): string {
  const compact = toAsciiDigits(value).replace(/[\s().-]/g, '');
  const mobile = EGYPT_MOBILE.exec(compact);
  return mobile ? `0${mobile[1]}` : compact;
}

const nullIfEmpty = (v: string | null) => (v === '' ? null : v);
const text = (max: number) => z.string().trim().max(max).nullable().transform(nullIfEmpty);

const fields = {
  /** Inner runs of spaces become one space. */
  full_name: z
    .string()
    .transform((v) => v.trim().replace(/\s+/g, ' '))
    .pipe(z.string().min(2).max(150)),
  /** The first phone is the main one. */
  phones: z
    .array(
      z
        .string()
        .transform(normalizeCustomerPhone)
        .refine((v) => CUSTOMER_PHONE_PATTERN.test(v), { message: 'Not a valid phone number' }),
    )
    .min(1)
    .max(CUSTOMER_MAX_PHONES)
    .refine((list) => new Set(list).size === list.length, { message: 'A phone is repeated' }),
  /** Empty means no national ID (null). */
  national_id: z
    .string()
    .transform(normalizeNationalId)
    .refine((v) => v === '' || isValidNationalId(v), { message: 'Not a valid national ID' })
    .nullable()
    .transform(nullIfEmpty),
  address: text(300),
  city: text(100),
  job: text(100),
  employer: text(150),
  monthly_income: Money.refine((v) => !v.startsWith('-'), {
    message: 'Income can not be negative',
  }).nullable(),
  /** A business customer needs a tax registration number (B2B e-invoices). */
  is_business: z.boolean(),
  tax_registration_no: z
    .string()
    .trim()
    .refine((v) => v === '' || CUSTOMER_TAX_NO_PATTERN.test(v), {
      message: 'Tax number must be 9-20 digits or dashes',
    })
    .nullable()
    .transform(nullIfEmpty),
  notes: text(1000),
};

export const CustomerCreateBody = z
  .object({
    full_name: fields.full_name,
    phones: fields.phones,
    national_id: fields.national_id.optional(),
    address: fields.address.optional(),
    city: fields.city.optional(),
    job: fields.job.optional(),
    employer: fields.employer.optional(),
    monthly_income: fields.monthly_income.optional(),
    is_business: fields.is_business.default(false),
    tax_registration_no: fields.tax_registration_no.optional(),
    notes: fields.notes.optional(),
  })
  .strict()
  .refine((b) => !b.is_business || !!b.tax_registration_no, {
    message: 'A business customer needs a tax registration number',
    path: ['tax_registration_no'],
  });
export type CustomerCreateBody = z.infer<typeof CustomerCreateBody>;
export type CustomerCreateInput = z.input<typeof CustomerCreateBody>;

/**
 * Any create field; at least one. Sending `national_id` for a customer who already has one needs
 * `customer.view_pii` on top of `customer.edit`, whatever the value.
 */
export const CustomerUpdateBody = z
  .object(fields)
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' });
export type CustomerUpdateBody = z.infer<typeof CustomerUpdateBody>;
export type CustomerUpdateInput = z.input<typeof CustomerUpdateBody>;

/** Block (a reason is required) or unblock. `watch` can't be set by hand. */
export const CustomerStatusBody = z
  .object({
    status: z.enum(['active', 'blocked']),
    reason: z.string().trim().max(300).optional(),
  })
  .strict()
  .refine((b) => b.status !== 'blocked' || (b.reason ?? '').length >= 3, {
    message: 'Blocking a customer needs a reason',
    path: ['reason'],
  });
export type CustomerStatusBody = z.infer<typeof CustomerStatusBody>;

export const CustomerIdParams = z.object({ id: Uuid }).strict();
export type CustomerIdParams = z.infer<typeof CustomerIdParams>;

export const Customer = z.object({
  id: Uuid,
  full_name: z.string(),
  phones: z.array(z.string()),
  national_id: z.string().nullable(),
  national_id_masked: z.string().nullable(),
  /** Read from the national ID by the server (never typed): null without one. */
  birth_date: BusinessDate.nullable(),
  gender: CustomerGender.nullable(),
  /** Governorate of birth (digits 8-9 of the ID), shown to everyone; the number itself stays masked. */
  governorate_code: z.enum(EGYPT_GOVERNORATE_CODES).nullable(),
  address: z.string().nullable(),
  city: z.string().nullable(),
  job: z.string().nullable(),
  employer: z.string().nullable(),
  monthly_income: Money.nullable(),
  is_business: z.boolean(),
  tax_registration_no: z.string().nullable(),
  status: CustomerStatus,
  notes: z.string().nullable(),
  id_photos_count: z.number().int().nonnegative(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
});
export type Customer = z.infer<typeof Customer>;
export const CustomerList = paginated(Customer);
export type CustomerList = z.infer<typeof CustomerList>;

export const CustomerStatusFilter = z.enum(['all', 'active', 'watch', 'blocked']);
export type CustomerStatusFilter = z.infer<typeof CustomerStatusFilter>;

/**
 * `search` matches the name (contains, any letter case), a phone (contains, digits only) or the
 * national ID: the whole 14 digits for everyone, a prefix of 4+ digits only with `customer.view_pii`.
 */
export const CustomerListQuery = PaginationQuery.extend({
  search: z
    .string()
    .trim()
    .max(100)
    .optional()
    .transform((v) => (v ? v : undefined)),
  status: CustomerStatusFilter.default('all'),
}).strict();
export type CustomerListQuery = z.infer<typeof CustomerListQuery>;

/** Details of `CUSTOMER_NATIONAL_ID_TAKEN`: the customer of this shop who already has the ID. */
export const CustomerNationalIdTakenDetail = z.object({ customer_id: Uuid, full_name: z.string() });
export type CustomerNationalIdTakenDetail = z.infer<typeof CustomerNationalIdTakenDetail>;
