import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRiskPayload } from './risk-coordinator.js';

const now = 1800000000000;
const base = {
  brokerServer: 'Broker-Live-01', login: '123456',
  clientId: 'terminal-a', snapshotAt: now - 100,
  equity: 10000, actualRiskMoney: 50
};

test('accepts a fresh account snapshot for a reservation', () => {
  const result = validateRiskPayload({...base, requestId: 'request_1234567890', proposedRiskMoney: 25, capPercent: 2}, 'reserve', now);
  assert.equal(result.error, undefined);
  assert.equal(result.value.maxSnapshotAgeMs, 5000);
});

test('rejects stale and future broker snapshots', () => {
  assert.match(validateRiskPayload({...base, snapshotAt: now - 6000}, 'reserve', now).error, /Fresh broker snapshot/);
  assert.match(validateRiskPayload({...base, snapshotAt: now + 3000}, 'reserve', now).error, /Fresh broker snapshot/);
});

test('hard cap cannot be raised above two percent', () => {
  assert.match(validateRiskPayload({...base, requestId: 'request_1234567890', proposedRiskMoney: 10, capPercent: 2.01}, 'reserve', now).error, /capPercent/);
});

test('rejects non-finite or negative exposure values', () => {
  assert.match(validateRiskPayload({...base, equity: Infinity}, 'reserve', now).error, /positive equity/);
  assert.match(validateRiskPayload({...base, actualRiskMoney: -1}, 'reserve', now).error, /positive equity/);
});

test('reconciliation only accepts an array of reflected reservation IDs', () => {
  assert.match(validateRiskPayload({...base, reflectedRequestIds: 'not-an-array'}, 'reconcile', now).error, /must be an array/);
});
