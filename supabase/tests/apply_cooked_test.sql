-- F3.4 acceptance test: app.apply_cooked reduces amounts, marks items used at <= 0 or on
-- "Used it up", skips items that aren't active or aren't the household's, and
-- app.undo_cooked restores the exact previous amounts and statuses.
--
--   ./scripts/test.sh db

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  eggs uuid; rice uuid; oil uuid; milk uuid; gone uuid;
  snap jsonb;
  r record;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source)
       values (38, 'eggs', 6, 'each', 'manual') returning id into eggs;
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source)
       values (67, 'rice', 0.5, 'kg', 'manual') returning id into rice;
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source)
       values (85, 'olive oil', null, 'ml', 'manual') returning id into oil;
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source)
       values (39, 'milk', 1, 'l', 'manual') returning id into milk;
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source, status)
       values (11, 'onion', 2, 'each', 'manual', 'used') returning id into gone;

  snap := app.apply_cooked(jsonb_build_array(
    jsonb_build_object('id', eggs, 'quantity', 4),
    jsonb_build_object('id', rice, 'quantity', 0.3),
    jsonb_build_object('id', oil, 'used', true),
    jsonb_build_object('id', milk, 'quantity', 0),
    jsonb_build_object('id', gone, 'quantity', 1)));

  if (select quantity from app.pantry_items where id = eggs) <> 4 then
    failures := array_append(failures, '6 eggs - 2 should leave 4'::text);
  end if;
  if (select quantity from app.pantry_items where id = rice) <> 0.3 then
    failures := array_append(failures, 'rice should be 0.3 kg'::text);
  end if;
  select * into r from app.pantry_items where id = oil;
  if r.status <> 'used' or r.quantity is not null or r.status_changed_at is null then
    failures := array_append(failures, format('"used it up" wrong: %s %s', r.status, r.quantity));
  end if;
  select * into r from app.pantry_items where id = milk;
  if r.status <> 'used' or r.quantity <> 0 then
    failures := array_append(failures, format('amount 0 should mark used: %s %s', r.status, r.quantity));
  end if;
  if (select status from app.pantry_items where id = gone) <> 'used' or (select quantity from app.pantry_items where id = gone) <> 2 then
    failures := array_append(failures, 'an item already used was changed'::text);
  end if;
  if jsonb_array_length(snap) <> 4 then
    failures := array_append(failures, format('snapshot has %s rows, expected 4', jsonb_array_length(snap)));
  end if;

  -- B (another household) can't change A's items: skipped, nothing returned.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  if jsonb_array_length(app.apply_cooked(jsonb_build_array(jsonb_build_object('id', eggs, 'quantity', 0)))) <> 0 then
    failures := array_append(failures, 'B changed A''s item'::text);
  end if;
  perform app.undo_cooked(jsonb_build_array(jsonb_build_object('id', eggs, 'quantity', 99, 'status', 'active')));
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  if (select quantity from app.pantry_items where id = eggs) <> 4 then
    failures := array_append(failures, 'B''s undo changed A''s item'::text);
  end if;

  -- Undo puts everything back exactly.
  perform app.undo_cooked(snap);
  for r in select id, quantity, status, status_changed_at from app.pantry_items where id in (eggs, rice, oil, milk) loop
    if r.status <> 'active' or r.status_changed_at is not null
       or r.quantity is distinct from (case r.id when eggs then 6 when rice then 0.5 when oil then null when milk then 1 end) then
      failures := array_append(failures, format('undo wrong for %s: %s %s', r.id, r.status, r.quantity));
    end if;
  end loop;

  begin
    perform app.undo_cooked(jsonb_build_array(jsonb_build_object('id', eggs, 'quantity', 1, 'status', 'eaten')));
    failures := array_append(failures, 'accepted a bad status'::text);
  exception when invalid_parameter_value then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
