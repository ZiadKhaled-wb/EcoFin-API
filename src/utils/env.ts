// server/src/utils/env.ts
//
// Environment configuration. Nothing here runs at import time: `loadEnv()` parses a source and
// either returns the typed env or throws ONE error naming every bad or missing variable (never
// their values). `server.ts` calls `getEnv()` on startup so a bad deployment stops
// with a clear message; tests can import any module freely.
import 'dotenv/config';

import { z } from 'zod';

const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace'] as const;

/** Comma-separated origins -> normalised origin strings (`https://host[:port]`). */
function parseOrigins(raw: string, ctx: z.RefinementCtx): string[] {
  const origins: string[] = [];
  for (const part of raw.split(',')) {
    const value = part.trim();
    if (value === '') continue;
    try {
      const url = new URL(value);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('protocol');
      origins.push(url.origin);
    } catch {
      // `*` and anything that is not an http(s) origin is rejected: the allow-list is strict.
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'not a valid http(s) origin' });
      return z.NEVER;
    }
  }
  return origins;
}

/** `false` or a number of proxy hops. */
function parseTrustProxy(raw: string, ctx: z.RefinementCtx): number | false {
  const value = raw.trim().toLowerCase();
  if (value === 'false') return false;
  if (/^\d+$/.test(value)) return Number(value);
  ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'must be a number of hops or false' });
  return z.NEVER;
}

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  PORT: z.coerce.number().int().positive().max(65535).default(3001),
  SERVICE_NAME: z.string().min(1).default('fintech-pro-api'),

  SUPABASE_URL: z.string().url(),
  SUPABASE_ANON_KEY: z.string().min(1),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1),
  // Optional. Needed only if we switch to local JWT verification.
  SUPABASE_JWT_SECRET: z.string().min(1).optional(),

  FRONTEND_URL: z.string().url(),
  INVITE_TTL_HOURS: z.coerce.number().int().min(1).max(168).default(72),
  SMTP_URL: z
    .string()
    .url()
    .refine((v) => /^smtps?:\/\//.test(v))
    .optional(),
  MAIL_FROM: z.string().min(1).optional(),
  // Comma-separated CORS allow-list. Required in production; elsewhere it defaults to FRONTEND_URL.
  CORS_ALLOWED_ORIGINS: z.string().transform(parseOrigins).optional(),
  // Number of reverse-proxy hops to trust for the client IP, or `false`.
  TRUST_PROXY: z.string().default('1').transform(parseTrustProxy),

  LOG_LEVEL: z.enum(LOG_LEVELS).default('info'),
  LOG_DRAIN_URL: z.string().url().optional(),

  // Optional. If set, the rate limiters use Redis so limits are shared across API instances.
  RATE_LIMIT_REDIS_URL: z.string().url().optional(),

  // D17 failed-login lockout: this many failures for one identifier (per shop) inside the window
  // returns TOO_MANY_LOGIN_ATTEMPTS before Supabase Auth is called.
  LOGIN_MAX_FAILURES: z.coerce.number().int().min(1).max(1000).default(5),
  LOGIN_WINDOW_MINUTES: z.coerce
    .number()
    .int()
    .min(1)
    .max(24 * 60)
    .default(15),

  // F13 background jobs (D34): the worker runs inside the API process. Safe on several instances.
  JOBS_ENABLED: z
    .enum(['true', 'false'])
    .default('true')
    .transform((v) => v === 'true'),
  JOBS_POLL_SECONDS: z.coerce.number().int().min(5).max(3600).default(30),

  // F14 file storage. The bucket refuses more than 10 MB, so the cap is the bucket's limit.
  FILE_MAX_BYTES: z.coerce.number().int().min(1).max(10485760).default(10485760),
  // Lifetime of a signed download link, in seconds.
  FILE_URL_TTL_SECONDS: z.coerce.number().int().min(1).max(3600).default(60),

  // Q02 error tracking (D35). Without a DSN nothing is sent anywhere.
  SENTRY_DSN: z.string().url().optional(),
  // Shown in Sentry; the dev VM runs NODE_ENV=production, so set this to `development` there.
  SENTRY_ENVIRONMENT: z.string().min(1).max(64).optional(),
  // The deployed build (image tag `sha-<commit>`), set by the Dockerfile.
  APP_RELEASE: z.string().min(1).max(100).optional(),

  // T02 ETA e-receipts (D67). The hosts of the two ETA systems; the defaults are the ones the
  // SDK documents (docs/eta/ERECEIPT_SPEC.md, section 1). A shop's eta_settings.environment picks
  // the set: a prod shop is never sent to a preprod host or the reverse.
  ETA_PREPROD_ID_URL: z.string().url().default('https://id.preprod.eta.gov.eg'),
  ETA_PREPROD_API_URL: z.string().url().default('https://api.preprod.invoicing.eta.gov.eg'),
  ETA_PREPROD_PORTAL_URL: z.string().url().default('https://preprod.invoicing.eta.gov.eg'),
  ETA_PROD_ID_URL: z.string().url().default('https://id.eta.gov.eg'),
  ETA_PROD_API_URL: z.string().url().default('https://api.invoicing.eta.gov.eg'),
  ETA_PROD_PORTAL_URL: z.string().url().default('https://invoicing.eta.gov.eg'),
});

