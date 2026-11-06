-- Seat-level control for the admin portal: block seats, sell at the box office, release seats.
-- Run after schema.sql (Supabase SQL Editor). Safe to re-run.

-- box-office payment methods
alter table public.orders drop constraint if exists orders_payment_method_check;
alter table public.orders add constraint orders_payment_method_check
  check (payment_method in ('mpesa','airtel','card','cash','complimentary'));

-- seats an admin has taken off sale (not tied to an order)
create table if not exists public.seat_blocks (
  section_id text not null references public.sections,
  row_no     int  not null check (row_no between 1 and 60),
  seat_no    int  not null check (seat_no between 1 and 2000),
  note       text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (section_id, row_no, seat_no)
);
alter table public.seat_blocks enable row level security;
drop policy if exists "admins read blocks" on public.seat_blocks;
create policy "admins read blocks" on public.seat_blocks
  for select to authenticated using ((select public.is_admin()));

-- parse [{"s":"119","r":7,"n":16}, ...]
create or replace function public._seat_list(p_seats jsonb, p_max int)
returns table (section_id text, row_no int, seat_no int)
language plpgsql immutable set search_path = '' as $$
declare v_n int;
begin
  if p_seats is null or jsonb_typeof(p_seats) <> 'array' then raise exception 'INVALID_SEATS'; end if;
  v_n := jsonb_array_length(p_seats);
  if v_n < 1 or v_n > p_max then raise exception 'INVALID_SEAT_COUNT'; end if;
  return query select distinct e->>'s', (e->>'r')::int, (e->>'n')::int from jsonb_array_elements(p_seats) e;
end $$;
revoke all on function public._seat_list(jsonb,int) from public, anon, authenticated;

-- ============ PUBLIC STATE: blocked seats count as taken ============
create or replace function public.get_public_state() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'sections', coalesce((select json_agg(json_build_object('id', id, 'status', status, 'price', price))
                          from public.sections), '[]'::json),
    'taken',    coalesce((select json_agg(json_build_array(section_id, row_no, seat_no)) from (
                            select section_id, row_no, seat_no from public.order_seats where active
                            union all
                            select section_id, row_no, seat_no from public.seat_blocks) t), '[]'::json)
  );
$$;

-- ============ PUBLIC BOOKING: also refuse blocked seats ============
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

  perform 1 from public.sections
    where id in (select e->>'s' from jsonb_array_elements(p_seats) e) for share;
  select string_agg(distinct e->>'s', ',') into v_bad
    from jsonb_array_elements(p_seats) e
    left join public.sections s on s.id = e->>'s'
    where s.id is null or s.status <> 'open' or s.price is null;
  if v_bad is not null then raise exception 'SECTION_NOT_OPEN' using detail = v_bad; end if;

  select jsonb_agg(jsonb_build_array(t.section_id, t.row_no, t.seat_no)) into v_taken
    from jsonb_array_elements(p_seats) e
    join (select section_id, row_no, seat_no from public.order_seats where active
          union all select section_id, row_no, seat_no from public.seat_blocks) t
      on t.section_id = e->>'s' and t.row_no = (e->>'r')::int and t.seat_no = (e->>'n')::int;
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

