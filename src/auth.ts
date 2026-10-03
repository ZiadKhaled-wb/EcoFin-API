import { z } from 'zod';
import { Ack, BusinessDate, IsoTimestamp, Uuid } from './common.js';
import { EmployeeRole } from './roles.js';

/** 8 to 72 characters (bcrypt's 72-byte limit in Supabase Auth), no character-class rules. */
export const Password = z.string().min(8).max(72);

/** `organizations.tenant_slug` CHECK pattern from the baseline. */
export const TenantSlug = z.string().regex(/^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$/);
export type TenantSlug = z.infer<typeof TenantSlug>;

/** `employees.username` pattern; unique per shop only. */
export const Username = z.string().regex(/^[a-z0-9._-]{3,32}$/);

/** An email or a username. */
export const LoginIdentifier = z.union([z.string().email(), Username]);

/** A username is only unique inside one shop, so it needs `tenantSlug`; an email does not. */
const needsTenantSlug = (v: { identifier: string; tenantSlug?: string | undefined }) =>
  v.identifier.includes('@') || v.tenantSlug !== undefined;
const tenantSlugIssue = {
  message: 'tenantSlug is required when identifier is a username',
  path: ['tenantSlug'],
};

/** Values of `public.org_status`. */
export const OrgStatus = z.enum(['active', 'suspended', 'expired', 'closed']);
export type OrgStatus = z.infer<typeof OrgStatus>;

export const AuthSession = z.object({
  accessToken: z.string().min(1),
  refreshToken: z.string().min(1),
  expiresAt: IsoTimestamp,
});
export type AuthSession = z.infer<typeof AuthSession>;

/** The login (auth.users row). Name, role and shop come from the shop membership, see `me`. */
export const AuthUser = z.object({
  id: Uuid,
  email: z.string().email().nullable(),
});
export type AuthUser = z.infer<typeof AuthUser>;

export const ShopMembership = z.object({
  orgId: Uuid,
  orgName: z.string(),
  tenantSlug: TenantSlug,
  role: EmployeeRole,
});
export type ShopMembership = z.infer<typeof ShopMembership>;

// F04 · POST /auth/login
export const AuthLoginBody = z
  .object({
    identifier: LoginIdentifier,
    password: z.string().min(1).max(128),
    tenantSlug: TenantSlug.optional(),
  })
  .strict()
  .refine(needsTenantSlug, tenantSlugIssue);
export const AuthLoginResponse = AuthSession.extend({
  user: AuthUser,
  mustChangePassword: z.boolean(),
  /** Every shop this login belongs to. One entry when there is a single membership. */
  shops: z.array(ShopMembership),
  /** True when the login has several shops and none was chosen: call select-shop next. */
  requiresShopSelection: z.boolean(),
});
export const AuthLogin = { body: AuthLoginBody, response: AuthLoginResponse };
export type AuthLoginBody = z.infer<typeof AuthLoginBody>;
export type AuthLoginResponse = z.infer<typeof AuthLoginResponse>;

// F04 · POST /auth/select-shop
export const AuthSelectShopBody = z.object({ orgId: Uuid }).strict();
export const AuthSelectShopResponse = AuthSession.extend({
  user: AuthUser,
  shop: ShopMembership,
});
export const AuthSelectShop = { body: AuthSelectShopBody, response: AuthSelectShopResponse };
export type AuthSelectShopBody = z.infer<typeof AuthSelectShopBody>;
export type AuthSelectShopResponse = z.infer<typeof AuthSelectShopResponse>;

// F04 · POST /auth/refresh
export const AuthRefreshBody = z.object({ refreshToken: z.string().min(1) }).strict();
export const AuthRefreshResponse = AuthSession;
export const AuthRefresh = { body: AuthRefreshBody, response: AuthRefreshResponse };
export type AuthRefreshBody = z.infer<typeof AuthRefreshBody>;
export type AuthRefreshResponse = z.infer<typeof AuthRefreshResponse>;

// F04 · POST /auth/logout (no body; the access token identifies the session)
export const AuthLogoutResponse = Ack;
export const AuthLogout = { response: AuthLogoutResponse };
export type AuthLogoutResponse = z.infer<typeof AuthLogoutResponse>;

// F04 · POST /auth/forgot-password (fixed 202 acknowledgement whether or not the account exists)
export const AuthForgotPasswordBody = z
  .object({ identifier: LoginIdentifier, tenantSlug: TenantSlug.optional() })
  .strict()
  .refine(needsTenantSlug, tenantSlugIssue);
export const AuthForgotPasswordResponse = Ack;
export const AuthForgotPassword = {
  body: AuthForgotPasswordBody,
  response: AuthForgotPasswordResponse,
};
export type AuthForgotPasswordBody = z.infer<typeof AuthForgotPasswordBody>;
export type AuthForgotPasswordResponse = z.infer<typeof AuthForgotPasswordResponse>;

// F04 · POST /auth/reset-password
export const AuthResetPasswordBody = z
  .object({ token: z.string().min(1), newPassword: Password })
  .strict();
export const AuthResetPasswordResponse = Ack;
export const AuthResetPassword = {
  body: AuthResetPasswordBody,
  response: AuthResetPasswordResponse,
};
export type AuthResetPasswordBody = z.infer<typeof AuthResetPasswordBody>;
export type AuthResetPasswordResponse = z.infer<typeof AuthResetPasswordResponse>;

// F04 · POST /auth/change-password (logged in)
export const AuthChangePasswordBody = z
  .object({ currentPassword: z.string().min(1).max(128), newPassword: Password })
  .strict();
export const AuthChangePasswordResponse = Ack;
export const AuthChangePassword = {
  body: AuthChangePasswordBody,
  response: AuthChangePasswordResponse,
};
export type AuthChangePasswordBody = z.infer<typeof AuthChangePasswordBody>;
export type AuthChangePasswordResponse = z.infer<typeof AuthChangePasswordResponse>;

// F04 · GET /auth/me
export const AuthMeResponse = z.object({
  employee: z.object({
    id: Uuid,
    fullName: z.string(),
    email: z.string().nullable(),
    username: z.string().nullable(),
    role: EmployeeRole,
    defaultBranchId: Uuid.nullable(),
    mustChangePassword: z.boolean(),
  }),
  org: z.object({
    id: Uuid,
    tenantSlug: z.string(),
    name: z.string(),
    timezone: z.string(),
    defaultLanguage: z.enum(['ar', 'en']),
    status: OrgStatus,
    planKey: z.string(),
    subscriptionEnd: BusinessDate.nullable(),
  }),
  /** Branches this employee may work in (all active branches for the owner). */
  branches: z.array(
    z.object({ id: Uuid, code: z.string(), name: z.string(), isMain: z.boolean() }),
  ),
});
export const AuthMe = { response: AuthMeResponse };
export type AuthMeResponse = z.infer<typeof AuthMeResponse>;
