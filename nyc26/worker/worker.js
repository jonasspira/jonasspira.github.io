/**
 * nyc26 API — www.spiiira.com/nyc26/
 *
 * The page itself is static and public; it is served by GitHub Pages and holds
 * no trip content. Everything private lives behind this Worker:
 *
 *   POST /session   swap the PIN for a 90-day signed token
 *   GET  /trip      read the trip document
 *   PUT  /trip      write it back, refusing stale revisions
 *   GET  /places    search NYC place names (proxied to Photon)
 *   GET  /health    is this deployed and configured? (never reports values)
 *
 * Bindings   DB              D1 database `nyc26`
 * Secrets    ACCESS_PIN      the PIN. Set in Cloudflare, never in this file.
 *            SESSION_SECRET  random string used to sign tokens.
 *
 * This file is public. It must never contain the PIN, the signing secret, or
 * any trip content. Validation below is the only authority on what may be
 * saved — the browser repeats none of it.
 */

const BUILD = '2026-10-26.2';

// The deployed Worker answers the live site and nothing else. DEV_ORIGINS adds
// local addresses during development; it is set in worker/.dev.vars, which git
// ignores, and is deliberately never set on the deployed Worker.
const SITE_ORIGIN = 'https://www.spiiira.com';

function allowedOrigins(env) {
  const extra = String(env.DEV_ORIGINS || '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  return [SITE_ORIGIN, ...extra];
}

const TRIP_ID = 'trip';
const RESEARCH_ID = 'research';

// The three sections of Jonas's travel framework. Candidates are filed under
// one of these, and nothing else is accepted.
const SECTIONS = ['Shopping', 'Food & Drink', 'Experiences'];
const VERDICTS = ['new', 'keep', 'skip'];
const DATA_VERSION = 2;
const SESSION_DAYS = 90;
const MAX_BODY = 600000;

// PIN guessing is the one real risk for a short code, so attempts are counted
// per address: five wrong tries inside fifteen minutes locks that address out
// for fifteen more.
const MAX_FAILS = 5;
const WINDOW_MS = 15 * 60 * 1000;

const CATEGORIES = ['Hotel', 'Office', 'Food', 'Shops', 'Other'];
const EMPTY = 'TO BE FILLED IN';

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin');
    const allowed = allowedOrigins(env).includes(origin) ? origin : null;

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: allowed ? 204 : 403, headers: cors(allowed) });
    }
    // A browser request from anywhere else is refused outright.
    if (origin && !allowed) return reply({ error: 'Invalid origin.' }, 403, null);

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    try {
      if (path === '/health') {
        return reply(
          {
            ok: true,
            build: BUILD,
            pin: Boolean(env.ACCESS_PIN),
            secret: Boolean(env.SESSION_SECRET),
            db: Boolean(env.DB),
          },
          200,
          allowed,
        );
      }
      if (path === '/session' && request.method === 'POST') return await session(request, env, allowed);
      if (path === '/trip' && request.method === 'GET') return await getTrip(request, env, allowed);
      if (path === '/trip' && request.method === 'PUT') return await putTrip(request, env, allowed);
      if (path === '/places' && request.method === 'GET') return await places(request, env, url, allowed);
      if (path === '/research' && request.method === 'GET') return await getResearch(request, env, allowed);
      if (path === '/research' && request.method === 'PUT') return await putResearch(request, env, allowed);
      if (path === '/intake' && request.method === 'POST') return await intake(request, env, allowed);
      return reply({ error: 'Not found.' }, 404, allowed);
    } catch {
      return reply({ error: 'Something went wrong. Please try again.' }, 503, allowed);
    }
  },
};

/* ---------------------------------------------------------------- responses */

function cors(allowed) {
  const headers = {
    'Cache-Control': 'no-store',
    Vary: 'Origin',
    'Access-Control-Allow-Methods': 'GET,PUT,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    'Access-Control-Max-Age': '86400',
  };
  if (allowed) headers['Access-Control-Allow-Origin'] = allowed;
  return headers;
}

function reply(body, status, allowed) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(allowed), 'Content-Type': 'application/json' },
  });
}

/* ------------------------------------------------------------------- tokens */

const encoder = new TextEncoder();

