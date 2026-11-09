-- F2.2 per-user recipe limits (like NFR-9 for scans). Generalizes app.scan_usage to any kind
-- of AI call. Recipe requests are counted by their first model call (kind 'recipes'); the
-- stronger fallback model logs as 'recipes_fallback' so a retry doesn't use up the user's limit.

create function app.ai_usage(p_kind text, p_user uuid default null)
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
               where l.user_id = uid and l.kind = p_kind and l.ok and l.created_at >= day_start),
    'this_month', (select count(*) from app.ai_usage_log l
                    where l.user_id = uid and l.kind = p_kind and l.ok and l.created_at >= month_start),
    'day_resets_at', (date_trunc('day', now() at time zone tz) + interval '1 day') at time zone tz,
    'month_resets_at', (date_trunc('month', now() at time zone tz) + interval '1 month') at time zone tz
  );
end;
$$;

revoke execute on function app.ai_usage(text, uuid) from public, anon;
grant execute on function app.ai_usage(text, uuid) to authenticated, service_role;
