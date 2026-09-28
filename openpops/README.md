# OpenPops

OpenPops puts folders of apps, files, folders and links in your Mac's Dock. Click its Dock icon and a grid of the things you grouped together pops up right above it, like a folder on an iPhone home screen. Each group is called a Pop.

It is an open-source take on [DockPops](https://dockpops.com/), built for personal use: every feature is unlocked and there are no limits on how many Pops or items you have.

Requires macOS 14 (Sonoma) or later.

## What it does

**Pops**
- Group any mix of apps, files, folders and web links into a Pop. No limit on Pops or items.
- Click the OpenPops icon in the Dock and your Pops open right above it. Works with the Dock at the bottom, left or right of the screen.
- Swipe between Pops with two fingers, click the dots or arrows, press ← →, or click the Pop's name to jump straight to another one.
- Hide a Pop from the main carousel and keep it on its own Dock icon only.

**Dock icons**
- The OpenPops icon shows a live grid of the current Pop's apps (2×2, 3×3, 4×4 or automatic).
- Give any Pop its own Dock icon (Add to Dock), or put several Pops behind one icon with a Group. Clicking it opens just that Pop or group.
- Each icon matches its Pop's colors, or use a glyph (a letter, word or emoji) or your own image.
- Right-click an OpenPops Dock icon to jump to a Pop, Open All, or Pop Out.

**Files and folders**
- Files open in their default app and show Quick Look thumbnails.
- Click a folder to browse it inside the Pop, including subfolders, with an "Open in Finder" cell at the end.
- Press Space for a Quick Look preview next to the Pop, with Show in Finder and Open buttons.

**Drag and drop**
- Drop apps, files, folders or links from Finder or a browser onto a Pop's Dock icon or into an open Pop.
- Hover a drag over the Dock icon to spring the Pop open, then drop inside it.
- Drag items inside a Pop to reorder them. Drag one off the Pop to remove it.

**More**
- Open All launches everything in a Pop, with an optional confirmation step.
- Pop Out: keep a Pop open as a floating, always-on-top window.
- Sort by hand, name, most used, recently added or kind. Grid or list layout.
- Menu bar mode: run from the menu bar instead of the Dock (or both). A click opens the carousel or a quick menu.
- Twelve built-in themes (System, Graphite, Sunset, Ocean, Matrix, Forest, Lavender, Rose, Mint, Midnight, Paper, Spiiira) and your own saved themes: color, gradient or photo backgrounds with a glass slider, color or gradient borders, and label font, size, weight, color and shadow.
- App Browser with search, categories, "Not in Any Pop" and "Recently Installed" filters.
- Suggestions for apps that fit a Pop, from app categories and makers. On macOS 26 with Apple Intelligence you can also ask the on-device model.
- `openpops://` links to open, add to, or pop out a Pop from Shortcuts, Raycast, Alfred or scripts.
- Starter Pops on first launch, launch at login, light and dark mode, Reduce Motion support.
- Everything stays on your Mac. No accounts, analytics or network access.

## Install

### Build it yourself (recommended)

You only need Apple's free Command Line Tools, not the full Xcode.

```bash
xcode-select --install          # once, if you don't have the tools yet
git clone https://github.com/jonasspira/jonasspira.github.io.git
cd jonasspira.github.io/openpops
./build.sh --install
```

`--install` copies `OpenPops.app` to `/Applications` (or `~/Applications` if that isn't writable) and opens it. Without it, the app is left in `build/OpenPops.app`.

An app you build yourself opens without Gatekeeper warnings.

### Or download a build

Every push that touches `openpops/` is built by GitHub Actions ([workflow](../.github/workflows/openpops.yml)). Open the latest **OpenPops** run under the repository's **Actions** tab and download the `OpenPops-app` artifact. Pushing a tag like `openpops-v1.0.0` also publishes the zip as a GitHub Release.

These builds are signed ad hoc, not notarized, so macOS blocks them the first time:

1. Unzip and move `OpenPops.app` to `/Applications`.
2. Open it. macOS says it can't verify the developer.
3. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

Or run `xattr -dr com.apple.quarantine /Applications/OpenPops.app` once.

## Using it

1. **Keep OpenPops in the Dock.** The Organizer has a button for it, or right-click the icon → Options → Keep in Dock.
2. **Click the icon.** Your Pops open above it. Click an app to open it.
3. **Fill your Pops.** Drag things onto the icon or into the open Pop, or use the Organizer (⌘, or the gear in the Pop).
4. **Give a Pop its own icon.** In the Organizer, select the Pop → Dock Icon → Add to Dock.

### Keyboard

| Keys | Does |
| --- | --- |
| ← → ↑ ↓ | Move between items. At the left or right edge, move on to the next Pop. |
| Return | Open the selected item |
| Space | Quick Look the selected (or hovered) file |
| Esc | Close Quick Look, leave a folder, or close the Pop |
| ⌘1 – ⌘9, Tab, ⇧Tab, ⌘← ⌘→ | Jump between Pops |
| Type a name | Select the first matching item |
| ⌘O, ⌘R | Open, or Show in Finder |
| ⌘⌫ | Remove the selected item from the Pop |
| ⌘, | Open the Organizer |

With the mouse: ⌘-click shows an item in Finder instead of opening it, and ⌥-click opens a folder in Finder instead of browsing it.

### Dock tiles for single Pops

A Pop's own Dock icon is a small app that OpenPops generates in `~/Applications/OpenPops Tiles/`. It's a copy of OpenPops that opens only that Pop (or group), so it works even when the main app isn't running. Add to Dock pins it and restarts the Dock once. You can also drag a tile from that folder into the Dock yourself, and Spotlight finds tiles by the Pop's name.

By default tile apps don't show up in ⌘-Tab or with a running dot. In that mode macOS only redraws a pinned tile's icon when the Dock restarts, so OpenPops restarts the Dock after you close the Organizer if a tile's icon changed. You can turn that off, or turn on **Show tile apps in Cmd-Tab** in Settings, which makes tile icons update live while they run.

Renamed Pops get their tile renamed when you close the Organizer. Deleting a Pop removes its tile. After you update OpenPops, it rebuilds its tiles on the next launch.

### Automation with openpops:// links

Open these from Shortcuts (Open URL), Raycast, Alfred, a keyboard launcher or Terminal (`open "openpops://show?pop=Work"`). Pops and groups can be named or given by id.

| Link | Does |
| --- | --- |
| `openpops://show` | Open the carousel |
| `openpops://show?pop=Work` | Open one Pop |
| `openpops://show?group=Projects` | Open a group |
| `openpops://add?pop=Work&url=https://example.com&name=Example` | Add a link |
| `openpops://add?pop=Work&path=/Users/me/Notes.txt` | Add a file, folder or app |
| `openpops://popout?pop=Work` | Pop out a floating window |
| `openpops://openall?pop=Work` | Open everything in a Pop |
| `openpops://tile?pop=Work` | Create a Dock tile and pin it (`&pin=0` to only create it) |
| `openpops://organizer?pop=Work` | Open the Organizer on a Pop |

## Permissions

- **Desktop, Documents and Downloads.** macOS asks the first time OpenPops shows a thumbnail or the contents of something in those folders. Each tile app is its own app to macOS, so it asks once as well.
- Apps signed ad hoc are identified by their exact build, so after rebuilding OpenPops macOS may ask again. To avoid that, create a code signing certificate in Keychain Access (Certificate Assistant → Create a Certificate, type Code Signing) and build with `OPENPOPS_SIGN_IDENTITY="Your Certificate Name" ./build.sh --install`.
- Add to Dock edits the Dock's own preferences and restarts it. Nothing else outside OpenPops' folders is changed.

## Your data

Everything is in `~/Library/Application Support/OpenPops/`:

- `library.json` holds your Pops, groups, themes and settings. It's plain JSON.
- `library.backup.json` is a copy from the start of each launch.
- `Images/` holds background photos and custom icons you picked, copied so they keep working if the originals move.

Settings → Data has Export and Import.

## How it differs from DockPops

- No App Store sandbox, so there's no separate Companion app: OpenPops creates the extra Dock tiles itself.
- DockPops' Siri and Spotlight shortcuts need an Xcode project with App Intents. OpenPops uses `openpops://` links instead, which Shortcuts can open, and Spotlight finds Dock tiles by name.
- There's no Share extension for saving links from other apps. Drag a link in, paste it in Add Link, or use `openpops://add`.
- Apple Intelligence suggestions need macOS 26 and a Mac that supports Apple Intelligence. The category-based suggestions work everywhere.

## Uninstall

1. Quit OpenPops and any tile apps, and remove their icons from the Dock (drag them out).
2. Delete `OpenPops.app`, `~/Applications/OpenPops Tiles/` and `~/Library/Application Support/OpenPops/`.
3. If you turned on Open at Login, turn it off first, or remove OpenPops under System Settings → General → Login Items.

## Development

```
openpops/
  Package.swift           Swift package: OpenPopsCore library, OpenPops app, tests
  Sources/OpenPopsCore/   Models, JSON storage, layout and placement math, themes (Foundation only)
  Sources/OpenPops/       The app: AppKit popover, Dock tiles, SwiftUI Organizer
  Tests/                  Unit tests for OpenPopsCore
  Resources/              Info.plist template and app icon
  build.sh                Builds and signs OpenPops.app
  scripts/self-test.sh    Runs the in-app self-test and a launch/reopen smoke test
  scripts/make-icon.py    Draws the app icon (needs Pillow)
```

- `swift test` runs the core tests. They also run on Linux.
- `./build.sh` builds the app; `scripts/self-test.sh` then renders every part of the UI to `build/self-test/` and checks that Dock tiles respond to clicks.
- CI builds a universal app on a macOS runner, runs both, and uploads the app and the screenshots as artifacts.
