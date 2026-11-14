#!/usr/bin/env python3
"""R4 dashboard keys (replaces the old Sheet's Officers tab and 3514 menu).

  python3 scripts/admin/officers.py list
  python3 scripts/admin/officers.py add "NAME" [--approver]   new R4: prints their personal link once
  python3 scripts/admin/officers.py rotate "NAME"             new key, old link stops working at once: prints the link
  python3 scripts/admin/officers.py revoke "NAME"             link stops working (row kept for history)
  python3 scripts/admin/officers.py approver "NAME" on|off    approvers decide proposals; their farm/main applies at once

The key is generated here and shown only in this terminal; the database stores sha256(key). Send the link to the
R4 privately; nobody (including this repo) can show it again, so a lost link = rotate. Use the exact in-game name
(the dashboard shows it as "marked by <name>"). Needs SUPABASE_URL + SUPABASE_SERVICE_KEY (.env), like the import.
Run it yourself: don't paste its output into chats or tickets.
"""
import argparse
import hashlib
import os
import secrets
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'import'))
from import_ledger import load_env, rpc  # noqa: E402

DASHBOARD = 'https://rizkyekoputra.github.io/rok-3514-app/'


def call(req):
    url, skey = load_env()
    res = rpc(url, skey, 'ledger_officer_admin', {'req': req})
    if not res.get('ok'):
        sys.exit(f"Refused: {res.get('error')}")
    return res


def new_key():
    key = secrets.token_hex(16)  # 32 hex chars, same shape as the old Apps Script keys
    return key, hashlib.sha256(key.encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('action', choices=['list', 'add', 'rotate', 'revoke', 'approver'])
    ap.add_argument('name', nargs='?')
    ap.add_argument('value', nargs='?', choices=['on', 'off'])
    ap.add_argument('--approver', action='store_true')
    a = ap.parse_args()
    if a.action == 'list':
        for o in call({'action': 'list'})['officers']:
            print(f"{o['status']:8} {'approver' if o['approver'] else '        '} {o['name']}"
                  f"{'' if not o['imported'] else '   (from the old Sheet)'}")
        return
    if not a.name:
        sys.exit('Give the R4 name')
    if a.action in ('add', 'rotate'):
        key, h = new_key()
        call({'action': a.action, 'name': a.name, 'key_hash': h, 'approver': a.approver})
        print(f'{a.name}: {"added" if a.action == "add" else "new key, the old link no longer works"}'
              f'{" (approver)" if a.approver else ""}.\nSend this link privately, it is not stored anywhere:\n\n'
              f'  {DASHBOARD}?key={key}\n')
    elif a.action == 'revoke':
        call({'action': 'revoke', 'name': a.name})
        print(f'{a.name}: revoked, their link no longer works.')
    else:
        if not a.value:
            sys.exit('approver needs on or off')
        call({'action': 'approver', 'name': a.name, 'approver': a.value == 'on'})
        print(f"{a.name}: approver {a.value}.")


if __name__ == '__main__':
    main()
