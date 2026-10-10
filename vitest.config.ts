// vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    setupFiles: ['src/test/setup-env.ts'],
    include: ['src/**/*.test.ts'],
    // Integration files share one seeded database; provisioning races global job assertions.
    // Keep unit files parallel and retain the concurrency exercised inside integration tests.
    fileParallelism: process.env['RUN_INTEGRATION'] !== '1',
    // An integration test is a whole story through the API (a shop, a shift, several documents);
    // on a busy machine the 5 s default cuts the long ones short. Unit tests keep the default.
    testTimeout: process.env['RUN_INTEGRATION'] === '1' ? 30_000 : 5_000,
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: ['src/**/*.ts'],
      exclude: [
        'src/**/*.test.ts',
        'src/**/*.d.ts',
        'src/docs/**',
        'src/server.ts',
        'src/app.ts',
        'src/types/**',
      ],
    },
    // Tests must not leak state between files. Each file gets a fresh
    // module registry so vi.mock() factories re-run.
    isolate: true,
  },
});
