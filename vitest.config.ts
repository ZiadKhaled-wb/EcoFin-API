// vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
    test: {
        globals: true,
        environment: 'node',
        include: ['src/**/*.test.ts'],
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