// scripts/check-permissions.ts  (npm run check:permissions)
//
// F06 / D19: builds the app with createApp(), lists every route it serves and exits 1, naming
// the route, when one has no access marker (requirePermission(key), authenticatedOnly() or
// publicRoute()) or more than one. src/test/route-access/check.test.ts runs the same check inside
// `npm test`. No database or network: the app is only built, never started.

process.env['NODE_ENV'] ??= 'test';
process.env['SUPABASE_URL'] ??= 'https://ci-test.supabase.co';
process.env['SUPABASE_ANON_KEY'] ??= 'ci-test-anon-key';
process.env['SUPABASE_SERVICE_ROLE_KEY'] ??= 'ci-test-service-role-key';
process.env['FRONTEND_URL'] ??= 'https://ci-test.example.com';

const { createApp } = await import('../src/app');
const { runRouteAccessCheck } = await import('../src/test/route-access/check');

const app = createApp({ env: { TRUST_PROXY: false, CORS_ALLOWED_ORIGINS: [] } });
process.exitCode = runRouteAccessCheck(app, (line) => console.log(line));
