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
  let ledgerClosed = false;
  const base = {
    login: '12345678', server: 'Broker-Live',
    equity: 10000, existingRiskMoney: 0,
    snapshotAtMs: now, snapshotId: 'snapshot-0001',
  };
  return {
    ledger, path, base, setNow(value) { now = value; },
    closeLedger() { if (!ledgerClosed) { ledger.close(); ledgerClosed = true; } },
    close() { this.closeLedger(); rmSync(dir, { recursive: true, force: true }); },
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
    expectCode(() => f.ledger.reserve({ ...input, riskMoney: 51 }), 'IDEMPOTENCY_KEY_CONFLICT');
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

test('settlement rejects a newer broker snapshot that still predates the reservation', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    f.setNow(f.base.snapshotAtMs + 100);
    const reservation = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 100 });
    expectCode(() => f.ledger.settle({ ...f.base,
      snapshotAtMs: f.base.snapshotAtMs + 50, snapshotId: 'snapshot-pre-order',
      reservationId: reservation.reservationId, instanceId: 'terminal-a' }),
      'POST_FILL_SNAPSHOT_NOT_NEW');
    // The failed settlement must roll back the attempted snapshot update.
    const valid = f.ledger.settle({ ...f.base,
      snapshotAtMs: f.base.snapshotAtMs + 150, snapshotId: 'snapshot-post-order',
      existingRiskMoney: 100, reservationId: reservation.reservationId, instanceId: 'terminal-a' });
    assert.equal(valid.settled, true);
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

test('unknown expired order outcome is reconciled as broker exposure before new risk is allowed', () => {
  const f = fixture({ reservationTtlMs: 5000 });
  try {
    f.ledger.reconcile(f.base);
    const reservation = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-unknown-0001', riskMoney: 150 });
    f.setNow(f.base.snapshotAtMs + 6000);

    // The terminal did not receive a conclusive order response. The broker scan
    // now finds the position, so reconciliation must transfer its risk into
    // broker exposure before consuming the expired reservation.
    const reconciled = f.ledger.reconcile({
      ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-after-unknown-fill', existingRiskMoney: 150,
    });
    assert.equal(reconciled.ok, true);
    assert.equal(reconciled.brokerRiskMoney, 150);

    expectCode(() => f.ledger.reserve({ ...f.base,
      snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-after-unknown-fill',
      instanceId: 'terminal-b', idempotencyKey: 'entry-new-0001', riskMoney: 60,
    }), 'ACCOUNT_RISK_BUDGET_EXCEEDED');
    expectCode(() => f.ledger.reserve({ ...f.base,
      snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-after-unknown-fill',
      instanceId: 'terminal-a', idempotencyKey: 'entry-unknown-0001', riskMoney: 150,
    }), 'IDEMPOTENCY_KEY_ALREADY_USED');
    assert.ok(reservation.reservationId);
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

test('simultaneous reservations from separate Node processes cannot oversubscribe the 2% account cap', async () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const moduleUrl = new URL('../risk-ledger.js', import.meta.url).href;
    const workerSource = `
      import { openRiskLedger } from ${JSON.stringify(moduleUrl)};
      const input = JSON.parse(process.argv[1]);
      const ledger = openRiskLedger(input.path, { clock: () => input.now });
      try {
        const result = ledger.reserve(input.request);
        process.stdout.write(JSON.stringify({ ok: true, result }));
      } catch (error) {
        process.stdout.write(JSON.stringify({ ok: false, code: error.code ?? error.message }));
      } finally {
        ledger.close();
      }
    `;
    const { execFile } = await import('node:child_process');
    const { promisify } = await import('node:util');
    const run = promisify(execFile);
    const makeRequest = terminal => ({
      path: f.path,
      now: f.base.snapshotAtMs,
      request: { ...f.base, instanceId: terminal,
        idempotencyKey: terminal + '-entry-0001', riskMoney: 120 },
    });
    const outcomes = await Promise.all(['terminal-race-a', 'terminal-race-b'].map(async terminal => {
      const { stdout } = await run(process.execPath, ['--input-type=module', '-e', workerSource,
        JSON.stringify(makeRequest(terminal))], { timeout: 10000 });
      return JSON.parse(stdout);
    }));
    assert.equal(outcomes.filter(x => x.ok).length, 1);
    assert.equal(outcomes.filter(x => !x.ok && x.code === 'ACCOUNT_RISK_BUDGET_EXCEEDED').length, 1);
  } finally { f.close(); }
});

test('active reservations survive a ledger process restart and idempotent retry', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const input = { ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-00000001', riskMoney: 150 };
    const original = f.ledger.reserve(input);
    f.closeLedger();
    const restarted = openRiskLedger(f.path, { clock: () => f.base.snapshotAtMs });
    try {
      const retry = restarted.reserve(input);
      assert.equal(retry.duplicate, true);
      assert.equal(retry.reservationId, original.reservationId);
      expectCode(() => restarted.reserve({ ...f.base, instanceId: 'terminal-b',
        idempotencyKey: 'entry-00000002', riskMoney: 60 }), 'ACCOUNT_RISK_BUDGET_EXCEEDED');
    } finally { restarted.close(); }
  } finally { f.close(); }
});

