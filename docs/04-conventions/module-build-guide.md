> ⚠️ **Outdated: don't copy these templates.** Follow the `ecotech-build` skill and `docs/EcoTech_Pro_Data_Model.md`.

# Module build guide

**Audience:** AI agents and human developers building the next module
(employees, POS, customers, collections, etc.).
**Prerequisite reading:** `docs/02-architecture/adr/0004-auth-and-tenancy.md`.

This document tells you the patterns every module follows. Deviating from
them silently is a bug. Deviating from them deliberately is fine — but you
must say why in a comment and, if the deviation is architectural, write a
new ADR.

---

## The ten invariants

These hold in every module. Do not violate them.

### I1. Tenant context comes from the JWT, not from the request

Every request carries a JWT. The JWT's `sub` claim resolves to an `employees`
row, which carries `organization_id`. That is the tenant context — nothing
else is.

Never read `organization_id` from `req.body`, `req.query`, or `req.params`.
If a controller needs it, it reads `req.employee.organization_id`.

### I2. Post-auth reads go through `supabaseUser(req.authToken)`

Never `supabaseAdmin`. RLS is the enforcement mechanism. A query that reads
through `supabaseAdmin` in a tenant handler is a bug, even if it happens to
return the right rows.

The only exceptions:
- Pre-auth flows (login, activation, check-license, forgot-password)
- Platform super-admin operations
- `auth.admin.*` calls
- Reads that must observe a state RLS is deliberately hiding (rare —
  see ADR-0004 §D5 for the one such case)

### I3. Every error has a `code`

`AppError(message, code, statusCode, details)`. If you're throwing a plain
`Error`, you're doing it wrong. Add a code to `ErrorCode` in
`src/utils/errors.ts` if a new one is needed.

### I4. Multi-step writes go through Postgres RPCs

If a flow touches two tables, it's a single RPC. Not two `.from().update()`
calls with a manual rollback. Not a `TransactionTracker`. One RPC, one
transaction, one failure mode.

The exception: when one step is a Supabase Auth call (outside Postgres's
transaction), order the steps so failure is recoverable, and log loudly if
the second step fails. See ADR-0004 §D3.

### I5. Never use `(req as any)`

Extend `Express.Request` via `src/types/express.d.ts`. If you need a new
field on `req`, add it there.

### I6. Never use `console.log`

`logger.info`, `logger.warn`, `logger.error`. The logger redacts credential
fields automatically; `console` does not.

### I7. Validate inputs at the service boundary

Controllers do not validate. They call services. Services validate with the
functions in `src/utils/validation.ts`. Add a new validator when the shape
isn't covered. Do not add inline regexes to services.

### I8. Never leak the raw Supabase error

`errorHandler` sanitizes. Services wrap Supabase errors in `AppError` with
a code. The client never sees the raw error object.

### I9. Idempotency keys are client-generated, DB-enforced

Any endpoint that creates a payment, order, or other financial event
requires an `idempotency_key` from the client. The DB has a
`UNIQUE (organization_id, idempotency_key)` constraint. The service
upserts.

### I10. Nothing after authentication uses `supabaseAdmin`

Grep your own output before you commit:

```bash
grep -rn 'supabaseAdmin' src/ --include='*.ts'
```

Every hit must be in an allowed context (see I2).

---

## The file structure

Every module has the same five files. Copy this structure.

```
src/
├── services/
│   └── <module>.service.ts      ← business logic, DB access, RPC calls
├── controllers/
│   └── <module>.controller.ts   ← HTTP plumbing only; no logic
├── routes/
│   └── <module>.ts              ← middleware chain + route table
├── types/
│   └── <module>.types.ts        ← DTOs, request/response shapes (optional)
└── docs/openapi.ts              ← append a new tag + path block
```

Plus, when the module has its own middleware (rare):
```
src/middleware/<module>.ts
```

Plus, when the module needs atomic multi-step writes:
```
migrations/000N_<module>_rpcs.sql
```

---

## The route template

Every route file looks like this. Fill in the blanks.

```ts
// server/src/routes/<module>.ts

import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import {
    authenticate,
    attachEmployee,
    requireTenant,
    requirePasswordChanged,
    authorizeModule,
    authorizeRole,
    isOwner,
} from '../middleware/auth';
import * as controller from '../controllers/<module>.controller';

const router = Router();

// Every route carries this chain, in this order, unless it is a
// deliberate exception (documented at the route).
const baseChain = [
    authenticate,
    attachEmployee,
    requireTenant,
    requirePasswordChanged,
];

// ---- READ endpoints -------------------------------------------------------
router.get(
    '/',
    ...baseChain,
    authorizeModule('<module>.view'),   // or 'pos', or 'sales.create'
    asyncHandler(controller.list),
);

router.get(
    '/:id',
    ...baseChain,
    authorizeModule('<module>.view'),
    asyncHandler(controller.getOne),
);

// ---- WRITE endpoints ------------------------------------------------------

router.post(
    '/',
    ...baseChain,
    authorizeModule('<module>.create'),
    asyncHandler(controller.create),
);

router.patch(
    '/:id',
    ...baseChain,
    authorizeModule('<module>.update'),
    asyncHandler(controller.update),
);

// Owner-only actions:
router.delete(
    '/:id',
    ...baseChain,
    isOwner,
    asyncHandler(controller.deactivate),
);

export default router;
```

