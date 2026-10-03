# Contributing (server)

## Setup
1. Node 24 (see `.nvmrc`; `nvm use`).
2. `npm ci`
3. `cp .env.example .env` and fill in the Supabase values (needed only to run the server, not the tests).

## Scripts
| Command | What it does |
|---|---|
| `npm run dev` | Start the server with reload |
| `npm run build` | Compile to `dist/` (`tsconfig.build.json`) |
| `npm run typecheck` | `tsc --noEmit`, strict mode |
| `npm run lint` | ESLint (type-aware, `no-explicit-any` is an error) |
| `npm run format` / `npm run format:check` | Prettier write / check |
| `npm test` | Vitest. Works without a `.env`: `src/test/setup-env.ts` sets safe test values |

## Rules
- CI runs on every pull request: typecheck, lint, format:check, test, build. A failure blocks the merge.
- Run all of them before you push. No `any`, no `@ts-ignore`, no skipped tests, no disabled lint rules.
- Formatting: Prettier (`.prettierrc.json`), LF line endings (`.gitattributes`).
- Branches: `feat/<slice-id>-<name>` or `fix/<name>`, opened as a pull request. Never commit to `main`.
- Commits: small, imperative, one concern each.
- Schema changes only through a new file in `supabase/migrations/`; never edit an existing one.
- Project rules and the build workflow: [`AGENTS.md`](AGENTS.md) and `.claude/skills/ecotech-build/SKILL.md`.
