#!/usr/bin/env python3
"""Daily cleanup of payment-claim proof files (Code.js cleanupClaims).

Deletes the files of claims decided over 30 days ago and of uploads never finished after a day (those claims become
"abandoned"), plus any file left behind by an already-cleaned claim. Storage files can only be deleted through the
Storage API, so this runs outside the database (.github/workflows/cleanup-claims.yml).

  python3 scripts/claims/cleanup_claims.py            # show what is due
  python3 scripts/claims/cleanup_claims.py --write    # delete the files and mark the claims cleaned

Needs SUPABASE_URL and SUPABASE_SERVICE_KEY in the environment (or in .env at the repo root).
"""
import argparse
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'import'))
from import_ledger import load_env, rpc  # noqa: E402

BUCKET = 'claims'


def delete_files(url, key, paths):
    headers = {'apikey': key, 'Content-Type': 'application/json'}
    if key.count('.') == 2:
        headers['Authorization'] = 'Bearer ' + key
    for i in range(0, len(paths), 100):
        req = urllib.request.Request(f'{url}/storage/v1/object/{BUCKET}', method='DELETE', headers=headers,
                                     data=json.dumps({'prefixes': paths[i:i + 100]}).encode())
        with urllib.request.urlopen(req, timeout=60) as r:
            r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    args = ap.parse_args()
    url, key = load_env()
    due = rpc(url, key, 'ledger_claims_due', {})
    paths = [p for c in due for p in c['paths']]
    print(f'{len(due)} claims due, {len(paths)} files')
    if not args.write or not due:
        return
    delete_files(url, key, paths)
    res = rpc(url, key, 'ledger_claims_cleaned', {'ids': [c['claim_id'] for c in due]})
    print('cleaned:', res.get('cleaned'))


if __name__ == '__main__':
    main()
