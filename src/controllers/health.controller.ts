// server/src/controllers/health.controller.ts
//
// GET /health: public, no auth. Reports only the contract fields (status, db, version, time).
import type { Request, Response } from 'express';
import type { HealthResponse } from '@ecotech/contracts';
import { supabaseAdmin } from '../utils/supabase';
import { logger } from '../utils/logger';

/** API version reported by /health. Keep in step with package.json. */
export const API_VERSION = '0.1.0';
export const DB_CHECK_TIMEOUT_MS = 2000;

/**
 * Cheap round trip to Postgres through the server client: read one row id, with a short timeout.
 * Any error, exception or timeout counts as "down". Details are logged, never returned.
 */
export async function checkDb(timeoutMs = DB_CHECK_TIMEOUT_MS): Promise<boolean> {
  let timer: NodeJS.Timeout | undefined;
  try {
    const query = supabaseAdmin.from('organizations').select('id').limit(1);
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error('database check timed out')), timeoutMs);
    });
    const { error } = await Promise.race([Promise.resolve(query), timeout]);
    if (error) {
      logger.warn({ err: error }, 'health: database check failed');
      return false;
    }
    return true;
  } catch (err) {
    logger.warn({ err }, 'health: database check failed');
    return false;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export async function getHealth(_req: Request, res: Response): Promise<void> {
  const dbOk = await checkDb();
  const body: HealthResponse = {
    status: dbOk ? 'ok' : 'degraded',
    db: dbOk ? 'ok' : 'down',
    version: API_VERSION,
    time: new Date().toISOString(),
  };
  res.setHeader('Cache-Control', 'no-store');
  res.status(dbOk ? 200 : 503).json(body);
}
