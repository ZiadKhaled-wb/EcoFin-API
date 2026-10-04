// src/test/supabase-mock.ts
//
// Chainable Supabase mock. Tests queue responses; every awaited terminal
// call pops one off the queue in order.
//
// Design notes:
//   * The mock throws if the queue is empty. Silent nulls hide bugs.
//   * `.from()`, `.select()`, `.eq()`, etc. all return the same object,
//     so any chain shape works without per-query setup.
//   * Awaited chains resolve via `then()`, matching PostgREST's thenable
//     return type.
//
// This is a unit-test tool, not an integration harness. It does not
// simulate RLS, JOIN semantics, or SQL constraints — those are tested
// against a real database (see "What's deferred" at the end).

import { vi, type Mock } from 'vitest';

export interface SupabaseResponse {
  data: unknown;
  error: unknown;
}

export interface SupabaseMock {
  queue: (...responses: SupabaseResponse[]) => SupabaseMock;
  reset: () => void;

  // Query builder — all chainable
  from: Mock;
  select: Mock;
  eq: Mock;
  gte: Mock;
  lte: Mock;
  neq: Mock;
  in: Mock;
  is: Mock;
  order: Mock;
  limit: Mock;
  range: Mock;
  update: Mock;
  insert: Mock;
  delete: Mock;
  upsert: Mock;
  maybeSingle: Mock;
  single: Mock;
  then: (resolve: (v: SupabaseResponse) => unknown) => Promise<unknown>;

  rpc: Mock;

  auth: {
    signInWithPassword: Mock;
    getUser: Mock;
    resetPasswordForEmail: Mock;
    admin: {
      getUserById: Mock;
      updateUserById: Mock;
      createUser: Mock;
      deleteUser: Mock;
    };
  };
}

const CHAINABLE = [
  'from',
  'select',
  'eq',
  'gte',
  'lte',
  'neq',
  'in',
  'is',
  'order',
  'limit',
  'range',
  'update',
  'insert',
  'delete',
  'upsert',
] as const;

export function createSupabaseMock(): SupabaseMock {
  const queue: SupabaseResponse[] = [];

  const pop = (): SupabaseResponse => {
    const next = queue.shift();
    if (next === undefined) {
      throw new Error(
        'supabase-mock: response queue is empty. ' +
          'Call mock.queue({ data, error }) before the query runs.',
      );
    }
    return next;
  };

  const mock: Partial<SupabaseMock> = {
    queue: (...responses) => {
      queue.push(...responses);
      return mock as SupabaseMock;
    },
    reset: () => {
      queue.length = 0;
    },
  };

  for (const name of CHAINABLE) {
    mock[name] = vi.fn(() => mock) as Mock;
  }

  mock.maybeSingle = vi.fn(() => Promise.resolve(pop()));
  mock.single = vi.fn(() => Promise.resolve(pop()));

  mock.then = (resolve) => Promise.resolve(pop()).then(resolve);

  mock.rpc = vi.fn(() => Promise.resolve(pop()));

  mock.auth = {
    signInWithPassword: vi.fn(() => Promise.resolve(pop())),
    getUser: vi.fn(() => Promise.resolve(pop())),
    resetPasswordForEmail: vi.fn(() => Promise.resolve(pop())),
    admin: {
      getUserById: vi.fn(() => Promise.resolve(pop())),
      updateUserById: vi.fn(() => Promise.resolve(pop())),
      createUser: vi.fn(() => Promise.resolve(pop())),
      deleteUser: vi.fn(() => Promise.resolve(pop())),
    },
  };

  return mock as SupabaseMock;
}
