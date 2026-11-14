-- Approvals on the new dashboard start the recalculation, like the Apps Script's triggerRecalc():
-- an approved proposal (approve) and an approver's own farm/main change start the rok-3514 "recalc.yml" Action,
-- which copies the old ledger in, runs track.py --pull and pushes the season data to this repo.
--
-- The GitHub token (fine-grained: rizkyekoputra/rok-3514 only, Actions read/write) lives in Supabase Vault as
-- 'github_recalc_token'; it is never in code, migrations or .env. Without it the answer says the hourly run picks
-- the change up, as before. pg_net queues the request in this transaction and sends it after commit, so a rolled
-- back write never starts a run.

create extension if not exists pg_net with schema extensions;

create or replace function ledger.start_recalc() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  tok text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'github_recalc_token' limit 1;
  if coalesce(tok, '') = '' then
    return 'recorded; the dashboard updates on its next hourly run';
  end if;
  perform net.http_post(
    url := 'https://api.github.com/repos/rizkyekoputra/rok-3514/actions/workflows/recalc.yml/dispatches',
    body := jsonb_build_object('ref', 'main'),
    headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'rok-3514-ledger',
                                  'Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
  return 'started, the dashboard updates in about 3 minutes';
exception when others then
  return 'recorded; could not start the recalculation, the hourly run will pick it up';
end $$;

revoke all on function ledger.start_recalc() from public, anon, authenticated;

-- ---------- ledger_post: as in 20261111120000_claims.sql, with ledger.start_recalc() for the two recalc answers ----------

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
    return jsonb_build_object('ok', true, 'by', o.name,
                              'recalc', case when act = 'approve' then ledger.start_recalc() else '' end);
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
                              'recalc', ledger.start_recalc());
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

-- ledger_post keeps its grants (create or replace preserves them)
