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
        '/api/stock': {
            get: {
                tags: ['Inventory'],
                summary: 'Stock per product and branch (stock.view)',
                description: 'I01. One row per product and branch in the caller\'s branches: on_hand, reserved, available (= on_hand − reserved), damaged, in_transit (sent transfers coming in), min_level and low (available < min_level). Every active product shows, also with zero stock. Filters: branch_id, category_id (+ include_subcategories), search, low_only. Schema: StockListQuery → StockList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'category_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'include_subcategories', in: 'query', schema: { type: 'string', enum: ['true', 'false'], default: 'true' } },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 100 } },
                    { name: 'low_only', in: 'query', schema: { type: 'string', enum: ['true', 'false'], default: 'false' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'StockList' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/movements': {
            get: {
                tags: ['Inventory'],
                summary: 'Movement history: ledger movements, newest first, with the running balance (stock.view)',
                description: 'I01 drill-down and I05 movement history (D51). Every filter is optional: product, branch (every branch in scope when left out), serial (exact, any case), types (comma-separated movement types), from / to (business dates). The running balance is the on-hand of that product, branch and stock state after the movement, over the whole ledger. Each movement names its product, unit, employee and source document (source_type + source_id, number, other party, adjustment reason). Errors: PRODUCT_NOT_FOUND, BRANCH_NOT_FOUND, BRANCH_DENIED, VALIDATION_FAILED. Schema: StockMovementsQuery → StockMovementList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'product_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'serial', in: 'query', schema: { type: 'string', maxLength: 64 } },
                    { name: 'types', in: 'query', description: 'Comma-separated: opening, purchase_in, purchase_return_out, sale_out, sale_return_in, transfer_out, transfer_in, adjustment, delivery_out, claim_out, claim_in', schema: { type: 'string' } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'StockMovementList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/low-summary': {
            get: {
                tags: ['Inventory'],
                summary: 'Low-stock dashboard card (stock.view)',
                description: 'I06 (D52). Low products per active branch of the caller and the biggest shortages (min level − available), 1-20 items (limit, default 5). A product is low when available < its min level: the branch override, else the product min stock, else the shop global minimum; never for an archived product or a deactivated branch. Schema: LowStockSummaryQuery → LowStockSummary.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'limit', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 20, default: 5 } },
                ],
                responses: { 200: { description: 'LowStockSummary' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/min-levels/{id}': {
            get: {
                tags: ['Inventory'],
                summary: 'A product min level in each of the caller branches (stock.view)',
                description: 'I06 (D52). Per branch: the override (min_stock, null when none), the level in use and where it comes from (branch, product, shop). Errors: PRODUCT_NOT_FOUND. Schema: BranchMinLevels.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'BranchMinLevels' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            put: {
                tags: ['Inventory'],
                summary: 'Set or remove a branch min level for a product (catalog.manage)',
                description: 'I06 (D52, user decision). min_stock 0-1 000 000 (0 = never low in that branch) or null to fall back to the product or shop level. Needs the branch (BRANCH_DENIED, BRANCH_INACTIVE); audited as stock.min_level_set with before and after. Errors: PRODUCT_NOT_FOUND, BRANCH_NOT_FOUND, VALIDATION_FAILED, SUBSCRIPTION_EXPIRED. Schema: BranchMinLevelBody → BranchMinLevels.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'BranchMinLevels' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/movements/export': {
            post: {
                tags: ['Inventory'],
                summary: 'Export the movement history (export.data + stock.view)',
                description: 'I05 (D51, user decision). The same filters as GET /api/stock/movements in the body, no paging; every matching movement, newest first, for the website to turn into a CSV. At most 10 000 rows: more is refused with EXPORT_TOO_LARGE (422, details.total and details.limit), never cut. Works in an expired shop. Audited as stock_movements.exported with the filters and the row count. Schema: StockMovementExportBody → StockMovementExport.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'StockMovementExport' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/adjustments': {
            get: {
                tags: ['Inventory'],
                summary: 'Stock adjustments, newest first (stock.view)',
                description: 'I02. Adjustments in the caller\'s branches; filters branch_id and reason (damage, loss, found, correction, count, other). Schema: StockAdjustmentListQuery → StockAdjustmentList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'reason', in: 'query', schema: { type: 'string', enum: ['damage', 'loss', 'found', 'correction', 'count', 'other'] } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'StockAdjustmentList' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Inventory'],
                summary: 'Post a stock adjustment (stock.adjust)',
                description: 'I02. Lines change sellable stock through the ledger (type adjustment). damage and loss remove stock, found adds it, correction and other go either way; other needs a note. Serialized products need unit_id and ±1. The same Idempotency-Key again returns the first adjustment. Errors: ADJUSTMENT_SIGN_INVALID, OUT_OF_STOCK, UNIT_*, DAY_CLOSED. Schema: StockAdjustmentCreateBody → StockAdjustment.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'StockAdjustment' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/adjustments/{id}': {
            get: {
                tags: ['Inventory'],
                summary: 'An adjustment with its lines (stock.view)',
                description: 'I02. Schema: StockAdjustment.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockAdjustment' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/counts': {
            get: {
                tags: ['Inventory'],
                summary: 'Stock counts, newest first (stock.count)',
                description: 'I02. Counts in the caller\'s branches; filters branch_id and status (open, posted, cancelled). Schema: StockCountListQuery → StockCountList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['open', 'posted', 'cancelled'] } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'StockCountList' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Inventory'],
                summary: 'Open a count sheet for a branch, optionally one category (stock.count)',
                description: 'I02. Lines are snapshotted: a line per product in scope (active, or archived with stock) and per serialized unit in the branch. Counts covering the same products can\'t be open together (STOCK_COUNT_OPEN). Schema: StockCountCreateBody → StockCount.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'StockCount' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/counts/{id}': {
            get: {
                tags: ['Inventory'],
                summary: 'A count and one page of its lines (stock.count)',
                description: 'I02. While open, expected_qty is the live stock, so difference is what posting will change. filter: all, uncounted, different; search: name, SKU prefix, exact barcode or serial. Schema: StockCountDetailQuery → StockCountDetail.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'filter', in: 'query', schema: { type: 'string', enum: ['all', 'uncounted', 'different'], default: 'all' } },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 100 } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'StockCountDetail' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/counts/{id}/lines': {
            put: {
                tags: ['Inventory'],
                summary: 'Save counted quantities (stock.count)',
                description: 'I02. Up to 500 lines; null clears a line. A product or unit in scope that is not on the sheet is added. Not audited (draft); posting is. Schema: StockCountLinesBody → StockCount.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockCount' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/counts/{id}/scan': {
            post: {
                tags: ['Inventory'],
                summary: 'Scan a serial, barcode or SKU into a count (stock.count)',
                description: 'I02. A serial counts its unit (1); a barcode or SKU adds one to the product\'s line; a serialized product\'s barcode is refused (UNIT_REQUIRED). Schema: StockCountScanBody → StockCountLine.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockCountLine' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/counts/{id}/post': {
            post: {
                tags: ['Inventory'],
                summary: 'Post a count (stock.count)',
                description: 'I02. Locks the stock, stores expected quantities and posts every difference as one adjustment (reason count): the stock then equals the counted numbers. Uncounted lines block it (STOCK_COUNT_INCOMPLETE) unless uncounted_as_zero. A posted count answers its result again. Schema: StockCountPostBody → StockCount.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 200: { description: 'StockCount' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/counts/{id}/cancel': {
            post: {
                tags: ['Inventory'],
                summary: 'Cancel an open count (stock.count)',
                description: 'I02. No stock change. A posted count can\'t be cancelled (DOCUMENT_FINAL). Schema: StockCount.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockCount' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/transfers': {
            get: {
                tags: ['Inventory'],
                summary: 'Branch transfers, newest first (stock.view)',
                description: 'I03. Transfers out of or into the caller\'s branches; branch_id = either side; status filter. Schema: StockTransferListQuery -> StockTransferList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['draft', 'sent', 'received', 'partially_received', 'cancelled'] } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'StockTransferList' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Inventory'],
                summary: 'Create a draft transfer (stock.transfer_send)',
                description: 'I03. From a branch the caller works in to another branch of the shop; serialized lines need a unit in stock in the source. Nothing moves until it is sent. The same Idempotency-Key returns the same draft. Schema: StockTransferCreateBody -> StockTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'StockTransfer' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/transfers/destinations': {
            get: {
                tags: ['Inventory'],
                summary: 'Where a transfer can go (stock.transfer_send)',
                description: 'I03. Every active branch of the shop (id, code, name), also those the sender doesn\'t work in. Schema: TransferDestinationList.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'TransferDestinationList' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/transfers/{id}': {
            get: {
                tags: ['Inventory'],
                summary: 'A transfer with its lines (stock.view)',
                description: 'I03. Schema: StockTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockTransfer' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            put: {
                tags: ['Inventory'],
                summary: 'Replace the notes and lines of a draft (stock.transfer_send)',
                description: 'I03. Only while draft (TRANSFER_ALREADY_SENT after). Schema: StockTransferUpdateBody -> StockTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockTransfer' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/transfers/{id}/send': {
            post: {
                tags: ['Inventory'],
                summary: 'Send a draft (stock.transfer_send)',
                description: 'I03. Every line leaves the source branch (transfer_out) and shows as in transit at the destination; units are re-checked under a lock (a reserved unit stays). Sending again answers the transfer. Schema: StockTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockTransfer' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/transfers/{id}/receive': {
            post: {
                tags: ['Inventory'],
                summary: 'Receive a sent transfer at the destination (stock.transfer_receive)',
                description: 'I03. Lists only the lines that did not arrive in full (qty_received, reason loss or damage). Everything sent enters the destination, then each shortage is written off there by an adjustment with its reason. Receiving again answers the transfer. Schema: StockTransferReceiveBody -> StockTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockTransfer' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/stock/transfers/{id}/cancel': {
            post: {
                tags: ['Inventory'],
                summary: 'Cancel a draft (stock.transfer_send)',
                description: 'I03. Nothing moved, nothing moves. A sent transfer can\'t be cancelled (TRANSFER_ALREADY_SENT). Schema: StockTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'StockTransfer' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/suppliers': {
            get: {
                tags: ['Purchasing'],
                summary: 'List suppliers (any purchasing read key)',
                description: 'U01 (D53). Readable with any of supplier.manage, purchase.order_manage, purchase.invoice_create, purchase.invoice_approve, purchase.return_create, supplier.payment_create, report.financial; works in an expired shop. search matches the name (contains, any letter case) or a phone prefix (spaces and dashes ignored). status: active (default) | archived | all. Ordered by name. Each supplier carries its balance (what the shop owes). Schema: SupplierListQuery → SupplierList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 100 } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['active', 'archived', 'all'], default: 'active' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'SupplierList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Purchasing'],
                summary: 'Create a supplier (supplier.manage)',
                description: 'U01 (D53). name 1-150 (trimmed); phone stored without spaces or dashes (+ and 6-15 digits); tax_registration_no 9-20 digits or dashes; address up to 300; notes up to 1000; payment_terms_days 0-365 (default 0). Names (any letter case) and phones are unique among active suppliers: SUPPLIER_NAME_TAKEN, SUPPLIER_PHONE_TAKEN. Audited as supplier.created. Schema: SupplierCreateBody → Supplier.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'Supplier' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/suppliers/{id}': {
            get: {
                tags: ['Purchasing'],
                summary: 'Read a supplier, archived included (any purchasing read key)',
                description: 'U01 (D53). Another shop\'s id answers SUPPLIER_NOT_FOUND. Schema: Supplier.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Supplier' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            patch: {
                tags: ['Purchasing'],
                summary: 'Update a supplier (supplier.manage)',
                description: 'U01 (D53). Any create field, at least one; null clears an optional field. An archived supplier answers SUPPLIER_NOT_FOUND (restore it first). Audited as supplier.updated with the changed keys only; no change, no audit row. Schema: SupplierUpdateBody → Supplier.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Supplier' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/suppliers/{id}/statement': {
            get: {
                tags: ['Purchasing'],
                summary: 'Supplier statement with a running balance (any purchasing read key)',
                description: 'U01 (D53). Shop-wide (every branch): approved invoices (debit), payments (credit), payment reversals (debit) and returns (credit when supplier_credit; 0 and 0 when the supplier refunded cash), ordered by date. from/to are business dates (from must not be after to); opening_balance is the net of the documents before from. Without dates the closing balance equals the supplier balance (invoices − payments − credit returns). Schema: SupplierStatementQuery → SupplierStatement.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                ],
                responses: { 200: { description: 'SupplierStatement' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/suppliers/{id}/archive': {
            post: {
                tags: ['Purchasing'],
                summary: 'Deactivate (archive) a supplier (supplier.manage)',
                description: 'U01 (D53). Refused while the balance is not 0 (SUPPLIER_HAS_BALANCE) or with open documents: invoices in draft or pending approval, purchase orders in draft, sent or partially received (SUPPLIER_HAS_OPEN_DOCUMENTS). Already archived: no change. Audited as supplier.archived (warning).',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Supplier' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/suppliers/{id}/restore': {
            post: {
                tags: ['Purchasing'],
                summary: 'Restore an archived supplier (supplier.manage)',
                description: 'U01 (D53). Refused when an active supplier now has the same name or phone (SUPPLIER_NAME_TAKEN, SUPPLIER_PHONE_TAKEN). Audited as supplier.restored.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Supplier' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-invoices': {
            get: {
                tags: ['Purchasing'],
                summary: 'List purchase invoices of the caller\'s branches (any purchasing read key)',
                description: 'U02 (D54). Newest invoice date first. Filters: supplier_id, branch_id, status (draft | pending_approval | approved | rejected), from/to (invoice date), search (the PI number or the supplier\'s invoice number, contains). Another shop\'s supplier answers SUPPLIER_NOT_FOUND; a branch the caller doesn\'t work in BRANCH_DENIED. Works in an expired shop. Schema: PurchaseInvoiceListQuery → PurchaseInvoiceList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'supplier_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['draft', 'pending_approval', 'approved', 'rejected'] } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 40 } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'PurchaseInvoiceList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Purchasing'],
                summary: 'Create a draft purchase invoice (purchase.invoice_create)',
                description: 'U02 (D54). Supplier (active), branch (the caller\'s), optional supplier invoice number (unique per supplier among non-rejected invoices: SUPPLIER_INVOICE_NO_TAKEN), invoice date (not in the future), 1-200 lines with each product once: quantity 1-100 000, unit_cost BEFORE VAT, tax_class_id (default the product\'s), serials for serialized products (optional on a draft; one per unit; needs the serials module). VAT per line from the class. The same Idempotency-Key returns the same invoice. Audited as purchase_invoice.created. Schema: PurchaseInvoiceCreateBody → PurchaseInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'PurchaseInvoice' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-invoices/{id}': {
            get: {
                tags: ['Purchasing'],
                summary: 'Read a purchase invoice with its lines (any purchasing read key)',
                description: 'U02 (D54). Another shop\'s invoice, or one of a branch the caller doesn\'t work in, answers PURCHASE_INVOICE_NOT_FOUND. outstanding (approved only) = total − payments − credit returns; unit_ids are the serial units created by the approval. Schema: PurchaseInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseInvoice' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            put: {
                tags: ['Purchasing'],
                summary: 'Change a draft purchase invoice (purchase.invoice_create)',
                description: 'U02 (D54). Drafts only (else PURCHASE_INVOICE_NOT_EDITABLE): supplier_invoice_no, invoice_date and/or lines (all lines replaced, totals recomputed). The supplier and the branch are fixed. Audited as purchase_invoice.updated with what changed; no change, no row. Schema: PurchaseInvoiceUpdateBody → PurchaseInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseInvoice' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-invoices/{id}/approve': {
            post: {
                tags: ['Purchasing'],
                summary: 'Approve a purchase invoice (purchase.invoice_approve)',
                description: 'U02 (D54). Recomputes VAT with the current class rates, then per line in product order: updates the product\'s moving-average cost on the net unit cost (all branches, half-up to 4 places; no stock → the unit cost) and posts the stock (purchase_in) once; serialized lines create their units. The supplier balance rises by the total including VAT. Already approved: answered unchanged. Errors: SERIALS_REQUIRED (422, details.line_ids), SERIAL_TAKEN (details.serials), SUPPLIER_ARCHIVED, PURCHASE_INVOICE_NOT_EDITABLE (rejected), BRANCH_DENIED / BRANCH_INACTIVE. Audited as purchase_invoice.approved with the costs before and after.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseInvoice' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-invoices/{id}/reject': {
            post: {
                tags: ['Purchasing'],
                summary: 'Reject a draft purchase invoice (purchase.invoice_approve)',
                description: 'U02 (D54). reason 3-500 characters. A rejected invoice is final and frees its supplier invoice number. Approved or already rejected: PURCHASE_INVOICE_NOT_EDITABLE. Audited as purchase_invoice.rejected (warning) with the reason. Schema: PurchaseInvoiceRejectBody → PurchaseInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseInvoice' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/units': {
            get: {
                tags: ['Inventory'],
                summary: 'Search serial units (stock.view)',
                description: 'I04. Serial prefix search (upper-cased) in the caller\'s branches; optional status and branch. Schema: UnitSearchQuery -> UnitList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 64 } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['in_stock', 'reserved', 'in_transit', 'sold', 'returned', 'in_repair', 'written_off'] } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'UnitList' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Inventory'],
                summary: 'Register serials the shop holds (stock.adjust, serials module)',
                description: 'I04. Product (serialized), branch, unit cost, 1-500 serials (trimmed, upper-cased). A serial repeated or already in the shop: SERIAL_TAKEN with details.serials. Posted as opening stock (an import job). The same Idempotency-Key returns the same batch. Schema: UnitRegisterBody -> UnitRegistration.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'UnitRegistration' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/units/find': {
            get: {
                tags: ['Inventory'],
                summary: 'A unit by its exact serial, with its history (stock.view)',
                description: 'I04. As scanned (trimmed, upper-cased). The unit\'s current branch must be one of the caller\'s. Schema: UnitFindQuery -> UnitDetail.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'serial', in: 'query', required: true, schema: { type: 'string', maxLength: 64 } },
                ],
                responses: { 200: { description: 'UnitDetail' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/units/{id}': {
            get: {
                tags: ['Inventory'],
                summary: 'A unit with its history (stock.view)',
                description: 'I04. Every ledger row, oldest first, with the document number and the other party (customer, supplier, from -> to). Schema: UnitDetail.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'UnitDetail' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
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
