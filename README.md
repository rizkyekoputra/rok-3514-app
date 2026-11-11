# rok-3514-app

New home of the Kingdom 3514 dashboard and ledger: Supabase Postgres in place of the "3514 Fines" Google Sheet + Apps Script, and later an app with AI-assisted imports (upload screenshots and recordings, then preview and submit).

The old system ([rok-3514](https://github.com/rizkyekoputra/rok-3514), Apps Script, Sheet, GitHub Pages dashboard) **keeps running unchanged** until the switchover. This repo only reads from it.

## Status

| Step | State |
|---|---|
| Supabase project `gwrqjzqkgvkapjzgktaf` (Singapore) | live |
| Ledger schema: officers, payments, account changes, must-migrate log, claim status | live (`supabase/migrations/`) |
| `ledger_get` / `ledger_post`: same JSON as the Apps Script `doGet` / `doPost` | live, tested |
| Hourly one-way copy from the old ledger (`.github/workflows/sync-ledger.yml`) | live; fails the run if the copy differs |
| Payment claims with proof files (Storage) | not yet |
| Dashboard data as `data.json` + frontend reading Supabase | not yet |
| Upload → AI extract → preview → submit | not yet |

## Security model

- Tables live in schema `ledger`, which the Data API does not expose. RLS is on, no policies, no grants to `anon`/`authenticated`.
- The browser uses the **publishable** key (`supabase.json`, public by design) and can only call:
  - `rpc/ledger_get {p_key}`: public reads; the R4-only parts (`zeroList`, `claimList`) need a valid key.
  - `rpc/ledger_post {req}`: player proposals without a key; every R4 action checks `sha256(key)` against `ledger.officers`.
- R4 keys are never stored, only their SHA-256. These are the same hashes as the old ledger, so existing R4 links keep working.
- `rpc/ledger_import` is callable only with the **secret** key. That key lives in `.env` (gitignored) and in the GitHub Actions secrets `SUPABASE_URL` / `SUPABASE_SERVICE_KEY`, never in code or chat.

## Day to day

```sh
python3 scripts/import/import_ledger.py            # what the old ledger has
python3 scripts/import/import_ledger.py --write    # copy it (replaces previously imported rows)
python3 scripts/import/import_ledger.py --check    # compare new vs old answers
gh workflow run sync-ledger.yml                    # same, on GitHub
```

The import replaces only rows marked `imported`. Rows written through the new API are kept.

### Database changes

```sh
supabase migration new <name>          # write SQL in supabase/migrations/
supabase start && supabase db reset    # test locally (Docker)
supabase db push --remote --dry-run    # see what would change
supabase db push --remote              # apply
```

## Not copied from the old ledger

The old ledger's public answer is a summary, so these are missing:
- undo history of payments (only the current state);
- who zeroed whom (imported zero records say `imported`);
- claim proof files and amounts (only each fine's latest claim status).

What the dashboard shows is identical, and `--check` verifies it.
