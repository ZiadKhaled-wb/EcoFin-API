import {
  CurrentShift,
  Shift,
  ShiftList,
  ShiftVaultList,
  type ShiftCashBody,
  type ShiftCloseBody,
  type ShiftListQuery,
  type ShiftOpenBody,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'shift database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_shifts returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

/** K02: a cashier's own shifts; with cash.view every shift of the caller's branches. */
export async function listShifts(ctx: RequestContext, query: ShiftListQuery): Promise<ShiftList> {
  const { data, error } = await ctx.db.rpc('list_shifts', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.employee_id ? { p_employee_id: query.employee_id } : {}),
    ...(query.status ? { p_status: query.status } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return ShiftList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

/** The caller's open shift with its drawer movements, or null. */
export async function getCurrentShift(ctx: RequestContext): Promise<CurrentShift> {
  const { data, error } = await ctx.db.rpc('get_current_shift');
  if (error) fail(error);
  return CurrentShift.parse({ shift: data ?? null });
}

export async function getShift(ctx: RequestContext, id: string): Promise<Shift> {
  const { data, error } = await ctx.db.rpc('get_shift', { p_id: id });
  if (error) fail(error);
  return Shift.parse(data);
}

/** The branch's active safes a float can come from or cash can go to (names only). */
export async function listShiftVaults(
  ctx: RequestContext,
  branchId: string,
): Promise<ShiftVaultList> {
  const { data, error } = await ctx.db.rpc('list_shift_vaults', { p_branch_id: branchId });
  if (error) fail(error);
  return ShiftVaultList.parse(data);
}

/** K02 (D60): opens the caller's shift; the same idempotency key again returns the same shift. */
export async function openShift(
  ctx: RequestContext,
  body: ShiftOpenBody,
  idempotencyKey: string,
): Promise<Shift> {
  const { data, error } = await ctx.db.rpc('open_shift', {
    p_branch_id: body.branch_id,
    p_opening_float: body.opening_float,
    p_idempotency_key: idempotencyKey,
    ...(body.vault_id ? { p_vault_id: body.vault_id } : {}),
    ...(body.device_id ? { p_device_id: body.device_id } : {}),
  });
  if (error) fail(error);
  return Shift.parse(data);
}

/** Cash from a safe into the drawer (in) or from the drawer into a safe (out). */
export async function moveShiftCash(
  ctx: RequestContext,
  id: string,
  body: ShiftCashBody,
  idempotencyKey: string,
): Promise<Shift> {
  const { data, error } = await ctx.db.rpc('move_shift_cash', {
    p_shift_id: id,
    p_direction: body.direction,
    p_amount: body.amount,
    p_vault_id: body.vault_id,
    p_note: body.note,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return Shift.parse(data);
}

/** Counts the cash, books a difference (with its reason) and returns the cash to a safe. */
export async function closeShift(
  ctx: RequestContext,
  id: string,
  body: ShiftCloseBody,
): Promise<Shift> {
  const { data, error } = await ctx.db.rpc('close_shift', {
    p_id: id,
    p_counts: body.counts as Json,
    ...(body.vault_id ? { p_vault_id: body.vault_id } : {}),
    ...(body.difference_reason ? { p_difference_reason: body.difference_reason } : {}),
  });
  if (error) fail(error);
  return Shift.parse(data);
}
