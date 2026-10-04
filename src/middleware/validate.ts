// server/src/middleware/validate.ts
//
// F05: every route declares what it accepts. validate({ body, query, params }) parses each part
// with its contract schema (strict, from @ziadkhaled-wb/contracts) and replaces it with the
// parsed value, so handlers only ever see whitelisted fields. A part without a schema must be
// empty: an unknown key anywhere is 400 VALIDATION_FAILED (the error handler maps the ZodError).
//
// Route params can't be checked by noClientOrg (they only exist once a route matched), so an
// org key in params (e.g. a route written as /:orgId/...) is refused here too.

import type { Request, Response, NextFunction, RequestHandler } from 'express';
import { z } from 'zod';
import { findOrgKey } from './noClientOrg';
import { BadRequest } from '../utils/errors';

/**
 * Anything with a zod-style parse(). The contracts package has its own zod copy (D24), so its
 * schemas are typed structurally rather than as this repo's ZodTypeAny.
 */
export interface Schema {
  parse(input: unknown): unknown;
}

export interface ValidateSchemas {
  body?: Schema;
  query?: Schema;
  params?: Schema;
}

/** The schema for a part the route doesn't take: nothing at all. */
const Nothing = z.object({}).strict();

export function validate(schemas: ValidateSchemas = {}): RequestHandler {
  return (req: Request, _res: Response, next: NextFunction) => {
    const orgKey = findOrgKey(req.params, 'params');
    if (orgKey) {
      throw BadRequest('The shop comes from the session, not the request.', 'VALIDATION_FAILED', {
        path: orgKey,
      });
    }
    // express.json() leaves {} when there is no JSON body.
    req.body = (schemas.body ?? Nothing).parse(req.body ?? {});
    req.query = (schemas.query ?? Nothing).parse(req.query) as Request['query'];
    req.params = (schemas.params ?? Nothing).parse(req.params) as Request['params'];
    next();
  };
}
