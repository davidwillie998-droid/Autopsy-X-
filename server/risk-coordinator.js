import { createHash } from 'node:crypto';

const RESERVATION_SCRIPT = String.raw`
local raw = redis.call('GET', KEYS[1])
local state = raw and cjson.decode(raw) or {
  equity = 0, actualRiskMoney = 0, snapshotAt = 0,
  reservations = {}, requests = {}
}
local action = ARGV[1]
local p = cjson.decode(ARGV[2])
local now = tonumber(p.serverNow)
local function save()
  redis.call('SET', KEYS[1], cjson.encode(state))
end
local function validSnapshot()
  return p.snapshotAt and p.snapshotAt > 0
    and p.snapshotAt <= now + 2000
    and now - p.snapshotAt <= p.maxSnapshotAgeMs
    and p.equity and p.equity > 0
    and p.actualRiskMoney and p.actualRiskMoney >= 0
end
local function totalReserved()
  local total = 0
  for _, r in pairs(state.reservations) do
    if r.status == 'pending' or r.status == 'unknown' then
      total = total + r.riskMoney
      if r.status == 'pending' and r.expiresAt <= now then
        r.status = 'unknown'
      end
    end
  end
  return total
end
if action == 'reserve' then
  if state.requests[p.requestId] then
    return cjson.encode({ok=true, duplicate=true, reservation=state.requests[p.requestId]})
  end
  if not validSnapshot() then
    return cjson.encode({ok=false, code='STALE_OR_INVALID_BROKER_SNAPSHOT'})
  end
  if p.snapshotAt < (state.snapshotAt or 0) then
    return cjson.encode({ok=false, code='OLDER_ACCOUNT_SNAPSHOT_REJECTED'})
  end
  state.equity = p.equity
  state.actualRiskMoney = p.actualRiskMoney
  state.snapshotAt = p.snapshotAt
  local reserved = totalReserved()
  local cap = p.equity * p.capPercent / 100
  if p.capPercent <= 0 or p.capPercent > 2 then
    return cjson.encode({ok=false, code='INVALID_HARD_CAP'})
  end
  if p.proposedRiskMoney <= 0 or p.proposedRiskMoney ~= p.proposedRiskMoney then
    return cjson.encode({ok=false, code='INVALID_PROPOSED_RISK'})
  end
  if p.actualRiskMoney + reserved + p.proposedRiskMoney > cap + 0.000001 then
    save()
    return cjson.encode({ok=false, code='ACCOUNT_RISK_BUDGET_EXCEEDED',
      actualRiskMoney=p.actualRiskMoney, reservedRiskMoney=reserved, capMoney=cap})
  end
  local r = {requestId=p.requestId, clientId=p.clientId,
    riskMoney=p.proposedRiskMoney, status='pending',
    createdAt=now, expiresAt=now+p.leaseMs}
  state.reservations[p.requestId] = r
  state.requests[p.requestId] = r
  save()
  return cjson.encode({ok=true, duplicate=false, reservation=r,
    actualRiskMoney=p.actualRiskMoney, reservedRiskMoney=reserved,
    remainingRiskMoney=cap-p.actualRiskMoney-reserved-p.proposedRiskMoney})
elseif action == 'reconcile' then
  if not validSnapshot() then
    return cjson.encode({ok=false, code='STALE_OR_INVALID_BROKER_SNAPSHOT'})
  end
  if p.snapshotAt < (state.snapshotAt or 0) then
    return cjson.encode({ok=false, code='OLDER_ACCOUNT_SNAPSHOT_REJECTED'})
  end
  state.equity = p.equity
  state.actualRiskMoney = p.actualRiskMoney
  state.snapshotAt = p.snapshotAt
  for _, requestId in ipairs(p.reflectedRequestIds or {}) do
    state.reservations[requestId] = nil
  end
  local reserved = totalReserved()
  save()
  return cjson.encode({ok=true, actualRiskMoney=state.actualRiskMoney,
    reservedRiskMoney=reserved, totalRiskMoney=state.actualRiskMoney+reserved,
    snapshotAt=state.snapshotAt})
elseif action == 'release' then
  local r = state.reservations[p.requestId]
  if not r then return cjson.encode({ok=true, alreadyReleased=true}) end
  if p.outcome ~= 'no_fill_confirmed' or not validSnapshot()
    or p.snapshotAt < r.createdAt or p.snapshotAt < (state.snapshotAt or 0) then
    return cjson.encode({ok=false, code='RELEASE_REQUIRES_FRESH_CONFIRMED_NO_FILL'})
  end
  state.equity = p.equity
  state.actualRiskMoney = p.actualRiskMoney
  state.snapshotAt = p.snapshotAt
  state.reservations[p.requestId] = nil
  state.requests[p.requestId] = nil
  save()
  return cjson.encode({ok=true, released=true})
end
return cjson.encode({ok=false, code='UNKNOWN_ACTION'})
`;

