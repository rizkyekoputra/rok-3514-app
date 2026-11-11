#!/usr/bin/env python3
"""One-way copy: old ledger (Apps Script web app, public read) -> Supabase ledger.

Reads only. The old ledger and the old repo (../rok-3514) are never written to.

  python3 scripts/import/import_ledger.py            # show what would be imported
  python3 scripts/import/import_ledger.py --write    # replace previously imported rows in Supabase
  python3 scripts/import/import_ledger.py --check    # compare the new ledger's answer with the old one

Needs SUPABASE_URL and SUPABASE_SERVICE_KEY in the environment (or in .env next to this repo's root).
The old ledger's public answer has no per-payment history (undo rows) and no record of who zeroed whom,
so imported zero records say "imported" as the R4; everything the dashboard shows is copied exactly.
"""
import argparse
import csv
import hashlib
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OLD = os.path.abspath(os.environ.get('OLD_REPO', os.path.join(os.path.dirname(ROOT), 'rok-3514')))
TRACKER = os.path.join(OLD, 'tracker')


def load_env():
    path = os.path.join(ROOT, '.env')
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            m = re.match(r'\s*([A-Z_]+)\s*=\s*(.*?)\s*$', line)
            if m and not line.lstrip().startswith('#'):
                os.environ.setdefault(m.group(1), m.group(2).strip('"\''))
    # TODO: Securely load these values from an environment variable or secrets vault. Do not hardcode.
    url, key = os.environ.get('SUPABASE_URL'), os.environ.get('SUPABASE_SERVICE_KEY')
    if not url or not key:
        sys.exit('Set SUPABASE_URL and SUPABASE_SERVICE_KEY (environment or .env)')
    return url.rstrip('/'), key


def old_ledger_url():
    if os.environ.get('OLD_LEDGER_URL'):
        return os.environ['OLD_LEDGER_URL']
    src = open(os.path.join(TRACKER, 'track.py'), encoding='utf-8').read()  # set OLD_LEDGER_URL when the old repo is not next to this one
    return re.search(r"^FINES_URL = '([^']+)'", src, re.M).group(1)


def get_json(url, data=None, headers=None):
    req = urllib.request.Request(url, data=None if data is None else json.dumps(data).encode(),
                                 headers=dict({'Content-Type': 'application/json'}, **(headers or {})))
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r)


def rpc(url, key, fn, body):
    headers = {'apikey': key}
    if key.count('.') == 2:  # legacy JWT keys also go in Authorization; new sb_secret_ keys only in apikey
        headers['Authorization'] = 'Bearer ' + key
    return get_json(f'{url}/rest/v1/rpc/{fn}', body, headers)


def read(name):
    path = os.path.join(TRACKER, name)
    return list(csv.DictReader(open(path, encoding='utf-8-sig'))) if os.path.exists(path) else []


def key(r):
    return r['governor_id'] or 'name:' + r['name']


def h10(s):
    return hashlib.sha1(s.encode()).hexdigest()[:10]


def names():
    """fine_id -> (player, week) and account_id -> player, from the old repo's CSVs (same ids as track.py)."""
    fines = {h10(f'3514|{key(r)}|{r["week"]}'): (r['name'], r['week']) for r in read('offense_log.csv')}
    fines.update({h10(f'3514|{key(r)}|mge|{r["mge"]}'): (r['name'], 'mge:' + r['mge']) for r in read('mge_log.csv')})
    fines.update({h10(f'3514|{key(r)}|gh|{r["gh"]}'): (r['name'], 'gh:' + r['gh']) for r in read('gh_log.csv')})
    accts = {}
    for f in ['accounts.csv', 'accounts_online.csv', 'migrate_online.csv'] + \
             [f'{d}/{x}' for d in ('scans', 'names', 'weeks') if os.path.isdir(os.path.join(TRACKER, d))
              for x in sorted(os.listdir(os.path.join(TRACKER, d))) if re.fullmatch(r'\d{4}-\d{2}-\d{2}\.csv', x)]:
        for r in read(f):
            if r.get('name'):
                accts[h10(f'3514|acct|{key(r)}')] = r['name']
    return fines, accts


