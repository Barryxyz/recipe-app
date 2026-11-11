-- F4.1 Share link (and the read side for the F4.2 public page).
--   app.create_share_link(p_recipe_id) -> token: the owner's existing token, or a new one
--     (22 base62 characters from 22 random bytes, ~131 bits: can't be guessed).
--   app.stop_sharing(p_recipe_id): clears the token; the old link stops working. Sharing again
--     makes a new token.
--   public.get_shared_recipe(p_token) -> jsonb: the recipe as currently saved, recipe fields only
--     (no ids, owner or dates), or null when the token is unknown, revoked or the recipe deleted.
--     Security definer, callable by anyone (the public page uses the anon key). It lives in the
--     public schema so anon needs no access to the app schema at all. There's no way to list
--     shared recipes or look one up by recipe id.

create function app.new_share_token()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  alphabet constant text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  bytes bytea := extensions.gen_random_bytes(22);
  token text := '';
begin
  for i in 0..21 loop
    token := token || substr(alphabet, (get_byte(bytes, i) % 62) + 1, 1);
  end loop;
  return token;
end;
$$;
revoke execute on function app.new_share_token() from public, anon, authenticated;

-- Security definer (it makes the token), limited to the caller's own, not deleted recipes.
create function app.create_share_link(p_recipe_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  token text;
begin
  select r.share_token into token from app.recipes r
   where r.id = p_recipe_id and r.user_id = auth.uid() and r.deleted_at is null
     for update;
  if not found then
    raise exception 'recipe not found' using errcode = 'P0002';
  end if;
  if token is null then
    token := app.new_share_token();
    update app.recipes set share_token = token where id = p_recipe_id;
  end if;
  return token;
end;
$$;

create function app.stop_sharing(p_recipe_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  update app.recipes set share_token = null where id = p_recipe_id and user_id = auth.uid();
  if not found then
    raise exception 'recipe not found' using errcode = 'P0002';
  end if;
end;
$$;

create function public.get_shared_recipe(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'title', r.title,
           'description', r.description,
           'servings', r.servings,
           'prep_min', r.prep_min,
           'cook_min', r.cook_min,
           'steps', r.steps,
           'macros_per_serving', r.macros_per_serving,
           'is_ai', r.source <> 'manual',
           'ingredients', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'name', i.name, 'quantity', i.quantity, 'unit', i.unit, 'note', i.note,
                      'is_optional', i.is_optional) order by i.position)
               from app.recipe_ingredients i where i.recipe_id = r.id), '[]'::jsonb))
    from app.recipes r
   where p_token ~ '^[0-9A-Za-z]{22}$' and r.share_token = p_token and r.deleted_at is null
$$;

revoke execute on function app.create_share_link(uuid) from public, anon;
revoke execute on function app.stop_sharing(uuid) from public, anon;
revoke execute on function public.get_shared_recipe(text) from public;
grant execute on function app.create_share_link(uuid) to authenticated;
grant execute on function app.stop_sharing(uuid) to authenticated;
grant execute on function public.get_shared_recipe(text) to anon, authenticated;
