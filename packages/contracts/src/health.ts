import { z } from 'zod';
import { IsoTimestamp } from './common.js';

// F08 · GET /health
export const HealthResponse = z.object({
  status: z.enum(['ok', 'degraded']),
  db: z.enum(['ok', 'down']),
  version: z.string(),
  time: IsoTimestamp,
});
export const Health = { response: HealthResponse };
export type HealthResponse = z.infer<typeof HealthResponse>;
