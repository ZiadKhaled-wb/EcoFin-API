// server/src/middleware/rateLimit.ts
//
// Rate limiters for the unauthenticated auth endpoints. The store is
// in-memory by default (per-process — fine for a single API instance, NOT
// fine behind a load balancer). Set RATE_LIMIT_REDIS_URL to share state
// across instances.
//
// Requires `express-rate-limit` v7+. Requires `req.ip` to be meaningful —
// the app must set `app.set('trust proxy', 1)` behind a reverse proxy.

import rateLimit from 'express-rate-limit';
import type { Request } from 'express';
import { env } from '../utils/env';
import { logger } from '../utils/logger';

type RateLimitOptions = NonNullable<Parameters<typeof rateLimit>[0]>;
type StoreOption = NonNullable<RateLimitOptions['store']>;

function buildStore(): StoreOption | undefined {
    if (!env.RATE_LIMIT_REDIS_URL) return undefined;
    try {
        // Lazy require so the app doesn't fail to boot when Redis isn't
        // installed (the packages are optional peer deps for this module).
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { RedisStore } = require('rate-limit-redis') as {
            RedisStore: new (opts: {
                sendCommand: (...args: string[]) => Promise<unknown>;
            }) => StoreOption;
        };
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const Redis = require('ioredis') as new (url: string) => {
            call: (...args: string[]) => Promise<unknown>;
        };
        const client = new Redis(env.RATE_LIMIT_REDIS_URL);
        return new RedisStore({
            sendCommand: (...args: string[]) => client.call(...args),
        });
    } catch (err) {
        logger.error(
            { err },
            'RATE_LIMIT_REDIS_URL is set but Redis store could not be loaded; falling back to in-memory',
        );
        return undefined;
    }
}

const store = buildStore();

// Key on IP + tenant_slug when the body has one. A shared NAT (a customer's
// office) should not be able to lock out an unrelated tenant, and a single
// bad tenant should not consume the whole IP budget.
function keyGenerator(req: Request): string {
    const ip = req.ip ?? 'unknown';
    const body = req.body as Record<string, unknown> | undefined;
    const slug = typeof body?.tenant_slug === 'string' ? body.tenant_slug : '';
    return slug ? `${ip}|${slug}` : ip;
}

const shared = {
    standardHeaders: 'draft-7' as const,
    legacyHeaders: false,
    keyGenerator,
    ...(store ? { store } : {}),
};

const TOO_MANY_MESSAGE = {
    error: 'محاولات كثيرة جداً. يرجى المحاولة لاحقاً.',
    code: 'TOO_MANY_REQUESTS',
};

export const loginLimiter = rateLimit({
    ...shared,
    windowMs: 15 * 60 * 1000,
    limit: 10,
    message: TOO_MANY_MESSAGE,
});

export const licenseLimiter = rateLimit({
    ...shared,
    windowMs: 15 * 60 * 1000,
    limit: 20,
    message: TOO_MANY_MESSAGE,
});

export const forgotPasswordLimiter = rateLimit({
    ...shared,
    windowMs: 60 * 60 * 1000,
    limit: 5,
    message: TOO_MANY_MESSAGE,
});