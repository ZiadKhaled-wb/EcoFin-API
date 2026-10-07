// T01 tax classes. Reads and writes go through the caller's own client and the T01 database
// functions (catalog.manage, audited). Rates are decimal strings.
import {
  TaxClassList,
  Uuid,
  type TaxClass,
  type TaxClassCreateBody,
  type TaxClassUpdateBody,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { AppError, mapDbError, ServerError } from '../utils/errors';

function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

export async function listTaxClasses(ctx: RequestContext): Promise<TaxClass[]> {
  const { data, error } = await ctx.db.rpc('list_tax_classes');
  if (error) fail(error);
  return TaxClassList.parse(data);
}

async function one(ctx: RequestContext, id: string): Promise<TaxClass> {
  const found = (await listTaxClasses(ctx)).find((c) => c.id === id);
  if (!found) throw new AppError('Tax class not found.', 'TAX_CLASS_NOT_FOUND');
  return found;
}

export async function createTaxClass(ctx: RequestContext, body: TaxClassCreateBody) {
  const { data, error } = await ctx.db.rpc('create_tax_class', {
    p_name: body.name,
    p_kind: body.kind,
    p_rate: Number(body.rate),
    p_eta_tax_type: body.eta_tax_type,
    p_eta_subtype: body.eta_subtype,
  });
  if (error) fail(error);
  return one(ctx, Uuid.parse(data));
}

export async function updateTaxClass(ctx: RequestContext, id: string, body: TaxClassUpdateBody) {
  const { error } = await ctx.db.rpc('update_tax_class', { p_id: id, p_changes: body as Json });
  if (error) fail(error);
  return one(ctx, id);
}

export async function setTaxClassArchived(ctx: RequestContext, id: string, archived: boolean) {
  const { error } = await ctx.db.rpc('set_tax_class_archived', { p_id: id, p_archived: archived });
  if (error) fail(error);
  return one(ctx, id);
}
