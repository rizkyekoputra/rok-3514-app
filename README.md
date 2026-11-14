# rok-3514-app

The Kingdom 3514 dashboard and ledger: **https://rizkyekoputra.github.io/rok-3514-app/**

This repo is the **frontend**: the page, the Supabase ledger (payments, account changes, must-migrate, claims, R4 keys) and the Pages deploy. [rok-3514](https://github.com/rizkyekoputra/rok-3514) is the **backend**: raw data, importers and `track.py`, which pushes the season data here as `data/season.json`.

Cutover done 15 Nov 2026: the "3514 Fines" Google Sheet is a read-only archive (its Apps Script web app is undeployed), and the old `rok-3514-dashboard` URL redirects here (keeping `?key=` and `#t=`, so old R4 links and mail links still work).

## Status

| Step | State |
|---|---|
| Supabase project `gwrqjzqkgvkapjzgktaf` (Singapore) | live |
| Ledger schema: officers, payments, account changes, must-migrate log, claim status | live (`supabase/migrations/`) |
| `ledger_get` / `ledger_post`: same JSON as the Apps Script `doGet` / `doPost` | live, tested |
| One-way copy from the old ledger (`scripts/import/import_ledger.py`) | retired at the cutover; the Apps Script web app is undeployed |
| Payment claims with proof files (private Storage bucket `claims`, Edge Function `claim-files`, daily cleanup) | live |
| Dashboard: `web/template.html` + `data/season.json` (from the tracker) + Supabase ledger, on GitHub Pages (`.github/workflows/pages.yml`, on push) | live: https://rizkyekoputra.github.io/rok-3514-app/ |
| Approvals start the rok-3514 recalc (`ledger.start_recalc()`, pg_net + Vault token `github_recalc_token`) | live |
| R4 key management (`scripts/admin/officers.py`, RPC `ledger_officer_admin`, secret key only) | live |
| Old dashboard URL redirects here | live |
| Upload → AI extract → preview → submit | not yet |

## Security model

- Tables live in schema `ledger`, which the Data API does not expose. RLS is on, no policies, no grants to `anon`/`authenticated`.
- The browser uses the **publishable** key (`supabase.json`, public by design) and can only call:
  - `rpc/ledger_get {p_key}`: public reads; the R4-only parts (`zeroList`, `claimList`) need a valid key.
  - `rpc/ledger_post {req}`: player proposals without a key; every R4 action checks `sha256(key)` against `ledger.officers`.
- R4 keys are never stored, only their SHA-256 (the old Sheet's keys were copied as hashes, so existing R4 links keep working).
- Claim proof files sit in the private bucket `claims` with no Storage policies. The `claim-files` Edge Function
  hands out signed URLs (upload: one file, no overwrite; view: 10 minutes) only after SQL has checked the claim
  token or R4 key. Claim tokens are stored as SHA-256.
- `rpc/ledger_import` and `rpc/ledger_officer_admin` are callable only with the **secret** key. That key lives in `.env` (gitignored) and in this repo's GitHub Actions secrets `SUPABASE_URL` / `SUPABASE_SERVICE_KEY`, never in code or chat.

## Day to day

Processing (rankings, MGE, AoO, …) happens in rok-3514: `sh tracker/publish.sh` there pulls the ledger, recalculates and
pushes `data/season.json` here; the site rebuilds in about a minute. The hourly `recalc` Action in rok-3514 does the same,
and every approval on the dashboard starts it right away.

### R4 keys

Run these yourself, in this folder. `add` and `rotate` print the R4's personal link **once**, in your terminal only: send it
to them privately. Nobody can show it again (only its SHA-256 is stored), so a lost link means `rotate`.

```sh
python3 scripts/admin/officers.py list
python3 scripts/admin/officers.py add "Exact In-game Name"            # new R4
python3 scripts/admin/officers.py add "Exact In-game Name" --approver # new approver (decides proposals)
python3 scripts/admin/officers.py rotate "Exact In-game Name"         # new link; the old one stops working at once
python3 scripts/admin/officers.py revoke "Exact In-game Name"         # remove an R4 (row kept for history)
python3 scripts/admin/officers.py approver "Exact In-game Name" on    # or off
```

Also keep the R4 list in rok-3514 (`tracker/accounts.csv`, role `R4`) in step: that one drives the reports and rewards.

### Dashboard

```sh
python3 scripts/web/build.py                  # site/ from web/template.html + data/season.json
python3 -m http.server -d site 8000           # look at it locally (reads the live Supabase ledger)
```

`data/season.json` comes from the tracker in rok-3514 (`track.py`, then `publish.sh` or the hourly `recalc` Action);
don't edit it here. `web/loader.js` loads `data.json` + `ledger_get`, then runs the page's script with its ledger
calls going to Supabase. UI changes go in `web/template.html`.

Every data table has a **Download CSV** button (also `web/loader.js`): exactly the rows and columns shown (search and
filters applied), as displayed, buttons left out; RFC 4180 quoting, CRLF, UTF-8 BOM for Excel; file name
`3514-<table title>-<data date>.csv`, so the same view always gives the same file.

### Payment claims

```sh
python3 scripts/claims/cleanup_claims.py           # what is due (files 30 days after the decision, stale uploads)
python3 scripts/claims/cleanup_claims.py --write   # delete them; daily on GitHub: cleanup-claims.yml
```

### Database changes

```sh
supabase migration new <name>          # write SQL in supabase/migrations/
supabase start && supabase db reset    # test locally (Docker)
supabase db push --remote --dry-run    # see what would change
supabase db push --remote              # apply
supabase functions deploy claim-files  # Edge Function
```

Local end-to-end test of claims (local stack only, it refuses anything else):

```sh
supabase db reset && supabase functions serve &   # then:
python3 scripts/test/test_claims.py
```

## Credentials and rotation

Where every key and password lives, and how to replace it. Never paste a secret value into a chat, an issue or a commit.

| Credential | Lives in | Used by | Expires |
|---|---|---|---|
| GitHub recalc token (fine-grained PAT) | Supabase Vault `github_recalc_token` | `ledger.start_recalc()`: approvals start rok-3514's `recalc.yml` | **yes**: the date you picked when creating it |
| Supabase secret key (`sb_secret_…`) | `.env` here + this repo's Actions secrets `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | `officers.py`, `cleanup-claims.yml`, `cleanup_claims.py` | no |
| Supabase database password | Supabase dashboard (you) | `supabase db push` / `supabase link` (CLI) | no |
| Supabase publishable key (public) | `supabase.json` | the page, `track.py --pull` | no |
| App deploy key (SSH, write) | rok-3514-app deploy key "rok-3514 recalc Action" + rok-3514 Actions secret `APP_DEPLOY_KEY` | `publish_app.sh` in the recalc Action pushes `data/season.json` | no |
| R4 dashboard keys | only with each R4 (DB keeps SHA-256) | `?key=` links | no |

**GitHub recalc token** (do this before it expires; when it has expired, approvals still work but wait for the hourly run):
1. GitHub → Settings → Developer settings → Fine-grained tokens → Generate new token. Repository access: only
   `rizkyekoputra/rok-3514`. Permissions: **Actions: Read and write**, nothing else. Note the expiry date.
2. Supabase dashboard → project rok-dashboard → SQL Editor:
   ```sql
   select vault.update_secret((select id from vault.secrets where name = 'github_recalc_token'), 'NEW_TOKEN');
   -- first time only (no secret yet):  select vault.create_secret('NEW_TOKEN', 'github_recalc_token');
   ```
3. Test: `select ledger.start_recalc();`, then a few seconds later
   `select status_code from net._http_response order by id desc limit 1;` → `204` (and a new "Recalculate dashboard" run
   in rok-3514's Actions). `401` = wrong token, `403`/`404` = missing permission or repository. Delete the old token on GitHub.

**Supabase secret key**:
1. Supabase dashboard → Project Settings → API Keys → Secret keys → create a new one.
2. Put it in `.env` here (`SUPABASE_SERVICE_KEY=…`) and in GitHub: `gh secret set SUPABASE_SERVICE_KEY -R rizkyekoputra/rok-3514-app`
   (it asks for the value; paste it there, not on the command line).
3. Check: `python3 scripts/admin/officers.py list` works. Then delete the old secret key in the dashboard.

**Supabase database password** (the CLI asks for it when linking or pushing migrations):
1. Supabase dashboard → Project Settings → Database → Reset database password. Save it in your password manager.
2. `supabase link --project-ref gwrqjzqkgvkapjzgktaf` (enter the new password), then
   `supabase db push --remote --dry-run` should connect.

**Supabase publishable key** (public, rotate only if you want to): create a new publishable key in the dashboard, put it
in `supabase.json`, push (the site rebuilds; the next recalc uses it), then disable the old one.

**App deploy key** (if it leaks or you want a fresh one):
```sh
ssh-keygen -t ed25519 -N '' -C 'rok-3514 recalc -> rok-3514-app' -f /tmp/app_key
gh repo deploy-key add /tmp/app_key.pub -R rizkyekoputra/rok-3514-app --allow-write -t 'rok-3514 recalc Action'
gh secret set APP_DEPLOY_KEY -R rizkyekoputra/rok-3514 < /tmp/app_key
rm /tmp/app_key /tmp/app_key.pub
gh repo deploy-key list -R rizkyekoputra/rok-3514-app   # then delete the old one: gh repo deploy-key delete <id> -R …
gh workflow run recalc.yml -R rizkyekoputra/rok-3514    # check it still publishes
```

**R4 key** (lost or leaked link): `python3 scripts/admin/officers.py rotate "Name"` and send the new link privately.

## Not copied from the old ledger

The old ledger's public answer is a summary, so these are missing:
- undo history of payments (only the current state);
- who zeroed whom (imported zero records say `imported`);
- claim proof files and amounts (only each fine's latest claim status). All 4 imported claims were already decided
  (approved) before the cutover; their proof files stay in the old ledger's Google Drive.

What the dashboard shows was identical at the cutover (`--check`).
