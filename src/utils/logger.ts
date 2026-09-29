import pino from 'pino';
import { env } from './env';

/**
 * Central logger. Redaction is intentionally aggressive — any field likely to
 * carry a credential or session token is censored before it hits stdout.
 * Extend the list when you add a new credential-bearing field, not later.
 */
export const logger = pino({
    level: env.LOG_LEVEL,
    redact: {
        paths: [
            // Passwords and secrets
            'password', '*.password',
            'confirmPassword', '*.confirmPassword',
            'newPassword', '*.newPassword',
            'currentPassword', '*.currentPassword',
            'license_key', '*.license_key',
            'SUPABASE_SERVICE_ROLE_KEY',
            'SUPABASE_ANON_KEY',
            'SUPABASE_JWT_SECRET',
            // Session / auth material
            'authorization', '*.authorization',
            'req.headers.authorization', 'req.headers.cookie',
            'refresh_token', '*.refresh_token',
            'access_token', '*.access_token',
            'jwt', '*.jwt',
            'token', '*.token',
        ],
        censor: '[REDACTED]',
    },
    base: {
        service: env.SERVICE_NAME,
        env: env.NODE_ENV,
    },
    timestamp: pino.stdTimeFunctions.isoTime,
});