// Google Identity Services is loaded only after the user chooses Connect Gmail.
// Access tokens, account details, filters and message metadata stay in memory.
// Docs: https://developers.google.com/identity/oauth2/web/guides/use-token-model
// Gmail requests below use gmail.readonly; they never change mail or filters.

export const CLIENT_ID = '994773724656-dht15sn4cq190nr2v9sgmn0ki5nqj86p.apps.googleusercontent.com';
const GMAIL_SCOPE = 'https://www.googleapis.com/auth/gmail.readonly';
const EMAIL_SCOPE = 'https://www.googleapis.com/auth/userinfo.email';
const SCOPES = `${GMAIL_SCOPE} ${EMAIL_SCOPE}`;
const GMAIL_API = 'https://gmail.googleapis.com/gmail/v1/users/me';
const GIS_URL = 'https://accounts.google.com/gsi/client';
const METADATA_HEADERS = ['From', 'Subject', 'Date', 'List-Id', 'List-Unsubscribe'];
const REQUEST_TIMEOUT = 30000;
let scriptLoading;
let signingIn = false;

export class GmailError extends Error {
  constructor(status, message) {
    super(message);
    this.name = 'GmailError';
    this.status = status;
  }
}

function abortError() {
  return new DOMException('Google request cancelled.', 'AbortError');
}

function checkAbort(signal) {
  if (signal?.aborted) throw abortError();
}

function googleOAuth() {
  return globalThis.google?.accounts?.oauth2;
}

function waitWithSignal(promise, signal) {
  if (!signal) return promise;
  checkAbort(signal);
  return new Promise((resolve, reject) => {
    const abort = () => { cleanup(); reject(abortError()); };
    const cleanup = () => signal.removeEventListener('abort', abort);
    signal.addEventListener('abort', abort, { once: true });
    promise.then(value => { cleanup(); resolve(value); }, error => { cleanup(); reject(error); });
  });
}

async function loadGoogleIdentity(signal) {
  checkAbort(signal);
  if (googleOAuth()?.initTokenClient) return googleOAuth();
  if (!globalThis.document?.createElement) {
    throw new GmailError(0, 'Google sign-in needs a web browser. Open this page in your browser and try again.');
  }
  if (!scriptLoading) {
    scriptLoading = new Promise((resolve, reject) => {
      const existing = document.querySelector(`script[src="${GIS_URL}"]`);
      const script = existing || document.createElement('script');
      let timer;
      const cleanup = () => {
        clearTimeout(timer);
        script.removeEventListener('load', loaded);
        script.removeEventListener('error', failed);
      };
      const failed = () => {
        cleanup();
        if (!existing) script.remove();
        reject(new GmailError(0, 'Google sign-in could not load. Check your connection or allow accounts.google.com in your content blocker, then try again.'));
      };
      const loaded = () => {
        if (!googleOAuth()?.initTokenClient) { failed(); return; }
        cleanup();
        resolve(googleOAuth());
      };
      script.addEventListener('load', loaded);
      script.addEventListener('error', failed);
      timer = setTimeout(failed, 15000);
      if (!existing) {
        script.src = GIS_URL;
        script.async = true;
        script.defer = true;
        try { document.head.appendChild(script); }
        catch { failed(); }
      }
    });
    // Permit a retry after a blocked download or a temporary connection failure.
    scriptLoading.catch(() => { scriptLoading = undefined; });
  }
  return waitWithSignal(scriptLoading, signal);
}

