-- F3.6 acceptance test (database side): server_now works for users, "changed since" pulls see
-- edits and soft deletes, and the nightly purge removes only rows deleted over 30 days ago.
--
--   ./scripts/test.sh db

begin;

do $$
declare
  a uuid := gen_random_uuid();
  failures text[] := '{}';
  t0 timestamptz;
  item uuid := gen_random_uuid();
  old_row uuid := gen_random_uuid();
  recent_row uuid := gen_random_uuid();
  n int;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated');

  -- As postgres: the purge removes rows deleted over 30 days ago only, and runs nightly.
  insert into app.shopping_list_items (id, household_id, name, deleted_at)
       values (old_row, (select household_id from app.users where id = a), 'old', now() - interval '31 days');
  insert into app.pantry_items (id, household_id, ingredient_id, display_name, source, deleted_at)
       values (recent_row, (select household_id from app.users where id = a), 38, 'eggs', 'manual', now() - interval '1 day');
  perform app.purge_soft_deleted();
  if exists (select 1 from app.shopping_list_items where id = old_row) then
    failures := array_append(failures, 'old soft-deleted row not purged'::text);
  end if;
  if not exists (select 1 from app.pantry_items where id = recent_row) then
    failures := array_append(failures, 'recently deleted row purged too early'::text);
  end if;
  if not exists (select 1 from cron.job where jobname = 'purge-soft-deleted') then
    failures := array_append(failures, 'nightly purge job not scheduled'::text);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  t0 := app.server_now();
  if t0 is null then failures := array_append(failures, 'server_now returned null'::text); end if;

  -- A client-generated id, upserted twice (as the outbox does): one row, last write wins.
  insert into app.pantry_items (id, ingredient_id, display_name, quantity, unit, source)
       values (item, 38, 'eggs', 6, 'each', 'manual')
  on conflict (id) do update set quantity = excluded.quantity;
  insert into app.pantry_items (id, ingredient_id, display_name, quantity, unit, source)
       values (item, 38, 'eggs', 4, 'each', 'manual')
  on conflict (id) do update set quantity = excluded.quantity;
  select count(*) into n from app.pantry_items where id = item and quantity = 4;
  if n <> 1 then failures := array_append(failures, 'idempotent upsert by id failed'::text); end if;

  -- Soft delete is visible to a "changed since" pull (updated_at moves with it).
  update app.pantry_items set deleted_at = now() where id = item;
  select count(*) into n from app.pantry_items where updated_at >= t0 and id = item and deleted_at is not null;
  if n <> 1 then failures := array_append(failures, 'soft delete not seen by a changed-since pull'::text); end if;

  begin
    perform app.purge_soft_deleted();
    failures := array_append(failures, 'a user can run the purge'::text);
  exception when insufficient_privilege then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
