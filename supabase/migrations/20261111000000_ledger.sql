-- 3514 ledger: the Postgres version of the "3514 Fines" Google Sheet + Apps Script (rok-3514/tracker/fines_ledger/Code.js).
--
-- Security model (same as the Apps Script web app):
--   * Tables live in schema `ledger`, which the Data API does not expose: nobody reads or writes them directly.
--   * The browser (publishable / anon key) can only call two functions:
--       public.ledger_get(key)  -> same JSON as the Apps Script doGet (reads are public, R4-only parts need a key)
--       public.ledger_post(req) -> same requests and answers as doPost; every R4 action checks the key's SHA-256
--   * R4 keys are never stored, only their SHA-256 (same hashes the dashboard already publishes in ledger.json),
--     so existing R4 links keep working.
--   * public.ledger_import(data) is for the one-way copy from the old ledger and only the service role may call it.
--
-- Not here yet: payment claims with proof files (needs Storage), the GitHub recalculation trigger.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists ledger;
revoke all on schema ledger from public, anon, authenticated;

-- ---------- tables ----------

create table ledger.officers (
  name      text primary key,
  key_hash  text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  status    text not null default 'active' check (status in ('active', 'revoked')),
  approver  boolean not null default false,
  created   timestamptz not null default now(),
  imported  boolean not null default false
);

-- append-only; the latest row per fine_id wins, action 'undo' clears it
create table ledger.payments (
  id        bigint generated always as identity primary key,
  time      timestamptz not null default now(),
  fine_id   text not null check (fine_id ~ '^[0-9a-f]{10}$'),
  player    text,
  week      text,
  amount    numeric not null check (amount >= 0 and amount <= 1e12),
  by_name   text not null,
  action    text not null check (action in ('paid', 'undo')),
  imported  boolean not null default false
);
create index on ledger.payments (fine_id, time);

-- farm/main changes; a proposal row is decided in place (status proposed -> approved | rejected)
create table ledger.account_changes (
  id         bigint generated always as identity primary key,
  time       timestamptz not null default now(),
  account_id text not null check (account_id ~ '^[0-9a-f]{10}$'),
  player     text,
  type       text not null check (type in ('farm', 'main')),
  by_name    text not null,
  status     text not null check (status in ('proposed', 'approved', 'rejected')),
  decided    timestamptz,
  decided_by text,
  note       text,
  imported   boolean not null default false
);
create index on ledger.account_changes (account_id, time);
create index on ledger.account_changes (status) where status = 'proposed';

-- append-only must-migrate log
create table ledger.migrate_events (
  id         bigint generated always as identity primary key,
  time       timestamptz not null default now(),
  account_id text not null check (account_id ~ '^[0-9a-f]{10}$'),
  player     text,
  action     text not null check (action in ('must', 'revoke', 'out', 'back', 'zero', 'zero_undo')),
  by_name    text not null,
  note       text,
  ref        text,
  imported   boolean not null default false
);
create index on ledger.migrate_events (account_id, time);

-- payment claims: only the public status for now (proof files come with Storage later)
create table ledger.claims (
  claim_id   text primary key,
  time       timestamptz not null default now(),
  fine_id    text not null check (fine_id ~ '^[0-9a-f]{10}$'),
  player     text,
  week       text,
  status     text not null check (status in ('uploading', 'pending', 'approved', 'rejected', 'abandoned')),
  decided    timestamptz,
  decided_by text,
  reason     text,
  imported   boolean not null default false
);
create index on ledger.claims (fine_id, time);

-- Defence in depth: RLS on with no policies, and no grants to the API roles.
alter table ledger.officers        enable row level security;
alter table ledger.payments        enable row level security;
alter table ledger.account_changes enable row level security;
alter table ledger.migrate_events  enable row level security;
alter table ledger.claims          enable row level security;
revoke all on all tables in schema ledger from public, anon, authenticated;

-- ---------- helpers (not callable from the API) ----------

