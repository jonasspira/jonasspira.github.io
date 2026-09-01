/**
 * Groton Inventory — product lookup + Notion sync worker
 *
 * Endpoints
 *   GET  /health   — which secrets are configured, and a live probe of each source
 *   POST /lookup   — { query } → normalized product details
 *   POST /sync     — { items:[…] } → rows in the Notion Home Inventory database
 *
 * The lookup chain, in order, stopping when it has enough:
 *   1. UPCitemdb free tier   — no key, ~100 requests/day, identity + recorded price range
 *   2. eBay Browse API       — optional key, identity + live market price
 *   3. Claude                — last resort, identifies from the code or phrase alone
 * Whatever comes back is then normalized by Claude into the exact Notion taxonomy.
 *
 * DEPLOY (Cloudflare dashboard, no command line)
 * 1. dash.cloudflare.com → Workers & Pages → Create → Start with Hello World → Deploy
 * 2. Edit code → replace everything with this file → Deploy
 * 3. Settings → Variables and Secrets → add:
 *      ANTHROPIC_API_KEY   (required — console.anthropic.com → API keys)
 *      NOTION_API_KEY      (required — notion.so/profile/integrations)
 *      EBAY_CLIENT_ID      (optional — developer.ebay.com, production keyset)
 *      EBAY_CLIENT_SECRET  (optional — same place)
 * 4. In Notion: Home Inventory page → ••• → Connections → add your integration.
 * 5. Open https://<your-worker>.workers.dev/health to confirm all four are live.
 */

const NOTION_DATABASE_ID = '556d2953-506a-4f0c-89a7-8ee499b7a229'; // Home Inventory (Groton)
const NOTION_VERSION = '2022-06-28';
const CLAUDE_MODEL = 'claude-haiku-4-5-20251001';

const ALLOWED_ORIGINS = [
  'https://www.spiiira.com',
  'https://spiiira.com',
  'https://jonasspira.github.io',
  'http://localhost',
  'http://127.0.0.1',
];

/* ------------------------------------------------------------------ *
 * Taxonomy — must stay identical to the select options in Notion and
 * to TYPE_MAP in index.html. Change all three together or sync breaks.
 * ------------------------------------------------------------------ */

const TYPE_MAP = {
  'Appliance': ['Refrigeration', 'Cooking', 'Dishwasher', 'Laundry', 'Small Appliance', 'Vacuum/Floor Care', 'Other'],
  'Tool': ['Power Tools', 'Hand Tools', 'Yard & Garden', 'Painting', 'Cleaning Supplies', 'Plumbing Tools', 'Electrical Tools', 'Fasteners & Hardware', 'Safety & PPE', 'Measuring & Layout', 'Auto Tools', 'Storage & Organization', 'Consumables', 'Other'],
  'Home Tech': ['Networking', 'Smart Home', 'Audio/Video', 'Computer/Tablet', 'Apple Device', 'Camera/Security', 'Wearable', 'Gaming', 'Other'],
  'Fixture & System': ['HVAC', 'Plumbing Fixture', 'Electrical/Wiring', 'Water Heater', 'Sump/Well', 'Lighting (built-in)', 'Other'],
  'Furnishing': ['Furniture', 'Decor / Art', 'Rug/Textile', 'Lamp (free-standing)', 'Plant', 'Window Treatment', 'Other'],
  'Vehicle & Outdoor': ['Vehicle', 'Bike', 'Grill/BBQ', 'Patio Furniture', 'Outdoor Structure', 'Yard Equipment', 'Other'],
  'Hobby & Maker': ['Crafting/Maker', '3D Printing', 'Office Equipment', 'Hobby Electronics', 'Other'],
  'Other': ['Other'],
};

/* ------------------------------------------------------------------ *
 * Plumbing
 * ------------------------------------------------------------------ */

