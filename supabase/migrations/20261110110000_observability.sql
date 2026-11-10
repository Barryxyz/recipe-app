-- F5.2 Observability (prototype: product events and the AI cost query).
--
-- app.events: product events from the app, inserted in batches. Insert-only for the user's own
--   rows; nobody reads them through the API (the developer queries them in the dashboard).
--   Props hold counts and options only: never food names, titles, typed text or photos.
-- app.model_prices: $ per 1M tokens, first-party API (DESIGN §8). Edit a row when prices change.
-- app.ai_cost_daily: daily AI cost by kind and model. Not exposed to the app.

create table app.events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references app.users on delete cascade,
  name       text not null check (name ~ '^[a-z_]{1,40}$'),
  props      jsonb not null default '{}'::jsonb check (jsonb_typeof(props) = 'object' and length(props::text) <= 2000),
  created_at timestamptz not null default now()
);
create index events_name_created_idx on app.events (name, created_at);

alter table app.events enable row level security;
create policy "insert own events" on app.events
  for insert to authenticated
  with check (user_id = (select auth.uid()));
revoke all on app.events from anon, authenticated;
grant insert on app.events to authenticated;
grant usage, select on sequence app.events_id_seq to authenticated;

create table app.model_prices (
  model             text primary key,
  input_usd_per_m   numeric not null check (input_usd_per_m >= 0),
  output_usd_per_m  numeric not null check (output_usd_per_m >= 0),
  updated_at        timestamptz not null default now()
);
alter table app.model_prices enable row level security;   -- no policies: dashboard only
insert into app.model_prices (model, input_usd_per_m, output_usd_per_m) values
  ('claude-sonnet-5-5', 2.00, 10.00),
  ('claude-haiku-5-5', 0.10, 0.50),
  ('claude-opus-5-5', 4.00, 20.00);

-- Days in UTC (the Anthropic console's day). A model without a price shows cost null.
create view app.ai_cost_daily with (security_invoker = true) as
select (l.created_at at time zone 'utc')::date as day,
       l.kind,
       l.model,
       count(*) as calls,
       sum(l.input_tokens) as input_tokens,
       sum(l.output_tokens) as output_tokens,
       round(sum(l.input_tokens) / 1e6 * max(p.input_usd_per_m)
           + sum(l.output_tokens) / 1e6 * max(p.output_usd_per_m), 4) as cost_usd
  from app.ai_usage_log l
  left join app.model_prices p on p.model = l.model
 group by 1, 2, 3;

revoke all on app.model_prices, app.ai_cost_daily from anon, authenticated;
grant all on app.events, app.model_prices to service_role;
grant select on app.ai_cost_daily to service_role;
