// Checks that need a Worker actually running.
//
//   Terminal 1:  npm run api
//   Terminal 2:  npm test
//
// If no local Worker is answering, every test here is skipped rather than
// failed, so `npm test` still works on its own.
//
// This only ever talks to 127.0.0.1 and the disposable local database under
// .wrangler/. Never point it at the deployed Worker.

import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const run = promisify(execFile);

const API = process.env.NYC26_API || 'http://127.0.0.1:8787';
const ORIGIN = 'http://127.0.0.1:5173';
const PIN = process.env.NYC26_PIN || '0000';

const live = await fetch(API + '/health')
  .then((r) => r.ok)
  .catch(() => false);
const needsWorker = { skip: live ? false : 'no local Worker on ' + API + ' (run: npm run api)' };

/**
 * Wipes the wrong-PIN lockout in the local database. Without this, the lockout
 * test leaves the door shut for fifteen minutes and the next `npm test` fails
 * for no good reason. Local database only — never the deployed one.
 */
async function clearLockout() {
  if (!live) return;
  // fileURLToPath, not URL.pathname: this folder's path contains a space.
  const cwd = fileURLToPath(new URL('..', import.meta.url));
  try {
    await run(
      'npx',
      ['wrangler', 'd1', 'execute', 'nyc26', '--local', '--persist-to', '.wrangler/state',
       '--config', 'worker/wrangler.toml', '--command', 'DELETE FROM pin_attempts'],
      { cwd },
    );
  } catch (e) {
    // Say so rather than letting the next run fail for a stale lockout.
    console.error('could not clear the PIN lockout:', e.message);
  }
}

before(clearLockout);
after(clearLockout);

const call = (path, init = {}) =>
  fetch(API + path, { ...init, headers: { Origin: ORIGIN, ...init.headers } });

async function token() {
  // Clear any lockout left by the wrong-PIN test before asking for a token.
  const response = await call('/session', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pin: PIN }),
  });
  const body = await response.json();
  assert.ok(body.token, 'the local PIN should be accepted: ' + (body.error || ''));
  return { Authorization: 'Bearer ' + body.token };
}

test('nothing private is readable without a token', needsWorker, async () => {
  for (const [path, init] of [
    ['/trip', {}],
    ['/places?q=strand', {}],
    ['/trip', { method: 'PUT', body: '{}' }],
  ]) {
    const response = await call(path, init);
    assert.equal(response.status, 401, path + ' should need a token');
    const body = await response.json();
    assert.equal(body.trip, undefined);
  }
});

test('a tampered or made-up token is refused', needsWorker, async () => {
  const real = (await token()).Authorization;
  for (const value of ['Bearer nonsense', 'Bearer v1.a.b', real.slice(0, -1) + 'x', real.replace('v1.', 'v2.')]) {
    const response = await call('/trip', { headers: { Authorization: value } });
    assert.equal(response.status, 401);
  }
});

test('only the real site may call the API from a browser', needsWorker, async () => {
  const headers = await token();
  const blocked = await fetch(API + '/trip', {
    headers: { ...headers, Origin: 'https://evil.example' },
  });
  assert.equal(blocked.status, 403);

  const preflight = await fetch(API + '/trip', {
    method: 'OPTIONS',
    headers: { Origin: 'https://www.spiiira.com' },
  });
  assert.equal(preflight.status, 204);
  assert.equal(
    preflight.headers.get('access-control-allow-origin'),
    'https://www.spiiira.com',
    'the live site must be allowed',
  );
});

test('an edit saves and comes back on the next read', needsWorker, async () => {
  const headers = await token();
  const before = await (await call('/trip', { headers })).json();

  const marker = 'Checked at ' + new Date().toISOString();
  const trip = { ...before.trip, practical: { ...before.trip.practical, weather: marker } };
  const saved = await call('/trip', {
    method: 'PUT',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify({ trip, revision: before.revision }),
  });
  assert.equal(saved.status, 200);
  const savedBody = await saved.json();
  assert.equal(savedBody.revision, before.revision + 1);

  // A second, independent reader sees it: this is the cross-device promise.
  const other = await (await call('/trip', { headers: await token() })).json();
  assert.equal(other.trip.practical.weather, marker);
});

test('a stale window cannot overwrite newer edits', needsWorker, async () => {
  const headers = await token();
  const loaded = await (await call('/trip', { headers })).json();

  const save = (revision, note) =>
    call('/trip', {
      method: 'PUT',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        trip: { ...loaded.trip, practical: { ...loaded.trip.practical, bites: note } },
        revision,
      }),
    });

  const first = await save(loaded.revision, 'first window');
  assert.equal(first.status, 200);

  // The second window still believes it holds the current revision.
  const second = await save(loaded.revision, 'second window');
  assert.equal(second.status, 409);
  assert.match((await second.json()).error, /changed in another window/);

  const now = await (await call('/trip', { headers })).json();
  assert.equal(now.trip.practical.bites, 'first window', 'the first save must stand');
});

test('a malformed document is refused with a reason', needsWorker, async () => {
  const headers = await token();
  const loaded = await (await call('/trip', { headers })).json();
  const send = (trip) =>
    call('/trip', {
      method: 'PUT',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ trip, revision: loaded.revision }),
    });

  const badCategory = structuredClone(loaded.trip);
  badCategory.places[0].category = 'Nope';
  assert.equal((await send(badCategory)).status, 400);

  const badPin = structuredClone(loaded.trip);
  badPin.location = null;
  badPin.places[0].location = { lat: 51.5, lon: -0.12, address: 'London', source: 'https://www.openstreetmap.org/node/1' };
  assert.equal((await send(badPin)).status, 400);

  assert.equal(
    (
      await call('/trip', {
        method: 'PUT',
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: 'not json at all',
      })
    ).status,
    400,
  );
});

test('place search returns New York results only', needsWorker, async () => {
  const headers = await token();
  const response = await call('/places?q=' + encodeURIComponent('Grand Central Terminal'), { headers });
  assert.equal(response.status, 200);
  const { results } = await response.json();
  assert.ok(results.length > 0, 'expected at least one match');
  for (const place of results) {
    const { lat, lon, source } = place.location;
    assert.ok(lat >= 40.45 && lat <= 41, 'latitude inside NYC');
    assert.ok(lon >= -74.3 && lon <= -73.65, 'longitude inside NYC');
    assert.match(source, /^https:\/\/www\.openstreetmap\.org\/(node|way|relation)\/\d+$/);
  }

  assert.equal((await call('/places?q=a', { headers })).status, 400, 'one letter is too short');
});

test('wrong PINs are counted and eventually locked out', needsWorker, async () => {
  const wrong = () =>
    call('/session', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin: 'definitely-not-the-pin' }),
    });

  const first = await wrong();
  assert.equal(first.status, 401);
  assert.match((await first.json()).error, /tries left/);

  let locked = false;
  for (let i = 0; i < 6 && !locked; i++) locked = (await wrong()).status === 429;
  assert.ok(locked, 'repeated wrong PINs must lock out, or a short PIN could be guessed');

  // Even the correct PIN is refused while the lockout stands.
  const during = await call('/session', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pin: PIN }),
  });
  assert.equal(during.status, 429);
});