function b64url(bytes) {
  let binary = '';
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sign(payload, secret) {
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return b64url(await crypto.subtle.sign('HMAC', key, encoder.encode(payload)));
}

/** Compare without leaking, through timing, how much of the value matched. */
function constantTimeEqual(a, b) {
  const left = encoder.encode(String(a));
  const right = encoder.encode(String(b));
  // Always compare the same number of bytes, so length alone decides nothing.
  let diff = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  return diff === 0;
}

async function issueToken(secret) {
  const expires = Date.now() + SESSION_DAYS * 86400000;
  const payload = b64url(encoder.encode(JSON.stringify({ exp: expires })));
  return 'v1.' + payload + '.' + (await sign(payload, secret));
}

async function tokenHolder(request, env) {
  if (!env.SESSION_SECRET) return false;
  const header = request.headers.get('Authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  const parts = token.split('.');
  if (parts.length !== 3 || parts[0] !== 'v1') return false;

  const expected = await sign(parts[1], env.SESSION_SECRET);
  if (!constantTimeEqual(parts[2], expected)) return false;

  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
    return Number.isFinite(payload.exp) && payload.exp > Date.now();
  } catch {
    return false;
  }
}

async function requireToken(request, env, allowed) {
  if (await tokenHolder(request, env)) return null;
  return reply({ error: 'Enter your PIN to open the trip.' }, 401, allowed);
}

/* ------------------------------------------------------------------ the PIN */

async function session(request, env, allowed) {
  if (!env.ACCESS_PIN || !env.SESSION_SECRET) {
    return reply({ error: 'This trip is not configured yet.' }, 503, allowed);
  }

  const who = request.headers.get('CF-Connecting-IP') || 'unknown';
  const now = Date.now();
  const row = await env.DB.prepare('SELECT fails, window_start FROM pin_attempts WHERE ip = ?')
    .bind(who)
    .first();

  const fresh = row && now - row.window_start < WINDOW_MS;
  if (fresh && row.fails >= MAX_FAILS) {
    const minutes = Math.ceil((WINDOW_MS - (now - row.window_start)) / 60000);
    return reply({ error: `Too many tries. Wait ${minutes} minutes.` }, 429, allowed);
  }

  let pin = '';
  try {
    const body = await request.json();
    pin = typeof body.pin === 'string' ? body.pin : '';
  } catch {
    pin = '';
  }

  if (!pin || pin.length > 32 || !constantTimeEqual(pin, env.ACCESS_PIN)) {
    const fails = fresh ? row.fails + 1 : 1;
    const start = fresh ? row.window_start : now;
    await env.DB.prepare(
      'INSERT INTO pin_attempts (ip, fails, window_start) VALUES (?, ?, ?) ' +
        'ON CONFLICT(ip) DO UPDATE SET fails = ?, window_start = ?',
    )
      .bind(who, fails, start, fails, start)
      .run();
    const left = MAX_FAILS - fails;
    return reply(
      { error: left > 0 ? `That PIN was not accepted. ${left} tries left.` : 'Too many tries. Wait 15 minutes.' },
      401,
      allowed,
    );
  }

  await env.DB.prepare('DELETE FROM pin_attempts WHERE ip = ?').bind(who).run();
  return reply({ token: await issueToken(env.SESSION_SECRET) }, 200, allowed);
}

/* --------------------------------------------------------------- validation */

const isText = (value, max) => typeof value === 'string' && value.length <= max;

function validLocation(value) {
  if (value === null) return true;
  if (!value || typeof value !== 'object') return false;
  const { lat, lon, address, source } = value;
  if (!Number.isFinite(lat) || lat < 40.45 || lat > 41.0) return false;
  if (!Number.isFinite(lon) || lon < -74.3 || lon > -73.65) return false;
  if (typeof address !== 'string' || !address.length || address.length > 800) return false;
  if (typeof source !== 'string') return false;
  try {
    const url = new URL(source);
    if (url.protocol !== 'https:' || url.username || url.password) return false;
    const osm = url.hostname === 'www.openstreetmap.org' && /^\/(node|way|relation)\/\d+$/.test(url.pathname);
    const nyc = url.hostname === 'geosearch.planninglabs.nyc' && url.pathname === '/v2/search';
    return osm || nyc;
  } catch {
    return false;
  }
}

/**
 * Mirrors the shape the Sites version enforced with zod. Returns the accepted
 * document, or a short sentence explaining the refusal.
 */
export function validateTrip(input) {
  if (!input || typeof input !== 'object') return { error: 'Check the fields and try again.' };
  if (input.dataVersion !== DATA_VERSION) {
    return { error: 'This window is using an older version. Reload before saving.' };
  }

  const e = input.essentials;
  if (!e || typeof e !== 'object') return { error: 'Check the fields and try again.' };
  for (const key of ['outbound', 'inbound', 'confirmation', 'hotelAddress']) {
    if (!isText(e[key], 4000)) return { error: 'Check the fields and try again.' };
  }

  if (!Array.isArray(input.evenings) || input.evenings.length !== 3) {
    return { error: 'Check the fields and try again.' };
  }
  for (const night of input.evenings) {
    if (!night || typeof night !== 'object') return { error: 'Check the fields and try again.' };
    for (const key of ['cluster', 'stops', 'awareness']) {
      if (!isText(night[key], 4000)) return { error: 'Check the fields and try again.' };
    }
  }

  if (!Array.isArray(input.places) || input.places.length > 200) {
    return { error: 'Check the fields and try again.' };
  }
  for (const place of input.places) {
    if (!place || typeof place !== 'object') return { error: 'Check the fields and try again.' };
    if (!isText(place.id, 80) || !place.id.length) return { error: 'Check the fields and try again.' };
    if (!Number.isSafeInteger(place.number) || place.number < 1) {
      return { error: 'Check the fields and try again.' };
    }
    if (typeof place.name !== 'string' || !place.name.length || place.name.length > 200) {
      return { error: 'Check the fields and try again.' };
    }
    if (!CATEGORIES.includes(place.category)) return { error: 'That category is not one of the five.' };
    if (!isText(place.note, 4000)) return { error: 'Check the fields and try again.' };
    if (!validLocation(place.location === undefined ? null : place.location)) {
      return { error: 'That location is outside New York, or its source is not one we trust.' };
    }
  }
  if (new Set(input.places.map((p) => p.id)).size !== input.places.length) {
    return { error: 'Duplicate place identifiers.' };
  }
  if (new Set(input.places.map((p) => p.number)).size !== input.places.length) {
    return { error: 'Duplicate place numbers.' };
  }

  if (!Array.isArray(input.thoughts) || input.thoughts.length > 200) {
    return { error: 'Check the fields and try again.' };
  }
  for (const thought of input.thoughts) {
    if (!thought || typeof thought !== 'object') return { error: 'Check the fields and try again.' };
    if (!isText(thought.id, 80) || !thought.id.length) return { error: 'Check the fields and try again.' };
    if (typeof thought.text !== 'string' || !thought.text.length || thought.text.length > 2000) {
      return { error: 'Check the fields and try again.' };
    }
  }

  const p = input.practical;
  if (!p || typeof p !== 'object') return { error: 'Check the fields and try again.' };
  for (const key of ['airport', 'subway', 'weather', 'bites']) {
    if (!isText(p[key], 4000)) return { error: 'Check the fields and try again.' };
  }

  return {
    trip: {
      dataVersion: DATA_VERSION,
      essentials: {
        outbound: e.outbound,
        inbound: e.inbound,
        confirmation: e.confirmation,
        hotelAddress: e.hotelAddress,
      },
      evenings: input.evenings.map((n) => ({
        cluster: n.cluster,
        stops: n.stops,
        awareness: n.awareness,
      })),
      places: input.places.map((x) => ({
        id: x.id,
        number: x.number,
        name: x.name,
        category: x.category,
        note: x.note,
        location: x.location === undefined ? null : x.location,
      })),
      thoughts: input.thoughts.map((t) => ({ id: t.id, text: t.text })),
      practical: { airport: p.airport, subway: p.subway, weather: p.weather, bites: p.bites },
    },
  };
}

/**
 * What a brand new database starts with. Deliberately disposable: three public
 * landmarks marked TEST, so pins, categories and the map can be exercised
 * without any real trip detail being in a public repository. Jonas's actual
 * places are loaded separately, as data, when he asks for them.
 */
export function initialTrip() {
  const test = [
    { name: 'TEST — Grand Central Terminal', category: 'Other', address: '89 E 42nd St', lat: 40.752726, lon: -73.977229, osm: 'way/264768896' },
    { name: 'TEST — Washington Square Park', category: 'Other', address: 'Washington Square', lat: 40.730823, lon: -73.997332, osm: 'way/23793787' },
    { name: 'TEST — Chelsea Market', category: 'Food', address: '75 9th Ave', lat: 40.742016, lon: -74.006001, osm: 'way/34633854' },
  ];
  return {
    dataVersion: DATA_VERSION,
    essentials: { outbound: EMPTY, inbound: EMPTY, confirmation: EMPTY, hotelAddress: EMPTY },
    evenings: [0, 1, 2].map(() => ({ cluster: EMPTY, stops: EMPTY, awareness: '' })),
    places: test.map((p, i) => ({
      id: 'test-' + i,
      number: i + 1,
      name: p.name,
      category: p.category,
      note: 'Disposable test data.',
      location: {
        lat: p.lat,
        lon: p.lon,
        address: p.address,
        source: 'https://www.openstreetmap.org/' + p.osm,
      },
    })),
    thoughts: [],
    practical: { airport: EMPTY, subway: EMPTY, weather: EMPTY, bites: EMPTY },
  };
}

/**
 * The research list: candidate places gathered by whichever AI tool did the
 * searching, waiting for Jonas to keep, skip, or push onto the map.
 */
export function validateResearch(input) {
  if (!input || typeof input !== 'object') return { error: 'Check the fields and try again.' };
  if (input.dataVersion !== 1) {
    return { error: 'This window is using an older version. Reload before saving.' };
  }
  if (!Array.isArray(input.candidates) || input.candidates.length > 500) {
    return { error: 'Check the fields and try again.' };
  }

  for (const c of input.candidates) {
    if (!c || typeof c !== 'object') return { error: 'Check the fields and try again.' };
    if (!isText(c.id, 80) || !c.id.length) return { error: 'Check the fields and try again.' };
    if (typeof c.name !== 'string' || !c.name.length || c.name.length > 200) {
      return { error: 'Every find needs a name.' };
    }
    if (!SECTIONS.includes(c.section)) return { error: 'That section is not one of the three.' };
    if (!VERDICTS.includes(c.verdict)) return { error: 'That verdict is not one we use.' };
    for (const key of ['neighborhood', 'why', 'source', 'address']) {
      if (!isText(c[key], 600)) return { error: 'Check the fields and try again.' };
    }
    if (typeof c.onMap !== 'boolean') return { error: 'Check the fields and try again.' };
  }
  if (new Set(input.candidates.map((c) => c.id)).size !== input.candidates.length) {
    return { error: 'Duplicate find identifiers.' };
  }

  return {
    research: {
      dataVersion: 1,
      candidates: input.candidates.map((c) => ({
        id: c.id,
        name: c.name,
        section: c.section,
        neighborhood: c.neighborhood,
        why: c.why,
        source: c.source,
        address: c.address,
        verdict: c.verdict,
        onMap: c.onMap,
      })),
    },
  };
}

export function initialResearch() {
  return { dataVersion: 1, candidates: [] };
}

async function getResearch(request, env, allowed) {
  const refused = await requireToken(request, env, allowed);
  if (refused) return refused;

  await env.DB.prepare(
    'INSERT INTO trips (id, data, revision) VALUES (?, ?, 0) ON CONFLICT(id) DO NOTHING',
  )
    .bind(RESEARCH_ID, JSON.stringify(initialResearch()))
    .run();

  const row = await env.DB.prepare('SELECT data, revision FROM trips WHERE id = ?')
    .bind(RESEARCH_ID)
    .first();
  if (!row) return reply({ error: 'The research list could not be loaded.' }, 503, allowed);

  const checked = validateResearch(JSON.parse(row.data));
  if (checked.error) return reply({ error: 'The research list could not be read.' }, 503, allowed);
  return reply({ research: checked.research, revision: row.revision }, 200, allowed);
}

async function putResearch(request, env, allowed) {
  const refused = await requireToken(request, env, allowed);
  if (refused) return refused;

  const raw = await request.text();
  if (raw.length > MAX_BODY) return reply({ error: 'This list is too large to save.' }, 413, allowed);

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return reply({ error: 'Check the fields and try again.' }, 400, allowed);
  }
  if (!Number.isSafeInteger(body.revision) || body.revision < 0) {
    return reply({ error: 'Check the fields and try again.' }, 400, allowed);
  }

  const checked = validateResearch(body.research);
  if (checked.error) {
    const stale = checked.error.startsWith('This window');
    return reply({ error: checked.error }, stale ? 409 : 400, allowed);
  }

  const result = await env.DB.prepare(
    'UPDATE trips SET data = ?, revision = ? WHERE id = ? AND revision = ?',
  )
    .bind(JSON.stringify(checked.research), body.revision + 1, RESEARCH_ID, body.revision)
    .run();

  if (!result.meta.changes) {
    return reply(
      {
        error:
          'This list changed in another window. Your edits are still here. Copy them, then reload to see the latest version.',
      },
      409,
      allowed,
    );
  }
  return reply({ research: checked.research, revision: body.revision + 1 }, 200, allowed);
}

