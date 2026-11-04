-- F1.5: manual add. Search over the catalog and the caller's own custom items, and
-- get-or-create for custom items so the same name is never stored twice.

-- One live custom item per name per user (case-insensitive).
create unique index ingredients_private_user_name_uidx
  on app.ingredients_private (user_id, lower(btrim(name)))
  where deleted_at is null;

-- Catalog results (catalog.search_ingredients) plus the caller's custom items, scored the
-- same way: exact 1.0, prefix 0.9, otherwise trigram similarity >= 0.3.
-- An exact custom match comes first, so "grandma's chili" finds the one already saved.
-- Security invoker: RLS limits custom items to the caller's own.
create function app.search_ingredients(q text, lim int default 8)
returns table (id bigint, name text, category text, default_unit text, is_custom boolean, score real)
language sql
stable
set search_path = ''
as $$
  with input as (
    select lower(btrim(q)) as q,
           replace(replace(replace(lower(btrim(q)), '\', '\\'), '%', '\%'), '_', '\_') || '%' as prefix
  ),
  custom as (
    select p.id, p.name, null::text as category, 'each'::text as default_unit, true as is_custom,
           (case
              when lower(btrim(p.name)) = input.q then 1.0
              when lower(btrim(p.name)) like input.prefix then 0.9
              else extensions.similarity(lower(btrim(p.name)), input.q)
            end)::real as score
      from app.ingredients_private p, input
     where p.user_id = auth.uid() and p.deleted_at is null and input.q <> ''
  ),
  found as (
    select c.id, c.name, c.category, c.default_unit, false as is_custom, c.score
      from catalog.search_ingredients(q, 50) c
    union all
    select * from custom where score >= 0.3
  )
  select f.id, f.name, f.category, f.default_unit, f.is_custom, f.score
    from found f
   order by (f.is_custom and f.score = 1.0) desc, f.score desc, length(f.name), f.name
   limit greatest(1, least(coalesce(lim, 8), 50))
$$;

-- Returns the caller's custom item with this name, creating it if needed.
create function app.get_or_create_custom_ingredient(p_name text)
returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  clean text := btrim(p_name);
  found_id bigint;
begin
  if clean is null or clean = '' or length(clean) > 100 then
    raise exception 'custom ingredient name must be 1-100 characters' using errcode = '22023';
  end if;

  insert into app.ingredients_private (user_id, name)
  values (auth.uid(), clean)
  on conflict (user_id, lower(btrim(name))) where deleted_at is null do nothing
  returning id into found_id;

  if found_id is null then
    select p.id into found_id
      from app.ingredients_private p
     where p.user_id = auth.uid() and lower(btrim(p.name)) = lower(clean) and p.deleted_at is null;
  end if;
  return found_id;
end;
$$;

revoke execute on function app.search_ingredients(text, int) from public, anon;
revoke execute on function app.get_or_create_custom_ingredient(text) from public, anon;
grant execute on function app.search_ingredients(text, int) to authenticated;
grant execute on function app.get_or_create_custom_ingredient(text) to authenticated;
