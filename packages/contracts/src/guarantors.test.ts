import { describe, it, expect } from 'vitest';
import {
  CustomerGuarantor,
  CustomerGuarantorLinkBody,
  CustomerGuarantorList,
  CustomerGuarantorParams,
  CustomerGuarantorRelationBody,
  GUARANTOR_RELATIONS,
  Guarantor,
  GuarantorCreateBody,
  GuarantorDetails,
  GuarantorIdParams,
  GuarantorList,
  GuarantorListQuery,
  GuarantorNationalIdTakenDetail,
  GuarantorRequiredDetail,
  GuarantorRequirement,
  GuarantorRequirementQuery,
  GuarantorUpdateBody,
  MAX_GUARANTORS_PER_CONTRACT,
  MAX_GUARANTORS_PER_CUSTOMER,
} from './guarantors.js';
import { InstallmentPolicyBody } from './settings.js';
import { errorCodeHttpStatus } from './errors.js';

const ID = 'a0710000-0000-4000-8000-000000000001';
const OTHER = 'a0710000-0000-4000-8000-000000000002';

const guarantor = {
  id: ID,
  full_name: 'Mahmoud Hassan',
  phone: '01001234567',
  national_id: null,
  national_id_masked: '**********0015',
  birth_date: null,
  gender: null,
  address: null,
  job: 'Teacher',
  monthly_income: '6000.00',
  also_customer: null,
  archived_at: null,
  id_photos_count: 1,
  created_at: '2026-10-15T08:00:00.000Z',
  updated_at: '2026-10-15T08:00:00.000Z',
};

const create = {
  full_name: 'Mahmoud Hassan',
  phone: '01001234567',
  national_id: '29001010100015',
};

describe('GuarantorCreateBody', () => {
  it('needs a name, a phone and a national ID', () => {
    expect(GuarantorCreateBody.safeParse(create).success).toBe(true);
    for (const key of ['full_name', 'phone', 'national_id'] as const) {
      const { [key]: _removed, ...rest } = create;
      expect(GuarantorCreateBody.safeParse(rest).success).toBe(false);
    }
  });

  it('cleans the name, the phone and the national ID the way customers do', () => {
    const body = GuarantorCreateBody.parse({
      full_name: '  Mahmoud   Hassan ',
      phone: ' +20 100 123 4567 ',
      national_id: ' 2900101-0100015 ',
    });
    expect(body).toEqual({
      full_name: 'Mahmoud Hassan',
      phone: '01001234567',
      national_id: '29001010100015',
    });
    expect(
      GuarantorCreateBody.parse({ ...create, national_id: '٢٩٠٠١٠١٠١٠٠٠١٥' }).national_id,
    ).toBe('29001010100015');
  });

  it('refuses a national ID that does not parse', () => {
    for (const bad of ['', '2900101010001', '49001010100015', '29002300100015', '39901010100015']) {
      expect(GuarantorCreateBody.safeParse({ ...create, national_id: bad }).success).toBe(false);
    }
  });

  it('refuses a bad phone, a one-letter name and a negative income', () => {
    expect(GuarantorCreateBody.safeParse({ ...create, phone: '12345' }).success).toBe(false);
    expect(GuarantorCreateBody.safeParse({ ...create, full_name: ' A ' }).success).toBe(false);
    expect(GuarantorCreateBody.safeParse({ ...create, monthly_income: '-1' }).success).toBe(false);
    expect(GuarantorCreateBody.safeParse({ ...create, monthly_income: '10.005' }).success).toBe(
      false,
    );
  });

  it('turns an empty optional field into null', () => {
    const body = GuarantorCreateBody.parse({
      ...create,
      address: '  ',
      job: '',
      monthly_income: null,
    });
    expect(body.address).toBeNull();
    expect(body.job).toBeNull();
    expect(body.monthly_income).toBeNull();
  });

  it('takes a link to a customer with a known relation, and nothing else', () => {
    const link = { customer_id: OTHER, relation: 'father' };
    expect(GuarantorCreateBody.parse({ ...create, link }).link).toEqual(link);
    expect(
      GuarantorCreateBody.safeParse({ ...create, link: { customer_id: OTHER, relation: 'boss' } })
        .success,
    ).toBe(false);
    expect(GuarantorCreateBody.safeParse({ ...create, link: { customer_id: OTHER } }).success).toBe(
      false,
    );
    expect(GuarantorCreateBody.safeParse({ ...create, link: { ...link, extra: 1 } }).success).toBe(
      false,
    );
  });

  it('refuses keys the client must not send', () => {
    for (const key of ['organization_id', 'customer_id', 'archived_at', 'birth_date', 'gender']) {
      expect(GuarantorCreateBody.safeParse({ ...create, [key]: 'x' }).success).toBe(false);
    }
  });
});