function corsHeaders(origin) {
  const allowed = ALLOWED_ORIGINS.some(o => origin && origin.startsWith(o))
    ? origin
    : ALLOWED_ORIGINS[0];
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

function json(data, status, headers) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: {
      ...headers,
      'Content-Type': 'application/json',
      // Without this a browser happily re-serves a stale /health for the same
      // URL, which reads exactly like a deploy that didn't take.
      'Cache-Control': 'no-store',
    },
  });
}

/** fetch with a hard timeout, so one dead source can't hang the whole lookup. */
async function timedFetch(url, options, ms) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms || 8000);
  try {
    return await fetch(url, { ...(options || {}), signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

/** A UPC-A / EAN-8 / EAN-13 / GTIN-14 is just 8, 12, 13 or 14 digits. */
function asBarcode(s) {
  const digits = String(s || '').replace(/[^0-9]/g, '');
  return [8, 12, 13, 14].includes(digits.length) ? digits : null;
}

function firstNumber() {
  for (const v of arguments) {
    const n = Number(v);
    if (v !== null && v !== undefined && v !== '' && !isNaN(n) && n > 0) return n;
  }
  return null;
}

/* ------------------------------------------------------------------ *
 * Source 1 — UPCitemdb (free tier, no key, ~100 requests/day per IP)
 * ------------------------------------------------------------------ */

/**
 * Pull a defensible price out of a UPCitemdb item.
 *
 * `lowest_recorded_price` and `highest_recorded_price` are not trustworthy at
 * the extremes — a can of Coke comes back as a $0–$5000 range, and a $200 drill
 * kit reports a $3 low. The per-merchant `offers` are real observed prices, so
 * take the median of those and ignore the range unless there is nothing else.
 * A wrong value on an insurance record is worse than a blank one, so this
 * returns null rather than guessing.
 */
function recordedPrice(it) {
  const offers = (Array.isArray(it.offers) ? it.offers : [])
    .map(o => firstNumber(o.price))
    .filter(Boolean)
    .sort((a, b) => a - b);

  if (offers.length) {
    return {
      value: offers[Math.floor(offers.length / 2)],
      note: 'Median of ' + offers.length + ' recorded retail ' +
            (offers.length === 1 ? 'offer' : 'offers'),
    };
  }

  // No offers: only trust the recorded range when it isn't obviously junk.
  const low = firstNumber(it.lowest_recorded_price);
  const high = firstNumber(it.highest_recorded_price);
  if (low && high && high / low <= 10) {
    return { value: (low + high) / 2, note: 'Midpoint of recorded price range' };
  }

  return { value: null, note: null };
}

/**
 * Reject a model number that is really something else.
 *
 * UPCitemdb's `model` is frequently a retailer SKU or a mangled barcode — a can of
 * Coke reports model "0004900004256", a Rheem heater reports a Home Depot item
 * number. And with no candidates to work from, the model tends to come back as the
 * product name restated ("Move" for a Sonos Move). All of those are worse than a
 * blank, because a wrong model number on an insurance record looks authoritative.
 */
function cleanModel(model, name, brand, upc) {
  if (!model) return null;
  const m = String(model).trim();
  if (m.length < 2 || m.length > 60) return null;

  const digitsOnly = m.replace(/[^0-9]/g, '');
  // A bare long number is a SKU or a barcode, never a model designation.
  if (/^[0-9\s-]+$/.test(m) && digitsOnly.length >= 10) return null;
  // Or it is literally the barcode we searched with.
  if (upc && (digitsOnly === String(upc) || String(upc).indexOf(digitsOnly) === 0) && digitsOnly.length >= 8) return null;

  const norm = s => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');
  const nm = norm(m);
  if (!nm) return null;
  if (nm === norm(brand)) return null;

  // A model with no digits that is just a word lifted out of the product name is
  // the name restated, not a designation. Real models nearly always carry digits.
  if (!/[0-9]/.test(m) && norm(name).indexOf(nm) !== -1) return null;

  return m;
}

/** Collapse near-duplicate listings so the alternates list shows distinct products. */
function dedupeCandidates(list, limit) {
  const seen = new Set();
  const out = [];
  for (const c of list) {
    if (!c.name) continue;
    const key = String(c.name).toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 40);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(c);
    if (out.length >= (limit || 4)) break;
  }
  return out;
}

function upcitemdbUrl(mode, value) {
  return mode === 'lookup'
    ? 'https://api.upcitemdb.com/prod/trial/lookup?upc=' + encodeURIComponent(value)
    : 'https://api.upcitemdb.com/prod/trial/search?s=' + encodeURIComponent(value) + '&match_mode=0&type=product';
}

async function upcitemdb(query, barcode) {
  // Their barcode catalogue is much thinner on hardware than their keyword index
  // is — a UPC that returns nothing often turns up as a search hit, so on a miss
  // we spend one more of the daily allowance rather than give up.
  const attempts = barcode
    ? [['lookup', barcode], ['search', barcode]]
    : [['search', query]];

  let lastError = null;
  let remaining = null;

  for (const [mode, value] of attempts) {
    const resp = await timedFetch(upcitemdbUrl(mode, value), { headers: { 'Accept': 'application/json' } }, 8000);
    remaining = resp.headers.get('X-RateLimit-Remaining') || remaining;

    if (!resp.ok) {
      lastError = 'HTTP_' + resp.status;
      try { lastError = (await resp.json()).code || lastError; } catch (e) { /* body not JSON */ }
      // A rate-limit or auth failure won't fix itself on the next attempt.
      if (resp.status === 429 || resp.status === 401) break;
      continue;
    }

    const data = await resp.json();
    const items = Array.isArray(data.items) ? data.items.slice(0, 5) : [];
    if (items.length === 0) {
      lastError = null;
      continue;   // reachable, just no match — try the next attempt
    }
    return { ok: true, mode: mode, remaining: remaining, candidates: items.map(it => ({
      source: 'upcitemdb',
      name: it.title || null,
      brand: it.brand || null,
      model: it.model || null,
      upc: it.upc || it.ean || it.gtin || barcode || null,
      category: it.category || null,
      imageUrl: (Array.isArray(it.images) && it.images[0]) || null,
      price: recordedPrice(it).value,
      priceNote: recordedPrice(it).note,
      description: it.description || null,
    })) };
  }

  // Every attempt was reachable but empty, or the last one errored.
  return { ok: !lastError, error: lastError, remaining: remaining, candidates: [] };
}

/* ------------------------------------------------------------------ *
 * Source 2 — eBay Browse API (optional; identity plus live market price)
 * ------------------------------------------------------------------ */

// Cached in the isolate. Workers reuse isolates, so most requests skip the mint.
let ebayToken = { value: null, expiresAt: 0 };

async function ebayAccessToken(env) {
  if (!env.EBAY_CLIENT_ID || !env.EBAY_CLIENT_SECRET) return null;
  if (ebayToken.value && Date.now() < ebayToken.expiresAt) return ebayToken.value;

  const basic = btoa(env.EBAY_CLIENT_ID + ':' + env.EBAY_CLIENT_SECRET);
  const resp = await timedFetch('https://api.ebay.com/identity/v1/oauth2/token', {
    method: 'POST',
    headers: {
      'Authorization': 'Basic ' + basic,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials&scope=' + encodeURIComponent('https://api.ebay.com/oauth/api_scope'),
  }, 8000);

  if (!resp.ok) throw new Error('eBay token ' + resp.status);
  const data = await resp.json();
  ebayToken = {
    value: data.access_token,
    // Refresh a minute early so a request never races the expiry.
    expiresAt: Date.now() + ((data.expires_in || 7200) - 60) * 1000,
  };
  return ebayToken.value;
}

async function ebay(env, query, barcode) {
  const token = await ebayAccessToken(env);
  if (!token) return { ok: false, error: 'NOT_CONFIGURED', candidates: [] };

  const params = barcode
    ? 'gtin=' + encodeURIComponent(barcode)
    : 'q=' + encodeURIComponent(query);
  const url = 'https://api.ebay.com/buy/browse/v1/item_summary/search?' + params +
    '&limit=8&filter=' + encodeURIComponent('conditions:{NEW}');

  const resp = await timedFetch(url, {
    headers: {
      'Authorization': 'Bearer ' + token,
      'X-EBAY-C-MARKETPLACE-ID': 'EBAY_US',
      'Accept': 'application/json',
    },
  }, 8000);

  if (!resp.ok) {
    // A 401 means the cached token went stale early; drop it so the next call re-mints.
    if (resp.status === 401) ebayToken = { value: null, expiresAt: 0 };
    return { ok: false, error: 'HTTP_' + resp.status, candidates: [] };
  }

  const data = await resp.json();
  const summaries = Array.isArray(data.itemSummaries) ? data.itemSummaries : [];
  if (summaries.length === 0) return { ok: true, candidates: [] };

  // Median asking price across new listings is a steadier replacement-cost
  // estimate than the cheapest one, which is usually an accessory or a knockoff.
  const prices = summaries
    .map(s => firstNumber(s.price && s.price.value))
    .filter(Boolean)
    .sort((a, b) => a - b);
  const median = prices.length
    ? prices[Math.floor(prices.length / 2)]
    : null;

  return {
    ok: true,
    candidates: summaries.slice(0, 5).map((s, i) => ({
      source: 'ebay',
      name: s.title || null,
      brand: (s.brand) || null,
      model: null,
      upc: barcode || null,
      category: (s.categories && s.categories[0] && s.categories[0].categoryName) || null,
      imageUrl: (s.image && s.image.imageUrl) || null,
      // Only the top match carries the market price; the rest are alternates.
      price: i === 0 ? median : firstNumber(s.price && s.price.value),
      priceNote: i === 0 && median
        ? 'Median asking price across ' + prices.length + ' new eBay listings'
        : null,
      link: s.itemWebUrl || null,
    })),
  };
}

/* ------------------------------------------------------------------ *
 * Source 3 + normalizer — Claude
 * ------------------------------------------------------------------ */

const NORMALIZE_PROMPT = `You are filling in one row of a home inventory for insurance purposes.

You will get a search query (a barcode number, or a product name typed by hand) and
zero or more candidate records retrieved from product databases. Turn them into one
clean record.

Return ONLY a JSON object, no markdown fences, no commentary:

{
  "name": "short specific item name a person would recognize, e.g. '20V Cordless Drill' or 'KitchenAid Stand Mixer 5qt'. Strip marketing filler, seller names, condition words, and shipping text out of retail listing titles.",
  "brand": "manufacturer only, e.g. 'DeWalt' — null if unknown",
  "model": "the MANUFACTURER's own model or part number, as printed on the product or its rating plate — e.g. 'DCD771C2', 'WM4000HWA', 'S17'. null if you do not actually know it.",
  "assetType": one of exactly: "Appliance" | "Tool" | "Home Tech" | "Fixture & System" | "Furnishing" | "Vehicle & Outdoor" | "Hobby & Maker" | "Other",
  "type": subcategory — must be one of the options listed for the assetType you chose:
    Appliance → "Refrigeration" | "Cooking" | "Dishwasher" | "Laundry" | "Small Appliance" | "Vacuum/Floor Care" | "Other"
    Tool → "Power Tools" | "Hand Tools" | "Yard & Garden" | "Painting" | "Cleaning Supplies" | "Plumbing Tools" | "Electrical Tools" | "Fasteners & Hardware" | "Safety & PPE" | "Measuring & Layout" | "Auto Tools" | "Storage & Organization" | "Consumables" | "Other"
    Home Tech → "Networking" | "Smart Home" | "Audio/Video" | "Computer/Tablet" | "Apple Device" | "Camera/Security" | "Wearable" | "Gaming" | "Other"
    Fixture & System → "HVAC" | "Plumbing Fixture" | "Electrical/Wiring" | "Water Heater" | "Sump/Well" | "Lighting (built-in)" | "Other"
    Furnishing → "Furniture" | "Decor / Art" | "Rug/Textile" | "Lamp (free-standing)" | "Plant" | "Window Treatment" | "Other"
    Vehicle & Outdoor → "Vehicle" | "Bike" | "Grill/BBQ" | "Patio Furniture" | "Outdoor Structure" | "Yard Equipment" | "Other"
    Hobby & Maker → "Crafting/Maker" | "3D Printing" | "Office Equipment" | "Hobby Electronics" | "Other"
    Other → "Other",
  "estimatedValue": replacement cost in USD as a plain number, or null,
  "valueBasis": one short phrase saying where estimatedValue came from, e.g. "Median of 8 new eBay listings" or "Estimate — no price found",
  "confidence": "high" | "medium" | "low",
  "notes": "one short line of useful detail (size, capacity, colour, wattage) or null"
}

Rules:

PICK THE BASE PRODUCT, NOT A LISTING.
- Retail listings are full of bundles, multi-packs and accessories. Choose the item
  itself as the manufacturer sells it. Exclude "with case", "+ charger", "bundle",
  "2-pack", "refurbished", "renewed", "open box", and replacement parts or
  accessories sold separately (cases, mounts, stands, filters, loose batteries) —
  unless the query is explicitly asking for one of those.
- A kit the manufacturer sells as one SKU is a base product, not a bundle. "DCD771C2
  Drill/Driver Kit" is correct; "DCD771C2 + extra battery + work light" is not.
- name is the product, not the listing headline. No seller names, no condition
  words, no shipping or promo text, no ALL CAPS.

MODEL NUMBERS — the strictest field here.
- Only give a model you actually know to be the manufacturer's designation.
- NEVER use: a retailer SKU or item number, a UPC/EAN or any bare 10+ digit number,
  the brand name, or the product name restated. If a candidate record's "model"
  looks like any of those, it is junk metadata — discard it and return null.
- "Sonos Move" is a product name, not a model. Returning "Move" as the model is
  wrong; return null instead.
- A blank model is a correct answer. A plausible-looking wrong one is a defect,
  because this ends up on an insurance record.

CONFIDENCE means verified, not familiar.
- "high" requires candidate records that agree with each other.
- With NO candidates you are working from memory alone and nothing has been checked:
  use "medium" at best for a product you know well, and "low" for anything else.
- A bare barcode you do not recognise returns confidence "low" and null name — do
  not invent a product.

VALUE.
- estimatedValue is what it would cost to replace the item new today.
- Prefer a price from a candidate record over your own estimate, and say which in
  valueBasis. If it is your own estimate, valueBasis must say so plainly.`;

async function claudeNormalize(env, query, candidates) {
  if (!env.ANTHROPIC_API_KEY) return null;

  const payload = {
    query,
    candidates: candidates.slice(0, 6).map(c => ({
      source: c.source, name: c.name, brand: c.brand, model: c.model,
      category: c.category, price: c.price, priceNote: c.priceNote,
      description: c.description ? String(c.description).slice(0, 400) : null,
    })),
  };

  const resp = await timedFetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': env.ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: CLAUDE_MODEL,
      max_tokens: 600,
      system: NORMALIZE_PROMPT,
      messages: [{ role: 'user', content: JSON.stringify(payload) }],
    }),
  }, 20000);

  if (!resp.ok) throw new Error('Anthropic ' + resp.status);

  const data = await resp.json();
  const raw = (data.content && data.content[0] && data.content[0].text) || '{}';
  try {
    return JSON.parse(raw);
  } catch (e) {
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return null;
    try { return JSON.parse(match[0]); } catch (e2) { return null; }
  }
}

