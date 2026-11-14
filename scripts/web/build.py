#!/usr/bin/env python3
"""Build the dashboard (site/) from the page template and the season data.

  web/template.html  the page (UI lives here); its main script reads window.__DATA and talks to Supabase via LEDGER
  web/loader.js      loads data.json + ledger_get, then runs the main script
  data/season.json   season data written by the tracker in rok-3514 (track.py -> publish.sh / publish_ci.sh)

Output:
  site/index.html    template with the main script made inert (web/loader.js runs it once DATA is in)
  site/data.json     data/season.json as is

  python3 scripts/web/build.py
  python3 -m http.server -d site 8000           # look at it (reads the live Supabase ledger)
"""
import argparse
import json
import os
import re
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# never published: the ledger snapshot, R4 key hashes and the Apps Script URL (track.py leaves them out already)
DROP = ('ledger', 'officers', 'finesUrl')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default=os.path.join(ROOT, 'data', 'season.json'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'site'))
    args = ap.parse_args()
    html = open(os.path.join(ROOT, 'web', 'template.html'), encoding='utf-8').read()
    data = json.load(open(args.data, encoding='utf-8'))
    leaked = [k for k in DROP if k in data]
    if leaked:
        raise SystemExit(f'{args.data} has keys that must not be published: {leaked}')
    cfg = json.load(open(os.path.join(ROOT, 'supabase.json')))  # public URL + publishable key only

    m = re.search(r'<script>\s*const DATA = window\.__DATA;', html)
    if not m:
        raise SystemExit('main script (const DATA = window.__DATA;) not found in web/template.html')
    start = m.start()
    end = html.index('</script>', start)
    app = html[start + len('<script>'):end]
    loader = open(os.path.join(ROOT, 'web', 'loader.js'), encoding='utf-8').read()
    loader = loader.replace('__SUPABASE__', json.dumps({'url': cfg['url'], 'key': cfg['publishableKey']}))
    page = (html[:start] + '<script type="text/plain" id="app">' + app.replace('</script', '<\\/script') +
            '</script>\n<script>' + loader + '</script>' + html[end + len('</script>'):])

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'index.html'), 'w', encoding='utf-8') as f:
        f.write(page)
    shutil.copyfile(args.data, os.path.join(args.out, 'data.json'))
    print(f'site/: index.html {len(page) // 1024} KB, data.json {os.path.getsize(os.path.join(args.out, "data.json")) // 1024} KB '
          f'({len(data.get("players", []))} players, {len(data.get("fines", []))} fines, updated {data.get("updated")})')


if __name__ == '__main__':
    main()
