# rok-3514-app

New home of the Kingdom 3514 dashboard and ledger: Supabase Postgres in place of the "3514 Fines" Google Sheet + Apps Script, and later an app with AI-assisted imports (upload screenshots and recordings, then preview and submit).

This repo is the **frontend**: the page, the Supabase ledger and the Pages deploy. [rok-3514](https://github.com/rizkyekoputra/rok-3514) is the **backend**: raw data, importers and `track.py`, which pushes the season data here as `data/season.json`. The old Apps Script ledger and GitHub Pages dashboard keep running until the cutover.

## Status

| Step | State |
|---|---|
| Supabase project `gwrqjzqkgvkapjzgktaf` (Singapore) | live |
| Ledger schema: officers, payments, account changes, must-migrate log, claim status | live (`supabase/migrations/`) |
| `ledger_get` / `ledger_post`: same JSON as the Apps Script `doGet` / `doPost` | live, tested |
| Daily one-way copy from the old ledger (`.github/workflows/sync-ledger.yml`) | live; fails the run if the copy differs |
| Payment claims with proof files (private Storage bucket `claims`, Edge Function `claim-files`, daily cleanup) | live |
| Dashboard: `web/template.html` + `data/season.json` (from the tracker) + Supabase ledger, on GitHub Pages (`.github/workflows/pages.yml`, on push) | live: https://rizkyekoputra.github.io/rok-3514-app/ |
| Upload → AI extract → preview → submit | not yet |

## Security model

- Tables live in schema `ledger`, which the Data API does not expose. RLS is on, no policies, no grants to `anon`/`authenticated`.
- The browser uses the **publishable** key (`supabase.json`, public by design) and can only call:
  - `rpc/ledger_get {p_key}`: public reads; the R4-only parts (`zeroList`, `claimList`) need a valid key.
  - `rpc/ledger_post {req}`: player proposals without a key; every R4 action checks `sha256(key)` against `ledger.officers`.
- R4 keys are never stored, only their SHA-256. These are the same hashes as the old ledger, so existing R4 links keep working.
- Claim proof files sit in the private bucket `claims` with no Storage policies. The `claim-files` Edge Function
  hands out signed URLs (upload: one file, no overwrite; view: 10 minutes) only after SQL has checked the claim
  token or R4 key. Claim tokens are stored as SHA-256.
- `rpc/ledger_import` is callable only with the **secret** key. That key lives in `.env` (gitignored) and in the GitHub Actions secrets `SUPABASE_URL` / `SUPABASE_SERVICE_KEY`, never in code or chat.

## Day to day

```sh
python3 scripts/import/import_ledger.py            # what the old ledger has
python3 scripts/import/import_ledger.py --write    # copy it (replaces previously imported rows)
python3 scripts/import/import_ledger.py --check    # compare new vs old answers
gh workflow run sync-ledger.yml                    # same, on GitHub
```

The import replaces only rows marked `imported`. Rows written through the new API are kept.

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

## Not copied from the old ledger

The old ledger's public answer is a summary, so these are missing:
- undo history of payments (only the current state);
- who zeroed whom (imported zero records say `imported`);
- claim proof files and amounts (only each fine's latest claim status). Imported claims are not in the R4 claim list
  and can't be decided here; decide them in the old ledger.

What the dashboard shows is identical, and `--check` verifies it.
