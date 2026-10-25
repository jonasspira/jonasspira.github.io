---
# Keeps these instructions off www.spiiira.com. Jekyll skips pages marked unpublished.
published: false
---

# nyc26 — setup

The page is one static folder, served by GitHub Pages like every other tool
here. Everything private lives in a single Cloudflare Worker with a small
database, so no secret is ever in the page source.

You only do this once. It takes about ten minutes.

Everything below is free. There is nothing to pay for and nothing to cancel.

---

## What lives where

| Path | What it is |
|---|---|
| `nyc26/src/` | The page source |
| `nyc26/index.html`, `nyc26/assets/` | The built page. GitHub Pages serves these |
| `nyc26/worker/worker.js` | The API. Deployed to Cloudflare, not to this site |
| Cloudflare Worker `nyc26-api` | Checks the PIN, reads and writes the trip |
| Cloudflare D1 database `nyc26` | The trip itself, one row |

Your Cloudflare account already runs two Workers (`groton-vision` and
`spiiira-filters-ai`). This adds a third. It does not touch either of them, and
it does not touch your domain or DNS.

---

## 1. Sign in to Cloudflare from this Mac

In Terminal:

```bash
cd ~/Projects/"SPIIIRA Tools"/jonasspira.github.io/nyc26 && npx wrangler login
```

A browser window opens. Approve it, then come back to Terminal. You only ever
do this once on this Mac.

## 2. Create the database

```bash
cd ~/Projects/"SPIIIRA Tools"/jonasspira.github.io/nyc26 && npx wrangler d1 create nyc26
```

It prints a block of text containing `database_id = "..."` with a long code.
Copy that code. Open `nyc26/worker/wrangler.toml`, find the line that says

```
database_id = "TO BE FILLED IN"
```

and put the code between the quotes instead. Save the file.

The id is not a secret, so it is fine to commit it.

## 3. Create the tables

```bash
cd ~/Projects/"SPIIIRA Tools"/jonasspira.github.io/nyc26 && npx wrangler d1 execute nyc26 --remote --file worker/schema.sql --config worker/wrangler.toml
```

Say yes if it asks to confirm.

## 4. Deploy the Worker

```bash
cd ~/Projects/"SPIIIRA Tools"/jonasspira.github.io/nyc26 && npx wrangler deploy --config worker/wrangler.toml
```

It prints the address it deployed to. It should be
`https://nyc26-api.jonas-spira.workers.dev`. If it is anything else, tell
whichever assistant you are working with, because the page has that address
built into it.

## 5. Set the two secrets

These are the only private values, and they live only in Cloudflare.

```bash
cd ~/Projects/"SPIIIRA Tools"/jonasspira.github.io/nyc26 && npx wrangler secret put ACCESS_PIN --config worker/wrangler.toml
```

It waits for you to type the PIN. Type it and press Return. Nothing appears on
screen as you type; that is normal.

Then the signing key, which you never need to remember or type again:

```bash
cd ~/Projects/"SPIIIRA Tools"/jonasspira.github.io/nyc26 && npx wrangler secret put SESSION_SECRET --config worker/wrangler.toml
```

When it waits, paste a long random string. To get one, run this first and copy
what it prints:

```bash
openssl rand -hex 32
```

Do not set `DEV_ORIGINS` on the deployed Worker. It exists only for local work.

## 6. Check it

```bash
curl https://nyc26-api.jonas-spira.workers.dev/health
```

You want to see all four true:

```
{"ok":true,"build":"...","pin":true,"secret":true,"db":true}
```

`pin` and `secret` only report whether something is set. They never show the
values, and neither does anything else.

If `pin` or `secret` is false, repeat step 5. If `db` is false, repeat steps 2
to 4.

---

## Changing the PIN later

Run step 5's first command again with the new PIN. Every device will ask for
the new one the next time its 90 days run out. To force every device out
immediately, set a new `SESSION_SECRET` as well; that makes every existing
token invalid at once.

## If you forget the PIN

Nothing is lost. Set a new one with step 5. The trip is untouched.

## How the PIN is protected

The PIN is never in the page, never in this repository, and never sent anywhere
except to your Worker. Five wrong tries from one address locks that address out
for fifteen minutes, so a four-digit PIN cannot be guessed by a machine working
through the possibilities.

Once a device has the PIN right, it stays open for 90 days without asking
again. What it stores is a signed token, not the PIN.

## Abandoning the experiment

Nothing here is entangled with your other tools.

1. Delete the `nyc26` folder from the website repository.
2. In `dash.cloudflare.com`, under Workers & Pages, delete the `nyc26-api`
   Worker.
3. Under Storage & Databases, delete the `nyc26` D1 database.

Your other six tools, your domain and the original ChatGPT Site are unaffected.
