import { describe, it, expect } from 'vitest';
import { createLogger } from './logger';

function capture() {
  const lines: string[] = [];
  const logger = createLogger({
    level: 'info',
    stream: {
      write: (line: string) => {
        lines.push(line);
      },
    },
  });
  return { logger, output: () => lines.join('') };
}

describe('logger redaction', () => {
  it('redacts credentials, tokens, authorization and national ids', () => {
    const { logger, output } = capture();
    logger.info(
      {
        password: 'pw-1',
        newPassword: 'pw-2',
        token: 'tok-1',
        accessToken: 'tok-2',
        refreshToken: 'tok-3',
        national_id: '29001011234567',
        nationalId: '29001011234568',
        apikey: 'key-1',
        authorization: 'Bearer tok-4',
        cookie: 'sid=abc',
      },
      'top level',
    );
    const text = output();
    for (const secret of [
      'pw-1',
      'pw-2',
      'tok-1',
      'tok-2',
      'tok-3',
      '2900101123456',
      'key-1',
      'tok-4',
      'sid=abc',
    ]) {
      expect(text).not.toContain(secret);
    }
    expect(text).toContain('[Redacted]');
  });

  it('redacts nested request headers and body, and a national id one level down', () => {
    const { logger, output } = capture();
    logger.info(
      {
        req: {
          headers: {
            authorization: 'Bearer tok-5',
            cookie: 'sid=def',
            'x-api-key': 'key-2',
            accept: 'json',
          },
          body: {
            password: 'pw-3',
            refreshToken: 'tok-6',
            customer: { national_id: '29001011234569' },
          },
        },
        customer: { national_id: '29001011234570', name: 'visible-name' },
      },
      'nested',
    );
    const parsed = JSON.parse(output()) as {
      req: {
        headers: Record<string, string>;
        body: { password: string; refreshToken: string; customer: { national_id: string } };
      };
      customer: { national_id: string; name: string };
    };
    expect(parsed.req.headers['authorization']).toBe('[Redacted]');
    expect(parsed.req.headers['cookie']).toBe('[Redacted]');
    expect(parsed.req.headers['x-api-key']).toBe('[Redacted]');
    expect(parsed.req.body.password).toBe('[Redacted]');
    expect(parsed.req.body.refreshToken).toBe('[Redacted]');
    expect(parsed.req.body.customer.national_id).toBe('[Redacted]');
    expect(parsed.customer.national_id).toBe('[Redacted]');
    expect(parsed.customer.name).toBe('visible-name');
    expect(parsed.req.headers['accept']).toBe('json');
  });
});
