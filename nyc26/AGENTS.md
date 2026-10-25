---
# Keeps this file off www.spiiira.com. Jekyll skips pages marked unpublished.
published: false
---

# nyc26

Jonas's New York work-trip hub, October 26&ndash;29, 2026. Served at
www.spiiira.com/nyc26/. This folder is the only copy; there is no separate
repository.

It was moved here from a private ChatGPT Site in October 2026. That Site is
still live and must be left alone (see "The old Site" below).

## Where the pieces are

| Piece | Lives in | Served from |
|---|---|---|
| The page | `src/` (React + TypeScript) | GitHub Pages, built into `index.html` and `assets/` |
| The API | `worker/worker.js` | Cloudflare Worker `nyc26-api` |
| The data | one row in Cloudflare D1 | database `nyc26` |
| The PIN | a Cloudflare secret | never in this repository |

The page and the API are on different addresses, so every request crosses
origins on purpose. Nothing is sent by the browser automatically: the session
token is attached by hand on each request, which is why there is no cookie and
no CSRF risk. `worker/worker.js` allows `https://www.spiiira.com` and nothing
else, unless `DEV_ORIGINS` is set locally.

## Rules that do not change

- **This repository is public.** Never commit trip content, the PIN, the signing
  secret, flight details, the hotel name or address, or a database export. The
  page ships to anyone who opens it; everything private comes from the Worker
  after it checks the token. `worker/.dev.vars` is git-ignored and stays that way.
- **The Worker is the only authority on what may be saved.** `validateTrip()` in
  `worker/worker.js` holds the rules. The browser repeats none of them. Do not
  add a second copy of the schema.
- **Keep the revision check.** Every accepted save increases `revision` by one,
  and a save is only applied when the revision still matches. That is what stops
  a stale phone tab replacing newer edits. Never replace it with a plain update.
- **Never reset live data to the seed.** `initialTrip()` is only used when the
  row does not exist yet.
- **Keep the four sections**: the essentials, three evenings, places & thoughts,
  good to know. Do not redesign them, and do not add bookings, reservations,
  itinerary optimisation, recommendations, notifications or collaboration.
  Events are awareness only. Nothing is ever booked.
- **Keep the design**: charcoal background, muted sage accents, compact spacing,
  darkened map tiles with category-coloured numbered pins, the legend, and the
  six category tabs with arrow / Home / End keys. Tabs filter the list only; the
  map stays above them and keeps showing every place matching the text search.
- **Unknown information stays `TO BE FILLED IN`** (or `TO BE VERIFIED`). Never
  invent flight details, addresses, hours or times.
- **Only the five categories**: Hotel, Office, Food, Shops, Other. Office is a
  category only; there is no office pin unless Jonas supplies one.
- **Pins must be real.** A place with no verified location is saved by name with
  `location: null`. Coordinates must sit inside the New York box and cite
  OpenStreetMap or NYC GeoSearch over https.
- Do not reintroduce the filler that was removed: "SPIIIRA / TRAVEL",
  "Private trip", Jonas's name, a "NYC / OCTOBER 2026" footer, "Your private
  pre-trip reference", "Work by day. Room to wander.", "Keep the things worth a
  detour.", "A little space for a good evening.", or section numbers 01&ndash;04.
  Place numbers are deliberate and stay.

## Working on it

```
npm install          # once
npm run api          # terminal 1: the Worker and a local database
npm run dev          # terminal 2: the page at localhost:5173/nyc26/
npm test             # 20 checks; the live ones skip if the Worker is not running
npm run build        # type check, build, and copy into index.html + assets/
```

The local PIN is in `worker/.dev.vars` and is not the real one. The local
database is a file under `.wrangler/` and holds disposable test data only.

`npm run build` writes `index.html`, `favicon.svg` and `assets/` into this
folder, and those built files are committed, exactly like `plates/assets/`.
Always run it before committing a change to `src/`, or the published page will
not match the source.

To check the built page the way GitHub Pages serves it, run
`python3 -m http.server 8080` from the repository root and open
`http://127.0.0.1:8080/nyc26/`. For that to reach a local Worker, build with
`VITE_API_BASE=http://127.0.0.1:8787 npm run build` first, and rebuild plainly
afterwards so the committed bundle points at the deployed Worker again.

## Deploying

The page goes live with the rest of the site when `main` is pushed. The Worker
is separate and does not deploy itself: run `npx wrangler deploy --config
worker/wrangler.toml`, or paste `worker/worker.js` into the Cloudflare dashboard
the way `groton-inventory/worker.js` is handled. A change to `worker/worker.js`
has no effect until that is done.

`SETUP.md` has the one-time account steps and how to check it is configured.

## Several tools work on this

Claude, Codex and Muse all edit this folder. Start from the latest `main`, use
one tool at a time, commit when the work is done, and push only when Jonas asks.
`STATUS.md` (local to Jonas's Mac, not committed) says where things stand.

## The old Site

The original lives on this Mac at
`~/Documents/Codex/2026-10-24/create-a-new-site-with-sites` and is still
published as a private ChatGPT Site. Its address is in that folder's own
STATUS.md and in this folder's local STATUS.md; it is deliberately not written
here, because this repository is public.

That Site still holds Jonas's real saved trip. Do not redeploy it, change it,
register a replacement, or copy credentials out of it. It stays until Jonas says
otherwise. This folder's database holds disposable test data until he authorises
a migration.
