-- F1.3 scan review (save in one transaction) and NFR-9 per-user scan limits.

------------------------------------------------------------------------ scan limits
-- Failed model calls are logged too (F0.5), but only successful ones count toward limits.
alter table app.ai_usage_log add column ok boolean not null default true;

-- Successful scans by this user today and this month, in their own timezone, plus when each
-- count resets. Called by scan-ingredients (service role, any user) and by the app (own user).
create function app.scan_usage(p_user uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := coalesce(p_user, auth.uid());
  tz text;
  day_start timestamptz;
  month_start timestamptz;
begin
  -- Clients may only ask about themselves.
  if p_user is not null and auth.role() <> 'service_role' and p_user is distinct from auth.uid() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select p.timezone into tz from app.user_prefs p where p.user_id = uid;
  tz := coalesce(tz, 'UTC');
  day_start := date_trunc('day', now() at time zone tz) at time zone tz;
  month_start := date_trunc('month', now() at time zone tz) at time zone tz;
  return jsonb_build_object(
    'today', (select count(*) from app.ai_usage_log l
               where l.user_id = uid and l.kind = 'scan' and l.ok and l.created_at >= day_start),
    'this_month', (select count(*) from app.ai_usage_log l
                    where l.user_id = uid and l.kind = 'scan' and l.ok and l.created_at >= month_start),
    'day_resets_at', (date_trunc('day', now() at time zone tz) + interval '1 day') at time zone tz,
    'month_resets_at', (date_trunc('month', now() at time zone tz) + interval '1 month') at time zone tz
  );
end;
$$;

revoke execute on function app.scan_usage(uuid) from public, anon;
grant execute on function app.scan_usage(uuid) to authenticated, service_role;

------------------------------------------------------------------------ scan review save
-- Saves a reviewed scan in one transaction: creates custom ingredients, inserts new pantry
-- rows (source 'scan') and applies "update amount" to existing rows. Any error rolls the whole
-- call back, so a failed save writes nothing and the app keeps the draft.
-- Security invoker: RLS applies (own household only).
--
-- items: [{ ingredient_id?: bigint, custom_name?: text, display_name: text, quantity?: numeric,
--           unit?: text, location: 'fridge'|'freezer'|'pantry', is_staple?: bool,
--           expiry_overridden?: bool, expires_at?: timestamptz,
--           update_item_id?: uuid }]     -- set: update that existing item's amount instead
-- Returns { added, updated }.
create function app.add_pantry_items(items jsonb)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  it jsonb;
  ing bigint;
  added int := 0;
  updated int := 0;
  n int;
begin
  if jsonb_typeof(items) <> 'array' then
    raise exception 'items must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(items) > 100 then
    raise exception 'at most 100 items per save' using errcode = '22023';
  end if;

  for it in select * from jsonb_array_elements(items) loop
    if coalesce(btrim(it->>'display_name'), '') = '' then
      raise exception 'every item needs a name' using errcode = '22023';
    end if;

    if it ? 'update_item_id' and it->>'update_item_id' is not null then
      update app.pantry_items
         set quantity = nullif(it->>'quantity', '')::numeric,
             unit = coalesce(it->>'unit', unit)
       where id = (it->>'update_item_id')::uuid and status = 'active' and deleted_at is null;
      get diagnostics n = row_count;
      if n <> 1 then
        raise exception 'item to update not found' using errcode = 'P0002';
      end if;
      updated := updated + 1;
      continue;
    end if;

    ing := nullif(it->>'ingredient_id', '')::bigint;
    if ing is null and coalesce(btrim(it->>'custom_name'), '') <> '' then
      ing := app.get_or_create_custom_ingredient(it->>'custom_name');
    end if;

    insert into app.pantry_items
      (ingredient_id, display_name, quantity, unit, location, is_staple,
       expiry_overridden, expires_at, source)
    values
      (ing, btrim(it->>'display_name'), nullif(it->>'quantity', '')::numeric, it->>'unit',
       coalesce(it->>'location', 'fridge'), coalesce((it->>'is_staple')::boolean, false),
       coalesce((it->>'expiry_overridden')::boolean, false),
       case when coalesce((it->>'expiry_overridden')::boolean, false)
            then nullif(it->>'expires_at', '')::timestamptz end,
       'scan');
    added := added + 1;
  end loop;

  return jsonb_build_object('added', added, 'updated', updated);
end;
$$;

revoke execute on function app.add_pantry_items(jsonb) from public, anon;
grant execute on function app.add_pantry_items(jsonb) to authenticated;
