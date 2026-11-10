-- F5.2 acceptance test: users can insert only their own events and can't read any;
-- the cost view and prices aren't readable from the app; the view prices tokens correctly.
--
--   ./scripts/test.sh db

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  n int;
  cost numeric;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  -- As postgres: two known calls on a far-past day, to check the view's arithmetic.
  insert into app.ai_usage_log (user_id, kind, model, input_tokens, output_tokens, created_at) values
    (a, 'test-f52', 'claude-sonnet-5-5', 1000000, 100000, '2001-01-01 12:00+00'),
    (a, 'test-f52', 'claude-haiku-5-5', 2000000, 1000000, '2001-01-01 13:00+00');
  select sum(cost_usd) into cost from app.ai_cost_daily where day = '2001-01-01' and kind = 'test-f52';
  -- Sonnet 1M in + 0.1M out = 2 + 1 = 3; Haiku 2M in + 1M out = 0.2 + 0.5 = 0.7
  if cost is distinct from 3.7 then failures := array_append(failures, format('cost %s, expected 3.7', cost)); end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  insert into app.events (name, props) values ('scan_completed', '{"photos": 2}');
  begin
    insert into app.events (user_id, name) values (b, 'scan_completed');
    failures := array_append(failures, 'A inserted an event as B'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    insert into app.events (name) values ('Bad Name!');
    failures := array_append(failures, 'accepted a bad event name'::text);
  exception when check_violation then null;
  end;
  begin
    select count(*) into n from app.events;
    failures := array_append(failures, 'a user can read events'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into n from app.ai_cost_daily;
    failures := array_append(failures, 'a user can read the cost view'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into n from app.model_prices;
    failures := array_append(failures, 'a user can read model prices'::text);
  exception when insufficient_privilege then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
