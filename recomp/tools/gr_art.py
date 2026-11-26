#!/usr/bin/env python3
"""gr_art.py <gr|ds|it> <art folder> [--game <Ghost Recon folder>] [--no-downloads]

The launch window's art for Ghost Recon or one of its expansions (install.sh), written to the given folder (never to
this project), from the Steam store page: Ghost Recon 15300, Desert Siege 13620, Island Thunder 13630. These old store
pages have no library hero or transparent logo, so the window draws the titles itself and uses screenshots:
  hero.jpg     a full-size (1920x1080) screenshot, across the top of the window
  shot1.jpg    another screenshot (600x338): the campaign's card
  header.jpg   the store page's header (the box art's logo on white), kept for reference; the window doesn't use it
Chosen screenshots are asked for by name; if one has gone, the store's screenshot list (appdetails) fills the gap.
  shot-<n>.jpg more of the store page's screenshots (1920x1080): the backdrop's slides
With --game, from the player's own copy (nothing of it is kept in this project):
  logo.png     the game's own title (Tom Clancy's GHOST RECON), keyed out of its main menu (the menu's picture with the
               title, less the same picture without it: Data/Shell/Art/main_menu-02.rsb and shell_bgd-02.rsb)
  scene-<n>.png  the main menu's pictures (shell_bgd-0n.rsb, Ghost Recon's card): the backdrop's slides
  portrait.png the soldier by the wall under the moon (shell_bgd-02.rsb): the framed portrait
  intro-<n>.jpg  frames of the campaign's intro movie (Data/Video or Mods/Mp1, Mp2: intro.avi), with ffmpeg
From GOG's store page for Ghost Recon (product 1207658751; gr only):
  cover.jpg    the box art (594x800): the framed portrait
  keyart.jpg   the key art with the logo (1600x740)
  logo-hd.png  the logo (Tom Clancy's GHOST RECON and its crosshair) cut out of the key art: about 700 px wide,
               sharp at Retina sizes. The letters are neutral metal on green camouflage: neutral and bright pixels,
               gaps closed and holes filled, kept where they form the letters, grown by the bevel's width, with the
               crosshair's green lines
--no-downloads (or no network): nothing is fetched. Standard library only (and ffmpeg for the intro, when installed).
"""
import json, os, shutil, struct, subprocess, sys, tempfile, urllib.request, zlib

GAMES = {   # app id, the hero screenshot, the card's screenshot
    'gr': (15300, '0000004465', '0000004461'),     # a fire team over a fence; a rifleman in the hills
    'ds': (13620, '0000003912', '0000003918'),     # a fire team in the woods; a night advance
    'it': (13630, '0000003920', '0000003927'),     # the jungle ridge; a village in the fog
}
ASSET = 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/%d/%s'
GOG_COVER = 'https://images.gog-statics.com/3c6ff5b86bd1f3b1a43dd7b16183a8121dc74bdc63c4c6cf721ef6c99ea52fbc.jpg'
GOG_KEYART = 'https://images.gog-statics.com/4f0ce624e272b3ef7aeeac53cfd210fd59cc56b1f41f6ee49a636c2caf4e3b30.png'
GOG_API = 'https://api.gog.com/v2/games/1207658751?locale=en-US'
JPG = b'\xff\xd8'

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'ghost-recon-installer'})
    with urllib.request.urlopen(req, timeout=20) as r: return r.read()

def download(url, path):
    try: d = fetch(url)
    except Exception as e:
        print('  %s: %s' % (os.path.basename(path), e), file=sys.stderr); return False
    if not d.startswith(JPG) or len(d) < 5000: return False
    with open(path + '.part', 'wb') as f: f.write(d)
    os.replace(path + '.part', path); return True

def store_shots(app):   # the store page's screenshot names (without size and extension)
    try: d = json.loads(fetch('https://store.steampowered.com/api/appdetails?appids=%d&filters=screenshots' % app))
    except Exception as e:
        print('  appdetails: %s' % e, file=sys.stderr); return []
    shots = (d.get(str(app)) or {}).get('data', {}).get('screenshots', [])
    return [os.path.basename(s.get('path_full', '')).split('.')[0] for s in shots if s.get('path_full')]

