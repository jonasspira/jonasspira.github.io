/**
 * Filters — authenticated AI analysis, with no mail or prompt logging.
 *
 * GET  /health  — configured providers and authentication, never secret values
 * POST /analyze — one structured analysis using a server-selected model
 *
 * DEPLOY (Cloudflare dashboard; see SETUP.md)
 * 1. Workers & Pages → Create application → Create Worker → deploy a Hello World.
 * 2. Name it spiiira-filters-ai. Edit code → replace it with this whole file → Deploy.
 * 3. Settings → Variables and Secrets → add encrypted secrets:
 *      ACCESS_CODE, ANTHROPIC_API_KEY and/or OPENAI_API_KEY, ALLOWED_EMAILS (optional).
 * 4. Open its /health address, then use the access code in the page's Settings.
 *
 * No API keys belong in the page or repository. Do not enable request-body logging.
 */

// Pinned to supported efficient models, checked against official docs 2026-10-19.
// To upgrade, change these constants, verify native structured-output support,
// run the tests, and deploy the new Worker. Callers can never select a model.
export const ANTHROPIC_MODEL = 'claude-haiku-5-5';
export const OPENAI_MODEL = 'gpt-6-luna';
const GOOGLE_CLIENT_ID = '994773724656-dht15sn4cq190nr2v9sgmn0ki5nqj86p.apps.googleusercontent.com';
const MAX_BODY_BYTES = 300 * 1024;
const MAX_UPSTREAM_BYTES = 1024 * 1024;
const TIMEOUT_MS = 55000;
const BUILD = '2026-10-19.2';
const PROD_ORIGINS = new Set([
  'https://www.spiiira.com', 'https://spiiira.com', 'https://jonasspira.github.io',
]);

/* ------------------------------------------------------------------ *
 * Plumbing — exact origins, bounded bodies and deliberately quiet errors
 * ------------------------------------------------------------------ */

export function isAllowedOrigin(origin) {
  if (PROD_ORIGINS.has(origin)) return true;
  try {
    const url = new URL(origin);
    return url.origin === origin && url.protocol === 'http:' &&
      ['localhost', '127.0.0.1'].includes(url.hostname) && !url.username && !url.password;
  } catch { return false; }
}

function corsHeaders(origin) {
  return {
    ...(isAllowedOrigin(origin) ? { 'Access-Control-Allow-Origin': origin } : {}),
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-Access-Code, Authorization',
    'Vary': 'Origin',
  };
}

function json(data, status, origin) {
  return new Response(JSON.stringify(data), {
    status, headers: {
      ...corsHeaders(origin), 'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    },
  });
}

class ServiceError extends Error {
  constructor(status, code, detail) { super(detail); this.status = status; this.code = code; }
}

async function cancelQuietly(response) {
  try { await response.body?.cancel(); } catch { /* Never expose cancellation errors or upstream content. */ }
}

async function readJSON(response, maxBytes = MAX_BODY_BYTES) {
  const length = response.headers.get('Content-Length');
  if (length && Number(length) > maxBytes) throw new ServiceError(413, 'too_large', 'This request is too large. Load fewer filters or emails.');
  if (!response.body) throw new ServiceError(400, 'invalid_json', 'Send a JSON request body.');
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        throw new ServiceError(413, 'too_large', 'This request is too large. Load fewer filters or emails.');
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { throw new ServiceError(400, 'invalid_json', 'Send a valid JSON request body.'); }
}

async function withTimeout(action, ms) {
  const controller = new AbortController();
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new ServiceError(502, 'timeout', 'The service took too long. Try again with fewer emails.'));
    }, ms);
  });
  try { return await Promise.race([action(controller.signal), timeout]); }
  finally { clearTimeout(timer); }
}