create function ledger.iso(t timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;

create function ledger.clip(s text, n int) returns text
language sql immutable set search_path = '' as $$
  select left(btrim(coalesce(s, '')), n)
$$;

-- the active officer for a dashboard key, or no row
create function ledger.officer(p_key text) returns table (name text, approver boolean)
language sql stable set search_path = '' as $$
  select o.name, o.approver from ledger.officers o
  where p_key is not null and p_key <> '' and o.status = 'active'
    and o.key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex')
$$;

-- account_id -> {type, by, decided, approvedBy, pending: {type, by, time, pub, note}}
create function ledger.account_state() returns jsonb
language sql stable set search_path = '' as $$
  with appr as (
    select distinct on (account_id) account_id, type, by_name, decided, decided_by
    from ledger.account_changes where status = 'approved' order by account_id, time desc, id desc
  ), last as (
    select distinct on (account_id) account_id, type, by_name, time, status, note
    from ledger.account_changes order by account_id, time desc, id desc
  )
  select coalesce(jsonb_object_agg(l.account_id,
    jsonb_strip_nulls(jsonb_build_object(
      'type', a.type, 'by', a.by_name, 'decided', ledger.iso(a.decided), 'approvedBy', a.decided_by,
      'pending', case when l.status = 'proposed' then jsonb_strip_nulls(jsonb_build_object(
        'type', l.type, 'by', l.by_name, 'time', ledger.iso(l.time), 'pub', l.by_name like 'player: %',
        'note', nullif(l.note, ''))) end))), '{}'::jsonb)
  from last l left join appr a using (account_id)
  where a.account_id is not null or l.status = 'proposed'
$$;

-- zero records still standing (zero minus zero_undo), oldest first
create function ledger.zeros() returns table (ref text, account_id text, player text, by_name text, at timestamptz, note text)
language sql stable set search_path = '' as $$
  select z.ref, z.account_id, z.player, z.by_name, z.time, nullif(z.note, '')
  from ledger.migrate_events z
  where z.action = 'zero'
    and not exists (select 1 from ledger.migrate_events u
                    where u.action = 'zero_undo' and u.ref = z.ref and u.account_id = z.account_id and u.id > z.id)
  order by z.time, z.id
$$;

-- account_id -> {m, mb, mt, out: {by, time}, z, zt}
create function ledger.migrate_state() returns jsonb
language sql stable set search_path = '' as $$
  with mark as (
    select distinct on (account_id) account_id, action, by_name, time from ledger.migrate_events
    where action in ('must', 'revoke') order by account_id, time desc, id desc
  ), outs as (
    select distinct on (account_id) account_id, action, by_name, time from ledger.migrate_events
    where action in ('out', 'back') order by account_id, time desc, id desc
  ), z as (
    select account_id, count(*) as n, max(at) as last from ledger.zeros() group by account_id
  ), ids as (
    select account_id from mark union select account_id from outs where action = 'out' union select account_id from z
  )
  select coalesce(jsonb_object_agg(i.account_id, jsonb_strip_nulls(jsonb_build_object(
    'm', m.action, 'mb', m.by_name, 'mt', ledger.iso(m.time),
    'out', case when o.action = 'out' then jsonb_build_object('by', o.by_name, 'time', ledger.iso(o.time)) end,
    'z', z.n, 'zt', ledger.iso(z.last)))), '{}'::jsonb)
  from ids i left join mark m using (account_id) left join outs o using (account_id) left join z using (account_id)
$$;

-- ---------- API: reads ----------

-- Same JSON as the Apps Script doGet: {paid, accounts, officer, approver, officers, claims, claimList, migrate, zeroList}
create function public.ledger_get(p_key text default null) returns jsonb
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
      'claimList', '[]'::jsonb,
      'zeroList', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                     'ref', ref, 'account_id', account_id, 'player', player, 'by', by_name, 'time', ledger.iso(at), 'note', note))), '[]'::jsonb)
                   from ledger.zeros()));
  end if;
  return res;