def rsb(path):
    """a Red Storm bitmap (24-bit, version 6): width, height, rows of (r, g, b); None for another kind"""
    try: d = open(path, 'rb').read()
    except OSError: return None
    ver, w, h, rb, gb, bb, ab = struct.unpack_from('<7I', d, 0)
    if ver != 6 or (rb, gb, bb, ab) != (8, 8, 8, 0) or len(d) < 28 + w * h * 3: return None
    px = d[28:28 + w * h * 3]
    return w, h, [[(px[(y * w + x) * 3 + 2], px[(y * w + x) * 3 + 1], px[(y * w + x) * 3]) for x in range(w)] for y in range(h)]

def write_png(path, rows, alpha=False):
    h, w = len(rows), len(rows[0])
    raw = b''.join(b'\0' + bytes(v for p in r for v in p) for r in rows)
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path + '.part', 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6 if alpha else 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
    os.replace(path + '.part', path)

def find_ci(folder, *parts):
    for part in parts:
        if not os.path.isdir(folder): return None
        hit = next((n for n in os.listdir(folder) if n.lower() == part.lower()), None)
        if not hit: return None
        folder = os.path.join(folder, hit)
    return folder

def from_copy(gid, game, out):
    """the title, the menu's pictures and the intro's frames, from the player's own copy"""
    art = find_ci(game, 'Data', 'Shell', 'Art')
    if gid == 'gr' and art:
        pics = {}
        for n in range(1, 6):
            p = os.path.join(out, 'scene-%d.png' % n)
            img = rsb(find_ci(art, 'shell_bgd-%02d.rsb' % n) or '')
            if not img: continue
            pics[n] = img; w, h, rows = img
            if not os.path.exists(p): write_png(p, [r[:640] for r in rows[:480]])   # (the menu's 640x480 in a 1024x512 texture)
        if 2 in pics and not os.path.exists(os.path.join(out, 'portrait.png')):
            write_png(os.path.join(out, 'portrait.png'), [r[300:640] for r in pics[2][2][:480]])
        menu = rsb(find_ci(art, 'main_menu-02.rsb') or '')
        if menu and 2 in pics and not os.path.exists(os.path.join(out, 'logo.png')):
            a, b = menu[2], pics[2][2]; x0, y0, x1, y1 = 640, 480, 0, 0; key = {}
            for y in range(104, 194):    # (the title's place in the menu: elsewhere the two pictures differ a little too)
                for x in range(8, 468):
                    m, s0 = a[y][x], b[y][x]; d = max(abs(m[0] - s0[0]), abs(m[1] - s0[1]), abs(m[2] - s0[2]))
                    al = min(255, (d - 40) * 4) if d > 40 and not (x > 436 and (y < 140 or y > 180)) and not (x > 456) and not (x > 400 and max(m) < 110) and not (x > 430 and y > 184) else 0   # (not the soldier's rifle above the N)
                    if al > 120: x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
                    key[y, x] = m + (al,)
            if x1 > x0 and y1 > y0:
                x0, y0, x1, y1 = max(8, x0 - 3), max(104, y0 - 3), min(467, x1 + 3), min(193, y1 + 3)
                write_png(os.path.join(out, 'logo.png'), [[key[y, x] for x in range(x0, x1 + 1)] for y in range(y0, y1 + 1)], alpha=True)
    ffmpeg = shutil.which('ffmpeg') or next((p for p in ('/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg') if os.path.exists(p)), None)
    movie = find_ci(game, 'Data', 'Video', 'intro.avi') if gid == 'gr' else find_ci(game, 'Mods', 'Mp1' if gid == 'ds' else 'Mp2', 'Video', 'intro.avi')
    if ffmpeg and movie:
        for k, at in enumerate((0.15, 0.30, 0.45, 0.62, 0.80)):
            p = os.path.join(out, 'intro-%d.jpg' % (k + 1))
            if os.path.exists(p): continue
            r = subprocess.run([ffmpeg.replace('ffmpeg', 'ffprobe'), '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', movie], capture_output=True, text=True)
            try: t = float(r.stdout.strip()) * at
            except ValueError: break
            subprocess.run([ffmpeg, '-v', 'error', '-y', '-ss', '%.1f' % t, '-i', movie, '-frames:v', '1', '-vf', 'crop=iw:ih*0.56:0:ih*0.22,scale=1280:-2:flags=lanczos,unsharp=5:5:0.6',
                            '-q:v', '2', p + '.part.jpg'], capture_output=True)
            if os.path.exists(p + '.part.jpg') and os.path.getsize(p + '.part.jpg') > 12000: os.replace(p + '.part.jpg', p)
            elif os.path.exists(p + '.part.jpg'): os.remove(p + '.part.jpg')

