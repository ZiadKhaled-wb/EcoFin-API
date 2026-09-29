// eslint.config.js
// ESLint 9 flat config. Uses the two packages installed via npm:
//   @typescript-eslint/eslint-plugin
//   @typescript-eslint/parser
//
// Rules are chosen to enforce the auth refactor's acceptance criteria:
//   no-explicit-any   -> criterion 8
//   no-console        -> criterion 9
//   no-unused-vars    -> keeps the refactor tidy; allows `_req`, `_next`, etc.

import tsPlugin from '@typescript-eslint/eslint-plugin';
import tsParser from '@typescript-eslint/parser';

export default [
    {
        ignores: ['dist/**', 'node_modules/**', 'coverage/**'],
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
            ...tsPlugin.configs.recommended.rules,

            // Criterion 8: no `any`.
            '@typescript-eslint/no-explicit-any': 'error',

            // Criterion 9: no console.
            'no-console': 'error',

            // Allow leading-underscore names for deliberately-unused params.
            '@typescript-eslint/no-unused-vars': [
                'error',
                { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
            ],
        },
    },
];