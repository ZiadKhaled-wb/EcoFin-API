// server/src/utils/validation.ts

// --------------------------------------------------
// Primitives
// --------------------------------------------------

export const isNonEmptyString = (value: unknown): value is string =>
  typeof value === 'string' && value.trim().length > 0;

export const isValidEmail = (value: unknown): value is string => {
  if (typeof value !== 'string') return false;
  const trimmed = value.trim();
  if (trimmed.length > 254) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed.toLowerCase());
};

// A small blocklist of the passwords that show up in every breach dump.
// Not exhaustive — the length rule does most of the work. Extend when new
// top-of-list entries appear; do not attempt to be clever beyond this.
const COMMON_PASSWORDS = new Set([
  'password',
  'password1',
  'password123',
  'passw0rd',
  'p@ssw0rd',
  '12345678',
  '123456789',
  '1234567890',
  'qwertyuiop',
  'qwerty123',
  'admin123',
  'admin1234',
  'welcome1',
  'welcome123',
  'letmein1',
  'iloveyou',
  '1q2w3e4r',
  'abc12345',
  'football',
  'monkey123',
]);

/**
 * NIST SP 800-63B style: length is the only hard rule.
 *
 * - Minimum 8 (recommend 12 in the UI copy; the server cannot force it
 *   without a per-password entropy estimate, which is out of scope).
 * - Maximum 128 (not a security limit — it prevents a DoS via bcrypt on
 *   pathological inputs).
 * - No character-class requirements: they reduce entropy in practice.
 * - No trimming: leading/trailing spaces are legitimate characters.
 *
 * The old regex rejected any password containing non-ASCII characters,
 * which is a real usability problem in an Arabic-first product.
 */
export const isValidPassword = (value: unknown): value is string => {
  if (typeof value !== 'string') return false;
  if (value.length < 8 || value.length > 128) return false;
  if (COMMON_PASSWORDS.has(value.toLowerCase())) return false;
  return true;
};

export const isValidPhoneNumber = (value: string): boolean => {
  const normalized = value.replace(/[^\d+]/g, '');
  const withoutCountryCode = normalized.replace(/^\+?20/, '');
  const local = withoutCountryCode.replace(/^0/, '');
  return /^1[0125]\d{8}$/.test(local);
};

export const isValidLicenseKey = (value: unknown): value is string => {
  if (typeof value !== 'string') return false;
  const normalized = value.trim().toUpperCase();
  if (normalized.length < 8 || normalized.length > 30) return false;
  return /^[A-Z0-9\u0600-\u06FF]+(-[A-Z0-9\u0600-\u06FF]+)+$/.test(normalized);
};

// --------------------------------------------------
// Tenant + idempotency
// --------------------------------------------------

/**
 * Public tenant identifier. Matches the DB CHECK constraint on
 * organizations.tenant_slug but applies the stricter 3–40 length up front
 * so the API rejects 1-char slugs before they hit Postgres.
 */
export const isValidTenantSlug = (value: unknown): value is string => {
  if (typeof value !== 'string') return false;
  if (value.length < 3 || value.length > 40) return false;
  return /^[a-z0-9]([a-z0-9-]*[a-z0-9])$/.test(value);
};

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ULID = /^[0-9A-HJKMNP-TV-Z]{26}$/;

export const isValidIdempotencyKey = (value: unknown): value is string => {
  if (typeof value !== 'string') return false;
  return UUID_V4.test(value) || ULID.test(value);
};

// --------------------------------------------------
// Roles (nine canonical tenant roles — see ADR-0004)
// --------------------------------------------------
//
// SUPER_ADMIN is NOT a tenant role: super admins live in `super_admins`
// with their own auth_user_id. MODERATOR and WH_MANAGER were removed.

export const VALID_ROLES = [
  'OWNER',
  'OPS_MANAGER',
  'ACCOUNTANT',
  'CASHIER',
  'COLLECTOR',
  'WAREHOUSE_MANAGER',
  'HR_MANAGER',
  'LAWYER',
  'EMPLOYEE',
] as const;

export type TenantRole = (typeof VALID_ROLES)[number];

export const isValidRole = (value: unknown): value is TenantRole =>
  typeof value === 'string' && (VALID_ROLES as readonly string[]).includes(value);

// --------------------------------------------------
// Permissions
// --------------------------------------------------
//
// Permissions are `<module>` or `<module>.<action>`. During the transition
// both forms are accepted; the module-level form gates the whole module.
// OWNER bypasses this check — do not encode that in the array.

export const VALID_MODULES = [
  'dashboard',
  'pos',
  'sales',
  'crm',
  'customers',
  'inventory',
  'purchases',
  'suppliers',
  'collection',
  'collections',
  'vaults',
  'treasury',
  'partners',
  'reports',
  'settings',
  'users',
  'hr',
  'attendance',
  'legal',
] as const;

export type ValidModule = (typeof VALID_MODULES)[number];

export const isValidPermission = (value: unknown): value is string => {
  if (typeof value !== 'string' || value.length === 0 || value.length > 64) return false;
  const parts = value.split('.');
  if (parts.length > 2) return false;
  const moduleName = parts[0];
  if (moduleName === undefined) return false;
  return (VALID_MODULES as readonly string[]).includes(moduleName);
};

export const isValidPermissions = (value: unknown): value is string[] => {
  if (!Array.isArray(value)) return false;
  return value.every(isValidPermission);
};

// --------------------------------------------------
// POS / sales
// --------------------------------------------------

export const VALID_SALE_TYPES = ['CASH', 'SHIPPING', 'INSTALLMENT'] as const;
export type ValidSaleType = (typeof VALID_SALE_TYPES)[number];

export const isValidSaleType = (value: string): value is ValidSaleType =>
  (VALID_SALE_TYPES as readonly string[]).includes(value);

export interface SaleItemInput {
  product_id: string;
  quantity: number;
}

/**
 * Cart lines: array of { product_id, quantity }, quantity a positive
 * integer. Price is deliberately NOT validated here — the service layer
 * always recomputes price from the product row (never trusts a
 * client-supplied total).
 */
export const isValidSaleItems = (value: unknown): value is SaleItemInput[] => {
  if (!Array.isArray(value) || value.length === 0) return false;
  return value.every((item) => {
    if (!item || typeof item !== 'object') return false;
    const obj = item as Record<string, unknown>;
    return (
      isNonEmptyString(obj.product_id) &&
      Number.isInteger(obj.quantity) &&
      (obj.quantity as number) > 0
    );
  });
};

export const isNonNegativeNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0;

export const isStrictlyPositiveNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value > 0;

export const isValidPositiveNumber = isStrictlyPositiveNumber;

export const isValidInstallmentCount = (value: unknown, maxMonths = 60): value is number =>
  typeof value === 'number' && Number.isInteger(value) && value > 0 && value <= maxMonths;

export const isValidMonthlyIncome = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value > 0;

export const isValidCreditScore = (value: unknown): value is number =>
  Number.isInteger(value) && typeof value === 'number' && value >= 0 && value <= 100;
