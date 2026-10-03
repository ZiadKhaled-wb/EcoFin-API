// Safe, fake values so `npm test` works on a fresh clone without a .env file.
// Real values already present in the environment (e.g. CI) win over these.
// `dotenv/config` (imported by src/utils/env.ts) never overrides existing variables,
// so a developer's .env cannot break the tests either.
process.env['NODE_ENV'] = 'test';
process.env['SUPABASE_URL'] ??= 'https://ci-test.supabase.co';
process.env['SUPABASE_ANON_KEY'] ??= 'ci-test-anon-key';
process.env['SUPABASE_SERVICE_ROLE_KEY'] ??= 'ci-test-service-role-key';
process.env['FRONTEND_URL'] ??= 'https://ci-test.example.com';
