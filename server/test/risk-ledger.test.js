import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openRiskLedger, RiskLedgerError } from '../risk-ledger.js';

function fixture(options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'ax-risk-ledger-'));
  const path = join(dir, 'risk.sqlite');
  let now = 1_800_000_000_000;
  const clock = () => now;
  const ledger = openRiskLedger(path, { clock, ...options });
  const base = {
    login: '12345678', server: 'Broker-Live',
    equity: 10000, existingRiskMoney: 0,
    snapshotAtMs: now, snapshotId: 'snapshot-0001',
  };
  return {
    ledger, path, base, setNow(value) { now = value; },
    close() { ledger.close(); rmSync(dir, { recursive: true, force: true }); },
  };
}

function expectCode(fn, code) {
  assert.throws(fn, error => error instanceof RiskLedgerError && error.code === code);
}

test('requires a fresh broker snapshot before any reservation', () => {
  const f = fixture();
  try {
    expectCode(() => f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 10 }), 'NO_BROKER_SNAPSHOT');
  } finally { f.close(); }
});

test('reconciles broker risk and derives the immutable 2% equity cap server-side', () => {
  const f = fixture();
  try {
    const result = f.ledger.reconcile({ ...f.base, existingRiskMoney: 30 });
    assert.equal(result.hardCapMoney, 200);
    assert.equal(result.withinCap, true);
  } finally { f.close(); }
});

test('rejects stale and out-of-order broker snapshots', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    expectCode(() => f.ledger.reconcile({ ...f.base, snapshotAtMs: f.base.snapshotAtMs - 1,
      snapshotId: 'snapshot-old' }), 'OUT_OF_ORDER_SNAPSHOT');
    expectCode(() => f.ledger.reconcile({ ...f.base, snapshotAtMs: f.base.snapshotAtMs,
      snapshotId: 'snapshot-other' }), 'OUT_OF_ORDER_SNAPSHOT');
  } finally { f.close(); }
});

test('atomically counts broker exposure and every active reservation against 2%', () => {
  const f = fixture();
  try {
    f.ledger.reconcile({ ...f.base, existingRiskMoney: 50 });
    const first = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 100 });
    assert.equal(first.ok, true);
    expectCode(() => f.ledger.reserve({ ...f.base, instanceId: 'terminal-b',
      idempotencyKey: 'entry-00000002', riskMoney: 51 }), 'ACCOUNT_RISK_BUDGET_EXCEEDED');
  } finally { f.close(); }
});

test('same idempotency key returns the original active reservation, never a second one', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const input = { ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 50 };
    const first = f.ledger.reserve(input);
    const duplicate = f.ledger.reserve(input);
    assert.equal(duplicate.duplicate, true);
    assert.equal(duplicate.reservationId, first.reservationId);
    expectCode(() => f.ledger.reserve({ ...input, riskMoney: 51 }), 'IDEMPOTENCY_KEY_ALREADY_USED');
  } finally { f.close(); }
});

test('separate ledger connections share reservations through the same persistent database', () => {
  const f = fixture();
  const second = openRiskLedger(f.path, { clock: () => 1_800_000_000_000 });
  try {
    f.ledger.reconcile(f.base);
    f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 150 });
    expectCode(() => second.reserve({ ...f.base, instanceId: 'terminal-b',
      idempotencyKey: 'entry-00000002', riskMoney: 51 }), 'ACCOUNT_RISK_BUDGET_EXCEEDED');
  } finally { second.close(); f.close(); }
});

