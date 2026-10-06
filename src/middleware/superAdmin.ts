import type { RequestHandler, Request } from 'express';
import { requestMeta } from './auth';
import { supabaseForRequest } from '../utils/supabase';
import { asyncHandler } from '../utils/asyncHandler';
import { AppError, ServerError } from '../utils/errors';

/** Platform requests must ignore even a malformed shop header before authenticate parses it. */
export const ignoreShopContext: RequestHandler = (req, _res, next) => {
  delete req.headers['x-org-id'];
  next();
};
export function adminDbFor(req: Request) {
  if (!req.auth) throw new Error('adminDbFor used before authenticate.');
  return supabaseForRequest(req.auth.accessToken, undefined, requestMeta(req));
}
export const requireSuperAdmin = asyncHandler(async (req, _res, next) => {
  if (!req.auth) throw new Error('requireSuperAdmin used before authenticate.');
  const { data, error } = await adminDbFor(req)
    .from('super_admins')
    .select('is_active')
    .eq('auth_user_id', req.auth.userId)
    .eq('is_active', true)
    .maybeSingle();
  if (error) throw ServerError('Request failed.');
  if (!data?.is_active) throw new AppError('Super admin required.', 'SUPER_ADMIN_REQUIRED');
  next();
});
