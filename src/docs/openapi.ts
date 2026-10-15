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
        { name: 'Devices', description: 'POS devices and pairing a computer with one (O03)' },
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
        '/api/customers': {
            get: {
                tags: ['Customers'],
                summary: 'List customers (any customer read key)',
                description: 'R01 (D63). Readable with any of customer.create, customer.edit, customer.view_pii, credit.approve, guarantor.manage, sale.create, quotation.manage, order.manage, installment.create, collection.create, survey.assign, survey.submit, survey.decide, legal.view, report.financial; needs the plan module customers (MODULE_NOT_IN_PLAN); works in an expired shop. PII: national_id is the full number only with customer.view_pii, otherwise null next to national_id_masked (ten stars and the last four digits). search matches the name (contains; letter case and Arabic letter forms ignored), a phone (contains, 3+ digits, however it is written) or the national ID: all 14 digits for everyone, a prefix of 4+ digits only with customer.view_pii. status: all (default) | active | watch | blocked. Ordered by name. Schema: CustomerListQuery → CustomerList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 100 } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['all', 'active', 'watch', 'blocked'], default: 'all' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'CustomerList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Customers'],
                summary: 'Create a customer (customer.create)',
                description: 'R01 (D63). full_name 2-150 (trimmed, inner spaces joined); phones 1-5, stored normalised (ASCII digits; an Egyptian mobile as 01XXXXXXXXX), no repeats; national_id optional: 14 digits that parse (century digit 2 or 3, a real birth date not in the future, a known governorate code; the check digit is not verified) and unique per shop: CUSTOMER_NATIONAL_ID_TAKEN (409, details customer_id and full_name of the customer who has it). The birth date, gender and governorate are never sent: the server reads them from the ID (`birth_date`, `gender` and `governorate_code` in the answer; null without an ID) and a body that contains birth_date or gender is refused. Also address, city, job, employer, monthly_income (decimal string), is_business with tax_registration_no, notes. The answer is masked like every read. Audited as customer.created (the ID never reaches the audit log, only its mask). Schema: CustomerCreateBody → Customer.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'Customer' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}': {
            get: {
                tags: ['Customers'],
                summary: 'Read a customer (any customer read key)',
                description: 'R01 (D63). national_id only with customer.view_pii; national_id_masked and id_photos_count for everyone (the photos themselves: GET /api/files with entityType customer, which needs customer.view_pii). Another shop answers CUSTOMER_NOT_FOUND. Schema: Customer.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Customer' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            patch: {
                tags: ['Customers'],
                summary: 'Update a customer (customer.edit)',
                description: 'R01 (D63). Any create field, at least one; null clears an optional field. Sending national_id for a customer who already has one also needs customer.view_pii, whatever the value (PERMISSION_DENIED); filling an empty ID needs customer.edit only. Audited as customer.updated with the changed keys only (an ID change shows as its masks plus national_id_changed, severity warning when an existing ID is replaced or removed); no change, no audit row. Schema: CustomerUpdateBody → Customer.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Customer' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/status': {
            post: {
                tags: ['Customers'],
                summary: 'Block or unblock a customer (customer.edit)',
                description: 'R01 (D63). status: blocked (reason 3-300 characters required) or active. A blocked customer can not buy on installments. watch is set by the system only and can be cleared to active here. The same status again changes nothing. Audited as customer.status_set with the reason (warning when blocking). Schema: CustomerStatusBody → Customer.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Customer' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/guarantors': {
            get: {
                tags: ['Guarantors'],
                summary: 'List guarantors (any customer read key)',
                description: 'R04 (D71). Readable with the customer read keys of D63 (customer.create, customer.edit, customer.view_pii, credit.approve, guarantor.manage, sale.create, ...); needs the plan module customers; works in an expired shop. PII like customers: national_id (and the birth_date and gender read from it) only with customer.view_pii, otherwise null next to national_id_masked. search matches the name, a phone, or the national ID (all 14 digits for everyone, a prefix of 4+ digits only with customer.view_pii). status: active (default) | archived | all. Ordered by name. Schema: GuarantorListQuery → GuarantorList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 100 } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['active', 'archived', 'all'], default: 'active' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'GuarantorList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Guarantors'],
                summary: 'Create a guarantor (guarantor.manage or customer.create)',
                description: 'R04 (D71). full_name 2-150, phone (one number, stored like customer phones), national_id (required: 14 digits that parse, Arabic digits accepted, birth date not in the future) are required; address up to 300, job up to 100, monthly_income (decimal string, 0 or more) are optional. The national ID is unique per shop: GUARANTOR_NATIONAL_ID_TAKEN (409, details guarantor_id and full_name of the guarantor who has it, so the screen can offer to link the existing one). With link {customer_id, relation} the guarantor is created and linked to that customer in one transaction (nothing is created when the link fails). Authorised in the database: either key works, anyone else gets PERMISSION_DENIED. The answer is masked like every read. Audited as guarantor.created (+ customer.guarantor_linked); the ID never reaches the audit log, only its mask. Schema: GuarantorCreateBody → Guarantor.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'Guarantor' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/guarantors/{id}': {
            get: {
                tags: ['Guarantors'],
                summary: 'Read a guarantor with their customers and contracts (any customer read key)',
                description: 'R04 (D71). Archived guarantors stay readable. customers: who they back and with which relation; contracts: the installment contracts they are on (empty until the installment sale exists). national_id only with customer.view_pii; id_photos_count for everyone (the photos: GET /api/files with entityType guarantor, which needs customer.view_pii). Another shop answers GUARANTOR_NOT_FOUND. Schema: GuarantorDetails.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'GuarantorDetails' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            patch: {
                tags: ['Guarantors'],
                summary: 'Update a guarantor (guarantor.manage)',
                description: 'R04 (D71). Any create field except link, at least one; an empty string (or null for the income) clears an optional field; phone, national_id and full_name can not be cleared. Sending national_id also needs customer.view_pii, whatever the value (PERMISSION_DENIED); a duplicate is GUARANTOR_NATIONAL_ID_TAKEN. Audited as guarantor.updated with the changed keys only (an ID change shows as its masks plus national_id_changed, severity warning); no change, no audit row. Schema: GuarantorUpdateBody → Guarantor.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Guarantor' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/guarantors/{id}/archive': {
            post: {
                tags: ['Guarantors'],
                summary: 'Archive a guarantor (guarantor.manage)',
                description: 'R04 (D71). Refused while the guarantor is on an active contract (GUARANTOR_ON_ACTIVE_CONTRACT). An archived guarantor stays readable and keeps its links and contract history but can not be linked or attached anew (GUARANTOR_ARCHIVED). The same state again changes nothing and writes no audit row. Audited as guarantor.archived (warning). Schema: Guarantor.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Guarantor' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/guarantors/{id}/restore': {
            post: {
                tags: ['Guarantors'],
                summary: 'Restore an archived guarantor (guarantor.manage)',
                description: 'R04 (D71). The same state again changes nothing and writes no audit row. Audited as guarantor.restored. Schema: Guarantor.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Guarantor' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/guarantors': {
            get: {
                tags: ['Guarantors'],
                summary: "A customer's guarantors (any customer read key)",
                description: 'R04 (D71). At most 5, oldest link first, no paging. Each carries its relation, when it was linked and on_active_contract (the guarantor is on an active contract of this customer, so it can not be unlinked). Editing a customer never changes this list. Another shop\'s customer answers CUSTOMER_NOT_FOUND. Schema: CustomerGuarantorList.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CustomerGuarantorList' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Guarantors'],
                summary: 'Link an existing guarantor to a customer (guarantor.manage or customer.create)',
                description: 'R04 (D71). One guarantor at a time with a relation (father, mother, brother, sister, spouse, son, daughter, relative, friend, colleague, employer, neighbour, other). At most 5 per customer (GUARANTOR_LIMIT_REACHED); the same pair again is GUARANTOR_ALREADY_LINKED; an archived guarantor is GUARANTOR_ARCHIVED; a blocked or archived customer is CUSTOMER_BLOCKED; a guarantor can not back themselves (GUARANTOR_IS_CUSTOMER). Authorised in the database: either key works. Audited as customer.guarantor_linked. Schema: CustomerGuarantorLinkBody → CustomerGuarantorList.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 201: { description: 'CustomerGuarantorList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/guarantors/{guarantorId}': {
            patch: {
                tags: ['Guarantors'],
                summary: 'Change the relation of a link (guarantor.manage)',
                description: 'R04 (D71). The same relation again changes nothing and writes no audit row. GUARANTOR_NOT_LINKED when the pair is not linked. Audited as customer.guarantor_relation_set (old and new relation). Schema: CustomerGuarantorRelationBody → CustomerGuarantorList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'guarantorId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'CustomerGuarantorList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/guarantors/{guarantorId}/unlink': {
            post: {
                tags: ['Guarantors'],
                summary: 'Unlink a guarantor from a customer (guarantor.manage)',
                description: 'R04 (D71). Refused while the guarantor is on an active contract of that customer (GUARANTOR_ON_ACTIVE_CONTRACT). The guarantor record stays. Audited as customer.guarantor_unlinked (warning, with the relation). There is no DELETE route in this API. Schema: CustomerGuarantorList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'guarantorId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'CustomerGuarantorList' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/guarantor-requirement': {
            get: {
                tags: ['Guarantors'],
                summary: 'Does the customer meet the policy for a financed amount? (any customer read key)',
                description: 'R04 (D71). Against the shop\'s current installment policy version: required_count is 0 when no guarantor is needed (guarantor_required_above empty, or the financed amount, cash price minus down payment, is not above it), else guarantors_required_count; linked_active_count counts the customer\'s linked guarantors that are not archived; met = linked_active_count >= required_count. The database also refuses a contract that needs guarantors and has fewer, at commit. Schema: GuarantorRequirementQuery → GuarantorRequirement.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'financed_amount', in: 'query', required: true, schema: { type: 'string', example: '15000.00' } },
                ],
                responses: { 200: { description: 'GuarantorRequirement' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/surveys': {
            get: {
                tags: ['Surveys'],
                summary: 'List field surveys (any customer read key; a collector sees only their own)',
                description: 'R05 (D75). Readable with the customer read keys of D63; needs the plan module customers; works in an expired shop. A caller with survey.submit but neither survey.assign nor survey.decide (the collector) gets only the surveys assigned to them; mine=true limits anyone to their own. Filters: status (assigned | submitted | approved | rejected | cancelled), customer_id, assigned_to. Newest first; without a status filter the submitted ones (the review queue) come first. Schema: SurveyListQuery → SurveyList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['assigned', 'submitted', 'approved', 'rejected', 'cancelled'] } },
                    { name: 'customer_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'assigned_to', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'mine', in: 'query', schema: { type: 'boolean', default: false } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'SurveyList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Surveys'],
                summary: 'Assign a field survey (survey.assign)',
                description: 'R05 (D75). customer_id and assigned_to are required; visit_type home (default) | work; due_date not before today; instructions up to 500. The customer must be active or on watch (CUSTOMER_BLOCKED for blocked or archived); the assignee must be an active employee of the shop who has survey.submit (SURVEY_ASSIGNEE_INVALID, details employee_id); one open survey (assigned or submitted) per customer (SURVEY_ALREADY_OPEN, details survey_id and status). Audited as survey.assigned. Schema: SurveyCreateBody → Survey.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'Survey' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/surveys/{id}': {
            get: {
                tags: ['Surveys'],
                summary: 'Read a field survey (any customer read key; a collector only their own)',
                description: 'R05 (D75). The customer (name, phones, address, city), the assignee, the answers (scores, checklist, notes, gps), gps_low_accuracy (accuracy above 100 m), survey_score, photos_count, the decision and valid_until (approved: 180 days after the decision). Photos: GET /api/files with entityType field_survey (needs customer.view_pii). Another shop, or another collector\'s survey, answers SURVEY_NOT_FOUND. Schema: Survey.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Survey' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            patch: {
                tags: ['Surveys'],
                summary: 'Save answers (survey.submit, the assignee)',
                description: 'R05 (D75). Status assigned; only the assignee (SURVEY_NOT_ASSIGNEE). Any of visit_type, scores (criteria 1-10), checklist (yes/no), notes (up to 2000), gps {lat, lng, gps_accuracy_m, client_captured_at} (all four, the capture time at most 5 minutes in the future); at least one key. Merged into what is saved; a criterion or item sent as null is removed, gps null clears the fix. The same values again change nothing and write no audit row. Audited as survey.saved with the changed keys (the GPS point itself is never in the audit log). Schema: SurveyAnswersBody → Survey.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Survey' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/surveys/{id}/reassign': {
            post: {
                tags: ['Surveys'],
                summary: 'Reassign a survey (survey.assign)',
                description: 'R05 (D75). Status assigned only (SURVEY_WRONG_STATUS); the same assignee rules as assigning. Saved answers and photos stay. The same assignee again changes nothing. Audited as survey.reassigned. Schema: SurveyReassignBody → Survey.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Survey' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/surveys/{id}/cancel': {
            post: {
                tags: ['Surveys'],
                summary: 'Cancel a survey (survey.assign)',
                description: 'R05 (D75). From assigned or submitted; a reason of 3-300 characters (kept in decision_note). Final. Audited as survey.cancelled (warning) with the reason. Schema: SurveyCancelBody → Survey.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Survey' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/surveys/{id}/submit': {
            post: {
                tags: ['Surveys'],
                summary: 'Submit a survey (survey.submit, the assignee)',
                description: 'R05 (D75). The same body as a save (may be empty), merged; then every criterion, every checklist item and the GPS fix are required (VALIDATION_FAILED) and at least one photo (SURVEY_PHOTO_REQUIRED; upload with POST /api/files, purpose survey_photo, entityType field_survey, at most 10, only the assignee while assigned). survey_score = round(average of the criteria x 10). Audited as survey.submitted. Schema: SurveySubmitBody → Survey.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Survey' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/surveys/{id}/decide': {
            post: {
                tags: ['Surveys'],
                summary: 'Approve or reject a survey (survey.decide)',
                description: 'R05 (D75). Status submitted only (SURVEY_WRONG_STATUS). decision approve | reject; a rejection needs a note of 3-500, an approval may have one. The assignee can not decide their own survey unless they are the OWNER (SURVEY_SELF_DECISION). Final. An approved survey counts for 180 days: it fills the residence part of the credit score and allows an installment contract above the policy\'s survey_required_above. Audited as survey.approved or survey.rejected (warning). Schema: SurveyDecisionBody → Survey.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Survey' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/surveys': {
            get: {
                tags: ['Surveys'],
                summary: "A customer's field surveys (any customer read key; a collector only their own)",
                description: 'R05 (D75). Newest first, at most 50, no paging. Another shop\'s customer answers CUSTOMER_NOT_FOUND. Schema: Survey[].',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Survey[]' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/survey-requirement': {
            get: {
                tags: ['Surveys'],
                summary: 'Does the customer need (and have) an approved survey for a financed amount? (any customer read key)',
                description: 'R05 (D75). Against the shop\'s current installment policy version: required when survey_required_above is set and the financed amount (cash price minus down payment) is greater than it; valid_survey is the newest approved survey decided within 180 days; open_survey the one assigned or submitted; met = not required or a valid survey exists. The database also refuses such a contract without one, at commit (SURVEY_REQUIRED). Schema: SurveyRequirementQuery → SurveyRequirement.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'financed_amount', in: 'query', required: true, schema: { type: 'string', example: '25000.00' } },
                ],
                responses: { 200: { description: 'SurveyRequirement' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/account': {
            get: {
                tags: ['Customers'],
                summary: "A customer's account: balances, overdue, contracts, payments, returns (any customer read key)",
                description: 'R02 (D74). Read only; readable with the customer read keys of D63; needs the plan module customers; works in an expired shop. balance: open_balance = contract totals (current schedule lines + what was paid on superseded ones) - payments on their schedule lines - returns settled against the contract (refund_method contract_adjustment), over the active and rescheduled contracts; fees_due apart, total_due = open_balance + fees_due; store_credit, and credit_limit / available as R03 shows them. overdue: amount, lines, max days late, the earliest unpaid line (next_due_date, may be in the past) and the aging buckets. totals: purchases (sales not voided), returns (returns, voids and exchanges), cash and bank transfer payments in and out that were not reversed. contracts: every contract, newest first. recent_payments and recent_returns: the last 10, newest first. documents_count: files on the customer and on its contracts (the list itself: GET /api/files). Purchases: GET /api/sales with customer_id (sale.create or report.view); guarantors: GET /api/customers/{id}/guarantors. Another shop\'s customer answers CUSTOMER_NOT_FOUND. Schema: CustomerAccount.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CustomerAccount' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/contracts/{contractId}/schedule': {
            get: {
                tags: ['Customers'],
                summary: "One contract's schedule with line statuses and fees (any customer read key)",
                description: 'R02 (D74). The contract (as in the account) with its schedule lines: the current version first, then the superseded ones (status superseded); each line has paid, remaining, fees_due, status (upcoming, due, partly_paid, overdue, paid, closed) and days_late (0 unless overdue). charges: late fees with what was waived, paid and is still due. A contract that is not this customer\'s answers CONTRACT_NOT_FOUND; another shop\'s customer CUSTOMER_NOT_FOUND. Schema: CustomerContractSchedule.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'contractId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'CustomerContractSchedule' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/statement': {
            get: {
                tags: ['Customers'],
                summary: "A customer's statement with a running balance (any customer read key)",
                description: 'R02 (D74). Shop-wide, dates in the shop timezone; from and to are optional (at most three years apart; from after to or a longer range answers VALIDATION_FAILED). A balance above 0 means the customer owes the shop. Debits: sales (a void is its own return row), a contract\'s total above its financed amount (the markup, plus what a reschedule added; a contract without a sale: its whole total), refunds paid out, late fees, reversals of payments in. Credits: payments in, returns / voids / exchanges, fee waivers, reversals of refunds. Store-credit payments are not rows (the credit was counted when it was given). opening_balance = everything before from; without dates closing_balance = total_due - store_credit of the account. Schema: CustomerStatementQuery → CustomerStatement.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'from', in: 'query', required: false, schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', required: false, schema: { type: 'string', format: 'date' } },
                ],
                responses: { 200: { description: 'CustomerStatement' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/credit': {
            get: {
                tags: ['Credit'],
                summary: "A customer's credit profile (any customer read key)",
                description: 'R03 (D72). Readable with the customer read keys of D63; needs the plan module customers; works in an expired shop. credit_limit is the only limit the server uses; suggested_limit (monthly income x the shop multiple, rounded down to the pound, null when either is missing) is only a hint. exposure = the unpaid principal of the customer\'s active and rescheduled contracts; available = limit - exposure, never below 0, with the excess in over_limit_by. score is 0-100 from the shop weights (guarantors, income, residence, identity) with each component and its points; min_score is the shop minimum. behaviour: on-time share, days late and the overdue amount of the due schedule lines, and the contract counts (null/zero until installments exist). limit_history: the last 10 limit changes. Nothing is stored for the score. Another shop\'s customer answers CUSTOMER_NOT_FOUND. Schema: CreditProfile.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CreditProfile' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/credit-limit': {
            put: {
                tags: ['Credit'],
                summary: "Set a customer's credit limit (credit.approve)",
                description: 'R03 (D72). credit_limit from 0 to 99 999 999.99 (a decimal string); a reason of 3-300 characters is required when the limit goes up (CREDIT_REASON_REQUIRED), optional when it goes down. A limit below the current exposure is allowed (the customer just can not take more). The same value again changes nothing and writes no audit row. Archived customers are refused (CUSTOMER_BLOCKED). Audited as customer.credit_limit_set (before, after, reason; a warning when it goes up). Needs the plan module customers. Schema: CreditLimitBody → CreditProfile.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CreditProfile' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/credit-check': {
            get: {
                tags: ['Credit'],
                summary: 'Would an installment sale of this financed amount pass? (any customer read key)',
                description: 'R03 (D72). financed_amount = cash price - down payment. Answers instead of raising for the credit reasons: allowed, reasons (limit: above the available credit; score: below the shop minimum; watch: the customer is on watch), needs_approval, the numbers, pending_approval_id (the newest pending request covering the amount) and approved_approval_id (the newest approved, unused, unexpired exception covering it). A customer who is not found (CUSTOMER_NOT_FOUND) or is blocked or archived (CUSTOMER_BLOCKED, never overridable) is an error. The decision itself is made in the database when the contract is created (N02) and again at commit. Schema: CreditCheckQuery → CreditCheck.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'financed_amount', in: 'query', required: true, schema: { type: 'string', example: '8000.00' } },
                ],
                responses: { 200: { description: 'CreditCheck' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/customers/{id}/credit-exceptions': {
            post: {
                tags: ['Credit'],
                summary: 'Ask for a credit exception (sale.create or credit.approve)',
                description: 'R03 (D72). An approval on the spot, like the S03 discount approvals: the cashier asks for an exception for this customer and financed amount with a reason (3-300, CREDIT_REASON_REQUIRED); the server stores what it knew (limit, exposure, available, score, reasons). APPROVAL_NOT_NEEDED when the sale would pass anyway; CUSTOMER_BLOCKED for a blocked or archived customer. Authorised in the database: either key works. Audited as credit_exception.requested. Schema: CreditExceptionRequestBody → CreditException.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 201: { description: 'CreditException' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/credit-exceptions': {
            get: {
                tags: ['Credit'],
                summary: 'List credit exceptions (any customer read key)',
                description: 'R03 (D72). status: pending (default) | approved | rejected | cancelled | all. Pending first, then newest, at most 100. mine marks the caller\'s own requests (only they can cancel). Works in an expired shop. Schema: CreditExceptionListQuery → CreditExceptionList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['pending', 'approved', 'rejected', 'cancelled', 'all'], default: 'pending' } },
                ],
                responses: { 200: { description: 'CreditExceptionList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/credit-exceptions/{id}': {
            get: {
                tags: ['Credit'],
                summary: 'Read a credit exception (any customer read key)',
                description: 'R03 (D72). approved: valid for 24 hours after the decision (expires_at) and for one contract (used). Another shop\'s id, or an approval of another kind, answers APPROVAL_NOT_FOUND. Schema: CreditException.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CreditException' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/credit-exceptions/{id}/decide': {
            post: {
                tags: ['Credit'],
                summary: 'Approve or reject a credit exception (credit.approve)',
                description: 'R03 (D72). Rejecting needs a note (APPROVAL_NOTE_REQUIRED). The requester can not decide their own request (APPROVAL_SELF), except the shop OWNER (to confirm with the owner). Only a pending request can be decided (APPROVAL_NOT_PENDING); approving a customer who was blocked or archived meanwhile is CUSTOMER_BLOCKED. Audited as credit_exception.approved (warning) or credit_exception.rejected. Schema: CreditExceptionDecideBody → CreditException.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CreditException' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/credit-exceptions/{id}/cancel': {
            post: {
                tags: ['Credit'],
                summary: 'Cancel your own pending credit exception (sale.create or credit.approve)',
                description: 'R03 (D72). Only the requester, while the request is pending (someone else\'s request answers APPROVAL_NOT_FOUND; a decided one APPROVAL_NOT_PENDING). Authorised in the database: either key works. Audited as credit_exception.cancelled. Schema: CreditException.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CreditException' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
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
                description: 'U02 (D54). Supplier (active), branch (the caller\'s), optional supplier invoice number (unique per supplier among non-rejected invoices: SUPPLIER_INVOICE_NO_TAKEN), invoice date (not in the future), 1-200 lines with each product once: quantity 1-100 000, unit_cost BEFORE VAT, tax_class_id (default the product\'s), serials for serialized products (optional on a draft; one per unit; needs the serials module). VAT per line from the class. U05: optional po_id (a sent or partly received order with the same supplier and branch, else PO_NOT_SENT / PO_CLOSED / PO_LINE_MISMATCH) and per line po_line_id (that order line, the same product, within what is still to come: PO_OVER_RECEIPT). The same Idempotency-Key returns the same invoice. Audited as purchase_invoice.created. Schema: PurchaseInvoiceCreateBody → PurchaseInvoice.',
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
                summary: 'Approve a purchase invoice (purchase.invoice_approve; above the threshold, the owner)',
                description: 'U02 (D54) + U06 (D55). Recomputes VAT with the current class rates, then per line in product order: updates the moving-average cost of the product on the net unit cost (all branches, half-up to 4 places; no stock → the unit cost) and posts the stock (purchase_in) once; serialized lines create their units. The supplier balance rises by the total including VAT. U06: when purchase_approval_threshold (shop settings) is set and the total (VAT included) is strictly greater, an approve of a draft by a non-owner answers status pending_approval with its approval (nothing posted, audited as purchase_invoice.approval_requested); only the owner decides a pending invoice, with a note (3-500; APPROVAL_NOTE_REQUIRED), and a non-owner gets APPROVAL_OWNER_ONLY. The owner approving a draft above the threshold posts it directly. U05: for an invoice of a purchase order the linked lines are checked again against what is still to come (PO_OVER_RECEIPT; a cancelled order: PO_CLOSED) and the order then moves to partially_received or received. Already approved: answered unchanged. Errors: SERIALS_REQUIRED (422, details.line_ids), SERIAL_TAKEN (details.serials), SUPPLIER_ARCHIVED, PURCHASE_INVOICE_NOT_EDITABLE (rejected), BRANCH_DENIED / BRANCH_INACTIVE. Schema: PurchaseInvoiceApproveBody → PurchaseInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseInvoice' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-invoices/{id}/reject': {
            post: {
                tags: ['Purchasing'],
                summary: 'Reject a draft purchase invoice (purchase.invoice_approve)',
                description: 'U02 (D54) + U06 (D55). reason 3-500 characters. A pending invoice (waiting for the owner) is rejected by the owner only (APPROVAL_OWNER_ONLY); its approval closes with the reason. A rejected invoice is final and frees its supplier invoice number. Approved or already rejected: PURCHASE_INVOICE_NOT_EDITABLE. Audited as purchase_invoice.rejected (warning) with the reason. Schema: PurchaseInvoiceRejectBody → PurchaseInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseInvoice' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-approvals': {
            get: {
                tags: ['Purchasing'],
                summary: 'Purchase invoices waiting for the owner, and decided ones (purchase.invoice_approve)',
                description: 'U06 (D55). Approvals in the branches of the caller (OWNER: all), newest first, each with its invoice summary. status: pending (default) | approved | rejected | cancelled; branch_id optional (BRANCH_DENIED / BRANCH_NOT_FOUND). Only the owner decides (POST /api/purchase-invoices/{id}/approve or /reject). Works in an expired shop. Schema: PurchaseApprovalListQuery → PurchaseApprovalList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['pending', 'approved', 'rejected', 'cancelled'], default: 'pending' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'PurchaseApprovalList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-invoices/{id}/returnable': {
            get: {
                tags: ['Purchasing'],
                summary: 'What can still go back to the supplier from an invoice (purchase.return_create)',
                description: 'U04 (D57). Per invoice line: purchased, returned, returnable (purchased minus every earlier return), the net unit cost and, for serialized products, the units of that line still in stock in the branch of the invoice. Another shop, or a branch the caller does not work in: PURCHASE_INVOICE_NOT_FOUND. Schema: ReturnableInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'ReturnableInvoice' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-returns': {
            get: {
                tags: ['Purchasing'],
                summary: 'List purchase returns of the branches of the caller (any purchasing read key)',
                description: 'U04 (D57). Newest business date first. Filters: supplier_id, branch_id, purchase_invoice_id, from/to (business date). Another shop answers SUPPLIER_NOT_FOUND / PURCHASE_INVOICE_NOT_FOUND / BRANCH_NOT_FOUND; a branch the caller does not work in BRANCH_DENIED. Works in an expired shop. Schema: PurchaseReturnListQuery → PurchaseReturnList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'supplier_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'purchase_invoice_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'PurchaseReturnList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Purchasing'],
                summary: 'Return goods to a supplier (purchase.return_create)',
                description: 'U04 (D57). Against an approved invoice (else PURCHASE_INVOICE_NOT_APPROVED), from its branch. Lines: each invoice line once, with quantity (normal products) or unit_ids (serialized: units that line created, in stock in that branch; else UNIT_NOT_AVAILABLE / UNIT_NOT_FOUND). Never more than bought minus returned: RETURN_QTY_EXCEEDED (409, details invoice_line_id and returnable). Stock leaves once at the net unit cost of the invoice (OUT_OF_STOCK when the goods are not in the branch); tax and gross per line follow D41, so the returns of a line add back to it exactly. The moving-average cost is recomputed: (Q×A − r×c) / (Q − r), half-up to 4 places, never below 0; nothing left keeps the average. refund_mode supplier_credit lowers the supplier balance (it may go negative); cash puts +total into cash_account_id, an active safe or bank of the branch or a shop-wide bank (VAULT_INVALID / CASH_ACCOUNT_INACTIVE), and leaves the balance alone. reason 3-500. Numbered PR. The same Idempotency-Key returns the first return. Audited as purchase_return.posted. Schema: PurchaseReturnCreateBody → PurchaseReturn.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'PurchaseReturn' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-returns/{id}': {
            get: {
                tags: ['Purchasing'],
                summary: 'Read a purchase return with its lines (any purchasing read key)',
                description: 'U04 (D57). Another shop, or a branch the caller does not work in: PURCHASE_RETURN_NOT_FOUND. Serialized lines come one per unit with the serial. Schema: PurchaseReturn.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseReturn' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchasing/cash-accounts': {
            get: {
                tags: ['Purchasing'],
                summary: 'Safes and banks money can move through for a branch (purchase.return_create or supplier.payment_create)',
                description: 'U04 (D57), also used by supplier payments. The active safes and banks of the branch plus shop-wide banks, with balances. The caller needs the branch (BRANCH_DENIED / BRANCH_NOT_FOUND). Schema: PayableCashAccountQuery → PayableCashAccountList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'PayableCashAccountList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-orders': {
            get: {
                tags: ['Purchasing'],
                summary: 'List purchase orders of the branches of the caller (any purchasing read key)',
                description: 'U05 (D59). Newest first, each with its number of lines and the units ordered and received. Filters: supplier_id, branch_id, status (draft | sent | partially_received | received | cancelled), search (part of the PO number). Another shop answers SUPPLIER_NOT_FOUND / BRANCH_NOT_FOUND; a branch the caller does not work in BRANCH_DENIED. Works in an expired shop. Schema: PurchaseOrderListQuery → PurchaseOrderList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'supplier_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['draft', 'sent', 'partially_received', 'received', 'cancelled'] } },
                    { name: 'search', in: 'query', schema: { type: 'string', maxLength: 40 } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'PurchaseOrderList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Purchasing'],
                summary: 'Create a draft purchase order (purchase.order_manage)',
                description: 'U05 (D59). Supplier (active), branch (of the caller), optional expected_date and notes (up to 1000 characters), 1-200 lines with each product once: quantity 1-100 000, optional expected_unit_cost before VAT, optional sales_order_line_id (a special order line of a customer: to_order, the same product, its order open, not yet linked; else SALES_ORDER_LINE_INVALID). Numbered PO. The same Idempotency-Key returns the same order. Audited as purchase_order.created. Schema: PurchaseOrderCreateBody → PurchaseOrder.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'PurchaseOrder' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-orders/{id}': {
            get: {
                tags: ['Purchasing'],
                summary: 'Read a purchase order with its lines and invoices (any purchasing read key)',
                description: 'U05 (D59). Per line: quantity, received (approved invoices only), remaining, on_draft_invoices (not received yet) and the customer order it fills, if any. invoices: every invoice made from the order. Another shop, or a branch the caller does not work in: PURCHASE_ORDER_NOT_FOUND. Schema: PurchaseOrder.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseOrder' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            put: {
                tags: ['Purchasing'],
                summary: 'Change a draft purchase order (purchase.order_manage)',
                description: 'U05 (D59). Drafts only (else PURCHASE_ORDER_NOT_EDITABLE): expected_date, notes and/or lines (all lines replaced). The supplier and the branch are fixed. Audited as purchase_order.updated with what changed; no change, no row. Schema: PurchaseOrderUpdateBody → PurchaseOrder.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseOrder' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-orders/{id}/send': {
            post: {
                tags: ['Purchasing'],
                summary: 'Send a draft purchase order (purchase.order_manage)',
                description: 'U05 (D59). draft → sent; an order that is already sent or further is answered unchanged. A cancelled order: PURCHASE_ORDER_NOT_EDITABLE. Audited as purchase_order.sent. Schema: → PurchaseOrder.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseOrder' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-orders/{id}/cancel': {
            post: {
                tags: ['Purchasing'],
                summary: 'Cancel a purchase order (purchase.order_manage)',
                description: 'U05 (D59). From draft, sent or partially_received, with a reason of 3-500 characters; it closes what is still to come. received and cancelled are final (PURCHASE_ORDER_NOT_EDITABLE). Draft invoices of the order can no longer be approved (PO_CLOSED). Audited as purchase_order.cancelled (warning) with the reason. Schema: PurchaseOrderCancelBody → PurchaseOrder.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'PurchaseOrder' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/purchase-orders/{id}/invoice': {
            post: {
                tags: ['Purchasing'],
                summary: 'Receive a purchase order as a draft purchase invoice (purchase.invoice_create)',
                description: 'U05 (D59). Only a sent or partially_received order (draft: PO_NOT_SENT; received or cancelled: PO_CLOSED). lines: order lines once each with a quantity and an optional unit_cost (default: the expected cost, 0 when none); without lines, every line with something still to come, for what remains. Never more than is still to come: PO_OVER_RECEIPT (409, details po_line_id and remaining); a line of another order: PO_LINE_MISMATCH. The draft takes the supplier and branch of the order and the shop date; it is edited and approved as any purchase invoice, and only an approved invoice counts as received (the order then moves to partially_received or received). The same Idempotency-Key returns the same invoice. Audited as purchase_invoice.created with po_id. Schema: PurchaseOrderInvoiceBody → PurchaseInvoice.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'PurchaseInvoice' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expense-categories': {
            get: {
                tags: ['Cash'],
                summary: 'List expense categories (expense.create, cash.view or report.financial)',
                description: 'K03 (D61). By name. include_archived=true also lists the archived ones. Works in an expired shop. Schema: ExpenseCategoryListQuery → ExpenseCategoryList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'include_archived', in: 'query', schema: { type: 'boolean', default: false } },
                ],
                responses: { 200: { description: 'ExpenseCategoryList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Cash'],
                summary: 'Create an expense category (expense.create)',
                description: 'K03 (D61). name 1-80, unique in the shop: EXPENSE_CATEGORY_NAME_TAKEN. Audited as expense_category.created. Schema: ExpenseCategoryBody → ExpenseCategory.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'ExpenseCategory' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expense-categories/{id}': {
            patch: {
                tags: ['Cash'],
                summary: 'Rename an expense category (expense.create)',
                description: 'K03 (D61). EXPENSE_CATEGORY_NOT_FOUND, EXPENSE_CATEGORY_NAME_TAKEN. The same name changes nothing. Audited as expense_category.renamed. Schema: ExpenseCategoryBody → ExpenseCategory.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'ExpenseCategory' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expense-categories/{id}/archive': {
            post: {
                tags: ['Cash'],
                summary: 'Archive an expense category (expense.create)',
                description: 'K03 (D61). An archived category keeps its expenses and takes no new one (EXPENSE_CATEGORY_ARCHIVED). Audited as expense_category.archived. Schema: ExpenseCategory.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'ExpenseCategory' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expense-categories/{id}/restore': {
            post: {
                tags: ['Cash'],
                summary: 'Restore an archived expense category (expense.create)',
                description: 'K03 (D61). Audited as expense_category.restored. Schema: ExpenseCategory.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'ExpenseCategory' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expenses': {
            get: {
                tags: ['Cash'],
                summary: 'List expenses (expense.create, cash.view or report.financial)',
                description: 'K03 (D61). The branches of the caller, newest first. Filters: branch_id, category_id, from/to (business dates). A reversal is its own row; include_reversals=false leaves out reversals and reversed expenses. Works in an expired shop. Schema: ExpenseListQuery → ExpenseList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'category_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'include_reversals', in: 'query', schema: { type: 'boolean', default: true } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'ExpenseList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Cash'],
                summary: 'Record an expense (expense.create)',
                description: 'K03 (D61). The money leaves cash_account_id, an active safe or bank of branch_id or a shop-wide bank (VAULT_INVALID / CASH_ACCOUNT_INACTIVE), or with from_shift the drawer of the open shift of the caller (SHIFT_REQUIRED), so it is part of the expected cash of that shift: one of the two. A safe or a drawer can not go below 0 (INSUFFICIENT_FUNDS). The category must be active (EXPENSE_CATEGORY_NOT_FOUND / EXPENSE_CATEGORY_ARCHIVED). receipt_file_id is a file registered with the purpose expense_receipt (FILE_NOT_FOUND). Numbered EX. The same Idempotency-Key returns the same expense. Audited as expense.posted. Schema: ExpenseCreateBody → Expense.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'Expense' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expenses/report': {
            get: {
                tags: ['Cash'],
                summary: 'Expenses per category in a period (expense.create, cash.view or report.financial)',
                description: 'K03 (D61). from and to are business dates (at most a year apart); branch_id narrows to one branch of the caller. Reversals and reversed expenses are left out. Largest total first. Schema: ExpenseReportQuery → ExpenseReport.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'from', in: 'query', required: true, schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', required: true, schema: { type: 'string', format: 'date' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'ExpenseReport' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expenses/{id}': {
            get: {
                tags: ['Cash'],
                summary: 'Read an expense',
                description: 'K03 (D61). An expense of a branch the caller works in; others: EXPENSE_NOT_FOUND. Schema: Expense.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Expense' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/expenses/{id}/reverse': {
            post: {
                tags: ['Cash'],
                summary: 'Reverse an expense (owner only)',
                description: 'K03 (D61). An expense is never edited or deleted. The owner (APPROVAL_OWNER_ONLY) reverses it once (EXPENSE_ALREADY_REVERSED) with a reason (3-500): a linked EX row and the money back into the account it left. When the expense was paid from a shift that is closed by now, cash_account_id (a vault of the branch) is required: VAULT_INVALID. The same Idempotency-Key returns the same reversal; the key of another expense: IDEMPOTENCY_CONFLICT. Audited as expense.reversed (warning). Schema: ExpenseReverseBody → Expense (the reversal).',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 200: { description: 'Expense' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/installments/preview': {
            post: {
                tags: ['Installments'],
                summary: 'Preview the terms of an installment sale (installment.create)',
                description: 'N01 (D76). The terms under the shop\'s current installment policy version: financed amount (cash price - down payment), the profit for the whole term (markup_pct is the whole-term profit %, never a rate per period; docs/ISLAMIC_FINANCE_RULES.md), the installment price (total_payable) and the schedule lines, each split into principal and profit, adding up exactly. Broken policy rules come back in violations (frequency_not_allowed, sale_below_minimum, down_payment_too_high, down_payment_too_low, too_many_months, installment_below_minimum, rounding, first_due_date_out_of_range), not as an error. With customer_id the answer adds the R03 credit check, the R04 guarantor requirement (selected / selected_met for guarantor_ids) and the R05 survey requirement; can_confirm is true only with a customer and nothing failing. Needs the installments module and the shop\'s installments switch (INSTALLMENTS_DISABLED) and a policy (POLICY_NOT_SET). Nothing is written; works in an expired shop. Other codes: CUSTOMER_NOT_FOUND, CUSTOMER_BLOCKED, VALIDATION_FAILED. Schema: InstallmentPreviewBody → InstallmentPreview.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'InstallmentPreview' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/sales/quote': {
            post: {
                tags: ['Sales'],
                summary: 'Price a cart without selling it (sale.create)',
                description: 'S01 (D62). The cart is priced for the open shift of the caller (SHIFT_REQUIRED without one): list prices from the catalogue, or another unit_price when the caller holds price.override (PRICE_OVERRIDE_DENIED otherwise), taxed by the VAT engine with the VAT mode of the shop. Each line answers the stock available in the branch right now; more than is available is reported, not refused. Serialized products name their unit (UNIT_REQUIRED, UNIT_NOT_AVAILABLE). S02 (D64): with payments (1-5 lines: cash with an optional tendered, bank_transfer with an active bank and a reference, store_credit with a customer) the answer also has paid, remaining (total - paid) and change, and store_credit_balance (reported, not reserved). Nothing is written or reserved; works in an expired shop. Schema: SaleQuoteBody → SaleQuote.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'SaleQuote' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/sales': {
            post: {
                tags: ['Sales'],
                summary: 'Complete a sale, paid in one or more ways (sale.create)',
                description: 'S01 (D62). One database transaction in the open shift of the caller (SHIFT_REQUIRED; its branch is the branch of the sale and its drawer takes the cash). The server prices the cart again and compares with expected_total, the total the cashier confirmed: a different total answers PRICE_CHANGED (409, details expected_total and total) and nothing is sold. Stock is checked on locked rows: OUT_OF_STOCK (409, details product_id, requested, available). A serialized line sells its exact unit, which becomes sold (UNIT_NOT_AVAILABLE when it is not in stock in the branch). Then the sale gets its number (SL), its lines with the tax snapshot, one stock ledger row per line, one cash payment (PY) into the drawer of the shift and one audit row (sale.created; a warning when a price was overridden). The same Idempotency-Key returns the same sale and sells nothing again. S02 (D64): `payments` (1-5 lines; at most one cash, one store_credit, three bank_transfer) replace the single cash payment. The lines must add up to the total exactly (PAYMENT_TOTAL_MISMATCH, 400, details total and paid); each line is one payment with its allocation and posts to its ledger: cash into the drawer of the shift (an optional tendered gives the change; only the amount is posted), a bank transfer into an active bank of the branch or a shop-wide one with its reference (VAULT_INVALID, CASH_ACCOUNT_INACTIVE; no shift on the bank movement), store credit from the balance of the customer (INSUFFICIENT_STORE_CREDIT, 409, details balance; needs a customer). Without payments the whole total is paid in cash. The audit row sale.created lists the payment lines. Other codes: PRODUCT_NOT_FOUND, PRODUCT_ARCHIVED, CUSTOMER_NOT_FOUND, PRICE_OVERRIDE_DENIED, SHIFT_CLOSED, DAY_CLOSED. S03 (D65): lines may carry a discount and the sale a sale_discount (amount or percent), with discount_reason (3-200; DISCOUNT_REASON_REQUIRED). Line discounts first, then the sale discount is spread over the lines by their net (largest remainder, ties to the lower line); T01 taxes each line on its discounted amount; expected_total and the payments are for the discounted total. Every line\'s effective percent must be within the caller\'s cap (org settings discount_caps by role; OWNER none; a role not listed 0) or the caller needs discount.above_cap or discount_approval_id of an approved request: else DISCOUNT_ABOVE_CAP (403, details line_no, cap_pct, effective_pct); an approval that does not fit answers APPROVAL_INVALID (409); a discount above its base or below 0 DISCOUNT_INVALID. Schema: SaleCreateBody → Sale.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'Sale' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' }, 422: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/sales/payment-accounts': {
            get: {
                tags: ['Sales'],
                summary: 'The banks a transfer can go into (sale.create)',
                description: 'S02 (D64). The active banks of the branch of the open shift of the caller and the shop-wide ones, by name only (no balances). No open shift: an empty list. Schema: SalePaymentAccountList.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'SalePaymentAccountList' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/sales/discount-approvals': {
            post: {
                tags: ['Sales'],
                summary: 'Ask a manager to approve an over-cap discount (sale.create)',
                description: 'S03 (D65). The cashier sends the cart (branch_id, lines with their discounts, sale_discount, reason 3-200). The server prices it, finds the highest effective percent over the lines (a line\'s whole discount, its share of the sale discount included, over its gross) and stores the cart\'s fingerprint (SHA-256, computed by the server only; the client never sends one). APPROVAL_NOT_NEEDED (400) when no line is above the caller\'s cap or the caller has discount.above_cap. Audited as approval.requested. Schema: DiscountApprovalRequestBody → DiscountApprovalRequested.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'DiscountApprovalRequested' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/sales/discount-approvals/{id}': {
            get: {
                tags: ['Sales'],
                summary: 'Read an over-cap discount approval (the requester, or discount.above_cap)',
                description: 'S03 (D65). The requester\'s own approval, or any of a branch the caller can access with discount.above_cap; others: APPROVAL_NOT_FOUND. The cashier polls it until it is approved, then sends the sale with discount_approval_id. Schema: DiscountApproval.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'DiscountApproval' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/sales/discount-approvals/{id}/cancel': {
            post: {
                tags: ['Sales'],
                summary: 'Take back a pending over-cap request (the requester)',
                description: 'S03 (D65). Only the requester, only while pending (APPROVAL_NOT_PENDING otherwise; another caller: APPROVAL_NOT_FOUND). Audited as approval.cancelled. Schema: DiscountApprovalResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'DiscountApprovalResult' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/approvals': {
            get: {
                tags: ['Sales'],
                summary: 'Over-cap discount requests of the caller\'s branches (discount.above_cap)',
                description: 'S03 (D65). kind (only discount_above_cap) and status (pending by default; approved, rejected, cancelled), newest first, at most 100, only branches the caller can access. Purchase approvals are on /api/purchase-approvals. Schema: DiscountApprovalListQuery → DiscountApprovalList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'kind', in: 'query', schema: { type: 'string', enum: ['discount_above_cap'] } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['pending', 'approved', 'rejected', 'cancelled'] } },
                ],
                responses: { 200: { description: 'DiscountApprovalList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/approvals/{id}/decide': {
            post: {
                tags: ['Sales'],
                summary: 'Approve or reject an over-cap discount request (discount.above_cap)',
                description: 'S03 (D65). From the manager\'s own session: needs access to the request\'s branch (BRANCH_DENIED), and not the requester (APPROVAL_SELF, 403). Only a pending request (APPROVAL_NOT_PENDING, 409); another shop\'s: APPROVAL_NOT_FOUND. An approval is good for 15 minutes after it is decided, for the requester, the branch and the same cart, and for ONE sale (APPROVAL_INVALID otherwise). Audited as approval.decided. Schema: DiscountApprovalDecideBody → DiscountApprovalResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'DiscountApprovalResult' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/sales/{id}': {
            get: {
                tags: ['Sales'],
                summary: 'Read a sale with its lines and payments',
                description: 'S01 (D62). The own sales of the caller with sale.create; with report.view or cash.view any sale of a branch the caller works in. Others: SALE_NOT_FOUND. Costs are never part of the answer. T02 (D67): `eta` is the ETA receipt of the sale (status, uuid, qr_payload to print as a QR code, last_error_code), null without one; POST /api/sales answers it too, built within 2 seconds when it can be. Schema: Sale.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Sale' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/eta/settings': {
            get: {
                tags: ['ETA'],
                summary: 'Read the ETA connection of the shop (org.settings_manage)',
                description: 'T02 (D67). The environment (preprod or prod), the client id, the activity code and whether ETA is on. The client secret is never returned: has_client_secret says whether one is stored. Schema: EtaSettings.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'EtaSettings' }, 403: { $ref: '#/components/responses/Error' } },
            },
            put: {
                tags: ['ETA'],
                summary: 'Set the ETA connection of the shop (org.settings_manage)',
                description: 'T02 (D67). Replaces the settings. client_secret is write-only and goes to Supabase Vault; left out or null keeps the stored one. Turning ETA on needs the client id, a secret and the activity code (VALIDATION_FAILED). The environment cannot change while a receipt is pending or submitted (ETA_ENV_BUSY, 409). Needs the eta module (MODULE_NOT_IN_PLAN). One audit row eta.settings_updated, without the secret. Schema: EtaSettingsBody → EtaSettings.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'EtaSettings' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/eta/settings/test': {
            post: {
                tags: ['ETA'],
                summary: 'Test the ETA connection with one POS (org.settings_manage)',
                description: 'T02 (D67). Logs one of the POS devices of the caller in at the ETA of the environment of the shop, with the stored credentials. Answers ok true, or ok false with the error code of the ETA (for example invalid_presharedkey), incomplete_settings or unreachable. Never a secret or a token. Changes nothing. DEVICE_NOT_FOUND for a POS of another shop. Schema: EtaTestBody → EtaTestResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'EtaTestResult' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/eta/submissions/{id}/retry': {
            post: {
                tags: ['ETA'],
                summary: 'Put a failed or rejected receipt back in the queue (fiscal.retry)',
                description: 'T02 (D67). Only a failed (blocked) or rejected receipt (FISCAL_NOT_RETRYABLE, 409). A receipt without a UUID is built again; one with a UUID is sent again as it is. Refused when the receipt belongs to the other ETA environment (ETA_ENV_MISMATCH, 409). FISCAL_NOT_FOUND for another shop or a branch the caller does not work in. One audit row fiscal.retry_requested. Schema: FiscalRetryResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'FiscalRetryResult' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal': {
            get: {
                tags: ['ETA'],
                summary: 'List ETA receipts with their situation and deadline (fiscal.view)',
                description: 'T03 (EC-91). Filters branch_id, from, to (the sale date in the shop), situation (waiting, accepted, cancelled, blocked, send_failed, rejected or problem), q (sale number or UUID prefix), limit (up to 100), offset. Sorted overdue, due soon, problems, the rest; newest first inside each group. Only the caller branches. Schema: FiscalListQuery -> FiscalList.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'FiscalList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/summary': {
            get: {
                tags: ['ETA'],
                summary: 'Counts for the alert badge (fiscal.view)',
                description: 'T03. blocked, send_failed, rejected, due_soon, overdue and accepted_today for the caller branches. Schema: FiscalAlertSummary.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'FiscalAlertSummary' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/day-summary': {
            get: {
                tags: ['ETA'],
                summary: 'Receipts of one branch and business day, for the day close (fiscal.view)',
                description: 'T03. Counts per situation and all_accepted. BRANCH_DENIED for a branch the caller does not work in. Schema: FiscalDaySummaryQuery -> FiscalDaySummary.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'FiscalDaySummary' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/retry-many': {
            post: {
                tags: ['ETA'],
                summary: 'Retry up to 200 receipts (fiscal.retry)',
                description: 'T03. Blocked -> prepared again, send_failed -> retried, rejected -> a correction is queued. A receipt that is not eligible, not ready or not the caller shop is skipped with its reason. Schema: FiscalRetryManyBody -> FiscalRetryManyResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'FiscalRetryManyResult' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/{id}': {
            get: {
                tags: ['ETA'],
                summary: 'One receipt with its diagnosis and event timeline (fiscal.view)',
                description: 'T03. The diagnosis is computed from the data as it is now (NO_DEVICE, ITEM_CODE, SELLER_DATA, BUYER_ID, BUYER_MISSING, ETA_REJECTED with the parsed ETA error) and says whether the receipt action can run now. Never the payload or a national ID. FISCAL_NOT_FOUND for another shop or a branch the caller does not work in. Schema: FiscalDetails.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'FiscalDetails' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/{id}/retry': {
            post: {
                tags: ['ETA'],
                summary: 'Retry a blocked or send_failed receipt (fiscal.retry)',
                description: 'T03. The same function as POST /api/eta/submissions/{id}/retry. A rejected receipt is USE_CORRECTION (409). Schema: FiscalRetryResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'FiscalRetryResult' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/{id}/correct': {
            post: {
                tags: ['ETA'],
                summary: 'Correct and resend a rejected receipt (fiscal.retry)',
                description: 'T03. Queues the eta.correct job (202). The worker rebuilds the receipt from the unchanged sale and the current master data with a new UUID, the same previousUUID and referenceOldUUID = the rejected UUID; when nothing changed it stores nothing and the receipt shows CORRECTION_NOTHING_CHANGED. NOT_REJECTED, CORRECTION_QUEUED (409). Schema: FiscalQueued.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 202: { description: 'FiscalQueued' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/{id}/assign-device': {
            post: {
                tags: ['ETA'],
                summary: 'Give a receipt without a POS a POS of its branch (fiscal.retry)',
                description: 'T03. Only a BLOCKED:NO_DEVICE receipt (NOT_BLOCKED_NO_DEVICE, 409); the device must be active and in the same branch (DEVICE_INVALID_FOR_RECEIPT, 400). Only the fiscal row changes. Schema: FiscalAssignDeviceBody -> FiscalRetryResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'FiscalRetryResult' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/fiscal/{id}/check-now': {
            post: {
                tags: ['ETA'],
                summary: 'Poll a submitted receipt now (fiscal.retry)',
                description: 'T03. NOT_SUBMITTED (409) unless the receipt is submitted. Schema: FiscalQueued.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 202: { description: 'FiscalQueued' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices': {
            get: {
                tags: ['ETA'],
                summary: 'List the POS devices of the branches of the caller (device.manage or org.settings_manage)',
                description: 'T02 (D67). Each device with its branch and its ETA registration (serial, OS version, model framework, status). The pre-shared key is never returned: has_preshared_key says whether one is stored. O03 (D69): paired, paired_at and last_seen_at say whether a computer holds the token of the device and when it last sent a request; the token and the pairing code are never returned. Schema: DeviceList.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'DeviceList' }, 403: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Devices'],
                summary: 'Create a POS device (device.manage)',
                description: 'O03 (D69). A device of a branch the caller works in (BRANCH_NOT_FOUND / BRANCH_DENIED), named 1 to 50 characters, unique in its branch without regard to case (DEVICE_NAME_TAKEN, 409). One more than the plan allows: PLAN_LIMIT_REACHED (409, details). The new device is active and not paired. Audited as device.created. Schema: DeviceCreateBody → DeviceCreated (201).',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 201: { description: 'DeviceCreated' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices/current': {
            get: {
                tags: ['Devices'],
                summary: 'The POS device this computer is paired with (any signed-in employee)',
                description: 'O03 (D69). A paired computer sends its device token in the x-device-token header on every request. The API hashes it and resolves the device (same shop, device active, branch active); only then does the request carry a device (towards the database: the device id with the hash of the token, which the database checks again). A device id or token hash sent by the client (x-device-id, x-device-token-hash) is always dropped. No token: device is null. A token that resolves to nothing (unpaired, deactivated, another shop): 403 DEVICE_REVOKED on this and every other route, and the client forgets the token. Schema: CurrentDeviceResponse.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'x-device-token', in: 'header', schema: { type: 'string' } }],
                responses: { 200: { description: 'CurrentDeviceResponse' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices/pair': {
            post: {
                tags: ['Devices'],
                summary: 'Pair this computer with a POS device (shift.operate or device.manage)',
                description: 'O03 (D69). The employee types the code shown on the devices screen (8 characters; spaces, dashes and lower case are forgiven). A code that is wrong, expired (15 minutes), already used, of another shop, of a device that is not active or of a branch the caller does not work in: PAIRING_CODE_INVALID (400), always the same answer. On success the code is used up and the answer carries the device token once; only its SHA-256 is stored. Pairing a device again replaces its token: the computer paired before answers DEVICE_REVOKED. Five attempts a minute for each user (429). Audited as device.paired, without the code or the token. Schema: DevicePairBody → DevicePaired.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'DevicePaired' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 429: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices/{id}': {
            patch: {
                tags: ['Devices'],
                summary: 'Rename a POS device or move it to another branch (device.manage)',
                description: 'O03 (D69). name, branch_id or both. The name is unique in the branch (DEVICE_NAME_TAKEN, 409). A device with an open shift can not be moved (DEVICE_HAS_OPEN_SHIFT, 409). DEVICE_NOT_FOUND for another shop, BRANCH_NOT_FOUND for a branch that is not of the shop. Audited as device.updated. Schema: DeviceUpdateBody → Device.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Device' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices/{id}/active': {
            post: {
                tags: ['Devices'],
                summary: 'Turn a POS device off or on (device.manage)',
                description: 'O03 (D69). Turning a device off needs a reason (REASON_REQUIRED), is refused while it has an open shift (DEVICE_HAS_OPEN_SHIFT, 409) and unpairs it: its computer answers DEVICE_REVOKED from the next request. Turning it on again counts against the plan (PLAN_LIMIT_REACHED, 409) and leaves it unpaired. Audited as device.deactivated / device.reactivated. Schema: DeviceActiveBody → DeviceActiveResult.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'DeviceActiveResult' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices/{id}/pairing-code': {
            post: {
                tags: ['Devices'],
                summary: 'Make a pairing code for a POS device (device.manage)',
                description: 'O03 (D69). An 8-character code (letters and digits without 0, O, 1, I, L) that is good for 15 minutes and for one pairing. It is answered here once and never again: only its SHA-256 is stored, and it is not logged or audited. A new code replaces an unused older one. The device must be active (DEVICE_INVALID). Audited as device.pairing_code_created. Schema: DevicePairingCode.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'DevicePairingCode' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices/{id}/unpair': {
            post: {
                tags: ['Devices'],
                summary: 'Unpair a POS device (device.manage)',
                description: 'O03 (D69). The token of the device and any unused pairing code stop working: its computer answers DEVICE_REVOKED from the next request. A shift open on the device stays open; a manager closes it with force-close (cash.adjust). Audited as device.unpaired. Schema: DeviceUnpaired.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'DeviceUnpaired' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/devices/{id}/eta': {
            put: {
                tags: ['ETA'],
                summary: 'Set the ETA registration of a POS (device.manage)',
                description: 'T02 (D67). The serial, OS version and model framework the ETA knows the POS by, its pre-shared key (write-only, to Supabase Vault; left out or null keeps the stored one) and its status. Status active needs all four (VALIDATION_FAILED). A serial another device of the shop has: DEVICE_SERIAL_TAKEN (409). A new serial starts the receipt chain of the POS again. DEVICE_NOT_FOUND for another shop. One audit row device.eta_updated, without the key. Schema: DeviceEtaBody → Device.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Device' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/shifts': {
            get: {
                tags: ['Cash'],
                summary: 'List shifts (shift.operate: own shifts; cash.view: the branches of the caller)',
                description: 'K02 (D60). Newest first. S02 (D64): every shift carries sales_total and payment_totals (cash, bank_transfer, store_credit: the incoming payments of its sales). Filters: branch_id, employee_id, status (open | closed), from/to (the shop day the shift was opened on). Each shift carries its expected cash (open: the drawer ledger sum now; closed: the snapshot at closing), counted cash and difference. Works in an expired shop. Schema: ShiftListQuery → ShiftList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'employee_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['open', 'closed'] } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'ShiftList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Cash'],
                summary: 'Open a shift (shift.operate)',
                description: 'K02 (D60). The caller opens their own shift in a branch they work in, on the paired POS device the request comes from (O03, D69): without one DEVICE_REQUIRED (409); a device of another branch DEVICE_BRANCH_MISMATCH (409); a device_id in the body that is not that device DEVICE_MISMATCH (409). The shift keeps the device, and every sale of the shift carries it. opening_float is 0 or more; above 0 it leaves vault_id, an active safe of the branch (VAULT_INVALID / CASH_ACCOUNT_INACTIVE; a safe can not go below 0: INSUFFICIENT_FUNDS), as a cash transfer (CX) into the drawer of the shift. One open shift per cashier and per device: SHIFT_ALREADY_OPEN. Numbered SH. The same Idempotency-Key returns the same shift. Audited as shift.opened. Schema: ShiftOpenBody → Shift.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'Shift' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/shifts/current': {
            get: {
                tags: ['Cash'],
                summary: 'The open shift of the caller, or null (shift.operate or cash.view)',
                description: 'K02 (D60). The shift with its drawer movements and the cash it should hold now (float + every movement of the shift; never the whole safe). Schema: CurrentShift.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                responses: { 200: { description: 'CurrentShift' }, 403: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/shifts/vaults': {
            get: {
                tags: ['Cash'],
                summary: 'Safes of a branch a float comes from or cash goes to (shift.operate or cash.view)',
                description: 'K02 (D60). The active safes of the branch by name, without balances (a cashier does not see vault balances). The caller needs the branch (BRANCH_DENIED / BRANCH_NOT_FOUND). Schema: ShiftVaultQuery → ShiftVaultList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'branch_id', in: 'query', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'ShiftVaultList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/shifts/{id}': {
            get: {
                tags: ['Cash'],
                summary: 'Read a shift with its drawer movements',
                description: 'K02 (D60). The own shift of the caller, or with cash.view any shift of a branch the caller works in; others: SHIFT_NOT_FOUND. Schema: Shift.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Shift' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/shifts/{id}/cash': {
            post: {
                tags: ['Cash'],
                summary: 'Move cash between the drawer of a shift and a safe (shift.operate)',
                description: 'K02 (D60). direction in: from the safe into the drawer (change); out: from the drawer into the safe (a cash drop). amount above 0, vault_id an active safe of the branch, note 3-500. A cash transfer (CX); neither side can go below 0 (INSUFFICIENT_FUNDS). Only an open shift (SHIFT_CLOSED). The own shift of the caller, or with cash.transfer too any shift of a branch the caller works in. The same Idempotency-Key moves nothing again. Audited as shift.cash_moved. Schema: ShiftCashBody → Shift.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 200: { description: 'Shift' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/shifts/{id}/force-close': {
            post: {
                tags: ['Cash'],
                summary: 'Force-close a shift (cash.adjust)',
                description: 'EC-147. Body: counted_cash (nonnegative decimal string), reason (3–500 characters). Branch access is required. Device state is ignored; counted cash returns to the branch default safe. Uses the shared K02 close transaction, audited as shift.force_closed (warning). Repeating a closed shift changes nothing. Schema: ShiftForceCloseBody → Shift.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { '200': { description: 'Closed shift' }, '400': { description: 'Invalid count or missing reason' }, '403': { description: 'Permission or branch denied' }, '404': { description: 'Shift not found' } },
            },
        },
        '/api/shifts/{id}/close': {
            post: {
                tags: ['Cash'],
                summary: 'Close a shift: count the cash and return it to a safe (shift.operate)',
                description: 'K02 (D60). counts: how many of each note and coin (200, 100, 50, 20, 10, 5, 1, 0.5, 0.25). Expected cash is the drawer ledger sum of the shift; when counted differs, difference_reason (3-500) is required: SHIFT_DIFFERENCE_REASON_REQUIRED (400, details expected, counted, difference). The difference is booked as an adjustment on the drawer and the counted cash goes to vault_id (an active safe of the branch; needed when anything was counted), leaving the drawer at 0. The own shift of the caller, or with cash.transfer too any shift of a branch the caller works in. A closed shift is answered unchanged and takes no more cash movements. Audited as shift.closed (warning when there is a difference). Schema: ShiftCloseBody → Shift.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'Shift' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/supplier-payments': {
            get: {
                tags: ['Purchasing'],
                summary: 'List supplier payments of the branches of the caller (any purchasing read key)',
                description: 'U03 (D58). Newest business date first; reversals are their own rows. Filters: supplier_id, branch_id, from/to (business date), include_reversals (default true; false leaves only the payments that count: no reversals and no reversed payments). Another shop answers SUPPLIER_NOT_FOUND / BRANCH_NOT_FOUND; a branch the caller does not work in BRANCH_DENIED. Works in an expired shop. Schema: SupplierPaymentListQuery → SupplierPaymentList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'supplier_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'include_reversals', in: 'query', schema: { type: 'string', enum: ['true', 'false'], default: 'true' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'SupplierPaymentList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Purchasing'],
                summary: 'Pay a supplier from a safe or bank (supplier.payment_create)',
                description: 'U03 (D58). The money leaves cash_account_id, an active safe or bank of branch_id or a shop-wide bank (VAULT_INVALID / CASH_ACCOUNT_INACTIVE); the caller needs the branch. Every payment is fully allocated to approved invoices of the supplier in the branches of the caller: the given allocations (each invoice once, each at most what is owed on it, adding up to the amount; else ALLOCATION_INVALID), or oldest invoice first when none are given. Never more than what is owed: PAYMENT_EXCEEDS_OUTSTANDING (409, details purchase_invoice_id or null, and outstanding). A safe can not go below 0: INSUFFICIENT_FUNDS; a closed day: DAY_CLOSED. reference up to 100 characters. Numbered SP (the receipt number). The same Idempotency-Key returns the first payment and moves no money again. Audited as supplier_payment.posted. Schema: SupplierPaymentCreateBody → SupplierPayment.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 201: { description: 'SupplierPayment' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/supplier-payments/open-invoices': {
            get: {
                tags: ['Purchasing'],
                summary: 'What a supplier is still owed, invoice by invoice (supplier.payment_create)',
                description: 'U03 (D58). Approved invoices of the supplier with something still owed, in the branches of the caller, oldest first: total, paid, returned_credit, outstanding, and the due date (invoice date + the payment terms of the supplier) with an overdue flag, for display only. Schema: OpenSupplierInvoiceQuery → OpenSupplierInvoiceList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'supplier_id', in: 'query', required: true, schema: { type: 'string', format: 'uuid' } },
                ],
                responses: { 200: { description: 'OpenSupplierInvoiceList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/supplier-payments/{id}': {
            get: {
                tags: ['Purchasing'],
                summary: 'Read a supplier payment with its allocations (any purchasing read key)',
                description: 'U03 (D58). Another shop, or a branch the caller does not work in: SUPPLIER_PAYMENT_NOT_FOUND. reversed_by_payment_id is set on a reversed payment; a reversal has reverses_payment_id, its reason and no allocations. Schema: SupplierPayment.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'SupplierPayment' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/supplier-payments/{id}/reverse': {
            post: {
                tags: ['Purchasing'],
                summary: 'Reverse a supplier payment (the owner, supplier.payment_create)',
                description: 'U03 (D58). Only the owner (others: APPROVAL_OWNER_ONLY), with a reason of 3-500 characters. Creates a linked reversal with its own SP number and puts the amount back into the account; the invoice and supplier balances go back up. Once per payment (PAYMENT_ALREADY_REVERSED); a reversal can not be reversed. The same Idempotency-Key returns the same reversal; the key of another payment: IDEMPOTENCY_CONFLICT. Audited as supplier_payment.reversed (warning) with the reason. Schema: SupplierPaymentReverseBody → SupplierPayment (the reversal).',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                responses: { 200: { description: 'SupplierPayment' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-accounts': {
            get: {
                tags: ['Cash'],
                summary: 'Safes and bank accounts (cash.view)',
                description: 'K01 (D56). The safes and banks of the caller branches plus every shop-wide bank (OWNER: all); drawers and collector wallets are not listed. status: active (default) | inactive | all; branch_id and kind optional. Works in an expired shop. Schema: CashAccountListQuery → CashAccountList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'status', in: 'query', schema: { type: 'string', enum: ['active', 'inactive', 'all'], default: 'active' } },
                    { name: 'branch_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'kind', in: 'query', schema: { type: 'string', enum: ['safe', 'bank'] } },
                ],
                responses: { 200: { description: 'CashAccountList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Cash'],
                summary: 'Create a safe or bank account (cash.account_manage)',
                description: 'K01. A safe needs a branch; a bank may be shop-wide (branch_id null). Kind and branch are fixed. A taken name in the same branch (or among shop-wide banks): CASH_ACCOUNT_NAME_TAKEN. Schema: CashAccountCreateBody → CashAccount.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: { 201: { description: 'CashAccount' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-accounts/{id}': {
            get: {
                tags: ['Cash'],
                summary: 'One safe or bank account (cash.view)',
                description: 'K01. Another shop or branch account: CASH_ACCOUNT_NOT_FOUND. Schema: CashAccount.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CashAccount' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            patch: {
                tags: ['Cash'],
                summary: 'Rename an account (cash.account_manage)',
                description: 'K01. Only the name changes; the same name again changes nothing. Schema: CashAccountUpdateBody → CashAccount.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: { 200: { description: 'CashAccount' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-accounts/{id}/movements': {
            get: {
                tags: ['Cash'],
                summary: 'The ledger of an account with its running balance (cash.view)',
                description: 'K01. Newest first; balance_after runs over the whole ledger. from/to are business dates; opening_balance is the sum before from, closing_balance the sum up to to (with no dates: the account balance). Schema: CashLedgerQuery → CashLedger.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'CashLedger' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-accounts/{id}/deactivate': {
            post: {
                tags: ['Cash'],
                summary: 'Deactivate an account (cash.account_manage)',
                description: 'K01. Refused with a balance (CASH_ACCOUNT_HAS_BALANCE) or as a branch default vault (CASH_ACCOUNT_IS_DEFAULT). An inactive account stays readable but takes no money. Schema: CashAccount.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CashAccount' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-accounts/{id}/reactivate': {
            post: {
                tags: ['Cash'],
                summary: 'Reactivate an account (cash.account_manage)',
                description: 'K01. Schema: CashAccount.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CashAccount' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-accounts/{id}/opening': {
            post: {
                tags: ['Cash'],
                summary: 'Give an empty account its opening balance (cash.adjust)',
                description: 'K01. Once, on an active account with no movements (else CASH_ACCOUNT_HAS_MOVEMENTS / CASH_ACCOUNT_INACTIVE); posted through an opening_cash import job. The same Idempotency-Key changes nothing. Schema: CashOpeningBody → CashAccount.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: { 200: { description: 'CashAccount' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-transfers': {
            get: {
                tags: ['Cash'],
                summary: 'Transfers between safes and banks (cash.view)',
                description: 'K01. Transfers with at least one side the caller may see, newest first; account_id, from and to optional. Schema: CashTransferListQuery → CashTransferList.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'account_id', in: 'query', schema: { type: 'string', format: 'uuid' } },
                    { name: 'from', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'to', in: 'query', schema: { type: 'string', format: 'date' } },
                    { name: 'page', in: 'query', schema: { type: 'integer', minimum: 1, default: 1 } },
                    { name: 'pageSize', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
                ],
                responses: { 200: { description: 'CashTransferList' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
            },
            post: {
                tags: ['Cash'],
                summary: 'Move money between two accounts (cash.transfer)',
                description: 'K01. Out of one active safe or bank and into another of the shop in one transaction, numbered CX. The caller needs the source account branch (a shop-wide bank: anyone with cash.transfer). Errors: INSUFFICIENT_FUNDS, DAY_CLOSED, TRANSFER_SAME_ACCOUNT, CASH_ACCOUNT_INACTIVE, BRANCH_DENIED. The same Idempotency-Key returns the same transfer. Schema: CashTransferCreateBody → CashTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [
                    { $ref: '#/components/parameters/OrgId' },
                    { name: 'Idempotency-Key', in: 'header', required: true, schema: { type: 'string', minLength: 8, maxLength: 128 } },
                ],
                requestBody: { required: true, content: { 'application/json': { schema: { type: 'object' } } } },
                responses: { 201: { description: 'CashTransfer' }, 400: { $ref: '#/components/responses/Error' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' }, 409: { $ref: '#/components/responses/Error' } },
            },
        },
        '/api/cash-transfers/{id}': {
            get: {
                tags: ['Cash'],
                summary: 'One transfer (cash.view)',
                description: 'K01. A transfer with no side the caller may see: CASH_TRANSFER_NOT_FOUND. Schema: CashTransfer.',
                security: [{ bearerAuth: [] }],
                parameters: [{ $ref: '#/components/parameters/OrgId' }, { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }],
                responses: { 200: { description: 'CashTransfer' }, 403: { $ref: '#/components/responses/Error' }, 404: { $ref: '#/components/responses/Error' } },
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
