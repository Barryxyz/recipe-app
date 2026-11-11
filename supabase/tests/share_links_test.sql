-- F4.1 acceptance test: sharing twice gives the same token, revoking and sharing again gives a
-- new one, revoked / deleted recipes return nothing, only the owner can share, and the public
-- read exposes recipe fields only (no ids, owner, token or dates), also to anon.
--
--   ./scripts/test.sh db

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  rid uuid;
  t1 text; t2 text; t3 text;
  shared jsonb;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  rid := app.save_recipe(jsonb_build_object('title', 'Lemon Chicken', 'servings', 2, 'steps', jsonb_build_array('Cook.'),
    'ingredients', jsonb_build_array(jsonb_build_object('name', 'chicken', 'ingredient_id', 52, 'quantity', 300, 'unit', 'g'),
                                     jsonb_build_object('name', 'lemon', 'is_optional', true))));
  t1 := app.create_share_link(rid);
  t2 := app.create_share_link(rid);
  if t1 !~ '^[0-9A-Za-z]{22}$' then failures := array_append(failures, format('bad token %s', t1)); end if;
  if t1 <> t2 then failures := array_append(failures, 'sharing twice gave a new token'::text); end if;

  -- B can't share or stop A's recipe.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  begin
    perform app.create_share_link(rid);
    failures := array_append(failures, 'B shared A''s recipe'::text);
  exception when no_data_found then null;
  end;
  begin
    perform app.stop_sharing(rid);
    failures := array_append(failures, 'B stopped A''s sharing'::text);
  exception when no_data_found then null;
  end;

  -- Anyone (anon) can read it, recipe fields only.
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  shared := public.get_shared_recipe(t1);
  if shared->>'title' <> 'Lemon Chicken' or jsonb_array_length(shared->'ingredients') <> 2
     or (shared->>'is_ai')::boolean is not true then
    failures := array_append(failures, format('shared recipe wrong: %s', shared));
  end if;
  if shared ?| array['id', 'user_id', 'share_token', 'created_at', 'updated_at', 'source', 'model_version'] then
    failures := array_append(failures, 'shared recipe exposes owner or internal fields'::text);
  end if;
  if public.get_shared_recipe('nope') is not null or public.get_shared_recipe(t1 || 'x') is not null then
    failures := array_append(failures, 'a bad token returned something'::text);
  end if;
  begin
    perform 1 from app.recipes limit 1;
    failures := array_append(failures, 'anon can read app.recipes'::text);
  exception when insufficient_privilege then null;
  end;

  -- Revoke, then share again: the old link is dead, the new one differs.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform app.stop_sharing(rid);
  if public.get_shared_recipe(t1) is not null then failures := array_append(failures, 'revoked link still works'::text); end if;
  t3 := app.create_share_link(rid);
  if t3 = t1 then failures := array_append(failures, 'sharing again reused the revoked token'::text); end if;

  -- A deleted recipe's link stops working.
  update app.recipes set deleted_at = now() where id = rid;
  if public.get_shared_recipe(t3) is not null then failures := array_append(failures, 'deleted recipe still shared'::text); end if;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
