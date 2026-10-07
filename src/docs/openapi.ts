// server/src/docs/openapi.ts
//
// Single source of truth for the HTTP API. Served by Swagger UI at /docs.
//
// WHY A .ts FILE AND NOT .yaml:
//   A YAML spec would need to be read from disk at runtime and copied into
//   dist/ during build — an extra step that's easy to forget and hard to
//   debug. A TS module is compiled with the rest of the source, gives
//   autocomplete while editing, and fails at typecheck if malformed.
//
// WHEN THIS FILE GETS PAINFUL (roughly >30 endpoints): migrate to a
// generator that derives the spec from Zod schemas (see @asteasolutions/
// zod-to-openapi) so request/response shapes can't drift from the
// validators. For now, hand-written is smaller than the migration.

export const openApiSpec = {
    openapi: '3.0.3',
    info: {
        title: 'EcoFin Pro API',
        version: '0.1.0',
        description:
            'Multi-tenant retail ERP/POS. Tenant scope is resolved from the ' +
            'JWT `sub` claim against the `employees` table.',
    },
    servers: [
        { url: 'http://localhost:3001', description: 'Local development' },
    ],
    tags: [
        { name: 'Health', description: 'Health check' },
        { name: 'Auth — public', description: 'No authentication required' },
        { name: 'Auth — authenticated', description: 'Requires a bearer JWT' },
        { name: 'Access (F06)', description: 'Permissions and branch scope' },
        { name: 'Audit (F07)', description: 'Search the shop audit log (audit.view)' },
    ],
    components: {
        securitySchemes: {
            bearerAuth: {
                type: 'http',
                scheme: 'bearer',
                bearerFormat: 'JWT',
                description:
                    'The `access_token` returned by /api/auth/login. ' +
                    'Paste it into the Authorize dialog — Swagger sends it on ' +
                    'every request from the same page.',
            },
        },
        schemas: {
            Health: {
                type: 'object',
                required: ['status', 'db', 'version', 'time'],
                properties: {
                    status: { type: 'string', enum: ['ok', 'degraded'] },
                    db: { type: 'string', enum: ['ok', 'down'] },
                    version: { type: 'string' },
                    time: { type: 'string', format: 'date-time' },
                },
            },
            Error: {
                type: 'object',
                required: ['error'],
                properties: {
                    error: {
                        type: 'object',
                        required: ['code', 'message'],
                        properties: {
                            code: {
                                type: 'string',
                                description: 'Machine-readable error code (contracts ErrorCode)',
                                example: 'INVALID_CREDENTIALS',
                            },
                            message: { type: 'string', description: 'Generic, safe message' },
                            details: {
                                description:
                                    'Optional structured detail (e.g. field issues for VALIDATION_FAILED). Sensitive keys are redacted.',
                                nullable: true,
                            },
                            requestId: { type: 'string' },
                        },
                    },
                },
            },

            // ---------- Auth (shapes from @ziadkhaled-wb/contracts `auth`) ----------

            ShopMembership: {
                type: 'object',
                required: ['orgId', 'orgName', 'tenantSlug', 'role'],
                properties: {
                    orgId: { type: 'string', format: 'uuid' },
                    orgName: { type: 'string' },
                    tenantSlug: { type: 'string', example: 'dev-shop-one' },
                    role: {
                        type: 'string',
                        enum: ['OWNER', 'BRANCH_MANAGER', 'CASHIER', 'WAREHOUSE', 'COLLECTOR', 'ACCOUNTANT', 'LAWYER'],
                    },
                },
            },
            AuthSession: {
                type: 'object',
                required: ['accessToken', 'refreshToken', 'expiresAt'],
                properties: {
                    accessToken: { type: 'string' },
                    refreshToken: { type: 'string' },
                    expiresAt: { type: 'string', format: 'date-time' },
                },
            },
            LoginRequest: {
                type: 'object',
                required: ['identifier', 'password'],
                additionalProperties: false,
                properties: {
                    identifier: {
                        type: 'string',
                        example: 'owner.one@ecotech.test',
                        description: 'Email, or a username (then tenantSlug is required).',
                    },
                    password: { type: 'string', format: 'password' },
                    tenantSlug: {
                        type: 'string',
                        example: 'dev-shop-one',
                        description: 'Required with a username. With a two-shop login it picks that shop.',
                    },
                },
            },
            LoginResponse: {
                allOf: [
                    { $ref: '#/components/schemas/AuthSession' },
                    {
                        type: 'object',
                        required: ['user', 'mustChangePassword', 'shops', 'requiresShopSelection'],
                        properties: {
                            user: {
                                type: 'object',
                                required: ['id', 'email'],
                                properties: {
                                    id: { type: 'string', format: 'uuid' },
                                    email: { type: 'string', nullable: true },
                                },
                            },
                            mustChangePassword: { type: 'boolean' },
                            shops: { type: 'array', items: { $ref: '#/components/schemas/ShopMembership' } },
                            requiresShopSelection: {
                                type: 'boolean',
                                description: 'True when the login has several shops and none was chosen: send x-org-id.',
                            },
                        },
                    },
                ],
            },
            RefreshRequest: {
                type: 'object',
                required: ['refreshToken'],
                additionalProperties: false,
                properties: { refreshToken: { type: 'string' } },
            },
            ForgotPasswordRequest: {
                type: 'object',
                required: ['identifier'],
                additionalProperties: false,
                properties: {
                    identifier: { type: 'string', example: 'owner.one@ecotech.test' },
                    tenantSlug: { type: 'string', description: 'Required with a username.' },
                },
            },
            ResetPasswordRequest: {
                type: 'object',
                required: ['token', 'newPassword'],
                additionalProperties: false,
                properties: {
                    token: {
                        type: 'string',
                        description:
                            'Access token of the recovery session from the emailed link (or the link token_hash).',
                    },
                    newPassword: { type: 'string', format: 'password', minLength: 8, maxLength: 72 },
                },
            },
            ChangePasswordRequest: {
                type: 'object',
                required: ['currentPassword', 'newPassword'],
                additionalProperties: false,
                properties: {
                    currentPassword: { type: 'string', format: 'password' },
                    newPassword: { type: 'string', format: 'password', minLength: 8, maxLength: 72 },
                },
            },
            MeResponse: {
                type: 'object',
                required: ['employee', 'org', 'branches'],
                properties: {
                    employee: {
                        type: 'object',
                        required: ['id', 'fullName', 'email', 'username', 'role', 'defaultBranchId', 'mustChangePassword'],
                        properties: {
                            id: { type: 'string', format: 'uuid' },
                            fullName: { type: 'string' },
                            email: { type: 'string', nullable: true },
                            username: { type: 'string', nullable: true },
                            role: { type: 'string' },
                            defaultBranchId: { type: 'string', format: 'uuid', nullable: true },
                            mustChangePassword: { type: 'boolean' },
                        },
                    },
                    org: {
                        type: 'object',
                        required: ['id', 'tenantSlug', 'name', 'timezone', 'defaultLanguage', 'status', 'planKey', 'subscriptionEnd'],
                        properties: {
                            id: { type: 'string', format: 'uuid' },
                            tenantSlug: { type: 'string' },
                            name: { type: 'string' },
                            timezone: { type: 'string' },
                            defaultLanguage: { type: 'string', enum: ['ar', 'en'] },
                            status: { type: 'string', enum: ['active', 'suspended', 'expired', 'closed'] },
                            planKey: { type: 'string' },
                            subscriptionEnd: { type: 'string', format: 'date', nullable: true },
                        },
                    },
                    branches: {
                        type: 'array',
                        items: {
                            type: 'object',
                            required: ['id', 'code', 'name', 'isMain'],
                            properties: {
                                id: { type: 'string', format: 'uuid' },
                                code: { type: 'string' },
                                name: { type: 'string' },
                                isMain: { type: 'boolean' },
                            },
                        },
                    },
                },
            },
            SelectShopRequest: {
                type: 'object',
                required: ['orgId'],
                additionalProperties: false,
                properties: { orgId: { type: 'string', format: 'uuid' } },
            },
            SelectShopResponse: {
                type: 'object',
                required: ['user', 'shop'],
                additionalProperties: false,
                properties: {
                    user: {
                        type: 'object',
                        required: ['id', 'email'],
                        properties: {
                            id: { type: 'string', format: 'uuid' },
                            email: { type: 'string', nullable: true },
                        },
                    },
                    shop: { $ref: '#/components/schemas/ShopMembership' },
                },
            },
            Ack: {
                type: 'object',
                required: ['ok'],
                properties: { ok: { type: 'boolean', enum: [true] } },
            },
        },

        parameters: {
            OrgId: {
                name: 'x-org-id',
                in: 'header',
                required: false,
                schema: { type: 'string', format: 'uuid' },
                description:
                    'Active shop for a login with several shops. Must be a UUID; the database checks membership.',
            },
        },

        responses: {
            Error: {
                description: 'Contract error (see error.code).',
                content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
            },
        },
    },

    paths: {
        // =========================================================
        // Health
        // =========================================================
        '/health': {
            get: {
                tags: ['Health'],
                summary: 'Health check (public, checks the database)',
                security: [],
                responses: {
                    200: {
                        description: 'Service and database are up',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Health' },
                                example: {
                                    status: 'ok',
                                    db: 'ok',
                                    version: '0.1.0',
                                    time: '2026-10-03T12:00:00.000Z',
                                },
                            },
                        },
                    },
                    503: {
                        description: 'Database unreachable or too slow (status degraded, db down)',
                        content: {
                            'application/json': {
                                schema: { $ref: '#/components/schemas/Health' },
                            },
                        },
                    },
                },
            },
        },
        // =========================================================
        // Auth (F04)
        // =========================================================
        '/api/auth/login': {
            post: {
                tags: ['Auth — public'],
                summary: 'Log in with email, or shop slug + username',
                description:
                    'Unknown user, wrong password and unknown slug all return the same 401 INVALID_CREDENTIALS. ' +
                    'Refused after a correct password (session revoked): 403 ACCOUNT_DISABLED, SHOP_INACTIVE, ' +
                    'SUBSCRIPTION_EXPIRED. Lockout (D17): 429 TOO_MANY_LOGIN_ATTEMPTS.',
                security: [],
                requestBody: {
                    required: true,
                    content: { 'application/json': { schema: { $ref: '#/components/schemas/LoginRequest' } } },
                },
                responses: {
                    200: {
                        description: 'Tokens and shops',
                        content: { 'application/json': { schema: { $ref: '#/components/schemas/LoginResponse' } } },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                    429: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/auth/refresh': {
            post: {
                tags: ['Auth — public'],
                summary: 'New token pair from a refresh token',
                description:
                    'Invalid or used refresh token: 401 TOKEN_INVALID. Supabase Auth busy or failing: 500 ' +
                    '(keep the session and retry). Own per-IP limit: 60 per minute (429).',
                security: [],
                requestBody: {
                    required: true,
                    content: { 'application/json': { schema: { $ref: '#/components/schemas/RefreshRequest' } } },
                },
                responses: {
                    200: {
                        description: 'New tokens',
                        content: { 'application/json': { schema: { $ref: '#/components/schemas/AuthSession' } } },
                    },
                    401: { $ref: '#/components/responses/Error' },
                    429: { $ref: '#/components/responses/Error' },
                    500: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/auth/forgot-password': {
            post: {
                tags: ['Auth — public'],
                summary: 'Send the password reset email (always 202)',
                security: [],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/ForgotPasswordRequest' } },
                    },
                },
                responses: {
                    202: {
                        description: 'Same answer whether or not the account exists',
                        content: { 'application/json': { schema: { $ref: '#/components/schemas/Ack' } } },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    429: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/auth/reset-password': {
            post: {
                tags: ['Auth — public'],
                summary: 'Set a new password with the token from the reset email',
                description: 'Ends every session of the user. A normal login token is refused (401 TOKEN_INVALID).',
                security: [],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/ResetPasswordRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'Password changed',
                        content: { 'application/json': { schema: { $ref: '#/components/schemas/Ack' } } },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/auth/me': {
            get: {
                tags: ['Auth — authenticated'],
                summary: 'The caller in the active shop',
                description:
                    'Two shops and no x-org-id: 400 SHOP_SELECTION_REQUIRED. A shop the caller is not in: 403 SHOP_NOT_ALLOWED.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: {
                    200: {
                        description: 'Employee, shop and branches',
                        content: { 'application/json': { schema: { $ref: '#/components/schemas/MeResponse' } } },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/auth/select-shop': {
            post: {
                tags: ['Auth — authenticated'],
                summary: 'Choose the active shop for a login with several shops (D23)',
                description:
                    'Works with the multi-shop login token and no x-org-id. The shop must be one of the ' +
                    "caller's usable shops (else 403 SHOP_NOT_ALLOWED). Writes auth.login in that shop. " +
                    'The client keeps its tokens and sends x-org-id from then on.',
                security: [{ bearerAuth: [] }],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/SelectShopRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'The chosen shop',
                        content: {
                            'application/json': { schema: { $ref: '#/components/schemas/SelectShopResponse' } },
                        },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/auth/logout': {
            post: {
                tags: ['Auth — authenticated'],
                summary: 'Revoke this session on the server',
                description: 'Afterwards the access token gets 401 on this API and the refresh token is dead.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: {
                    200: {
                        description: 'Logged out',
                        content: { 'application/json': { schema: { $ref: '#/components/schemas/Ack' } } },
                    },
                    401: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/auth/change-password': {
            post: {
                tags: ['Auth — authenticated'],
                summary: 'Change your own password',
                description:
                    'Wrong current password: 401 INVALID_CREDENTIALS. Clears must_change_password and ends the other sessions.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': { schema: { $ref: '#/components/schemas/ChangePasswordRequest' } },
                    },
                },
                responses: {
                    200: {
                        description: 'Password changed',
                        content: { 'application/json': { schema: { $ref: '#/components/schemas/Ack' } } },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                    429: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/me/permissions': {
            get: {
                tags: ['Access (F06)'],
                summary: 'Your effective permissions and branches',
                description:
                    'Role defaults plus or minus per-employee overrides; the owner has every key and every branch (allBranches: true).',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: {
                    200: {
                        description: 'Permission keys and branch scope',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['keys', 'branchIds', 'allBranches'],
                                    properties: {
                                        keys: { type: 'array', items: { type: 'string', example: 'sale.create' } },
                                        branchIds: { type: 'array', items: { type: 'string', format: 'uuid' } },
                                        allBranches: { type: 'boolean' },
                                    },
                                },
                            },
                        },
                    },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/employees/{employeeId}/permissions': {
            put: {
                tags: ['Access (F06)'],
                summary: 'Add or remove one permission for an employee (employee.manage)',
                description:
                    'Setting a key back to the role default removes the override. 403 FORBIDDEN: the owner or yourself as target; a non-owner granting or removing a key they don\'t hold, or employee.manage (owner-only). Another shop\'s employee: 404. One audit row per call.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'employeeId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: {
                                type: 'object',
                                additionalProperties: false,
                                required: ['permissionKey', 'granted', 'reason'],
                                properties: {
                                    permissionKey: { type: 'string', example: 'sale.void' },
                                    granted: { type: 'boolean' },
                                    reason: { type: 'string', minLength: 1, maxLength: 500, description: 'Stored on the audit row' },
                                },
                            },
                        },
                    },
                },
                responses: {
                    200: {
                        description: 'The effective value',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    properties: {
                                        employeeId: { type: 'string', format: 'uuid' },
                                        permissionKey: { type: 'string' },
                                        granted: { type: 'boolean' },
                                    },
                                },
                            },
                        },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                    404: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/employees/{employeeId}/branches': {
            put: {
                tags: ['Access (F06)'],
                summary: 'Replace an employee\'s branch list (employee.manage)',
                description:
                    'Every branch must be in your shop (422 BRANCH_NOT_IN_ORG). An empty list removes every branch. 403 FORBIDDEN: the owner or yourself as target; a non-owner adding or removing a branch they don\'t work in. One audit row per call.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'employeeId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: {
                                type: 'object',
                                additionalProperties: false,
                                required: ['branchIds', 'reason'],
                                properties: {
                                    branchIds: { type: 'array', maxItems: 100, items: { type: 'string', format: 'uuid' } },
                                    reason: { type: 'string', minLength: 1, maxLength: 500, description: 'Stored on the audit row' },
                                },
                            },
                        },
                    },
                },
                responses: {
                    200: {
                        description: 'The new branch list',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    properties: {
                                        employeeId: { type: 'string', format: 'uuid' },
                                        branchIds: { type: 'array', items: { type: 'string', format: 'uuid' } },
                                    },
                                },
                            },
                        },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                    404: { $ref: '#/components/responses/Error' },
                    422: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/employees/{employeeId}/active': {
            put: {
                tags: ['Access (F06)'],
                summary: 'Deactivate or reactivate an employee (employee.manage)',
                description:
                    'EC-143. A deactivated employee is refused on their very next request (403 ACCOUNT_DISABLED), even with a live token, and can\'t log in. 404 NOT_FOUND: not an employee of your shop. 403 FORBIDDEN: the owner or yourself as target. One audit row (employee.active_set) per state change; unchanged state writes none. Deactivation requires a reason; reactivation accepts an omitted reason.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'employeeId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                requestBody: {
                    required: true,
                    content: {
                        'application/json': {
                            schema: {
                                type: 'object',
                                additionalProperties: false,
                                required: ['active'],
                                properties: {
                                    active: { type: 'boolean' },
                                    reason: { type: 'string', minLength: 1, description: 'Required when active is false; stored on the audit row' },
                                },
                            },
                        },
                    },
                },
                responses: {
                    200: {
                        description: 'The new state',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    properties: {
                                        id: { type: 'string', format: 'uuid' },
                                        is_active: { type: 'boolean' },
                                        employeeId: { type: 'string', format: 'uuid' },
                                        active: { type: 'boolean' },
                                    },
                                },
                            },
                        },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                    404: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/monitoring/test-error': {
            post: {
                tags: ['Monitoring (Q02)'],
                summary: 'Raise a deliberate server error (org.settings_manage)',
                description:
                    'Always 500 INTERNAL with a request id; the same id is on the error in Sentry when error tracking is on. Writes nothing. Takes no body.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: {
                    '403': { description: 'No org.settings_manage, or a shop you are not in' },
                    '500': { description: 'The deliberate test error (contract error shape with requestId)' },
                },
            },
        },
        '/api/audit': {
            get: {
                tags: ['Audit (F07)'],
                summary: 'Search the audit log of your shop (audit.view)',
                description:
                    'Newest first. Rows are already PII-stripped. Only your shop is searched (the session decides; an org in the query is 400). Unknown filters are 400.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'page', in: 'query', required: false, schema: { type: 'integer', minimum: 1, default: 1 }, description: 'Page number' },
                    { name: 'pageSize', in: 'query', required: false, schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 }, description: 'Rows per page' },
                    { name: 'from', in: 'query', required: false, schema: { type: 'string', format: 'date-time' }, description: 'Created at or after' },
                    { name: 'to', in: 'query', required: false, schema: { type: 'string', format: 'date-time' }, description: 'Created at or before' },
                    { name: 'actorEmployeeId', in: 'query', required: false, schema: { type: 'string', format: 'uuid' }, description: 'Who did it' },
                    { name: 'action', in: 'query', required: false, schema: { type: 'string', example: 'auth.login' }, description: 'Exact action' },
                    { name: 'entityType', in: 'query', required: false, schema: { type: 'string', example: 'employee' }, description: 'Record type' },
                    { name: 'entityId', in: 'query', required: false, schema: { type: 'string', format: 'uuid' }, description: 'Record id' },
                    { name: 'branchId', in: 'query', required: false, schema: { type: 'string', format: 'uuid' }, description: 'Branch' },
                ],
                responses: {
                    200: {
                        description: 'One page of audit rows',
                        content: {
                            'application/json': {
                                schema: {
                                    type: 'object',
                                    required: ['items', 'page', 'pageSize', 'total'],
                                    properties: {
                                        items: {
                                            type: 'array',
                                            items: {
                                                type: 'object',
                                                properties: {
                                                    id: { type: 'integer' },
                                                    branchId: { ...{ type: 'string', format: 'uuid' }, nullable: true },
                                                    employeeId: { ...{ type: 'string', format: 'uuid' }, nullable: true },
                                                    actorName: { type: 'string', nullable: true },
                                                    superAdminId: { ...{ type: 'string', format: 'uuid' }, nullable: true },
                                                    deviceId: { ...{ type: 'string', format: 'uuid' }, nullable: true },
                                                    ip: { type: 'string', nullable: true },
                                                    userAgent: { type: 'string', nullable: true },
                                                    requestId: { type: 'string', nullable: true },
                                                    action: { type: 'string' },
                                                    entityType: { type: 'string', nullable: true },
                                                    entityId: { ...{ type: 'string', format: 'uuid' }, nullable: true },
                                                    severity: { type: 'string', enum: ['info', 'warning', 'critical'] },
                                                    reason: { type: 'string', nullable: true },
                                                    before: {},
                                                    after: {},
                                                    createdAt: { type: 'string', format: 'date-time' },
                                                },
                                            },
                                        },
                                        page: { type: 'integer' },
                                        pageSize: { type: 'integer' },
                                        total: { type: 'integer' },
                                    },
                                },
                            },
                        },
                    },
                    400: { $ref: '#/components/responses/Error' },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/settings': {
            get: {
                tags: ['Settings'],
                summary: 'Shop settings (P03)',
                description:
                    'Any employee of the shop. Money and column percentages are decimal strings. Includes the caller\'s own discount cap (my_discount), the current installment policy and the tax class options. Schema: ShopSettings in @ziadkhaled-wb/contracts.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: {
                    200: { description: 'Settings', content: { 'application/json': { schema: { type: 'object' } } } },
                    401: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                },
            },
            patch: {
                tags: ['Settings'],
                summary: 'Change shop settings (org.settings_manage)',
                description:
                    'Any subset of the editable fields (ShopSettingsUpdateBody). receipt_fields and legal_referral_days merge; discount_caps replaces. One org.settings_updated audit row with the changed keys; no change, no row. Errors: SETTINGS_INVALID, NAME_REQUIRED, TAX_CLASS_NOT_FOUND, FILE_NOT_FOUND.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: {
                    200: { description: 'The full settings after the change', content: { 'application/json': { schema: { type: 'object' } } } },
                    400: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                    404: { $ref: '#/components/responses/Error' },
                },
            },
        },
        '/api/tax-classes': {
            get: {
                tags: ['Tax'],
                summary: 'Tax classes of the shop (T01)',
                description: 'Any employee. Archived classes last. Rates are decimal strings. Schema: TaxClassList.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'TaxClassList', content: { 'application/json': { schema: { type: 'array', items: { type: 'object' } } } } } },
            },
            post: {
                tags: ['Tax'],
                summary: 'Create a tax class (catalog.manage)',
                description: 'TaxClassCreateBody. Zero-rated and exempt classes are 0%. Errors: TAX_CLASS_NAME_TAKEN, NAME_REQUIRED, VALIDATION_FAILED.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: { 201: { description: 'TaxClass' }, 400: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/tax-classes/{id}': {
            patch: {
                tags: ['Tax'],
                summary: 'Change a tax class (catalog.manage)',
                description: 'TaxClassUpdateBody. A new rate applies to new documents only; issued lines keep their snapshot.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: { 200: { description: 'TaxClass' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/tax-classes/{id}/archive': {
            post: {
                tags: ['Tax'],
                summary: 'Archive a tax class (catalog.manage); /restore brings it back',
                description: 'The default class, the delivery fee class and a class used by active products answer TAX_CLASS_IN_USE.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'TaxClass' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/categories': {
            get: {
                tags: ['Catalog'],
                summary: 'List product categories',
                security: [{ bearerAuth: [] }],
                responses: { 200: { description: 'CategoryList' } },
            },
            post: {
                tags: ['Catalog'],
                summary: 'Create a product category',
                security: [{ bearerAuth: [] }],
                responses: { 201: { description: 'Category' } },
            },
        },
        '/api/categories/{id}': {
            patch: {
                tags: ['Catalog'],
                summary: 'Update a product category',
                security: [{ bearerAuth: [] }],
                responses: { 200: { description: 'Category' } },
            },
        },
        '/api/categories/{id}/archive': {
            post: {
                tags: ['Catalog'],
                summary: 'Archive a product category',
                security: [{ bearerAuth: [] }],
                responses: { 200: { description: 'Category' } },
            },
        },
        '/api/categories/{id}/restore': {
            post: {
                tags: ['Catalog'],
                summary: 'Restore a product category',
                security: [{ bearerAuth: [] }],
                responses: { 200: { description: 'Category' } },
            },
        },
        '/api/products': {
            get: {
                tags: ['Catalog'],
                summary: 'Search the catalog (any employee)',
                description: 'search matches the Arabic or English name, a SKU prefix or the exact barcode. category_id includes subcategories unless include_subcategories=false. status: active (default) | archived | all. Schema: ProductListQuery → ProductList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 100 } },
                    { name: 'category_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'include_subcategories', in: 'query', schema: { type: 'string', enum: ['true', 'false'], default: 'true' } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['active', 'archived', 'all'], default: 'active' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'ProductList' }, 400: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Catalog'],
                summary: 'Create a product (catalog.manage)',
                description: 'An empty or missing barcode is generated (in-store EAN-13 starting with 2). tax_class_id defaults to the shop default. avg_cost is never accepted. Schema: ProductCreateBody → Product.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'Product' }, 400: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/products/lookup': {
            get: {
                tags: ['Catalog'],
                summary: 'POS lookup: an active product by exact barcode, then SKU (any employee)',
                description: 'Archived products answer PRODUCT_NOT_FOUND. Schema: ProductLookupQuery → Product.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'code', in: 'query', required: true, schema: { type: 'string', minLength: 1, maxLength: 64 } }],
                responses: { 200: { description: 'Product' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/products/{id}': {
            get: {
                tags: ['Catalog'],
                summary: 'Read a product, archived included (any employee)',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Product' }, 404: { $ref: '#/components/responses/Error' } },
            },
            patch: {
                tags: ['Catalog'],
                summary: 'Update a product (catalog.manage; a price change also needs catalog.price_change)',
                description: 'barcode null or empty generates a new one. is_serialized is locked (PRODUCT_SERIAL_LOCKED) once units or stock movements exist. An archived product answers PRODUCT_NOT_FOUND. Schema: ProductUpdateBody → Product.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Product' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/products/{id}/units': {
            get: {
                tags: ['Catalog'],
                summary: 'Serialized units of a product, for labels (any employee)',
                description: 'Units in the branches the caller can access (OWNER: all), in serial order. status: in_stock (default), any unit status, or all. Another shop\'s product answers PRODUCT_NOT_FOUND. Schema: ProductUnitsQuery → ProductUnitList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'status', in: 'query', schema: { type: 'string', default: 'in_stock' } },
                ],
                responses: { 200: { description: 'ProductUnitList' }, 400: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },        '/api/products/{id}/archive': {
            post: {
                tags: ['Catalog'],
                summary: 'Archive a product (catalog.manage); it can no longer be sold',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Product' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/products/{id}/restore': {
            post: {
                tags: ['Catalog'],
                summary: 'Restore an archived product (catalog.manage)',
                description: 'Refused under an archived category (PRODUCT_CATEGORY_ARCHIVED) or with an archived tax class (TAX_CLASS_NOT_FOUND).',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Product' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/settings/profile': {
            get: {
                tags: ['Settings'],
                summary: 'Read the legal and financing profile (P04)',
                description: 'Any employee may read the shop profile. creditor_model is read-only and is in_house in V1. Schema: ShopProfile.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'ShopProfile' }, 401: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
            patch: {
                tags: ['Settings'],
                summary: 'Update the legal and financing profile (org.profile_manage)',
                description: 'Body: ShopProfileUpdateBody. Legal status is owner-entered information, not an eligibility determination. One org.profile_updated audit row records changed keys only. Turning installments off denies new contract inserts and leaves existing contracts serviceable.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: { 200: { description: 'ShopProfile' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/settings/installment-policies': {
            get: {
                tags: ['Settings'],
                summary: 'Installment policy versions, newest first (org.settings_manage)',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: {
                    200: { description: 'InstallmentPolicyList', content: { 'application/json': { schema: { type: 'array', items: { type: 'object' } } } } },
                    403: { $ref: '#/components/responses/Error' },
                },
            },
            post: {
                tags: ['Settings'],
                summary: 'Publish a new installment policy version (org.settings_manage, installments module)',
                description:
                    'Body: InstallmentPolicyBody, the changes from the current version. Versions are immutable; contracts keep the version they used. The same terms again return the current version. Errors: POLICY_INVALID, MODULE_NOT_IN_PLAN.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: {
                    201: { description: 'The current version (InstallmentPolicy)', content: { 'application/json': { schema: { type: 'object' } } } },
                    400: { $ref: '#/components/responses/Error' },
                    403: { $ref: '#/components/responses/Error' },
                },
            },
        },
    },
} as const;

export type OpenApiSpec = typeof openApiSpec;