function requestToken(oauth, signal) {
  checkAbort(signal);
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer;
    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
    };
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      cleanup();
      if (error) reject(error);
      else resolve(value);
    };
    const abort = () => finish(abortError());
    timer = setTimeout(() => finish(new GmailError(0, 'Google sign-in timed out. Close the sign-in window and try again.')), 120000);
    signal?.addEventListener('abort', abort, { once: true });
    try {
      const client = oauth.initTokenClient({
        client_id: CLIENT_ID,
        scope: SCOPES,
        include_granted_scopes: false,
        callback: response => {
          if (settled) return;
          if (response?.error) {
            finish(new GmailError(401, response.error === 'access_denied'
              ? 'Google access was not granted. Connect Gmail again and allow read-only Gmail access.'
              : 'Google sign-in failed. Please try signing in again.'));
            return;
          }
          const scopes = new Set(String(response?.scope || '').split(/\s+/));
          let granted = false;
          try {
            granted = typeof oauth.hasGrantedAllScopes === 'function'
              ? oauth.hasGrantedAllScopes(response, GMAIL_SCOPE, EMAIL_SCOPE)
              : scopes.has(GMAIL_SCOPE) && (scopes.has(EMAIL_SCOPE) || scopes.has('email'));
          } catch { /* Treat an incomplete Google response as missing consent. */ }
          if (!granted) {
            finish(new GmailError(403, 'Read-only Gmail access and your email address are required. Sign in again and allow both permissions.'));
            return;
          }
          const seconds = Number(response?.expires_in);
          if (typeof response?.access_token !== 'string' || !response.access_token.trim() || !Number.isFinite(seconds) || seconds <= 0) {
            finish(new GmailError(401, 'Google did not return a usable sign-in. Please sign in again.'));
            return;
          }
          finish(null, { token: response.access_token, expiresAt: Date.now() + seconds * 1000 });
        },
        error_callback: error => {
          const message = error?.type === 'popup_closed'
            ? 'The Google sign-in window was closed. Choose Connect Gmail to try again.'
            : error?.type === 'popup_failed_to_open'
              ? 'Your browser blocked Google sign-in. Allow pop-up windows for this page and try again.'
              : 'Google sign-in could not open. Please try again.';
          finish(new GmailError(0, message));
        },
      });
      client.requestAccessToken({ prompt: 'select_account' });
    } catch {
      finish(new GmailError(0, 'Google sign-in could not open. Allow pop-up windows for this page and try again.'));
    }
  });
}

function httpError(status) {
  const messages = {
    400: 'Google could not read this request. Please try again.',
    401: 'Your Google sign-in has expired or was revoked. Sign in again to continue.',
    403: 'Google blocked this request. Sign in again and allow read-only Gmail access. If it continues, enable the Gmail API in this app’s Google Cloud project or check your work account’s policy.',
    404: 'This Gmail message or resource is no longer available. Please refresh and try again.',
    429: 'Gmail is receiving too many requests. Wait a moment and try again.',
  };
  return new GmailError(status, messages[status] || 'Google is temporarily unavailable. Please try again later.');
}