/* --------------------------------------------------------------- the trip */

async function getTrip(request, env, allowed) {
  const refused = await requireToken(request, env, allowed);
  if (refused) return refused;

  await env.DB.prepare(
    'INSERT INTO trips (id, data, revision) VALUES (?, ?, 0) ON CONFLICT(id) DO NOTHING',
  )
    .bind(TRIP_ID, JSON.stringify(initialTrip()))
    .run();

  const row = await env.DB.prepare('SELECT data, revision FROM trips WHERE id = ?')
    .bind(TRIP_ID)
    .first();
  if (!row) return reply({ error: 'Your saved trip could not be loaded.' }, 503, allowed);

  const checked = validateTrip(JSON.parse(row.data));
  if (checked.error) return reply({ error: 'Your saved trip could not be read.' }, 503, allowed);
  return reply({ trip: checked.trip, revision: row.revision }, 200, allowed);
}

async function putTrip(request, env, allowed) {
  const refused = await requireToken(request, env, allowed);
  if (refused) return refused;

  const raw = await request.text();
  if (raw.length > MAX_BODY) return reply({ error: 'This trip is too large to save.' }, 413, allowed);

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return reply({ error: 'Check the fields and try again.' }, 400, allowed);
  }
  if (!Number.isSafeInteger(body.revision) || body.revision < 0) {
    return reply({ error: 'Check the fields and try again.' }, 400, allowed);
  }

  const checked = validateTrip(body.trip);
  if (checked.error) {
    const stale = checked.error.startsWith('This window');
    return reply({ error: checked.error }, stale ? 409 : 400, allowed);
  }

  // Compare-and-swap: the write only lands if nothing else has saved since this
  // window loaded, so a stale tab can never quietly replace newer edits.
  const result = await env.DB.prepare(
    'UPDATE trips SET data = ?, revision = ? WHERE id = ? AND revision = ?',
  )
    .bind(JSON.stringify(checked.trip), body.revision + 1, TRIP_ID, body.revision)
    .run();

  if (!result.meta.changes) {
    return reply(
      {
        error:
          'This trip changed in another window. Your edits are still here. Copy them, then reload to see the latest version.',
      },
      409,
      allowed,
    );
  }
  return reply({ trip: checked.trip, revision: body.revision + 1 }, 200, allowed);
}

