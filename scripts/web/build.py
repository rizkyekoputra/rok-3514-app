#!/usr/bin/env python3
"""Build the new dashboard (site/) from the old published one, pointed at Supabase.

Until the switchover the old tracker keeps publishing rok-3514-dashboard, so this reads that public page (read-only)
and splits it into:
  site/data.json   the season data (DATA without the ledger snapshot, R4 key hashes and the Apps Script URL)
  site/index.html  the same page; it loads data.json + ledger_get, and its ledger calls go to Supabase

  python3 scripts/web/build.py                  # from the published old dashboard
  python3 scripts/web/build.py --src FILE.html  # from a local copy (e.g. ~/rok-3514/tracker/dashboard/index.html)
  python3 -m http.server -d site 8000           # look at it
"""
import argparse
import json
import os
import re
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OLD_PAGE = 'https://rizkyekoputra.github.io/rok-3514-dashboard/'
DROP = ('ledger', 'officers', 'finesUrl')  # live from Supabase instead

# Patches to the old page's script; each must match exactly once, so a changed template fails the build loudly.
PATCHES = [
    # proof files: straight to Storage through a signed URL instead of base64 in JSON
    ("await post({action: 'claim_file', claim_id, token, name: files[i].name, type: typeOf(files[i]), data: await base64(files[i])});",
     "await LEDGER.uploadClaimFile(claim_id, token, files[i], typeOf(files[i]));"),
    # R4 view: a signed URL (10 minutes) instead of base64 bytes
    ("const bytes = Uint8Array.from(atob(j.data), ch => ch.charCodeAt(0)), url = URL.createObjectURL(new Blob([bytes], {type: j.type}));",
     "const url = j.url;"),
    ("Could not reach the sheet just now", "Could not reach the ledger just now"),
]


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'Cache-Control': 'no-cache'}), timeout=60) as r:
        return r.read().decode('utf-8')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src')
    ap.add_argument('--out', default=os.path.join(ROOT, 'site'))
    args = ap.parse_args()
    html = open(args.src, encoding='utf-8').read() if args.src else fetch(OLD_PAGE)
    cfg = json.load(open(os.path.join(ROOT, 'supabase.json')))  # public URL + publishable key only

    m = re.search(r'<script>\s*const DATA = (\{.*?\});\n', html, re.S)
    if not m:
        raise SystemExit('DATA not found in the old page')
    data = json.loads(m.group(1))
    for k in DROP:
        data.pop(k, None)

    # the main script waits for the loader: it becomes inert text that web/loader.js runs once DATA is in
    start = m.start()
    end = html.index('</script>', start)
    app = html[start + len('<script>'):end].replace(m.group(1), 'window.__DATA', 1)
    for old, new in PATCHES:
        if app.count(old) != 1:
            raise SystemExit(f'patch does not match the old page any more: {old[:70]}…')
        app = app.replace(old, new)
    loader = open(os.path.join(ROOT, 'web', 'loader.js'), encoding='utf-8').read()
    loader = loader.replace('__SUPABASE__', json.dumps({'url': cfg['url'], 'key': cfg['publishableKey']}))
    page = (html[:start] + '<script type="text/plain" id="app">' + app.replace('</script', '<\\/script') +
            '</script>\n<script>' + loader + '</script>' + html[end + len('</script>'):])

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'index.html'), 'w', encoding='utf-8') as f:
        f.write(page)
    with open(os.path.join(args.out, 'data.json'), 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
    print(f'site/: index.html {len(page) // 1024} KB, data.json {os.path.getsize(os.path.join(args.out, "data.json")) // 1024} KB '
          f'({len(data.get("players", []))} players, {len(data.get("fines", []))} fines, updated {data.get("updated")})')


if __name__ == '__main__':
    main()
