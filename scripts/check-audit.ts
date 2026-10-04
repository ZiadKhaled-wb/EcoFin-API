// scripts/check-audit.ts  (npm run check:audit)
//
// F07 / D19: builds the app with createApp(), lists every write route (method other than GET) and
// exits 1, naming the route, when it isn't in src/test/audit-registry/registry.ts (an audit action
// or an explicit `none` with a reason). check.test.ts runs the same check inside `npm test`.
// No database or network: the app is only built, never started.

process.env['NODE_ENV'] ??= 'test';
process.env['SUPABASE_URL'] ??= 'https://ci-test.supabase.co';
process.env['SUPABASE_ANON_KEY'] ??= 'ci-test-anon-key';
process.env['SUPABASE_SERVICE_ROLE_KEY'] ??= 'ci-test-service-role-key';
process.env['FRONTEND_URL'] ??= 'https://ci-test.example.com';

const { createApp } = await import('../src/app');
const { runAuditRegistryCheck } = await import('../src/test/audit-registry/check');

const app = createApp({ env: { TRUST_PROXY: false, CORS_ALLOWED_ORIGINS: [] } });
process.exitCode = runAuditRegistryCheck(app, (line) => console.log(line));