/* ---------------------------------------------------------------- intake */

/**
 * One place, added by an outside tool.
 *
 *   POST /intake
 *   X-Intake-Key: <the INTAKE_KEY secret>
 *   { "name": "Narkara", "section": "Food & Drink", "neighborhood": "Union Square",
 *     "why": "Thai", "address": "5 E 17th St", "target": "map" }
 *
 * Deliberately append-only and write-only. It cannot read the trip, cannot
 * change or remove anything that is already there, and never returns trip
 * content. The worst a leaked key can do is add unwanted places, which Jonas can
 * delete. That is why it uses its own secret rather than the PIN.
 *
 * target "map" puts it straight on the trip map, looking the name up for a pin
 * and saving by name when nothing matches. target "research" (the default)
 * parks it on the research page instead.
 */
async function intake(request, env, allowed) {
  if (!env.INTAKE_KEY) {
    return reply({ error: 'Intake is not configured.' }, 503, allowed);
  }
  const offered = request.headers.get('X-Intake-Key') || '';
  if (!offered || offered.length > 200 || !constantTimeEqual(offered, env.INTAKE_KEY)) {
    return reply({ error: 'Not authorised.' }, 401, allowed);
  }

  let body;
  try {
    body = JSON.parse(await request.text());
  } catch {
    return reply({ error: 'Send JSON.' }, 400, allowed);
  }

  const text = (value, max) =>
    typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, max) : '';
  const name = text(body.name, 200);
  if (!name) return reply({ error: 'A name is required.' }, 400, allowed);

  const section = SECTIONS.includes(body.section) ? body.section : 'Shopping';
  const neighborhood = text(body.neighborhood, 600);
  const why = text(body.why, 600);
  const address = text(body.address, 600);
  const source = text(body.source, 60) || 'An AI tool';
  const target = body.target === 'map' ? 'map' : 'research';

  if (target === 'research') {
    const added = await appendResearch(env, {
      id: 'find-' + crypto.randomUUID().slice(0, 12),
      name,
      section,
      neighborhood,
      why,
      source,
      address,
      verdict: 'new',
      onMap: false,
    });
    if (!added) return reply({ error: 'Already on the list.', duplicate: true }, 200, allowed);
    return reply({ ok: true, added: 'research', name }, 200, allowed);
  }

  const location = await resolvePin(name, address);

  const category =
    section === 'Food & Drink' ? 'Food' : section === 'Shopping' ? 'Shops' : 'Other';
  const note = [why, neighborhood, address].filter(Boolean).join(' · ').slice(0, 4000);
  const added = await appendPlace(env, { name, category, note, location });
  if (!added) return reply({ error: 'Already on the map.', duplicate: true }, 200, allowed);
  return reply({ ok: true, added: 'map', name, pinned: Boolean(location) }, 200, allowed);
}

