import { describe, expect, it } from 'vitest';
import { errorCodeHttpStatus } from './errors.js';
import { Contract } from './installments.js';
import {
  AddCaseNoteBody,
  AddHearingBody,
  ContractLegalFlag,
  LEGAL_CASE_STATUSES,
  LEGAL_OUTCOME_KINDS,
  LawyerListResponse,
  LegalCaseDetail,
  LegalCaseListQuery,
  LegalCaseListResponse,
  OpenLegalCaseBody,
  SetLegalCaseStatusBody,
  UpdateHearingBody,
  UpdateLegalCaseBody,
  legalNextStatuses,
} from './legal.js';
import { OverdueContractRow } from './overdue.js';
import { PERMISSION_KEYS, ROLE_DEFAULT_PERMISSIONS } from './permissions.js';

const ID = '11111111-1111-4111-8111-111111111111';
const row = {
  id: ID,
  number: 'BR1-LC-26-000001',
  case_number: null,
  court: null,
  case_type: null,
  status: 'preparing',
  opened_on: '2026-10-24',
  next_hearing_date: null,
  claim_amount: '11000.00',
  remaining: '11000.00',
  contract: { id: ID, number: 'BR1-CT-26-000001', branch_id: ID },
  customer: { id: ID, name: 'Nadia', phone: '01011112222', status: 'blocked' },
  lawyer: null,
};
const detail = {
  ...row,
  guarantors: [],
  hearings: [],
  notes: [],
  amounts: {
    claim_amount: '11000.00',
    total_payable: '14000.00',
    paid_before_case: '1000.00',
    paid_since_opened: '500.00',
    remaining: '10500.00',
  },
  collections_since_opened: [],
  referral: null,
  outcome_kind: null,
  outcome: null,
  closed_at: null,
  created_by_name: 'Owner',
};

describe('L01 reads', () => {
  it('parses the list query and refuses fee-like filters', () => {
    expect(LegalCaseListQuery.parse({ status: 'all', limit: '10', q: ' Nadia ' })).toEqual({
      status: 'all',
      limit: 10,
      q: 'Nadia',
    });
    expect(LegalCaseListQuery.safeParse({ status: 'filed' }).success).toBe(false);
    expect(LegalCaseListQuery.safeParse({ limit: '101' }).success).toBe(false);
    expect(LegalCaseListQuery.safeParse({ fee: '1' }).success).toBe(false);
  });

  it('parses a page and a detail; money stays a string', () => {
    expect(LegalCaseListResponse.safeParse({ rows: [row], next_cursor: null }).success).toBe(true);
    expect(LegalCaseDetail.safeParse(detail).success).toBe(true);
    expect(LegalCaseDetail.safeParse({ ...detail, claim_amount: 11000 }).success).toBe(false);
    expect(
      LawyerListResponse.safeParse({
        items: [{ id: ID, full_name: 'A', phone: null, open_cases: 2 }],
      }).success,
    ).toBe(true);
  });

  it('has no fee, cost or charge member anywhere in a case', () => {
    const keys = JSON.stringify(Object.keys(LegalCaseDetail.shape));
    expect(keys).not.toMatch(/fee|cost|charge|penalt|interest/i);
  });

  it('adds the flag to the contract, the customer account and the overdue row', () => {
    const flag = {
      id: ID,
      number: 'BR1-LC-26-000001',
      status: 'in_court',
      opened_on: '2026-10-24',
    };
    expect(ContractLegalFlag.safeParse(flag).success).toBe(true);
    expect(ContractLegalFlag.safeParse({ ...flag, status: 'appealed' }).success).toBe(false);
    expect(Contract.shape.legal_case.safeParse(flag).success).toBe(true);
    expect(Contract.shape.legal_case.safeParse(null).success).toBe(true);
    expect(Contract.shape.legal_case.safeParse(undefined).success).toBe(true);
    expect(
      OverdueContractRow.shape.legal_case.safeParse({ id: ID, number: 'x', status: 'filed' })
        .success,
    ).toBe(true);
  });
});

