// server/src/services/permissions.service.ts
//
// F06: the caller's effective permissions and branch scope, from public.my_permissions()
// (role defaults +/- per-employee overrides; OWNER has every key and every branch). Read at most
// once per request: requirePermission and GET /api/me/permissions share the same promise.

import { MePermissionsResponse } from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { ServerError, mapDbError } from '../utils/errors';
import { logger } from '../utils/logger';

const loaded = new WeakMap<RequestContext, Promise<MePermissionsResponse>>();

/** The caller's effective permissions and branch scope; one DB call per request at most. */
export function getMyPermissions(ctx: RequestContext): Promise<MePermissionsResponse> {
  let pending = loaded.get(ctx);
  if (!pending) {
    pending = fetchMyPermissions(ctx);
    loaded.set(ctx, pending);
  }
  return pending;
}

async function fetchMyPermissions(ctx: RequestContext): Promise<MePermissionsResponse> {
  const { data, error } = await ctx.db.rpc('my_permissions').single();
  if (error) {
    const mapped = mapDbError(error);
    if (mapped) throw mapped;
    logger.error({ err: error }, 'my_permissions failed');
    throw ServerError('Request failed.');
  }
  // A key the contract doesn't know means the DB and the contracts drifted: a server error.
  const parsed = MePermissionsResponse.safeParse({
    keys: data.keys,
    branchIds: data.branch_ids,
    allBranches: data.all_branches,
  });
  if (!parsed.success) {
    logger.error({ issues: parsed.error.issues }, 'my_permissions: response outside the contract');
    throw ServerError('Request failed.');
  }
  return parsed.data;
}
