import { describe, it, expect } from 'vitest';
import { loadEnv } from './env';

const valid = {
  SUPABASE_URL: 'https://abc.supabase.co',
  SUPABASE_ANON_KEY: 'anon-secret-value',
  SUPABASE_SERVICE_ROLE_KEY: 'service-secret-value',
  FRONTEND_URL: 'https://app.example.com',
};

describe('loadEnv', () => {
  it('parses a valid object and applies defaults', () => {
    const env = loadEnv(valid);
    expect(env.PORT).toBe(3001);
    expect(env.LOG_LEVEL).toBe('info');
    expect(env.TRUST_PROXY).toBe(1);
    expect(env.CORS_ALLOWED_ORIGINS).toEqual(['https://app.example.com']);
  });

  it('throws ONE error naming every missing required variable', () => {
    let message = '';
    try {
      loadEnv({});
    } catch (err) {
      message = (err as Error).message;
    }
    for (const name of [
      'SUPABASE_URL',
      'SUPABASE_ANON_KEY',
      'SUPABASE_SERVICE_ROLE_KEY',
      'FRONTEND_URL',
    ]) {
      expect(message).toContain(name);
    }
  });

  it('names a bad variable but never prints its value', () => {
    const secret = 'super-secret-not-a-url';
    let message = '';
    try {
      loadEnv({ ...valid, SUPABASE_URL: secret });
    } catch (err) {
      message = (err as Error).message;
    }
    expect(message).toContain('SUPABASE_URL (invalid)');
    expect(message).not.toContain(secret);
  });

  it('parses TRUST_PROXY as hops or false and rejects anything else', () => {
    expect(loadEnv({ ...valid, TRUST_PROXY: '2' }).TRUST_PROXY).toBe(2);
    expect(loadEnv({ ...valid, TRUST_PROXY: 'false' }).TRUST_PROXY).toBe(false);
    expect(() => loadEnv({ ...valid, TRUST_PROXY: 'true' })).toThrow(/TRUST_PROXY/);
  });

  it('parses a comma-separated CORS allow-list and rejects *', () => {
    const env = loadEnv({
      ...valid,
      CORS_ALLOWED_ORIGINS: 'https://a.example.com, https://b.example.com:8443/',
    });
    expect(env.CORS_ALLOWED_ORIGINS).toEqual([
      'https://a.example.com',
      'https://b.example.com:8443',
    ]);
    expect(() => loadEnv({ ...valid, CORS_ALLOWED_ORIGINS: '*' })).toThrow(/CORS_ALLOWED_ORIGINS/);
  });

  it('requires CORS_ALLOWED_ORIGINS in production and rejects a local Supabase there', () => {
    expect(() => loadEnv({ ...valid, NODE_ENV: 'production' })).toThrow(/CORS_ALLOWED_ORIGINS/);
    expect(() =>
      loadEnv({
        ...valid,
        NODE_ENV: 'production',
        CORS_ALLOWED_ORIGINS: 'https://app.example.com',
        SUPABASE_URL: 'http://127.0.0.1:54321',
      }),
    ).toThrow(/SUPABASE_URL/);
    expect(
      loadEnv({
        ...valid,
        NODE_ENV: 'production',
        CORS_ALLOWED_ORIGINS: 'https://app.example.com',
      }).NODE_ENV,
    ).toBe('production');
  });
});
