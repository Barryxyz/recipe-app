-- F0.2: every new auth user (anonymous now, Sign in with Apple in v1) gets a personal
-- household, an app.users row and default preferences, in the same transaction as the sign-up.

create function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  hid uuid;
begin
  insert into app.households default values returning id into hid;
  insert into app.users (id, household_id) values (new.id, hid);
  insert into app.user_prefs (user_id) values (new.id);
  return new;
end;
$$;

-- Only the trigger calls it.
revoke execute on function app.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();
