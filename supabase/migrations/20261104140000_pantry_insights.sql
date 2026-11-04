-- F1.8 History & waste: monthly numbers for the insights card.
-- Security invoker: RLS limits everything to the caller's household.
--
-- Returns {used, thrown_out, waste_rate, thrown_most: [{name, count}], bought_most: [{name, count}]}
--   used / thrown_out: items whose status changed in that calendar month (user's timezone)
--   waste_rate: thrown_out / (used + thrown_out), null when fewer than 5 items (a single
--               thrown-out avocado shouldn't read as "100% waste")
--   thrown_most: top 3 ingredients thrown out in the last 90 days
--   bought_most: top 5 ingredients added in the last 90 days
-- Batches of the same ingredient count together; items without an ingredient group by name.

create function app.pantry_insights(month_start date, tz text default 'UTC')
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  zone text := coalesce((select name from pg_catalog.pg_timezone_names where name = tz), 'UTC');
  from_ts timestamptz := (date_trunc('month', month_start)::timestamp) at time zone zone;
  to_ts timestamptz := ((date_trunc('month', month_start) + interval '1 month')::timestamp) at time zone zone;
  used_n int;
  thrown_n int;
begin
  select count(*) filter (where p.status = 'used'),
         count(*) filter (where p.status = 'discarded')
    into used_n, thrown_n
    from app.pantry_items p
   where p.deleted_at is null and p.status <> 'active'
     and p.status_changed_at >= from_ts and p.status_changed_at < to_ts;

  return jsonb_build_object(
    'month_start', date_trunc('month', month_start)::date,
    'used', used_n,
    'thrown_out', thrown_n,
    'waste_rate', case when used_n + thrown_n >= 5
                       then round(thrown_n::numeric / (used_n + thrown_n), 3) end,
    'thrown_most', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name)
        from (select min(p.display_name) as name, count(*) as n
                from app.pantry_items p
               where p.deleted_at is null and p.status = 'discarded'
                 and p.status_changed_at >= now() - interval '90 days'
               group by coalesce(p.ingredient_id::text, lower(btrim(p.display_name)))
               order by count(*) desc, min(p.display_name)
               limit 3) t), '[]'::jsonb),
    'bought_most', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc, t.name)
        from (select min(p.display_name) as name, count(*) as n
                from app.pantry_items p
               where p.deleted_at is null
                 and p.added_at >= now() - interval '90 days'
               group by coalesce(p.ingredient_id::text, lower(btrim(p.display_name)))
               order by count(*) desc, min(p.display_name)
               limit 5) t), '[]'::jsonb)
  );
end;
$$;

revoke execute on function app.pantry_insights(date, text) from public, anon;
grant execute on function app.pantry_insights(date, text) to authenticated;
