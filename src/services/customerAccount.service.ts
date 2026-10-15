import {
  CustomerAccount,
  CustomerContractSchedule,
  CustomerStatement,
  type CustomerStatementQuery,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// R02 (D74). Read only: the database computes the open balance, the overdue numbers and the
// statement's running balance; nothing here adds money up. The rows are only checked against the
// contract on the way out.

function fail(error: unknown): never {
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'customer account database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

export async function getCustomerAccount(
  ctx: RequestContext,
  customerId: string,
): Promise<CustomerAccount> {
  const { data, error } = await ctx.db.rpc('get_customer_account', { p_customer_id: customerId });
  if (error) fail(error);
  return CustomerAccount.parse(data);
}

/** CONTRACT_NOT_FOUND when the contract is not this customer's. */
export async function getContractSchedule(
  ctx: RequestContext,
  customerId: string,
  contractId: string,
): Promise<CustomerContractSchedule> {
  const { data, error } = await ctx.db.rpc('get_customer_contract_schedule', {
    p_customer_id: customerId,
    p_contract_id: contractId,
  });
  if (error) fail(error);
  return CustomerContractSchedule.parse(data);
}

/** Without dates the whole history; the closing balance then equals total due − store credit. */
export async function getCustomerStatement(
  ctx: RequestContext,
  customerId: string,
  query: CustomerStatementQuery,
): Promise<CustomerStatement> {
  const { data, error } = await ctx.db.rpc('customer_statement', {
    p_customer_id: customerId,
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
  });
  if (error) fail(error);
  return CustomerStatement.parse(data);
}
