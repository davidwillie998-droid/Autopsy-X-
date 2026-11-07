import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer, request as httpRequest } from 'node:http';
import { createServer as createNetServer } from 'node:net';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';

async function freePort() {
  const server = createNetServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return port;
}

async function waitForHealth(url, child) {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`Risk bridge exited early with code ${child.exitCode}`);
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('Risk bridge did not become healthy within six seconds.');
}

function startResponseDroppingProxy(upstreamPort) {
  let dropNextReservationResponse = true;
  let droppedBackendResponse = null;
  const proxy = createServer((incoming, outgoing) => {
    const upstream = httpRequest({
      hostname: '127.0.0.1',
      port: upstreamPort,
      path: incoming.url,
      method: incoming.method,
      headers: { ...incoming.headers, host: `127.0.0.1:${upstreamPort}` },
    }, upstreamResponse => {
      const chunks = [];
      upstreamResponse.on('data', chunk => chunks.push(chunk));
      upstreamResponse.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        if (incoming.url === '/risk/reserve' && dropNextReservationResponse) {
          dropNextReservationResponse = false;
          droppedBackendResponse = {
            statusCode: upstreamResponse.statusCode,
            body,
          };
          outgoing.destroy();
          return;
        }
        outgoing.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        outgoing.end(body);
      });
    });
    upstream.on('error', error => {
      if (!outgoing.destroyed) {
        outgoing.writeHead(502, { 'content-type': 'application/json' });
        outgoing.end(JSON.stringify({ error: error.message }));
      }
    });
    incoming.pipe(upstream);
  });
  return {
    proxy,
    getDroppedBackendResponse: () => droppedBackendResponse,
  };
}

test('HTTP lost response after committed reservation returns the same reservation on retry', {
  timeout: 20000,
}, async t => {
  const tempDir = mkdtempSync(join(tmpdir(), 'flipdemon-risk-http-'));
  const ledgerPath = join(tempDir, 'risk-ledger.sqlite');
  const bridgePort = await freePort();
  const coordinatorKey = 'integration-test-risk-coordinator-key-0123456789';
  const bridgeOptions = {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      ANTHROPIC_API_KEY: '',
      BRIDGE_KEY: 'integration-test-bridge-key',
      HOST: '127.0.0.1',
      PORT: String(bridgePort),
      RISK_COORDINATOR_KEY: coordinatorKey,
      RISK_LEDGER_PATH: ledgerPath,
      RISK_LEDGER_PERSISTENCE_ACK: 'CONFIRMED',
      RISK_RESERVATION_TTL_MS: '60000',
      RISK_MAX_SNAPSHOT_AGE_MS: '15000',
    },
    stdio: 'ignore',
  };
  let bridge = spawn(process.execPath, ['server.js'], bridgeOptions);
  let proxyServer;
  t.after(async () => {
    if (proxyServer?.listening) {
      await new Promise(resolve => proxyServer.close(resolve));
    }
    if (bridge.exitCode === null) {
      bridge.kill('SIGTERM');
      await Promise.race([
        once(bridge, 'exit'),
        new Promise(resolve => setTimeout(resolve, 3000)),
      ]);
    }
    rmSync(tempDir, { recursive: true, force: true });
  });

  const bridgeUrl = `http://127.0.0.1:${bridgePort}`;
  await waitForHealth(`${bridgeUrl}/health`, bridge);

  const { proxy, getDroppedBackendResponse } = startResponseDroppingProxy(bridgePort);
  proxyServer = proxy;
  proxy.listen(0, '127.0.0.1');
  await once(proxy, 'listening');
  const proxyUrl = `http://127.0.0.1:${proxy.address().port}`;
  const headers = {
    'content-type': 'application/json',
    'x-risk-coordinator-key': coordinatorKey,
  };

  const snapshot = {
    login: '7654321',
    server: 'Integration-Test-Broker',
    equity: 10000,
    existingRiskMoney: 0,
    snapshotAtMs: Date.now(),
    snapshotId: 'http-snapshot-0001',
  };
  const reconcileResponse = await fetch(`${proxyUrl}/risk/reconcile`, {
    method: 'POST',
    headers,
    body: JSON.stringify(snapshot),
  });
  assert.equal(reconcileResponse.status, 200);
  assert.equal((await reconcileResponse.json()).withinCap, true);

  const reservationRequest = {
    login: snapshot.login,
    server: snapshot.server,
    instanceId: 'terminal-http-test',
    idempotencyKey: 'http-lost-response-0001',
    riskMoney: 150,
  };

  await assert.rejects(
    fetch(`${proxyUrl}/risk/reserve`, {
      method: 'POST',
      headers,
      body: JSON.stringify(reservationRequest),
    }),
    /fetch failed|socket|closed|terminated/i,
    'the proxy must drop the client response after the bridge has committed it',
  );

  const committed = getDroppedBackendResponse();
  assert.ok(committed, 'the proxy must observe the completed backend response before dropping it');
  assert.equal(committed.statusCode, 200);
  const committedBody = JSON.parse(committed.body);
  assert.equal(committedBody.ok, true);
  assert.equal(committedBody.duplicate, false);

  // Simulate the harder failure: the reservation committed to SQLite, the
  // client lost the response, and the bridge process then restarted before retry.
  bridge.kill('SIGTERM');
  await once(bridge, 'exit');
  bridge = spawn(process.execPath, ['server.js'], bridgeOptions);
  await waitForHealth(`${bridgeUrl}/health`, bridge);

  const retryResponse = await fetch(`${proxyUrl}/risk/reserve`, {
    method: 'POST',
    headers,
    body: JSON.stringify(reservationRequest),
  });
  assert.equal(retryResponse.status, 200);
  const retry = await retryResponse.json();
  assert.equal(retry.ok, true);
  assert.equal(retry.duplicate, true);
  assert.equal(retry.reservationId, committedBody.reservationId);

  const oversubscriptionResponse = await fetch(`${proxyUrl}/risk/reserve`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      ...reservationRequest,
      idempotencyKey: 'http-over-cap-000001',
      riskMoney: 60,
    }),
  });
  assert.equal(oversubscriptionResponse.status, 409);
  const oversubscription = await oversubscriptionResponse.json();
  assert.equal(oversubscription.code, 'ACCOUNT_RISK_BUDGET_EXCEEDED');
});
