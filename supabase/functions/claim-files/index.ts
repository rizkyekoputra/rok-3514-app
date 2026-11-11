// claim-files: proof-file transfers for payment claims (see supabase/migrations/*_claims.sql for the whole flow).
//
//   {action: "claim_file", claim_id, token, name, type, size} -> {ok, file_id, count, upload}
//       player: reserves one file slot, then PUTs the file to `${SUPABASE_URL}${upload}` with its Content-Type
//   {key, action: "claim_view", claim_id, file_id}            -> {ok, type, name, url}
//       R4: `${SUPABASE_URL}${url}` serves the file for 10 minutes
//
// All checks (token, R4 key, limits) happen in SQL (ledger_claim_file / ledger_claim_view, service role only).
// This function only adds what SQL can't do: signing Storage URLs. Errors are {ok: false, error}, like ledger_post.
// The service key comes from the Edge runtime's environment and is never sent back.

const API = Deno.env.get('SUPABASE_URL')!;
// TODO: Securely load this value from an environment variable or secrets vault. Do not hardcode.
const KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const BUCKET = 'claims';
const VIEW_SECONDS = 600;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const answer = (body: unknown) =>
  new Response(JSON.stringify(body), { headers: { ...CORS, 'Content-Type': 'application/json' } });

async function post(path: string, body: unknown): Promise<any> {
  const headers: Record<string, string> = { apikey: KEY, 'Content-Type': 'application/json' };
  if (KEY.split('.').length === 3) headers.Authorization = `Bearer ${KEY}`; // legacy JWT keys; sb_secret_ keys: apikey only
  const r = await fetch(`${API}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`${path.split('?')[0]}: HTTP ${r.status}`);
  return r.json();
}

const objectPath = (p: string) => p.split('/').map(encodeURIComponent).join('/');

async function claimFile(req: any) {
  const slot = await post('/rest/v1/rpc/ledger_claim_file', { req });
  if (!slot.ok) return slot;
  // one upload, no overwrite; the signed URL is valid for 2 hours
  const signed = await post(`/storage/v1/object/upload/sign/${BUCKET}/${objectPath(slot.path)}`, {});
  return { ok: true, file_id: slot.file_id, count: slot.count, upload: `/storage/v1${signed.url}` };
}

async function claimView(req: any) {
  const f = await post('/rest/v1/rpc/ledger_claim_view', { req });
  if (!f.ok) return f;
  const signed = await post(`/storage/v1/object/sign/${BUCKET}/${objectPath(f.path)}`, { expiresIn: VIEW_SECONDS });
  return { ok: true, type: f.type, name: f.name, url: `/storage/v1${signed.signedURL}` };
}

Deno.serve(async (r) => {
  if (r.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (r.method !== 'POST') return answer({ ok: false, error: 'bad request' });
  let req: any;
  try {
    req = await r.json();
  } catch {
    return answer({ ok: false, error: 'bad request' });
  }
  if (!req || typeof req !== 'object' || Array.isArray(req)) return answer({ ok: false, error: 'bad request' });
  try {
    if (req.action === 'claim_file') return answer(await claimFile(req));
    if (req.action === 'claim_view') return answer(await claimView(req));
    return answer({ ok: false, error: 'bad request' });
  } catch (err) {
    console.error(err instanceof Error ? err.message : err);
    return answer({ ok: false, error: 'server error, try again' });
  }
});
