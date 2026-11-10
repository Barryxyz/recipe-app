-- F3.5 Shopping list. The table and its household RLS exist since 20261103; this adds:
--   source_recipe_title: "for <recipe>" also for recipe ideas that were never saved
--   app.add_shopping_items(items): adds rows or merges into existing ones, in one transaction
--   app.move_bought_to_pantry(items): bought rows -> pantry items, in one transaction

alter table app.shopping_list_items add column source_recipe_title text
  check (length(source_recipe_title) <= 200);

-- items: [{merge_id?, ingredient_id?, name, quantity?, unit?, source_recipe_id?, source_recipe_title?}]
-- merge_id: an unchecked row of the household to add `quantity` to (the app converts it to
-- that row's unit first). If that row is gone or checked, a new row is added instead.
-- Returns how many items were added or merged.
create function app.add_shopping_items(items jsonb)
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  it jsonb;
  qty numeric;
  n int := 0;
  v_name text;
begin
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 100 then
    raise exception 'items must be an array of at most 100' using errcode = '22023';
  end if;

  for it in select * from jsonb_array_elements(items) loop
    v_name := btrim(coalesce(it->>'name', ''));
    if v_name = '' or length(v_name) > 100 then
      raise exception 'every item needs a name (1-100 characters)' using errcode = '22023';
    end if;
    qty := nullif(it->>'quantity', '')::numeric;
    if qty < 0 then raise exception 'quantity must be >= 0' using errcode = '22023'; end if;

    if it->>'merge_id' is not null then
      update app.shopping_list_items s
         set quantity = case when s.quantity is null or qty is null then coalesce(s.quantity, qty)
                             else s.quantity + qty end,
             unit = coalesce(s.unit, nullif(btrim(it->>'unit'), ''))
       where s.id = (it->>'merge_id')::uuid and not s.checked and s.deleted_at is null;
      if found then n := n + 1; continue; end if;
    end if;

    insert into app.shopping_list_items (ingredient_id, name, quantity, unit, source_recipe_id, source_recipe_title)
    values (nullif(it->>'ingredient_id', '')::bigint, v_name, qty, nullif(btrim(it->>'unit'), ''),
            (select r.id from app.recipes r where r.id = nullif(it->>'source_recipe_id', '')::uuid),
            left(nullif(btrim(it->>'source_recipe_title'), ''), 200));
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- items: [{id, location, quantity?, unit?}] for checked rows of the household.
-- Each becomes an active pantry item (source 'shopping_list', expiry from the F1.6 rules);
-- a row without a catalog id becomes the user's custom ingredient. The rows are deleted.
-- Returns how many pantry items were added.
create function app.move_bought_to_pantry(items jsonb)
returns int
language plpgsql
volatile
set search_path = ''
as $$
declare
  it jsonb;
  row app.shopping_list_items%rowtype;
  ing_id bigint;
  n int := 0;
begin
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 100 then
    raise exception 'items must be an array of at most 100' using errcode = '22023';
  end if;

  for it in select * from jsonb_array_elements(items) loop
    if coalesce(it->>'location', '') not in ('fridge', 'freezer', 'pantry') then
      raise exception 'bad location' using errcode = '22023';
    end if;
    select * into row from app.shopping_list_items s
     where s.id = (it->>'id')::uuid and s.deleted_at is null
       for update;
    continue when not found;     -- not this household's, or already moved

    ing_id := coalesce(row.ingredient_id, app.get_or_create_custom_ingredient(row.name));
    insert into app.pantry_items (ingredient_id, display_name, quantity, unit, location, source)
    values (ing_id, row.name,
            case when it ? 'quantity' then nullif(it->>'quantity', '')::numeric else row.quantity end,
            coalesce(nullif(btrim(it->>'unit'), ''), row.unit, 'each'),
            it->>'location', 'shopping_list');
    delete from app.shopping_list_items where id = row.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke execute on function app.add_shopping_items(jsonb) from public, anon;
revoke execute on function app.move_bought_to_pantry(jsonb) from public, anon;
grant execute on function app.add_shopping_items(jsonb) to authenticated;
grant execute on function app.move_bought_to_pantry(jsonb) to authenticated;
