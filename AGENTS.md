---
# Keeps this file off www.spiiira.com. Jekyll skips pages marked unpublished.
published: false
---

# jonasspira.github.io

This repository is Jonas's website, www.spiiira.com. GitHub Pages builds it with Jekyll and publishes the `main` branch automatically through `.github/workflows/pages.yml`. The separate `.github/workflows/link-check.yml` checks every page and Markdown file for broken links on each push. The repository holds web tools only.

## Working with Jonas

- Jonas is not a programmer. Use plain language and give exact steps.
- No emojis.
- Ask before doing anything beyond the task.

## What goes here

- Tools that run in the browser. Each tool is a top-level folder with an `index.html`, and the folder name is its address: www.spiiira.com/<folder>/.
- When you add a tool, also:
  - add a card for it to the homepage, `index.html`, in the same format as the existing cards;
  - add a row for it to the table in `README.md`.
- Build new tools in the spiiira-ui house style (the spiiira-ui skill) unless Jonas asks for something else.
- Pages are plain static files and everything in this repository is public. Anything that needs a secret goes in a separate service, never in the page (see `groton-inventory/worker.js` and `groton-inventory/SETUP.md`).

## What doesn't go here

- Mac apps, and any other software that isn't a web page. Mac apps live in `jonasspira/mac-apps`, one folder per app: `Nib`, `Tally`, `Pasties` and `OpenPops`.
- If a session started on this repository is asked to build an app, stop before writing any code and say it belongs in `jonasspira/mac-apps`, where Jonas can start a new session or have that repository attached to this session.
- Planning notes and project briefs. Keep them in the conversation. Markdown files here get published as pages on the site.
- Separate repositories for web tools. The folder here is the only copy of each tool.

## Jekyll

- Markdown files are published as pages unless their front matter says `published: false`. `groton-inventory/SETUP.md`, `AGENTS.md` and `CLAUDE.md` use that to stay off the site. `README.md` is skipped automatically.
- `plates/index.html` and `toronto26/index.html` have front matter and use Liquid to list their images. `_data/captions.yml` holds the toronto26 captions.
- Plates' dome source lives in `plates/src/`. After changing it, run
  `npm ci --prefix plates` and `npm run build --prefix plates`. Commit the
  generated `plates/assets/` files too; GitHub Pages serves these directly.
  Adding plate photos still needs no JavaScript build or image manifest.
- The publishing workflow generates Plates' newest-first image list from each
  photo's Git addition date, then builds and checks the entire site. Photos added
  in the same commit use filename order. Newest photos occupy the dome's center.
  Keep Pages configured for GitHub Actions, not legacy branch publishing.
  For local Jekyll previews, run `node _scripts/plate-order.mjs` first; it needs
  full Git history and committed photos. Do not commit `_data/plates_order.json`.
- The photo list filters identical file content using SHA-256, keeping the
  newest copy. Never delete source photos as part of this filtering. The built
  site check also rejects duplicate photo content. Run
  `node --test _scripts/plate-order.test.mjs` after changing this behavior.
- Plates supports a zoom slider, zoom buttons, phone/trackpad pinch, and a reset
  to the newest photos. Ordinary wheel movement still rotates the gallery.
- Don't write `{{` or `{%` in Markdown files or in pages with front matter unless you mean Liquid.

## Housekeeping

- Several AI tools work on this repository (Claude, Codex, Muse). Start from the
  latest `main`. When the work is done, commit it, and push it or open a pull
  request when Jonas asks, so the next tool starts from it.
- Cloud sessions may not be able to delete branches or push tags. Leave those to
  Jonas.
- Merged branches get deleted on github.com; the repository's "Automatically delete head branches" setting (Settings > General > Pull Requests) does it on every merge.