describe('L01 bodies', () => {
  it('opens a case: contract required, claim above 0 as a money string, no fee field', () => {
    expect(OpenLegalCaseBody.safeParse({ contract_id: ID }).success).toBe(true);
    expect(
      OpenLegalCaseBody.safeParse({ contract_id: ID, claim_amount: '100.5', note: 'first' })
        .success,
    ).toBe(true);
    expect(OpenLegalCaseBody.safeParse({ contract_id: ID, claim_amount: 100 }).success).toBe(false);
    expect(OpenLegalCaseBody.safeParse({ contract_id: ID, claim_amount: '0.00' }).success).toBe(
      false,
    );
    expect(OpenLegalCaseBody.safeParse({ contract_id: ID, claim_amount: '-5.00' }).success).toBe(
      false,
    );
    expect(OpenLegalCaseBody.safeParse({ contract_id: ID, court_fee: '5.00' }).success).toBe(false);
    expect(OpenLegalCaseBody.safeParse({ claim_amount: '5.00' }).success).toBe(false);
    expect(
      OpenLegalCaseBody.safeParse({ contract_id: ID, case_type: 'x'.repeat(101) }).success,
    ).toBe(false);
  });

  it('updates need at least one field; the lawyer and text fields can be cleared', () => {
    expect(UpdateLegalCaseBody.safeParse({}).success).toBe(false);
    expect(UpdateLegalCaseBody.safeParse({ court: null, lawyer_employee_id: null }).success).toBe(
      true,
    );
    expect(UpdateLegalCaseBody.safeParse({ claim_amount: '1.00', cost: '1' }).success).toBe(false);
  });

  it('closing needs an outcome kind, and a note for other; other moves take none', () => {
    expect(SetLegalCaseStatusBody.safeParse({ status: 'filed' }).success).toBe(true);
    expect(
      SetLegalCaseStatusBody.safeParse({ status: 'filed', outcome_kind: 'paid' }).success,
    ).toBe(false);
    expect(SetLegalCaseStatusBody.safeParse({ status: 'closed' }).success).toBe(false);
    expect(
      SetLegalCaseStatusBody.safeParse({ status: 'closed', outcome_kind: 'paid' }).success,
    ).toBe(true);
    expect(
      SetLegalCaseStatusBody.safeParse({ status: 'closed', outcome_kind: 'other' }).success,
    ).toBe(false);
    expect(
      SetLegalCaseStatusBody.safeParse({
        status: 'closed',
        outcome_kind: 'other',
        outcome: 'See file',
      }).success,
    ).toBe(true);
    expect(SetLegalCaseStatusBody.safeParse({ status: 'appealed' }).success).toBe(false);
  });

  it('hearings and notes', () => {
    expect(AddHearingBody.safeParse({ hearing_date: '2026-11-01' }).success).toBe(true);
    expect(AddHearingBody.safeParse({ hearing_date: '2026-13-01' }).success).toBe(false);
    expect(UpdateHearingBody.safeParse({}).success).toBe(false);
    expect(UpdateHearingBody.safeParse({ outcome: 'Adjourned' }).success).toBe(true);
    expect(AddCaseNoteBody.safeParse({ note: '  ' }).success).toBe(false);
    expect(AddCaseNoteBody.safeParse({ note: 'x'.repeat(2001) }).success).toBe(false);
    expect(AddCaseNoteBody.safeParse({ note: 'ok' }).success).toBe(true);
  });
});

describe('L01 rules shared with the screens', () => {
  it('lists the allowed moves: forward, one appeal back, close from any open status', () => {
    expect(LEGAL_CASE_STATUSES).toEqual(['preparing', 'filed', 'in_court', 'judgment', 'closed']);
    expect(legalNextStatuses('preparing')).toEqual(['filed', 'closed']);
    expect(legalNextStatuses('judgment')).toEqual(['in_court', 'closed']);
    expect(legalNextStatuses('closed')).toEqual([]);
    expect(LEGAL_OUTCOME_KINDS).toHaveLength(6);
  });

  it('has the new error codes with the status the spec gives', () => {
    expect(errorCodeHttpStatus.LEGAL_CASE_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.HEARING_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.LEGAL_CASE_ALREADY_OPEN).toBe(409);
    expect(errorCodeHttpStatus.LEGAL_CASE_CLOSED).toBe(409);
    expect(errorCodeHttpStatus.LEGAL_CASE_FILED).toBe(409);
    expect(errorCodeHttpStatus.LEGAL_STATUS_INVALID).toBe(409);
    expect(errorCodeHttpStatus.LEGAL_CONTRACT_NOT_DEFAULTED).toBe(422);
    expect(errorCodeHttpStatus.LEGAL_CLAIM_TOO_HIGH).toBe(422);
    expect(errorCodeHttpStatus.LAWYER_INVALID).toBe(422);
  });

  it('adds no permission key: the lawyer keeps the four it had', () => {
    expect(PERMISSION_KEYS).toContain('legal.view');
    expect(PERMISSION_KEYS).toContain('legal.manage');
    expect([...(ROLE_DEFAULT_PERMISSIONS.LAWYER ?? [])].sort()).toEqual([
      'customer.view_pii',
      'legal.manage',
      'legal.view',
      'overdue.view',
    ]);
  });
});
