# CLAUDE.md

Kingdom 3514 (Rise of Kingdoms) dashboard (frontend) + ledger (Supabase Postgres). Cutover done 15 Nov 2026: the
"3514 Fines" Google Sheet + Apps Script and the old `rok-3514-dashboard` page are retired. See README.md for status.

## Two repos: frontend here, backend in rok-3514

- **This repo = frontend + ledger.** The page (`web/template.html`, `web/loader.js`), the Supabase ledger
  (migrations, RPCs, Edge Functions) and the Pages deploy. UI changes happen here, in `web/template.html`.
- **`~/rok-3514` = backend / admin processing.** Raw recordings and screenshots, the importers and `tracker/track.py`
  (the weekly skill in `.claude/skills/rok-weekly`). `track.py` writes `tracker/season.json`; `tracker/publish_app.sh`
  (run by `publish.sh` and the hourly `recalc` Action, deploy key `APP_DEPLOY_KEY`) commits it here as
  `data/season.json`, and the push rebuilds the site. Never hand-edit `data/season.json`; rerun the tracker.
- `track.py --pull` reads the ledger from here (public `ledger_get`, publishable key from `supabase.json`). Approvals
  start the rok-3514 `recalc` Action (`ledger.start_recalc()`).
- Retired, read-only archive (don't change): the Apps Script + "3514 Fines" Sheet
  (`~/rok-3514/tracker/fines_ledger/Code.js`, still the reference for API behaviour: keep `ledger_post` answers and
  error texts as in its `doPost`) and `rok-3514-dashboard`, now only a redirect here that keeps `?key=` and `#t=`.

## Secrets

- Public by design: the publishable key + URL in `supabase.json`.
- Secret: the secret (service role) key, in `.env` (gitignored) and in the GitHub Actions secrets
  `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` (this repo only). **Never print, echo, log or commit it**, and never put it in a
  frontend. Scripts read it from the environment / `.env` (see `load_env()` in `scripts/import/import_ledger.py`).
- R4 keys are never stored anywhere in this repo or database, only `sha256(key)` in `ledger.officers.key_hash`.
  `scripts/admin/officers.py` (service key, RPC `ledger_officer_admin`) adds/rotates/revokes them and prints a new link
  once: the user runs it; never run `add`/`rotate` for real yourself or ask for its output.
- Future AI provider keys go in Supabase Vault, not in code or `.env` files that get committed.
- Vault `github_recalc_token`: fine-grained GitHub token (rizkyekoputra/rok-3514 only, Actions read/write) that
  `ledger.start_recalc()` uses to start the `recalc.yml` Action (pg_net, sent after commit) when an approval is made
  (`approve`, or an approver's own `farm`/`main`), like the Apps Script's `triggerRecalc()`. The user sets or rotates
  it in the Supabase SQL editor; never handle the value yourself. Without it, answers say the hourly run picks it up.
- How to rotate each credential: README.md, "Credentials and rotation".

## Security model

- All tables are in schema `ledger`: not exposed by the Data API, RLS on with no policies, no grants to
  `anon` / `authenticated`. Don't add policies or grants to make something work; add an RPC instead.
- The browser (publishable key) may only call `SECURITY DEFINER` functions in `public`:
  - `ledger_get(p_key)`: public reads; R4-only parts (`claimList`, `zeroList`) need a valid key.
  - `ledger_post(req)`: player actions without a key (`propose`, `claim`, `claim_done`); every other action checks
    `sha256(req.key)` against active officers.
- `ledger_import(data)`, `ledger_officer_admin(req)` and anything else that bypasses the officer check is
  `service_role` only.
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

## Old ledger import (retired)

`scripts/import/import_ledger.py` copied the old Sheet into Supabase until the cutover (rows `imported = true`; rows
written through the API were kept). Reading and `--check` still work; `--write` refuses unless
`LEDGER_IMPORT_AFTER_CUTOVER=1`, since it would overwrite changes made here since (e.g. rotated R4 keys).

## Dashboard

`scripts/web/build.py` builds `site/` from `web/template.html` + `data/season.json`; `web/loader.js` loads
`data.json` + `ledger_get` and runs the page's script, with its ledger calls going to Supabase.
Deployed by `.github/workflows/pages.yml` on every push (so on every new `data/season.json`). The template started as
a copy of the old tracker's `dashboard_template.html` (14 Nov 2026, since deleted there), patched for Supabase; all UI
work happens here. Remaining phases: `docs/frontend-plan.md`.

## Plans

Frontend and AI extraction: `docs/frontend-plan.md`.

## Conventions

- Keep `ledger_post` answers `{ok: true, ...}` / `{ok: false, error}` with the same error texts as Code.js (the page expects them).
- Player-supplied text goes through `ledger.clip()`; lengths match Code.js.
- One writer at a time: `pg_advisory_xact_lock(3514)` at the start of every write RPC.
