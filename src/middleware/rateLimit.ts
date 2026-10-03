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
import type { RedisReply } from 'rate-limit-redis';
import type { Request } from 'express';
import { env } from '../utils/env';
import { logger } from '../utils/logger';

type RateLimitOptions = NonNullable<Parameters<typeof rateLimit>[0]>;
type StoreOption = NonNullable<RateLimitOptions['store']>;

async function buildStore(): Promise<StoreOption | undefined> {
  if (!env.RATE_LIMIT_REDIS_URL) return undefined;

  try {
    // Dynamic import for ESM compatibility — require() is not available
    // in ESM modules. ioredis uses raw TCP which is not supported in
    // Cloudflare Workers, so this will fail gracefully there.
    const { RedisStore } = await import('rate-limit-redis');
    const { default: Redis } = await import('ioredis');
    const client = new Redis(env.RATE_LIMIT_REDIS_URL);
    return new RedisStore({
      sendCommand: (command: string, ...args: string[]) =>
        client.call(command, ...args) as Promise<RedisReply>,
    });
  } catch (err) {
    logger.warn(
      { err },
      'RATE_LIMIT_REDIS_URL is set but Redis store could not be loaded; falling back to in-memory rate limiting',
    );
    return undefined;
  }
}

const store = await buildStore();

function createMemoryStore(windowMs: number): StoreOption {
  const clients = new Map<string, { totalHits: number; resetTime: Date }>();
  let nextCleanupAt = 0;

  return {
    localKeys: true,
    async increment(key) {
      const now = Date.now();
      if (now >= nextCleanupAt) {
        for (const [clientKey, client] of clients) {
          if (client.resetTime.getTime() <= now) clients.delete(clientKey);
        }
        nextCleanupAt = now + windowMs;
      }

      let client = clients.get(key);
      if (!client || client.resetTime.getTime() <= now) {
        client = { totalHits: 0, resetTime: new Date(now + windowMs) };
        clients.set(key, client);
      }
      client.totalHits += 1;
      return client;
    },
    async decrement(key) {
      const client = clients.get(key);
      if (client && client.totalHits > 0) client.totalHits -= 1;
    },
    async resetKey(key) {
      clients.delete(key);
    },
    async resetAll() {
      clients.clear();
    },
  };
}

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
};

const TOO_MANY_MESSAGE = {
  error: 'محاولات كثيرة جداً. يرجى المحاولة لاحقاً.',
  code: 'TOO_MANY_REQUESTS',
};

export const loginLimiter = rateLimit({
  ...shared,
  store: store ?? createMemoryStore(15 * 60 * 1000),
  windowMs: 15 * 60 * 1000,
  limit: 10,
  message: TOO_MANY_MESSAGE,
});

export const licenseLimiter = rateLimit({
  ...shared,
  store: store ?? createMemoryStore(15 * 60 * 1000),
  windowMs: 15 * 60 * 1000,
  limit: 20,
  message: TOO_MANY_MESSAGE,
});

export const forgotPasswordLimiter = rateLimit({
  ...shared,
  store: store ?? createMemoryStore(60 * 60 * 1000),
  windowMs: 60 * 60 * 1000,
  limit: 5,
  message: TOO_MANY_MESSAGE,
});
