// server/src/controllers/auth.controller.ts
//
// Thin handlers: parse the body with the contract schema (a ZodError, recognised by name, becomes VALIDATION_FAILED
// in the error handler), call the service, send the contract response.

import type { Request, Response } from 'express';
import {
  AuthChangePasswordBody,
  AuthForgotPasswordBody,
  AuthLoginBody,
  AuthRefreshBody,
  AuthResetPasswordBody,
  AuthSelectShopBody,
  type Ack,
  type AuthLoginResponse,
  type AuthMeResponse,
  type AuthRefreshResponse,
  type AuthSelectShopResponse,
} from '@ziadkhaled-wb/contracts';
import * as authService from '../services/auth.service';
import { requestMeta } from '../middleware/auth';
import type { RequestAuth } from '../types/express';
import { Unauthorized } from '../utils/errors';

const ACK: Ack = { ok: true };

function requireAuth(req: Request): RequestAuth {
  if (!req.auth) throw Unauthorized('Authentication required.', 'UNAUTHORIZED');
  return req.auth;
}

export async function login(req: Request, res: Response) {
  const body = AuthLoginBody.parse(req.body);
  const result: AuthLoginResponse = await authService.login(body, requestMeta(req));
  res.json(result);
}

export async function refresh(req: Request, res: Response) {
  const body = AuthRefreshBody.parse(req.body);
  const result: AuthRefreshResponse = await authService.refresh(body.refreshToken);
  res.json(result);
}

export async function selectShop(req: Request, res: Response) {
  const body = AuthSelectShopBody.parse(req.body);
  const result: AuthSelectShopResponse = await authService.selectShop(
    requireAuth(req),
    body.orgId,
    requestMeta(req),
  );
  res.json(result);
}

export async function logout(req: Request, res: Response) {
  await authService.logout(requireAuth(req), requestMeta(req));
  res.json(ACK);
}

export async function forgotPassword(req: Request, res: Response) {
  const body = AuthForgotPasswordBody.parse(req.body);
  await authService.forgotPassword(body);
  res.status(202).json(ACK);
}

export async function resetPassword(req: Request, res: Response) {
  const body = AuthResetPasswordBody.parse(req.body);
  await authService.resetPassword(body);
  res.json(ACK);
}

export async function changePassword(req: Request, res: Response) {
  const body = AuthChangePasswordBody.parse(req.body);
  await authService.changePassword(requireAuth(req), body, requestMeta(req));
  res.json(ACK);
}

export async function me(req: Request, res: Response) {
  const result: AuthMeResponse = await authService.getMe(requireAuth(req), requestMeta(req));
  res.json(result);
}
