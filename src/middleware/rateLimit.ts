// server/src/middleware/rateLimit.ts
//
// Rate limiters for the unauthenticated auth endpoints. The store is in-memory by default
// (per-process: fine for a single API instance, NOT fine behind a load balancer). Set
// RATE_LIMIT_REDIS_URL to share state across instances.
//
// The key is the client IP as Express resolves it (`req.ip`). Behind a reverse proxy that only
// works when the app sets `trust proxy` (env TRUST_PROXY, see createApp): with it on, Express
// reads the client from X-Forwarded-For; with it off, X-Forwarded-For is ignored (so a client
// cannot pick its own bucket). Nothing here reads X-Forwarded-For itself.
//
// Nothing runs at import time: the env and the Redis connection are read on the first request.

import rateLimit from 'express-rate-limit';
import type { RedisReply } from 'rate-limit-redis';
import type { Request, Response, RequestHandler } from 'express';
import { errorCodeHttpStatus, type ErrorResponse } from '@ecotech/contracts';
import { getEnv } from '../utils/env';
import { logger } from '../utils/logger';

type RateLimitOptions = NonNullable<Parameters<typeof rateLimit>[0]>;
type StoreOption = NonNullable<RateLimitOptions['store']>;

export function createMemoryStore(windowMs: number): StoreOption {
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

type RedisCall = (command: string, ...args: string[]) => Promise<RedisReply>;
let redisClient: Promise<RedisCall | undefined> | undefined;

/** One Redis connection shared by every limiter, created on first use. */
function getRedisCall(): Promise<RedisCall | undefined> {
  redisClient ??= (async () => {
    const url = getEnv().RATE_LIMIT_REDIS_URL;
    if (!url) return undefined;
    try {
      // Dynamic import: ioredis uses raw TCP, which Cloudflare Workers don't support,
      // so this fails gracefully there.
      const { default: Redis } = await import('ioredis');
      const client = new Redis(url);
      return (command, ...args) => client.call(command, ...args) as Promise<RedisReply>;
    } catch (err) {
      logger.warn(
        { err },
        'RATE_LIMIT_REDIS_URL is set but Redis could not be loaded; falling back to in-memory rate limiting',
      );
      return undefined;
    }
  })();
  return redisClient;
}

async function buildStore(name: string, windowMs: number): Promise<StoreOption> {
  const sendCommand = await getRedisCall();
  if (!sendCommand) return createMemoryStore(windowMs);
  const { RedisStore } = await import('rate-limit-redis');
  // A prefix per limiter, so the login and forgot-password counters never share keys.
  return new RedisStore({ sendCommand, prefix: `rl:${name}:` });
}

// Key on IP + tenant_slug when the body has one. A shared NAT (a customer's
// office) should not be able to lock out an unrelated tenant, and a single
// bad tenant should not consume the whole IP budget.
function keyGenerator(req: Request): string {
  const ip = req.ip ?? 'unknown';
  const body = req.body as Record<string, unknown> | undefined;
  const slug = typeof body?.['tenant_slug'] === 'string' ? body['tenant_slug'] : '';
  return slug ? `${ip}|${slug}` : ip;
}

function tooManyRequests(req: Request, res: Response): void {
  const body: ErrorResponse = {
    error: {
      code: 'TOO_MANY_REQUESTS',
      message: 'Too many requests. Please try again later.',
      ...(req.requestId !== undefined ? { requestId: req.requestId } : {}),
    },
  };
  res.status(errorCodeHttpStatus.TOO_MANY_REQUESTS).json(body);
}

export interface LimiterOptions {
  windowMs: number;
  limit: number;
  store?: StoreOption;
}

/** A limiter keyed by client IP (as Express resolves it), answering with the contract error. */
export function createLimiter(options: LimiterOptions): RequestHandler {
  return rateLimit({
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    keyGenerator,
    handler: tooManyRequests,
    store: options.store ?? createMemoryStore(options.windowMs),
    windowMs: options.windowMs,
    limit: options.limit,
  });
}

/** Builds its store (memory or Redis) on the first request, so importing this file is free. */
function lazyLimiter(name: string, options: LimiterOptions): RequestHandler {
  let ready: Promise<RequestHandler> | undefined;
  return (req, res, next) => {
    ready ??= buildStore(name, options.windowMs).then((store) =>
      createLimiter({ ...options, store }),
    );
    ready.then((handler) => handler(req, res, next), next);
  };
}

export const loginLimiter = lazyLimiter('login', { windowMs: 15 * 60 * 1000, limit: 10 });
export const licenseLimiter = lazyLimiter('license', { windowMs: 15 * 60 * 1000, limit: 20 });
export const forgotPasswordLimiter = lazyLimiter('forgot', { windowMs: 60 * 60 * 1000, limit: 5 });
