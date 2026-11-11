#!/usr/bin/env python3
"""End-to-end test of payment claims against the LOCAL Supabase stack only.

  supabase start && supabase db reset
  supabase functions serve &          # serves claim-files
  python3 scripts/test/test_claims.py

Reads the local URL/keys from `supabase status -o env` (never printed) and refuses to run against anything that is
not localhost. Writes test rows; run `supabase db reset` afterwards for a clean database.
"""
import hashlib
import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def local_env():
    out = subprocess.run(['supabase', 'status', '-o', 'env'], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    env = {}
    for line in out.splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip('"')
    url = env.get('API_URL', '')
    if not url.startswith(('http://127.0.0.1', 'http://localhost')):
        sys.exit('refusing: not a local stack')
    return url, env['ANON_KEY'], env['SERVICE_ROLE_KEY']


URL, ANON, SERVICE = local_env()
ok_count = 0


def http(method, path, body=None, key=ANON, raw=None, headers=None):
    h = {'apikey': key, 'Authorization': 'Bearer ' + key}
    if raw is None:
        h['Content-Type'] = 'application/json'
    h.update(headers or {})
    data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
    req = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            b = r.read()
            return r.status, (json.loads(b) if r.headers.get('Content-Type', '').startswith('application/json') else b)
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def post(req, key=ANON):
    return http('POST', '/rest/v1/rpc/ledger_post', {'req': req}, key)[1]


def get(k=None):
    return http('POST', '/rest/v1/rpc/ledger_get', {'p_key': k})[1]


def fn(req):
    return http('POST', '/functions/v1/claim-files', req)[1]


def sql(q):
    # psql inside the local database container (no local psql needed)
    return subprocess.run(['docker', 'exec', 'supabase_db_rok-3514-app', 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-qAtc', q],
                          capture_output=True, text=True, check=True).stdout.strip()


def check(name, cond, got=None):
    global ok_count
    if not cond:
        sys.exit(f'FAIL {name}: {got!r}')
    ok_count += 1
    print('ok  ', name)


def upload(up, data, ctype):
    return http('PUT', up, raw=data, headers={'Content-Type': ctype})[0]


R4_KEY = secrets.token_hex(16)  # throwaway local test key
s, r = http('POST', '/rest/v1/rpc/ledger_import', {'data': {'officers': [
    {'name': 'Test R4', 'key_hash': hashlib.sha256(R4_KEY.encode()).hexdigest(), 'approver': True}]}}, SERVICE)
check('import a test officer', s == 200 and r.get('ok'), r)

FINE = secrets.token_hex(5)
PNG, MP4 = b'\x89PNG\r\n\x1a\n' + secrets.token_bytes(500), secrets.token_bytes(3000)
base = {'action': 'claim', 'fine_id': FINE, 'player': 'Tester', 'week': '2026-11-02', 'fine': '5M gold', 'sent': '5M',
        'gold_value': 5000000, 'note': 'paid via trade'}
files = [{'type': 'image/png', 'size': len(PNG)}, {'type': 'video/mp4', 'size': len(MP4)}]

# ---- claim validation
check('bad fine_id', post({**base, 'fine_id': 'xyz', 'files': files})['error'] == 'bad request')
check('no files', post({**base, 'files': []})['error'] == 'attach 1 to 20 files')
check('21 files', post({**base, 'files': files[:1] * 21})['error'] == 'attach 1 to 20 files')
check('bad type', post({**base, 'files': [{'type': 'application/pdf', 'size': 9}]})['error'].startswith('only screenshots'))
check('over 30MB', post({**base, 'files': [{'type': 'video/mp4', 'size': 31457281}]})['error'] == 'files are over 30MB in total')

c = post({**base, 'files': files})
check('claim opens', c.get('ok') and len(c['claim_id']) == 12 and len(c['token']) == 32, c)
check('token stored hashed', sql(f"select token_hash = encode(extensions.digest('{c['token']}', 'sha256'), 'hex') "
                                  f"from ledger.claims where claim_id = '{c['claim_id']}'") == 't')
check('uploading claim is not public', FINE not in get()['claims'])

# ---- files
ff = {'action': 'claim_file', 'claim_id': c['claim_id'], 'token': c['token']}
check('claim_file via ledger_post points to the function', post(ff)['error'] == 'send this to the claim-files function')
check('wrong token', fn({**ff, 'token': 'nope', 'name': 'a.png', 'type': 'image/png', 'size': len(PNG)})['error'] == 'claim not open for upload')
check('bad file type', fn({**ff, 'name': 'a.pdf', 'type': 'application/pdf', 'size': 9})['error'] == 'file type not allowed')
check('bigger than announced', fn({**ff, 'name': 'a.png', 'type': 'image/png', 'size': len(PNG) + len(MP4) + 1})['error'] == 'file over the limit')
s1 = fn({**ff, 'name': 'pay ment.png', 'type': 'image/png', 'size': len(PNG)})
check('slot 1', s1.get('ok') and s1['count'] == 1 and s1['upload'].startswith('/storage/v1/object/upload/sign/claims/'), s1)
s1b = fn({**ff, 'name': 'pay ment.png', 'type': 'image/png', 'size': len(PNG)})
check('retry before upload reuses slot 1', s1b.get('file_id') == s1['file_id'], s1b)
check('anon cannot upload without a signed URL',
      http('POST', f'/storage/v1/object/claims/{c["claim_id"]}/x.png', raw=PNG, headers={'Content-Type': 'image/png'})[0] >= 400)
check('upload 1', upload(s1b['upload'], PNG, 'image/png') == 200)
check('signed upload URL cannot overwrite', upload(s1['upload'], PNG, 'image/png') >= 400)
s2 = fn({**ff, 'name': 'clip.mp4', 'type': 'video/mp4', 'size': len(MP4)})
check('slot 2', s2.get('ok') and s2['count'] == 2, s2)
check('no slot 3', fn({**ff, 'name': 'more.png', 'type': 'image/png', 'size': 10})['error'] == 'file over the limit')
check('upload 2', upload(s2['upload'], MP4, 'video/mp4') == 200)
check('claim_done wrong token', post({'action': 'claim_done', 'claim_id': c['claim_id'], 'token': 'x'})['error'] == 'claim not open')
check('claim_done', post({'action': 'claim_done', 'claim_id': c['claim_id'], 'token': c['token']}) == {'ok': True})
check('token gone after done', fn({**ff, 'name': 'late.png', 'type': 'image/png', 'size': 10})['error'] == 'claim not open for upload')
check('pending is public', get()['claims'].get(FINE, {}).get('s') == 'pending')
check('second claim while pending', post({**base, 'files': files})['error'] == 'proof for this fine is already waiting for an R4')

# ---- R4 view + decide
check('no claimList without key', 'claimList' not in get())
cl = [x for x in get(R4_KEY)['claimList'] if x['id'] == c['claim_id']]
check('claimList entry', len(cl) == 1 and [f['n'] for f in cl[0]['files']] == ['pay ment.png', 'clip.mp4']
      and cl[0]['gold'] == 5000000 and cl[0]['decided'] == '' and cl[0]['cleaned'] is False, cl)
fid = cl[0]['files'][1]['id']
check('claim_view without key', fn({'action': 'claim_view', 'claim_id': c['claim_id'], 'file_id': fid})['error'] == 'invalid key')
v = fn({'key': R4_KEY, 'action': 'claim_view', 'claim_id': c['claim_id'], 'file_id': fid})
check('claim_view signs a URL', v.get('ok') and v['type'] == 'video/mp4' and v['name'] == 'clip.mp4', v)
st, body = http('GET', v['url'])
check('signed URL serves the same bytes', st == 200 and body == MP4, st)
check('anon cannot call ledger_claim_file', http('POST', '/rest/v1/rpc/ledger_claim_file', {'req': ff})[0] in (401, 403, 404))
check('anon cannot call ledger_claims_due', http('POST', '/rest/v1/rpc/ledger_claims_due', {})[0] in (401, 403, 404))
check('anon cannot list the bucket', http('POST', '/storage/v1/object/list/claims', {'prefix': ''})[1] in (b'[]', []))

dec = {'key': R4_KEY, 'claim_id': c['claim_id']}
check('decide without key', post({**dec, 'key': 'bad', 'action': 'claim_approve', 'amount': 1})['error'] == 'invalid key')
check('reject needs reason', post({**dec, 'action': 'claim_reject', 'reason': '  '})['error'] == 'give a reason')
check('approve bad amount', post({**dec, 'action': 'claim_approve', 'amount': 0})['error'] == 'bad amount')
check('approve', post({**dec, 'action': 'claim_approve', 'amount': 5000000}) == {'ok': True, 'by': 'Test R4'})
g = get()
check('approval is a payment', g['paid'].get(FINE, {}).get('amount') == 5000000 and g['paid'][FINE]['by'] == 'Test R4', g['paid'].get(FINE))
check('public status approved', g['claims'][FINE]['s'] == 'approved')
check('approve twice', post({**dec, 'action': 'claim_approve', 'amount': 1})['error'] == 'claim is not waiting for a decision')

# ---- reject + size mismatch on another fine
F2 = secrets.token_hex(5)
c2 = post({**base, 'fine_id': F2, 'files': [{'type': 'image/png', 'size': 10}]})
s = fn({'action': 'claim_file', 'claim_id': c2['claim_id'], 'token': c2['token'], 'name': 'p.png', 'type': 'image/png', 'size': 10})
check('upload a bigger file than its slot', upload(s['upload'], PNG, 'image/png') == 200)
check('claim_done catches the size', post({'action': 'claim_done', 'claim_id': c2['claim_id'], 'token': c2['token']})['error'] == 'file over the limit')
c3 = post({**base, 'fine_id': F2, 'files': [{'type': 'image/png', 'size': len(PNG)}]})
check('claim_done with no upload', post({'action': 'claim_done', 'claim_id': c3['claim_id'], 'token': c3['token']})['error'] == 'no files arrived')
s = fn({'action': 'claim_file', 'claim_id': c3['claim_id'], 'token': c3['token'], 'name': 'p.png', 'type': 'image/png', 'size': len(PNG)})
upload(s['upload'], PNG, 'image/png')
post({'action': 'claim_done', 'claim_id': c3['claim_id'], 'token': c3['token']})
check('reject', post({'key': R4_KEY, 'claim_id': c3['claim_id'], 'action': 'claim_reject', 'reason': 'wrong amount'})['ok'])
check('public shows why', get()['claims'][F2] == {'s': 'rejected', 't': get()['claims'][F2]['t'], 'why': 'wrong amount'})

# ---- cleanup: decided 31 days ago, upload stale for 2 days
sql(f"update ledger.claims set decided = now() - interval '31 days' where claim_id = '{c['claim_id']}';"
    f"update ledger.claims set time = now() - interval '2 days' where claim_id = '{c2['claim_id']}'")
env = dict(os.environ, SUPABASE_URL=URL, SUPABASE_SERVICE_KEY=SERVICE)
out = subprocess.run([sys.executable, os.path.join(ROOT, 'scripts/claims/cleanup_claims.py'), '--write'],
                     env=env, capture_output=True, text=True)
check('cleanup runs', out.returncode == 0 and '2 claims due, 3 files' in out.stdout and 'cleaned: 2' in out.stdout, out.stdout + out.stderr)
check('files gone', sql(f"select count(*) from storage.objects where bucket_id = 'claims' and "
                        f"(name like '{c['claim_id']}/%' or name like '{c2['claim_id']}/%')") == '0')
check('stale upload abandoned', sql(f"select status from ledger.claims where claim_id = '{c2['claim_id']}'") == 'abandoned')
check('view after cleanup', fn({'key': R4_KEY, 'action': 'claim_view', 'claim_id': c['claim_id'], 'file_id': fid})['error']
      == 'file not found (deleted after 30 days?)')
check('rejected recent claim kept', sql(f"select count(*) from storage.objects where name like '{c3['claim_id']}/%'") == '1')
out = subprocess.run([sys.executable, os.path.join(ROOT, 'scripts/claims/cleanup_claims.py')], env=env, capture_output=True, text=True)
check('nothing due afterwards', '0 claims due' in out.stdout, out.stdout)

# ---- per-fine and burst limits
F3 = secrets.token_hex(5)
n = 0
while post({**base, 'fine_id': F3, 'files': files[:1]}).get('ok'):
    n += 1
check('perFine: 5 claims per fine', n == 5, n)
errs = []
for i in range(30):
    r = post({**base, 'fine_id': secrets.token_hex(5), 'files': files[:1]})
    if not r.get('ok'):
        errs.append(r['error'])
recent = int(sql("select count(*) from ledger.claims where not imported and time > now() - interval '10 minutes'"))
check('burst: 20 per 10 minutes', recent == 20 and errs and set(errs) == {'many claims just now, try again in a few minutes'}, (recent, errs[:1]))

print(f'\nall {ok_count} checks passed')
