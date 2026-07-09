/**
 * Groton Inventory — Vision + Sync Worker
 * Cloudflare Worker with two endpoints:
 *   POST /identify — photo in, item details out (via Claude vision)
 *   POST /sync     — items in, written directly to the Notion Home Inventory database
 *
 * DEPLOY (Cloudflare dashboard, no command line needed):
 * 1. dash.cloudflare.com → Workers & Pages → Create → Start with Hello World → Deploy
 * 2. Edit code → replace everything with this file → Deploy
 * 3. Settings → Variables and Secrets → add two SECRETS:
 *      ANTHROPIC_API_KEY  (from console.anthropic.com → API keys)
 *      NOTION_API_KEY     (from notion.so/profile/integrations → your integration's secret)
 * 4. In Notion: open the "Home Inventory" page → ••• menu → Connections → add your integration.
 * 5. Copy the worker URL (https://<name>.<account>.workers.dev) into WORKER_URL in index.html.
 */

const NOTION_DATABASE_ID = '556d2953-506a-4f0c-89a7-8ee499b7a229'; // Home Inventory (Groton)

const ALLOWED_ORIGINS = [
  'https://www.spiiira.com',
  'https://spiiira.com',
  'https://jonasspira.github.io',
  'http://localhost',
  'http://127.0.0.1',
];

function corsHeaders(origin) {
  const allowed = ALLOWED_ORIGINS.some(o => origin && origin.startsWith(o))
    ? origin
    : ALLOWED_ORIGINS[0];
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

function json(data, status, headers) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: { ...headers, 'Content-Type': 'application/json' },
  });
}

const SYSTEM_PROMPT = `You are identifying a household item for a home inventory app.
Analyze the image and return a JSON object with these exact fields (use null for anything uncertain):

{
  "name": "specific item name, e.g. '20V Cordless Drill' or 'KitchenAid Stand Mixer 5qt'",
  "brand": "manufacturer, e.g. 'DeWalt', 'Apple', 'Whirlpool'",
  "assetType": one of exactly: "Appliance" | "Tool" | "Home Tech" | "Fixture & System" | "Furnishing" | "Vehicle & Outdoor" | "Hobby & Maker" | "Other",
  "type": subcategory string — must match the list for the chosen assetType:
    Appliance → "Refrigeration" | "Cooking" | "Dishwasher" | "Laundry" | "Small Appliance" | "Vacuum/Floor Care" | "Other"
    Tool → "Power Tools" | "Hand Tools" | "Yard & Garden" | "Painting" | "Cleaning Supplies" | "Plumbing Tools" | "Electrical Tools" | "Fasteners & Hardware" | "Safety & PPE" | "Measuring & Layout" | "Auto Tools" | "Storage & Organization" | "Consumables" | "Other"
    Home Tech → "Networking" | "Smart Home" | "Audio/Video" | "Computer/Tablet" | "Apple Device" | "Camera/Security" | "Wearable" | "Gaming" | "Other"
    Fixture & System → "HVAC" | "Plumbing Fixture" | "Electrical/Wiring" | "Water Heater" | "Sump/Well" | "Lighting (built-in)" | "Other"
    Furnishing → "Furniture" | "Decor / Art" | "Rug/Textile" | "Lamp (free-standing)" | "Plant" | "Window Treatment" | "Other"
    Vehicle & Outdoor → "Vehicle" | "Bike" | "Grill/BBQ" | "Patio Furniture" | "Outdoor Structure" | "Yard Equipment" | "Other"
    Hobby & Maker → "Crafting/Maker" | "3D Printing" | "Office Equipment" | "Hobby Electronics" | "Other"
    Other → "Other",
  "model": "model number or name if visible on the item, else null",
  "estimatedValue": replacement cost in USD as a number (no $ sign), or null if unsure,
  "notes": "brief useful detail: color, size, visible condition, any serial/model number spotted — null if nothing notable"
}

Respond with ONLY the JSON object. No explanation, no markdown fences.`;

