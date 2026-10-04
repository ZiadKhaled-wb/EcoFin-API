// server/src/utils/tenant.ts
//
// F05 helpers that keep one shop out of another shop's data.
//
//   assertSameOrg(ctx, table, ids)   every foreign id in a request must belong to the caller's
//                                    shop. Missing or other-shop ids are both 404 NOT_FOUND, so
//                                    another shop's id looks exactly like one that doesn't exist.
//   tenantFilePath(ctx, ...parts)    the only way to build a private storage path: <orgId>/<parts>
//   assertOwnPath(ctx, path)         a stored path the caller wants to read must start with its
//                                    own <orgId>/ (bucket tenant-files; storage RLS checks it too).

import type { RequestContext } from '../middleware/requestContext';
import type { Database } from '../types/database.types';
import { BadRequest, NotFound, ServerError, mapDbError } from './errors';
import { logger } from './logger';

type PublicTable = keyof Database['public']['Tables'];

/**
 * Tables whose ids a request may reference. Fixed list, never built from user input; each has
 * `id uuid` and `organization_id`. Add a table here when an endpoint starts accepting its ids.
 */
export const SAME_ORG_TABLES = [
  'branches',
  'employees',
  'devices',
  'files',
  'categories',
  'tax_classes',
  'products',
  'units',
  'suppliers',
  'customers',
  'guarantors',
  'cash_accounts',
  'shifts',
  'expense_categories',
  'installment_policies',
  'purchase_orders',
  'purchase_invoices',
  'purchase_returns',
  'stock_transfers',
  'stock_counts',
  'stock_adjustments',
  'quotations',
  'sales_orders',
  'deliveries',
  'sales',
  'sales_returns',
  'warranty_claims',
  'contracts',
  'legal_cases',
  'payments',
  'expenses',
  'supplier_payments',
] as const satisfies readonly PublicTable[];

export type SameOrgTable = (typeof SAME_ORG_TABLES)[number];

type TenantCtx = Pick<RequestContext, 'db' | 'orgId'>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const notFound = () => NotFound('Not found.');

/**
 * Resolves when every id is a row of `table` in the caller's shop; otherwise 404 NOT_FOUND.
 * Reads through ctx.db (RLS-scoped to the active shop) and also filters on ctx.orgId.
 */
export async function assertSameOrg(
  ctx: TenantCtx,
  table: SameOrgTable,
  ids: readonly string[],
): Promise<void> {
  if (!(SAME_ORG_TABLES as readonly string[]).includes(table)) {
    // Only reachable by casting around the type: a programming error, never user input.
    throw new Error(`assertSameOrg: table "${String(table)}" is not in SAME_ORG_TABLES.`);
  }
  const wanted = [...new Set(ids.map((id) => id.toLowerCase()))];
  if (wanted.length === 0) return;
  // Not a uuid can't be a row; answer before the DB would fail on the cast.
  if (wanted.some((id) => !UUID.test(id))) throw notFound();

  const { data, error } = await ctx.db
    .from(table)
    .select('id')
    .eq('organization_id', ctx.orgId)
    .in('id', wanted);
  if (error) {
    const mapped = mapDbError(error);
    if (mapped) throw mapped;
    logger.error({ err: error, table }, 'assertSameOrg: select failed');
    throw ServerError('Request failed.');
  }
  const found = new Set((data as { id: string }[]).map((row) => row.id.toLowerCase()));
  if (wanted.some((id) => !found.has(id))) throw notFound();
}

/** One path part: no empty, `.`/`..`, backslash, NUL or other control characters. */
function checkPart(part: string): void {
  if (part === '' || part === '.' || part === '..' || /[\\\u0000-\u001f\u007f]/.test(part)) {
    throw BadRequest('Invalid file path.', 'VALIDATION_FAILED');
  }
}

/**
 * `<orgId>/<parts...>`. A part may itself contain `/` (e.g. `invoices/2026`), but an absolute
 * path, `..`, `.`, an empty part or a backslash is refused with 400 VALIDATION_FAILED.
 */
export function tenantFilePath(ctx: Pick<RequestContext, 'orgId'>, ...parts: string[]): string {
  if (parts.length === 0) throw BadRequest('Invalid file path.', 'VALIDATION_FAILED');
  const pieces = parts.flatMap((part) => part.split('/'));
  pieces.forEach(checkPart);
  return [ctx.orgId, ...pieces].join('/');
}

/**
 * Returns `path` when it is a well-formed path under the caller's own `<orgId>/`; another shop's
 * prefix (or a malformed path) is 404 NOT_FOUND, like a file that doesn't exist.
 */
export function assertOwnPath(ctx: Pick<RequestContext, 'orgId'>, path: string): string {
  const [first, ...rest] = path.split('/');
  if (first?.toLowerCase() !== ctx.orgId.toLowerCase() || rest.length === 0) throw notFound();
  try {
    rest.forEach(checkPart);
  } catch {
    throw notFound();
  }
  return path;
}