The middleware chain order is load-bearing:

1. `authenticate` — verifies the JWT, sets `req.user` + `req.authToken`
2. `attachEmployee` — loads the employee row through RLS, sets `req.employee`
3. `requireTenant` — rejects if `req.employee` is missing (i.e. super admin)
4. `requirePasswordChanged` — rejects if the temp-password flag is still set
5. `authorizeModule` / `authorizeRole` / `isOwner` — role/permission gate

**Do not reorder.** If a route doesn't need `requireTenant` (e.g. a
platform-wide endpoint), that's a deliberate exception — comment it.

---

## The controller template

Controllers are thin. They extract from the request, call the service,
and return.

```ts
// server/src/controllers/<module>.controller.ts

import type { Request, Response } from 'express';
import * as service from '../services/<module>.service';
import { Unauthorized } from '../utils/errors';

export async function list(req: Request, res: Response) {
    const employee = req.employee;
    if (!employee) throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');

    const result = await service.list(employee.organization_id, req.query);
    return res.json(result);
}

export async function create(req: Request, res: Response) {
    const employee = req.employee;
    if (!employee) throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');

    const body = (req.body ?? {}) as Record<string, unknown>;
    const result = await service.create(employee.organization_id, employee.id, body);
    return res.status(201).json(result);
}
```

What a controller **must not** do:
- Query the database
- Validate inputs beyond presence
- Format error messages
- Call `supabaseAdmin` or `supabaseUser` (both are service concerns)

---

## The service template

Services carry the logic and the DB access.

```ts
// server/src/services/<module>.service.ts

import { supabaseAdmin, supabaseUser } from '../utils/supabase';
import { AppError, BadRequest, Forbidden, NotFound } from '../utils/errors';
import {
    isNonEmptyString,
    isValidRole,
    // ... etc
} from '../utils/validation';
import { logger } from '../utils/logger';

// ---------------------------------------------------------------------------
// READ — uses the user-scoped client so RLS applies.
// ---------------------------------------------------------------------------
export async function list(orgId: string, query: Record<string, unknown>) {
    // Note: orgId is passed for logging/context, but the actual filter is
    // RLS. Do NOT add `.eq('organization_id', orgId)` — that would be a
    // second, redundant layer that hides a broken policy.
    const { data, error } = await supabaseUser(/* token from req */)
        .from('<table>')
        .select('*');

    if (error) {
        logger.error({ err: error, orgId }, '<module>.list: query failed');
        throw new AppError('فشل تحميل البيانات.', 'INTERNAL', 500);
    }

    return data ?? [];
}
```

Wait — the service doesn't have the JWT. See the "Passing the JWT" section
below. For now, the pattern is: **controllers pass `req.authToken` to the
service**, or the service accepts a `SupabaseClient` parameter.

Correct pattern:

```ts
export async function list(
    client: SupabaseClient,
    orgId: string,
    query: Record<string, unknown>,
) {
    const { data, error } = await client
        .from('<table>')
        .select('*');
    // ...
}
```

And the controller:

```ts
import { supabaseUser } from '../utils/supabase';

export async function list(req: Request, res: Response) {
    const employee = req.employee;
    const token = req.authToken;
    if (!employee || !token) throw Unauthorized('...', 'UNAUTHORIZED');

    const client = supabaseUser(token);
    const result = await service.list(client, employee.organization_id, req.query);
    return res.json(result);
}
```

Why pass the client rather than rebuild it in the service:
- Explicit dependency. The service cannot accidentally use `supabaseAdmin`.
- Testable. Unit tests pass a mock client.
- Clear. `service.list(client, ...)` reads as "list rows through this client."

**Note:** The current auth module doesn't use this pattern because its
service is pre-auth. Future modules will. Adopt this pattern from module two.

---

## The validation template

Add validators to `src/utils/validation.ts` as needed. Follow this shape:

```ts
export const isValid<Thing> = (value: unknown): value is <Thing> => {
    if (typeof value !== 'string') return false;
    if (value.length < MIN || value.length > MAX) return false;
    return /^pattern$/.test(value);
};
```

Rules:
- Always accept `unknown`, always return a type predicate (`value is T`).
- Never throw. Return `false`.
- Never `trim()` unless the caller expects trimming.
- Add the validator to `validation.test.ts` in the same commit.

