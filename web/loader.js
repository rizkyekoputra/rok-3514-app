// Loader for the new dashboard (inlined into site/index.html by scripts/web/build.py).
// Loads data.json + the live ledger, then runs the old page's script unchanged except for a few patches. That script
// talks to the Apps Script with fetch(DATA.finesUrl, ...); here DATA.finesUrl is a marker and those calls go to the
// Supabase RPCs (ledger_get / ledger_post) and the claim-files function instead, with the same JSON.
// Only the publishable key is used here (public by design); every write is checked in the database.
(() => {
  const SB = __SUPABASE__, MARK = 'supabase:ledger';
  const headers = {apikey: SB.key, 'Content-Type': 'application/json'};
  const realFetch = window.fetch.bind(window);
  const call = async (path, body) => {
    const r = await realFetch(SB.url + path, {method: 'POST', headers, body: JSON.stringify(body)});
    const j = await r.json().catch(() => null);
    if (!r.ok || !j) throw new Error((j && (j.message || j.error)) || 'HTTP ' + r.status);
    return j;
  };
  const rpc = (fn, body) => call('/rest/v1/rpc/' + fn, body);
  const claimFiles = body => call('/functions/v1/claim-files', body);

  async function ledger(url, opts) {
    if (!opts || !opts.method || opts.method === 'GET') {
      const key = new URL(url.replace(MARK, 'https://x/'), location.href).searchParams.get('key');
      return rpc('ledger_get', {p_key: key || null});
    }
    const req = JSON.parse(opts.body);
    if (req.action === 'claim_view') {
      const j = await claimFiles(req);
      return j.ok ? {...j, url: SB.url + j.url} : j;
    }
    return rpc('ledger_post', {req});
  }
  window.fetch = (url, opts) => typeof url === 'string' && url.startsWith(MARK)
    ? ledger(url, opts).then(j => new Response(JSON.stringify(j), {headers: {'Content-Type': 'application/json'}}))
    : realFetch(url, opts);

  window.LEDGER = {
    // one proof file: reserve a slot, then PUT the file to its signed upload URL (one retry)
    async uploadClaimFile(claim_id, token, file, type) {
      for (let attempt = 1; ; attempt++) {
        const s = await claimFiles({action: 'claim_file', claim_id, token, name: file.name, type, size: file.size});
        if (!s.ok) throw new Error(s.error || 'not saved');
        const r = await realFetch(SB.url + s.upload, {method: 'PUT', headers: {apikey: SB.key, 'Content-Type': type}, body: file});
        if (r.ok) return s;
        if (attempt === 2) throw new Error('upload failed (' + r.status + ')');
      }
    },
  };

  const start = (data, live) => {
    data.finesUrl = MARK;
    if (live) {
      data.ledger = {paid: live.paid || {}, accounts: live.accounts || {}, migrate: live.migrate || {}};
      data.officers = live.officers || [];
    }
    window.__DATA = data;
    const s = document.createElement('script');
    s.textContent = document.getElementById('app').textContent;
    document.body.appendChild(s);
  };
  Promise.all([
    realFetch('data.json', {cache: 'no-cache'}).then(r => { if (!r.ok) throw new Error('data.json: HTTP ' + r.status); return r.json(); }),
    rpc('ledger_get', {p_key: null}).catch(() => null),  // the page refreshes it again anyway
  ]).then(([data, live]) => start(data, live)).catch(err => {
    document.body.classList.remove('gating');
    document.body.insertAdjacentHTML('afterbegin',
      '<p style="padding:16px;font:16px system-ui">Could not load the dashboard data. Reload the page in a minute. (' +
      String(err.message).replace(/[<&]/g, '') + ')</p>');
  });
})();
