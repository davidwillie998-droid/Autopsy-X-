import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';

const SERVER_PATH = new URL('../server.js', import.meta.url);

async function reservePort() {
  const probe = createServer();
  probe.listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const { port } = probe.address();
  await new Promise((resolve, reject) => probe.close(error => error ? reject(error) : resolve()));
  return port;
}

async function startBridge({ bridgeKey }) {
  const port = await reservePort();
  const child = spawn(process.execPath, [SERVER_PATH.pathname], {
    env: {
      ...process.env,
      PORT: String(port),
      HOST: '127.0.0.1',
      BRIDGE_KEY: bridgeKey,
      ANTHROPIC_API_KEY: '',
      RISK_COORDINATOR_KEY: '',
      RISK_LEDGER_PATH: '',
      RISK_LEDGER_PERSISTENCE_ACK: '',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk.toString(); });
  child.stderr.on('data', chunk => { output += chunk.toString(); });
  const baseUrl = `http://127.0.0.1:${port}`;

  try {
    let ready = false;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      if (child.exitCode !== null) throw new Error(`Bridge exited before becoming ready.\n${output}`);
      try {
        const response = await fetch(`${baseUrl}/health`);
        if (response.ok) { ready = true; break; }
      } catch { /* Server is still starting. */ }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (!ready) throw new Error(`Bridge did not become ready.\n${output}`);
    return {
      baseUrl,
      async close() {
        await new Promise(resolve => {
          const timeout = setTimeout(() => {
            child.kill('SIGKILL');
            resolve();
          }, 2000);
          child.once('exit', () => {
            clearTimeout(timeout);
            resolve();
          });
          child.kill('SIGTERM');
        });
      },
    };
  } catch (error) {
    child.kill('SIGKILL');
    throw error;
  }
}

test('protected ingest endpoint fails closed when BRIDGE_KEY is missing', async () => {
  const bridge = await startBridge({ bridgeKey: '' });
  try {
    const response = await fetch(`${bridge.baseUrl}/ingest/tick`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ symbol: 'XAUUSD', bid: 2000, ask: 2001 }),
    });
    assert.equal(response.status, 503);
  } finally {
    await bridge.close();
  }
});

test('protected ingest endpoint rejects an invalid bridge key', async () => {
  const bridge = await startBridge({ bridgeKey: 'test-bridge-secret-32-characters-minimum' });
  try {
    const response = await fetch(`${bridge.baseUrl}/ingest/tick`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-bridge-key': 'wrong-key' },
      body: JSON.stringify({ symbol: 'XAUUSD', bid: 2000, ask: 2001 }),
    });
    assert.equal(response.status, 401);
  } finally {
    await bridge.close();
  }
});

test('protected ingest endpoint accepts the configured bridge key', async () => {
  const key = 'test-bridge-secret-32-characters-minimum';
  const bridge = await startBridge({ bridgeKey: key });
  try {
    const response = await fetch(`${bridge.baseUrl}/ingest/tick`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-bridge-key': key },
      body: JSON.stringify({ symbol: 'XAUUSD', bid: 2000, ask: 2001 }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
  } finally {
    await bridge.close();
  }
});

test('/analyze rejects a missing key before attempting an upstream API call', async () => {
  const key = 'test-bridge-secret-32-characters-minimum';
  const bridge = await startBridge({ bridgeKey: key });
  try {
    const response = await fetch(`${bridge.baseUrl}/analyze`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ system: 'test', prompt: 'test' }),
    });
    assert.equal(response.status, 401);
  } finally {
    await bridge.close();
  }
});
test('/analyze accepts the configured key before checking upstream credentials', async () => {
  const key = 'test-bridge-secret-32-characters-minimum';
  const bridge = await startBridge({ bridgeKey: key });
  try {
    const response = await fetch(`${bridge.baseUrl}/analyze`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-bridge-key': key },
      body: JSON.stringify({ system: 'test', prompt: 'test' }),
    });
    // The test process deliberately has no Anthropic key. Reaching this
    // response proves bridge authentication passed before upstream handling.
    assert.equal(response.status, 500);
    assert.match((await response.json()).error, /no ANTHROPIC_API_KEY/i);
  } finally {
    await bridge.close();
  }
});
test('/state rejects requests without the bridge key', async () => {
  const key = 'test-bridge-secret-32-characters-minimum';
  const bridge = await startBridge({ bridgeKey: key });
  try {
    const response = await fetch(`${bridge.baseUrl}/state`);
    assert.equal(response.status, 401);
  } finally {
    await bridge.close();
  }
});

test('/state returns account state only with the configured bridge key', async () => {
  const key = 'test-bridge-secret-32-characters-minimum';
  const bridge = await startBridge({ bridgeKey: key });
  try {
    const response = await fetch(`${bridge.baseUrl}/state`, {
      headers: { 'x-bridge-key': key },
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      symbols: {},
      account: null,
      staleness_ms: null,
    });
  } finally {
    await bridge.close();
  }
});

test('dashboard state polling CORS preflight permits the bridge-key header', async () => {
  const bridge = await startBridge({ bridgeKey: 'test-bridge-secret-32-characters-minimum' });
  try {
    const response = await fetch(`${bridge.baseUrl}/state`, {
      method: 'OPTIONS',
      headers: {
        origin: 'https://autopsy-x-dashboard.onrender.com',
        'access-control-request-method': 'GET',
        'access-control-request-headers': 'x-bridge-key',
      },
    });
    assert.equal(response.status, 204);
    assert.equal(response.headers.get('access-control-allow-origin'), 'https://autopsy-x-dashboard.onrender.com');
    assert.match(response.headers.get('access-control-allow-headers') || '', /x-bridge-key/i);
    assert.match(response.headers.get('access-control-allow-methods') || '', /GET/i);
  } finally {
    await bridge.close();
  }
});
