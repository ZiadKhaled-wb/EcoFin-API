// server/src/eta/config.ts
//
// T02 (D67, decision 13). The hosts of the two ETA systems, from the environment (defaults: the
// hosts the SDK documents, docs/eta/ERECEIPT_SPEC.md section 1). A receipt is sent to the hosts
// of its own environment only (fiscal_submissions.environment), never to the other system.

import type { EtaEnvironment } from '@ziadkhaled-wb/contracts';
import type { Env } from '../utils/env';

export interface EtaHosts {
  /** Identity service: the token call. */
  idUrl: string;
  /** System API: submit, poll, lookup. */
  apiUrl: string;
  /** Invoicing portal: the link in the QR code. */
  portalUrl: string;
}

export type EtaHostMap = Readonly<Record<EtaEnvironment, EtaHosts>>;

export type EtaEnv = Pick<
  Env,
  | 'ETA_PREPROD_ID_URL'
  | 'ETA_PREPROD_API_URL'
  | 'ETA_PREPROD_PORTAL_URL'
  | 'ETA_PROD_ID_URL'
  | 'ETA_PROD_API_URL'
  | 'ETA_PROD_PORTAL_URL'
>;

const trim = (url: string): string => url.replace(/\/+$/, '');

export function etaHosts(env: EtaEnv): EtaHostMap {
  return {
    preprod: {
      idUrl: trim(env.ETA_PREPROD_ID_URL),
      apiUrl: trim(env.ETA_PREPROD_API_URL),
      portalUrl: trim(env.ETA_PREPROD_PORTAL_URL),
    },
    prod: {
      idUrl: trim(env.ETA_PROD_ID_URL),
      apiUrl: trim(env.ETA_PROD_API_URL),
      portalUrl: trim(env.ETA_PROD_PORTAL_URL),
    },
  };
}
