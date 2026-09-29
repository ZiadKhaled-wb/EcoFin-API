// server/src/utils/env.ts
//
// Single source of truth for environment configuration. Importing this file
// throws if the environment is invalid — fail fast, not at 3 AM.
import 'dotenv/config';

import { z } from 'zod';

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

    LOG_LEVEL: z
        .enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace'])
        .default('info'),
    LOG_DRAIN_URL: z.string().url().optional(),

    // Optional. If set, the auth rate limiter uses Redis so limits are
    // shared across API instances.
    RATE_LIMIT_REDIS_URL: z.string().url().optional(),
});

const parsed = envSchema.safeParse(process.env);

if (!parsed.success) {
    // Only field names — never values.
    const fields = [...new Set(parsed.error.issues.map((i) => i.path.join('.') || '(root)'))];
    throw new Error(
        `Invalid environment configuration. Fix these fields: ${fields.join(', ')}`,
    );
}

const data = parsed.data;

// Guardrail: a production deployment pointing at a developer laptop is a
// silent security hole (service-role key leaking to a local Supabase).
if (data.NODE_ENV === 'production') {
    const host = new URL(data.SUPABASE_URL).hostname;
    if (host === 'localhost' || host === '127.0.0.1' || host.endsWith('.local')) {
        throw new Error(
            'Invalid environment configuration: SUPABASE_URL must not point to a local host in production.',
        );
    }
}

export const env = data;