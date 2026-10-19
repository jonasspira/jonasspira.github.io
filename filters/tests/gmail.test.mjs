import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { CLIENT_ID, GmailError, connectGoogle, readGoogleFilters, readInbox, signOutGoogle } from '../gmail.js';

const ORIGINALS = Object.fromEntries(['fetch', 'google', 'document', 'setTimeout', 'clearTimeout'].map(key => [key, globalThis[key]]));
afterEach(() => {
  for (const [key, value] of Object.entries(ORIGINALS)) {
    if (value === undefined) delete globalThis[key];
    else globalThis[key] = value;
  }
});
const TOKEN = 'mock-credential-for-unit-tests-only';
const SCOPE = 'https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/userinfo.email';
const validFilter = { id: 'filter-one', criteria: { from: 'mail@example.test' }, action: { addLabelIds: ['Label_1'] } };
const validLabel = { id: 'Label_1', name: 'Receipts', type: 'user' };
const json = (data, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => data });
const metadata = id => ({
  id, snippet: 'A short preview',
  payload: { headers: [
    { name: 'FROM', value: 'Sender <mail@example.test>' }, { name: 'Subject', value: 'Invoice' },
    { name: 'Date', value: 'Mon, 19 Oct 2026 12:00:00 +0000' },
    { name: 'List-Id', value: '<news.example.test>' },
    { name: 'List-Unsubscribe', value: '<mailto:unsubscribe@example.test>' },
  ], body: { data: 'this-body-must-never-be-returned' } },
});
function mockOAuth(response = { access_token: TOKEN, expires_in: 3600, scope: SCOPE }) {
  let config;
  let requested;
  globalThis.google = { accounts: { oauth2: {
    initTokenClient(value) {
      config = value;
      return { requestAccessToken(options) { requested = options; queueMicrotask(() => config.callback(response)); } };
    },
  } } };
  return { get config() { return config; }, get requested() { return requested; } };
}
function sourceFetch(url, options) {
  assert.equal(options.method, 'GET');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.cache, 'no-store');
  assert.equal(options.headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(options.body, undefined);
  assert.ok(!String(url).includes(TOKEN));
  if (String(url).includes('/userinfo')) return json({ email: 'person@example.test' });
  if (String(url).includes('/settings/filters')) return json({ filter: [validFilter] });
  if (String(url).includes('/labels')) return json({ labels: [validLabel] });
  assert.fail('Unexpected endpoint');
}

test('reads filters and real label names using authenticated GET requests', async () => {
  const urls = [];
  globalThis.fetch = async (url, options) => { urls.push(String(url)); return sourceFetch(url, options); };
  assert.deepEqual(await readGoogleFilters(TOKEN), { filters: [validFilter], labels: [validLabel] });
  assert.equal(urls.length, 2);
  assert.ok(urls.every(url => url.startsWith('https://gmail.googleapis.com/')));
});

test('a Gmail account with zero filters or labels is valid', async () => {
  globalThis.fetch = async () => json({});
  assert.deepEqual(await readGoogleFilters(TOKEN), { filters: [], labels: [] });
});

test('rejects malformed filters or labels instead of returning partial source data', async () => {
  for (const data of [{ filter: null }, { filter: [{}] }, { filter: 'not-an-array' }]) {
    globalThis.fetch = async url => json(String(url).includes('/settings/filters') ? data : { labels: [validLabel] });
    await assert.rejects(readGoogleFilters(TOKEN), error => error instanceof GmailError && error.status === 502);
  }
  globalThis.fetch = async url => json(String(url).includes('/labels') ? { labels: [{ id: 'Label_1' }] } : { filter: [validFilter] });
  await assert.rejects(readGoogleFilters(TOKEN), /incomplete filters or labels/i);
});