async function handleIdentify(body, env, headers) {
  const { image, mimeType } = body;
  if (!image || !mimeType) {
    return json({ error: 'Missing image or mimeType' }, 400, headers);
  }

  const anthropicResp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': env.ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 512,
      system: SYSTEM_PROMPT,
      messages: [{
        role: 'user',
        content: [{
          type: 'image',
          source: { type: 'base64', media_type: mimeType, data: image }
        }, {
          type: 'text',
          text: 'Identify this item.'
        }]
      }]
    })
  });

  if (!anthropicResp.ok) {
    const err = await anthropicResp.text();
    return json({ error: 'Anthropic API error', detail: err }, 502, headers);
  }

  const data = await anthropicResp.json();
  const raw = data.content?.[0]?.text || '{}';

  let result;
  try {
    result = JSON.parse(raw);
  } catch {
    const match = raw.match(/\{[\s\S]*\}/);
    try { result = match ? JSON.parse(match[0]) : { error: 'Parse failed', raw }; }
    catch { result = { error: 'Parse failed', raw }; }
  }

  return json(result, 200, headers);
}

/** Map one app item to Notion page properties (names must match the database exactly). */
function notionProperties(item) {
  const props = {
    'Item': { title: [{ text: { content: String(item.item || 'Untitled item').slice(0, 200) } }] },
  };
  if (item.assetType) props['Asset Type'] = { select: { name: item.assetType } };
  if (item.type) props['Type'] = { select: { name: item.type } };
  if (item.location) props['Location'] = { select: { name: item.location } };
  if (item.brand) props['Brand'] = { select: { name: item.brand } };
  if (item.condition) props['Condition'] = { select: { name: item.condition } };
  if (item.model) props['Model'] = { rich_text: [{ text: { content: String(item.model) } }] };
  if (item.serial) props['Serial'] = { rich_text: [{ text: { content: String(item.serial) } }] };
  if (item.notes) props['Notes'] = { rich_text: [{ text: { content: String(item.notes) } }] };
  if (item.acquired) props['Acquired'] = { date: { start: item.acquired } };
  if (item.value !== null && item.value !== undefined && !isNaN(item.value)) {
    props['Value (USD)'] = { number: Number(item.value) };
  }
  return props;
}

async function handleSync(body, env, headers) {
  const items = Array.isArray(body.items) ? body.items : null;
  if (!items || items.length === 0) {
    return json({ error: 'No items to sync' }, 400, headers);
  }
  if (items.length > 50) {
    return json({ error: 'Max 50 items per sync — sync in smaller batches' }, 400, headers);
  }

  const results = [];
  for (const item of items) {
    try {
      const resp = await fetch('https://api.notion.com/v1/pages', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + env.NOTION_API_KEY,
          'Notion-Version': '2022-06-28',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          parent: { database_id: NOTION_DATABASE_ID },
          properties: notionProperties(item),
        }),
      });
      if (resp.ok) {
        const page = await resp.json();
        results.push({ ok: true, id: item.id || null, notionUrl: page.url || null });
      } else {
        const errText = await resp.text();
        let message = 'Notion error ' + resp.status;
        try { message = JSON.parse(errText).message || message; } catch {}
        results.push({ ok: false, id: item.id || null, error: message });
      }
    } catch (e) {
      results.push({ ok: false, id: item.id || null, error: String(e && e.message || e) });
    }
    // Stay under Notion's ~3 requests/second rate limit
    await new Promise(r => setTimeout(r, 350));
  }

  const synced = results.filter(r => r.ok).length;
  return json({ synced, failed: results.length - synced, results }, 200, headers);
}

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const headers = corsHeaders(origin);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers });
    }
    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405, headers });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400, headers);
    }

    const path = new URL(request.url).pathname;
    if (path.endsWith('/sync')) {
      return handleSync(body, env, headers);
    }
    // /identify — also the default so the original single-endpoint contract still works
    return handleIdentify(body, env, headers);
  }
};