end $$;

-- ---------- API: writes ----------

-- Same requests as the Apps Script doPost (see Code.js). Always answers {ok: true, ...} or {ok: false, error}.
create function public.ledger_post(req jsonb) returns jsonb
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

  if act in ('claim', 'claim_file', 'claim_done', 'claim_view', 'claim_approve', 'claim_reject') then
    return jsonb_build_object('ok', false, 'error', 'payment claims are not available on the new ledger yet');
  end if;

  -- everything else needs an R4 key
  select * into o from ledger.officer(req->>'key');
  if o.name is null then
    return jsonb_build_object('ok', false, 'error', 'invalid key');
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

-- ---------- one-way import from the old ledger (service role only) ----------

-- data = {officers: [...], payments: [...], account_changes: [...], migrate_events: [...], claims: [...]},
-- rows shaped like the tables (time as ISO text). Replaces every previously imported row; rows written through
-- the new API (imported = false) are kept.
create function public.ledger_import(data jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(3514);
  delete from ledger.officers where imported;
  delete from ledger.payments where imported;
  delete from ledger.account_changes where imported;
  delete from ledger.migrate_events where imported;
  delete from ledger.claims where imported;

  insert into ledger.officers (name, key_hash, status, approver, imported)
  select r->>'name', r->>'key_hash', 'active', coalesce((r->>'approver')::boolean, false), true
  from jsonb_array_elements(coalesce(data->'officers', '[]')) r
  on conflict (name) do nothing;  -- an officer created on the new ledger wins

  insert into ledger.payments (time, fine_id, player, week, amount, by_name, action, imported)
  select (r->>'time')::timestamptz, r->>'fine_id', r->>'player', r->>'week', (r->>'amount')::numeric, r->>'by_name', r->>'action', true
  from jsonb_array_elements(coalesce(data->'payments', '[]')) r;

  insert into ledger.account_changes (time, account_id, player, type, by_name, status, decided, decided_by, note, imported)
  select (r->>'time')::timestamptz, r->>'account_id', r->>'player', r->>'type', r->>'by_name', r->>'status',
         (r->>'decided')::timestamptz, r->>'decided_by', r->>'note', true
  from jsonb_array_elements(coalesce(data->'account_changes', '[]')) r;

  insert into ledger.migrate_events (time, account_id, player, action, by_name, note, ref, imported)
  select (r->>'time')::timestamptz, r->>'account_id', r->>'player', r->>'action', r->>'by_name', r->>'note', r->>'ref', true
  from jsonb_array_elements(coalesce(data->'migrate_events', '[]')) r;

  insert into ledger.claims (claim_id, time, fine_id, player, week, status, decided, decided_by, reason, imported)
  select r->>'claim_id', (r->>'time')::timestamptz, r->>'fine_id', r->>'player', r->>'week', r->>'status',
         (r->>'decided')::timestamptz, r->>'decided_by', r->>'reason', true
  from jsonb_array_elements(coalesce(data->'claims', '[]')) r
  on conflict (claim_id) do nothing;

  return jsonb_build_object('ok', true,
    'officers', (select count(*) from ledger.officers), 'payments', (select count(*) from ledger.payments),
    'account_changes', (select count(*) from ledger.account_changes), 'migrate_events', (select count(*) from ledger.migrate_events),
    'claims', (select count(*) from ledger.claims));
end $$;

-- ---------- grants ----------

revoke all on all functions in schema ledger from public, anon, authenticated;
revoke all on function public.ledger_get(text), public.ledger_post(jsonb), public.ledger_import(jsonb) from public, anon, authenticated;
grant execute on function public.ledger_get(text) to anon, authenticated;
grant execute on function public.ledger_post(jsonb) to anon, authenticated;
grant execute on function public.ledger_import(jsonb) to service_role;
grant usage on schema ledger to service_role;