describe('GuarantorUpdateBody', () => {
  it('needs at least one key and takes no link', () => {
    expect(GuarantorUpdateBody.safeParse({}).success).toBe(false);
    expect(GuarantorUpdateBody.safeParse({ job: 'Driver' }).success).toBe(true);
    expect(
      GuarantorUpdateBody.safeParse({ link: { customer_id: OTHER, relation: 'father' } }).success,
    ).toBe(false);
  });

  it('clears an optional field with an empty string but never the required ones', () => {
    expect(GuarantorUpdateBody.parse({ address: '' }).address).toBeNull();
    expect(GuarantorUpdateBody.parse({ monthly_income: null }).monthly_income).toBeNull();
    expect(GuarantorUpdateBody.safeParse({ phone: '' }).success).toBe(false);
    expect(GuarantorUpdateBody.safeParse({ national_id: '' }).success).toBe(false);
    expect(GuarantorUpdateBody.safeParse({ full_name: '' }).success).toBe(false);
  });
});

describe('relations and limits', () => {
  it('has the thirteen relations of the decision', () => {
    expect(GUARANTOR_RELATIONS).toHaveLength(13);
    expect(CustomerGuarantorRelationBody.safeParse({ relation: 'colleague' }).success).toBe(true);
    expect(CustomerGuarantorRelationBody.safeParse({ relation: 'boss' }).success).toBe(false);
    expect(CustomerGuarantorRelationBody.safeParse({}).success).toBe(false);
  });

  it('allows 5 guarantors per customer and 3 per contract', () => {
    expect(MAX_GUARANTORS_PER_CUSTOMER).toBe(5);
    expect(MAX_GUARANTORS_PER_CONTRACT).toBe(3);
  });

  it('links one guarantor at a time', () => {
    expect(
      CustomerGuarantorLinkBody.safeParse({ guarantor_id: ID, relation: 'brother' }).success,
    ).toBe(true);
    expect(CustomerGuarantorLinkBody.safeParse({ guarantor_id: ID }).success).toBe(false);
    expect(
      CustomerGuarantorLinkBody.safeParse({ guarantor_id: 'x', relation: 'brother' }).success,
    ).toBe(false);
    expect(
      CustomerGuarantorLinkBody.safeParse({ guarantor_id: ID, relation: 'brother', ids: [] })
        .success,
    ).toBe(false);
  });
});

describe('params and queries', () => {
  it('checks ids', () => {
    expect(GuarantorIdParams.safeParse({ id: ID }).success).toBe(true);
    expect(GuarantorIdParams.safeParse({ id: '../x' }).success).toBe(false);
    expect(CustomerGuarantorParams.safeParse({ id: ID, guarantorId: OTHER }).success).toBe(true);
    expect(CustomerGuarantorParams.safeParse({ id: ID }).success).toBe(false);
  });

  it('lists active guarantors by default', () => {
    const q = GuarantorListQuery.parse({});
    expect(q).toMatchObject({ status: 'active', page: 1 });
    expect(GuarantorListQuery.parse({ search: '  ' }).search).toBeUndefined();
    expect(GuarantorListQuery.safeParse({ status: 'blocked' }).success).toBe(false);
    expect(GuarantorListQuery.safeParse({ status: 'archived' }).success).toBe(true);
  });

  it('asks for the requirement with a financed amount', () => {
    expect(GuarantorRequirementQuery.parse({ financed_amount: '15000.00' })).toEqual({
      financed_amount: '15000.00',
    });
    expect(GuarantorRequirementQuery.safeParse({}).success).toBe(false);
    expect(GuarantorRequirementQuery.safeParse({ financed_amount: '-5' }).success).toBe(false);
    expect(GuarantorRequirementQuery.safeParse({ financed_amount: '10.005' }).success).toBe(false);
  });
});

