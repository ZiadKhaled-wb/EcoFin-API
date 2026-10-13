import { describe, expect, it } from 'vitest';
import { BranchUpdateBody, ManagedBranch } from './branches';
import { errorCodeHttpStatus } from './errors';
import {
  Device,
  DeviceEtaBody,
  EtaSettings,
  EtaSettingsBody,
  EtaTestBody,
  EtaTestResult,
  FiscalRetryResult,
  SaleEta,
} from './eta';
import { Sale } from './sales';

const ID = 'a0900000-0000-4000-8000-000000000001';

describe('T02 ETA contracts', () => {
  it('settings answers say whether a secret is stored and carry no secret field', () => {
    const settings = {
      environment: 'preprod',
      client_id: 'client-1',
      has_client_secret: true,
      activity_code: '4620',
      is_enabled: true,
      updated_at: '2026-10-12T09:00:00+00:00',
    };
    expect(
      EtaSettings.parse({ ...settings, client_secret: 'leak', client_secret_vault_id: ID }),
    ).toEqual(settings);
    expect(EtaSettings.safeParse({ ...settings, environment: 'staging' }).success).toBe(false);
  });

  it('the settings body takes the secret write-only and trims the rest', () => {
    const body = {
      environment: 'prod',
      client_id: ' client-1 ',
      activity_code: '4620',
      is_enabled: true,
    };
    expect(EtaSettingsBody.parse(body)).toEqual({ ...body, client_id: 'client-1' });
    expect(EtaSettingsBody.parse({ ...body, client_secret: 's3cret' }).client_secret).toBe(
      's3cret',
    );
    expect(EtaSettingsBody.parse({ ...body, client_secret: null }).client_secret).toBeNull();
    // A cleared input clears the value.
    expect(EtaSettingsBody.parse({ ...body, client_id: '', activity_code: ' ' })).toMatchObject({
      client_id: null,
      activity_code: null,
    });
    for (const bad of [
      { ...body, client_secret: '' },
      { ...body, client_secret: 'x'.repeat(101) },
      { ...body, client_id: 'x'.repeat(101) },
      { ...body, activity_code: '46 20' },
      { ...body, activity_code: '12345678901' },
      { ...body, environment: 'test' },
      { ...body, organization_id: ID },
      { environment: 'prod' },
    ]) {
      expect(EtaSettingsBody.safeParse(bad).success).toBe(false);
    }
  });

  it('a device answer says whether a key is stored and carries no key', () => {
    const device = {
      id: ID,
      name: 'Till 1',
      branch_id: ID,
      branch_name: 'Main',
      eta_serial: null,
      eta_os_version: null,
      eta_model_framework: null,
      eta_status: 'unregistered',
      has_preshared_key: false,
      is_active: true,
      paired: false,
      paired_at: null,
      last_seen_at: null,
    };
    expect(
      Device.parse({ ...device, preshared_key: 'leak', eta_preshared_key_vault_id: ID }),
    ).toEqual(device);
    expect(Device.safeParse({ ...device, eta_status: 'retired' }).success).toBe(false);
  });

  it('the device body follows the SDK limits (serial 100, OS 50, framework 10, key 200)', () => {
    const body = {
      eta_serial: 'POS-001',
      eta_os_version: 'android 14',
      eta_model_framework: '1',
      eta_status: 'active',
    };
    expect(DeviceEtaBody.parse(body)).toEqual(body);
    expect(
      DeviceEtaBody.parse({ ...body, preshared_key: 'k'.repeat(200) }).preshared_key,
    ).toHaveLength(200);
    expect(DeviceEtaBody.parse({ ...body, eta_serial: ' ' }).eta_serial).toBeNull();
    for (const bad of [
      { ...body, eta_serial: 'x'.repeat(101) },
      { ...body, eta_os_version: 'x'.repeat(51) },
      { ...body, eta_model_framework: 'x'.repeat(11) },
      { ...body, preshared_key: 'k'.repeat(201) },
      { ...body, preshared_key: '' },
      { ...body, eta_status: 'on' },
      { ...body, branch_id: ID },
    ]) {
      expect(DeviceEtaBody.safeParse(bad).success).toBe(false);
    }
  });

  it('the connection test, the retry answer and the receipt of a sale', () => {
    expect(EtaTestBody.safeParse({ device_id: 'x' }).success).toBe(false);
    expect(EtaTestResult.parse({ ok: false, message: 'invalid_presharedkey' }).message).toBe(
      'invalid_presharedkey',
    );
    expect(FiscalRetryResult.parse({ id: ID, status: 'pending' }).status).toBe('pending');
    const eta = {
      status: 'failed',
      uuid: null,
      qr_payload: null,
      last_error_code: 'BLOCKED:ITEM_CODE',
    };
    expect(SaleEta.parse(eta)).toEqual(eta);
    expect(SaleEta.safeParse({ ...eta, status: 'sent' }).success).toBe(false);
    // Optional on a sale: a sale read by an older client, or without a receipt, still parses.
    expect(Sale.shape.eta.parse(undefined)).toBeUndefined();
    expect(Sale.shape.eta.parse(null)).toBeNull();
    expect(Sale.shape.eta.parse(eta)).toEqual(eta);
  });

  it('a branch carries the building number the receipt address needs', () => {
    expect(BranchUpdateBody.parse({ name: 'Main', building_number: ' 14 ' }).building_number).toBe(
      '14',
    );
    expect(BranchUpdateBody.parse({ name: 'Main' }).building_number).toBeUndefined();
    expect(
      BranchUpdateBody.safeParse({ name: 'Main', building_number: 'x'.repeat(101) }).success,
    ).toBe(false);
    expect(ManagedBranch.shape.building_number.parse(null)).toBeNull();
  });

  it('error codes', () => {
    expect(errorCodeHttpStatus.DEVICE_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.FISCAL_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.DEVICE_SERIAL_TAKEN).toBe(409);
    expect(errorCodeHttpStatus.ETA_ENV_BUSY).toBe(409);
    expect(errorCodeHttpStatus.ETA_ENV_MISMATCH).toBe(409);
    expect(errorCodeHttpStatus.FISCAL_NOT_RETRYABLE).toBe(409);
  });
});
