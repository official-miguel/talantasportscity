// Sends the M-Pesa / Airtel Money PIN prompt to the customer's phone via Flutterwave.
// The money lands in the Flutterwave merchant account, which pays out to PAYEE_NUMBER
// (set the payout/settlement account in the Flutterwave dashboard to that number).
//
// Secrets (supabase secrets set ...): FLW_SECRET_KEY, optional UGX_PER_KES (default 28)
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const { ref, phone, method } = await req.json();
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

    // Amount and customer always come from the stored order, never from the browser.
    const { data: o } = await sb.from('orders')
      .select('ref,first_name,last_name,phone,email,total,status').eq('ref', ref).maybeSingle();
    if (!o || o.phone !== String(phone).replace(/\s/g, '')) return json({ error: 'ORDER_NOT_FOUND' }, 404);
    if (o.status !== 'pending') return json({ error: 'ORDER_NOT_PENDING' }, 409);

    const digits = o.phone.replace(/\D/g, '');
    const txRef = `${o.ref}_${Date.now()}`;
    const base = {
      tx_ref: txRef,
      email: o.email,
      fullname: `${o.first_name} ${o.last_name}`,
      phone_number: digits,
    };

    let type: string, body: Record<string, unknown>;
    if (method === 'mpesa') {
      if (!o.phone.startsWith('+254')) return json({ error: 'MPESA_KENYA_ONLY' }, 400);
      type = 'mpesa';
      body = { ...base, amount: o.total, currency: 'KES' };
    } else if (method === 'airtel') {
      if (!o.phone.startsWith('+256')) return json({ error: 'AIRTEL_UGANDA_ONLY' }, 400);
      type = 'mobile_money_uganda';
      const rate = Number(Deno.env.get('UGX_PER_KES') ?? '28');
      body = { ...base, amount: Math.round(o.total * rate), currency: 'UGX', network: 'AIRTEL' };
    } else {
      return json({ error: 'METHOD_NOT_PROMPTABLE' }, 400);
    }

    const r = await fetch(`https://api.flutterwave.com/v3/charges?type=${type}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${Deno.env.get('FLW_SECRET_KEY')}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    if (!r.ok || j.status !== 'success') {
      console.error('flutterwave', JSON.stringify(j));
      return json({ error: 'CHARGE_FAILED' }, 502);
    }
    return json({ ok: true });
  } catch (e) {
    console.error(e);
    return json({ error: 'SERVER_ERROR' }, 500);
  }
});