---

## The RPC template

When a write touches more than one table, write an RPC.

```sql
-- migrations/000N_<module>_rpcs.sql

CREATE OR REPLACE FUNCTION public.<action>(
    p_<arg1> <type1>,
    p_<arg2> <type2>
)
RETURNS TABLE (result_field_1 <type>, result_field_2 <type>)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_<local> <type>;
BEGIN
    -- Lock first. Always SELECT ... FOR UPDATE before re-validating.
    SELECT ... INTO v_<local> FROM ... FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOMAIN_ERROR_CODE' USING ERRCODE = 'P0001';
    END IF;

    -- Do the work.
    UPDATE ...;
    INSERT ...;

    RETURN QUERY SELECT ...;
END;
$$;

REVOKE ALL ON FUNCTION public.<action>(<types>) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.<action>(<types>) TO service_role;
```

Conventions:
- Parameter names prefixed `p_`.
- Local variables prefixed `v_`.
- Errors raised as `P0001` with a machine-readable code.
- The service layer maps the code to an `ErrorCode`.
- Always `REVOKE ... FROM PUBLIC` then `GRANT ... TO service_role`.

Service-side call:

```ts
const { data, error } = await supabaseAdmin.rpc('<action>', {
    p_arg1: value1,
    p_arg2: value2,
});

if (error) {
    const msg = error.message ?? '';
    if (msg.includes('DOMAIN_ERROR_CODE')) {
        throw BadRequest('...', 'SOME_CODE');
    }
    logger.error({ err: error, ... }, 'P1: <action> RPC failed');
    throw new AppError('فشل تنفيذ العملية.', 'INTERNAL', 500);
}
```

---

## The OpenAPI pattern

After building the routes, add them to `src/docs/openapi.ts`.

1. Add a tag:

```ts
{ name: 'Employees', description: 'Tenant employee management' },
```

2. Add schemas to `components.schemas` for the request/response shapes.

3. Add paths:

```ts
'/api/employees': {
    get: {
        tags: ['Employees'],
        summary: 'List employees in the caller org',
        security: [{ bearerAuth: [] }],
        responses: {
            200: {
                description: 'List',
                content: {
                    'application/json': {
                        schema: { type: 'array', items: { $ref: '#/components/schemas/Employee' } },
                    },
                },
            },
            401: { $ref: '#/components/responses/Unauthorized' },
            403: { $ref: '#/components/responses/Forbidden' },
        },
    },
    post: { /* ... */ },
},
```

Reuse `#/components/responses/Unauthorized`, `Forbidden`, `BadRequest`,
`TooManyRequests`. Reuse `#/components/schemas/Error`.

Load `http://localhost:3001/docs` and verify your endpoints render with
the correct request body shape.

---

## The test pattern

Every service function needs at least four tests:

1. **Happy path** — valid input → expected output
2. **Tenant isolation** — a caller in org A cannot touch org B's row
3. **Validation failure** — malformed input → correct error code
4. **Not-found** — the resource doesn't exist → `NOT_FOUND`

Every middleware needs:
1. **Pass** — valid context → `next()` called
2. **Reject** — missing/wrong context → error thrown with correct code

Every validator needs:
1. **Accepts** at the boundary conditions
2. **Rejects** just outside

Use the `createSupabaseMock()` helper. Do not use real Supabase in unit
tests. Integration tests (real DB) come later — see "Testing tiers" below.

---

## Testing tiers

Three tiers. Aim for the first two before shipping a module.

**Tier 1 — Unit (Vitest, mocked Supabase):**
- Pure functions, service logic, middleware gates.
- Runs on `npm test`. Sub-second. Run on every commit.

**Tier 2 — HTTP (Supertest, in-process Express, mocked Supabase):**
- Route wiring, middleware chain order, error handler behavior.
- Runs on `npm run test:integration`. A few seconds.

**Tier 3 — End-to-end (live Supabase, real HTTP):**
- RLS enforcement, RPC atomicity, concurrency.
- Runs on `npm run test:e2e`. Opt-in. Requires a live project.
- Written as `.e2e.ts` files, excluded from default test runs.

For each new module, write Tier 1 and Tier 2. Add Tier 3 for anything that
touches RLS or an RPC.

---

## Anti-patterns to avoid

Every one of these has been a real bug in this codebase's history. Do not
reintroduce them.

