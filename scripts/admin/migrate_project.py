#!/usr/bin/env python3
"""Copy the 3514 ledger (and claim proof files) from one Supabase project to another.

Run the migrations on the new project first (`supabase db push --remote`, after `supabase link`), then this script,
then deploy the `claim-files` Edge Function to the new project. Keep both sites quiet during the copy.

Credentials are read from the environment / .env only, never from arguments or chat:

  OLD_DATABASE_URL, NEW_DATABASE_URL       direct Postgres connection strings (with the DB password)
  OLD_SUPABASE_URL, OLD_SUPABASE_SERVICE_KEY
  SUPABASE_URL, SUPABASE_SERVICE_KEY       the new project (same names as the other scripts), for proof files

  python3 scripts/admin/migrate_project.py            # counts + plan, no changes
  python3 scripts/admin/migrate_project.py --write    # copy tables, then proof files
  python3 scripts/admin/migrate_project.py --files-only  # only proof files (tables already copied)

The old project can be egress-restricted (HTTP 402); in that case wait for the billing cycle or upgrade it first.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUCKET = 'claims'
TABLES = ('officers', 'payments', 'account_changes', 'migrate_events', 'claims', 'claim_files')
SECRET_NAMES = ('OLD_DATABASE_URL', 'NEW_DATABASE_URL', 'OLD_SUPABASE_URL', 'OLD_SUPABASE_SERVICE_KEY',
                'SUPABASE_SERVICE_KEY')


def load_env():
    path = os.path.join(ROOT, '.env')
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            if line.lstrip().startswith('#'):
                continue
            m = re.match(r'\s*([A-Z_]+)\s*=\s*(.*?)\s*$', line)
            if m:
                os.environ.setdefault(m.group(1), m.group(2).strip('"\''))
    for name in ('OLD_DATABASE_URL', 'NEW_DATABASE_URL', 'OLD_SUPABASE_URL', 'OLD_SUPABASE_SERVICE_KEY',
                 'SUPABASE_URL', 'SUPABASE_SERVICE_KEY'):
        if not os.environ.get(name):
            sys.exit(f'Set {name} in the environment or in .env (see the docstring)')


def redact(text):
    for name in SECRET_NAMES:
        value = os.environ.get(name)
        if value and len(value) > 6:
            text = text.replace(value, f'<{name}>')
    return text


def pg_args(url):
    u = urllib.parse.urlsplit(url)
    env = dict(os.environ, PGPASSWORD=urllib.parse.unquote(u.password or ''))
    args = ['-h', u.hostname or 'localhost', '-p', str(u.port or 5432),
            '-U', urllib.parse.unquote(u.username or ''), '-d', (u.path or '/postgres').lstrip('/')]
    return args, env


def psql(url, sql):
    args, env = pg_args(url)
    cmd = ['psql', '--no-psqlrc', '-v', 'ON_ERROR_STOP=1', '-A', '-t', '-F', '\t', '-c', sql] + args
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode:
        sys.exit('psql failed: ' + redact(r.stderr.strip()))
    return r.stdout.strip()


def counts(url):
    q = ' union all '.join(f"select '{t}', count(*) from ledger.{t}" for t in TABLES)
    return dict(line.split('\t') for line in psql(url, q).splitlines() if line)


def copy_tables(old, new):
    old_args, old_env = pg_args(old)
    new_args, new_env = pg_args(new)
    dump = subprocess.Popen(['pg_dump', '--data-only', '--no-owner', '--no-privileges', '-n', 'ledger'] + old_args,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=old_env)
    restore = subprocess.run(['psql', '--no-psqlrc', '-v', 'ON_ERROR_STOP=1', '-f', '-'] + new_args,
                             stdin=dump.stdout, capture_output=True, text=True, env=new_env)
    dump.stdout.close()
    dump_err = dump.stderr.read().decode()
    if dump.wait() or restore.returncode:
        sys.exit('table copy failed: ' + redact((dump_err + '\n' + restore.stderr).strip()))


def storage_headers(key, content_type=None):
    h = {'apikey': key}
    if key.count('.') == 2:
        h['Authorization'] = 'Bearer ' + key
    if content_type:
        h['Content-Type'] = content_type
    return h


def request(url, key, method='GET', data=None, headers=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={**storage_headers(key), **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read(), r.headers
    except urllib.error.HTTPError as e:
        sys.exit(f'{urllib.parse.urlsplit(url).path}: HTTP {e.code} {redact(e.read().decode()[:200])}')


def copy_files(old_db, old_url, old_key, new_url, new_key, write):
    rows = psql(old_db, "select path, type from ledger.claim_files order by path").splitlines()
    paths = [line.split('\t') for line in rows if line]
    print(f'{len(paths)} proof files referenced by the ledger')
    if not write:
        return
    for i, (path, typ) in enumerate(paths, 1):
        data, hdrs = request(f'{old_url}/storage/v1/object/{BUCKET}/{urllib.parse.quote(path)}', old_key)
        request(f'{new_url}/storage/v1/object/{BUCKET}/{urllib.parse.quote(path)}', new_key, method='POST',
                data=data, headers={'x-upsert': 'true', 'Content-Type': typ or hdrs.get('Content-Type', 'application/octet-stream')})
        if i % 10 == 0:
            print(f'  copied {i}/{len(paths)}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--files-only', action='store_true', help='copy proof files only; leaves the ledger tables alone')
    args = ap.parse_args()
    load_env()
    old_db, new_db = os.environ['OLD_DATABASE_URL'], os.environ['NEW_DATABASE_URL']
    old_url, old_key = os.environ['OLD_SUPABASE_URL'].rstrip('/'), os.environ['OLD_SUPABASE_SERVICE_KEY']
    new_url, new_key = os.environ['SUPABASE_URL'].rstrip('/'), os.environ['SUPABASE_SERVICE_KEY']

    if args.files_only:
        copy_files(old_db, old_url, old_key, new_url, new_key, True)
        print('proof files copied')
        return

    before, after = counts(old_db), counts(new_db)
    print('table'.ljust(18), 'old'.rjust(7), 'new'.rjust(7))
    for t in TABLES:
        print(t.ljust(18), before.get(t, '?').rjust(7), after.get(t, '?').rjust(7))
    if not args.write:
        print('dry run: add --write to copy the tables and proof files')
        return
    copy_tables(old_db, new_db)
    got = counts(new_db)
    if any(before.get(t) != got.get(t) for t in TABLES):
        sys.exit('row counts differ after the copy: ' + json.dumps(got, sort_keys=True))
    print('tables copied and verified')
    copy_files(old_db, old_url, old_key, new_url, new_key, True)
    print('done; deploy claim-files to the new project and update supabase.json + GitHub secrets')


if __name__ == '__main__':
    main()
