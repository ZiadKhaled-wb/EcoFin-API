// server/src/eta/runtime.ts
//
// T02 (D67). One ETA client, store and host map per process, shared by the routes and the jobs
// (the client's token cache is per process). Built on first use, so importing this never needs a
// valid environment.

import { getEnv } from '../utils/env';
import { logger } from '../utils/logger';
import { supabaseAdmin } from '../utils/supabase';
import { EtaClient } from './client';
import { etaHosts, type EtaHostMap } from './config';
import { supabaseEtaStore, type EtaStore } from './store';

export interface EtaRuntime {
  store: EtaStore;
  client: EtaClient;
  hosts: EtaHostMap;
}

let cached: EtaRuntime | undefined;

export function etaRuntime(): EtaRuntime {
  if (!cached) {
    const hosts = etaHosts(getEnv());
    cached = {
      store: supabaseEtaStore(supabaseAdmin),
      client: new EtaClient({ hosts, logger }),
      hosts,
    };
  }
  return cached;
}