/**
 * Work out where a place actually is, or decide it cannot be pinned.
 *
 * An address, when given, is geocoded against NYC GeoSearch, which is the city's
 * own address service and returns the building itself. Only if there is no
 * address do we fall back to searching the name on the map, and then only an
 * actual name match counts.
 *
 * What this deliberately does NOT do is take the nearest search result. An
 * earlier version did, and pinned a restaurant to a Citi Bike dock 748 metres
 * away because the name matched nothing. No pin is far better than a wrong one;
 * a place with no pin still shows in the list.
 */
async function resolvePin(name, address) {
  if (address) {
    try {
      const url = new URL('https://geosearch.planninglabs.nyc/v2/search');
      url.search = new URLSearchParams({ text: address + ' Manhattan', size: '1' }).toString();
      const response = await fetch(url, {
        signal: AbortSignal.timeout(12000),
        headers: { Accept: 'application/json' },
        redirect: 'manual',
      });
      if (response.ok) {
        const data = await response.json();
        const feature = (data.features || [])[0];
        const [lon, lat] = feature?.geometry?.coordinates || [];
        const label = feature?.properties?.label;
        if (
          Number.isFinite(lat) && Number.isFinite(lon) &&
          lat >= 40.45 && lat <= 41 && lon >= -74.3 && lon <= -73.65 && label
        ) {
          return {
            lat,
            lon,
            address: address.slice(0, 800),
            source: 'https://geosearch.planninglabs.nyc/v2/search?' +
              new URLSearchParams({ text: address + ' Manhattan', size: '1' }).toString(),
          };
        }
      }
    } catch {
      // Fall through to the name search.
    }
  }

  try {
    const found = await lookupPlaces(name.slice(0, 160));
    const exact = found.find((r) => sameKey(r.name) === sameKey(name));
    return exact ? exact.location : null;
  } catch {
    return null;
  }
}

