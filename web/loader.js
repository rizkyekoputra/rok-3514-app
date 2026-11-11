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

  // ---------- CSV export: a "Download CSV" button above every data table ----------
  // Deterministic: the rows and columns the table shows right now (search/filters applied), in the same order, as
  // displayed text; buttons/inputs dropped; RFC 4180 quoting, CRLF, UTF-8 BOM (Excel shows the names right).
  // The file name comes from the card title + the data date, so the same view always gives the same file.
  const clean = el => {
    const c = el.cloneNode(true);
    c.querySelectorAll('button, input, select, textarea, svg, script, style, [hidden]').forEach(x => x.remove());
    return c.textContent.replace(/\s+/g, ' ').trim();
  };
  const cellCsv = v => {
    if (/^[=+@\t\r]/.test(v) || (/^-/.test(v) && !/^-[\d.,]+$/.test(v))) v = "'" + v;  // no formulas in Excel
    return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
  };
  const expand = tr => [...tr.cells].flatMap(td => [td, ...Array(Math.max(0, (td.colSpan || 1) - 1)).fill(null)]);
  function tableCsv(table) {
    const rows = [...table.tBodies].flatMap(b => [...b.rows]).filter(tr => !tr.hidden);
    let head = table.tHead && table.tHead.rows.length ? table.tHead.rows[table.tHead.rows.length - 1] : null;
    if (!head && rows.length && [...rows[0].cells].every(c => c.tagName === 'TH')) head = rows.shift();
    // drop message rows ("No players match…"): one cell spanning several columns
    const grid = rows.map(expand).filter(r => !(r[0] && r[0].colSpan > 1 && r.filter(Boolean).length === 1));
    // hidden header cells belong to R4-only columns whose cells are not rendered at all, so rows line up with the
    // visible headers only
    const hcells = head ? expand(head).filter(c => !(c && c.hidden)) : [];
    const width = Math.max(hcells.length, ...grid.map(r => r.length), 0);
    const text = (c) => (c ? clean(c) : '');
    // drop columns with no header and no text in any row (action buttons)
    const keep = [...Array(width).keys()].filter(i => text(hcells[i]) || grid.some(r => text(r[i])));
    const lines = [];
    if (head) lines.push(keep.map(i => cellCsv(text(hcells[i]))).join(','));
    grid.forEach(r => lines.push(keep.map(i => cellCsv(text(r[i]))).join(',')));
    return '﻿' + lines.join('\r\n') + '\r\n';
  }
  const slug = s => s.toLowerCase().normalize('NFKD').replace(/[^\w]+/g, '-').replace(/^-|-$/g, '').slice(0, 50) || 'table';
  function download(table) {
    const card = table.closest('.card'), h = card && card.querySelector('h2');
    const name = `3514-${slug(h ? clean(h) : 'table')}-${(window.__DATA && window.__DATA.updated) || 'data'}.csv`;
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([tableCsv(table)], {type: 'text/csv;charset=utf-8'}));
    a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }
  function addCsvButtons() {
    document.querySelectorAll('.table-wrap > table').forEach(table => {
      const wrap = table.parentElement;
      if (wrap.dataset.csv) return;
      wrap.dataset.csv = '1';
      const bar = document.createElement('div');
      bar.className = 'csv-bar';
      bar.innerHTML = '<button class="act ghost" type="button">Download CSV</button>';
      bar.firstChild.addEventListener('click', () => download(table));
      wrap.before(bar);
    });
  }
  const css = document.createElement('style');
  css.textContent = '.csv-bar{display:flex;justify-content:flex-end;margin-top:8px}';
  document.head.appendChild(css);
  window.LEDGER.tableCsv = tableCsv;  // for tests

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
    addCsvButtons();
    let queued = false;  // tables re-rendered or added later (dialogs, tabs) get their button too
    new MutationObserver(() => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => { queued = false; addCsvButtons(); });
    }).observe(document.body, {childList: true, subtree: true});
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
