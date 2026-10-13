import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Uuid } from './common.js';
import { FileResponse } from './files.js';

export const ClaimStatus = z.enum([
  'open',
  'in_repair',
  'repaired',
  'replaced',
  'rejected',
  'closed',
]);
export type ClaimStatus = z.infer<typeof ClaimStatus>;
export const WarrantyLookupQuery = z
  .object({
    serial: z.string().trim().min(1).max(200).optional(),
    phone: z.string().trim().min(1).max(60).optional(),
    sale_number: z.string().trim().min(1).max(100).optional(),
  })
  .strict()
  .refine((q) => Object.values(q).filter(Boolean).length === 1, { message: 'LOOKUP_ONE_KEY' });
export type WarrantyLookupQuery = z.infer<typeof WarrantyLookupQuery>;
export const WarrantyClaimsQuery = z
  .object({
    status: ClaimStatus.optional(),
    branch_id: Uuid.optional(),
    out_of_warranty: z.preprocess(
      (v) => (v === 'true' ? true : v === 'false' ? false : v),
      z.boolean().optional(),
    ),
    page: z.coerce.number().int().min(1).default(1),
    page_size: z.coerce.number().int().min(1).max(100).default(20),
  })
  .strict();
export type WarrantyClaimsQuery = z.infer<typeof WarrantyClaimsQuery>;
export const OpenWarrantyClaimBody = z
  .object({
    sale_line_id: Uuid,
    unit_id: Uuid.optional(),
    issue: z.string().trim().min(3).max(500),
    condition: z.string().trim().min(3).max(300),
  })
  .strict();
export type OpenWarrantyClaimBody = z.infer<typeof OpenWarrantyClaimBody>;
export const MoveWarrantyClaimBody = z
  .object({
    to: ClaimStatus,
    note: z.string().trim().optional(),
    replacement_unit_id: Uuid.optional(),
  })
  .strict()
  .refine((v) => !['rejected', 'replaced'].includes(v.to) || (v.note?.length ?? 0) >= 1, {
    message: 'A note is required',
    path: ['note'],
  });
export type MoveWarrantyClaimBody = z.infer<typeof MoveWarrantyClaimBody>;
export const WarrantyClaimIdParams = z.object({ id: Uuid }).strict();
export const WarrantyClaimOpened = z.object({
  claim_id: Uuid,
  number: z.string(),
  out_of_warranty: z.boolean(),
});
export type WarrantyClaimOpened = z.infer<typeof WarrantyClaimOpened>;
export const WarrantyClaimSummary = z.object({
  id: Uuid,
  number: z.string(),
  status: ClaimStatus,
  unit_id: Uuid.nullable(),
  replacement_unit_id: Uuid.nullable(),
  out_of_warranty: z.boolean(),
  created_at: IsoTimestamp,
});
export const WarrantyLine = z.object({
  sale_line_id: Uuid,
  product: z.object({ id: Uuid, name: z.string(), sku: z.string(), serialized: z.boolean() }),
  quantity: z.number().int().positive(),
  branch: z.object({ id: Uuid, name: z.string() }),
  customer: z.object({ id: Uuid, name: z.string() }).nullable(),
  sale_id: Uuid,
  sale_number: z.string(),
  sale_date: BusinessDate,
  warranty_until: BusinessDate.nullable(),
  in_warranty: z.boolean(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  chain: z.array(
    z.object({
      unit_id: Uuid,
      serial: z.string(),
      at: IsoTimestamp,
      warranty_until: BusinessDate.nullable(),
    }),
  ),
  claims: z.array(WarrantyClaimSummary),
});
export type WarrantyLine = z.infer<typeof WarrantyLine>;
export const WarrantyLookupResponse = z.object({ items: z.array(WarrantyLine) });
export type WarrantyLookupResponse = z.infer<typeof WarrantyLookupResponse>;
export const WarrantyClaim = z.object({
  id: Uuid,
  number: z.string(),
  branch_id: Uuid,
  sale_line_id: Uuid,
  unit_id: Uuid.nullable(),
  replacement_unit_id: Uuid.nullable(),
  status: ClaimStatus,
  issue: z.string(),
  resolution: z.string().nullable(),
  out_of_warranty: z.boolean(),
  created_at: IsoTimestamp,
  closed_at: IsoTimestamp.nullable(),
  line: WarrantyLine,
  files: z.array(FileResponse),
  history: z.array(z.object({ action: z.string(), at: IsoTimestamp, note: z.string().nullable() })),
});
export type WarrantyClaim = z.infer<typeof WarrantyClaim>;
export const WarrantyClaimsResponse = z.object({
  items: z.array(WarrantyClaim),
  total: z.number().int().nonnegative(),
});
export type WarrantyClaimsResponse = z.infer<typeof WarrantyClaimsResponse>;
