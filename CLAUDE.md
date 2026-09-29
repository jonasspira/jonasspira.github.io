---
# Keeps this file off www.spiiira.com. Jekyll skips pages marked unpublished.
published: false
---

# jonasspira.github.io

This repository is Jonas's website, www.spiiira.com. GitHub Pages builds it with Jekyll and publishes the `main` branch automatically, usually within a minute or two. There is no workflow of our own. The repository holds web tools only.

## What goes here

- Tools that run in the browser. Each tool is a top-level folder with an `index.html`, and the folder name is its address: www.spiiira.com/<folder>/.
- When you add a tool, also:
  - add a card for it to the homepage, `index.html`, in the same format as the existing cards;
  - add a row for it to the table in `README.md`.
- Build new tools in the spiiira-ui house style (the spiiira-ui skill) unless Jonas asks for something else.
- Pages are plain static files and everything in this repository is public. Anything that needs a secret goes in a separate service, never in the page (see `groton-inventory/worker.js` and `groton-inventory/SETUP.md`).

## What doesn't go here

- Mac apps, and any other software that isn't a web page. Each Mac app has its own repository: `Nib`, `Tally`, `Pasties` and `openpops`.
- If a session started on this repository is asked to build an app, stop before writing any code and say it needs its own repository. Claude sessions can't create repositories, so Jonas has to create an empty one on github.com first, then either start a new session on it or have it attached to this session.
- Planning notes and project briefs. Keep them in the conversation. Markdown files here get published as pages on the site.
- Separate repositories for web tools. The folder here is the only copy of each tool.

## Jekyll

- Markdown files are published as pages (for example `groton-inventory/SETUP.md` is live at /groton-inventory/SETUP.html). `README.md` is skipped automatically, and this file is kept off by its front matter.
- `plates/index.html` and `toronto26/index.html` have front matter and use Liquid to list their images. `_data/captions.yml` holds the toronto26 captions.
- Don't write `{{` or `{%` in Markdown files or in pages with front matter unless you mean Liquid.

## Housekeeping

- Claude sessions can push commits but can't delete branches or push tags. Merged branches get deleted on github.com; the repository's "Automatically delete head branches" setting (Settings > General > Pull Requests) does it on every merge.
