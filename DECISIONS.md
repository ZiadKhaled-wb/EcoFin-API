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

### D12. One-time Prettier reformat when F01 lands (both repos)
Prettier settings are the same in both repos: `{ singleQuote, semi, trailingComma: "all", printWidth: 100, endOfLine: "lf" }` with the default 2-space indent. The server code was 4-space, so F01 reformats every server source file once, with no logic change. `.gitattributes` (`* text=auto eol=lf`) stops Windows `core.autocrlf` from breaking `format:check`. Branches cut before F01 must rebase and run `npm run format`.

### D13. typescript-eslint `no-unsafe-*` rules stay off for now
They give about 55 errors that come from the untyped Supabase client in the old auth code. F01 turns on the safe type-aware rules (no-floating-promises, no-misused-promises, await-thenable, only-throw-error, …). **Follow-up:** turn on `recommended-type-checked` once the typed DB client (`src/types/database.types.ts`, F02) and the contracts (F03) are in use.

### D14. The service-role client is used only for pre-session auth steps
Before a user has a session, the API can't use their JWT. The service-role client is allowed **only** in one module (`src/services/auth.admin.ts` or equivalent) for: resolving `tenantSlug + username` to the login email, checking whether the employee, shop and subscription are active before issuing tokens, and inserting `login_attempts` (the baseline grants that table to the service role only). Everything after login uses a per-request client built from the user's JWT (plus `x-org-id`). Reads a logged-in user needs across shops (their list of shops) go through a `SECURITY DEFINER` function in a new migration, not the service role.

### D15. License and activate-workspace endpoints are removed from Sprint 1
The old `check-license` / `activate-workspace` code targets tables that aren't in the V1 baseline (`saaslicenses`). The data model says owners join through an emailed invite (P01/P02). **Updated by the user's decision (3 Oct):** the server routes, services, limiter and tests are removed in F08 (B5), because the contracts dropped the `LICENSE_*` codes. The client pages are removed in F04 (B7). Git history keeps the old code for P01/P02 to port.

### D16. Token transport and storage
The API returns the access and refresh tokens in the JSON body (contracts `auth`). The client keeps the partner's approach: tokens persisted in `localStorage` through the zustand store, with the trade-off documented in `authStore.ts`. Silent refresh happens before expiry, and logout revokes the session on the server. **Follow-up (hardening):** move the refresh token to an httpOnly cookie and add a strict CSP.

### D17. Failed-login limits
Lockout after **5 failed attempts per identifier (per shop) in 15 minutes**, counted from `login_attempts`, which returns `TOO_MANY_LOGIN_ATTEMPTS` (429). Both numbers are env-configurable (`LOGIN_MAX_FAILURES`, `LOGIN_WINDOW_MINUTES`). This sits on top of the per-IP `loginLimiter`. It's a technical default, not a business rule; change it if the business sets one.

### D18. Client permission code is split between F09 and F06
F09 (wave 3) builds `usePermissions()` (reads `GET /api/me/permissions` through the contract) and the `<RequirePermission>` route guard. F06 (wave 4) adds `useCan`, `<Can>` and `useBranchAccess` on top of it, plus the server half. Both are coded against the same contract, so neither needs a stand-in.

### D19. Route markers make a forgotten check fail CI
Every API route carries a permission marker (`requirePermission(key)`, `authenticatedOnly()` or `publicRoute()`), a cross-shop case (F05) and an audit-registry entry for writes (F07). Scripts and unit tests fail when a route is missing any of them.

### D20. `/health` may use the server (service-role) client for one read-only query
`anon` has no grants, so a public health check can't touch the DB any other way. Allowed: one cheap read-only query with a short timeout, returning only the contract fields. That's the only service-role use outside D14's auth module.

### D21. Incident: `EcoFin-Contracts` wiped by a worktree removal, rebuilt and verified (3 Oct, 12:06)
**What happened:** the master ran `git worktree remove --force` on an API worktree. On Windows, git followed the npm `file:` link `node_modules/@ecotech/contracts` (a junction) and deleted its **target**: the whole `EcoFin-Contracts` folder, `.git` included. The repo had never been pushed.
**Recovery:** the repo was re-initialised, and the F03 builder's recorded steps were replayed in order (its writes and commands, including its own commits). The rebuilt package passes all 27 tests, and its built `dist/`, `package.json`, README and CHANGELOG are **byte-identical** to the reviewer's `npm pack` of the approved version. Commit hashes in `EcoFin-Contracts` differ from the original; content doesn't.
**Rule from now on (anyone, not just agents):** before deleting a worktree or clone that has run `npm ci`/`npm install`, unlink every link inside it first, then remove it. A junction is removed safely with `cmd /c rmdir <link>` (it never touches the target). In Git Bash:
```bash
find <worktree> -path '<worktree>/.git' -prune -o -type l -print | while read -r l; do cmd //c rmdir "$(cygpath -w "$l")"; done
git worktree remove --force <worktree>
```
Publishing `EcoFin-Contracts` to GitHub (D1) removes the single point of failure.

### D22. A story starts once its real dependencies are merged, not the whole previous wave (user OK, 3 Oct)
To finish sooner, F09 (B9, client only) starts as soon as F03 and the F04 client half (B7) are merged, without waiting for the F04 server half (B6). F05 still waits for B6, and wave 4 still waits for F05 and F09.

### D23. `select-shop` returns `{ user, shop }`, not new tokens (contract fix in 0.1.0)
Supabase tokens carry no shop. The active shop is chosen per request by the `x-org-id` header, which the DB checks against the caller's memberships. So `POST /api/auth/select-shop` checks that the shop is one of the caller's (`my_shops()`), writes `auth.login` in that shop, and returns `{ user, shop }`. The client keeps its tokens and sends `x-org-id`. The contract stays at `0.1.0` because it hasn't been published yet.

### D24. Auth hardening found while building F04
- `must_change_password` is cleared only by the API, through the service-role client in `auth.admin.ts` (an extension of D14), **after** Supabase confirms the password change. The DB function isn't executable by `authenticated`, so a user can't clear the flag directly through PostgREST.
- Local `jwt_expiry` is 900 s (15 min). A logged-out access token is refused by the API at once, but PostgREST accepts it until it expires, so a short expiry narrows that window. **Production:** set the same JWT expiry in the Supabase project settings.
- `/refresh` has its own generous per-IP limiter (not the login limiter), so silent refreshes from one shop IP can't block logins.
- The error handler recognises zod errors by name, as well as with `instanceof`, because the contracts package carries its own zod copy.