/** Hash both inputs, then compare all digest bytes without an early exit. */
async function constantTimeEqual(left, right) {
  const encode = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', encode.encode(left)),
    crypto.subtle.digest('SHA-256', encode.encode(right)),
  ]);
  const av = new Uint8Array(a), bv = new Uint8Array(b);
  let difference = 0;
  for (let i = 0; i < av.length; i++) difference |= av[i] ^ bv[i];
  return difference === 0;
}

function allowedEmails(env) {
  return new Set(String(env.ALLOWED_EMAILS || '').split(',').map(email => email.trim().toLowerCase()).filter(Boolean));
}

async function authenticate(request, env, fetchImpl, timeoutMs) {
  const code = request.headers.get('X-Access-Code') || '';
  if (env.ACCESS_CODE && code && code.length <= 1024 && await constantTimeEqual(code, String(env.ACCESS_CODE))) return true;
  const bearer = request.headers.get('Authorization') || '';
  const token = /^Bearer ([^\s]{1,4096})$/i.exec(bearer)?.[1];
  const emails = allowedEmails(env);
  if (!token || !emails.size) return false;
  try {
    return await withTimeout(async signal => {
      const url = new URL('https://oauth2.googleapis.com/tokeninfo');
      url.searchParams.set('access_token', token);
      // workerd supports manual/follow, not redirect:'error'. Do not follow redirects.
      const response = await fetchImpl(url.href, { signal, redirect: 'manual' });
      if (!response.ok) { await cancelQuietly(response); return false; }
      const info = await readJSON(response, 16 * 1024);
      return info.aud === (env.GOOGLE_CLIENT_ID || GOOGLE_CLIENT_ID) &&
        (info.email_verified === true || info.email_verified === 'true') &&
        Number(info.expires_in) > 0 && typeof info.email === 'string' &&
        emails.has(info.email.toLowerCase());
    }, Math.min(timeoutMs, 8000));
  } catch { return false; }
}

/* A small validator for the plain JSON-schema subset used by both providers.
 * Reject unknown schema constructs rather than pretending to validate them. */
function validSchema(schema, depth = 0) {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema) || depth > 12) return false;
  const types = Array.isArray(schema.type) ? schema.type : [schema.type];
  if (!types.length || types.some(type => !['object', 'array', 'string', 'integer', 'number', 'boolean', 'null'].includes(type))) return false;
  if (Object.keys(schema).some(key => !['type', 'properties', 'required', 'additionalProperties', 'items', 'enum', 'description'].includes(key))) return false;
  if (schema.enum && (!Array.isArray(schema.enum) || schema.enum.length > 100)) return false;
  if (types.includes('object')) {
    if (schema.additionalProperties !== false || !schema.properties || typeof schema.properties !== 'object' || Array.isArray(schema.properties)) return false;
    const keys = Object.keys(schema.properties);
    if (keys.length > 100 || !Array.isArray(schema.required) || schema.required.length !== keys.length ||
      keys.some(key => !schema.required.includes(key) || !validSchema(schema.properties[key], depth + 1))) return false;
  }
  if (types.includes('array') && !validSchema(schema.items, depth + 1)) return false;
  return true;
}

function matchesSchema(value, schema, depth = 0) {
  if (depth > 12) return false;
  const types = Array.isArray(schema.type) ? schema.type : [schema.type];
  const actual = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
  if (!(types.includes(actual) || (actual === 'number' && types.includes('integer') && Number.isInteger(value)))) return false;
  if (schema.enum && !schema.enum.includes(value)) return false;
  if (actual === 'object') {
    const properties = schema.properties || {};
    if (Object.keys(value).some(key => !Object.hasOwn(properties, key)) || schema.required.some(key => !Object.hasOwn(value, key))) return false;
    return Object.entries(value).every(([key, child]) => matchesSchema(child, properties[key], depth + 1));
  }
  if (actual === 'array') return value.every(child => matchesSchema(child, schema.items, depth + 1));
  return actual !== 'number' || Number.isFinite(value);
}

