"""Draws the OpenPops app icon.

Usage (needs Pillow: pip3 install pillow):
    python3 scripts/make-icon.py Resources

Writes Resources/AppIcon.png (1024 px) and Resources/AppIcon.icns.
"""
from PIL import Image, ImageDraw, ImageFilter
import sys
S = 4  # supersample
W = 1024 * S

def hexc(h, a=255):
    h = h.lstrip('#'); return (int(h[0:2],16), int(h[2:4],16), int(h[4:6],16), a)

def vgrad(size, top, bottom):
    w, h = size
    g = Image.new('RGBA', (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)))
    return g.resize((w, h))

def layer(draw_fn):
    """Draw on a transparent layer so alpha blends instead of overwriting."""
    l = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(l))
    return l

def box(b): return [v * S for v in b]

canvas = Image.new('RGBA', (W, W), (0, 0, 0, 0))

shadow = layer(lambda d: d.rounded_rectangle(box((100, 114, 924, 938)), radius=185*S, fill=(0, 0, 0, 120)))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18*S)))

body_mask = Image.new('L', (W, W), 0)
ImageDraw.Draw(body_mask).rounded_rectangle(box((100, 100, 924, 924)), radius=185*S, fill=255)
canvas.paste(vgrad((W, W), hexc('#2E2E29'), hexc('#0D0D0C')), (0, 0), body_mask)
canvas.alpha_composite(layer(lambda d: d.rounded_rectangle(box((100, 100, 924, 924)), radius=185*S,
                                                         outline=(255, 255, 255, 30), width=3*S)))

# Dock bar with five tiles; the orange one is "open".
canvas.alpha_composite(layer(lambda d: d.rounded_rectangle(box((170, 744, 854, 842)), radius=34*S, fill=hexc('#EBE2CF', 34))))
tile = 60
xs = [212, 346, 482, 618, 752]
cols = ['#1E5663', '#FF4A14', '#F28C00', '#D6C2A7', '#55554C']
def dock_tiles(d):
    for x, c in zip(xs, cols):
        d.rounded_rectangle(box((x, 763, x + tile, 763 + tile)), radius=15*S, fill=hexc(c))
canvas.alpha_composite(layer(dock_tiles))
cx = xs[1] + tile / 2
canvas.alpha_composite(layer(lambda d: d.ellipse(box((cx - 6, 830, cx + 6, 842)), fill=hexc('#EBE2CF', 210))))

# Popover card with a caret pointing at the orange tile, plus a soft shadow.
card = (200, 190, 824, 668)
def card_shape(d, fill):
    d.rounded_rectangle(box(card), radius=62*S, fill=fill)
    d.polygon([((cx - 36) * S, 660 * S), ((cx + 36) * S, 660 * S), (cx * S, 716 * S)], fill=fill)
card_shadow = layer(lambda d: card_shape(d, (0, 0, 0, 140))).filter(ImageFilter.GaussianBlur(14*S))
canvas.alpha_composite(card_shadow, (0, 6*S))
canvas.alpha_composite(layer(lambda d: card_shape(d, hexc('#EBE2CF'))))

# 3x3 grid centered in the card.
colors = ['#1E5663', '#FF4A14', '#F28C00',
          '#F28C00', '#1E5663', '#C7B08F',
          '#FF4A14', '#55554C', '#1E5663']
cell, gap = 124, 26
grid = 3 * cell + 2 * gap
gx0 = card[0] + (card[2] - card[0] - grid) / 2
gy0 = card[1] + (card[3] - card[1] - grid) / 2
def grid_tiles(d):
    for i, c in enumerate(colors):
        r, col = divmod(i, 3)
        x = gx0 + col * (cell + gap); y = gy0 + r * (cell + gap)
        d.rounded_rectangle(box((x, y, x + cell, y + cell)), radius=32*S, fill=hexc(c))
canvas.alpha_composite(layer(grid_tiles))

icon = canvas.resize((1024, 1024), Image.LANCZOS)
out = sys.argv[1]
icon.save(out + '/AppIcon.png')
icon.save(out + '/AppIcon.icns')
print('ok')
