// scripts/check-cross-shop.ts  (npm run check:cross-shop)
//
// F05 / D19: builds the app with createApp(), lists every route it serves and exits 1, naming
// the route, when one has no cross-shop case (src/test/cross-shop/cases.ts) and isn't in
// PUBLIC_ROUTES. check.test.ts runs the same check inside `npm test`.
//
// No database or network: the app is only built, never started. The env values below are
// placeholders for the import-time env check; real ones win when present.

process.env['NODE_ENV'] ??= 'test';
process.env['SUPABASE_URL'] ??= 'https://ci-test.supabase.co';
process.env['SUPABASE_ANON_KEY'] ??= 'ci-test-anon-key';
process.env['SUPABASE_SERVICE_ROLE_KEY'] ??= 'ci-test-service-role-key';
process.env['FRONTEND_URL'] ??= 'https://ci-test.example.com';

const { createApp } = await import('../src/app');
const { registeredCases, runCrossShopCheck } = await import('../src/test/cross-shop/harness');
await import('../src/test/cross-shop/cases');

const app = createApp({ env: { TRUST_PROXY: false, CORS_ALLOWED_ORIGINS: [] } });
process.exitCode = runCrossShopCheck(app, registeredCases(), (line) => console.log(line));