function validateRequest(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
    !['anthropic', 'openai'].includes(body.provider) ||
    typeof body.system !== 'string' || !body.system.trim() || body.system.length > 24000 ||
    typeof body.prompt !== 'string' || !body.prompt.trim() ||
    !validSchema(body.schema) || body.schema.type !== 'object' || JSON.stringify(body.schema).length > 50000) {
    throw new ServiceError(400, 'invalid_request', 'Choose a provider and send valid analysis text and a response schema.');
  }
  const requested = typeof body.maxTokens === 'number' && Number.isFinite(body.maxTokens) ? Math.floor(body.maxTokens) : 8000;
  return { ...body, maxTokens: Math.max(1000, Math.min(16000, requested)) };
}

function upstreamError(status) {
  const detail = status === 429 ? 'The AI provider is busy or has reached its spending limit. Try again later.'
    : status === 401 || status === 403 ? 'The AI provider rejected its API key. Check the Worker secrets.'
      : 'The AI provider could not complete this request. Try again or choose the other provider.';
  return new ServiceError(502, 'provider_error', detail);
}

function normalizedUsage(usage) {
  const result = {};
  for (const key of ['input_tokens', 'output_tokens', 'total_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens']) {
    if (Number.isFinite(usage?.[key]) && usage[key] >= 0) result[key] = usage[key];
  }
  return result;
}