/** Case- and punctuation-insensitive key, matching the browser's sameName(). */
function sameKey(name) {
  return String(name)
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/\b(the|a|an)\b/g, '')
    .replace(/[^a-z0-9]/g, '');
}

/**
 * Append to a stored document under the usual compare-and-swap, retrying when
 * something else saves first. Returns false when the name is already there.
 */
async function appendTo(env, id, fallback, add) {
  for (let attempt = 0; attempt < 4; attempt++) {
    await env.DB.prepare(
      'INSERT INTO trips (id, data, revision) VALUES (?, ?, 0) ON CONFLICT(id) DO NOTHING',
    )
      .bind(id, JSON.stringify(fallback()))
      .run();

    const row = await env.DB.prepare('SELECT data, revision FROM trips WHERE id = ?')
      .bind(id)
      .first();
    if (!row) throw new Error('missing document');

    const next = add(JSON.parse(row.data));
    if (!next) return false; // duplicate

    const result = await env.DB.prepare(
      'UPDATE trips SET data = ?, revision = ? WHERE id = ? AND revision = ?',
    )
      .bind(JSON.stringify(next), row.revision + 1, id, row.revision)
      .run();
    if (result.meta.changes) return true;
  }
  throw new Error('could not append');
}

function appendResearch(env, find) {
  return appendTo(env, RESEARCH_ID, initialResearch, (research) => {
    if (research.candidates.some((c) => sameKey(c.name) === sameKey(find.name))) return null;
    const next = { ...research, candidates: [...research.candidates, find] };
    return validateResearch(next).error ? null : next;
  });
}

