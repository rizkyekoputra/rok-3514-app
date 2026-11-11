-- Payment claims with proof files: the Supabase version of the claim flow in rok-3514/tracker/fines_ledger/Code.js.
--
--   player  ledger_post {action: "claim", fine_id, player, week, fine, sent, gold_value, note, files: [{type, size}]}
--             -> {ok, claim_id, token}            (token is shown once; only its SHA-256 is stored)
--   player  claim-files fn {action: "claim_file", claim_id, token, name, type, size}
--             -> {ok, file_id, count, upload}     (upload: signed upload URL path for exactly this file)
--   player  ledger_post {action: "claim_done", claim_id, token}   -> {ok}   (checks what actually arrived in Storage)
--   R4      ledger_get(key).claimList                              (pending + decided in the last 30 days)
--   R4      claim-files fn {key, action: "claim_view", claim_id, file_id} -> {ok, type, name, url} (signed, 10 min)
--   R4      ledger_post {key, action: "claim_approve", claim_id, amount} | {key, action: "claim_reject", claim_id, reason}
--             approving appends a payment row, so it counts like a payment an R4 marked
--   daily   scripts/claims/cleanup_claims.py: files deleted 30 days after the decision; uploads never finished are
--           abandoned (and their files deleted) after a day
--
-- Proof files live in the private bucket `claims` at {claim_id}/{n}_{name}. There are no Storage policies: only the
-- service role (the claim-files Edge Function and the cleanup script) reaches the bucket.
--
-- Differences from Code.js: files go straight to Storage via signed URLs instead of base64 inside JSON, so
-- claim_file / claim_view are served by the claim-files Edge Function (same request fields, plus `size`; the answers
-- carry a URL instead of `data`). Claim tokens are stored hashed.

-- ---------- limits (Code.js CLAIM) ----------

create function ledger.claim_type_ok(t text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(t ~ '^(image/(jpeg|png|webp|gif|heic|heif)|video/(mp4|quicktime|webm|3gpp))$', false)
$$;
-- maxFiles 20, maxBytes 30MB, perFine 5, open 100, burst 20 per 10 minutes, keepDays 30, abandon after 1 day:
-- written inline below, search for "claim limit".

create function ledger.num(t text) returns numeric
language plpgsql immutable set search_path = '' as $$
begin
  return t::numeric;
exception when others then
  return null;
end $$;

-- ---------- storage ----------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('claims', 'claims', false, 31457280,  -- claim limit: 30MB (per file here; per claim in SQL)
        array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic', 'image/heif',
              'video/mp4', 'video/quicktime', 'video/webm', 'video/3gpp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

-- ---------- tables ----------

alter table ledger.claims
  add column fine         text,
  add column sent         text,
  add column gold_value   numeric,
  add column note         text,
  add column expect_n     int,
  add column expect_bytes bigint,
  add column token_hash   text check (token_hash ~ '^[0-9a-f]{64}$'),
  add column cleaned      timestamptz;
create index on ledger.claims (status) where status in ('uploading', 'pending');

-- one row per reserved upload slot; a slot whose file never arrived is dropped at claim_done
create table ledger.claim_files (
  file_id  text primary key check (file_id ~ '^[0-9a-f]{16}$'),
  claim_id text not null references ledger.claims (claim_id) on delete cascade,
  seq      int not null,
  path     text not null unique,
  name     text not null,
  type     text not null,
  size     bigint not null check (size > 0),
  created  timestamptz not null default now(),
  unique (claim_id, seq)
);
alter table ledger.claim_files enable row level security;
revoke all on ledger.claim_files from public, anon, authenticated;

-- [{id, n, t, s}] of a claim's files, as Code.js lists them
create function ledger.claim_file_list(p_claim text) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', file_id, 'n', name, 't', type, 's', size) order by seq), '[]'::jsonb)
  from ledger.claim_files where claim_id = p_claim
$$;

-- ---------- API: reads (claimList added) ----------

create or replace function public.ledger_get(p_key text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  o record;
  res jsonb;
begin
  select * into o from ledger.officer(p_key);
  res := jsonb_build_object(
    'paid', (select coalesce(jsonb_object_agg(fine_id, jsonb_build_object('amount', amount, 'by', by_name, 'time', ledger.iso(time))), '{}'::jsonb)
             from (select distinct on (fine_id) * from ledger.payments order by fine_id, time desc, id desc) p
             where action = 'paid'),
    'accounts', ledger.account_state(),
    'officer', o.name,
    'approver', coalesce(o.approver, false),
    'officers', (select coalesce(jsonb_agg(jsonb_build_object('h', key_hash, 'n', name, 'a', approver) order by created, name), '[]'::jsonb)
                 from ledger.officers where status = 'active'),
    'claims', (select coalesce(jsonb_object_agg(fine_id, jsonb_strip_nulls(jsonb_build_object(
                 's', status, 't', ledger.iso(time), 'why', case when status = 'rejected' then reason end))), '{}'::jsonb)
               from (select distinct on (fine_id) * from ledger.claims where status in ('pending', 'approved', 'rejected')
                     order by fine_id, time desc) c),
    'migrate', ledger.migrate_state());
  if o.name is not null then
    res := res || jsonb_build_object(
      -- same fields as Code.js officerClaims(); empty cells are '' there, so they are '' here too.
      -- Imported claims are left out: their proof files are in the old ledger's Drive.
      'claimList', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', c.claim_id, 'fine_id', c.fine_id, 'player', coalesce(c.player, ''), 'week', coalesce(c.week, ''),
                      'fine', coalesce(c.fine, ''), 'sent', coalesce(c.sent, ''), 'gold', coalesce(c.gold_value, 0),
                      'note', coalesce(c.note, ''), 'files', ledger.claim_file_list(c.claim_id), 'status', c.status,
                      'time', ledger.iso(c.time), 'decided', coalesce(ledger.iso(c.decided), ''), 'by', coalesce(c.decided_by, ''),
                      'reason', coalesce(c.reason, ''), 'cleaned', c.cleaned is not null) order by c.time), '[]'::jsonb)
                    from ledger.claims c
                    where not c.imported
                      and (c.status = 'pending'
                           or (c.status in ('approved', 'rejected') and c.decided > now() - interval '30 days'))),  -- claim limit: keepDays
      'zeroList', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                     'ref', ref, 'account_id', account_id, 'player', player, 'by', by_name, 'time', ledger.iso(at), 'note', note))), '[]'::jsonb)
                   from ledger.zeros()));
  end if;
  return res;
