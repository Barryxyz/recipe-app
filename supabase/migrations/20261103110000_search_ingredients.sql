-- F0.4: catalog search used by scan matching (F1.2), manual add (F1.5) and the shopping list (F3.5).
-- Scores: exact name/alias match 1.0, prefix match 0.9, otherwise trigram similarity (kept if >= 0.3).
-- Ordered by score, then shorter names first ("egg" before "eggplant").

create function catalog.search_ingredients(q text, lim int default 10)
returns table (id bigint, name text, category text, default_unit text, score real)
language sql
stable
parallel safe
set search_path = ''
as $$
  with input as (
    select lower(btrim(q)) as q,
           -- escape LIKE wildcards so "50%" doesn't match everything
           replace(replace(replace(lower(btrim(q)), '\', '\\'), '%', '\%'), '_', '\_') || '%' as prefix
  ),
  scored as (
    select i.id, i.name, i.category, i.default_unit,
           (select max(
                     case
                       when t = input.q then 1.0
                       when t like input.prefix then 0.9
                       else extensions.similarity(t, input.q)
                     end)
              from unnest(array_prepend(lower(i.name), (select array_agg(lower(a)) from unnest(i.aliases) a))) t
           )::real as score
      from catalog.ingredients i, input
     where input.q <> ''
  )
  select s.id, s.name, s.category, s.default_unit, s.score
    from scored s
   where s.score >= 0.3
   order by s.score desc, length(s.name), s.name
   limit greatest(1, least(coalesce(lim, 10), 50))
$$;

revoke execute on function catalog.search_ingredients(text, int) from public, anon;
grant execute on function catalog.search_ingredients(text, int) to authenticated, service_role;