/* ------------------------------------------------------------------ *
 * POST /lookup
 * ------------------------------------------------------------------ */

async function handleLookup(body, env, headers) {
  const query = String(body.query || '').trim();
  if (!query) return json({ error: 'Missing query' }, 400, headers);
  if (query.length > 200) return json({ error: 'Query too long' }, 400, headers);

  const barcode = asBarcode(query);
  const sources = [];
  let candidates = [];

  // Both databases are queried in parallel — they fail independently and the
  // slower one shouldn't add its latency to the faster one.
  const [dbResult, ebayResult] = await Promise.allSettled([
    upcitemdb(query, barcode),
    ebay(env, query, barcode),
  ]);

  for (const [name, result] of [['upcitemdb', dbResult], ['ebay', ebayResult]]) {
    if (result.status === 'fulfilled') {
      const r = result.value;
      sources.push({ name, ok: r.ok, error: r.error || null, hits: r.candidates.length });
      candidates = candidates.concat(r.candidates);
    } else {
      sources.push({ name, ok: false, error: String(result.reason && result.reason.message || result.reason), hits: 0 });
    }
  }

  let normalized = null;
  let normalizeError = null;
  try {
    normalized = await claudeNormalize(env, query, candidates);
  } catch (e) {
    normalizeError = String(e && e.message || e);
  }
  sources.push({ name: 'claude', ok: !!normalized, error: normalizeError, hits: normalized ? 1 : 0 });

  if (!normalized && candidates.length === 0) {
    return json({
      error: 'Nothing found for that code or phrase',
      sources,
    }, 404, headers);
  }

  // Fall back to the best raw candidate if Claude couldn't be reached.
  const top = candidates[0] || {};
  const resolvedName = (normalized && normalized.name) || top.name || null;
  const resolvedBrand = (normalized && normalized.brand) || top.brand || null;
  const resolvedUpc = barcode || top.upc || null;

  // With nothing retrieved, the answer is unverified recall no matter how sure the
  // model sounds. Cap it here rather than trusting the prompt to hold the line.
  const verified = candidates.length > 0;
  let confidence = (normalized && normalized.confidence) || 'low';
  if (!verified && confidence === 'high') confidence = 'medium';

  const result = {
    name: resolvedName,
    brand: resolvedBrand,
    model: cleanModel((normalized && normalized.model) || top.model || null,
                      resolvedName, resolvedBrand, resolvedUpc),
    upc: resolvedUpc,
    assetType: null,
    type: null,
    estimatedValue: (normalized && firstNumber(normalized.estimatedValue)) || top.price || null,
    valueBasis: (normalized && normalized.valueBasis) || top.priceNote || null,
    confidence: confidence,
    verified: verified,
    notes: (normalized && normalized.notes) || null,
    imageUrl: top.imageUrl || null,
    sources,
    // Alternates the app can offer if the top answer is wrong. Deduped, because
    // five spellings of the same listing is noise, not choice.
    candidates: dedupeCandidates(candidates, 4).map(c => ({
      source: c.source, name: c.name, brand: c.brand,
      price: c.price, imageUrl: c.imageUrl, link: c.link || null,
    })),
  };

  // Only accept a taxonomy pair that actually exists — a hallucinated
  // subcategory would be rejected by Notion at sync time, which is worse.
  if (normalized && TYPE_MAP[normalized.assetType]) {
    result.assetType = normalized.assetType;
    if (TYPE_MAP[normalized.assetType].includes(normalized.type)) {
      result.type = normalized.type;
    }
  }

  return json(result, 200, headers);
}

