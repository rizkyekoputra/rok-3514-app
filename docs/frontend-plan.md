# Frontend plan

Goal: the new dashboard reads `data.json` (static, rebuilt by the tracker) + the Supabase RPCs (live ledger), and later
lets players upload proof, have AI extract the details, preview and submit.

## Today (old system, read-only for us)

`track.py write_dashboard()` builds one `DATA` object (~690 KB) and inlines it into `dashboard_template.html` →
`dashboard/index.html` → GitHub Pages (`rok-3514-dashboard`). `DATA` mixes two kinds of things:

| Kind | Keys | New home |
|---|---|---|
| Season data (changes when the tracker runs) | `weeks minF minT players fines scanDay namesDay mainAlly kvks mges mgeHist ghs ghFine canyons aoos power immig rosters aooMin mgeFine fineKinds bank claimsOn updated` | `data.json` |
| Ledger snapshot + endpoint | `ledger {paid, accounts, migrate}`, `officers`, `finesUrl` | dropped: live from `ledger_get` |

The template also POSTs to the Apps Script (`DATA.finesUrl`) for payments, proposals, migrate, claims.

## Phase 1: `data.json` without touching the old system

1. `scripts/data/extract_data.py`: read the published old dashboard (public GitHub Pages `index.html`, or
   `~/rok-3514/tracker/dashboard/index.html` locally), pull out `DATA`, drop the ledger keys, write `public/data.json`.
   Check it's byte-for-byte stable across runs (sorted keys only where the order doesn't matter).
2. Run it in the hourly sync workflow (or its own workflow) and commit `data.json` only when it changed.
   Player names only, no Governor IDs (`track.py` already keeps IDs local).
3. At switchover, `track.py` writes `data.json` itself and the extractor goes away. That is a change in the old repo,
   so it waits for the switchover.

## Phase 2: new frontend = the old template, ported

The template is 160 KB of working UI, so port it rather than rewrite it:

- Static site in this repo (`web/`), built with Vite (plain TS, no framework), deployed to GitHub Pages from this
  repo. No supabase-js: two `fetch` calls with the publishable key from `supabase.json`.
- `const DATA = /*__DATA__*/null` → `await fetch('data.json')`; `DATA.ledger` / `DATA.officers` →
  `rpc/ledger_get {p_key}` (one call, merged in the same shapes the template already reads).
- Every `fetch(DATA.finesUrl, …)` → `rpc/ledger_post {req}`; the request bodies are unchanged.
- Claim upload: `ledger_post claim` → for each file `claim-files claim_file` + `PUT` to the signed URL (with
  progress, one retry) → `ledger_post claim_done`. R4 view: `claim-files claim_view` → open the signed URL
  (instead of decoding base64).
- After an approval: today the Apps Script starts the `recalc` Action in the old repo. Until the switchover the new
  frontend just re-reads `ledger_get`; the TODO in `ledger_post` stays open.
- Verify: same `data.json` + same ledger answer must render the same as the old page (screenshot diff of the main
  views, both themes, phone width).

## Phase 3: upload → AI extraction → preview → submit

- Upload goes to the existing claim flow (files in the private `claims` bucket), so there is no second upload path.
- Edge Function `extract`: given `{claim_id, token}` (player) or `{key, ...}` (R4), signs the stored images, sends them
  to the configured provider and returns structured fields, e.g. `{sent: [{resource, amount}], to_kd, time,
  confidence}`. Images first; for recordings, the browser grabs a few frames and uploads them as images.
- Provider + model in a `ledger.settings` row; the provider API key in **Supabase Vault**
  (`vault.create_secret`), read only by a service-role RPC that the function calls. Never in code, `.env` or the
  frontend. Changing provider = new Vault secret + settings row, no redeploy.
- Limits: once per claim (stored result), the same burst limits as claims, a daily cap on calls.
- Preview: the player sees the extracted fields in the claim form, can correct them, then `claim_done`. R4s see
  "AI read: …" next to the player's numbers, so a mismatch stands out. AI never approves anything.

## Open questions

1. Hosting: GitHub Pages from this repo (simplest), or keep the `rok-3514-dashboard` URL and switch its content at
   cutover (players' bookmarks keep working)?
2. Should AI extraction also cover R4 work (e.g. ranking screenshots → weekly data), or only payment proof?
3. Cutover: pending claims in the old ledger have their files in Drive. Decide them there before switching.
