#!/usr/bin/env python3
"""Write the public ledger snapshot that GitHub Pages serves as ledger.json.

The dashboard used to call ledger_get on every page load (twice, in fact) and download the whole ledger each time,
which burned the Supabase egress quota. This publishes the same public answer once an hour instead: ordinary visitors
read it from Pages, while R4 logins and writes still go straight to Supabase.

  python3 scripts/web/snapshot_ledger.py

Uses only the publishable key from supabase.json (public by design). R4-only fields (claimList, zeroList) are
never requested or written. Run by .github/workflows/ledger-snapshot.yml, which commits the file when it changes.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'import'))
from import_ledger import rpc  # noqa: E402

FIELDS = ('paid', 'accounts', 'claims', 'migrate', 'officers')  # exactly what the page shows to everyone


def main():
    cfg = json.load(open(os.path.join(ROOT, 'supabase.json'), encoding='utf-8'))
    res = rpc(cfg['url'], cfg['publishableKey'], 'ledger_get', {'p_key': None})
    if not isinstance(res, dict):
        sys.exit('ledger_get did not return an object')
    out = {k: res[k] for k in FIELDS if k in res}
    if 'claimList' in res or 'zeroList' in res:
        sys.exit('ledger_get returned R4-only fields with no key; refusing to publish them')
    path = os.path.join(ROOT, 'data', 'ledger_public.json')
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(out, f, sort_keys=True, separators=(',', ':'))
        f.write('\n')
    print(f'data/ledger_public.json: {os.path.getsize(path) // 1024} KB, '
          f'{len(out.get("paid", {}))} paid, {len(out.get("claims", {}))} claims')


if __name__ == '__main__':
    main()