/* ------------------------------------------------------------------ *
 * POST /sync — write to Notion
 * ------------------------------------------------------------------ */

/** Map one app item to Notion page properties. Names must match the database exactly. */
function notionProperties(item) {
  const props = {
    'Item': { title: [{ text: { content: String(item.item || 'Untitled item').slice(0, 200) } }] },
  };
  if (item.assetType) props['Asset Type'] = { select: { name: item.assetType } };
  if (item.type) props['Type'] = { select: { name: item.type } };
  if (item.location) props['Location'] = { select: { name: item.location } };
  if (item.brand) props['Brand'] = { select: { name: String(item.brand).slice(0, 100) } };
  if (item.condition) props['Condition'] = { select: { name: item.condition } };
  if (item.model) props['Model'] = { rich_text: [{ text: { content: String(item.model).slice(0, 1900) } }] };
  if (item.serial) props['Serial'] = { rich_text: [{ text: { content: String(item.serial).slice(0, 1900) } }] };
  if (item.upc) props['UPC'] = { rich_text: [{ text: { content: String(item.upc).slice(0, 100) } }] };
  if (item.notes) props['Notes'] = { rich_text: [{ text: { content: String(item.notes).slice(0, 1900) } }] };
  if (item.acquired) props['Acquired'] = { date: { start: item.acquired } };
  if (item.value !== null && item.value !== undefined && !isNaN(item.value)) {
    props['Value (USD)'] = { number: Number(item.value) };
  }
  return props;
}

