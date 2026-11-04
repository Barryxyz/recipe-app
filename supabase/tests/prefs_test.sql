-- F1.7 acceptance test: food preferences save, stay within limits and stay private.
-- Runs as two signed-in users in a rolled-back transaction.
--
--   ./scripts/test.sh db
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  n int;
  p record;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);

  ------------------------------------------------------------------ as A
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  -- New users start with empty prefs and 2 servings (sign-up trigger, F0.2).
  select * into p from app.user_prefs where user_id = a;
  if p.diets <> '{}' or p.allergens <> '{}' or p.staple_ingredient_ids <> '{}' or p.default_servings <> 2 then
    failures := array_append(failures, format('unexpected starting prefs: %s', p));
  end if;

  -- What the app saves after onboarding.
  update app.user_prefs
     set diets = array['vegan','gluten_free'],
         allergens = array['peanuts','wheat','gluten','mustard'],
         default_servings = 4
   where user_id = a;
  get diagnostics n = row_count;
  if n <> 1 then failures := array_append(failures, 'A could not save prefs'::text); end if;
  select * into p from app.user_prefs where user_id = a;
  if p.default_servings <> 4 or not (p.allergens @> array['wheat','gluten','mustard']) then
    failures := array_append(failures, format('prefs not saved as sent: %s', p));
  end if;

  -- Staples: the catalog's 13 common staples include the ones added for F1.7. (Users' staples
  -- are pantry items with is_staple since 2026-11-04; see manual_add_test.sql.)
  select count(*) into n from catalog.ingredients
   where is_common_staple and name in ('butter','garlic powder','onion powder','baking soda','baking powder','white vinegar','soy sauce');
  if n <> 7 then failures := array_append(failures, format('%s of 7 new staples marked in the catalog', n)); end if;

  -- Servings must stay within 1-20.
  begin
    update app.user_prefs set default_servings = 0 where user_id = a;
    failures := array_append(failures, 'servings 0 accepted'::text);
  exception when check_violation then null;
  end;
  begin
    update app.user_prefs set default_servings = 21 where user_id = a;
    failures := array_append(failures, 'servings 21 accepted'::text);
  exception when check_violation then null;
  end;

  ------------------------------------------------------------------ as B
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  select count(*) into n from app.user_prefs where user_id = a;
  if n > 0 then failures := array_append(failures, 'B can read A''s prefs'::text); end if;
  update app.user_prefs set allergens = '{}' where user_id = a;
  get diagnostics n = row_count;
  if n > 0 then failures := array_append(failures, 'B changed A''s allergies'::text); end if;
  begin
    insert into app.user_prefs (user_id) values (a);
    failures := array_append(failures, 'B created prefs for A'::text);
  exception when insufficient_privilege or unique_violation then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