function appendPlace(env, place) {
  return appendTo(env, TRIP_ID, initialTrip, (trip) => {
    if (trip.places.some((p) => sameKey(p.name) === sameKey(place.name))) return null;
    const next = {
      ...trip,
      places: [
        ...trip.places,
        {
          id: crypto.randomUUID(),
          number: Math.max(0, ...trip.places.map((p) => p.number)) + 1,
          name: place.name,
          category: place.category,
          note: place.note,
          location: place.location,
        },
      ],
    };
    return validateTrip(next).error ? null : next;
  });
}

/* ------------------------------------------------------------ place search */

const NYC_CITIES = ['New York', 'New York City', 'Brooklyn', 'Queens', 'Bronx', 'The Bronx', 'Staten Island', 'Manhattan'];
const NYC_DISTRICTS = ['Manhattan', 'Brooklyn', 'Queens', 'Bronx', 'The Bronx', 'Staten Island'];
const OSM_KIND = { N: 'node', W: 'way', R: 'relation' };
const searchCache = new Map();

async function places(request, env, url, allowed) {
  const refused = await requireToken(request, env, allowed);
  if (refused) return refused;

  const q = (url.searchParams.get('q') || '').trim();
  if (q.length < 2 || q.length > 160) {
    return reply({ error: 'Enter a place name (2–160 characters).' }, 400, allowed);
  }

  try {
    return reply({ results: await lookupPlaces(q) }, 200, allowed);
  } catch {
    return reply(
      { error: 'Place search is unavailable right now. Try again, or add by name without a pin.' },
      502,
      allowed,
    );
  }
}

/**
 * Ask Photon for New York matches. Throws if the upstream is unreachable, so
 * callers can decide whether a missing pin matters. Results are cached briefly,
 * because the same name gets looked up repeatedly while adding a place.
 */
async function lookupPlaces(q) {
  const key = q.toLowerCase();
  const cached = searchCache.get(key);
  if (cached && Date.now() - cached.at < 300000) return cached.results;

  {
    const search = new URL('https://photon.komoot.io/api/');
    search.search = new URLSearchParams({
      q,
      lat: '40.74',
      lon: '-73.99',
      bbox: '-74.3,40.45,-73.65,41.0',
      limit: '8',
      lang: 'en',
    }).toString();

    const response = await fetch(search, {
      signal: AbortSignal.timeout(12000),
      headers: { Accept: 'application/json' },
      redirect: 'manual',
    });
    if (!response.ok) throw new Error('upstream');
    const data = await response.json();

    const results = (data.features || []).flatMap((feature) => {
      const p = feature.properties || {};
      const [lon, lat] = feature.geometry?.coordinates || [];
      if (!NYC_CITIES.includes(p.city) && !NYC_DISTRICTS.includes(p.district)) return [];
      if (feature.geometry?.type !== 'Point') return [];
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) return [];
      if (lat < 40.45 || lat > 41 || lon < -74.3 || lon > -73.65) return [];
      if (!p.name || !p.osm_id) return [];
      const kind = OSM_KIND[p.osm_type];
      if (!kind) return [];
      const street = [p.housenumber, p.street].filter(Boolean).join(' ');
      const address = [street, p.district, p.city, p.state, p.postcode].filter(Boolean).join(', ');
      if (!address) return [];
      return [
        {
          id: p.osm_type + p.osm_id,
          name: p.name,
          location: {
            lat,
            lon,
            address,
            source: 'https://www.openstreetmap.org/' + kind + '/' + p.osm_id,
          },
        },
      ];
    });

    const normalized = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
    const wanted = normalized(q);
    results.sort((a, b) => Number(normalized(b.name) === wanted) - Number(normalized(a.name) === wanted));

    if (searchCache.size > 100) searchCache.clear();
    searchCache.set(key, { at: Date.now(), results });
    return results;
  }
}
