-- F5.3 acceptance test: Delete account removes the user, their household data, recipes and
-- share links, keeps other users' data, and anon can't call it.
--
--   ./scripts/test.sh db

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  hh_a uuid; hh_b uuid;
  rid uuid; token text;
  c uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated'),
                                                (c, 'authenticated', 'authenticated');
  update app.users set original_transaction_id = 'test-otid-' || a, subscription_expires_at = now() + interval '30 days'
   where id = a;
  select household_id into hh_a from app.users where id = a;
  select household_id into hh_b from app.users where id = b;
  if hh_a is null or hh_b is null then failures := array_append(failures, 'signup trigger made no household'::text); end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source) values (52, 'Chicken', 1, 'each', 'manual');
  insert into app.shopping_list_items (name) values ('Milk');
  rid := app.save_recipe(jsonb_build_object('title', 'Soup', 'servings', 2, 'steps', jsonb_build_array('Cook.'),
    'ingredients', jsonb_build_array(jsonb_build_object('name', 'leek'))));
  token := app.create_share_link(rid);
  insert into app.events (name) values ('recipe_saved');

  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  insert into app.pantry_items (ingredient_id, display_name, quantity, unit, source) values (52, 'Chicken', 1, 'each', 'manual');

  -- anon can't delete anything.
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  begin
    perform app.delete_my_account();
    failures := array_append(failures, 'anon called delete_my_account'::text);
  exception when insufficient_privilege then null;
  end;

  -- A deletes their account.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform app.delete_my_account();

  perform set_config('role', 'postgres', true);
  if exists (select 1 from auth.users where id = a) then failures := array_append(failures, 'auth user left'::text); end if;
  if exists (select 1 from app.users where id = a) then failures := array_append(failures, 'app user left'::text); end if;
  if exists (select 1 from app.households where id = hh_a) then failures := array_append(failures, 'household left'::text); end if;
  if exists (select 1 from app.pantry_items where household_id = hh_a) then failures := array_append(failures, 'pantry left'::text); end if;
  if exists (select 1 from app.shopping_list_items where household_id = hh_a) then failures := array_append(failures, 'shopping list left'::text); end if;
  if exists (select 1 from app.recipes where id = rid) then failures := array_append(failures, 'recipe left'::text); end if;
  if exists (select 1 from app.events where user_id = a) then failures := array_append(failures, 'events left'::text); end if;
  if exists (select 1 from app.user_prefs where user_id = a) then failures := array_append(failures, 'prefs left'::text); end if;
  if public.get_shared_recipe(token) is not null then failures := array_append(failures, 'share link still works'::text); end if;

  if not exists (select 1 from app.released_subscriptions where original_transaction_id = 'test-otid-' || a) then
    failures := array_append(failures, 'subscription not released'::text);
  end if;

  -- Clients can't see or add released subscriptions.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  begin
    perform 1 from app.released_subscriptions limit 1;
    failures := array_append(failures, 'a client can read released subscriptions'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    insert into app.released_subscriptions values ('x');
    failures := array_append(failures, 'a client can release a subscription'::text);
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);

  -- B is untouched.
  if not exists (select 1 from app.users where id = b) or not exists (select 1 from app.pantry_items where household_id = hh_b) then
    failures := array_append(failures, 'another user''s data was deleted'::text);
  end if;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
