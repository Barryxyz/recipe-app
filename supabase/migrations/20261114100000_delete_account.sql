-- F5.3 / F0.2: Delete account (App Review guideline 5.1.1(v)).
--   app.delete_my_account(): deletes the caller's auth user straight away. That cascades to
--   app.users and every per-user table (prefs, recipes and their share links, custom
--   ingredients, shelf-life overrides, events, subscription columns). The household (pantry
--   and shopping list) is deleted too when no other member is left. app.ai_usage_log keeps
--   its token counts with user_id set to null (cost totals only, no content).
--   Security definer: the authenticated role can't delete from auth.users itself.
--
-- A subscription isn't cancelled by deleting the account (it belongs to the Apple ID), so its
-- Apple original transaction id is kept in app.released_subscriptions (nothing else about the
-- person). Restore purchases on a new account can then claim it once (verify-subscription),
-- although Apple's appAccountToken still names the deleted account. Only Edge Functions (service
-- role) read or write this table.

create table app.released_subscriptions (
  original_transaction_id text primary key,
  released_at             timestamptz not null default now()
);
alter table app.released_subscriptions enable row level security;
revoke all on app.released_subscriptions from public, anon, authenticated;

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
  insert into app.released_subscriptions (original_transaction_id)
  select u.original_transaction_id from app.users u where u.id = uid and u.original_transaction_id is not null
  on conflict (original_transaction_id) do update set released_at = now();
  select u.household_id into hh from app.users u where u.id = uid;
  delete from auth.users where id = uid;
  if hh is not null and not exists (select 1 from app.users u where u.household_id = hh) then
    delete from app.households where id = hh;
  end if;
end;
$$;

revoke execute on function app.delete_my_account() from public, anon;
grant execute on function app.delete_my_account() to authenticated;
