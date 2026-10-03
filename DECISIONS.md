# Decisions (server repo)

Decisions taken during Sprint 1 that the docs don't already settle. Newest last. Each one is the simplest option that follows the docs.

## Sprint 1 (3 Oct 2026)

### D1. Contracts package lives in a third repo `EcoFin-Contracts/` (decided by the team)
- Package `@ecotech/contracts`, built with `tsc`, version `0.1.0`.
- Both repos depend on it with `"@ecotech/contracts": "file:../EcoFin-Contracts"` **for now**.
- **Before merging Sprint 1 to `main`:** create the GitHub repo `EcoFin-Contracts`, push it, tag `v0.1.0`, and switch both repos to `"github:<owner>/EcoFin-Contracts#v0.1.0"`. Until then **GitHub CI can't install this repo**, because `../EcoFin-Contracts` doesn't exist on the runner.
- The new repo has no `main` yet. Its first commit is on `integration/sprint-1`; `main` is created when you publish it.

### D2. Writes go through SECURITY DEFINER functions (decided by the team)
`ecotech-build` rule 11. The API never writes tables directly.

### D3. The partner's existing auth code is reviewed and reused where it passes the rules (decided by the team)

### D4. Worktrees are created by the master with `git worktree add`, as siblings of the repos
The Agent tool's built-in worktree isolation would branch the wrong repository (the workspace folder sits inside a home-directory git repo). So the master creates `EcoFine/wt-<agent>` with `git worktree add -b feat/<id>-<slug> ... integration/sprint-1` and hands each builder its path. The worktrees sit next to the repos so `file:../EcoFin-Contracts` resolves the same way in a worktree as in the repo. Worktrees are removed after merge.

### D5. Sprint 1 contracts cover every Sprint 1 endpoint up front
F03 (contracts 0.1.0) defines the schemas for F04 auth, F06 my-permissions / permission override / branch assignment, F07 audit search and F08 health. Later Sprint 1 builders don't change the contracts package. If one finds a schema missing, it stops and reports, and the master adds the schema. This keeps one version, `0.1.0`, for the tag in D1.

### D6. F08 starts after F03 is merged (still inside wave 1)
F08's error handler must return the F03 error shape. Building it in parallel would need a stand-in, which the rules forbid. F02 and F03 run in parallel. F08 is cut from `integration/sprint-1` once F03 is merged. Wave 2 still waits for all three.

### D7. Shared-file ownership per wave (API repo)
| Wave | `package.json` + lockfile | `.github/workflows/*` | `src/app.ts` / route wiring | `.env.example` |
|---|---|---|---|---|
| 0 | B1 | B1 | B1 | B1 |
| 1 | B3 | B3 | B5 | B5 |
| 2 | B6 | B6 | B6 | B6 |
| 3 | B8 | B8 | B8 | B8 |
| 4 | B10 | B10 | B10 | B10 |
The master adds the contracts dependency at F03 merge. Non-owners install with `--no-save` and list what they need.

### D8. Reserved migration timestamps (new migrations only, baseline never edited)
`20261003060000` F04 · `20261003080000` F05 · `20261003100000` F06 · `20261003110000` F07. A task that doesn't need its slot leaves it unused.

### D9. Local Supabase CLI runs through `npx supabase@2.119.0`
It isn't installed globally. Scripts use `npx supabase ...` (or a pinned `supabase` devDependency if F02 chooses one).

### D10. Node network workaround on the dev machine
`NODE_OPTIONS=--no-network-family-autoselection` is needed for npm and Node network calls on this machine. It's machine-specific, so it goes in `docs/testing/ENVIRONMENT.md` and not in the scripts.
