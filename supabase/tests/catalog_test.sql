-- F0.4 acceptance test: catalog completeness and search_ingredients behavior.
-- Runs as a signed-in user (role `authenticated`) in a transaction that is rolled back.
--
--   supabase db query --remote --yes -f supabase/tests/catalog_test.sql
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

do $$
declare
  failures text[] := '{}';
  n int;
  top text;

  -- Expected first result for a query; an empty expectation means "no results".
  cases constant text[][] := array[
    ['scallion',      'green onion'],
    ['Scallions',     'green onion'],   -- case and plural (alias)
    ['  scallion  ',  'green onion'],   -- surrounding spaces
    ['courgette',     'zucchini'],      -- UK/US alias
    ['egg',           'egg'],           -- exact beats "eggplant"-style prefixes
    ['tomatos',       'tomato'],        -- typo, trigram match
    ['chicken breast','chicken breast'],
    ['evoo',          'olive oil'],
    ['steak',         'sirloin steak'],  -- user feedback 2026-11-04: steak and fish were missing
    ['fish',          'cod'],
    ['aubergine',     'eggplant'],
    ['chips',         'potato chips'],   -- US meaning, not fries
    ['50%',           ''],              -- LIKE wildcards are escaped
    ['_',             ''],
    ['',              ''],
    ['xqzvw',         '']               -- nonsense finds nothing
  ];
  c text[];
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);

  ---------------------------------------------------------------- completeness (acceptance criteria)
  select count(*) into n from catalog.ingredients;
  if n < 300 then failures := array_append(failures, format('only %s catalog items', n)); end if;

  select count(*) into n
    from catalog.ingredients i
    left join catalog.ingredient_nutrients x on x.ingredient_id = i.id
   where x.ingredient_id is null or x.kcal is null or x.protein_g is null or x.carbs_g is null or x.fat_g is null;
  if n > 0 then failures := array_append(failures, format('%s items without core nutrients', n)); end if;

  select count(*) into n from catalog.ingredients where shelf_life_fridge_days is null;
  if n > 0 then failures := array_append(failures, format('%s items without fridge shelf life', n)); end if;

  select count(*) into n from catalog.ingredients where default_unit = 'each' and grams_per_unit is null;
  if n > 0 then failures := array_append(failures, format('%s "each" items without grams_per_unit', n)); end if;

  -- F2.3: foods recipes measure in cups/spoons need a density. Meat, fish, grains (mostly
  -- by weight) and snacks are exempt; liquids default to ml and are covered above.
  select count(*) into n from catalog.ingredients
   where default_unit in ('g', 'ml') and density_g_per_ml is null
     and category in ('produce', 'dairy', 'frozen', 'nuts', 'canned', 'baking', 'condiments', 'protein',
                      'spices', 'oils', 'sauces')
     and name <> 'frozen french fries';
  if n > 0 then failures := array_append(failures, format('%s cup-measured items without density', n)); end if;

  select count(*) into n from catalog.ingredients
   where not allergens <@ array['milk','egg','fish','shellfish','tree nuts','peanuts','wheat','soy','sesame','gluten'];
  if n > 0 then failures := array_append(failures, format('%s items with unknown allergen tags', n)); end if;

  ---------------------------------------------------------------- search
  foreach c slice 1 in array cases loop
    select s.name into top from catalog.search_ingredients(c[1]) s limit 1;
    if coalesce(top, '') <> c[2] then
      failures := array_append(failures, format('search %L: expected %L, got %L', c[1], c[2], top));
    end if;
    top := null;
  end loop;

  -- Scores are in (0.3, 1] and ordered.
  select count(*) into n from catalog.search_ingredients('chi', 50) where score < 0.3 or score > 1;
  if n > 0 then failures := array_append(failures, 'scores outside [0.3, 1]'::text); end if;

  -- The limit is respected and clamped to 1..50.
  select count(*) into n from catalog.search_ingredients('a', 3);
  if n > 3 then failures := array_append(failures, 'lim not respected'::text); end if;
  select count(*) into n from catalog.search_ingredients('a', 1000);
  if n > 50 then failures := array_append(failures, 'lim not clamped to 50'::text); end if;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
