// src/test/fake-eta-server.ts
//
// INT-4: T02's fake ETA as a long-running local process (`npm run fake-eta`), so the API server and
// its job worker can send receipts to it during the end-to-end run. Test tooling only: nothing in
// the app imports this file and the build never bundles it. Both ports bind to 127.0.0.1.
//   FAKE_ETA_PORT        the ETA side (point ETA_PREPROD_ID_URL / ETA_PREPROD_API_URL here)
//   FAKE_ETA_ADMIN_PORT  the controls the tests use:
//     POST /admin/invalid-next  {message, code?, propertyPath?}  the next receipt is found Invalid
//     POST /admin/fail-next     {fault: accept-then-drop | unavailable | duplicate, retryAfter?}
//     POST /admin/in-progress   {polls}                         details answer InProgress first
//     GET  /admin/state         counts per UUID, receipts, chain breaks, bad hashes, call counts
// The credentials are fake ones that match the dev seed (shop int4-shop-a) and INT-4's devices.

import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import express, { type Request, type Response } from 'express';
import { startFakeEta, type FakeEta, type FakeEtaCredentials, type SubmitFault } from './fake-eta';

export const INT4_FAKE_ETA: FakeEtaCredentials = {
  clientId: 'int4-fake-client',
  clientSecret: 'int4-fake-secret',
  posSerial: 'INT4-POS-1',
  presharedKey: 'int4-fake-psk-1',
  extraPos: [
    { posSerial: 'INT4-POS-2', presharedKey: 'int4-fake-psk-2' },
    { posSerial: 'TEST4-POS-AR', presharedKey: 'test4-fake-psk-ar' },
    { posSerial: 'TEST4-POS-EN', presharedKey: 'test4-fake-psk-en' },
    // S08's offline e2e (EcoFin-Web e2e/s08-offline.spec.ts).
    { posSerial: 'S08-POS-1', presharedKey: 's08-fake-psk-1' },
  ],
};

const FAULTS: readonly SubmitFault[] = ['accept-then-drop', 'unavailable', 'duplicate'];
const str = (value: unknown): string | undefined => (typeof value === 'string' ? value : undefined);

export interface FakeEtaProcess {
  fake: FakeEta;
  adminUrl: string;
  close(): Promise<void>;
}

export async function startFakeEtaProcess(ports: {
  eta: number;
  admin: number;
}): Promise<FakeEtaProcess> {
  const fake = await startFakeEta(INT4_FAKE_ETA, { port: ports.eta });
  const admin = express();
  admin.use(express.json());

  admin.post('/admin/invalid-next', (req: Request, res: Response) => {
    const body = req.body as Record<string, unknown>;
    const message = str(body['message']);
    if (!message) {
      res.status(400).json({ error: 'message is required' });
      return;
    }
    const code = str(body['code']);
    const propertyPath = str(body['propertyPath']);
    fake.invalidNext({
      message,
      ...(code ? { code } : {}),
      ...(propertyPath ? { propertyPath } : {}),
    });
    res.status(204).end();
  });
  admin.post('/admin/fail-next', (req: Request, res: Response) => {
    const body = req.body as Record<string, unknown>;
    const fault = FAULTS.find((f) => f === body['fault']);
    if (!fault) {
      res.status(400).json({ error: `fault must be one of ${FAULTS.join(', ')}` });
      return;
    }
    const retryAfter = body['retryAfter'];
    fake.failNextSubmit(fault, typeof retryAfter === 'number' ? retryAfter : 0);
    res.status(204).end();
  });
  admin.post('/admin/in-progress', (req: Request, res: Response) => {
    const polls = (req.body as Record<string, unknown>)['polls'];
    fake.inProgressFor(typeof polls === 'number' ? polls : 0);
    res.status(204).end();
  });
  admin.get('/admin/state', (_req: Request, res: Response) => {
    res.json({
      received: Object.fromEntries(fake.received),
      receipts: [...fake.receipts.values()].map((r) => ({
        uuid: r.uuid,
        previousUuid: r.previousUuid,
        referenceOldUuid: r.referenceOldUuid,
        receiptNumber: r.receiptNumber,
        status: r.status,
        reason: r.reason,
      })),
      chainBreaks: fake.chainBreaks,
      badHashes: fake.badHashes,
      calls: fake.calls,
    });
  });

  const server: Server = createServer(admin);
  await new Promise<void>((resolve) => server.listen(ports.admin, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return {
    fake,
    adminUrl: `http://127.0.0.1:${port}`,
    close: async () => {
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) =>
        server.close((err) => (err ? reject(err) : resolve())),
      );
      await fake.close();
    },
  };
}

// Run directly: `npm run fake-eta`.
if (process.argv[1]?.replace(/\\/g, '/').endsWith('src/test/fake-eta-server.ts')) {
  const eta = Number(process.env['FAKE_ETA_PORT'] ?? 4010);
  const adminPort = Number(process.env['FAKE_ETA_ADMIN_PORT'] ?? 4011);
  const running = await startFakeEtaProcess({ eta, admin: adminPort });
  process.stdout.write(`fake ETA on ${running.fake.url}, controls on ${running.adminUrl}
`);
  const stop = () => void running.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