end $$;

-- ---------- claims (called from ledger_post; never directly from the API) ----------

-- player: open a claim and announce its files; answers the claim id and a one-time upload token
create function ledger.claim_new(req jsonb) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare
  files jsonb := case when jsonb_typeof(req->'files') = 'array' then req->'files' else '[]'::jsonb end;
  gold  numeric := ledger.num(req->>'gold_value');
  n     int := jsonb_array_length(files);
  bytes numeric;
  v_id  text;
  token text;
begin
  if coalesce(req->>'fine_id', '') !~ '^[0-9a-f]{10}$' or coalesce(req->>'week', '') !~ '^\d{4}-\d{2}-\d{2}$'
     or gold is null or gold < 0 or gold > 1e13 then
    return jsonb_build_object('ok', false, 'error', 'bad request');
  end if;
  if n = 0 or n > 20 then  -- claim limit: maxFiles
    return jsonb_build_object('ok', false, 'error', 'attach 1 to 20 files');
  end if;
  if exists (select 1 from jsonb_array_elements(files) f
             where jsonb_typeof(f) <> 'object' or not ledger.claim_type_ok(f->>'type')
                or coalesce(ledger.num(f->>'size'), 0) <= 0) then
    return jsonb_build_object('ok', false, 'error', 'only screenshots (JPG, PNG, WebP, HEIC) and recordings (MP4, MOV, WebM)');
  end if;
  select sum(ledger.num(f->>'size')) into bytes from jsonb_array_elements(files) f;
  if bytes > 31457280 then  -- claim limit: maxBytes
    return jsonb_build_object('ok', false, 'error', 'files are over 30MB in total');
  end if;
  if (select count(*) from ledger.claims where not imported and time > now() - interval '10 minutes') >= 20 then  -- claim limit: burst
    return jsonb_build_object('ok', false, 'error', 'many claims just now, try again in a few minutes');
  end if;
  if exists (select 1 from ledger.claims where fine_id = req->>'fine_id' and status = 'pending') then
    return jsonb_build_object('ok', false, 'error', 'proof for this fine is already waiting for an R4');
  end if;
  if (select count(*) from ledger.claims where fine_id = req->>'fine_id' and status <> 'abandoned') >= 5 then  -- claim limit: perFine
    return jsonb_build_object('ok', false, 'error', 'too many claims for this fine, please contact an R4');
  end if;
  if (select count(*) from ledger.claims where status in ('pending', 'uploading')) >= 100 then  -- claim limit: open
    return jsonb_build_object('ok', false, 'error', 'too many claims are waiting, try again later');
  end if;
  v_id := encode(extensions.gen_random_bytes(6), 'hex');
  token := encode(extensions.gen_random_bytes(16), 'hex');
  insert into ledger.claims (claim_id, fine_id, player, week, fine, sent, gold_value, note, expect_n, expect_bytes, status, token_hash)
  values (v_id, req->>'fine_id', ledger.clip(req->>'player', 80), req->>'week', ledger.clip(req->>'fine', 80),
          ledger.clip(req->>'sent', 80), gold, ledger.clip(req->>'note', 300), n, bytes, 'uploading',
          encode(extensions.digest(token, 'sha256'), 'hex'));
  return jsonb_build_object('ok', true, 'claim_id', v_id, 'token', token);
