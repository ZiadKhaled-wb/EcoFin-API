// The same check as `npm run check:audit`, so `npm test` also fails on an unregistered write route.
import { describe, it, expect } from 'vitest';
import { Router } from 'express';
import { createApp } from '../../app';
import { mountRouter } from '../../routes/registry';
import { checkAuditRegistry, runAuditRegistryCheck } from './check';

const env = { TRUST_PROXY: false as const, CORS_ALLOWED_ORIGINS: [] as string[] };

describe('audit registry (F07 / D19)', () => {
  it('the current app: every write route says which audit action it writes', () => {
    const lines: string[] = [];
    const code = runAuditRegistryCheck(createApp({ env }), (l) => lines.push(l));
    expect(lines.join('\n')).not.toMatch(/MISSING|STALE|INVALID/);
    expect(code).toBe(0);
  });

  it('a new write route without an entry fails (exit 1) and is named', () => {
    const app = createApp({ env });
    const extra = Router();
    extra.post('/', (_req, res) => {
      res.json({});
    });
    mountRouter(app, '/api/not-registered-yet', extra);
    const lines: string[] = [];
    expect(runAuditRegistryCheck(app, (l) => lines.push(l))).toBe(1);
    expect(lines).toContain(
      'MISSING audit entry: POST /api/not-registered-yet (add it to src/test/audit-registry/registry.ts)',
    );
  });

  it('GET routes need no entry', () => {
    const report = checkAuditRegistry([{ method: 'GET', path: '/api/audit' }], {});
    expect(report).toEqual({ missing: [], stale: [], invalid: [] });
  });

  it('stale and invalid entries are reported', () => {
    const report = checkAuditRegistry([{ method: 'POST', path: '/api/a' }], {
      'POST /api/a': { none: 'x' },
      'POST /api/gone': { action: 'thing.done' },
      'PUT /api/b': { action: 'NotAnAction' },
    });
    expect(report.missing).toEqual([]);
    expect(report.stale).toEqual(['POST /api/gone', 'PUT /api/b']);
    expect(report.invalid).toEqual(['POST /api/a', 'PUT /api/b']);
  });
});
