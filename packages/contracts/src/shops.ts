import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { SubscriptionState } from './subscriptions.js';
import { OrgStatus, TenantSlug } from './auth.js';

const name = z.string().trim().min(1).max(200);
export const ShopSlug = z
  .string()
  .trim()
  .toLowerCase()
  .pipe(TenantSlug)
  .refine((v) => !['admin', 'api', 'app', 'www', 'support'].includes(v), 'Reserved shop slug');
export const AdminShopId = z.object({ id: Uuid }).strict();
export const AdminCreateShopBody = z
  .object({
    name,
    tenant_slug: ShopSlug,
    plan_key: z.string().min(1).max(64),
    owner: z
      .object({
        full_name: name,
        email: z.string().trim().email().toLowerCase(),
        phone: z.string().trim().max(40).optional(),
      })
      .strict(),
    branch_name: name.optional(),
  })
  .strict();
export type AdminCreateShopBody = z.infer<typeof AdminCreateShopBody>;
export const AdminPlansResponse = z.array(
  z.object({ key: z.string(), name: z.string(), price_monthly: Money }),
);
export type AdminPlansResponse = z.infer<typeof AdminPlansResponse>;
export const AdminShopsQuery = z
  .object({
    search: z.string().trim().max(200).optional(),
    status: OrgStatus.optional(),
    page: z.coerce.number().int().min(1).default(1),
    page_size: z.coerce.number().int().min(1).max(100).default(20),
  })
  .strict();
export type AdminShopsQuery = z.infer<typeof AdminShopsQuery>;
export const AdminShop = z.object({
  id: Uuid,
  name: z.string(),
  tenant_slug: z.string(),
  plan_key: z.string(),
  status: OrgStatus,
  created_at: IsoTimestamp,
  owner_full_name: z.string().nullable(),
  owner_email: z.string().nullable(),
  owner_invite_status: z.enum(['accepted', 'pending', 'expired', 'none']),
  subscription_end: BusinessDate.nullable(),
  subscription_state: SubscriptionState,
});
export type AdminShop = z.infer<typeof AdminShop>;
export const AdminShopsResponse = z.object({
  items: z.array(AdminShop),
  total: z.number().int().nonnegative(),
});
export type AdminShopsResponse = z.infer<typeof AdminShopsResponse>;
export const AdminInviteResponse = z.object({
  invite_expires_at: IsoTimestamp,
  invite_email_sent: z.boolean(),
});
export type AdminInviteResponse = z.infer<typeof AdminInviteResponse>;
export const AdminCreateShopResponse = AdminInviteResponse.extend({
  organization_id: Uuid,
  tenant_slug: TenantSlug,
  owner_employee_id: Uuid,
});
export type AdminCreateShopResponse = z.infer<typeof AdminCreateShopResponse>;
export const AdminShopStatusBody = z
  .object({
    status: z.enum(['active', 'suspended']),
    reason: z.string().trim().max(1000).optional(),
  })
  .strict()
  .refine((v) => v.status !== 'suspended' || !!v.reason, {
    message: 'Reason required',
    path: ['reason'],
  });
export type AdminShopStatusBody = z.infer<typeof AdminShopStatusBody>;
export const AdminShopStatusResponse = z.object({
  id: Uuid,
  status: z.enum(['active', 'suspended']),
});
export type AdminShopStatusResponse = z.infer<typeof AdminShopStatusResponse>;
export const InviteLookupBody = z.object({ token: z.string().min(1).max(128) }).strict();
export const InviteAcceptBody = InviteLookupBody.extend({
  password: z.string().min(1).max(128),
}).strict();
export type InviteAcceptBody = z.infer<typeof InviteAcceptBody>;
export const InviteLookupResponse = z.object({
  login: z.string(),
  shop_name: z.string(),
  full_name: z.string(),
  email: z.string().email(),
  account_exists: z.boolean(),
});
export type InviteLookupResponse = z.infer<typeof InviteLookupResponse>;
export const InviteAcceptResponse = z.object({
  tenant_slug: TenantSlug,
  email: z.string().email(),
});
export type InviteAcceptResponse = z.infer<typeof InviteAcceptResponse>;
// RPC boundaries: validated JSON, shared with the API, never exposed verbatim.
export const ProvisionOrganizationResult = z.object({
  organization_id: Uuid,
  branch_id: Uuid,
  owner_employee_id: Uuid,
  invite_id: Uuid,
});
export const ResendOwnerInviteResult = z.object({
  email: z.string().email(),
  owner_full_name: z.string(),
  shop_name: z.string(),
  expires_at: IsoTimestamp,
});
export const InviteLookupResult = z.union([
  InviteLookupResponse.extend({ status: z.literal('valid'), tenant_slug: TenantSlug }),
  z.object({ status: z.enum(['not_found', 'expired', 'used']) }),
]);