async function handleSync(body, env, headers) {
  if (!env.NOTION_API_KEY) {
    return json({ error: 'NOTION_API_KEY is not set on the worker' }, 500, headers);
  }
  const items = Array.isArray(body.items) ? body.items : null;
  if (!items || items.length === 0) return json({ error: 'No items to sync' }, 400, headers);
  if (items.length > 50) return json({ error: 'Max 50 items per sync — sync in smaller batches' }, 400, headers);

  const results = [];
  for (const item of items) {
    try {
      const resp = await timedFetch('https://api.notion.com/v1/pages', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + env.NOTION_API_KEY,
          'Notion-Version': NOTION_VERSION,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          parent: { database_id: NOTION_DATABASE_ID },
          properties: notionProperties(item),
        }),
      }, 15000);

      if (resp.ok) {
        const page = await resp.json();
        results.push({ ok: true, id: item.id || null, notionUrl: page.url || null });
      } else {
        const errText = await resp.text();
        let message = 'Notion error ' + resp.status;
        try { message = JSON.parse(errText).message || message; } catch (e) { /* not JSON */ }
        results.push({ ok: false, id: item.id || null, error: message });
      }
    } catch (e) {
      results.push({ ok: false, id: item.id || null, error: String(e && e.message || e) });
    }
    // Stay under Notion's ~3 requests/second rate limit.
    await new Promise(r => setTimeout(r, 350));
  }

  const synced = results.filter(r => r.ok).length;
  return json({ synced, failed: results.length - synced, results }, 200, headers);
}

