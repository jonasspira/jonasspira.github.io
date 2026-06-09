/**
 * Groton Inventory — Vision Worker
 * Cloudflare Worker: proxies images to Claude for item identification.
 *
 * DEPLOY INSTRUCTIONS:
 * 1. Install Wrangler: npm install -g wrangler
 * 2. wrangler login
 * 3. wrangler deploy worker.js --name groton-vision --compatibility-date 2024-01-01
 * 4. wrangler secret put ANTHROPIC_API_KEY   (paste your key when prompted)
 * 5. Copy the deployed URL into VISION_WORKER_URL in index.html
 *
 * Or deploy via the Cloudflare dashboard (Workers > Create > Paste this file).
 */

const ALLOWED_ORIGINS = [
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
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400, headers: { ...headers, 'Content-Type': 'application/json' }
      });
    }

    const { image, mimeType } = body;
    if (!image || !mimeType) {
      return new Response(JSON.stringify({ error: 'Missing image or mimeType' }), {
        status: 400, headers: { ...headers, 'Content-Type': 'application/json' }
      });
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
      return new Response(JSON.stringify({ error: 'Anthropic API error', detail: err }), {
        status: 502, headers: { ...headers, 'Content-Type': 'application/json' }
      });
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

    return new Response(JSON.stringify(result), {
      headers: { ...headers, 'Content-Type': 'application/json' }
    });
  }
};
