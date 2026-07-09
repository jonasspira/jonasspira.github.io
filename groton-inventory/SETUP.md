# Groton Inventory v2 — Setup Guide

v2 adds two features, both powered by one small Cloudflare Worker:

- **📷 Identify from Photo** — snap a picture, Claude fills in the form (name, brand, category, model, value).
- **Sync to Notion** — one tap pushes unsynced items straight into the Home Inventory database. No more copy-paste.

You need to do four things once. Everything is free except the Anthropic API usage, which costs a fraction of a cent per photo.

---

## 1. Get an Anthropic API key (~3 min)

1. Go to **console.anthropic.com** and sign in (this is separate from your Claude.ai account).
2. Add a payment method under **Billing** — $5 of credit will last a very long time at inventory scale.
3. Go to **API keys → Create key**. Name it `groton-vision`.
4. Copy the key (starts with `sk-ant-`) somewhere safe — you only see it once.

## 2. Create a Notion integration (~3 min)

This is how the worker gets permission to write to your database.

1. Go to **notion.so/profile/integrations** (or Notion → Settings → Connections → Develop or manage integrations).
2. **New integration**. Name: `Groton Inventory`. Workspace: your workspace. Type: Internal.
3. Under **Capabilities**, it needs *Insert content* (Read is fine to leave on too).
4. Copy the **Internal Integration Secret** (starts with `ntn_` or `secret_`).
5. **Important:** in Notion, open the **Home Inventory** page (under Groton) → click the **•••** menu (top right) → **Connections** → add **Groton Inventory**. Without this step the worker gets "not found" errors.

## 3. Deploy the worker (~5 min)

1. Go to **dash.cloudflare.com** → **Workers & Pages** → **Create** → **Start with Hello World** → **Deploy**.
2. Click **Edit code**, delete everything, paste in the full contents of `worker.js`, then **Deploy**.
3. Go to the worker's **Settings → Variables and Secrets** → **Add**:
   - Type **Secret**, name `ANTHROPIC_API_KEY`, value = your key from step 1.
   - Type **Secret**, name `NOTION_API_KEY`, value = your secret from step 2.
4. Copy the worker's URL — it looks like `https://something.your-account.workers.dev`.

## 4. Connect the app

Open `index.html`, find this line near the top of the `<script>` section:

```js
const WORKER_URL = '';
```

Paste your worker URL between the quotes, then push to GitHub. (Or just give Claude the URL — it'll do this part and push.)

---

## How to tell it's working

- The **📷 Identify from Photo** button turns teal instead of grey.
- Take a photo of anything — in a few seconds the form fills itself in.
- Log a couple of items, open **Sync**, tap **Sync to Notion** — they appear in the Notion database and grey out in the app.

## If something breaks

- **Photo ID fails:** check the `ANTHROPIC_API_KEY` secret and that billing is set up at console.anthropic.com.
- **Sync fails with "not found":** you skipped the Connections step (step 2.5) — the integration can't see the database.
- **Everything fails:** the old copy-paste export still exists under Sync → "Manual Export (Fallback)".
