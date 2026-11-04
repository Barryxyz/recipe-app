-- F1.6: one rule that sets each pantry item's expiry date.
-- Priority: 1. the user set the date (expiry_overridden) -> never recalculated
--           2. the user's default for (ingredient, location)  [app.user_shelf_life_overrides]
--           3. the catalog's shelf life for the location      [catalog.ingredients]
--           4. fallback: fridge 7, freezer 90, pantry 30 days
-- expires_at = end (23:59:59) of local day (date added + days), in the user's timezone.
-- The Swift ExpiryCalculator implements the same rule; supabase/tests/expiry_cases.json
-- is run against both.

-- The user's IANA timezone, set by the app on launch. The server needs it to know which
-- local day an item was added on.
alter table app.user_prefs add column timezone text not null default 'UTC';

create function app.check_timezone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'unknown timezone: %', new.timezone using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger check_timezone
  before insert or update of timezone on app.user_prefs
  for each row execute function app.check_timezone();

-- Shelf life in days for an ingredient at a location, for a given user (rules 2-4).
create function app.shelf_life_days(p_user uuid, p_ingredient bigint, p_location text)
returns int
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d int;
begin
  -- 2. the user's own default for this ingredient and location
  if p_user is not null and p_ingredient is not null then
    select o.days into d
      from app.user_shelf_life_overrides o
     where o.user_id = p_user and o.ingredient_id = p_ingredient
       and o.location = p_location and o.deleted_at is null;
    if d is not null then return d; end if;
  end if;

  -- 3. the catalog (custom items have ids >= 1e12 and never match)
  if p_ingredient is not null then
    select case p_location
             when 'fridge'  then i.shelf_life_fridge_days
             when 'freezer' then i.shelf_life_freezer_days
             when 'pantry'  then i.shelf_life_pantry_days
           end
      into d
      from catalog.ingredients i
     where i.id = p_ingredient;
    if d is not null then return d; end if;
  end if;

  -- 4. fallback
  return case p_location when 'freezer' then 90 when 'pantry' then 30 else 7 end;
end;
$$;

-- The default expiry for an item (rules 2-4), as a timestamp.
create function app.default_expiry(p_user uuid, p_ingredient bigint, p_location text, p_added_at timestamptz)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  tz text;
  local_day date;
begin
  select p.timezone into tz from app.user_prefs p where p.user_id = p_user;
  tz := coalesce(tz, 'UTC');
  local_day := (p_added_at at time zone tz)::date + app.shelf_life_days(p_user, p_ingredient, p_location);
  -- 23:59:59 local time on that day
  return ((local_day + 1)::timestamp at time zone tz) - interval '1 second';
end;
$$;

-- Fills in expires_at (rule 1 keeps whatever the user set).
-- Insert: always computed unless the user set the date; the server's value is final.
-- Update: recomputed when expires_at is cleared, or the location or ingredient changes.
-- Computed from added_at, so moving milk to the freezer gives added date + freezer days.
create function app.pantry_items_set_expiry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.expiry_overridden then
    return new;
  end if;
  if tg_op = 'INSERT'
     or new.expires_at is null
     or new.location is distinct from old.location
     or new.ingredient_id is distinct from old.ingredient_id then
    new.expires_at := app.default_expiry(coalesce(new.added_by, auth.uid()), new.ingredient_id, new.location, new.added_at);
  end if;
  return new;
end;
$$;

create trigger set_expiry
  before insert or update on app.pantry_items
  for each row execute function app.pantry_items_set_expiry();

-- Called only by triggers (and tests as postgres). Security definer functions shouldn't be
-- callable by clients: shelf_life_days would reveal another user's defaults.
revoke execute on function app.check_timezone()            from public, anon, authenticated;
revoke execute on function app.shelf_life_days(uuid, bigint, text)                    from public, anon, authenticated;
revoke execute on function app.default_expiry(uuid, bigint, text, timestamptz)        from public, anon, authenticated;
revoke execute on function app.pantry_items_set_expiry()   from public, anon, authenticated;
