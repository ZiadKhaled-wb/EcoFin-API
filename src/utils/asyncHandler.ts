import type { Request, Response, NextFunction, RequestHandler } from 'express';

export type AsyncRequestHandler = (
    req: Request,
    res: Response,
    next: NextFunction,
) => Promise<unknown>;

/**
 * Wraps an async Express handler so any rejection (a thrown AppError, a raw
 * Error, a Supabase error turned into a throw) lands in errorHandler instead
 * of becoming an unhandled rejection. Sync throws are caught by Express itself.
 */
export const asyncHandler = (fn: AsyncRequestHandler): RequestHandler => {
    return (req, res, next) => {
        // Promise.resolve handles a handler that (accidentally) returns a
        // non-Promise value — we still want a uniform .catch.
        Promise.resolve(fn(req, res, next)).catch(next);
    };
};