def build(old):
    fines, accts = names()
    data = {'officers': [], 'payments': [], 'account_changes': [], 'migrate_events': [], 'claims': []}
    for o in old.get('officers', []):
        data['officers'].append(dict(name=o['n'], key_hash=o['h'], approver=bool(o.get('a'))))
    for fid, p in old.get('paid', {}).items():
        player, week = fines.get(fid, (None, None))
        data['payments'].append(dict(time=p['time'], fine_id=fid, player=player, week=week, amount=p['amount'],
                                     by_name=p['by'], action='paid'))
    for aid, a in old.get('accounts', {}).items():
        if a.get('type'):
            data['account_changes'].append(dict(time=a['decided'], account_id=aid, player=accts.get(aid), type=a['type'],
                                                by_name=a['by'], status='approved', decided=a['decided'],
                                                decided_by=a.get('approvedBy')))
        if a.get('pending'):
            p = a['pending']
            data['account_changes'].append(dict(time=p['time'], account_id=aid, player=accts.get(aid), type=p['type'],
                                                by_name=p['by'], status='proposed', note=p.get('note')))
    for aid, m in old.get('migrate', {}).items():
        player = accts.get(aid)
        if m.get('m'):
            data['migrate_events'].append(dict(time=m['mt'], account_id=aid, player=player, action=m['m'], by_name=m['mb']))
        if m.get('out'):
            data['migrate_events'].append(dict(time=m['out']['time'], account_id=aid, player=player, action='out',
                                               by_name=m['out']['by']))
        for i in range(int(m.get('z') or 0)):
            data['migrate_events'].append(dict(time=m['zt'], account_id=aid, player=player, action='zero',
                                               by_name='imported', ref=h10(f'zero|{aid}|{i}')))
    for fid, c in old.get('claims', {}).items():
        player, week = fines.get(fid, (None, None))
        data['claims'].append(dict(claim_id='imp-' + fid, time=c['t'], fine_id=fid, player=player, week=week,
                                   status=c['s'], reason=c.get('why')))
    return data


def compare(old, new):
    """Differences between the old and new ledger answers, for the parts the dashboard reads."""
    diffs = []
    norm = lambda v: json.loads(json.dumps(v, sort_keys=True))
    for part in ('paid', 'accounts', 'migrate', 'claims'):
        a, b = norm(old.get(part, {})), norm(new.get(part, {}))
        for k in sorted(set(a) | set(b)):
            if a.get(k) != b.get(k):
                diffs.append(f'{part}[{k}]: old {a.get(k)} / new {b.get(k)}')
    oa = sorted((o['n'], o['h'], bool(o.get('a'))) for o in old.get('officers', []))
    ob = sorted((o['n'], o['h'], bool(o.get('a'))) for o in new.get('officers', []))
    if oa != ob:
        diffs.append(f'officers differ: {len(oa)} old / {len(ob)} new (names: '
                     f'{sorted(set(x[0] for x in oa) ^ set(x[0] for x in ob)) or "same names, hash or approver differs"})')
    return diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()
    url, skey = load_env()
    old = get_json(old_ledger_url())
    data = build(old)
    unnamed = sum(1 for p in data['payments'] if not p['player']) + sum(1 for a in data['account_changes'] if not a['player'])
    print('old ledger: ' + ', '.join(f'{len(v)} {k}' for k, v in data.items()) +
          (f'; {unnamed} rows without a player name (still imported, matched by id)' if unnamed else ''))
    if args.write:
        print('imported:', rpc(url, skey, 'ledger_import', {'data': data}))
    if args.check or args.write:
        new = rpc(url, skey, 'ledger_get', {'p_key': None})
        diffs = compare(old, new)
        print('\n'.join(diffs) if diffs else 'new ledger matches the old one (paid, accounts, migrate, claims, officers)')
        sys.exit(1 if diffs else 0)
    if not args.write:
        print('Rerun with --write to import.')


if __name__ == '__main__':
    main()
