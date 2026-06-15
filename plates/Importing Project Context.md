# Mitten Plates — Project Context

## What this is

A single, self-contained webpage that displays a random Michigan vanity license plate photo on each load. No social account, no feed, no navigation. Just the photo and a button to get another one.

---

## Hosting & repo

The site lives as a subdirectory in an existing GitHub Pages repo:

- **Repo**: `/Users/jonasspira/jonasspira.github.io`
- **Live domain**: `www.spiiira.com` (via CNAME)
- **Target path for this project**: `/mitten-plates/` → accessible at `www.spiiira.com/mitten-plates/`

Other subdirectory projects in the repo follow the same pattern: `/toronto26/`, `/groton-inventory/`, `/breaker-map/`, `/filters/`. Each is self-contained with its own `index.html`.

The `toronto26/` project is a photo gallery with fullscreen image display already implemented — reference it for image loading and display patterns if useful.

The main `index.html` at the repo root lists all projects as tool cards. Once Mitten Plates is ready, add a card there pointing to `/mitten-plates/`.

---

## Core behavior

- On load: display a random plate photo, fullscreen
- A button (minimal text, e.g. "Next") is layered on top of the image
- Clicking the button loads the next random plate
- No repeats within a session — shuffle all plates, cycle through before repeating
- Transition between images: modern and alive — not a plain crossfade. A subtle scale, blur, or combined effect. Should feel fun without being distracting.

---

## Visual direction

- Plate image fills the full viewport
- All UI (button, any other elements) overlaid on top — nothing lives outside or below the image
- Clean, minimal text on interactive elements
- Modern and fun — not sterile, not over-designed
- No header, no footer, no links back to spiiira.com or anywhere else
- The existing site uses JetBrains Mono, Archivo Black, and Gasoek One — consistent typography is fine but not required for this page since it lives alone

---

## Images

- A few hundred JPG photos of Michigan vanity license plates
- Currently stored locally at `/Users/jonasspira/Desktop/PLATES420`
- Naming convention: `PLATE | PLATETEXT.jpg`
- Originals may be large camera files — resize before deployment
- Images should be placed in `/mitten-plates/images/` within the repo
- A `plates.json` manifest file listing all image filenames should be generated and placed in `/mitten-plates/` — the page reads from this to select and cycle images, rather than querying any external service at runtime

---

## Notion database (management tool only — not a runtime dependency)

Used to maintain a clean, deduplicated text list of all plates. The page does not query Notion.

- **URL**: `https://www.notion.so/spiiira/d395339c96cc479eac27c5b787c0647f?v=1116a3e5686246dcb446aabdd91a448a`
- **Database ID**: `269d2f78-05f8-46cd-bf76-3e8c52301144`
- Key field: **PLATE** — exact plate text, matches the filename

---

## What to build

1. `/mitten-plates/index.html` — the page itself: fullscreen image, overlay button, shuffle/no-repeat session logic, transition effect
2. `/mitten-plates/plates.json` — manifest of all image filenames, generated from the PLATES420 folder
3. A script to resize plate images from PLATES420 for web and copy them to `/mitten-plates/images/`
4. A card added to the root `index.html` linking to `/mitten-plates/`
