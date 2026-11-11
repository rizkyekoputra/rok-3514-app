# CLAUDE.md

New home of the Kingdom 3514 (Rise of Kingdoms) dashboard + ledger. Supabase Postgres replaces the "3514 Fines"
Google Sheet + Apps Script; a new frontend will replace the GitHub Pages dashboard. See README.md for status.

## Hard rule: the old system is read-only

Until the switchover, the old system keeps running untouched. **Only read from it. Never commit, push, `clasp push`
or edit there:**

- `~/rok-3514` (tracker/track.py, the weekly skill in `.claude/skills/rok-weekly`)
- the Apps Script + "3514 Fines" Google Sheet (`~/rok-3514/tracker/fines_ledger/Code.js`)
- the GitHub Pages dashboard repo `rok-3514-dashboard`

`Code.js` is the reference for API behaviour: `ledger_get` / `ledger_post` must answer the same JSON as its
`doGet` / `doPost`. When porting a feature, read it there and reimplement it here.

## Secrets

- Public by design: the publishable key + URL in `supabase.json`.
- Secret: the secret (service role) key, in `.env` (gitignored) and in the GitHub Actions secrets
  `SUPABASE_URL` / `SUPABASE_SERVICE_KEY`. **Never print, echo, log or commit it**, and never put it in a
  frontend. Scripts read it from the environment / `.env` (see `load_env()` in `scripts/import/import_ledger.py`).
- R4 keys are never stored anywhere in this repo or database, only `sha256(key)` in `ledger.officers.key_hash`.
- Future AI provider keys go in Supabase Vault, not in code or `.env` files that get committed.

## Security model

- All tables are in schema `ledger`: not exposed by the Data API, RLS on with no policies, no grants to
  `anon` / `authenticated`. Don't add policies or grants to make something work; add an RPC instead.
- The browser (publishable key) may only call `SECURITY DEFINER` functions in `public`:
  - `ledger_get(p_key)`: public reads; R4-only parts (`claimList`, `zeroList`) need a valid key.
  - `ledger_post(req)`: player actions without a key (`propose`, `claim`, `claim_done`); every other action checks
    `sha256(req.key)` against active officers.
- `ledger_import(data)` and anything else that bypasses the officer check is `service_role` only.
- Every `SECURITY DEFINER` function has `set search_path = ''` and fully qualified names. After adding one,
  `revoke all ... from public, anon, authenticated` and grant only what's needed.
- Proof files for payment claims live in the private Storage bucket `claims` (no Storage policies). The browser
  only gets short-lived signed URLs from the `claim-files` Edge Function, after the SQL side has checked the
  claim token or R4 key.

## IDs (must match the old tracker)

- `fine_id = sha1("3514|{gid or 'name:'+name}|{week}")[:10]`; MGE: `"3514|{gid…}|mge|{start}"`; GH: `"3514|{gid…}|gh|{start}"`
- `account_id = sha1("3514|acct|{gid or 'name:'+name}")[:10]`

## Database changes

Migrations are in `supabase/migrations/`. Never edit a migration that is already applied remotely; add a new one.

```sh
supabase migration new <name>
supabase start && supabase db reset      # local test (Docker)
supabase db push --remote --dry-run      # always show this to the user first
supabase db push --remote                # only after the user OKs the dry run
supabase functions deploy claim-files    # Edge Functions: also only after the user OKs
```

Claims test (local only): `supabase db reset`, `supabase functions serve` in the background, then
`python3 scripts/test/test_claims.py`. For anything else against the local stack, take keys from
`supabase status -o env` into env vars without printing them; `.env` holds the *remote* secret key.

## Import / sync from the old ledger (one way)

```sh
python3 scripts/import/import_ledger.py            # what the old ledger has
python3 scripts/import/import_ledger.py --write    # replace imported rows (imported = true), keep API-written rows
python3 scripts/import/import_ledger.py --check    # compare new vs old ledger_get answers
```

`.github/workflows/sync-ledger.yml` runs `--write` hourly (public GET of the old web app + public checkout of the
old repo for player names) and fails if the result differs. Rows written through the new API are never touched by
the import, so using the new write paths for real before the switchover makes `--check` report differences.

## Dashboard

`scripts/web/build.py` builds `site/` from the published old dashboard; `web/loader.js` is the Supabase adapter.
Deployed by `.github/workflows/pages.yml` (push + hourly). Remaining phases: `docs/frontend-plan.md`.

## Plans

Frontend and AI extraction: `docs/frontend-plan.md`.

## Conventions

- Keep `ledger_post` answers `{ok: true, ...}` / `{ok: false, error}` with the same error texts as Code.js.
- Player-supplied text goes through `ledger.clip()`; lengths match Code.js.
- One writer at a time: `pg_advisory_xact_lock(3514)` at the start of every write RPC.
