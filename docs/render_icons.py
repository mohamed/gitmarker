"""Renders the app icon variants in assets/icon/ from docs/logo.svg.

    python3 docs/render_icons.py docs/logo.svg assets/icon   # needs cairosvg, Pillow
    dart run flutter_launcher_icons                         # platform icon files

icon.png: the logo (Android legacy, Windows, Linux window, About dialog);
icon_ios.png: full-bleed square without alpha (iOS masks the corners);
icon_macos.png: the tile on Apple's 824/1024 grid; background.png and
foreground.png: the Android adaptive icon layers.
"""
import re, sys, cairosvg, io
from PIL import Image
src = open(sys.argv[1]).read()
out = sys.argv[2]
inner = src[src.index('</defs>')+7:src.rindex('</svg>')]
tile = re.search(r'<rect[^>]*/>', inner).group(0)
note = inner.replace(tile, '')          # note + M, no tile
defs = src[src.index('<defs>'):src.index('</defs>')+7]
def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{defs}{body}</svg>'
def png(body, name, size=1024, alpha=True):
    data = cairosvg.svg2png(bytestring=svg(body).encode(), output_width=size, output_height=size)
    im = Image.open(io.BytesIO(data)).convert('RGBA')
    if not alpha:
        im = im.convert('RGB')
    im.save(f'{out}/{name}', optimize=True)
full = '<rect width="1024" height="1024" fill="url(#tile)"/>'
png(src[src.index('<defs>'):src.rindex('</svg>')], 'icon.png')            # the logo as is
png(full + note, 'icon_ios.png', alpha=False)                               # full bleed, iOS masks it
# macOS: 824 px tile with 100 px margin (Apple's grid), same corner ratio.
png(f'<g transform="translate(100 100) scale({824/1024})">{tile}{note}</g>', 'icon_macos.png')
png(full, 'background.png', alpha=False)                                   # Android adaptive background
# Android adaptive foreground: launchers may mask the layer to a circle of
# 66/108 of its size (the safe zone); the note (528 x 672, diagonal 854)
# must fit inside it with its corners.
# flutter_launcher_icons draws the foreground with a 16 % inset on each
# side (68 % of the layer), so it is rendered that much larger here.
k = 0.98 * (66 / 108) * 1024 / 854 / 0.68
png(f'<g transform="translate(512 512) scale({k}) translate(-512 -512)">{note}</g>', 'foreground.png')
