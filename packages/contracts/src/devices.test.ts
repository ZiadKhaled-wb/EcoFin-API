import { describe, it, expect } from 'vitest';
import {
  CurrentDeviceResponse,
  Device,
  DeviceActiveBody,
  DeviceCreateBody,
  DevicePairBody,
  DevicePaired,
  DeviceUpdateBody,
  DEVICE_TOKEN_HEADER,
  PAIRING_CODE_ALPHABET,
  errorCodeHttpStatus,
  isPairingCode,
  normalizePairingCode,
} from './index.js';

const ID = '11111111-1111-4111-8111-111111111111';
const BRANCH = '22222222-2222-4222-8222-222222222222';

describe('O03 device contracts', () => {
  it('a new device needs a branch and a name of 1 to 50 characters', () => {
    expect(DeviceCreateBody.parse({ branch_id: BRANCH, name: '  POS-1 ' })).toEqual({
      branch_id: BRANCH,
      name: 'POS-1',
    });
    for (const bad of [
      { branch_id: BRANCH, name: ' ' },
      { branch_id: BRANCH, name: 'x'.repeat(51) },
      { branch_id: 'nope', name: 'POS-1' },
      { branch_id: BRANCH, name: 'POS-1', organization_id: ID },
    ]) {
      expect(DeviceCreateBody.safeParse(bad).success).toBe(false);
    }
  });

  it('an update changes the name, the branch or both, never nothing', () => {
    expect(DeviceUpdateBody.parse({ name: 'POS-2' })).toEqual({ name: 'POS-2' });
    expect(DeviceUpdateBody.parse({ branch_id: BRANCH })).toEqual({ branch_id: BRANCH });
    expect(DeviceUpdateBody.safeParse({}).success).toBe(false);
    expect(DeviceUpdateBody.safeParse({ name: 'POS-2', is_active: false }).success).toBe(false);
  });

  it('turning a device off needs a reason; turning it on does not', () => {
    expect(DeviceActiveBody.parse({ active: true })).toEqual({ active: true });
    expect(DeviceActiveBody.parse({ active: false, reason: ' stolen ' }).reason).toBe('stolen');
    expect(DeviceActiveBody.safeParse({ active: false }).success).toBe(false);
    expect(DeviceActiveBody.safeParse({ active: false, reason: '  ' }).success).toBe(false);
    expect(DeviceActiveBody.safeParse({ active: false, reason: 'x'.repeat(201) }).success).toBe(
      false,
    );
  });

  it('the pairing alphabet has no look-alike characters and a typed code is normalised', () => {
    expect(PAIRING_CODE_ALPHABET).toHaveLength(31);
    for (const c of '01OIL') expect(PAIRING_CODE_ALPHABET).not.toContain(c);
    expect(normalizePairingCode(' abcd-efgh ')).toBe('ABCDEFGH');
    expect(isPairingCode('ABCDEFGH')).toBe(true);
    for (const bad of ['ABCDEFG', 'ABCDEFGHJ', 'ABCDEFG0', 'ABCDEFGO', 'abcdefgh']) {
      expect(isPairingCode(bad)).toBe(false);
    }
    expect(DevicePairBody.parse({ code: 'abcd efgh' })).toEqual({ code: 'abcd efgh' });
    expect(DevicePairBody.safeParse({ code: '' }).success).toBe(false);
    expect(DevicePairBody.safeParse({ code: 'ABCDEFGH', device_id: ID }).success).toBe(false);
  });

  it('answers name the device of the request and never carry a hash', () => {
    const device = { id: ID, name: 'POS-1', branch_id: BRANCH, branch_name: 'Main' };
    expect(DevicePaired.parse({ device_token: 't', device, token_hash: 'h' })).toEqual({
      device_token: 't',
      device,
    });
    expect(CurrentDeviceResponse.parse({ device: null })).toEqual({ device: null });
    expect(CurrentDeviceResponse.parse({ device: { ...device, token_hash: 'h' } })).toEqual({
      device,
    });
    expect(DEVICE_TOKEN_HEADER).toBe('x-device-token');
  });

  it('a listed device says whether it is paired and when it was last seen', () => {
    const row = {
      id: ID,
      name: 'POS-1',
      branch_id: BRANCH,
      branch_name: 'Main',
      eta_serial: null,
      eta_os_version: null,
      eta_model_framework: null,
      eta_status: 'unregistered',
      has_preshared_key: false,
      is_active: true,
      paired: true,
      paired_at: '2026-10-13T09:00:00+00:00',
      last_seen_at: null,
    };
    expect(Device.parse({ ...row, token_hash: 'h', pairing_code_hash: 'h' })).toEqual(row);
    expect(Device.safeParse({ ...row, paired: undefined }).success).toBe(false);
  });

  it('the device error codes have the statuses the task fixes', () => {
    expect(errorCodeHttpStatus.DEVICE_REQUIRED).toBe(409);
    expect(errorCodeHttpStatus.DEVICE_HAS_OPEN_SHIFT).toBe(409);
    expect(errorCodeHttpStatus.DEVICE_NAME_TAKEN).toBe(409);
    expect(errorCodeHttpStatus.DEVICE_BRANCH_MISMATCH).toBe(409);
    expect(errorCodeHttpStatus.DEVICE_MISMATCH).toBe(409);
    expect(errorCodeHttpStatus.DEVICE_REVOKED).toBe(403);
    expect(errorCodeHttpStatus.DEVICE_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.PAIRING_CODE_INVALID).toBe(400);
  });
});
