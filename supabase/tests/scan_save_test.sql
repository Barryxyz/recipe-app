-- F1.3 / NFR-9 acceptance test: app.add_pantry_items (all-or-nothing save of a reviewed scan)
-- and app.scan_usage (scan limits). Two users, rolled back.
--
--   ./scripts/test.sh db
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  r jsonb;
  n int;
  milk uuid;
  b_item uuid;
  custom_id bigint;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);

  ------------------------------------------------------------------ B has an item A must not touch
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  insert into app.pantry_items (display_name, source) values ('B milk', 'manual') returning id into b_item;

  ------------------------------------------------------------------ as A
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source)
  values (39, 'milk', 1000, 'ml', 'manual') returning id into milk;

  r := app.add_pantry_items(jsonb_build_array(
    jsonb_build_object('ingredient_id', 38, 'display_name', 'egg', 'quantity', 6, 'unit', 'each', 'location', 'fridge'),
    jsonb_build_object('custom_name', 'gochujang', 'display_name', 'gochujang', 'location', 'fridge'),
    jsonb_build_object('ingredient_id', 80, 'display_name', 'cumin', 'location', 'pantry', 'is_staple', true,
                       'expiry_overridden', true),
    jsonb_build_object('ingredient_id', 24, 'display_name', 'spinach', 'location', 'fridge',
                       'expiry_overridden', true, 'expires_at', '2026-12-01T07:59:59Z'),
    jsonb_build_object('update_item_id', milk, 'display_name', 'milk', 'quantity', 500, 'unit', 'ml')
  ));
  if (r->>'added')::int <> 4 or (r->>'updated')::int <> 1 then
    failures := array_append(failures, format('save result %s', r));
  end if;

  select count(*) into n from app.pantry_items where source = 'scan';
  if n <> 4 then failures := array_append(failures, format('%s scan rows, expected 4', n)); end if;
  select count(*) into n from app.pantry_items where id = milk and quantity = 500;
  if n <> 1 then failures := array_append(failures, 'update amount not applied'::text); end if;
  select count(*) into n from app.pantry_items where display_name = 'egg' and expires_at is not null and not expiry_overridden;
  if n <> 1 then failures := array_append(failures, 'egg did not get a rule-based expiry'::text); end if;
  select count(*) into n from app.pantry_items where display_name = 'cumin' and is_staple and expires_at is null;
  if n <> 1 then failures := array_append(failures, 'staple saved with a date or without the flag'::text); end if;
  select count(*) into n from app.pantry_items where display_name = 'spinach' and expires_at = '2026-12-01T07:59:59Z';
  if n <> 1 then failures := array_append(failures, 'user-set expiry not kept'::text); end if;
  select ingredient_id into custom_id from app.pantry_items where display_name = 'gochujang';
  if custom_id is null or custom_id < 1000000000000 then
    failures := array_append(failures, 'custom item not created for unmatched name'::text);
  end if;

  -- Custom items aren't duplicated by a second scan.
  perform app.add_pantry_items(jsonb_build_array(
    jsonb_build_object('custom_name', 'Gochujang', 'display_name', 'gochujang', 'location', 'fridge')));
  select count(*) into n from app.ingredients_private where lower(name) = 'gochujang';
  if n <> 1 then failures := array_append(failures, format('%s gochujang custom rows', n)); end if;

  -- All or nothing: one bad row (another household's item) rolls back the whole save.
  select count(*) into n from app.pantry_items;
  begin
    perform app.add_pantry_items(jsonb_build_array(
      jsonb_build_object('ingredient_id', 10, 'display_name', 'tomato', 'location', 'fridge'),
      jsonb_build_object('update_item_id', b_item, 'display_name', 'milk', 'quantity', 1)));
    failures := array_append(failures, 'updating another household''s item did not fail'::text);
  exception when no_data_found then null;
  end;
  if (select count(*) from app.pantry_items) <> n then
    failures := array_append(failures, 'a failed save left rows behind'::text);
  end if;
  begin
    perform app.add_pantry_items(jsonb_build_array(jsonb_build_object('display_name', '  ')));
    failures := array_append(failures, 'blank name accepted'::text);
  exception when invalid_parameter_value then null;
  end;

  ------------------------------------------------------------------ scan usage (NFR-9)
  perform set_config('role', 'postgres', true);
  insert into app.ai_usage_log (user_id, kind, model, input_tokens, output_tokens, ok) values
    (a, 'scan', 'claude-sonnet-5-5', 5000, 500, true),
    (a, 'scan', 'claude-sonnet-5-5', 5000, 500, true),
    (a, 'scan', 'claude-sonnet-5-5', 5000, 0, false),              -- failed: doesn't count
    (a, 'test', 'claude-haiku-5-5', 10, 10, true),                   -- not a scan
    (a, 'scan', 'claude-sonnet-5-5', 5000, 500, true);
  update app.ai_usage_log set created_at = now() - interval '40 days'
   where user_id = a and kind = 'scan' and output_tokens = 500
     and id = (select max(id) from app.ai_usage_log where user_id = a);  -- last month
  perform set_config('role', 'authenticated', true);

  r := app.scan_usage();
  if (r->>'today')::int <> 2 then failures := array_append(failures, format('scans today: %s', r)); end if;
  if (r->>'day_resets_at')::timestamptz <= now() or (r->>'month_resets_at')::timestamptz <= now() then
    failures := array_append(failures, 'reset times not in the future'::text);
  end if;
  begin
    perform app.scan_usage(b);
    failures := array_append(failures, 'A read B''s scan usage'::text);
  exception when insufficient_privilege then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
