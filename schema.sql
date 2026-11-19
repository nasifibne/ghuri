-- =====================================================================
-- Ghuri — database setup for Supabase
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run once on a fresh project.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Trips (public)
-- ---------------------------------------------------------------------
create table if not exists public.trips (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  author_name    text not null check (char_length(author_name) between 2 and 60),
  is_local       boolean not null default false,
  title          text not null check (char_length(title) between 4 and 120),
  start_district text not null check (char_length(start_district) between 2 and 40),
  trip_length    text not null check (trip_length in ('day','overnight','2-3','4plus')),
  group_size     int  not null check (group_size between 1 and 50),
  trip_month     text not null check (trip_month ~ '^[0-9]{4}-[0-9]{2}$'),
  places         jsonb not null,
  costs          jsonb not null,
  per_person     numeric not null,
  total          numeric not null,
  tips           text,
  watch_out      text,
  season         text,
  vibes          text[] not null default '{}',
  photos         text[] not null default '{}',
  up_votes       int not null default 0,
  down_votes     int not null default 0,
  status         text not null default 'published' check (status in ('published','hidden'))
);

-- ---------------------------------------------------------------------
-- Phone numbers + private map links (PRIVATE — never readable from the website)
-- You can see them in Supabase → Table Editor → trip_contacts.
-- private_maps = Google Maps links of places the poster chose to keep hidden.
-- ---------------------------------------------------------------------
create table if not exists public.trip_contacts (
  trip_id    uuid primary key references public.trips(id) on delete cascade,
  phone        text not null,
  private_maps jsonb not null default '[]',
  created_at   timestamptz not null default now()
);
alter table public.trip_contacts add column if not exists private_maps jsonb not null default '[]';

