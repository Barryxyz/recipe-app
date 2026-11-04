-- When an item was marked used or discarded, for History & waste (F1.8).
-- Set by the database whenever status changes; cleared when an item goes back to active (Undo).

alter table app.pantry_items add column status_changed_at timestamptz;

-- Items already used or discarded: updated_at is the best available guess.
update app.pantry_items set status_changed_at = updated_at where status <> 'active';

create function app.pantry_items_set_status_changed_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.status_changed_at := case when new.status = 'active' then null else now() end;
  elsif new.status is distinct from old.status then
    new.status_changed_at := case when new.status = 'active' then null else now() end;
  else
    new.status_changed_at := old.status_changed_at;   -- clients can't set it directly
  end if;
  return new;
end;
$$;

revoke execute on function app.pantry_items_set_status_changed_at() from public, anon, authenticated;

create trigger set_status_changed_at
  before insert or update on app.pantry_items
  for each row execute function app.pantry_items_set_status_changed_at();

-- History queries: a household's used/discarded items, newest first.
create index pantry_items_household_history_idx
  on app.pantry_items (household_id, status_changed_at desc)
  where status <> 'active' and deleted_at is null;
