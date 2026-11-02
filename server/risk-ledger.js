import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { isAbsolute } from 'node:path';

export class RiskLedgerError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function fail(status, code, message) {
  throw new RiskLedgerError(status, code, message);
}

function finiteNumber(value, name, { min = 0, exclusive = false } = {}) {
  if (typeof value !== 'number' || !Number.isFinite(value) ||
      (exclusive ? value <= min : value < min)) {
    fail(400, 'INVALID_' + name.toUpperCase(), `${name} must be a finite number ${exclusive ? 'greater than' : 'at least'} ${min}.`);
  }
  return value;
}

function accountIdentity(input) {
  const login = String(input?.login ?? '').trim();
  const server = String(input?.server ?? '').trim();
  if (!/^\d{1,24}$/.test(login) || !server || server.length > 128) {
    fail(400, 'INVALID_ACCOUNT_IDENTITY', 'A numeric MT5 login and broker server name are required.');
  }
  return { login, server, accountKey: `${login}@${server.toLowerCase()}` };
}

function snapshotFields(input, now, maxAgeMs) {
  const equity = finiteNumber(input?.equity, 'equity', { min: 0, exclusive: true });
  const brokerRiskMoney = finiteNumber(input?.existingRiskMoney, 'existingRiskMoney');
  const snapshotAtMs = finiteNumber(input?.snapshotAtMs, 'snapshotAtMs', { min: 0, exclusive: true });
  const snapshotId = String(input?.snapshotId ?? '').trim();
  if (!snapshotId || snapshotId.length > 160) {
    fail(400, 'INVALID_SNAPSHOT_ID', 'A non-empty snapshotId of at most 160 characters is required.');
  }
  if (snapshotAtMs > now + 5000 || now - snapshotAtMs > maxAgeMs) {
    fail(409, 'STALE_BROKER_SNAPSHOT', 'Broker exposure snapshot is stale or has a future timestamp.');
  }
  return {
    equity,
    brokerRiskMoney,
    hardCapMoney: equity * 0.02,
    snapshotAtMs,
    snapshotId,
  };
}

function transaction(db, callback) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = callback();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
}