-- ============ ADMIN: BLOCK / UNBLOCK ============
create or replace function public.admin_block_seats(p_seats jsonb, p_note text default null) returns int
language plpgsql security definer set search_path = '' as $$
declare v_taken jsonb; v_n int;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select jsonb_agg(jsonb_build_array(o.section_id, o.row_no, o.seat_no)) into v_taken
    from public._seat_list(p_seats, 2000) l
    join public.order_seats o on o.active and o.section_id = l.section_id and o.row_no = l.row_no and o.seat_no = l.seat_no;
  if v_taken is not null then raise exception 'SEATS_TAKEN' using detail = v_taken::text; end if;
  insert into public.seat_blocks (section_id, row_no, seat_no, note)
    select l.section_id, l.row_no, l.seat_no, nullif(btrim(p_note), '') from public._seat_list(p_seats, 2000) l
    on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.admin_unblock_seats(p_seats jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  delete from public.seat_blocks b using public._seat_list(p_seats, 2000) l
    where b.section_id = l.section_id and b.row_no = l.row_no and b.seat_no = l.seat_no;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ============ ADMIN: SELL AT THE BOX OFFICE ============
-- Works for any section status. Blocked seats are sold too (their block is removed).
create or replace function public.admin_sell_seats(
  p_seats jsonb, p_first text, p_last text, p_phone text, p_email text, p_method text, p_paid boolean default true
) returns json
language plpgsql security definer set search_path = '' as $$
declare v_order uuid; v_ref text; v_total int; v_taken jsonb; v_try int := 0; v_bad text;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_method not in ('mpesa','airtel','card','cash','complimentary') then raise exception 'INVALID_METHOD'; end if;
  select string_agg(distinct l.section_id, ',') into v_bad
    from public._seat_list(p_seats, 200) l left join public.sections s on s.id = l.section_id where s.id is null;
  if v_bad is not null then raise exception 'UNKNOWN_SECTION' using detail = v_bad; end if;
  select jsonb_agg(jsonb_build_array(o.section_id, o.row_no, o.seat_no)) into v_taken
    from public._seat_list(p_seats, 200) l
    join public.order_seats o on o.active and o.section_id = l.section_id and o.row_no = l.row_no and o.seat_no = l.seat_no;
  if v_taken is not null then raise exception 'SEATS_TAKEN' using detail = v_taken::text; end if;

  loop
    v_try := v_try + 1;
    v_ref := 'TSC-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from public.orders where ref = v_ref) or v_try > 5;
  end loop;
  insert into public.orders (ref, first_name, last_name, phone, email, payment_method, total, status)
    values (v_ref,
            coalesce(nullif(btrim(p_first), ''), 'Box office'), coalesce(nullif(btrim(p_last), ''), 'sale'),
            coalesce(regexp_replace(coalesce(p_phone, ''), '\s', '', 'g'), ''), lower(btrim(coalesce(p_email, ''))),
            p_method, 0, case when p_paid then 'paid' else 'pending' end)
    returning id into v_order;
  begin
    insert into public.order_seats (order_id, section_id, row_no, seat_no, price)
      select v_order, l.section_id, l.row_no, l.seat_no,
             case when p_method = 'complimentary' then 0 else coalesce(s.price, 0) end
      from public._seat_list(p_seats, 200) l join public.sections s on s.id = l.section_id;
  exception when unique_violation then
    raise exception 'SEATS_TAKEN';
  end;
  delete from public.seat_blocks b using public._seat_list(p_seats, 200) l
    where b.section_id = l.section_id and b.row_no = l.row_no and b.seat_no = l.seat_no;
  select coalesce(sum(price), 0) into v_total from public.order_seats where order_id = v_order;
  update public.orders set total = v_total where id = v_order;
  return json_build_object('ref', v_ref, 'total', v_total);
end $$;

-- ============ ADMIN: RELEASE SEATS ============
-- Frees the given seats (sold, held or blocked). Order totals are recalculated;
-- an order left with no seats is cancelled.
create or replace function public.admin_release_seats(p_seats jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int := 0; v_b int := 0; v_orders uuid[];
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  with rel as (
    update public.order_seats o set active = false
      from public._seat_list(p_seats, 2000) l
      where o.active and o.section_id = l.section_id and o.row_no = l.row_no and o.seat_no = l.seat_no
      returning o.order_id)
  select count(*), array_agg(distinct order_id) into v_n, v_orders from rel;
  if v_n > 0 then
    update public.orders o set
        total = coalesce((select sum(price) from public.order_seats s where s.order_id = o.id and s.active), 0),
        status = case when exists (select 1 from public.order_seats s where s.order_id = o.id and s.active)
                      then o.status else 'cancelled' end
      where o.id = any(v_orders);
  end if;
  delete from public.seat_blocks b using public._seat_list(p_seats, 2000) l
    where b.section_id = l.section_id and b.row_no = l.row_no and b.seat_no = l.seat_no;
  get diagnostics v_b = row_count;
  return v_n + v_b;
end $$;

-- ============ PERMISSIONS ============
revoke all on function public.admin_block_seats(jsonb,text) from public;
revoke all on function public.admin_unblock_seats(jsonb) from public;
revoke all on function public.admin_sell_seats(jsonb,text,text,text,text,text,boolean) from public;
revoke all on function public.admin_release_seats(jsonb) from public;
grant execute on function public.admin_block_seats(jsonb,text) to authenticated;
grant execute on function public.admin_unblock_seats(jsonb) to authenticated;
grant execute on function public.admin_sell_seats(jsonb,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.admin_release_seats(jsonb) to authenticated;
