import {
  AdminSubscription,
  SubscriptionStatus,
  SubscriptionPaymentResponse,
  Uuid,
  type SubscriptionPlanBody,
  type SubscriptionDatesBody,
  type SubscriptionPaymentBody,
} from '@ziadkhaled-wb/contracts';
import type { DbClient } from '../utils/supabase';
import { adminError } from './admin.service';
export async function getAdminSubscription(db: DbClient, id: string) {
  const { data, error } = await db.rpc('admin_get_subscription', { p_organization_id: id });
  if (error) adminError(error);
  return AdminSubscription.parse(data);
}
export async function getSubscriptionStatus(db: DbClient) {
  const { data, error } = await db.rpc('get_subscription_status');
  if (error) adminError(error);
  return SubscriptionStatus.parse(data);
}
export async function changePlan(db: DbClient, id: string, body: SubscriptionPlanBody) {
  const { error } = await db.rpc('admin_change_plan', {
    p_organization_id: id,
    p_plan_key: body.plan_key,
    p_reason: body.reason,
  });
  if (error) adminError(error);
  return { plan_key: body.plan_key };
}
export async function setDates(db: DbClient, id: string, body: SubscriptionDatesBody) {
  const { error } = await db.rpc('admin_set_subscription_dates', {
    p_organization_id: id,
    p_start: body.start,
    p_end: body.end,
    p_reason: body.reason,
  });
  if (error) adminError(error);
  return { start: body.start, end: body.end };
}
export async function recordPayment(
  db: DbClient,
  id: string,
  body: SubscriptionPaymentBody,
  key: string,
) {
  const { data, error } = await db.rpc('admin_record_subscription_payment', {
    p_organization_id: id,
    p_amount: body.amount,
    p_period_start: body.period_start,
    p_period_end: body.period_end,
    p_reference: body.reference ?? null,
    p_extend: body.extend,
    p_idempotency_key: key,
  });
  if (error) adminError(error);
  const paymentId = Uuid.parse(data);
  const snapshot = await getAdminSubscription(db, id);
  return SubscriptionPaymentResponse.parse({
    payment_id: paymentId,
    subscription_end: snapshot.subscription_end,
  });
}