test('terminal recovery distinguishes an exact completed reservation from a key conflict', () => {
  const f = fixture({ reservationTtlMs: 5000 });
  try {
    f.ledger.reconcile(f.base);
    const input = { ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-recovery-0001', riskMoney: 100 };
    f.ledger.reserve(input);
    f.setNow(f.base.snapshotAtMs + 6000);
    f.ledger.reconcile({ ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-recovery-0002', existingRiskMoney: 0 });
    expectCode(() => f.ledger.reserve(input), 'IDEMPOTENCY_KEY_ALREADY_USED');
    expectCode(() => f.ledger.reserve({ ...input, riskMoney: 99 }), 'IDEMPOTENCY_KEY_CONFLICT');
    expectCode(() => f.ledger.reserve({ ...input, instanceId: 'terminal-b' }), 'IDEMPOTENCY_KEY_CONFLICT');
  } finally { f.close(); }
});

test('crash before reservation leaves no server-side reservation to recover', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const next = f.ledger.reserve({ ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-pre-crash-0001', riskMoney: 100 });
    assert.equal(next.duplicate, false);
    assert.ok(next.reservationId);
  } finally { f.close(); }
});

test('crash after commit but before response replays the same active reservation', () => {
  const f = fixture();
  try {
    f.ledger.reconcile(f.base);
    const request = { ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-post-commit-0001', riskMoney: 100 };
    const committed = f.ledger.reserve(request);
    const recovered = f.ledger.reserve(request);
    assert.equal(recovered.duplicate, true);
    assert.equal(recovered.reservationId, committed.reservationId);
  } finally { f.close(); }
});

test('crash after broker submission with no fill releases only after expiry and fresh empty snapshot', () => {
  const f = fixture({ reservationTtlMs: 5000 });
  try {
    f.ledger.reconcile(f.base);
    const request = { ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-after-submit-0001', riskMoney: 100 };
    const committed = f.ledger.reserve(request);
    f.setNow(f.base.snapshotAtMs + 6000);
    const reconciled = f.ledger.reconcile({
      ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-no-fill-0002', existingRiskMoney: 0,
    });
    assert.equal(reconciled.brokerRiskMoney, 0);
    expectCode(() => f.ledger.reserve(request), 'IDEMPOTENCY_KEY_ALREADY_USED');
    const next = f.ledger.reserve({ ...f.base,
      snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-no-fill-0002',
      instanceId: 'terminal-b', idempotencyKey: 'entry-after-recovery-0001',
      riskMoney: 190,
    });
    assert.equal(next.ok, true);
    assert.ok(committed.reservationId);
  } finally { f.close(); }
});

test('crash after fill is reconciled into broker exposure before reservation is consumed', () => {
  const f = fixture({ reservationTtlMs: 5000 });
  try {
    f.ledger.reconcile(f.base);
    const request = { ...f.base, instanceId: 'terminal-a',
      idempotencyKey: 'entry-after-fill-0001', riskMoney: 100 };
    f.ledger.reserve(request);
    f.setNow(f.base.snapshotAtMs + 6000);
    const snapshot = { ...f.base, snapshotAtMs: f.base.snapshotAtMs + 6000,
      snapshotId: 'snapshot-after-fill-0002', existingRiskMoney: 100 };
    const reconciled = f.ledger.reconcile(snapshot);
    assert.equal(reconciled.brokerRiskMoney, 100);
    expectCode(() => f.ledger.reserve(request), 'IDEMPOTENCY_KEY_ALREADY_USED');
    expectCode(() => f.ledger.reserve({ ...snapshot, instanceId: 'terminal-b',
      idempotencyKey: 'entry-over-cap-0001', riskMoney: 101 }), 'ACCOUNT_RISK_BUDGET_EXCEEDED');
  } finally { f.close(); }
});

