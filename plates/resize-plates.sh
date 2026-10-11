#!/usr/bin/env bash
#
# Make the photos in plates/images/ ready for the web, in place.
#
# Drop photos straight into images/ (exported from Photos, AirDrop, anywhere),
# then run this. For every photo it:
#   - shrinks it so the long edge is 1600px, saved as quality-80 JPEG
#     (photos already that small are left alone, so re-running is safe);
#   - turns HEIC and PNG files into JPEGs and moves the original to the Trash;
#   - replaces spaces and other odd characters in the file name with "-";
#   - removes the map location saved inside the photo.
#
# Uses macOS's built-in `sips` and `python3` — no extra tools to install.
#
# Usage:  ./resize-plates.sh [FOLDER]     (default: images/ next to this script)
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")" && pwd)/images}"
MAX=1600

if [ ! -d "$DIR" ]; then
  echo "Folder not found: $DIR" >&2
  exit 1
fi

shopt -s nullglob nocaseglob
files=("$DIR"/*.jpg "$DIR"/*.jpeg "$DIR"/*.heic "$DIR"/*.heif "$DIR"/*.png)
total=${#files[@]}
if [ "$total" -eq 0 ]; then
  echo "No photos found in $DIR"
  exit 0
fi

progress() {  # progress <done> <total>
  local width=30 filled=$(( $1 * 30 / $2 ))
  printf '\r  [%s%s] %d/%d' \
    "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$(printf '%*s' $((width - filled)) '' | tr ' ' '-')" "$1" "$2"
}

before=$(du -sk "$DIR" | cut -f1)
shrunk=0 converted=0 renamed=0 count=0
echo "Preparing $total photo(s) in $DIR"
progress 0 "$total"
for f in "${files[@]}"; do
  base="$(basename "$f")"
  name="${base%.*}"
  ext="${base##*.}"
  convert=false
  case "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" in
    heic|heif|png) convert=true; ext=jpg ;;
  esac

  # URL-safe name: runs of anything but letters, digits, "_" or "-" become "-".
  safe="$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+|-+$//g')"
  [ -z "$safe" ] && safe="plate"
  out="$DIR/$safe.$ext"
  if [ "$out" != "$f" ]; then
    n=2
    while [ -e "$out" ]; do out="$DIR/$safe-$n.$ext"; n=$((n + 1)); done
  fi

  long_edge="$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {print $2}' | sort -n | tail -1)"
  args=(-s format jpeg -s formatOptions 80)
  [ "$long_edge" -gt "$MAX" ] && args+=(-Z "$MAX")

  if $convert; then
    sips "${args[@]}" "$f" --out "$out" >/dev/null
    if command -v trash >/dev/null; then trash "$f"; else mv "$f" "$HOME/.Trash/"; fi
    converted=$((converted + 1))
  else
    if [ "$out" != "$f" ]; then
      mv "$f" "$out"
      renamed=$((renamed + 1))
    fi
    if [ "$long_edge" -gt "$MAX" ]; then
      sips "${args[@]}" "$out" >/dev/null
      shrunk=$((shrunk + 1))
    fi
  fi
  count=$((count + 1))
  progress "$count" "$total"
done
echo

# Remove the map location by emptying the GPS section of each photo's EXIF
# details. Only those bytes change; the picture itself is not re-saved.
cleaned="$(python3 - "$DIR" <<'PY'
import os, struct, sys

SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}

def blank_gps(data, t, end):
    """Empty the GPS directory of the EXIF block whose TIFF header starts at t."""
    bo = '<' if data[t:t + 2] == b'II' else '>'
    u16 = lambda o: struct.unpack_from(bo + 'H', data, t + o)[0]
    u32 = lambda o: struct.unpack_from(bo + 'I', data, t + o)[0]
    ifd0 = u32(4)
    gps = next((u32(ifd0 + 2 + 12 * k + 8) for k in range(u16(ifd0))
                if u16(ifd0 + 2 + 12 * k) == 0x8825), None)
    if gps is None or u16(gps) == 0:
        return False
    count = u16(gps)
    if t + gps + 6 + 12 * count > end:
        return False
    for k in range(count):
        e = gps + 2 + 12 * k
        size = SIZES.get(u16(e + 2), 1) * u32(e + 4)
        if size > 4 and t + u32(e + 8) + size <= end:
            off = t + u32(e + 8)
            data[off:off + size] = bytes(size)
    data[t + gps:t + gps + 6 + 12 * count] = bytes(6 + 12 * count)
    return True

def strip(path):
    with open(path, 'rb') as fh:
        data = bytearray(fh.read())
    pos, changed = 2, False
    while data[:2] == b'\xff\xd8' and pos + 4 <= len(data) and data[pos] == 0xFF:
        marker = data[pos + 1]
        if marker in (0xD9, 0xDA):  # end of image, or start of the picture data
            break
        length = struct.unpack_from('>H', data, pos + 2)[0]
        if marker == 0xE1 and data[pos + 4:pos + 10] == b'Exif\x00\x00':
            changed |= blank_gps(data, pos + 10, pos + 2 + length)
        pos += 2 + length
    if changed:
        with open(path, 'wb') as fh:
            fh.write(data)
    return changed

folder, cleaned = sys.argv[1], 0
for name in sorted(os.listdir(folder)):
    if name.lower().endswith(('.jpg', '.jpeg')):
        try:
            cleaned += strip(os.path.join(folder, name))
        except (struct.error, IndexError):
            print(f"  Could not read the details of {name}; left it as is.", file=sys.stderr)
print(cleaned)
PY
)"

after=$(du -sk "$DIR" | cut -f1)
echo "Done. Shrunk $shrunk, converted $converted, renamed $renamed, removed the location from $cleaned."
echo "Folder size: $((before / 1024)) MB -> $((after / 1024)) MB"
