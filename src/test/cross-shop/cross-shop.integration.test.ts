// F05 cross-shop suite against local Supabase: every case in cases.ts, through the real app
// (in-process, supertest) + local GoTrue + Postgres. Skipped unless RUN_INTEGRATION=1.
// Needs `npm run db:reset` (seeds) and the local env, see src/routes/auth.integration.test.ts.
// Each call gets its own X-Forwarded-For: the per-IP limiters don't interfere, and audit rows
// written by one call can be found by its IP.
import { describe, it, expect, beforeAll } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, ErrorResponse } from '@ziadkhaled-wb/contracts';
import { createApp } from '../../app';
import { getEnv } from '../../utils/env';
import { registeredCases, type CrossShopHarness } from './harness';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../posDevice';
import { etaHosts } from '../../eta/config';
import { supabaseOfflineStore, verifyRow } from '../../offline/process';
import './cases';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const SEED_PASSWORD = 'LocalDev-Only-2026!';

// 203.0.113.0/24 (TEST-NET-3); auth.integration.test.ts uses 198.51.100.0/24.
// Only 250 addresses, and the local database keeps audit rows between runs, so an address is
// reused: auditRowsFrom counts only rows written since that address's latest call.
let ipCounter = 0;
const nextIp = () => `203.0.113.${(ipCounter++ % 250) + 1}`;
const ipSince = new Map<string, string>();

describe.skipIf(!RUN)('F05 cross-shop suite against local Supabase', () => {
  let h: CrossShopHarness;

  beforeAll(() => {
    const env = getEnv();
    const app = createApp({ env });
    const service: SupabaseClient = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const call: CrossShopHarness['call'] = async (method, path, options = {}) => {
      const ip = nextIp();
      // One second of slack for the database clock.
      ipSince.set(ip, new Date(Date.now() - 1000).toISOString());
      const url = options.query ? `${path}?${options.query}` : path;
      const agent = request(app);
      let r =
        method === 'GET'
          ? agent.get(url)
          : method === 'POST'
            ? agent.post(url)
            : method === 'PUT'
              ? agent.put(url)
              : method === 'PATCH'
                ? agent.patch(url)
                : agent.delete(url);
      r = r.set('X-Forwarded-For', ip);
      if (options.token) r = r.set('Authorization', `Bearer ${options.token}`);
      if (options.orgId) r = r.set('x-org-id', options.orgId);
      if (options.idempotencyKey) r = r.set('Idempotency-Key', options.idempotencyKey);
      if (options.deviceToken) r = r.set(DEVICE_TOKEN_HEADER, options.deviceToken);
      if (options.deviceId) r = r.set('x-device-id', options.deviceId);
      const res = options.body ? await r.send(options.body) : await r;
      return { res, ip };
    };

    h = {
      expect,
      call,
      async login(identifier, tenantSlug) {
        const { res } = await call('POST', '/api/auth/login', {
          body: { identifier, password: SEED_PASSWORD, ...(tenantSlug ? { tenantSlug } : {}) },
        });
        expect(res.status, JSON.stringify(res.body)).toBe(200);
        return AuthLoginResponse.parse(res.body);
      },
      code: (res) => ErrorResponse.parse(res.body).error.code,
      pairDevice: (orgId, branchId, name) => pairTestDevice(service, orgId, branchId, name),
      async auditRowsFrom(orgId, ip) {
        const { count, error } = await service
          .from('audit_log')
          .select('id', { count: 'exact', head: true })
          .eq('organization_id', orgId)
          .eq('ip', ip)
          .gte('created_at', ipSince.get(ip) ?? new Date(0).toISOString());
        if (error) throw new Error(error.message);
        return count ?? 0;
      },
      async processOffline(deviceId) {
        const store = supabaseOfflineStore(service);
        const hosts = etaHosts(env);
        for (const row of await store.loadReceived(deviceId, 50)) {
          const checks = verifyRow(row, hosts);
          await store.process(row.id, checks.signatureOk, checks.uuidOk, checks.qr);
        }
      },
      async accessOf(employeeId) {
        const [o, b, e] = await Promise.all([
          service
            .from('employee_permission_overrides')
            .select('permission_key, granted')
            .eq('employee_id', employeeId),
          service.from('employee_branches').select('branch_id').eq('employee_id', employeeId),
          service.from('employees').select('is_active').eq('id', employeeId).single(),
        ]);
        if (o.error) throw new Error(o.error.message);
        if (b.error) throw new Error(b.error.message);
        if (e.error) throw new Error(e.error.message);
        return {
          overrides: (o.data as { permission_key: string; granted: boolean }[])
            .map((r) => `${r.permission_key}=${String(r.granted)}`)
            .sort(),
          branchIds: (b.data as { branch_id: string }[]).map((r) => r.branch_id).sort(),
          active: e.data.is_active as boolean,
        };
      },
    };
  });

  for (const c of registeredCases()) {
    it(`${c.method} ${c.path}: ${c.name}`, async () => {
      await c.run(h);
    });
  }
});