end $$;

-- the claim a player's token opens, if it is still uploading
create function ledger.claim_open(p_id text, p_token text) returns ledger.claims
language sql stable set search_path = '' as $$
  select * from ledger.claims
  where claim_id = p_id and status = 'uploading' and not imported
    and coalesce(p_token, '') <> '' and token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
$$;

-- player: all files are in. Only files that really arrived in Storage, with the announced size and type, count.
create function ledger.claim_done(req jsonb) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare
  c ledger.claims;
  bad int;
  total bigint;
begin
  c := ledger.claim_open(req->>'claim_id', req->>'token');
  if c.claim_id is null then
    return jsonb_build_object('ok', false, 'error', 'claim not open');
  end if;
  delete from ledger.claim_files f where f.claim_id = c.claim_id
    and not exists (select 1 from storage.objects o where o.bucket_id = 'claims' and o.name = f.path);
  select count(*) filter (where (o.metadata->>'size')::bigint is distinct from f.size or o.metadata->>'mimetype' is distinct from f.type),
         coalesce(sum((o.metadata->>'size')::bigint), 0)
    into bad, total
  from ledger.claim_files f join storage.objects o on o.bucket_id = 'claims' and o.name = f.path
  where f.claim_id = c.claim_id;
  if bad > 0 or total > least(c.expect_bytes, 31457280) then  -- claim limit: maxBytes
    return jsonb_build_object('ok', false, 'error', 'file over the limit');
  end if;
  if total = 0 then
    return jsonb_build_object('ok', false, 'error', 'no files arrived');
  end if;
  update ledger.claims set status = 'pending', token_hash = null where claim_id = c.claim_id;
  return jsonb_build_object('ok', true);
end $$;

-- R4: approve (appends a payment) or reject (needs a reason) a pending claim
create function ledger.claim_decide(req jsonb, by text) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare
  c ledger.claims;
  amt numeric;
  why text;
begin
  select * into c from ledger.claims where claim_id = req->>'claim_id' and not imported for update;
  if c.claim_id is null or c.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'claim is not waiting for a decision');
  end if;
  if req->>'action' = 'claim_reject' then
    why := ledger.clip(req->>'reason', 200);
    if why = '' then
      return jsonb_build_object('ok', false, 'error', 'give a reason');
    end if;
    update ledger.claims set status = 'rejected', decided = now(), decided_by = by, reason = why where claim_id = c.claim_id;
    return jsonb_build_object('ok', true, 'by', by);
  end if;
  amt := ledger.num(req->>'amount');
  if amt is null or not (amt > 0 and amt <= 1e12) then
    return jsonb_build_object('ok', false, 'error', 'bad amount');
  end if;
  -- the latest payment row per fine is its total paid, so the dashboard sends previous payments + this claim
  insert into ledger.payments (fine_id, player, week, amount, by_name, action)
  values (c.fine_id, c.player, c.week, amt, by, 'paid');
  update ledger.claims set status = 'approved', decided = now(), decided_by = by where claim_id = c.claim_id;
  return jsonb_build_object('ok', true, 'by', by);
end $$;

-- ---------- API: writes (claims wired in; everything else unchanged) ----------

