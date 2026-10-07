import { z } from 'zod';
import { IsoTimestamp } from './common.js';

const optionalText = (max: number) => z.string().trim().max(max).nullable();

export const ShopProfile = z.object({
  legal_name: optionalText(200),
  commercial_register: optionalText(50),
  tax_registration_no: optionalText(50),
  consumer_finance_legal_status: optionalText(500),
  creditor_model: z.literal('in_house'),
  installments_enabled: z.boolean(),
  updated_at: IsoTimestamp,
});
export type ShopProfile = z.infer<typeof ShopProfile>;

export const ShopProfileUpdateBody = z
  .object({
    legal_name: optionalText(200).optional(),
    commercial_register: optionalText(50).optional(),
    tax_registration_no: optionalText(50).optional(),
    consumer_finance_legal_status: optionalText(500).optional(),
    installments_enabled: z.boolean().optional(),
  })
  .strict()
  .refine((value) => Object.keys(value).length > 0, { message: 'Nothing to change' });
export type ShopProfileUpdateBody = z.infer<typeof ShopProfileUpdateBody>;
