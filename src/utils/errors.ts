// server/src/utils/errors.ts
//
// Every error thrown by the service layer carries a machine-readable `code`
// alongside the human-readable `message`. The controller/errorHandler layer
// never has to parse strings to decide how to react. Codes come from the shared contracts.

import {
  errorCodeHttpStatus,
  PlanLimitDetail,
  PlanDowngradeDetail,
  BranchDeactivationCheck,
  CategoryInUseDetail,
  SerialTakenDetail,
  type ErrorCode,
} from '@ziadkhaled-wb/contracts';

export type { ErrorCode };

export class AppError extends Error {
  public readonly statusCode: number;
  public readonly code: ErrorCode;
  public readonly details?: unknown;

  constructor(
    message: string,
    code: ErrorCode,
    statusCode: number = errorCodeHttpStatus[code],
    details?: unknown,
  ) {
    super(message);
    // Restore prototype chain — TS target < ES6 loses `instanceof AppError`.
    Object.setPrototypeOf(this, AppError.prototype);
    this.name = 'AppError';
    this.code = code;
    this.statusCode = statusCode;
    this.details = details;
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, AppError);
    }
  }
}

export const BadRequest = (message: string, code: ErrorCode = 'BAD_REQUEST', details?: unknown) =>
  new AppError(message, code, 400, details);

export const Unauthorized = (message: string, code: ErrorCode = 'UNAUTHORIZED') =>
  new AppError(message, code, 401);

export const Forbidden = (message: string, code: ErrorCode = 'FORBIDDEN') =>
  new AppError(message, code, 403);

export const NotFound = (message: string, code: ErrorCode = 'NOT_FOUND') =>
  new AppError(message, code, 404);

export const Conflict = (message: string, code: ErrorCode = 'CONFLICT') =>
  new AppError(message, code, 409);

export const UnprocessableEntity = (message: string, details?: unknown) =>
  new AppError(message, 'UNPROCESSABLE_ENTITY', 422, details);

export const TooManyRequests = (message: string, details?: unknown) =>
  new AppError(message, 'TOO_MANY_REQUESTS', 429, details);

export const ServerError = (message: string, details?: unknown) =>
  new AppError(message, 'INTERNAL', 500, details);

/** `OUT_OF_STOCK` -> `Out of stock.` A generic message; the client localises from the code. */
export function safeMessage(code: ErrorCode): string {
  const words = code.toLowerCase().replaceAll('_', ' ');
  return `${words.charAt(0).toUpperCase()}${words.slice(1)}.`;
}

/**
 * Turns a database error into an AppError when its message starts with a contract error code
 * (`OUT_OF_STOCK: product ...`, `PERMISSION_DENIED`, `DAY_CLOSED: ...`). Returns undefined for
 * anything else. Raw messages and hints are never copied. Only subscription limit details
 * validated by the shared contracts are exposed alongside the safe generic message.
 */
export function mapDbError(err: unknown): AppError | undefined {
  if (typeof err !== 'object' || err === null) return undefined;
  const message = (err as { message?: unknown }).message;
  if (typeof message !== 'string') return undefined;
  const token = /^([A-Z][A-Z0-9_]*)(?![A-Za-z0-9_])/.exec(message)?.[1];
  if (token === undefined || !Object.hasOwn(errorCodeHttpStatus, token)) return undefined;
  const code = token as ErrorCode;
  let details: unknown;
  if (
    code === 'PLAN_LIMIT_REACHED' ||
    code === 'PLAN_DOWNGRADE_BLOCKED' ||
    code === 'BRANCH_DEACTIVATE_NEEDS_CONFIRM' ||
    code === 'CATEGORY_IN_USE' ||
    code === 'SERIAL_TAKEN'
  ) {
    try {
      const raw = (err as { details?: unknown }).details;
      if (typeof raw === 'string') {
        const parsed = (
          code === 'PLAN_LIMIT_REACHED'
            ? PlanLimitDetail
            : code === 'PLAN_DOWNGRADE_BLOCKED'
              ? PlanDowngradeDetail
              : code === 'CATEGORY_IN_USE'
                ? CategoryInUseDetail
                : code === 'SERIAL_TAKEN'
                  ? SerialTakenDetail
                  : BranchDeactivationCheck
        ).safeParse(JSON.parse(raw));
        if (parsed.success) details = parsed.data;
      }
    } catch {
      /* Invalid DB detail is omitted. */
    }
  }
  return new AppError(safeMessage(code), code, errorCodeHttpStatus[code], details);
}