create or replace function public.ledger_post(req jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  act  text := req->>'action';
  o    record;
  aid  text := req->>'account_id';
  n    int;
  v_ref text;
  amt  numeric;
  list jsonb;
  pend jsonb;
begin
  -- one writer at a time (the Apps Script used a script lock)
  perform pg_advisory_xact_lock(3514);

  -- players, no key: propose farm/main for one account
  if act = 'propose' then
    if aid !~ '^[0-9a-f]{10}$' or (req->>'type') not in ('farm', 'main') then
      return jsonb_build_object('ok', false, 'error', 'bad request');
    end if;
    if (select count(*) from ledger.account_changes where by_name like 'player: %' and time > now() - interval '10 minutes') >= 20 then
      return jsonb_build_object('ok', false, 'error', 'many proposals just now, try again in a few minutes');
    end if;
    if exists (select 1 from ledger.account_changes where account_id = aid and status = 'proposed') then
      return jsonb_build_object('ok', false, 'error', 'a change for this account is already waiting for an R4');
    end if;
    if (select count(*) from ledger.account_changes where status = 'proposed' and by_name like 'player: %') >= 100 then
      return jsonb_build_object('ok', false, 'error', 'too many proposals are waiting, try again later');
    end if;
    insert into ledger.account_changes (account_id, player, type, by_name, status, note)
    values (aid, ledger.clip(req->>'player', 80), req->>'type',
            'player: ' || coalesce(nullif(ledger.clip(req->>'name', 40), ''), 'anonymous'), 'proposed',
            nullif(ledger.clip(req->>'note', 200), ''));
    return jsonb_build_object('ok', true);
  end if;

  -- players, no key: payment claims (the files themselves go through the claim-files Edge Function)
  if act = 'claim' then
    return ledger.claim_new(req);
  end if;
  if act = 'claim_done' then
    return ledger.claim_done(req);
  end if;
  if act in ('claim_file', 'claim_view') then
    return jsonb_build_object('ok', false, 'error', 'send this to the claim-files function');
  end if;

  -- everything else needs an R4 key
  select * into o from ledger.officer(req->>'key');
  if o.name is null then
    return jsonb_build_object('ok', false, 'error', 'invalid key');
  end if;

  if act in ('claim_approve', 'claim_reject') then
    return ledger.claim_decide(req, o.name);
  end if;

  if act = 'migrate' then
    if aid !~ '^[0-9a-f]{10}$' or (req->>'op') not in ('must', 'revoke', 'out', 'back', 'zero', 'zero_undo') then
      return jsonb_build_object('ok', false, 'error', 'bad request');
    end if;
    v_ref := '';
    if req->>'op' = 'zero' then
      v_ref := left(encode(extensions.gen_random_bytes(8), 'hex'), 10);
    elsif req->>'op' = 'zero_undo' then
      v_ref := coalesce(req->>'ref', '');
      if not exists (select 1 from ledger.zeros() z where z.ref = v_ref and z.account_id = aid) then
        return jsonb_build_object('ok', false, 'error', 'that zero record is already gone');
      end if;
    end if;
    insert into ledger.migrate_events (account_id, player, action, by_name, note, ref)
    values (aid, ledger.clip(req->>'player', 80), req->>'op', o.name, nullif(ledger.clip(req->>'note', 200), ''), nullif(v_ref, ''));
    return jsonb_build_object('ok', true, 'by', o.name, 'ref', v_ref);
  end if;

  if act in ('approve', 'reject') then
    if aid !~ '^[0-9a-f]{10}$' then
      return jsonb_build_object('ok', false, 'error', 'bad request');
    end if;
    pend := ledger.account_state()->aid->'pending';
    if not o.approver and not coalesce((pend->>'pub')::boolean, false) then  -- player proposals: any R4
      return jsonb_build_object('ok', false, 'error', 'not an approver');
    end if;
    update ledger.account_changes set status = case act when 'approve' then 'approved' else 'rejected' end,
           decided = now(), decided_by = o.name
    where account_id = aid and status = 'proposed';
    get diagnostics n = row_count;
    if n = 0 then
      return jsonb_build_object('ok', false, 'error', 'nothing to decide');
    end if;
    -- TODO: start the recalculation (GitHub Action) once the new dashboard reads from here
    return jsonb_build_object('ok', true, 'by', o.name,
                              'recalc', case when act = 'approve' then 'recorded; the dashboard updates on its next run' else '' end);
  end if;

  if act in ('farm', 'main') then
    list := case when jsonb_typeof(req->'accounts') = 'array' then req->'accounts'
                 else jsonb_build_array(jsonb_build_object('account_id', aid, 'player', req->>'player')) end;
    if jsonb_array_length(list) = 0 or jsonb_array_length(list) > 500
       or exists (select 1 from jsonb_array_elements(list) a where jsonb_typeof(a) <> 'object' or coalesce(a->>'account_id', '') !~ '^[0-9a-f]{10}$') then
      return jsonb_build_object('ok', false, 'error', 'bad request');
    end if;
    if o.approver then  -- approvers' changes supersede open proposals
      update ledger.account_changes set status = 'rejected', decided = now(), decided_by = o.name
      where status = 'proposed' and account_id in (select a->>'account_id' from jsonb_array_elements(list) a);
    end if;
    insert into ledger.account_changes (account_id, player, type, by_name, status, decided, decided_by)
    select a->>'account_id', ledger.clip(a->>'player', 80), act, o.name,
           case when o.approver then 'approved' else 'proposed' end,
           case when o.approver then now() end, case when o.approver then o.name end
    from jsonb_array_elements(list) a;
    get diagnostics n = row_count;
    if not o.approver then
      return jsonb_build_object('ok', true, 'by', o.name, 'count', n);
    end if;
    return jsonb_build_object('ok', true, 'by', o.name, 'count', n, 'approved', true,
                              'recalc', 'recorded; the dashboard updates on its next run');
  end if;

  -- fine payment: {key, fine_id, player, week, amount, action: paid | undo}
  begin
    amt := (req->>'amount')::numeric;
  exception when others then
    amt := null;
  end;
  if coalesce(req->>'fine_id', '') !~ '^[0-9a-f]{10}$' or coalesce(req->>'week', '') !~ '^\d{4}-\d{2}-\d{2}$'
     or amt is null or amt < 0 or amt > 1e12 then
    return jsonb_build_object('ok', false, 'error', 'bad request');
  end if;
  insert into ledger.payments (fine_id, player, week, amount, by_name, action)
  values (req->>'fine_id', ledger.clip(req->>'player', 80), req->>'week',
          case when act = 'undo' then 0 else amt end, o.name, case when act = 'undo' then 'undo' else 'paid' end);
  return jsonb_build_object('ok', true, 'by', o.name);
end $$;

-- ---------- service role only: the claim-files Edge Function ----------

-- reserve one upload slot: {claim_id, token, name, type, size} -> {ok, file_id, path, count}
create function public.ledger_claim_file(req jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  c ledger.claims;
  sz numeric := ledger.num(req->>'size');
  used bigint;
  cnt int;
  fid text;
  fname text;
  f record;
begin
  perform pg_advisory_xact_lock(3514);
  c := ledger.claim_open(req->>'claim_id', req->>'token');
  if c.claim_id is null or c.time < now() - interval '20 hours' then  -- leave signed URLs time to expire before cleanup
    return jsonb_build_object('ok', false, 'error', 'claim not open for upload');
  end if;
  if not ledger.claim_type_ok(req->>'type') then
    return jsonb_build_object('ok', false, 'error', 'file type not allowed');
  end if;
  if sz is null or sz <= 0 or sz <> trunc(sz) then
    return jsonb_build_object('ok', false, 'error', 'bad file');
  end if;
  -- a retry of the same file whose upload never arrived gets its slot (and a fresh signed URL) again
  select cf.file_id, cf.path, cf.seq into f
  from ledger.claim_files cf
  where cf.claim_id = c.claim_id and cf.name = left(coalesce(nullif(req->>'name', ''), 'proof'), 80)
    and cf.type = req->>'type' and cf.size = sz
    and not exists (select 1 from storage.objects o where o.bucket_id = 'claims' and o.name = cf.path)
  order by cf.seq limit 1;
  if f.file_id is not null then
    return jsonb_build_object('ok', true, 'file_id', f.file_id, 'path', f.path, 'count', f.seq);
  end if;
  select count(*), coalesce(sum(size), 0) into cnt, used from ledger.claim_files where claim_id = c.claim_id;
  if cnt >= c.expect_n or used + sz > least(c.expect_bytes, 31457280) then  -- claim limit: maxBytes
    return jsonb_build_object('ok', false, 'error', 'file over the limit');
  end if;
  fid := encode(extensions.gen_random_bytes(8), 'hex');
  fname := right(regexp_replace(coalesce(nullif(req->>'name', ''), 'proof'), '[^A-Za-z0-9._-]+', '_', 'g'), 60);
  insert into ledger.claim_files (file_id, claim_id, seq, path, name, type, size)
  values (fid, c.claim_id, cnt + 1, c.claim_id || '/' || (cnt + 1) || '_' || fname,
          left(coalesce(nullif(req->>'name', ''), 'proof'), 80), req->>'type', sz::bigint);
  return jsonb_build_object('ok', true, 'file_id', fid, 'path', c.claim_id || '/' || (cnt + 1) || '_' || fname, 'count', cnt + 1);
end $$;

-- R4: which object to sign for viewing: {key, claim_id, file_id} -> {ok, path, type, name}
create function public.ledger_claim_view(req jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  f record;
begin
  if not exists (select 1 from ledger.officer(req->>'key')) then
    return jsonb_build_object('ok', false, 'error', 'invalid key');
  end if;
  select cf.path, cf.type, cf.name into f
  from ledger.claim_files cf join ledger.claims c using (claim_id)
  where cf.claim_id = req->>'claim_id' and cf.file_id = req->>'file_id' and c.cleaned is null and c.status <> 'uploading';
  if f.path is null then
    return jsonb_build_object('ok', false, 'error', 'file not found (deleted after 30 days?)');
  end if;
  return jsonb_build_object('ok', true, 'path', f.path, 'type', f.type, 'name', f.name);
end $$;

-- ---------- service role only: daily cleanup (scripts/claims/cleanup_claims.py) ----------

-- claims whose files should go: decided over 30 days ago, uploads never finished after a day, and any files left
-- behind by already-cleaned claims. -> [{claim_id, paths: [...]}]
create function public.ledger_claims_due() returns jsonb
language sql stable security definer set search_path = '' as $$
  with due as (
    select claim_id from ledger.claims
    where not imported and cleaned is null
      and ((status in ('approved', 'rejected') and decided < now() - interval '30 days')  -- claim limit: keepDays
           or (status = 'uploading' and time < now() - interval '1 day'))                 -- claim limit: abandon
    union
    select c.claim_id from ledger.claims c
    where c.cleaned is not null
      and exists (select 1 from storage.objects o where o.bucket_id = 'claims' and o.name like c.claim_id || '/%')
  )
  select coalesce(jsonb_agg(jsonb_build_object('claim_id', d.claim_id, 'paths',
           (select coalesce(jsonb_agg(o.name order by o.name), '[]'::jsonb) from storage.objects o
            where o.bucket_id = 'claims' and o.name like d.claim_id || '/%'))), '[]'::jsonb)
  from due d
$$;

-- mark claims cleaned once none of their files are left (unfinished uploads become abandoned)
create function public.ledger_claims_cleaned(ids text[]) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  n int;
begin
  perform pg_advisory_xact_lock(3514);
  update ledger.claims c
     set status = case when c.status = 'uploading' then 'abandoned' else c.status end,
         token_hash = null, cleaned = coalesce(c.cleaned, now())
  where c.claim_id = any(ids) and not c.imported
    and (c.cleaned is not null  -- leftover files swept again
         or (c.status in ('approved', 'rejected') and c.decided < now() - interval '30 days')
         or (c.status = 'uploading' and c.time < now() - interval '1 day'))
    and not exists (select 1 from storage.objects o where o.bucket_id = 'claims' and o.name like c.claim_id || '/%');
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'cleaned', n);
end $$;

-- ---------- grants ----------

revoke all on all functions in schema ledger from public, anon, authenticated;
revoke all on function public.ledger_claim_file(jsonb), public.ledger_claim_view(jsonb),
                       public.ledger_claims_due(), public.ledger_claims_cleaned(text[]) from public, anon, authenticated;
grant execute on function public.ledger_claim_file(jsonb), public.ledger_claim_view(jsonb),
                          public.ledger_claims_due(), public.ledger_claims_cleaned(text[]) to service_role;
-- ledger_get / ledger_post keep their grants (create or replace preserves them)