test('release requires a newer broker snapshot and the originating instance', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const reservation = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 150 });
    expectCode(() => f.ledger.release({ ...f.base, reservationId: reservation.reservationId,
      instanceId: 'terminal-a' }), 'RELEASE_REQUIRES_NEW_BROKER_SNAPSHOT');
    f.setNow(f.base.snapshotAtMs + 100);
    expectCode(() => f.ledger.release({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 100,
      snapshotId: 'snapshot-0002', reservationId: reservation.reservationId,
      instanceId: 'terminal-b' }), 'RESERVATION_OWNER_MISMATCH');
    assert.equal(f.ledger.release({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 100,
      snapshotId: 'snapshot-0002', reservationId: reservation.reservationId,
      instanceId: 'terminal-a' }).released, true);
    const next = f.ledger.reserve({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 100,
      snapshotId: 'snapshot-0002', instanceId: 'terminal-b',
      idempotencyKey: 'entry-00000002', riskMoney: 190 });
    assert.equal(next.ok, true);
  } finally { f.close(); }
});

test('settlement updates broker exposure and consumes its reservation in one transaction', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const reservation = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 100 });
    f.setNow(f.base.snapshotAtMs + 100);
    const settled = f.ledger.settle({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 100,
      snapshotId: 'snapshot-0002', existingRiskMoney: 100, reservationId: reservation.reservationId, instanceId: 'terminal-a' });
    assert.equal(settled.settled, true);
    assert.equal(settled.withinCap, true);
    expectCode(() => f.ledger.release({ ...f.base, reservationId: reservation.reservationId, instanceId: 'terminal-a' }),
      'RESERVATION_ALREADY_SETTLED');
  } finally { f.close(); }
});

test('settlement refuses to consume a reservation without a new post-fill broker snapshot', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const reservation = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 100 });
    expectCode(() => f.ledger.settle({ ...f.base, reservationId: reservation.reservationId, instanceId: 'terminal-a' }),
      'POST_FILL_SNAPSHOT_NOT_NEW');
  } finally { f.close(); }
});

test('settlement reports an actual broker overrun instead of hiding it', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const reservation = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 100 });
    f.setNow(f.base.snapshotAtMs + 100);
    const result = f.ledger.settle({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 100,
      snapshotId: 'snapshot-0002', existingRiskMoney: 205, reservationId: reservation.reservationId, instanceId: 'terminal-a' });
    assert.equal(result.withinCap, false);
  } finally { f.close(); }
});

test('expired reservations are not counted after a fresh broker snapshot', () => {
  const f = fixture({ reservationTtlMs: 5000 });
  try {
    f.ledger.reconcile(f.base);
    f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 150 });
    f.setNow(f.base.snapshotAtMs + 6000);
    f.ledger.reconcile({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-0002' });
    const next = f.ledger.reserve({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      instanceId: 'terminal-b', idempotencyKey: 'entry-00000002', riskMoney: 190 });
    assert.equal(next.ok, true);
  } finally { f.close(); }
});


test('expired reservations block new risk until a newer broker reconciliation resolves them', () => {
  const f = fixture({ reservationTtlMs: 5000 });
  try {
    f.ledger.reconcile(f.base);
    f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 150 });
    f.setNow(f.base.snapshotAtMs + 6000);
    expectCode(() => f.ledger.reserve({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-0002', instanceId: 'terminal-b',
      idempotencyKey: 'entry-00000002', riskMoney: 190 }),
      'EXPIRED_RESERVATION_REQUIRES_RECONCILIATION');
    const reconciled = f.ledger.reconcile({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-0002', existingRiskMoney: 0 });
    assert.equal(reconciled.ok, true);
    const next = f.ledger.reserve({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-0002', instanceId: 'terminal-b',
      idempotencyKey: 'entry-00000002', riskMoney: 190 });
    assert.equal(next.ok, true);
  } finally { f.close(); }
});

test('a client cannot raise the server-calculated cap by supplying extra fields', () => {
  const f = fixture();
  try {
    f.ledger.reconcile({ ...f.base, hardCapMoney: 999999 });
    expectCode(() => f.ledger.reserve({ ...f.base, hardCapMoney: 999999,
      instanceId: 'terminal-a', idempotencyKey: 'entry-00000001', riskMoney: 201 }),
      'ACCOUNT_RISK_BUDGET_EXCEEDED');
  } finally { f.close(); }
});
