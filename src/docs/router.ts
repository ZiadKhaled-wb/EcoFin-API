// server/src/docs/router.ts
//
// Mounts Swagger UI at /docs. Dev-only by default; set ENABLE_API_DOCS=true
// to expose it in production (some teams do this behind basic auth for
// internal consumers — but never on the public internet without a gate).

import { Router } from 'express';
import swaggerUi from 'swagger-ui-express';
import { openApiSpec } from './openapi';
import { logger } from '../utils/logger';

const docsEnabled = process.env.NODE_ENV !== 'production' || process.env.ENABLE_API_DOCS === 'true';

export const docsRouter = Router();

if (docsEnabled) {
    docsRouter.use(
        '/',
        swaggerUi.serve,
        swaggerUi.setup(openApiSpec, {
            customSiteTitle: 'EcoFin Pro API',
            swaggerOptions: {
                // Keep the token between page reloads so you don't re-authorize
                // after every code change.
                persistAuthorization: true,
                // Sort operations by tag then path for stable reading order.
                operationsSorter: 'alpha',
                tagsSorter: 'alpha',
                // Don't expand every operation on first load — with 30+
                // endpoints this becomes unreadable.
                docExpansion: 'list',
                // Show the request duration so you can spot slow endpoints.
                displayRequestDuration: true,
            },
        }),
    );
    logger.info('API docs mounted at /docs');
} else {
    docsRouter.get('/', (_req, res) => {
        res.status(404).json({ error: 'المسار غير موجود', code: 'NOT_FOUND' });
    });
}