function accountKey(brokerServer, login) {
  const digest = createHash('sha256').update(`${brokerServer.trim().toLowerCase()}|${String(login)}`).digest('hex');
  return `flipdemon:risk:v1:${digest}`;
}

function finiteNonNegative(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}

export function validateRiskPayload(body, action, now = Date.now()) {
  if (!body || typeof body !== 'object') return { error: 'JSON body required.' };
  const { brokerServer, login, snapshotAt, equity, actualRiskMoney, clientId } = body;
  if (typeof brokerServer !== 'string' || !brokerServer.trim() || brokerServer.length > 160 ||
      !/^[0-9]{1,24}$/.test(String(login)) ||
      typeof clientId !== 'string' || !clientId.trim() || clientId.length > 128) {
    return { error: 'brokerServer, numeric login and clientId are required.' };
  }
  if (!Number.isSafeInteger(snapshotAt) || snapshotAt <= 0 ||
      snapshotAt > now + 2000 || now - snapshotAt > 5000 ||
      !finiteNonNegative(equity) || equity <= 0 ||
      !finiteNonNegative(actualRiskMoney)) {
    return { error: 'Fresh broker snapshot, positive equity and non-negative actual risk are required.' };
  }
  if (action === 'reserve') {
    if (typeof body.requestId !== 'string' || !/^[a-zA-Z0-9_-]{16,128}$/.test(body.requestId) ||
        !finiteNonNegative(body.proposedRiskMoney) || body.proposedRiskMoney <= 0 ||
        !Number.isFinite(body.capPercent) || body.capPercent <= 0 || body.capPercent > 2) {
      return { error: 'Valid requestId, proposedRiskMoney and capPercent (0, 2] are required.' };
    }
  }
  if (action === 'release' && typeof body.requestId !== 'string') return { error: 'requestId required.' };
  if (action === 'reconcile' && body.reflectedRequestIds !== undefined &&
      (!Array.isArray(body.reflectedRequestIds) ||
       body.reflectedRequestIds.some(x => typeof x !== 'string'))) {
    return { error: 'reflectedRequestIds must be an array of request IDs.' };
  }
  return { value: { ...body, serverNow: now, maxSnapshotAgeMs: 5000,
    leaseMs: Math.min(Math.max(Number(body.leaseMs) || 15000, 5000), 60000) } };
}

export function createRiskCoordinator({ redisUrl, redisToken, fetchImpl = fetch }) {
  if (!redisUrl || !redisToken) throw new Error('UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN are required.');
  const base = redisUrl.replace(/\/+$/, '');
  return async function execute(action, payload) {
    const key = accountKey(payload.brokerServer, payload.login);
    const response = await fetchImpl(base, {
      method: 'POST',
      headers: { Authorization: `Bearer ${redisToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(['EVAL', RESERVATION_SCRIPT, '1', key, action, JSON.stringify(payload)]),
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) throw new Error(`Risk store HTTP ${response.status}`);
    const data = await response.json();
    if (data.error) throw new Error('Risk store command failed.');
    if (typeof data.result !== 'string') throw new Error('Invalid risk store response.');
    return JSON.parse(data.result);
  };
}
