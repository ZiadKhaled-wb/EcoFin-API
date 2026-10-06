import type { Request, Response } from 'express';
import { InviteLookupBody, InviteAcceptBody } from '@ziadkhaled-wb/contracts';
import { lookupInvite, acceptInvite } from '../services/invites.service';
import { requestMeta } from '../middleware/auth';
export async function lookup(req: Request, res: Response) {
  res.json(await lookupInvite(InviteLookupBody.parse(req.body).token, requestMeta(req)));
}
export async function accept(req: Request, res: Response) {
  res.json(await acceptInvite(InviteAcceptBody.parse(req.body), requestMeta(req)));
}