export function openRiskLedger(path, {
  clock = () => Date.now(),
  maxSnapshotAgeMs = 15000,
  reservationTtlMs = 60000,
} = {}) {
  if (typeof path !== 'string' || !path || path === ':memory:' || !isAbsolute(path)) {
    throw new Error('RISK_LEDGER_PATH must be an absolute path to a persistent SQLite file, not an in-memory or relative database.');
  }
  if (!Number.isInteger(maxSnapshotAgeMs) || maxSnapshotAgeMs < 1000 ||
      !Number.isInteger(reservationTtlMs) || reservationTtlMs < 5000) {
    throw new Error('Invalid risk ledger timing configuration.');
  }

  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;');
  db.exec(`
    CREATE TABLE IF NOT EXISTS risk_account_snapshots (
      account_key TEXT PRIMARY KEY,
      login TEXT NOT NULL,
      server TEXT NOT NULL,
      equity REAL NOT NULL CHECK (equity > 0),
      broker_risk_money REAL NOT NULL CHECK (broker_risk_money >= 0),
      hard_cap_money REAL NOT NULL CHECK (hard_cap_money >= 0),
      snapshot_at_ms INTEGER NOT NULL,
      snapshot_id TEXT NOT NULL,
      updated_at_ms INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS risk_reservations (
      reservation_id TEXT PRIMARY KEY,
      account_key TEXT NOT NULL REFERENCES risk_account_snapshots(account_key),
      instance_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      risk_money REAL NOT NULL CHECK (risk_money > 0),
      status TEXT NOT NULL CHECK (status IN ('active','released','settled','expired')),
      expires_at_ms INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      UNIQUE (account_key, idempotency_key)
    );
    CREATE INDEX IF NOT EXISTS idx_risk_reservations_active
      ON risk_reservations(account_key, status, expires_at_ms);
  `);

  const getSnapshot = db.prepare('SELECT * FROM risk_account_snapshots WHERE account_key = ?');
  const insertSnapshot = db.prepare(`
    INSERT INTO risk_account_snapshots
      (account_key, login, server, equity, broker_risk_money, hard_cap_money, snapshot_at_ms, snapshot_id, updated_at_ms)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(account_key) DO UPDATE SET
      login=excluded.login, server=excluded.server, equity=excluded.equity,
      broker_risk_money=excluded.broker_risk_money, hard_cap_money=excluded.hard_cap_money,
      snapshot_at_ms=excluded.snapshot_at_ms, snapshot_id=excluded.snapshot_id,
      updated_at_ms=excluded.updated_at_ms
  `);

  function storeSnapshot(identity, input, now) {
    const fields = snapshotFields(input, now, maxSnapshotAgeMs);
    const previous = getSnapshot.get(identity.accountKey);
    if (previous && fields.snapshotAtMs <= previous.snapshot_at_ms) {
      if (fields.snapshotId === previous.snapshot_id &&
          fields.equity === previous.equity &&
          fields.brokerRiskMoney === previous.broker_risk_money) {
        return { ...fields, duplicate: true };
      }
      fail(409, 'OUT_OF_ORDER_SNAPSHOT', 'Snapshot is not newer than the last accepted broker snapshot.');
    }
    insertSnapshot.run(identity.accountKey, identity.login, identity.server,
      fields.equity, fields.brokerRiskMoney, fields.hardCapMoney,
      fields.snapshotAtMs, fields.snapshotId, now);
    return { ...fields, duplicate: false };
  }

  function reconcile(input) {
    const now = clock();
    const identity = accountIdentity(input);
    return transaction(db, () => {
      const snapshot = storeSnapshot(identity, input, now);
      return {
        ok: true, accountKey: identity.accountKey, snapshotId: snapshot.snapshotId,
        equity: snapshot.equity, brokerRiskMoney: snapshot.brokerRiskMoney,
        hardCapMoney: snapshot.hardCapMoney,
        withinCap: snapshot.brokerRiskMoney <= snapshot.hardCapMoney + 0.01,
        duplicate: snapshot.duplicate,
      };
    });
  }

  function reserve(input) {
    const now = clock();
    const identity = accountIdentity(input);
    const instanceId = String(input?.instanceId ?? '').trim();
    const idempotencyKey = String(input?.idempotencyKey ?? '').trim();
    const riskMoney = finiteNumber(input?.riskMoney, 'riskMoney', { min: 0, exclusive: true });
    if (!instanceId || instanceId.length > 128 ||
        !/^[A-Za-z0-9._:-]{8,128}$/.test(idempotencyKey)) {
      fail(400, 'INVALID_RESERVATION_IDENTITY', 'instanceId and a unique idempotencyKey are required.');
    }

    return transaction(db, () => {
      db.prepare(`UPDATE risk_reservations SET status='expired', updated_at_ms=?
        WHERE account_key=? AND status='active' AND expires_at_ms<=?`).run(now, identity.accountKey, now);

      const snapshot = getSnapshot.get(identity.accountKey);
      if (!snapshot) fail(409, 'NO_BROKER_SNAPSHOT', 'No broker exposure snapshot exists for this account.');
      if (now - snapshot.snapshot_at_ms > maxSnapshotAgeMs || snapshot.snapshot_at_ms > now + 5000) {
        fail(409, 'STALE_BROKER_SNAPSHOT', 'A fresh broker exposure snapshot is required before reserving risk.');
      }

      const prior = db.prepare('SELECT * FROM risk_reservations WHERE account_key=? AND idempotency_key=?')
        .get(identity.accountKey, idempotencyKey);
      if (prior) {
        if (prior.status === 'active' && prior.instance_id === instanceId &&
            Math.abs(prior.risk_money - riskMoney) < 0.000001 && prior.expires_at_ms > now) {
          return { ok: true, duplicate: true, reservationId: prior.reservation_id,
            expiresAtMs: prior.expires_at_ms, reservedRiskMoney: prior.risk_money };
        }
        fail(409, 'IDEMPOTENCY_KEY_ALREADY_USED', 'This idempotency key has already been consumed or belongs to another request.');
      }

      const pending = db.prepare(`SELECT COALESCE(SUM(risk_money),0) AS total
        FROM risk_reservations WHERE account_key=? AND status='active' AND expires_at_ms>?`)
        .get(identity.accountKey, now).total;
      const totalAfterReservation = snapshot.broker_risk_money + pending + riskMoney;
      if (snapshot.broker_risk_money > snapshot.hard_cap_money + 0.01 ||
          totalAfterReservation > snapshot.hard_cap_money + 0.01) {
        fail(409, 'ACCOUNT_RISK_BUDGET_EXCEEDED', 'Broker exposure plus active reservations would exceed the immutable 2% equity risk ceiling.');
      }

      const reservationId = randomUUID();
      const expiresAtMs = now + reservationTtlMs;
      db.prepare(`INSERT INTO risk_reservations
        (reservation_id,account_key,instance_id,idempotency_key,risk_money,status,expires_at_ms,created_at_ms,updated_at_ms)
        VALUES (?,?,?,?,?,'active',?,?,?)`).run(reservationId, identity.accountKey,
          instanceId, idempotencyKey, riskMoney, expiresAtMs, now, now);
      return { ok: true, duplicate: false, reservationId, expiresAtMs,
        reservedRiskMoney: riskMoney, totalReservedRiskMoney: pending + riskMoney,
        brokerRiskMoney: snapshot.broker_risk_money, hardCapMoney: snapshot.hard_cap_money };
    });
  }

  function release(input) {
    const now = clock();
    const identity = accountIdentity(input);
    const reservationId = String(input?.reservationId ?? '').trim();
    if (!reservationId) fail(400, 'INVALID_RESERVATION_ID', 'reservationId is required.');
    return transaction(db, () => {
      const reservation = db.prepare('SELECT * FROM risk_reservations WHERE reservation_id=? AND account_key=?')
        .get(reservationId, identity.accountKey);
      if (!reservation) fail(404, 'RESERVATION_NOT_FOUND', 'Reservation was not found for this account.');
      if (reservation.status === 'released' || reservation.status === 'expired') {
        return { ok: true, released: false, status: reservation.status };
      }
      if (reservation.status !== 'active') fail(409, 'RESERVATION_ALREADY_SETTLED', 'A settled reservation cannot be released.');
      db.prepare(`UPDATE risk_reservations SET status='released',updated_at_ms=?
        WHERE reservation_id=? AND status='active'`).run(now, reservationId);
      return { ok: true, released: true, status: 'released' };
    });
  }

  function settle(input) {
    const now = clock();
    const identity = accountIdentity(input);
    const reservationId = String(input?.reservationId ?? '').trim();
    if (!reservationId) fail(400, 'INVALID_RESERVATION_ID', 'reservationId is required.');
    return transaction(db, () => {
      const reservation = db.prepare('SELECT * FROM risk_reservations WHERE reservation_id=? AND account_key=?')
        .get(reservationId, identity.accountKey);
      if (!reservation || reservation.status !== 'active' || reservation.expires_at_ms <= now) {
        fail(409, 'RESERVATION_NOT_ACTIVE', 'Only an active, unexpired reservation can be settled.');
      }
      const snapshot = storeSnapshot(identity, input, now);
      if (snapshot.duplicate) {
        fail(409, 'POST_FILL_SNAPSHOT_NOT_NEW', 'Settlement requires a new broker snapshot captured after the order outcome.');
      }
      db.prepare(`UPDATE risk_reservations SET status='settled',updated_at_ms=?
        WHERE reservation_id=? AND status='active'`).run(now, reservationId);
      return { ok: true, settled: true, withinCap: snapshot.brokerRiskMoney <= snapshot.hardCapMoney + 0.01,
        brokerRiskMoney: snapshot.brokerRiskMoney, hardCapMoney: snapshot.hardCapMoney,
        remainingRiskMoney: Math.max(0, snapshot.hardCapMoney - snapshot.brokerRiskMoney) };
    });
  }

  return {
    reconcile, reserve, release, settle,
    close() { db.close(); },
  };
}