type ParsedEnv = z.infer<typeof envSchema>;
export type Env = Omit<ParsedEnv, 'CORS_ALLOWED_ORIGINS'> & {
  /** Final allow-list (normalised origins). Never contains `*`. */
  CORS_ALLOWED_ORIGINS: string[];
};

function isLocalHost(host: string): boolean {
  return host === 'localhost' || host === '127.0.0.1' || host.endsWith('.local');
}

export function loadEnv(source: Record<string, string | undefined> = process.env): Env {
  const parsed = envSchema.safeParse(source);

  // variable name -> reason. Names and reasons only, never values.
  const problems = new Map<string, string>();

  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      const name = issue.path.join('.') || '(root)';
      if (problems.has(name)) continue;
      const missing = issue.code === 'invalid_type' && issue.received === 'undefined';
      problems.set(name, missing ? 'missing' : 'invalid');
    }
  } else {
    const data = parsed.data;
    // Two environments on one host would send test receipts to the real ETA (or the reverse).
    for (const kind of ['ID', 'API'] as const) {
      const prod = new URL(data[`ETA_PROD_${kind}_URL`]).host;
      if (prod === new URL(data[`ETA_PREPROD_${kind}_URL`]).host) {
        problems.set(`ETA_PROD_${kind}_URL`, 'must not be the pre-production host');
      }
    }
    if (data.NODE_ENV === 'production') {
      if (!data.SMTP_URL) problems.set('SMTP_URL', 'missing (required in production)');
      if (!data.MAIL_FROM) problems.set('MAIL_FROM', 'missing (required in production)');
      if (!data.CORS_ALLOWED_ORIGINS || data.CORS_ALLOWED_ORIGINS.length === 0) {
        problems.set('CORS_ALLOWED_ORIGINS', 'missing (required in production)');
      }
      // A production deployment pointing at a developer laptop is a silent security hole
      // (service-role key leaking to a local Supabase).
      if (isLocalHost(new URL(data.SUPABASE_URL).hostname)) {
        problems.set('SUPABASE_URL', 'must not point to a local host in production');
      }
    }
  }

  if (problems.size > 0 || !parsed.success) {
    const list = [...problems].map(([name, reason]) => `${name} (${reason})`).join(', ');
    throw new Error(`Invalid environment configuration. Fix these variables: ${list}`);
  }

  const data = parsed.data;
  const origins =
    data.CORS_ALLOWED_ORIGINS && data.CORS_ALLOWED_ORIGINS.length > 0
      ? data.CORS_ALLOWED_ORIGINS
      : [new URL(data.FRONTEND_URL).origin];

  return { ...data, CORS_ALLOWED_ORIGINS: origins };
}

let cached: Env | undefined;

/** Loads `process.env` once and caches it. Call it on startup so failures happen there. */
export function getEnv(): Env {
  cached ??= loadEnv(process.env);
  return cached;
}
