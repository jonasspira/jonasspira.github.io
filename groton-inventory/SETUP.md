# Groton Inventory — setup

The app is one static HTML file. Everything that needs a secret lives in a single
Cloudflare Worker, so no key is ever in the page source.

The worker does two jobs:

- **`/lookup`** — you type a barcode or a product name, it comes back with the item's
  name, brand, model, category and replacement value.
- **`/sync`** — writes unsynced items into the Notion Home Inventory database.

If you already ran the v2 setup, you have the first two secrets. Skip to step 3.

---

## What lives where

| Path | What it is |
|---|---|
| `jonasspira/groton-inventory` | Source of truth. Edit here. |
| `jonasspira.github.io/groton-inventory/` | Deployed copy, served at spiiira.com/groton-inventory/ |
| Cloudflare worker | `groton-vision.jonas-spira.workers.dev` |
| Notion | Home Inventory database, under Groton |

The two repo copies are kept in sync by hand — change one, copy to the other, commit
both. The worker is deployed by pasting `worker.js` into the Cloudflare dashboard.

---

## 1. Anthropic API key (required)

Used to turn messy retail listing titles into clean inventory rows, and to identify
anything the product databases miss.

1. **console.anthropic.com** → sign in (separate from your Claude.ai account).
2. Add a payment method under **Billing**. $5 lasts a very long time — each lookup is
   a fraction of a cent on Haiku.
3. **API keys → Create key**, name it `groton-inventory`.
4. Copy it (starts with `sk-ant-`). You only see it once.

## 2. Notion integration (required)

1. **notion.so/profile/integrations** → **New integration**.
   Name `Groton Inventory`, type Internal, your workspace.
2. Under **Capabilities** it needs *Insert content*.
3. Copy the **Internal Integration Secret** (starts with `ntn_` or `secret_`).
4. **This step is the one people skip:** in Notion, open the **Home Inventory** page
   under Groton → **•••** menu → **Connections** → add **Groton Inventory**. Without
   it every sync fails with "not found".

## 3. eBay developer keys (optional, but this is where prices come from)

Free. Takes about ten minutes, most of it waiting on the email verification.

1. **developer.ebay.com** → **Join the eBay Developers Program** → sign in with your
   normal eBay account.
2. **My Account → Application Keysets**. You get a Sandbox and a Production keyset —
   you want **Production**.
3. Copy the **App ID (Client ID)** and the **Cert ID (Client Secret)**.

Skip this and lookups still work, they just fall back to UPCitemdb's recorded price
range and Claude's estimate. You'll see it in the value basis line under the value
field: it says where each number came from.

Nothing to do for UPCitemdb — its free tier needs no signup. It allows about 100
lookups a day from one IP, which is plenty for inventorying a house over a few
weekends.

## 4. Deploy the worker

1. **dash.cloudflare.com** → **Workers & Pages** → **Create** → **Start with Hello
   World** → **Deploy**.
2. **Edit code**, delete everything, paste the full contents of `worker.js`, **Deploy**.
3. **Settings → Variables and Secrets** → **Add**, type **Secret** each time:

   | Name | Value |
   |---|---|
   | `ANTHROPIC_API_KEY` | from step 1 |
   | `NOTION_API_KEY` | from step 2 |
   | `EBAY_CLIENT_ID` | from step 3, optional |
   | `EBAY_CLIENT_SECRET` | from step 3, optional |

4. Copy the worker URL. If it isn't `groton-vision.jonas-spira.workers.dev`, put the
   new one in `WORKER_URL` near the top of the `<script>` block in `index.html`.

## 5. Check it

Open **`https://groton-vision.jonas-spira.workers.dev/health`** in a browser. It runs a
real lookup against every source and tells you what's broken:

```json
{
  "secrets": { "ANTHROPIC_API_KEY": true, "NOTION_API_KEY": true,
               "EBAY_CLIENT_ID": true, "EBAY_CLIENT_SECRET": true },
  "probes": {
    "upcitemdb": { "ok": true, "hits": 1 },
    "ebay":      { "ok": true, "hits": 5 },
    "notion":    { "ok": true },
    "claude":    { "ok": true, "sample": "Apple USB-C Charge Cable 2m" }
  }
}
```

Every `ok: true` means that path works end to end. Anything false carries the reason.

---

## How lookup actually resolves

Both databases are queried at the same time, then Claude reconciles them into one row
that matches the Notion taxonomy exactly.

| Source | Needs a key | Gives you | Limit |
|---|---|---|---|
| UPCitemdb free tier | no | name, brand, model, category, recorded price range | ~100/day per IP |
| eBay Browse API | optional | name, brand, image, live asking prices | 5,000/day |
| Claude | yes | identification when both miss; taxonomy mapping always | pay per call |

The value the app fills in is **replacement cost** — the median asking price across
new eBay listings when eBay answered, otherwise UPCitemdb's recorded low, otherwise
Claude's estimate. The line under the value field always names which one it used.
Correct it whenever you know better; that number is what an insurer would care about.

A bare barcode Claude doesn't recognise comes back with confidence `low` and no name
rather than an invented product. That's deliberate — a wrong row is worse than a
blank one.

---

## When something breaks

| Symptom | Cause |
|---|---|
| Lookup says "Nothing matched" on a real barcode | Item isn't in UPCitemdb and has no live eBay listing. Type the product name instead. |
| Lookup worked this morning, not now | UPCitemdb's ~100/day cap. Add eBay keys, or wait until tomorrow. |
| Sync fails with "not found" | Step 2.4 — the integration isn't connected to the Home Inventory page. |
| Sync fails with "Value (USD) is not a property" | The Notion property was renamed. Names in `notionProperties()` must match Notion exactly. |
| Everything fails | Sync tab → **Manual export** still works: copy the JSON into a Claude chat. |

Items live in the browser's localStorage until they sync. Clearing Safari's website
data wipes anything unsynced, so sync often, and use **Plain-text backup** before any
long session.

---

## Changing the categories

The category list exists in three places and they must agree, or sync fails with an
invalid-select error:

1. `TYPE_MAP` in `index.html`
2. `TYPE_MAP` in `worker.js` (and the same list written out in `NORMALIZE_PROMPT`)
3. The **Asset Type** and **Type** select options in Notion

Change all three together.
