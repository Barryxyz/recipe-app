-- F0.6 Subscription verification (monthly and yearly auto-renewable subscriptions).
-- The subscription lives on app.users. Clients can read their own row but never write it
-- (no client update grant or policy on app.users); only the verify-subscription and
-- appstore-notifications Edge Functions write it, with the service role.
-- Replaces the one-time purchase columns.

alter table app.users
  add column subscription_product text,
  add column subscription_expires_at timestamptz,          -- includes Apple's billing grace period
  add column subscription_environment text check (subscription_environment in ('Production', 'Sandbox', 'Xcode')),
  add column original_transaction_id text,
  add column subscription_updated_at timestamptz;

create unique index users_original_transaction_idx on app.users (original_transaction_id)
  where original_transaction_id is not null;

alter table app.users drop column purchase_verified_at, drop column purchase_environment;

-- Notifications: the newest signed date wins, so an old, retried notification can't undo a newer one.
comment on column app.users.subscription_updated_at is
  'signedDate of the Apple data last applied (F0.6); older data is ignored.';
