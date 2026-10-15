import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import { CUSTOMER_PHONE_PATTERN, CustomerGender, normalizeCustomerPhone } from './customers.js';
import { isValidNationalId, normalizeNationalId } from './nationalId.js';

/**
 * R04 guarantors (D71).
 *
 * One guarantor record per person per shop; it may back several customers (with a relation) and
 * several installment contracts. Same ID rules and masking as customers (D63): `national_id` is the
 * full number only for a caller with `customer.view_pii` (and `birth_date` / `gender` are read from
 * it only then); everyone else gets `national_id_masked`. ID photos are `files` rows (purpose
 * `customer_id`, entity `guarantor`).
 *
 * The installment policy (`guarantor_required_above`, `guarantors_required_count`) says when a
 * contract needs guarantors; the database refuses a contract that needs them and has fewer.
 */
export const GUARANTOR_RELATIONS = [
  'father',
  'mother',
  'brother',
  'sister',
  'spouse',
  'son',
  'daughter',
  'relative',
  'friend',
  'colleague',
  'employer',
  'neighbour',
  'other',
] as const;
export const GuarantorRelation = z.enum(GUARANTOR_RELATIONS);
export type GuarantorRelation = z.infer<typeof GuarantorRelation>;

export const MAX_GUARANTORS_PER_CUSTOMER = 5;
export const MAX_GUARANTORS_PER_CONTRACT = 3;

const nullIfEmpty = (v: string | null) => (v === '' ? null : v);
const text = (max: number) => z.string().trim().max(max).nullable().transform(nullIfEmpty);

const fields = {
  /** Inner runs of spaces become one space. */
  full_name: z
    .string()
    .transform((v) => v.trim().replace(/\s+/g, ' '))
    .pipe(z.string().min(2).max(150)),
  /** One number, stored the way R01 stores customer phones. */
  phone: z
    .string()
    .transform(normalizeCustomerPhone)
    .refine((v) => CUSTOMER_PHONE_PATTERN.test(v), { message: 'Not a valid phone number' }),
  /** Required: a guarantor only exists to back installment debt. */
  national_id: z
    .string()
    .transform(normalizeNationalId)
    .refine((v) => isValidNationalId(v), { message: 'Not a valid national ID' }),
  address: text(300),
  job: text(100),
  monthly_income: Money.refine((v) => !v.startsWith('-'), {
    message: 'Income can not be negative',
  }).nullable(),
};

export const GuarantorCreateBody = z
  .object({
    full_name: fields.full_name,
    phone: fields.phone,
    national_id: fields.national_id,
    address: fields.address.optional(),
    job: fields.job.optional(),
    monthly_income: fields.monthly_income.optional(),
    /** Create and link to this customer in one transaction. */
    link: z.object({ customer_id: Uuid, relation: GuarantorRelation }).strict().optional(),
  })
  .strict();
export type GuarantorCreateBody = z.infer<typeof GuarantorCreateBody>;
export type GuarantorCreateInput = z.input<typeof GuarantorCreateBody>;

/**
 * Any create field except `link`; at least one. `''` clears an optional field. Sending
 * `national_id` needs `customer.view_pii` on top of `guarantor.manage`, whatever the value.
 */
export const GuarantorUpdateBody = z
  .object({
    full_name: fields.full_name,
    phone: fields.phone,
    national_id: fields.national_id,
    address: fields.address,
    job: fields.job,
    monthly_income: fields.monthly_income,
  })
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' });
export type GuarantorUpdateBody = z.infer<typeof GuarantorUpdateBody>;
export type GuarantorUpdateInput = z.input<typeof GuarantorUpdateBody>;

export const GuarantorIdParams = z.object({ id: Uuid }).strict();
export type GuarantorIdParams = z.infer<typeof GuarantorIdParams>;

/** `/api/customers/:id/guarantors/:guarantorId[/unlink]`. */
export const CustomerGuarantorParams = z.object({ id: Uuid, guarantorId: Uuid }).strict();
export type CustomerGuarantorParams = z.infer<typeof CustomerGuarantorParams>;

export const CustomerGuarantorLinkBody = z
  .object({ guarantor_id: Uuid, relation: GuarantorRelation })
  .strict();
export type CustomerGuarantorLinkBody = z.infer<typeof CustomerGuarantorLinkBody>;

export const CustomerGuarantorRelationBody = z.object({ relation: GuarantorRelation }).strict();
export type CustomerGuarantorRelationBody = z.infer<typeof CustomerGuarantorRelationBody>;

