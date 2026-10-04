# jonasspira.github.io

The source for [www.spiiira.com](https://www.spiiira.com). GitHub Pages publishes the `main` branch automatically, usually within a minute or two of a change.

Each web tool is a folder. The folder name is its address on the site, and the homepage (`index.html`) has a card for each one.

| Folder | Tool | Live at |
| --- | --- | --- |
| `filters/` | Gmail Filter Builder: builds search queries for Gmail filters | [spiiira.com/filters](https://www.spiiira.com/filters/) |
| `groton-inventory/` | Home Inventory: records appliances, systems and assets at Groton Rd and syncs them to Notion through a Cloudflare Worker (see `SETUP.md` in the folder) | [spiiira.com/groton-inventory](https://www.spiiira.com/groton-inventory/) |
| `breaker-map/` | Breaker Map: fill in an electrical panel's circuits, then export them to PDF | [spiiira.com/breaker-map](https://www.spiiira.com/breaker-map/) |
| `toronto26/` | Toronto: photo gallery | [spiiira.com/toronto26](https://www.spiiira.com/toronto26/) |
| `plates/` | MI Plates: a random Michigan vanity plate on every tap | [spiiira.com/plates](https://www.spiiira.com/plates/) |
| `tinfoil/` | Tinfoil: conspiracy fridge magnet poetry | [spiiira.com/tinfoil](https://www.spiiira.com/tinfoil/) |

Other files:

- `index.html`: the homepage.
- `CNAME`: tells GitHub Pages to serve the site at www.spiiira.com.
- `_data/captions.yml`: photo captions for `toronto26/`.
- `CLAUDE.md`: instructions for Claude Code sessions that work in this repository.

## Mac apps

Mac apps don't live here. They share one repository, [mac-apps](https://github.com/jonasspira/mac-apps), with a folder per app:

- [Nib](https://github.com/jonasspira/mac-apps/tree/main/Nib): markdown editor
- [Tally](https://github.com/jonasspira/mac-apps/tree/main/Tally): notepad calculator
- [Pasties](https://github.com/jonasspira/mac-apps/tree/main/Pasties): menu bar clipboard queue
- [OpenPops](https://github.com/jonasspira/mac-apps/tree/main/OpenPops): folders of apps, files and links in the Dock