-- ---------------------------------------------------------------------
-- Ask-a-local comments and reports
-- ---------------------------------------------------------------------
create table if not exists public.comments (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  name       text not null check (char_length(name) between 2 and 60),
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

create table if not exists public.reports (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  reason     text not null check (char_length(reason) between 1 and 300),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.trips         enable row level security;
alter table public.trip_contacts enable row level security;  -- no policies = nobody reads it via the API
alter table public.comments      enable row level security;
alter table public.reports       enable row level security;

drop policy if exists "read published trips" on public.trips;
create policy "read published trips" on public.trips
  for select using (status = 'published');

drop policy if exists "read comments" on public.comments;
create policy "read comments" on public.comments
  for select using (exists (select 1 from public.trips t where t.id = trip_id and t.status = 'published'));

drop policy if exists "add comments" on public.comments;
create policy "add comments" on public.comments
  for insert with check (char_length(name) between 2 and 60 and char_length(body) between 1 and 1000);

drop policy if exists "add reports" on public.reports;
create policy "add reports" on public.reports
  for insert with check (char_length(reason) between 1 and 300);

-- ---------------------------------------------------------------------
-- Table permissions for the website (newer Supabase projects need these).
-- The website may read trips and comments, add comments and reports.
-- It gets NO access to trip_contacts (phone numbers, private map links).
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select on public.trips to anon, authenticated;
grant select, insert on public.comments to anon, authenticated;
grant insert on public.reports to anon, authenticated;
revoke all on public.trip_contacts from anon, authenticated;

-- ---------------------------------------------------------------------
-- create_trip: the only way to add a trip. Saves the phone privately and
-- recalculates the cost totals on the server so they can't be faked.
-- ---------------------------------------------------------------------
create or replace function public.create_trip(p jsonb, phone text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
  gs     int;
  pp     numeric := 0;
  item   jsonb;
  amt    numeric;
  pl     jsonb;
  m      text;
  pub    jsonb := '[]'::jsonb;
  priv   jsonb := '[]'::jsonb;
begin
  phone := regexp_replace(coalesce(phone, ''), '[^0-9+]', '', 'g');
  if phone !~ '^(\+?88)?01[3-9][0-9]{8}$' then
    raise exception 'Invalid phone number';
  end if;

  gs := (p->>'group_size')::int;
  if gs is null or gs < 1 or gs > 50 then raise exception 'Invalid group size'; end if;

  if jsonb_typeof(p->'places') <> 'array'
     or jsonb_array_length(p->'places') < 1 or jsonb_array_length(p->'places') > 20 then
    raise exception 'Add 1 to 20 places';
  end if;
  if jsonb_typeof(p->'costs') <> 'array'
     or jsonb_array_length(p->'costs') < 1 or jsonb_array_length(p->'costs') > 40 then
    raise exception 'Add 1 to 40 cost items';
  end if;

  -- Every place must have a Google Maps link. Hidden spots keep it private.
  for pl in select * from jsonb_array_elements(p->'places') loop
    m := trim(coalesce(pl->>'map', ''));
    if m !~* '^https://(www\.)?(google\.[a-z.]+/maps|maps\.google\.[a-z.]+|maps\.app\.goo\.gl|goo\.gl/maps)' then
      raise exception 'Each place needs a Google Maps link';
    end if;
    if char_length(coalesce(pl->>'name', '')) < 1 then raise exception 'Place name missing'; end if;
    if coalesce((pl->>'exact')::boolean, true) then
      pub := pub || jsonb_build_array(pl);
    else
      pub  := pub  || jsonb_build_array(jsonb_set(pl, '{map}', '""'::jsonb));
      priv := priv || jsonb_build_array(jsonb_build_object('name', pl->>'name', 'district', pl->>'district', 'map', m));
    end if;
  end loop;

  for item in select * from jsonb_array_elements(p->'costs') loop
    amt := (item->>'amount')::numeric;
    if amt is null or amt < 0 or amt > 1000000 then raise exception 'Invalid amount'; end if;
    if item->>'per' = 'group' then pp := pp + amt / gs; else pp := pp + amt; end if;
  end loop;
  pp := round(pp);

  insert into public.trips (
    author_name, is_local, title, start_district, trip_length, group_size, trip_month,
    places, costs, per_person, total, tips, watch_out, season, vibes, photos
  ) values (
    trim(p->>'author_name'),
    coalesce((p->>'is_local')::boolean, false),
    trim(p->>'title'),
    p->>'start_district',
    p->>'trip_length',
    gs,
    p->>'trip_month',
    pub,
    p->'costs',
    pp,
    pp * gs,
    nullif(left(trim(coalesce(p->>'tips', '')), 2000), ''),
    nullif(left(trim(coalesce(p->>'watch_out', '')), 1000), ''),
    nullif(p->>'season', ''),
    coalesce(array(select jsonb_array_elements_text(coalesce(p->'vibes', '[]'::jsonb))), '{}'),
    coalesce(array(select jsonb_array_elements_text(coalesce(p->'photos', '[]'::jsonb))), '{}')
  )
  returning id into new_id;

  insert into public.trip_contacts (trip_id, phone, private_maps) values (new_id, phone, priv);
  return new_id;
end;
$$;

-- ---------------------------------------------------------------------
-- vote_trip: "Was this cost accurate?" yes / no
-- ---------------------------------------------------------------------
create or replace function public.vote_trip(tid uuid, is_up boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update public.trips
     set up_votes   = up_votes   + case when is_up then 1 else 0 end,
         down_votes = down_votes + case when is_up then 0 else 1 end
   where id = tid and status = 'published';
$$;

grant execute on function public.create_trip(jsonb, text) to anon, authenticated;
grant execute on function public.vote_trip(uuid, boolean)  to anon, authenticated;

-- ---------------------------------------------------------------------
-- Auto-hide a trip after 3 reports (you can un-hide it in Table Editor
-- by setting status back to 'published').
-- ---------------------------------------------------------------------
create or replace function public.auto_hide_reported()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.reports where trip_id = new.trip_id) >= 3 then
    update public.trips set status = 'hidden' where id = new.trip_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_auto_hide on public.reports;
create trigger trg_auto_hide after insert on public.reports
  for each row execute function public.auto_hide_reported();

-- ---------------------------------------------------------------------
-- Photo storage (public read, anyone can upload images up to 2 MB)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('trip-photos', 'trip-photos', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "upload trip photos" on storage.objects;
create policy "upload trip photos" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'trip-photos');
