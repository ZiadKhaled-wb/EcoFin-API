// ESLint 10 flat config: typescript-eslint with type-aware rules, Prettier-compatible.
import tsPlugin from '@typescript-eslint/eslint-plugin';
import tsParser from '@typescript-eslint/parser';
import prettier from 'eslint-config-prettier';

export default [
  {
    ignores: ['dist/**', 'node_modules/**', 'coverage/**', 'graphify-out/**'],
  },
  {
    files: ['src/**/*.ts'],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        project: './tsconfig.json',
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: {
      '@typescript-eslint': tsPlugin,
    },
    rules: {
      ...tsPlugin.configs['eslint-recommended'].overrides[0].rules,
      ...tsPlugin.configs.recommended.rules,

      // Type-aware rules that catch real bugs. The rest of `recommended-type-checked`
      // (no-unsafe-*, require-await, restrict-template-expressions) is deferred: it needs
      // typed Supabase/contract types (F02/F03) and would force behaviour-adjacent rewrites.
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-misused-promises': 'error',
      '@typescript-eslint/await-thenable': 'error',
      '@typescript-eslint/no-unnecessary-type-assertion': 'error',
      '@typescript-eslint/only-throw-error': 'error',
      '@typescript-eslint/no-for-in-array': 'error',

      '@typescript-eslint/no-explicit-any': 'error',
      'no-console': 'error',

      // Allow leading-underscore names for deliberately-unused params.
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
    },
  },
  {
    // Config files are not part of tsconfig.json, so no type information here.
    files: ['eslint.config.js', 'vitest.config.ts'],
    languageOptions: { parser: tsParser },
    plugins: { '@typescript-eslint': tsPlugin },
    rules: {
      ...tsPlugin.configs.recommended.rules,
      '@typescript-eslint/no-explicit-any': 'error',
    },
  },
  prettier,
];
