-- Seasoning & Staples (user request 2026-11-04): staples are ordinary pantry items with a flag,
-- shown in their own section at the bottom of the pantry. Amount and expiry are optional
-- (default: "some" and no expiry). Replaces user_prefs.staple_ingredient_ids.

alter table app.pantry_items add column is_staple boolean not null default false;

comment on column app.user_prefs.staple_ingredient_ids is
  'Deprecated 2026-11-04: staples are pantry_items with is_staple = true. Converted once by this migration; no longer written.';

-- Convert each user's onboarding staples into staple pantry items (no amount, no expiry),
-- skipping ingredients the household already has as a staple.
insert into app.pantry_items
  (household_id, added_by, ingredient_id, display_name, quantity, unit, location,
   expiry_overridden, expires_at, source, is_staple)
select u.household_id, u.id, s.ingredient_id, coalesce(c.name, p.name), null,
       coalesce(c.default_unit, 'each'),
       case
         when c.category = 'frozen' then 'freezer'
         when c.category in ('bakery','grains','baking','spices','oils','canned','nuts','snacks') then 'pantry'
         else 'fridge'
       end,
       true, null, 'manual', true
  from app.user_prefs up
  join app.users u on u.id = up.user_id
  cross join lateral unnest(up.staple_ingredient_ids) as s(ingredient_id)
  left join catalog.ingredients c on c.id = s.ingredient_id
  left join app.ingredients_private p on p.id = s.ingredient_id
 where coalesce(c.name, p.name) is not null
   and not exists (
     select 1 from app.pantry_items x
      where x.household_id = u.household_id and x.ingredient_id = s.ingredient_id
        and x.is_staple and x.status = 'active' and x.deleted_at is null);

update app.user_prefs set staple_ingredient_ids = '{}' where staple_ingredient_ids <> '{}';
