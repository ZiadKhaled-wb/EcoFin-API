// Q02: which errors reach the error tracker. Server errors (5xx) do, with the request id the
// client gets back; client errors (4xx) never do.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';

const capture = vi.hoisted(() => vi.fn());
vi.mock('../utils/monitoring', () => ({ captureServerError: capture }));

import { errorHandler } from './errorHandler';
import { requestId } from './requestId';
import { AppError } from '../utils/errors';

function app() {
  const a = express();
  a.use(requestId());
  a.post('/api/things/:id', () => {
    throw new Error('unexpected failure');
  });
  a.get('/server', () => {
    throw new AppError('Request failed.', 'INTERNAL');
  });
  a.get('/client', () => {
    throw new AppError('Not enough stock', 'OUT_OF_STOCK');
  });
  a.use(errorHandler);
  return a;
}

beforeEach(() => capture.mockReset());

describe('errorHandler -> error tracker', () => {
  it('an unhandled error is reported with the same request id the client receives', async () => {
    const res = await request(app()).post('/api/things/42').set('x-request-id', 'req-q02-0001');
    expect(res.status).toBe(500);
    expect(res.body.error.requestId).toBe('req-q02-0001');
    expect(capture).toHaveBeenCalledTimes(1);
    const [err, context] = capture.mock.calls[0] as [Error, Record<string, unknown>];
    expect(err.message).toBe('unexpected failure');
    expect(context).toMatchObject({
      requestId: 'req-q02-0001',
      method: 'POST',
      route: '/api/things/:id',
      path: '/api/things/42',
      code: 'INTERNAL',
    });
  });

  it('a 5xx AppError is reported', async () => {
    await request(app()).get('/server');
    expect(capture).toHaveBeenCalledWith(
      expect.any(AppError),
      expect.objectContaining({ code: 'INTERNAL' }),
    );
  });

  it('a 4xx is not reported', async () => {
    const res = await request(app()).get('/client');
    expect(res.status).toBe(409);
    expect(capture).not.toHaveBeenCalled();
  });
});