| Anti-pattern | Why it's wrong | Correct pattern |
|---|---|---|
| `supabaseAdmin.from('contracts')` in a controller | Bypasses RLS | `supabaseUser(req.authToken).from('contracts')` |
| `(req as any).employee` | Defeats type safety | Extend `Express.Request` in `types/express.d.ts` |
| `.eq('organization_id', orgId)` on every query | Redundant with RLS — hides a broken policy | Trust RLS; log `orgId` for context only |
| Try/catch that swallows and returns null | Loses the error | Log with context and rethrow |
| Double-checking the same condition in middleware and service | Unclear ownership | Pick one layer. Middleware gates on the request; service gates on the data. |
| Manual rollback via a tracker | Fragile, untested | Postgres RPC |
| `console.log` anywhere | No redaction, no structured output | `logger` |
| Raw Supabase error in a response | Leaks internal structure | Wrap in `AppError` with a code |
| `catch (e) { throw new Error(e.message) }` | Loses the type/code | `if (e instanceof AppError) throw e; throw new AppError(...)` |
| `.single()` on a row that might not exist | Throws on zero rows | `.maybeSingle()` and handle null |
| `parseInt(req.params.id)` without checking | `NaN` silently propagates | Validate UUID format first |
| Reusing `req.employee` for a super admin's context | They're different principals | `req.superAdmin` is separate |
| Adding `SUPER_ADMIN` to `VALID_ROLES` | Not a tenant role | Super admins live in `super_admins` |
| Trimming passwords | Rejects legitimate passwords | Compare as-is |
| Validating the same field in controller and service | Duplicated logic drifts | Validate in the service; controller just calls |

---

## The build checklist

Before opening a PR for a new module:

- [ ] All routes go through the standard middleware chain
- [ ] Every service read uses `supabaseUser`, not `supabaseAdmin`
- [ ] Every write that touches >1 table goes through an RPC
- [ ] Every error has a `code` from `ErrorCode`
- [ ] No `(req as any)`, no `console.log`, no raw `any`
- [ ] Inputs validated in the service, not the controller
- [ ] OpenAPI spec updated and rendering at `/docs`
- [ ] Tier 1 tests written for every exported function
- [ ] Tier 2 tests written for every route
- [ ] Tier 3 tests written if the module touches RLS or an RPC
- [ ] `npm run typecheck` → zero errors
- [ ] `npm run lint` → zero errors
- [ ] `npm test` → all passing
- [ ] Three greps return clean:
    - `grep -rn 'supabaseAdmin' src/ --include='*.ts'` — only allowed contexts
    - `grep -rn 'as any\|: any\|<any>' src/ --include='*.ts'` — zero
    - `grep -rn 'console\.' src/ --include='*.ts'` — zero
- [ ] If any architectural choice wasn't obvious, write a new ADR

---

## Reference implementations

When in doubt, read these files:

| Pattern | Reference |
|---|---|
| Middleware chain | `src/middleware/auth.ts` |
| Error handler with redaction | `src/middleware/errorHandler.ts` |
| Rate limiter | `src/middleware/rateLimit.ts` |
| Service with pre-auth flow | `src/services/auth.service.ts` |
| Service with RPC call | `activateWorkspace` in `src/services/auth.service.ts` |
| Controller shape | `src/controllers/auth.controller.ts` |
| Route chain | `src/routes/auth.ts` |
| OpenAPI block | `src/docs/openapi.ts` (auth section) |
| RPC definition | `migrations/0001_activate_workspace.sql` |
| Unit test structure | `src/services/auth.service.test.ts` |
| Middleware tests | `src/middleware/auth.test.ts` |

---

## Module-specific notes

### For the employees module

- Employee list endpoint: `authorizeModule('users.view')`
- Create endpoint: `authorizeRole('OWNER')` only — do NOT trust the client to enforce this
- Deactivation: set `is_active = false`, do not delete rows (they're FK targets)
- Password reset for an employee: reuse `resetOwnerPassword` from auth.service (rename if needed)
- Avatar upload: defer to a separate module (storage bucket integration)

### For the POS module

- Cart to contract: single RPC that creates the contract, its items, and the inventory transactions
- **Never trust client-supplied prices.** The service recomputes `total_sale_amount_piasters` from the product rows.
- Idempotency key on contract creation. The DB has `UNIQUE (organization_id, idempotency_key)` on `payments`; mirror this pattern on `contracts` if needed.
- Cash sale payments and installment down-payments are separate payment subtypes. See §10 of the schema.

### For the collections module

- Wallet cycle is stateful — open, collect, settle, close. Each transition is its own RPC.
- Collection acceptance is an append-only event (`collection_acceptances`). Never update a payment.
- GPS capture: reject if accuracy > 100m. Reject if the location is suspiciously far from the customer's recorded address.

### For the treasury module

- Vault transfers: two paired `vault_transactions` rows in one RPC. The `paired_payment_id` links them.
- Balance is a projection from `vault_balances`. Never cache it on the vaults table.
- Cash variance: always requires a `reason`.

---

## Updating this document

When you discover a new pattern, add it here. When you find an anti-pattern
in the wild, add it to the anti-pattern table.

If an entire section is wrong or missing, flag it in a PR comment and
propose a change. This document is the guardrail — if it drifts from
reality, every future module drifts with it.