/* ------------------------------------------------------------------ *
 * GET /health — is everything actually wired up?
 * ------------------------------------------------------------------ */

async function handleHealth(env, headers, deep) {
  const report = {
    worker: 'ok',
    checkedAt: new Date().toISOString(),
    mode: deep ? 'deep — live probes, spends one UPCitemdb lookup' : 'quick',
    secrets: {
      ANTHROPIC_API_KEY: !!env.ANTHROPIC_API_KEY,
      NOTION_API_KEY: !!env.NOTION_API_KEY,
      EBAY_CLIENT_ID: !!env.EBAY_CLIENT_ID,
      EBAY_CLIENT_SECRET: !!env.EBAY_CLIENT_SECRET,
    },
    probes: {},
  };

  // Verified present in UPCitemdb, so zero hits means the source is broken
  // rather than the catalogue merely being thin for this product.
  const probeUpc = '049000042566';

  // The UPCitemdb allowance is small and shared, so a routine health check must
  // not spend it. Only /health?deep=1 hits the product sources for real.
  const skip = Promise.resolve({
    ok: null, candidates: [], error: 'NOT_PROBED',
    hint: 'Add ?deep=1 to actually call this source.',
  });

  const [db, eb, notion] = await Promise.allSettled([
    deep ? upcitemdb(probeUpc, probeUpc) : skip,
    deep ? ebay(env, probeUpc, probeUpc) : skip,
    env.NOTION_API_KEY
      ? timedFetch('https://api.notion.com/v1/databases/' + NOTION_DATABASE_ID, {
          headers: {
            'Authorization': 'Bearer ' + env.NOTION_API_KEY,
            'Notion-Version': NOTION_VERSION,
          },
        }, 10000)
      : Promise.reject(new Error('NOTION_API_KEY not set')),
  ]);

  if (db.status === 'fulfilled' && db.value.ok === null) {
    report.probes.upcitemdb = { ok: null, hint: db.value.hint };
  } else if (db.status === 'fulfilled') {
    const hits = db.value.candidates.length;
    report.probes.upcitemdb = {
      ok: db.value.ok && hits > 0,
      hits: hits,
      matchedBy: db.value.mode || null,
      lookupsLeftToday: db.value.remaining !== null && db.value.remaining !== undefined
        ? Number(db.value.remaining) : 'unknown',
      error: db.value.error || null,
      hint: hits > 0 ? null
        : 'Reachable but returned nothing for a barcode known to be in the catalogue — likely the daily cap.',
    };
  } else {
    report.probes.upcitemdb = { ok: false, error: String(db.reason && db.reason.message || db.reason) };
  }

  if (eb.status === 'fulfilled' && eb.value.ok === null) {
    report.probes.ebay = {
      ok: null,
      configured: !!(env.EBAY_CLIENT_ID && env.EBAY_CLIENT_SECRET),
      hint: eb.value.hint,
    };
  } else if (eb.status === 'fulfilled') {
    report.probes.ebay = {
      ok: eb.value.ok && eb.value.candidates.length > 0,
      hits: eb.value.candidates.length,
      error: eb.value.error || null,
      hint: eb.value.error === 'NOT_CONFIGURED'
        ? 'Optional. Without eBay keys there is no live market pricing, and hardware barcodes have thinner coverage.'
        : null,
    };
  } else {
    report.probes.ebay = { ok: false, error: String(eb.reason && eb.reason.message || eb.reason) };
  }

  if (notion.status === 'fulfilled') {
    const ok = notion.value.ok;
    let error = null;
    if (!ok) {
      const t = await notion.value.text();
      try { error = JSON.parse(t).message; } catch (e) { error = 'HTTP ' + notion.value.status; }
    }
    report.probes.notion = {
      ok,
      error,
      hint: ok ? null : 'Open the Home Inventory page in Notion → ••• → Connections → add your integration.',
    };
  } else {
    report.probes.notion = { ok: false, error: String(notion.reason && notion.reason.message || notion.reason) };
  }

  if (!deep) {
    report.probes.claude = {
      ok: null,
      configured: !!env.ANTHROPIC_API_KEY,
      hint: 'Add ?deep=1 to actually call this source.',
    };
  } else if (env.ANTHROPIC_API_KEY) {
    try {
      // Sent with no candidates on purpose: a null name here is the guard against
      // inventing products working correctly, not a failure.
      const n = await claudeNormalize(env, probeUpc, []);
      report.probes.claude = {
        ok: !!n,
        sample: n ? n.name : null,
        note: n && !n.name
          ? 'Responded, and correctly declined to invent a product for a bare barcode.'
          : null,
      };
    } catch (e) {
      report.probes.claude = { ok: false, error: String(e && e.message || e) };
    }
  } else {
    report.probes.claude = { ok: false, error: 'ANTHROPIC_API_KEY not set' };
  }

  return json(report, 200, headers);
}

/* ------------------------------------------------------------------ *
 * Router
 * ------------------------------------------------------------------ */

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const headers = corsHeaders(origin);
    const path = new URL(request.url).pathname.replace(/\/+$/, '');

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers });
    }

    if (path.endsWith('/health')) {
      const deep = new URL(request.url).searchParams.get('deep') === '1';
      return handleHealth(env, headers, deep);
    }

    if (request.method !== 'POST') {
      return json({ error: 'Method not allowed. Try GET /health.' }, 405, headers);
    }

    let body;
    try {
      body = await request.json();
    } catch (e) {
      return json({ error: 'Invalid JSON body' }, 400, headers);
    }

    if (path.endsWith('/sync')) return handleSync(body, env, headers);
    if (path.endsWith('/lookup')) return handleLookup(body, env, headers);

    return json({ error: 'Unknown endpoint. Use /lookup, /sync or /health.' }, 404, headers);
  },
};