test('inbox scan encodes its query, fetches five metadata headers and strips message bodies', async () => {
  const requests = [];
  const id = 'message/with?reserved=characters';
  globalThis.fetch = async (url, options) => {
    requests.push({ url: String(url), options });
    const parsed = new URL(url);
    if (parsed.pathname.endsWith('/messages')) return json({ messages: [{ id }] });
    const message = metadata(id);
    message.snippet = 'x'.repeat(350);
    return json(message);
  };
  const progress = [];
  const emails = await readInbox(TOKEN, { onProgress: (done, total) => progress.push([done, total]) });
  assert.equal(new URL(requests[0].url).searchParams.get('q'), 'is:unread in:inbox');
  assert.equal(new URL(requests[0].url).searchParams.get('maxResults'), '50');
  const detail = new URL(requests[1].url);
  assert.ok(detail.pathname.endsWith(encodeURIComponent(id)));
  assert.equal(detail.searchParams.get('format'), 'metadata');
  assert.deepEqual(detail.searchParams.getAll('metadataHeaders'), ['From', 'Subject', 'Date', 'List-Id', 'List-Unsubscribe']);
  assert.equal(detail.searchParams.get('fields'), 'id,snippet,payload/headers');
  assert.deepEqual(emails, [{
    from: 'Sender <mail@example.test>', subject: 'Invoice', date: 'Mon, 19 Oct 2026 12:00:00 +0000',
    listId: '<news.example.test>', listUnsubscribe: '<mailto:unsubscribe@example.test>', snippet: 'x'.repeat(200), id,
  }]);
  assert.deepEqual(progress, [[0, 1], [1, 1]]);
  for (const { url, options } of requests) {
    assert.equal(options.method, 'GET');
    assert.equal(options.body, undefined);
    assert.ok(!url.includes(TOKEN));
  }
});

test('metadata batches never exceed ten concurrent requests and preserve list order', async () => {
  const ids = Array.from({ length: 25 }, (_, i) => `message-${i}`);
  let active = 0;
  let maximum = 0;
  globalThis.fetch = async url => {
    const parsed = new URL(url);
    if (parsed.pathname.endsWith('/messages')) return json({ messages: ids.map(id => ({ id })) });
    active++;
    maximum = Math.max(maximum, active);
    await new Promise(resolve => setTimeout(resolve, (25 - Number(parsed.pathname.split('-').at(-1))) % 4));
    active--;
    return json(metadata(parsed.pathname.split('/').at(-1)));
  };
  const progress = [];
  const emails = await readInbox(TOKEN, { limit: 25, onProgress: (done, total) => progress.push([done, total]) });
  assert.equal(maximum, 10);
  assert.deepEqual(emails.map(email => email.id), ids);
  assert.deepEqual(progress, Array.from({ length: 26 }, (_, done) => [done, 25]));
});

test('all-inbox scans follow message pages up to the selected limit, without duplicates', async () => {
  const listRequests = [];
  globalThis.fetch = async url => {
    const parsed = new URL(url);
    if (parsed.pathname.endsWith('/messages')) {
      listRequests.push(parsed);
      return json(parsed.searchParams.has('pageToken')
        ? { messages: [{ id: 'one' }, { id: 'two' }] }
        : { messages: [{ id: 'one' }], nextPageToken: 'next + & page' });
    }
    return json(metadata(parsed.pathname.split('/').at(-1)));
  };
  const emails = await readInbox(TOKEN, { unreadOnly: false, limit: 25 });
  assert.deepEqual(emails.map(email => email.id), ['one', 'two']);
  assert.equal(listRequests[0].searchParams.get('q'), 'in:inbox');
  assert.equal(listRequests[1].searchParams.get('maxResults'), '24');
  assert.equal(listRequests[1].searchParams.get('pageToken'), 'next + & page');
});

test('empty inbox returns an empty result and completes progress', async () => {
  globalThis.fetch = async () => json({});
  const progress = [];
  assert.deepEqual(await readInbox(TOKEN, { onProgress: (done, total) => progress.push([done, total]) }), []);
  assert.deepEqual(progress, [[0, 0]]);
});

test('inbox rejects unsupported limits before making a Google request', async () => {
  globalThis.fetch = () => assert.fail('No Google request expected');
  for (const limit of [0, 10, 26, 1000, '50']) await assert.rejects(readInbox(TOKEN, { limit }), /25, 50 or 100/);
});

test('incomplete message lists or metadata do not return partial emails', async () => {
  globalThis.fetch = async () => json({ messages: [{}] });
  await assert.rejects(readInbox(TOKEN), /incomplete message list/);
  globalThis.fetch = async url => json(new URL(url).pathname.endsWith('/messages')
    ? { messages: [{ id: 'one' }, { id: 'two' }] }
    : String(url).includes('/one?') ? metadata('one') : { id: 'two' });
  await assert.rejects(readInbox(TOKEN), /incomplete message details/);
});

