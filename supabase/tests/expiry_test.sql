-- F1.6 acceptance test: expiry rules (app.default_expiry and the pantry_items trigger).
-- The case table lives in expiry_cases.json and is shared with the Swift tests; test.sh
-- substitutes it for __EXPIRY_CASES_JSON__ below. Runs in a rolled-back transaction.
--
--   ./scripts/test.sh db
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

-- 23:59:59 Los Angeles time on the given day.
create function pg_temp.app_expect(d text) returns timestamptz language sql immutable as
$$ select ((d::date + 1)::timestamp at time zone 'America/Los_Angeles') - interval '1 second' $$;

do $test$
declare
  fx jsonb := $json$__EXPIRY_CASES_JSON__$json$::jsonb;
  u uuid := gen_random_uuid();
  failures text[] := '{}';
  c jsonb;
  tz text;
  got timestamptz;
  want timestamptz;
  item uuid;
  e1 timestamptz;
  e2 timestamptz;
begin
  ------------------------------------------------------------------ fixture (as postgres)
  insert into auth.users (id, aud, role) values (u, 'authenticated', 'authenticated');  -- trigger creates prefs

  insert into catalog.ingredients (id, name, shelf_life_fridge_days, shelf_life_freezer_days, shelf_life_pantry_days)
  overriding system value
  select (x->>'id')::bigint, x->>'name', (x->>'fridge')::int, (x->>'freezer')::int, (x->>'pantry')::int
    from jsonb_array_elements(fx->'catalog') x;

  insert into app.user_shelf_life_overrides (user_id, ingredient_id, location, days, deleted_at)
  select u, (x->>'ingredient_id')::bigint, x->>'location', (x->>'days')::int,
         case when (x->>'deleted')::boolean then now() end
    from jsonb_array_elements(fx->'user_overrides') x;

  ------------------------------------------------------------------ shared case table
  for c in select * from jsonb_array_elements(fx->'cases') loop
    tz := coalesce(c->>'timezone', fx->>'default_timezone');
    update app.user_prefs set timezone = tz where user_id = u;
    got := app.default_expiry(u, (c->>'ingredient_id')::bigint, c->>'location', (c->>'added_at')::timestamptz);
    want := (((c->>'expect_local_date')::date + 1)::timestamp at time zone tz) - interval '1 second';
    if got is distinct from want then
      failures := array_append(failures, format('%s: expected %s, got %s', c->>'name',
        to_char(want at time zone tz, 'YYYY-MM-DD HH24:MI:SS'), to_char(got at time zone tz, 'YYYY-MM-DD HH24:MI:SS')));
    end if;
  end loop;

  ------------------------------------------------------------------ trigger behavior (as the user)
  update app.user_prefs set timezone = 'America/Los_Angeles' where user_id = u;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);

  -- Insert fills expires_at and ignores a client-supplied value.
  insert into app.pantry_items (display_name, ingredient_id, location, source, added_at, expires_at)
  values ('chicken', 900002, 'fridge', 'manual', '2026-03-10T15:00:00Z', '2030-01-01T00:00:00Z')
  returning id, expires_at into item, e1;
  if e1 <> pg_temp.app_expect('2026-03-12') then
    failures := array_append(failures, format('insert: expected 2026-03-12 end of day, got %s', e1));
  end if;

  -- Moving fridge -> freezer recalculates from added_at (2 -> 270 days).
  update app.pantry_items set location = 'freezer' where id = item returning expires_at into e2;
  if e2 <> pg_temp.app_expect('2026-12-05') then
    failures := array_append(failures, format('move to freezer: expected 2026-12-05, got %s', e2));
  end if;

  -- Changing the ingredient recalculates (chicken freezer 270 -> milk freezer 90).
  update app.pantry_items set ingredient_id = 900001 where id = item returning expires_at into e2;
  if e2 <> pg_temp.app_expect('2026-06-08') then
    failures := array_append(failures, format('ingredient change: expected 2026-06-08, got %s', e2));
  end if;

  -- Clearing expires_at recalculates ("Also update existing items").
  update app.pantry_items set expires_at = null where id = item returning expires_at into e2;
  if e2 is null or e2 <> pg_temp.app_expect('2026-06-08') then
    failures := array_append(failures, 'clearing expires_at did not recalculate'::text);
  end if;

  -- A date the user set is never recalculated, even when the item moves.
  update app.pantry_items set expires_at = '2026-04-01T12:00:00Z', expiry_overridden = true where id = item;
  update app.pantry_items set location = 'fridge' where id = item returning expires_at into e2;
  if e2 <> '2026-04-01T12:00:00Z'::timestamptz then
    failures := array_append(failures, format('overridden date changed on move: %s', e2));
  end if;

  -- Overridden with no date means "no expiry" and stays null.
  update app.pantry_items set expires_at = null where id = item returning expires_at into e2;
  if e2 is not null then
    failures := array_append(failures, 'overridden null date was filled in'::text);
  end if;

  -- An unrelated edit (quantity) doesn't touch a computed date.
  insert into app.pantry_items (display_name, ingredient_id, location, source, added_at)
  values ('milk', 900001, 'fridge', 'manual', '2026-03-10T15:00:00Z') returning id, expires_at into item, e1;
  update app.pantry_items set quantity = 2 where id = item returning expires_at into e2;
  if e1 is distinct from e2 then
    failures := array_append(failures, 'quantity edit changed expires_at'::text);
  end if;

  -- Clients can't call the security-definer helpers directly.
  begin
    perform app.shelf_life_days(u, 900001, 'fridge');
    failures := array_append(failures, 'client can call app.shelf_life_days'::text);
  exception when insufficient_privilege then null;
  end;

  -- Invalid timezones are rejected.
  begin
    update app.user_prefs set timezone = 'Mars/Olympus_Mons' where user_id = u;
    failures := array_append(failures, 'invalid timezone accepted'::text);
  exception when invalid_parameter_value then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$test$;

select current_setting('fridge.test_result') as result;

rollback;