export const Guarantor = z.object({
  id: Uuid,
  full_name: z.string(),
  phone: z.string(),
  national_id: z.string().nullable(),
  national_id_masked: z.string().nullable(),
  /** Read from the national ID: only for a caller who may see the full ID. */
  birth_date: BusinessDate.nullable(),
  gender: CustomerGender.nullable(),
  address: z.string().nullable(),
  job: z.string().nullable(),
  monthly_income: Money.nullable(),
  /** The shop's customer with the same national ID, if there is one. */
  also_customer: z.object({ id: Uuid, full_name: z.string() }).nullable(),
  archived_at: IsoTimestamp.nullable(),
  id_photos_count: z.number().int().nonnegative(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
});
export type Guarantor = z.infer<typeof Guarantor>;

export const GuarantorDetails = Guarantor.extend({
  customers: z.array(
    z.object({
      customer_id: Uuid,
      full_name: z.string(),
      relation: GuarantorRelation,
      linked_at: IsoTimestamp,
    }),
  ),
  /** Empty until the installment sale (N02) exists. */
  contracts: z.array(
    z.object({
      contract_id: Uuid,
      number: z.string(),
      customer_id: Uuid,
      customer_name: z.string(),
      status: z.enum(['active', 'completed', 'rescheduled', 'written_off', 'returned']),
      total_payable: Money,
    }),
  ),
});
export type GuarantorDetails = z.infer<typeof GuarantorDetails>;

export const CustomerGuarantor = Guarantor.extend({
  relation: GuarantorRelation,
  linked_at: IsoTimestamp,
  on_active_contract: z.boolean(),
});
export type CustomerGuarantor = z.infer<typeof CustomerGuarantor>;
/** At most 5, no paging. */
export const CustomerGuarantorList = z.array(CustomerGuarantor);
export type CustomerGuarantorList = z.infer<typeof CustomerGuarantorList>;

export const GuarantorStatusFilter = z.enum(['active', 'archived', 'all']);
export type GuarantorStatusFilter = z.infer<typeof GuarantorStatusFilter>;

/** `search` works as for customers: name, phone, the whole national ID (a prefix needs `customer.view_pii`). */
export const GuarantorListQuery = PaginationQuery.extend({
  search: z
    .string()
    .trim()
    .max(100)
    .optional()
    .transform((v) => (v ? v : undefined)),
  status: GuarantorStatusFilter.default('active'),
}).strict();
export type GuarantorListQuery = z.infer<typeof GuarantorListQuery>;

export const GuarantorList = paginated(Guarantor);
export type GuarantorList = z.infer<typeof GuarantorList>;

/** `GET /api/customers/:id/guarantor-requirement?financed_amount=` (cash price - down payment). */
export const GuarantorRequirementQuery = z
  .object({ financed_amount: Money.refine((v) => !v.startsWith('-'), { message: 'Not negative' }) })
  .strict();
export type GuarantorRequirementQuery = z.infer<typeof GuarantorRequirementQuery>;

/**
 * Against the shop's current policy version. `required_count` is 0 when no guarantor is needed;
 * `linked_active_count` counts the customer's linked guarantors that are not archived.
 * The policy fields are null only for a shop that has no policy version yet.
 */
export const GuarantorRequirement = z.object({
  policy_id: Uuid.nullable(),
  policy_version: z.number().int().min(1).nullable(),
  required_above: Money.nullable(),
  required_count: z.number().int().min(0).max(MAX_GUARANTORS_PER_CONTRACT),
  linked_active_count: z.number().int().min(0),
  met: z.boolean(),
});
export type GuarantorRequirement = z.infer<typeof GuarantorRequirement>;

/** Details of `GUARANTOR_NATIONAL_ID_TAKEN`: the guarantor of this shop who already has the ID. */
export const GuarantorNationalIdTakenDetail = z.object({
  guarantor_id: Uuid,
  full_name: z.string(),
});
export type GuarantorNationalIdTakenDetail = z.infer<typeof GuarantorNationalIdTakenDetail>;

/** Details of `GUARANTOR_REQUIRED`: how many the policy needs and how many were given. */
export const GuarantorRequiredDetail = z.object({
  required: z.number().int().min(1),
  given: z.number().int().min(0),
});
export type GuarantorRequiredDetail = z.infer<typeof GuarantorRequiredDetail>;