test('one failed metadata request cancels its peers and prevents later batches', async () => {
  const ids = Array.from({ length: 25 }, (_, i) => `message-${i}`);
  let details = 0;
  let aborted = 0;
  const progress = [];
  globalThis.fetch = async (url, options) => {
    const parsed = new URL(url);
    if (parsed.pathname.endsWith('/messages')) return json({ messages: ids.map(id => ({ id })) });
    details++;
    if (parsed.pathname.endsWith('/message-0')) return json({}, 429);
    return new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => {
      aborted++;
      reject(new DOMException('cancelled', 'AbortError'));
    }, { once: true }));
  };
  await assert.rejects(readInbox(TOKEN, { limit: 25, onProgress: (done, total) => progress.push([done, total]) }), error => error.status === 429);
  assert.equal(details, 10);
  assert.equal(aborted, 9);
  assert.deepEqual(progress, [[0, 25]]);
});

test('HTTP errors are human readable and do not expose Google response content', async () => {
  for (const [status, message] of [[401, /sign in again/i], [403, /enable the Gmail API/i], [429, /wait a moment/i], [500, /temporarily unavailable/i]]) {
    globalThis.fetch = async () => json({ error: { message: 'private data from upstream response' } }, status);
    await assert.rejects(readGoogleFilters(TOKEN), error => {
      assert.ok(error instanceof GmailError);
      assert.equal(error.status, status);
      assert.match(error.message, message);
      assert.ok(!error.message.includes('private data'));
      return true;
    });
  }
});

test('network failures are sanitized, and missing credentials require sign-in', async () => {
  globalThis.fetch = async () => { throw new Error('network details that must not appear'); };
  await assert.rejects(readGoogleFilters(TOKEN), error => error.status === 0 && /internet connection/.test(error.message) && !error.message.includes('details'));
  globalThis.fetch = () => assert.fail('No request without a token');
  await assert.rejects(readInbox(''), error => error.status === 401);
});

test('invalid JSON and request timeouts have clear recoverable errors', async () => {
  globalThis.fetch = async () => ({ ok: true, status: 200, json() { throw new SyntaxError('private response details'); } });
  await assert.rejects(readInbox(TOKEN), error => error.status === 502 && /unreadable response/.test(error.message));
  let timeout;
  globalThis.setTimeout = (callback, duration) => { assert.equal(duration, 30000); timeout = callback; return 1; };
  globalThis.clearTimeout = () => {};
  globalThis.fetch = async (_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new DOMException('cancelled', 'AbortError')), { once: true });
  });
  const pending = readInbox(TOKEN);
  timeout();
  await assert.rejects(pending, error => error.status === 0 && /too long to respond/.test(error.message));
});

test('cancellation stops an active Google request and preserves AbortError', async () => {
  const controller = new AbortController();
  globalThis.fetch = async (_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new DOMException('cancelled', 'AbortError')), { once: true });
    queueMicrotask(() => controller.abort());
  });
  await assert.rejects(readInbox(TOKEN, { signal: controller.signal }), { name: 'AbortError' });
  globalThis.fetch = () => assert.fail('No request after cancellation');
  await assert.rejects(readGoogleFilters(TOKEN, { signal: controller.signal }), { name: 'AbortError' });
});

test('connection requests read-only access and returns one complete account source', async () => {
  const oauth = mockOAuth();
  globalThis.fetch = async (url, options) => sourceFetch(url, options);
  const now = Date.now();
  const connection = await connectGoogle();
  assert.equal(oauth.config.client_id, CLIENT_ID);
  assert.equal(oauth.config.scope, SCOPE);
  assert.equal(oauth.config.include_granted_scopes, false);
  assert.deepEqual(oauth.requested, { prompt: 'select_account' });
  assert.deepEqual(connection.filters, [validFilter]);
  assert.deepEqual(connection.labels, [validLabel]);
  assert.equal(connection.email, 'person@example.test');
  assert.equal(connection.token, TOKEN);
  assert.ok(connection.expiresAt >= now + 3600000 && connection.expiresAt <= Date.now() + 3600000);
});

