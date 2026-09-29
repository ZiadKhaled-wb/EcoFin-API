// server/src/utils/errors.ts
//
// Every error thrown by the service layer carries a machine-readable `code`
// alongside the human-readable `message`. The controller/errorHandler layer
// never has to parse strings to decide how to react.

export type ErrorCode =
    // Generic
    | 'BAD_REQUEST'
    | 'UNAUTHORIZED'
    | 'FORBIDDEN'
    | 'NOT_FOUND'
    | 'CONFLICT'
    | 'UNPROCESSABLE_ENTITY'
    | 'TOO_MANY_REQUESTS'
    | 'INTERNAL'
    // Auth-specific
    | 'INVALID_CREDENTIALS'
    | 'TENANT_NOT_FOUND'
    | 'TENANT_SCOPE_REQUIRED'
    | 'ACCOUNT_DISABLED'
    | 'MUST_CHANGE_PASSWORD'
    | 'LICENSE_INVALID'
    | 'LICENSE_USED'
    | 'LICENSE_EXPIRED'
    | 'LICENSE_NOT_PROVISIONED'
    | 'VALIDATION_FAILED';

export class AppError extends Error {
    public readonly statusCode: number;
    public readonly code: ErrorCode;
    public readonly details?: unknown;

    constructor(message: string, code: ErrorCode, statusCode = 500, details?: unknown) {
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