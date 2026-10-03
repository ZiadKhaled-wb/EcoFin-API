// Needs local Supabase (`npx -y supabase@2.119.0 start`) and the matching env vars in .env.
// Skipped unless RUN_INTEGRATION=1.
import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { HealthResponse } from '@ecotech/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';

describe.skipIf(process.env['RUN_INTEGRATION'] !== '1')(
  'GET /health against local Supabase',
  () => {
    it('returns 200 with db: ok', async () => {
      const res = await request(createApp({ env: getEnv() })).get('/health');
      expect(res.status).toBe(200);
      expect(HealthResponse.parse(res.body)).toMatchObject({ status: 'ok', db: 'ok' });
    });
  },
);
