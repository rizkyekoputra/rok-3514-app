-- R4 key management after the cutover (replaces the Sheet's "Create keys for missing R4s", "New key for selected
-- R4", Officers status/approver columns). Service role only: scripts/admin/officers.py with the secret key.
-- The key itself never reaches the database: the script generates it locally and sends sha256(key).
--
--   {action: 'list'}                                  -> {ok, officers: [{name, status, approver, created, imported}]}
--   {action: 'add', name, key_hash, approver}         new R4 (error if the name exists)
--   {action: 'rotate', name, key_hash}                new key for an R4 (reactivates a revoked one); old link stops
--   {action: 'revoke', name}                          link stops working; the row stays for history
--   {action: 'approver', name, approver: true|false}  approver = may approve proposals / their farm/main applies at once
--
-- Touched rows get imported = false, so a later ledger_import (old-ledger copy) can't overwrite them.

create or replace function public.ledger_officer_admin(req jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  act  text := req->>'action';
  nm   text := btrim(coalesce(req->>'name', ''));
  kh   text := lower(coalesce(req->>'key_hash', ''));
  n    int;
begin
  perform pg_advisory_xact_lock(3514);
  if act = 'list' then
    return jsonb_build_object('ok', true, 'officers', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'status', status, 'approver', approver,
                                          'created', created, 'imported', imported) order by status, name)
      from ledger.officers), '[]'::jsonb));
  end if;
  if nm = '' or length(nm) > 80 then
    return jsonb_build_object('ok', false, 'error', 'bad name');
  end if;
  if act in ('add', 'rotate') and kh !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'error', 'bad key_hash');
  end if;
  if act = 'add' then
    if exists (select 1 from ledger.officers where name = nm) then
      return jsonb_build_object('ok', false, 'error', 'name exists (use rotate)');
    end if;
    insert into ledger.officers (name, key_hash, status, approver, imported)
    values (nm, kh, 'active', coalesce((req->>'approver')::boolean, false), false);
    return jsonb_build_object('ok', true, 'name', nm);
  elsif act = 'rotate' then
    update ledger.officers set key_hash = kh, status = 'active', imported = false where name = nm;
  elsif act = 'revoke' then
    update ledger.officers set status = 'revoked', imported = false where name = nm;
  elsif act = 'approver' then
    if jsonb_typeof(req->'approver') is distinct from 'boolean' then
      return jsonb_build_object('ok', false, 'error', 'approver must be true or false');
    end if;
    update ledger.officers set approver = (req->>'approver')::boolean, imported = false where name = nm;
  else
    return jsonb_build_object('ok', false, 'error', 'unknown action');
  end if;
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('ok', false, 'error', 'no such officer');
  end if;
  return jsonb_build_object('ok', true, 'name', nm);
end $$;

revoke all on function public.ledger_officer_admin(jsonb) from public, anon, authenticated;
grant execute on function public.ledger_officer_admin(jsonb) to service_role;
