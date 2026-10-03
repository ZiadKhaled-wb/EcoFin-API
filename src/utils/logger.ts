import 'dotenv/config';
import pino, { type DestinationStream, type Logger } from 'pino';

/**
 * Keys that may carry a credential, token or national id. Matching is case sensitive, so header
 * names are listed in lower case (Node lower-cases incoming header names).
 */
/** Shared with the error handler so both redact the same keys. */
export const SENSITIVE_KEYS = [
  'password',
  'newPassword',
  'confirmPassword',
  'currentPassword',
  'token',
  'accessToken',
  'refreshToken',
  'access_token',
  'refresh_token',
  'authorization',
  'cookie',
  'national_id',
  'nationalId',
  'apikey',
  'x-api-key',
  'license_key',
  'jwt',
  'SUPABASE_SERVICE_ROLE_KEY',
  'SUPABASE_ANON_KEY',
  'SUPABASE_JWT_SECRET',
];

/** Each key at the top level, one and two levels down, and in request headers and body. */
export const REDACT_PATHS = SENSITIVE_KEYS.flatMap((key) => {
  const k = /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) ? `.${key}` : `["${key}"]`;
  const top = k.startsWith('.') ? key : `["${key}"]`;
  return [
    top,
    `*${k}`,
    `*.*${k}`,
    `req.headers${k}`,
    `req.body${k}`,
    `req.body.*${k}`,
    `headers${k}`,
    `body${k}`,
    `body.*${k}`,
  ];
});

const LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace'];

function levelFromEnv(): string {
  const level = process.env['LOG_LEVEL'];
  return level !== undefined && LEVELS.includes(level) ? level : 'info';
}

export interface LoggerOptions {
  level?: string;
  stream?: DestinationStream;
}

/** Builds a redacting logger. `stream` lets tests capture the output. */
export function createLogger(options: LoggerOptions = {}): Logger {
  const config = {
    level: options.level ?? levelFromEnv(),
    redact: { paths: REDACT_PATHS },
    base: {
      service: process.env['SERVICE_NAME'] ?? 'fintech-pro-api',
      env: process.env['NODE_ENV'] ?? 'development',
    },
    timestamp: pino.stdTimeFunctions.isoTime,
  };
  return options.stream ? pino(config, options.stream) : pino(config);
}

/** Central logger. Configuration comes straight from process.env so importing it never throws. */
export const logger = createLogger();
