-- F3.4 "Cooked this": reduce pantry items after cooking, in one transaction, with undo.
--
-- app.apply_cooked(changes) takes [{id, quantity?, used?}]:
--   quantity: the item's new amount (rounded by the app); <= 0 marks it used
--   used: true marks it used ("Used it up"), keeping its last amount for History
-- Only active, not deleted items of the caller's household change (RLS); others are skipped,
-- e.g. a household member used the item meanwhile. Returns the rows as they were before,
-- [{id, quantity, status}], which app.undo_cooked(snapshot) puts back exactly.

create function app.apply_cooked(changes jsonb)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  ch jsonb;
  item record;
  new_qty numeric;
  snapshot jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(changes) <> 'array' then
    raise exception 'changes must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(changes) > 100 then
    raise exception 'too many changes' using errcode = '22023';
  end if;

  for ch in select * from jsonb_array_elements(changes) loop
    select p.id, p.quantity, p.status into item
      from app.pantry_items p
     where p.id = (ch->>'id')::uuid and p.status = 'active' and p.deleted_at is null
       for update;
    continue when not found;

    new_qty := nullif(ch->>'quantity', '')::numeric;
    if coalesce((ch->>'used')::boolean, false) or new_qty <= 0 then
      update app.pantry_items
         set status = 'used', quantity = case when new_qty is not null then 0 else quantity end,
             updated_at = now()
       where id = item.id;
    elsif new_qty is not null then
      update app.pantry_items set quantity = new_qty, updated_at = now() where id = item.id;
    else
      continue;   -- nothing to change
    end if;

    snapshot := snapshot || jsonb_build_array(
      jsonb_build_object('id', item.id, 'quantity', item.quantity, 'status', item.status));
  end loop;

  return snapshot;
end;
$$;

create function app.undo_cooked(snapshot jsonb)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  s jsonb;
begin
  if jsonb_typeof(snapshot) <> 'array' or jsonb_array_length(snapshot) > 100 then
    raise exception 'bad snapshot' using errcode = '22023';
  end if;
  for s in select * from jsonb_array_elements(snapshot) loop
    if coalesce(s->>'status', '') not in ('active', 'used', 'discarded') then
      raise exception 'bad status in snapshot' using errcode = '22023';
    end if;
    update app.pantry_items
       set quantity = nullif(s->>'quantity', '')::numeric, status = s->>'status', updated_at = now()
     where id = (s->>'id')::uuid and deleted_at is null;
  end loop;
end;
$$;

revoke execute on function app.apply_cooked(jsonb) from public, anon;
revoke execute on function app.undo_cooked(jsonb) from public, anon;
grant execute on function app.apply_cooked(jsonb) to authenticated;
grant execute on function app.undo_cooked(jsonb) to authenticated;