async function getGoogle(url, token, { signal } = {}) {
  checkAbort(signal);
  if (typeof token !== 'string' || !token.trim()) throw httpError(401);
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, REQUEST_TIMEOUT);
  try {
    const response = await fetch(url, {
      method: 'GET',
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
      signal: controller.signal,
      cache: 'no-store',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
    });
    checkAbort(signal);
    if (!response.ok) throw httpError(response.status);
    let data;
    try { data = await response.json(); }
    catch { throw new GmailError(502, 'Google returned an unreadable response. Please try again.'); }
    checkAbort(signal);
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
      throw new GmailError(502, 'Google returned an incomplete response. Please try again.');
    }
    return data;
  } catch (error) {
    if (signal?.aborted) throw abortError();
    if (timedOut) throw new GmailError(0, 'Google took too long to respond. Check your connection and try again.');
    if (error instanceof GmailError) throw error;
    throw new GmailError(0, 'Could not read Gmail. Check your internet connection and try again.');
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

function responseArray(data, key) {
  // Google omits an empty collection. A present but malformed one is an error.
  if (data[key] === undefined) return [];
  if (!Array.isArray(data[key]) || data[key].some(item => !item || typeof item !== 'object' || Array.isArray(item))) {
    throw new GmailError(502, 'Google returned an incomplete response. Please try again.');
  }
  return data[key];
}

export async function readGoogleFilters(token, { signal } = {}) {
  const [filterData, labelData] = await Promise.all([
    getGoogle(`${GMAIL_API}/settings/filters`, token, { signal }),
    getGoogle(`${GMAIL_API}/labels?fields=labels(id,name,type)`, token, { signal }),
  ]);
  const filters = responseArray(filterData, 'filter');
  const labels = responseArray(labelData, 'labels');
  if (filters.some(filter => typeof filter.id !== 'string' || !filter.id || !filter.criteria || typeof filter.criteria !== 'object' || Array.isArray(filter.criteria) || !filter.action || typeof filter.action !== 'object' || Array.isArray(filter.action)) ||
      labels.some(label => typeof label.id !== 'string' || typeof label.name !== 'string')) {
    throw new GmailError(502, 'Google returned incomplete filters or labels. Please reconnect and try again.');
  }
  return { filters, labels };
}

export async function connectGoogle({ signal } = {}) {
  checkAbort(signal);
  if (signingIn) throw new GmailError(0, 'A Google sign-in is already open. Finish or close that window first.');
  signingIn = true;
  try {
    const oauth = await loadGoogleIdentity(signal);
    const credentials = await requestToken(oauth, signal);
    const [account, source] = await Promise.all([
      getGoogle('https://www.googleapis.com/oauth2/v2/userinfo?fields=email', credentials.token, { signal }),
      readGoogleFilters(credentials.token, { signal }),
    ]);
    if (typeof account.email !== 'string' || !/^[^\s@]+@[^\s@]+$/.test(account.email)) {
      throw new GmailError(502, 'Google did not return your email address. Please sign in again.');
    }
    checkAbort(signal);
    // No partial source is returned when account, filters or labels fail.
    return { ...credentials, email: account.email, ...source };
  } finally {
    signingIn = false;
  }
}

export async function readInbox(token, { unreadOnly = true, limit = 50, onProgress = () => {}, signal } = {}) {
  checkAbort(signal);
  if (![25, 50, 100].includes(limit)) throw new GmailError(400, 'Choose 25, 50 or 100 messages.');
  const ids = [];
  const seenIds = new Set();
  const seenPages = new Set();
  let pageToken = '';
  do {
    const params = new URLSearchParams({ q: unreadOnly ? 'is:unread in:inbox' : 'in:inbox', maxResults: String(limit - ids.length), fields: 'messages(id),nextPageToken' });
    if (pageToken) params.set('pageToken', pageToken);
    const data = await getGoogle(`${GMAIL_API}/messages?${params}`, token, { signal });
    for (const message of responseArray(data, 'messages')) {
      if (typeof message.id !== 'string' || !message.id) throw new GmailError(502, 'Gmail returned an incomplete message list. Please try again.');
      if (!seenIds.has(message.id) && ids.length < limit) { ids.push(message.id); seenIds.add(message.id); }
    }
    pageToken = typeof data.nextPageToken === 'string' ? data.nextPageToken : '';
    if (pageToken && seenPages.has(pageToken)) throw new GmailError(502, 'Gmail returned a repeated message page. Please try again.');
    seenPages.add(pageToken);
  } while (pageToken && ids.length < limit);
  onProgress(0, ids.length);
  const emails = [];
  let done = 0;
  // At most ten metadata requests run at once. No full message bodies are read.
  for (let start = 0; start < ids.length; start += 10) {
    checkAbort(signal);
    const batchController = new AbortController();
    const abortBatch = () => batchController.abort();
    signal?.addEventListener('abort', abortBatch, { once: true });
    try {
      const batch = await Promise.all(ids.slice(start, start + 10).map(async id => {
        const params = new URLSearchParams({ format: 'metadata', fields: 'id,snippet,payload/headers' });
        METADATA_HEADERS.forEach(header => params.append('metadataHeaders', header));
        const data = await getGoogle(`${GMAIL_API}/messages/${encodeURIComponent(id)}?${params}`, token, { signal: batchController.signal });
        if (typeof data.id !== 'string' || data.id !== id || !Array.isArray(data.payload?.headers)) {
          throw new GmailError(502, 'Gmail returned incomplete message details. Please try again.');
        }
        const header = name => {
          const match = data.payload.headers.find(item => typeof item?.name === 'string' && item.name.toLowerCase() === name.toLowerCase());
          return typeof match?.value === 'string' ? match.value : '';
        };
        const email = {
          from: header('From'), subject: header('Subject'), date: header('Date'),
          listId: header('List-Id'), listUnsubscribe: header('List-Unsubscribe'),
          snippet: typeof data.snippet === 'string' ? data.snippet.slice(0, 200) : '', id,
        };
        checkAbort(batchController.signal);
        onProgress(++done, ids.length);
        return email;
      }));
      emails.push(...batch);
    } catch (error) {
      // Stop the rest of this batch, including late progress updates, on failure.
      batchController.abort();
      throw error;
    } finally {
      signal?.removeEventListener('abort', abortBatch);
    }
  }
  return emails;
}

export async function signOutGoogle(token) {
  if (typeof token !== 'string' || !token.trim()) return;
  // The app clears its in-memory session immediately; revocation is best effort.
  await new Promise(resolve => {
    let timer;
    const finish = () => { clearTimeout(timer); resolve(); };
    timer = setTimeout(finish, 5000);
    try {
      const oauth = googleOAuth();
      if (typeof oauth?.revoke === 'function') oauth.revoke(token, finish);
      else {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 4500);
        fetch('https://oauth2.googleapis.com/revoke', {
          method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ token }), signal: controller.signal,
          credentials: 'omit', referrerPolicy: 'no-referrer',
        }).catch(() => {}).finally(() => { clearTimeout(timeout); finish(); });
      }
    } catch { finish(); }
  });
}
