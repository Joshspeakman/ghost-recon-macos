#!/usr/bin/env python3
"""gta3_art.py <art folder> [--no-downloads]

The launch window's art (install.sh), written to the data folder's art/ (never to this project), from Steam's store
page for Grand Theft Auto III (app 12100, the same art as the Mac release 12230):
  logo.png              the game's logo with transparency
  hero.jpg              Steam's library hero (Catalina against the city), across the top of the window
  shot1-3.jpg           three of the store page's screenshots, for the window's strip of Liberty City
--no-downloads (or no network): nothing is fetched and the window writes the title instead. Standard library only.
"""
import os, sys, urllib.request

CDN = 'https://cdn.cloudflare.steamstatic.com/steam/apps/12100/'
SHOTS = 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/12100/%s.600x338.jpg'
FILES = {'logo.png': (CDN + 'logo.png', b'\x89PNG'), 'hero.jpg': (CDN + 'library_hero.jpg', b'\xff\xd8'),
         'shot1.jpg': (SHOTS % '0000003292', b'\xff\xd8'), 'shot2.jpg': (SHOTS % '0000003296', b'\xff\xd8'),
         'shot3.jpg': (SHOTS % '0000003295', b'\xff\xd8')}

def download(url, path, magic):
    try:
        with urllib.request.urlopen(url, timeout=20) as r: d = r.read()
    except Exception as e:
        print('  %s: %s' % (os.path.basename(path), e), file=sys.stderr); return False
    if not d.startswith(magic) or len(d) < 5000: return False
    with open(path + '.part', 'wb') as f: f.write(d)
    os.replace(path + '.part', path); return True

def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    if '--no-downloads' in sys.argv[2:]: return 0
    got = [n for n, (u, m) in FILES.items() if os.path.exists(os.path.join(out, n)) or download(u, os.path.join(out, n), m)]
    return 0 if got else 1

if __name__ == '__main__': sys.exit(main())