describe('answers', () => {
  it('parses a guarantor, a list and the details', () => {
    expect(Guarantor.parse(guarantor)).toEqual(guarantor);
    expect(
      GuarantorList.parse({ items: [guarantor], total: 1, page: 1, pageSize: 50 }).items,
    ).toHaveLength(1);
    const details = GuarantorDetails.parse({
      ...guarantor,
      customers: [
        {
          customer_id: OTHER,
          full_name: 'Ahmed',
          relation: 'friend',
          linked_at: guarantor.created_at,
        },
      ],
      contracts: [],
    });
    expect(details.customers[0]?.relation).toBe('friend');
  });

  it('parses a customer guarantor with its relation and the active-contract flag', () => {
    const item = {
      ...guarantor,
      relation: 'brother',
      linked_at: guarantor.created_at,
      on_active_contract: false,
    };
    expect(CustomerGuarantor.parse(item).relation).toBe('brother');
    expect(CustomerGuarantorList.parse([item])).toHaveLength(1);
    expect(CustomerGuarantor.safeParse({ ...item, relation: 'boss' }).success).toBe(false);
  });

  it('parses the requirement, with or without a policy', () => {
    const met = {
      policy_id: ID,
      policy_version: 3,
      required_above: '10000.00',
      required_count: 2,
      linked_active_count: 1,
      met: false,
    };
    expect(GuarantorRequirement.parse(met).met).toBe(false);
    expect(
      GuarantorRequirement.parse({
        ...met,
        policy_id: null,
        policy_version: null,
        required_above: null,
      }),
    ).toBeTruthy();
    expect(GuarantorRequirement.safeParse({ ...met, required_count: 4 }).success).toBe(false);
  });

  it('describes the error details', () => {
    expect(GuarantorNationalIdTakenDetail.parse({ guarantor_id: ID, full_name: 'X' })).toBeTruthy();
    expect(GuarantorRequiredDetail.parse({ required: 2, given: 1 })).toEqual({
      required: 2,
      given: 1,
    });
    expect(GuarantorRequiredDetail.safeParse({ required: 0, given: 0 }).success).toBe(false);
  });
});

describe('error codes and the policy field', () => {
  it('maps the guarantor codes to their HTTP status', () => {
    expect(errorCodeHttpStatus.GUARANTOR_NOT_FOUND).toBe(404);
    for (const code of [
      'GUARANTOR_NATIONAL_ID_TAKEN',
      'GUARANTOR_ALREADY_LINKED',
      'GUARANTOR_NOT_LINKED',
      'GUARANTOR_LIMIT_REACHED',
      'GUARANTOR_IS_CUSTOMER',
      'GUARANTOR_ARCHIVED',
      'GUARANTOR_ON_ACTIVE_CONTRACT',
      'GUARANTOR_REQUIRED',
      'CUSTOMER_BLOCKED',
    ] as const) {
      expect(errorCodeHttpStatus[code]).toBe(409);
    }
  });

  it('lets a policy version carry 1 to 3 guarantors', () => {
    for (const n of [1, 2, 3]) {
      expect(InstallmentPolicyBody.safeParse({ guarantors_required_count: n }).success).toBe(true);
    }
    for (const n of [0, 4, 1.5, '2']) {
      expect(InstallmentPolicyBody.safeParse({ guarantors_required_count: n }).success).toBe(false);
    }
  });
});
