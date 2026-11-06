-- Hylar Herbs: customer review publishing (run once in HYlar's Supabase SQL Editor)
-- Additive change; does not touch products, orders, payments, or existing homepage reviews.
create table if not exists public.site_reviews (
  id uuid primary key default gen_random_uuid(),
  reviewer_name text not null check (char_length(btrim(reviewer_name)) between 1 and 80),
  reviewer_location text not null default '' check (char_length(reviewer_location) <= 100),
  review_text text not null check (char_length(btrim(review_text)) between 10 and 1500),
  rating smallint not null default 5 check (rating between 1 and 5),
  verified boolean not null default false,
  is_visible boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists site_reviews_visible_created_idx
on public.site_reviews (created_at) where is_visible = true;
alter table public.site_reviews enable row level security;
revoke all on public.site_reviews from PUBLIC, anon, authenticated;
grant select on public.site_reviews to anon, authenticated;
grant insert, update, delete on public.site_reviews to authenticated;
drop policy if exists "Anyone may read published reviews" on public.site_reviews;
drop policy if exists "Admins may read and manage all reviews" on public.site_reviews;
drop policy if exists "Admins may insert reviews" on public.site_reviews;
drop policy if exists "Admins may update reviews" on public.site_reviews;
drop policy if exists "Admins may delete reviews" on public.site_reviews;
create policy "Anyone may read published reviews" on public.site_reviews
for select to anon, authenticated using (is_visible = true);
create policy "Admins may read and manage all reviews" on public.site_reviews
for select to authenticated using (
  exists (select 1 from public.admins a where a.user_id = (select auth.uid()))
);
create policy "Admins may insert reviews" on public.site_reviews
for insert to authenticated with check (
  exists (select 1 from public.admins a where a.user_id = (select auth.uid()))
);
create policy "Admins may update reviews" on public.site_reviews
for update to authenticated using (
  exists (select 1 from public.admins a where a.user_id = (select auth.uid()))
) with check (
  exists (select 1 from public.admins a where a.user_id = (select auth.uid()))
);
create policy "Admins may delete reviews" on public.site_reviews
for delete to authenticated using (
  exists (select 1 from public.admins a where a.user_id = (select auth.uid()))
);
-- No starter rows are inserted. The three existing homepage reviews remain in the HTML.