const SAFE_ERROR_TYPES = new Set(['Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'DOMException', 'AbortError', 'TimeoutError']);
function safeErrorType(error) {
  return SAFE_ERROR_TYPES.has(error?.name) ? error.name : 'Error';
}

async function analyze(body, env, fetchImpl, timeoutMs, setStage) {
  setStage('provider_request');
  const provider = body.provider;
  const label = provider === 'anthropic' ? 'Claude' : 'OpenAI';
  const key = String((provider === 'anthropic' ? env.ANTHROPIC_API_KEY : env.OPENAI_API_KEY) || '').trim();
  if (!key) throw new ServiceError(400, 'provider_unavailable', 'That AI provider has not been configured. Choose the other provider.');
  if (/[^\x21-\x7e]/.test(key)) throw new ServiceError(400, 'provider_configuration', `${label}'s API key contains invalid characters. Replace its Cloudflare secret with a single-line API key.`);
  const model = provider === 'anthropic' ? ANTHROPIC_MODEL : OPENAI_MODEL;
  return withTimeout(async signal => {
    const payload = provider === 'anthropic' ? {
      model, max_tokens: body.maxTokens,
      system: body.system, messages: [{ role: 'user', content: body.prompt }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: body.schema } },
    } : {
      model, max_output_tokens: body.maxTokens, store: false,
      reasoning: { effort: 'low' },
      instructions: body.system, input: body.prompt,
      text: { format: { type: 'json_schema', name: 'filter_analysis', schema: body.schema, strict: true } },
    };
    let response;
    try {
      response = await fetchImpl(provider === 'anthropic' ? 'https://api.anthropic.com/v1/messages' : 'https://api.openai.com/v1/responses', {
        method: 'POST', redirect: 'manual', signal,
        headers: provider === 'anthropic' ? {
          'Content-Type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01',
        } : { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
        body: JSON.stringify(payload),
      });
    } catch (error) {
      throw new ServiceError(502, 'provider_connection', `${label} could not be reached from the AI service. [stage:provider_request, type:${safeErrorType(error)}]`);
    }
    setStage('provider_response');
    if (response.status >= 300 && response.status < 400) {
      await cancelQuietly(response);
      throw new ServiceError(502, 'provider_redirect', `${label} returned an unexpected redirect. The AI service did not follow it.`);
    }
    if (!response.ok) {
      await cancelQuietly(response);
      throw upstreamError(response.status);
    }
    let result;
    try { result = await readJSON(response, MAX_UPSTREAM_BYTES); }
    catch { throw new ServiceError(502, 'invalid_response', 'The AI provider returned an unreadable response.'); }
    setStage('response_validation');
    let text;
    if (provider === 'anthropic') {
      if (result.stop_reason !== 'end_turn') {
        throw new ServiceError(502, 'incomplete_response', result.stop_reason === 'max_tokens'
          ? 'The AI result was too long. Try fewer filters or emails.' : 'The AI provider declined or could not finish this request.');
      }
      text = result.content?.filter(block => block.type === 'text').map(block => block.text).join('');
    } else {
      if (result.status !== 'completed') throw new ServiceError(502, 'incomplete_response', 'The AI result was incomplete. Try fewer filters or emails.');
      const content = result.output?.filter(item => item.type === 'message').flatMap(item => item.content || []) || [];
      if (content.some(block => block.type === 'refusal')) throw new ServiceError(502, 'refusal', 'The AI provider declined this request.');
      text = content.filter(block => block.type === 'output_text').map(block => block.text).join('');
    }
    let data;
    try { data = JSON.parse(text); } catch { throw new ServiceError(502, 'invalid_response', 'The AI provider returned an unreadable analysis.'); }
    if (!matchesSchema(data, body.schema)) throw new ServiceError(502, 'invalid_response', 'The AI analysis did not match the expected format. Try again.');
    return { ok: true, provider, model, data, usage: normalizedUsage(result.usage) };
  }, timeoutMs);
}

export async function handleRequest(request, env = {}, { fetchImpl = fetch, timeoutMs = TIMEOUT_MS } = {}) {
  const origin = request.headers.get('Origin');
  const path = new URL(request.url).pathname;
  // Fixed stage names only. Never include raw exception messages or request data.
  let stage = 'auth';
  const setStage = value => { stage = value; };
  try {
    if (request.method === 'OPTIONS') {
      if (!isAllowedOrigin(origin)) throw new ServiceError(403, 'origin_forbidden', 'This website is not allowed to use the service.');
      return new Response(null, { status: 204, headers: { ...corsHeaders(origin), 'Cache-Control': 'no-store' } });
    }
    if (path === '/health' && request.method === 'GET') {
      return json({ build: BUILD, anthropic: Boolean(env.ANTHROPIC_API_KEY), openai: Boolean(env.OPENAI_API_KEY),
        accessCode: Boolean(env.ACCESS_CODE), allowedEmails: allowedEmails(env).size }, 200, origin);
    }
    if (path !== '/analyze') throw new ServiceError(404, 'not_found', 'That service address does not exist.');
    if (request.method !== 'POST') throw new ServiceError(405, 'method_not_allowed', 'Use POST for analysis.');
    if (!isAllowedOrigin(origin)) throw new ServiceError(403, 'origin_forbidden', 'This website is not allowed to use the service.');
    if (!/^application\/json(?:\s*;|\s*$)/i.test(request.headers.get('Content-Type') || '')) {
      throw new ServiceError(400, 'invalid_request', 'Send the request as JSON.');
    }
    if (!await authenticate(request, env, fetchImpl, timeoutMs)) throw new ServiceError(401, 'unauthorized', 'Enter your access code in Settings, or reconnect an allowed Google account.');
    setStage('request_body');
    const body = validateRequest(await withTimeout(() => readJSON(request), Math.min(timeoutMs, 10000)));
    return json(await analyze(body, env, fetchImpl, timeoutMs, setStage), 200, origin);
  } catch (error) {
    if (error instanceof ServiceError) return json({ ok: false, error: error.code, detail: error.message }, error.status, origin);
    // Do not return/log raw upstream errors: they may contain credentials or mail.
    return json({ ok: false, error: 'service_error', detail: `The AI service could not complete the request. [stage:${stage}, type:${safeErrorType(error)}]` }, 502, origin);
  }
}

export default { fetch: (request, env) => handleRequest(request, env) };
