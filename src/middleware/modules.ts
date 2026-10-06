import type { ModuleKey } from '@ziadkhaled-wb/contracts';
import { getCtx } from './requestContext';
import { asyncHandler } from '../utils/asyncHandler';
import { mapDbError, ServerError } from '../utils/errors';
/** Optional feature gate; attach alongside the route's permission marker. */
export function requireModule(key: ModuleKey) {
  return asyncHandler(async (req, _res, next) => {
    const { error } = await getCtx(req).db.rpc('require_module', { p_module: key });
    if (error) throw mapDbError(error) ?? ServerError('Request failed.');
    next();
  });
}
