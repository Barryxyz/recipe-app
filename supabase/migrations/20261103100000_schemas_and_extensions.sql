-- F0.3: schemas, extensions and shared helpers.
-- DESIGN §5 / D1: one database, two schemas. `catalog` is shared and read-only to
-- users; `app` holds per-user data behind row-level security.

create extension if not exists pg_trgm with schema extensions;

create schema if not exists catalog;
create schema if not exists app;

-- Signed-in users (anonymous sign-ins included) use the `authenticated` role.
-- `anon` (no session) gets nothing in either schema.
grant usage on schema catalog to authenticated, service_role;
grant usage on schema app     to authenticated, service_role;

-- Keeps updated_at current. Attached to every table with an updated_at column.
create or replace function app.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
