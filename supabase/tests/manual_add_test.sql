-- F1.5 acceptance test: custom items are created once and found again, combined search,
-- manual pantry rows. Runs as two signed-in users in a rolled-back transaction.
--
--   ./scripts/test.sh db
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  id1 bigint;
  id2 bigint;
  id3 bigint;
  n int;
  top record;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);

  ------------------------------------------------------------------ as A
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  id1 := app.get_or_create_custom_ingredient('Grandma''s Chili');
  id2 := app.get_or_create_custom_ingredient('  grandma''s chili ');   -- same name, other case/spaces
  if id1 is null or id1 <> id2 then
    failures := array_append(failures, format('custom item duplicated: %s vs %s', id1, id2));
  end if;
  select count(*) into n from app.ingredients_private where user_id = a;
  if n <> 1 then failures := array_append(failures, format('%s custom rows, expected 1', n)); end if;
  if id1 < 1000000000000 then failures := array_append(failures, 'custom id below 1e12'::text); end if;

  -- Found again, first, as an exact match.
  select * into top from app.search_ingredients('grandma''s chili') limit 1;
  if top.id is distinct from id1 or not top.is_custom or top.score <> 1 then
    failures := array_append(failures, format('exact custom match not first: %s', top));
  end if;
  -- Found by prefix and by typo too.
  select count(*) into n from app.search_ingredients('grandma') where id = id1;
  if n <> 1 then failures := array_append(failures, 'custom item not found by prefix'::text); end if;
  select count(*) into n from app.search_ingredients('grandmas chilli') where id = id1;
  if n <> 1 then failures := array_append(failures, 'custom item not found with a typo'::text); end if;

  -- Catalog results still come back, with categories and units.
  select * into top from app.search_ingredients('scallion') limit 1;
  if top.name is distinct from 'green onion' or top.is_custom or top.default_unit is null then
    failures := array_append(failures, format('catalog search through app.search_ingredients: %s', top));
  end if;
  -- A custom item named like a catalog item: the exact custom match wins.
  id3 := app.get_or_create_custom_ingredient('egg');
  select * into top from app.search_ingredients('egg') limit 1;
  if top.id is distinct from id3 then
    failures := array_append(failures, 'exact custom "egg" should come before catalog "egg"'::text);
  end if;

  -- Manual pantry rows with a custom ingredient get the fallback expiry and "some".
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, location, source)
  values (id1, 'Grandma''s Chili', null, 'each', 'fridge', 'manual');
  select count(*) into n from app.pantry_items
   where ingredient_id = id1 and quantity is null and source = 'manual' and expires_at is not null;
  if n <> 1 then failures := array_append(failures, 'manual custom pantry row not saved as expected'::text); end if;

  -- status_changed_at (F1.8): set on Used/Discard, cleared on Undo, untouched by other edits,
  -- and not settable by the client.
  declare
    item uuid;
    t1 timestamptz;
    t2 timestamptz;
  begin
    insert into app.pantry_items (display_name, source, status_changed_at)
    values ('history test', 'manual', '2000-01-01') returning id, status_changed_at into item, t1;
    if t1 is not null then failures := array_append(failures, 'client set status_changed_at on insert'::text); end if;
    update app.pantry_items set status = 'used' where id = item returning status_changed_at into t1;
    if t1 is null then failures := array_append(failures, 'status_changed_at not set on Used'::text); end if;
    update app.pantry_items set quantity = 3, status_changed_at = '2000-01-01' where id = item returning status_changed_at into t2;
    if t2 is distinct from t1 then failures := array_append(failures, 'status_changed_at changed by an unrelated edit'::text); end if;
    update app.pantry_items set status = 'active' where id = item returning status_changed_at into t2;
    if t2 is not null then failures := array_append(failures, 'status_changed_at not cleared on Undo'::text); end if;
    update app.pantry_items set status = 'discarded' where id = item returning status_changed_at into t2;
    if t2 is null then failures := array_append(failures, 'status_changed_at not set on Discard'::text); end if;
  end;

  -- Bad names are rejected.
  begin
    perform app.get_or_create_custom_ingredient('   ');
    failures := array_append(failures, 'blank custom name accepted'::text);
  exception when invalid_parameter_value then null;
  end;

  -- A soft-deleted custom item can be created again under the same name.
  update app.ingredients_private set deleted_at = now() where id = id1;
  id2 := app.get_or_create_custom_ingredient('Grandma''s Chili');
  if id2 = id1 then failures := array_append(failures, 'deleted custom item was reused'::text); end if;

  ------------------------------------------------------------------ as B
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  select count(*) into n from app.search_ingredients('grandma') where is_custom;
  if n > 0 then failures := array_append(failures, 'B sees A''s custom items in search'::text); end if;
  id3 := app.get_or_create_custom_ingredient('Grandma''s Chili');   -- B's own, separate
  if id3 in (id1, id2) then failures := array_append(failures, 'B got A''s custom item'::text); end if;

  -- anon can't call either function
  perform set_config('role', 'anon', true);
  begin
    perform app.search_ingredients('egg');
    failures := array_append(failures, 'anon can search'::text);
  exception when insufficient_privilege then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