def read_png(path):
    """an 8-bit RGB or RGBA PNG (no interlace): width, height, rows of (r, g, b)"""
    d = open(path, 'rb').read(); i = 8; idat = b''; w = h = ct = 0
    while i < len(d):
        n, t = struct.unpack('>I4s', d[i:i + 8]); c = d[i + 8:i + 8 + n]; i += 12 + n
        if t == b'IHDR': w, h, bd, ct, _, _, il = struct.unpack('>IIBBBBB', c); assert bd == 8 and ct in (2, 6) and not il
        elif t == b'IDAT': idat += c
    bpp = 3 if ct == 2 else 4; raw = zlib.decompress(idat); stride = w * bpp; rows = []; prev = bytearray(stride); o = 0
    for _ in range(h):
        f = raw[o]; line = bytearray(raw[o + 1:o + 1 + stride]); o += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([tuple(line[k:k + 3]) for k in range(0, stride, bpp)]); prev = line
    return w, h, rows

def _grow(m, w, h, r):   # dilate a 0/1 list-of-lists by r (square), separably
    out = [[0] * w for _ in range(h)]
    for y in range(h):
        row = m[y]; acc = [0] * (w + 1)
        for x in range(w): acc[x + 1] = acc[x] + row[x]
        out[y] = [1 if acc[min(w, x + r + 1)] - acc[max(0, x - r)] else 0 for x in range(w)]
    res = [[0] * w for _ in range(h)]
    for x in range(w):
        acc = [0] * (h + 1)
        for y in range(h): acc[y + 1] = acc[y] + out[y][x]
        for y in range(h): res[y][x] = 1 if acc[min(h, y + r + 1)] - acc[max(0, y - r)] else 0
    return res

def _shrink(m, w, h, r):
    inv = [[1 - v for v in row] for row in m]
    g = _grow(inv, w, h, r); return [[1 - v for v in row] for row in g]

def _components(m, w, h):
    lab = [[0] * w for _ in range(h)]; sizes = [0]; n = 0
    for y in range(h):
        for x in range(w):
            if m[y][x] and not lab[y][x]:
                n += 1; stack = [(y, x)]; lab[y][x] = n; c = 0
                while stack:
                    cy, cx = stack.pop(); c += 1
                    for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
                        if 0 <= ny < h and 0 <= nx < w and m[ny][nx] and not lab[ny][nx]: lab[ny][nx] = n; stack.append((ny, nx))
                sizes.append(c)
    return lab, sizes

