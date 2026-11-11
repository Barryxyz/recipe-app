-- F3.6 Offline cache & sync.
--   app.server_now(): the server's clock, so the app's "pulled up to" marks don't depend on the
--     phone's clock.
--   Shopping list rows are soft deleted from now on (deleted_at), so other devices learn about
--     deletes; app.move_bought_to_pantry marks moved rows deleted instead of removing them.
--   Indexes for "changed since" pulls.
--   A nightly job removes rows soft deleted more than 30 days ago (pg_cron).

create function app.server_now()
returns timestamptz
language sql
stable
set search_path = ''
as $$ select now() $$;
revoke execute on function app.server_now() from public, anon;
grant execute on function app.server_now() to authenticated;

create index pantry_items_household_updated_idx on app.pantry_items (household_id, updated_at);
create index shopping_list_items_household_updated_idx on app.shopping_list_items (household_id, updated_at);

create or replace function app.move_bought_to_pantry(items jsonb)
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
    update app.shopping_list_items set deleted_at = now() where id = row.id;   -- soft delete (F3.6)
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Nightly clean-up of soft-deleted rows (recipe_ingredients go with their recipe).
create extension if not exists pg_cron;

create function app.purge_soft_deleted()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from app.pantry_items where deleted_at < now() - interval '30 days';
  delete from app.shopping_list_items where deleted_at < now() - interval '30 days';
  delete from app.recipes where deleted_at < now() - interval '30 days';
$$;
revoke execute on function app.purge_soft_deleted() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'purge-soft-deleted';
select cron.schedule('purge-soft-deleted', '30 3 * * *', 'select app.purge_soft_deleted()');
