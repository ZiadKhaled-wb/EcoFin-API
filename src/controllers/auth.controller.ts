// server/src/controllers/auth.controller.ts
//
// Thin handlers: parse the body with the contract schema (a ZodError becomes VALIDATION_FAILED
// in the error handler), call the service, send the contract response.

import type { Request, Response } from 'express';
import {
  AuthChangePasswordBody,
  AuthForgotPasswordBody,
  AuthLoginBody,
  AuthRefreshBody,
  AuthResetPasswordBody,
  type Ack,
  type AuthLoginResponse,
  type AuthMeResponse,
  type AuthRefreshResponse,
} from '@ecotech/contracts';
import * as authService from '../services/auth.service';
import { requestMeta } from '../middleware/auth';
import type { RequestAuth } from '../types/express';
import { BadRequest, Unauthorized } from '../utils/errors';

const ACK: Ack = { ok: true };

interface BodySchema<T> {
  safeParse(input: unknown):
    | { success: true; data: T }
    | {
        success: false;
        error: { issues: { path: (string | number)[]; code: string; message: string }[] };
      };
}

/**
 * Parses a body with its contract schema. The contracts package brings its own zod copy, so its
 * ZodError is not an instance of the API's ZodError and the error handler would answer 500. This
 * returns the same 400 VALIDATION_FAILED shape the error handler uses for zod errors.
 */
function parseBody<T>(schema: BodySchema<T>, body: unknown): T {
  const result = schema.safeParse(body ?? {});
  if (result.success) return result.data;
  throw BadRequest(
    'Validation failed.',
    'VALIDATION_FAILED',
    result.error.issues.map((issue) => ({
      path: issue.path.join('.'),
      code: issue.code,
      message: issue.message,
    })),
  );
}

function requireAuth(req: Request): RequestAuth {
  if (!req.auth) throw Unauthorized('Authentication required.', 'UNAUTHORIZED');
  return req.auth;
}

export async function login(req: Request, res: Response) {
  const body = parseBody(AuthLoginBody, req.body);
  const result: AuthLoginResponse = await authService.login(body, requestMeta(req));
  res.json(result);
}

export async function refresh(req: Request, res: Response) {
  const body = parseBody(AuthRefreshBody, req.body);
  const result: AuthRefreshResponse = await authService.refresh(body.refreshToken);
  res.json(result);
}

export async function logout(req: Request, res: Response) {
  await authService.logout(requireAuth(req), requestMeta(req));
  res.json(ACK);
}

export async function forgotPassword(req: Request, res: Response) {
  const body = parseBody(AuthForgotPasswordBody, req.body);
  await authService.forgotPassword(body);
  res.status(202).json(ACK);
}

export async function resetPassword(req: Request, res: Response) {
  const body = parseBody(AuthResetPasswordBody, req.body);
  await authService.resetPassword(body);
  res.json(ACK);
}

export async function changePassword(req: Request, res: Response) {
  const body = parseBody(AuthChangePasswordBody, req.body);
  await authService.changePassword(requireAuth(req), body, requestMeta(req));
  res.json(ACK);
}

export async function me(req: Request, res: Response) {
  const result: AuthMeResponse = await authService.getMe(requireAuth(req), requestMeta(req));
  res.json(result);
}
