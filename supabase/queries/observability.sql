-- F5.2: saved queries for the Supabase dashboard (SQL editor → paste one, run, save as a snippet).
-- Or from the repo: supabase db query --remote --yes "<query>"
-- Everything here is read-only.

-- 1. Daily AI cost, last 14 days, by kind and model (UTC days, like the Anthropic console).
select day, kind, model, calls, input_tokens, output_tokens, cost_usd
  from app.ai_cost_daily
 where day >= current_date - 14
 order by day desc, cost_usd desc nulls last;

-- 2. Daily total, to compare with the Anthropic console (should match within 5%).
select day, sum(calls) as calls, sum(cost_usd) as cost_usd
  from app.ai_cost_daily
 where day >= current_date - 14
 group by day order by day desc;

-- 3. Top 10 users by AI cost, last 7 days.
select l.user_id, count(*) as calls,
       round(sum(l.input_tokens / 1e6 * p.input_usd_per_m + l.output_tokens / 1e6 * p.output_usd_per_m), 4) as cost_usd
  from app.ai_usage_log l join app.model_prices p on p.model = l.model
 where l.created_at >= now() - interval '7 days'
 group by l.user_id order by cost_usd desc limit 10;

-- 4. Cost per active user, last 30 days (no purchasers in the prototype; v1 divides by verified
--    purchasers and compares with the ~$4.24 net per sale, D5). Hosting isn't included.
select round(sum(l.input_tokens / 1e6 * p.input_usd_per_m + l.output_tokens / 1e6 * p.output_usd_per_m), 4) as ai_cost_usd,
       count(distinct l.user_id) as active_ai_users,
       round(sum(l.input_tokens / 1e6 * p.input_usd_per_m + l.output_tokens / 1e6 * p.output_usd_per_m)
             / nullif(count(distinct l.user_id), 0), 4) as cost_per_user_usd
  from app.ai_usage_log l join app.model_prices p on p.model = l.model
 where l.created_at >= now() - interval '30 days';

-- 5. Scan edit rate = (deleted + edited + added by hand) ÷ saved, from scan_saved events.
select count(*) as reviews,
       sum((props->>'saved')::int) as saved,
       round(sum((props->>'deleted')::int + (props->>'edited')::int + (props->>'added_manually')::int)::numeric
             / nullif(sum((props->>'saved')::int), 0), 3) as edit_rate
  from app.events
 where name = 'scan_saved' and created_at >= now() - interval '30 days';

-- 6. Scan vs. manual mix: how pantry items were added, last 30 days.
select source, count(*) as items, round(100.0 * count(*) / sum(count(*)) over (), 1) as percent
  from app.pantry_items
 where added_at >= now() - interval '30 days' and deleted_at is null
 group by source order by items desc;

-- 7. Recipe save rate = recipes saved ÷ recipes generated, last 30 days.
select coalesce(sum((props->>'count')::int) filter (where name = 'recipes_generated'), 0) as generated,
       count(*) filter (where name = 'recipe_saved') as saved,
       round(count(*) filter (where name = 'recipe_saved')::numeric
             / nullif(sum((props->>'count')::int) filter (where name = 'recipes_generated'), 0), 3) as save_rate
  from app.events
 where name in ('recipes_generated', 'recipe_saved') and created_at >= now() - interval '30 days';

-- 8. Event counts, last 7 days (a quick check that events arrive).
select name, count(*) as events, count(distinct user_id) as users, max(created_at) as last_seen
  from app.events
 where created_at >= now() - interval '7 days'
 group by name order by events desc;
