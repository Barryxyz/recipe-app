-- F5.3 / F0.2: Delete account (App Review guideline 5.1.1(v)).
--   app.delete_my_account(): deletes the caller's auth user straight away. That cascades to
--   app.users and every per-user table (prefs, recipes and their share links, custom
--   ingredients, shelf-life overrides, events, subscription columns). The household (pantry
--   and shopping list) is deleted too when no other member is left. app.ai_usage_log keeps
--   its token counts with user_id set to null (cost totals only, no content).
--   Security definer: the authenticated role can't delete from auth.users itself.

create function app.delete_my_account()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  hh uuid;
begin
  if uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select u.household_id into hh from app.users u where u.id = uid;
  delete from auth.users where id = uid;
  if hh is not null and not exists (select 1 from app.users u where u.household_id = hh) then
    delete from app.households where id = hh;
  end if;
end;
$$;

revoke execute on function app.delete_my_account() from public, anon;
grant execute on function app.delete_my_account() to authenticated;
