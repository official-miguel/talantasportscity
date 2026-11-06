-- Talanta Sports City ticketing: sections, orders, seats and admin access.
-- Run once in the Supabase SQL Editor (or apply as a migration). Safe to re-run.

-- ============ TABLES ============
create table if not exists public.sections (
  id         text primary key,
  name       text not null,
  grp        text not null,              -- L1, L2, L3, GOLD, PLAT, SB, OTHER
  level      int  not null,
  price      int  check (price is null or price >= 0),
  status     text not null default 'closed' check (status in ('open','closed','reserved','sold_out')),
  sort       int  not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.admins (
  user_id    uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  ref            text not null unique,
  first_name     text not null,
  last_name      text not null,
  phone          text not null,
  email          text not null,
  payment_method text not null check (payment_method in ('mpesa','airtel','card')),
  total          int  not null,
  status         text not null default 'pending' check (status in ('pending','paid','cancelled')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists public.order_seats (
  id         bigint generated always as identity primary key,
  order_id   uuid not null references public.orders on delete cascade,
  section_id text not null references public.sections,
  row_no     int  not null check (row_no between 1 and 60),
  seat_no    int  not null check (seat_no between 1 and 2000),
  price      int  not null,
  active     boolean not null default true   -- false once the order is cancelled
);
-- a seat can only be held by one active order
create unique index if not exists order_seats_one_active
  on public.order_seats (section_id, row_no, seat_no) where active;
create index if not exists order_seats_order on public.order_seats (order_id);
create index if not exists orders_created on public.orders (created_at desc);

-- ============ HELPERS ============
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists sections_touch on public.sections;
create trigger sections_touch before update on public.sections
  for each row execute function public.touch_updated_at();
drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders
  for each row execute function public.touch_updated_at();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ============ ROW LEVEL SECURITY ============
alter table public.sections    enable row level security;
alter table public.admins      enable row level security;
alter table public.orders      enable row level security;
alter table public.order_seats enable row level security;

drop policy if exists "sections readable"      on public.sections;
drop policy if exists "admins update sections" on public.sections;
drop policy if exists "admin sees own row"     on public.admins;
drop policy if exists "admins read orders"     on public.orders;
drop policy if exists "admins read seats"      on public.order_seats;

create policy "sections readable" on public.sections
  for select to anon, authenticated using (true);
create policy "admins update sections" on public.sections
  for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "admin sees own row" on public.admins
  for select to authenticated using (user_id = (select auth.uid()));
create policy "admins read orders" on public.orders
  for select to authenticated using ((select public.is_admin()));
create policy "admins read seats" on public.order_seats
  for select to authenticated using ((select public.is_admin()));
-- Orders and seats are only written through the functions below.

-- ============ PUBLIC: STATE FOR THE TICKETS PAGE ============
-- Section statuses/prices and the seats that are taken. No customer details.
create or replace function public.get_public_state() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'sections', coalesce((select json_agg(json_build_object('id', id, 'status', status, 'price', price))
                          from public.sections), '[]'::json),
    'taken',    coalesce((select json_agg(json_build_array(section_id, row_no, seat_no))
                          from public.order_seats where active), '[]'::json)
  );
$$;

-- ============ PUBLIC: BOOK SEATS ============
-- p_seats: [{"s":"119","r":7,"n":16}, ...]  (1-10 seats)
create or replace function public.book_seats(
  p_first text, p_last text, p_phone text, p_email text, p_method text, p_seats jsonb
) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_order uuid; v_ref text; v_total int := 0; v_n int; v_bad text; v_taken jsonb; v_try int := 0;
begin
  p_first := btrim(coalesce(p_first, '')); p_last := btrim(coalesce(p_last, ''));
  p_phone := regexp_replace(coalesce(p_phone, ''), '\s', '', 'g');
  p_email := lower(btrim(coalesce(p_email, '')));
  if length(p_first) not between 1 and 60 or length(p_last) not between 1 and 60 then
    raise exception 'INVALID_NAME'; end if;
  if p_phone !~ '^\+[0-9]{9,15}$' then raise exception 'INVALID_PHONE'; end if;
  if p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(p_email) > 200 then raise exception 'INVALID_EMAIL'; end if;
  if p_method not in ('mpesa','airtel','card') then raise exception 'INVALID_METHOD'; end if;
  if jsonb_typeof(p_seats) <> 'array' then raise exception 'INVALID_SEATS'; end if;
  v_n := jsonb_array_length(p_seats);
  if v_n < 1 or v_n > 10 then raise exception 'INVALID_SEAT_COUNT'; end if;
  if (select count(distinct (e->>'s', e->>'r', e->>'n')) from jsonb_array_elements(p_seats) e) <> v_n then
    raise exception 'DUPLICATE_SEATS'; end if;

  -- every section must exist, be open and have a price (lock them while booking)
  perform 1 from public.sections
    where id in (select e->>'s' from jsonb_array_elements(p_seats) e) for share;
  select string_agg(distinct e->>'s', ',') into v_bad
    from jsonb_array_elements(p_seats) e
    left join public.sections s on s.id = e->>'s'
    where s.id is null or s.status <> 'open' or s.price is null;
  if v_bad is not null then raise exception 'SECTION_NOT_OPEN' using detail = v_bad; end if;

  select jsonb_agg(jsonb_build_array(os.section_id, os.row_no, os.seat_no)) into v_taken
    from jsonb_array_elements(p_seats) e
    join public.order_seats os on os.active and os.section_id = e->>'s'
      and os.row_no = (e->>'r')::int and os.seat_no = (e->>'n')::int;
  if v_taken is not null then raise exception 'SEATS_TAKEN' using detail = v_taken::text; end if;

  loop
    v_try := v_try + 1;
    v_ref := 'TSC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from public.orders where ref = v_ref) or v_try > 5;
  end loop;

  insert into public.orders (ref, first_name, last_name, phone, email, payment_method, total)
    values (v_ref, p_first, p_last, p_phone, p_email, p_method, 0)
    returning id into v_order;

  begin
    insert into public.order_seats (order_id, section_id, row_no, seat_no, price)
      select v_order, e->>'s', (e->>'r')::int, (e->>'n')::int, s.price
      from jsonb_array_elements(p_seats) e join public.sections s on s.id = e->>'s';
  exception when unique_violation then
    raise exception 'SEATS_TAKEN';
  end;

  select sum(price) into v_total from public.order_seats where order_id = v_order;
  update public.orders set total = v_total where id = v_order;
  return json_build_object('ref', v_ref, 'total', v_total);
end $$;

-- ============ ADMIN: CHANGE ORDER STATUS ============
-- pending -> paid, pending/paid -> cancelled (cancelling frees the seats)
create or replace function public.admin_set_order_status(p_order uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_cur text;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select status into v_cur from public.orders where id = p_order for update;
  if v_cur is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if p_status = 'paid' and v_cur = 'pending' then
    update public.orders set status = 'paid' where id = p_order;
  elsif p_status = 'cancelled' and v_cur in ('pending','paid') then
    update public.orders set status = 'cancelled' where id = p_order;
    update public.order_seats set active = false where order_id = p_order;
  else
    raise exception 'INVALID_STATUS_CHANGE';
  end if;
end $$;

-- ============ PERMISSIONS ============
revoke all on function public.get_public_state() from public;
revoke all on function public.book_seats(text,text,text,text,text,jsonb) from public;
revoke all on function public.admin_set_order_status(uuid,text) from public;
revoke all on function public.is_admin() from public;
grant execute on function public.get_public_state() to anon, authenticated;
grant execute on function public.book_seats(text,text,text,text,text,jsonb) to anon, authenticated;
grant execute on function public.admin_set_order_status(uuid,text) to authenticated;
grant execute on function public.is_admin() to authenticated;

-- ============ SEED SECTIONS (matches the stadium map) ============
-- Starting statuses follow the current design; existing rows are never overwritten.
insert into public.sections (id, name, grp, level, price, status, sort)
select id, name, grp, level, price,
  case when id in ('119','111','110','105','125','218','203','212','209','PL1') then 'open'
       when id in ('128','403','412','414','415','431','433') then 'sold_out'
       else status end,
  sort
from (
select n::text as id, 'Section ' || n as name, 'L1' as grp, 1 as level, 15000 as price, 'closed' as status, n as sort from generate_series(101, 128) n
union all
select n::text, 'Section ' || n, 'L1', 1, 15000, 'closed', n from generate_series(101, 128) n
union all
select n::text, 'Section ' || n, 'L2', 2, 20000, 'closed', n from generate_series(201, 220) n
union all
select * from (values
  ('PL1', 'Platinum 1', 'PLAT', 2, 50000, 'closed', 230),
  ('PL',  'Platinum',   'PLAT', 2, 50000, 'closed', 231),
  ('PL2', 'Platinum 2', 'PLAT', 2, 50000, 'closed', 232)) v(id, name, grp, level, price, status, sort)
union all
select 'GF0' || n, 'Gold F0' || n, 'GOLD', 2, null::int, 'closed', 240 + n from generate_series(1, 5) n
union all
select n::text, 'Box ' || n, 'SB', 2, null::int, 'closed', n from generate_series(301, 350) n
union all
select n::text, 'Section ' || n, 'L3', 3, null::int, 'closed', n from generate_series(401, 435) n
union all
select * from (values
  ('RES',   'Reserved', 'OTHER', 2, null::int, 'reserved', 900),
  ('MEDIA', 'Media',    'OTHER', 3, null::int, 'reserved', 901)) v(id, name, grp, level, price, status, sort)
) seed
on conflict (id) do nothing;

-- ============ MAKE YOURSELF AN ADMIN ============
-- 1. Supabase dashboard > Authentication > Users > Add user (email + password).
-- 2. Run this with that email:
-- insert into public.admins (user_id) select id from auth.users where email = 'you@example.com' on conflict do nothing;
