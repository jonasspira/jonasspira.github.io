#!/usr/bin/env bash
#
# Resize Michigan plate photos for the web and copy them into plates/images/.
#
# Source photos are expected at ~/Desktop/PLATES420, named like "PLATE | ABC123.jpg".
# Originals are large camera files; this downsizes the long edge to 1600px,
# re-encodes as quality-80 JPEG, and writes URL-safe filenames into images/.
#
# Uses macOS's built-in `sips` — no extra tools to install.
# Re-running is safe: it overwrites whatever is already in images/.
#
# Usage:  ./resize-plates.sh [SOURCE_DIR]
set -euo pipefail

SRC="${1:-$HOME/Desktop/PLATES420}"
DEST="$(cd "$(dirname "$0")" && pwd)/images"
MAX=1600

if [ ! -d "$SRC" ]; then
  echo "Source folder not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DEST"
shopt -s nullglob nocaseglob

count=0
for f in "$SRC"/*.jpg "$SRC"/*.jpeg "$SRC"/*.png; do
  base="$(basename "$f")"
  name="${base%.*}"

  # Make a URL-safe filename: lowercase, " | " -> "-", spaces -> "-",
  # drop anything that isn't a-z 0-9 - or _, collapse repeats.
  safe="$(printf '%s' "$name" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/ *\| */-/g; s/[[:space:]]+/-/g; s/[^a-z0-9_-]//g; s/-+/-/g; s/^-+|-+$//g')"
  [ -z "$safe" ] && safe="plate-$count"

  out="$DEST/$safe.jpg"
  sips -s format jpeg -s formatOptions 80 -Z "$MAX" "$f" --out "$out" >/dev/null
  count=$((count + 1))
  echo "  $base -> images/$safe.jpg"
done

echo "Done. $count image(s) written to $DEST"
