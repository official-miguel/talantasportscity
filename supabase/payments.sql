-- Mobile-money payments (Flutterwave). Run once in Supabase > SQL Editor, after schema.sql.

alter table public.orders add column if not exists pay_ref text;   -- Flutterwave transaction id

-- Lets the tickets page poll whether the customer has approved the phone prompt.
-- Needs both the order ref and the phone number used at checkout, so refs can't be probed.
create or replace function public.order_status(p_ref text, p_phone text) returns text
language sql stable security definer set search_path = '' as $$
  select status from public.orders
  where ref = p_ref and phone = regexp_replace(coalesce(p_phone, ''), '\s', '', 'g');
$$;
revoke all on function public.order_status(text,text) from public;
grant execute on function public.order_status(text,text) to anon, authenticated;