test('connection rejects missing Gmail permission and unusable token responses', async () => {
  globalThis.fetch = () => assert.fail('No request before successful permission and credential checks');
  mockOAuth({ access_token: TOKEN, expires_in: 3600, scope: 'https://www.googleapis.com/auth/userinfo.email' });
  await assert.rejects(connectGoogle(), error => error.status === 403 && /both permissions/.test(error.message));
  mockOAuth({ access_token: '', expires_in: 3600, scope: SCOPE });
  await assert.rejects(connectGoogle(), /usable sign-in/);
  mockOAuth({ access_token: TOKEN, expires_in: -1, scope: SCOPE });
  await assert.rejects(connectGoogle(), /usable sign-in/);
});

test('connection fails atomically when email or one source response is invalid', async () => {
  mockOAuth();
  globalThis.fetch = async (url, options) => String(url).includes('/userinfo') ? json({}) : sourceFetch(url, options);
  await assert.rejects(connectGoogle(), /email address/);
  globalThis.fetch = async (url, options) => String(url).includes('/labels') ? json({ labels: null }) : sourceFetch(url, options);
  await assert.rejects(connectGoogle(), /incomplete response/);
});

test('closed or blocked sign-in popups give a recovery instruction', async () => {
  for (const [type, pattern] of [['popup_closed', /window was closed/], ['popup_failed_to_open', /Allow pop-up windows/]]) {
    globalThis.google = { accounts: { oauth2: { initTokenClient(config) {
      return { requestAccessToken() { queueMicrotask(() => config.error_callback({ type })); } };
    } } } };
    await assert.rejects(connectGoogle(), pattern);
  }
});

test('sign-in can be cancelled and rejects a concurrent attempt', async () => {
  const controller = new AbortController();
  let ready;
  const opened = new Promise(resolve => { ready = resolve; });
  globalThis.google = { accounts: { oauth2: { initTokenClient() {
    return { requestAccessToken() { ready(); } };
  } } } };
  const pending = connectGoogle({ signal: controller.signal });
  await opened;
  await assert.rejects(connectGoogle(), /already open/);
  controller.abort();
  await assert.rejects(pending, { name: 'AbortError' });
});

test('Google sign-in timeout is reported without keeping the operation busy', async () => {
  let timeout;
  globalThis.setTimeout = (callback, duration) => { assert.equal(duration, 120000); timeout = callback; return 1; };
  globalThis.clearTimeout = () => {};
  mockOAuth();
  globalThis.google.accounts.oauth2.initTokenClient = () => ({ requestAccessToken() {} });
  const pending = connectGoogle();
  await Promise.resolve();
  await Promise.resolve();
  timeout();
  await assert.rejects(pending, /timed out/);
});

test('sign-in script is lazy, reports blocked downloads, and can retry', async () => {
  const fresh = await import(`../gmail.js?script-test=${Date.now()}`);
  delete globalThis.google;
  let appends = 0;
  let shouldFail = true;
  globalThis.document = {
    querySelector: () => null,
    createElement() {
      const listeners = new Map();
      return { addEventListener: (name, callback) => listeners.set(name, callback), removeEventListener: name => listeners.delete(name), remove() {}, listeners };
    },
    head: { appendChild(script) {
      appends++;
      assert.equal(script.src, 'https://accounts.google.com/gsi/client');
      queueMicrotask(() => {
        if (shouldFail) script.listeners.get('error')();
        else { mockOAuth(); script.listeners.get('load')(); }
      });
    } },
  };
  assert.equal(appends, 0);
  await assert.rejects(fresh.connectGoogle(), /content blocker/);
  shouldFail = false;
  globalThis.fetch = async (url, options) => sourceFetch(url, options);
  assert.equal((await fresh.connectGoogle()).email, 'person@example.test');
  assert.equal(appends, 2);
});

test('sign-out revokes the in-memory credential and tolerates revocation failure', async () => {
  const revoked = [];
  mockOAuth();
  globalThis.google.accounts.oauth2.revoke = (token, done) => { revoked.push(token); done({ successful: true }); };
  await signOutGoogle(TOKEN);
  assert.deepEqual(revoked, [TOKEN]);
  globalThis.google.accounts.oauth2.revoke = () => { throw new Error('revocation failed'); };
  await signOutGoogle(TOKEN);
  await signOutGoogle('');
});
