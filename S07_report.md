# S07: sales history and void

## Result

Implemented branch-scoped sales search, additive sale details and atomic same-day voids. GET /api/sales/:id already existed; its response now uses a separate mapper retaining every S01/S02/S03 field. Sale-create functions and routes were not changed.

## Changed files

- Contracts: salesHistory schemas/tests, errors, index, version and changelog; API dependency and lockfile.
- API: salesHistory service/tests/controller/routes/integration tests; app mount and existing detail controller; generated database types.
- SQL: new 20261012194500_s07_sales_history.sql; S07 tests and additive tenant/permission and ledger replay guards.
- Registries: void audit driver/registry and F05 history/void cases with route-count update.
- Documentation: DECISIONS.md, TEST_PLAN.md, plans/S07.md and this report.

## Verification

- Typecheck, lint and format: passed.
- API unit: 684 passed; contracts: 290 passed.
- API full run with RUN_INTEGRATION=1: 1,063 passed, including 379 integration tests.
- Clean local database reset and every SQL test file: 2,615 passed, zero failures; S07: 44.
- Web: 551 passed; final sales history/detail regression check: 24 passed.
- Real Chrome: EN/LTR and AR/RTL lookup by serialized sale, detail, reason dialog, successful void and refreshed list; Arabic mobile width also checked. Screenshots are ignored local test artifacts in Web/test-results/s07.

## Compatibility and local setup

Authorized expired subscriptions keep read-only history/detail access while void remains blocked. Permission tests cover callers without reader keys. Pending fiscal submissions cancel; issued submissions block void. Concurrent void requests produced exactly one reversal.

Used an isolated local Supabase stack named ecofin-api-s07-s12 (ports 554xx), leaving the other running development stack untouched. Windows exFAT cannot create npm workspace links, so installed dependencies were copied locally without changing tracked dependency versions beyond contracts 0.35.0. The Web consumes the same locally packed contracts artifact.

No S07 work remains. Reprint and start-return actions are named empty slots as instructed. Supabase remains running for S12. Nothing was pushed. The existing local CLAUDE.md edit was preserved and excluded from the commit.
