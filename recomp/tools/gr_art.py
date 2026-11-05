#!/usr/bin/env python3
"""gr_art.py <gr|ds|it> <art folder> [--no-downloads]

The launch window's art for Ghost Recon or one of its expansions (install.sh), written to the given folder (never to
this project), from the Steam store page: Ghost Recon 15300, Desert Siege 13620, Island Thunder 13630. These old store
pages have no library hero or transparent logo, so the window draws the titles itself and uses screenshots:
  hero.jpg     a full-size (1920x1080) screenshot, across the top of the window
  shot1.jpg    another screenshot (600x338): the campaign's card
  header.jpg   the store page's header (the box art's logo on white), kept for reference; the window doesn't use it
Chosen screenshots are asked for by name; if one has gone, the store's screenshot list (appdetails) fills the gap.
--no-downloads (or no network): nothing is fetched and the window draws plain colours. Standard library only.
"""
import json, os, sys, urllib.request

GAMES = {   # app id, the hero screenshot, the card's screenshot
    'gr': (15300, '0000004465', '0000004461'),     # a fire team over a fence; a rifleman in the hills
    'ds': (13620, '0000003912', '0000003918'),     # a fire team in the woods; a night advance
    'it': (13630, '0000003920', '0000003927'),     # the jungle ridge; a village in the fog
}
ASSET = 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/%d/%s'
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

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) < 2 or args[0] not in GAMES: sys.exit(__doc__)
    app, hero, card = GAMES[args[0]]; out = args[1]; os.makedirs(out, exist_ok=True)
    if '--no-downloads' in sys.argv[1:]: return 0
    have = lambda n: os.path.exists(os.path.join(out, n))
    if not have('header.jpg'): download(ASSET % (app, 'header.jpg'), os.path.join(out, 'header.jpg'))
    spare = None
    for n, name, size in (('hero.jpg', hero, '1920x1080'), ('shot1.jpg', card, '600x338')):
        p = os.path.join(out, n)
        if have(n) or download(ASSET % (app, '%s.%s.jpg' % (name, size)), p): continue
        if spare is None: spare = [s for s in store_shots(app) if s not in (hero, card)]   # a chosen one has gone
        while spare and not download(ASSET % (app, '%s.%s.jpg' % (spare.pop(0), size)), p): pass
    return 0 if have('hero.jpg') or have('shot1.jpg') else 1

if __name__ == '__main__': sys.exit(main())