def key_logo(keyart, out):
    """the logo out of GOG's key art (see the module's notes): written as an RGBA PNG"""
    W, H, px = read_png(keyart)
    if (W, H) != (1600, 740): return False                       # (another picture: the crop below is this one's)
    x0, y0, x1, y1 = 460, 160, 1160, 520; w, h = x1 - x0, y1 - y0
    rgb = [row[x0:x1] for row in px[y0:y1]]
    m = [[1 if (max(p) > 107 and (max(p) - min(p)) < 0.16 * max(p)) else 0 for p in row] for row in rgb]
    for _ in range(2): m = _shrink(_grow(m, w, h, 2), w, h, 2)  # close the metal's scratches
    outside = [[0] * w for _ in range(h)]; stack = [(y, x) for y in (0, h - 1) for x in range(w) if not m[y][x]] + [(y, x) for x in (0, w - 1) for y in range(h) if not m[y][x]]
    for y, x in stack: outside[y][x] = 1
    while stack:                                                 # holes: what the outside can't reach
        cy, cx = stack.pop()
        for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
            if 0 <= ny < h and 0 <= nx < w and not m[ny][nx] and not outside[ny][nx]: outside[ny][nx] = 1; stack.append((ny, nx))
    m = [[1 if m[y][x] or not outside[y][x] else 0 for x in range(w)] for y in range(h)]
    lab, sizes = _components(m, w, h)
    letters = [[1 if sizes[lab[y][x]] > 1500 else 0 for x in range(w)] for y in range(h)]
    near = _grow(letters, w, h, 14); far = _grow(letters, w, h, 60)
    keep = [[1 if letters[y][x] or (lab[y][x] and 60 < sizes[lab[y][x]] <= 1500 and near[y][x]) else 0 for x in range(w)] for y in range(h)]
    green = [[1 if far[y][x] and rgb[y][x][1] > rgb[y][x][0] + 20 and rgb[y][x][1] > rgb[y][x][2] + 20 else 0 for x in range(w)] for y in range(h)]
    gl, gs = _components(green, w, h)
    bevel = _grow(keep, w, h, 4)
    a = [[255 if bevel[y][x] or (gl[y][x] and gs[gl[y][x]] > 40) else 0 for x in range(w)] for y in range(h)]
    soft = [[sum(a[yy][xx] for yy in (y - 1, y, y + 1) for xx in (x - 1, x, x + 1) if 0 <= yy < h and 0 <= xx < w) // 9 for x in range(w)] for y in range(h)]
    on = [(x, y) for y in range(h) for x in range(w) if soft[y][x] > 5]
    bx0, by0, bx1, by1 = min(p[0] for p in on), min(p[1] for p in on), max(p[0] for p in on) + 1, max(p[1] for p in on) + 1
    rows = []
    for y in range(by0, by1):
        row = []
        for x in range(bx0, bx1):
            lx, ly = x - bx0, y - by0; al = soft[y][x]
            if (lx > 500 and ly < 78) or (lx > 660 and ly < 112): al = 0   # (the camouflage beside TOM CLANCY'S and the T)
            row.append(rgb[y][x] + (al,))
        rows.append(row)
    write_png(out, rows, alpha=True); return True

def gog_art(out):
    """GOG's box art and key art for Ghost Recon; the API's links if the known ones have gone"""
    have = lambda n: os.path.exists(os.path.join(out, n))
    cover, keyart = GOG_COVER, GOG_KEYART
    if not have('cover.jpg') and not download(cover, os.path.join(out, 'cover.jpg')):
        try: links = json.loads(fetch(GOG_API)).get('_links', {}); download(links['boxArtImage']['href'], os.path.join(out, 'cover.jpg'))
        except Exception as e: print('  GOG: %s' % e, file=sys.stderr)
    if not have('keyart.png'):
        try:
            d = fetch(keyart)
            if d.startswith(b'\x89PNG'):
                with open(os.path.join(out, 'keyart.png.part'), 'wb') as f: f.write(d)
                os.replace(os.path.join(out, 'keyart.png.part'), os.path.join(out, 'keyart.png'))
        except Exception as e: print('  GOG key art: %s' % e, file=sys.stderr)
    if have('keyart.png') and not have('logo-hd.png'):
        try: key_logo(os.path.join(out, 'keyart.png'), os.path.join(out, 'logo-hd.png'))
        except Exception as e: print('  logo: %s' % e, file=sys.stderr)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    game = sys.argv[sys.argv.index('--game') + 1] if '--game' in sys.argv[1:-1] else None
    if game in args: args.remove(game)
    if len(args) < 2 or args[0] not in GAMES: sys.exit(__doc__)
    app, hero, card = GAMES[args[0]]; out = args[1]; os.makedirs(out, exist_ok=True)
    if game: from_copy(args[0], game, out)
    if '--no-downloads' in sys.argv[1:]: return 0
    have = lambda n: os.path.exists(os.path.join(out, n))
    if not have('header.jpg'): download(ASSET % (app, 'header.jpg'), os.path.join(out, 'header.jpg'))
    if args[0] == 'gr': gog_art(out)
    spare = None
    for n, name, size in (('hero.jpg', hero, '1920x1080'), ('shot1.jpg', card, '600x338')):
        p = os.path.join(out, n)
        if have(n) or download(ASSET % (app, '%s.%s.jpg' % (name, size)), p): continue
        if spare is None: spare = [s for s in store_shots(app) if s not in (hero, card)]   # a chosen one has gone
        while spare and not download(ASSET % (app, '%s.%s.jpg' % (spare.pop(0), size)), p): pass
    others = [x for x in store_shots(app) if x not in (hero, card)][:4]   # more of the store's screenshots: slides
    for k, name in enumerate(others):
        if not have('shot-%d.jpg' % (k + 2)): download(ASSET % (app, '%s.1920x1080.jpg' % name), os.path.join(out, 'shot-%d.jpg' % (k + 2)))
    return 0 if have('hero.jpg') or have('shot1.jpg') else 1

if __name__ == '__main__': sys.exit(main())
