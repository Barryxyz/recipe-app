-- F1.8 acceptance test: History & waste (status_changed_at and app.pantry_insights).
-- Runs as two signed-in users in a rolled-back transaction. To place items in past months,
-- the status_changed_at trigger is disabled inside the transaction (undone by the rollback).
--
--   ./scripts/test.sh db
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

alter table app.pantry_items disable trigger set_status_changed_at;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  ha uuid;
  hb uuid;
  failures text[] := '{}';
  r jsonb;
  item uuid;
  e1 timestamptz;
  e2 timestamptz;
  n int;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  select household_id into ha from app.users where id = a;
  select household_id into hb from app.users where id = b;

  -- A, October 2026 (Los Angeles): 6 used, 2 thrown out; one more thrown out in September.
  insert into app.pantry_items (household_id, added_by, ingredient_id, display_name, location, source, status, status_changed_at, added_at)
  select ha, a, 38, 'egg', 'fridge', 'manual', 'used', ('2026-10-0' || g || 'T18:00:00Z')::timestamptz, '2026-09-20T18:00:00Z'
    from generate_series(1, 6) g;
  insert into app.pantry_items (household_id, added_by, ingredient_id, display_name, location, source, status, status_changed_at, added_at) values
    (ha, a, 24, 'spinach', 'fridge', 'manual', 'discarded', '2026-10-10T18:00:00Z', '2026-10-01T18:00:00Z'),
    (ha, a, 24, 'spinach', 'fridge', 'manual', 'discarded', '2026-10-20T18:00:00Z', '2026-10-12T18:00:00Z'),
    (ha, a, 39, 'milk',    'fridge', 'manual', 'discarded', '2026-09-15T18:00:00Z', '2026-09-01T18:00:00Z'),
    -- 06:30 UTC on Nov 1 is 23:30 on Oct 31 in Los Angeles (still UTC-7: DST ends later that night):
    -- counts for October there, November in UTC.
    (ha, a, 39, 'milk',    'fridge', 'manual', 'used',      '2026-11-01T06:30:00Z', '2026-10-25T18:00:00Z'),
    -- Soft-deleted rows (Delete = mistake) never count.
    (ha, a, 24, 'spinach', 'fridge', 'manual', 'discarded', '2026-10-21T18:00:00Z', '2026-10-12T18:00:00Z');
  update app.pantry_items set deleted_at = now()
   where household_id = ha and status_changed_at = '2026-10-21T18:00:00Z';

  -- B's items must never show up for A.
  insert into app.pantry_items (household_id, added_by, ingredient_id, display_name, location, source, status, status_changed_at, added_at)
  select hb, b, 54, 'ground beef', 'fridge', 'manual', 'discarded', '2026-10-05T18:00:00Z', now() - interval '1 day'
    from generate_series(1, 9);

  ------------------------------------------------------------------ as A
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  r := app.pantry_insights('2026-10-01', 'America/Los_Angeles');
  if (r->>'used')::int <> 7 or (r->>'thrown_out')::int <> 2 then
    failures := array_append(failures, format('October LA counts: %s', r));
  end if;
  if (r->>'waste_rate')::numeric <> 0.222 then
    failures := array_append(failures, format('waste rate 2/9 expected 0.222: %s', r->>'waste_rate'));
  end if;

  r := app.pantry_insights('2026-10-01', 'UTC');
  if (r->>'used')::int <> 6 then
    failures := array_append(failures, format('October UTC should exclude the Nov 1 06:30Z item: %s', r->>'used'));
  end if;

  -- Fewer than 5 items: no waste rate.
  r := app.pantry_insights('2026-09-01', 'America/Los_Angeles');
  if (r->>'thrown_out')::int <> 1 or r->'waste_rate' <> 'null'::jsonb then
    failures := array_append(failures, format('September: %s', r));
  end if;

  -- An unknown timezone falls back to UTC instead of failing.
  r := app.pantry_insights('2026-10-01', 'Mars/Olympus_Mons');
  if (r->>'used')::int <> 6 then failures := array_append(failures, 'unknown timezone not treated as UTC'::text); end if;

  -- Last-90-days lists: batches grouped, B's beef never included.
  update app.pantry_items set status_changed_at = now() - interval '2 days' where household_id = ha and display_name = 'spinach' and deleted_at is null;
  update app.pantry_items set added_at = now() - interval '3 days' where household_id = ha and display_name = 'egg';
  r := app.pantry_insights(date_trunc('month', now())::date, 'UTC');
  if r->'thrown_most'->0->>'name' <> 'spinach' or (r->'thrown_most'->0->>'count')::int <> 2 then
    failures := array_append(failures, format('thrown_most: %s', r->'thrown_most'));
  end if;
  if r->'bought_most'->0->>'name' <> 'egg' or (r->'bought_most'->0->>'count')::int <> 6 then
    failures := array_append(failures, format('bought_most: %s', r->'bought_most'));
  end if;
  if r::text like '%ground beef%' then failures := array_append(failures, 'A sees B''s items in insights'::text); end if;

  -- History list for A: only A's finished, non-deleted rows.
  select count(*) into n from app.pantry_items where status <> 'active' and deleted_at is null;
  if n <> 10 then failures := array_append(failures, format('A history rows: %s, expected 10', n)); end if;

  ------------------------------------------------------------------ put back
  -- Re-enable the trigger (as the owner) for the put-back check.
  perform set_config('role', 'postgres', true);
  execute 'alter table app.pantry_items enable trigger set_status_changed_at';
  perform set_config('role', 'authenticated', true);

  insert into app.pantry_items (display_name, ingredient_id, location, source, added_at)
  values ('yogurt', 48, 'fridge', 'manual', '2026-10-01T18:00:00Z') returning id, expires_at into item, e1;
  update app.pantry_items set status = 'discarded' where id = item;
  update app.pantry_items set status = 'active' where id = item returning expires_at into e2;
  if e2 is distinct from e1 then
    failures := array_append(failures, format('put back changed the expiry: %s -> %s', e1, e2));
  end if;
  select count(*) into n from app.pantry_items where id = item and status_changed_at is null;
  if n <> 1 then failures := array_append(failures, 'put back did not clear status_changed_at'::text); end if;

  -- anon can't call the insights function.
  perform set_config('role', 'anon', true);
  begin
    perform app.pantry_insights('2026-10-01', 'UTC');
    failures := array_append(failures, 'anon can read insights'::text);
  exception when insufficient_privilege then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
