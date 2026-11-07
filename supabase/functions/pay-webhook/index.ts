// Flutterwave calls this when the customer approves (or fails) the prompt.
// Dashboard > Settings > Webhooks: URL = https://<project>.supabase.co/functions/v1/pay-webhook
// and "Secret hash" = the same value as the FLW_SECRET_HASH secret.
// Deploy with:  supabase functions deploy pay-webhook --no-verify-jwt
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.headers.get('verif-hash') !== Deno.env.get('FLW_SECRET_HASH')) return new Response('forbidden', { status: 401 });
  try {
    const evt = await req.json();
    const id = evt?.data?.id;
    if (!id) return new Response('ignored');

    // Never trust the webhook body alone: ask Flutterwave for the real transaction.
    const v = await fetch(`https://api.flutterwave.com/v3/transactions/${id}/verify`, {
      headers: { Authorization: `Bearer ${Deno.env.get('FLW_SECRET_KEY')}` },
    });
    const t = (await v.json()).data;
    if (!t || t.status !== 'successful') return new Response('not successful');

    const ref = String(t.tx_ref).split('_')[0];
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: o } = await sb.from('orders').select('id,total,status').eq('ref', ref).maybeSingle();
    if (!o) return new Response('unknown order');

    const rate = t.currency === 'UGX' ? Number(Deno.env.get('UGX_PER_KES') ?? '28') : 1;
    if (!['KES', 'UGX'].includes(t.currency) || Number(t.amount) < Math.round(o.total * rate)) {
      console.error('amount mismatch', ref, t.amount, t.currency);
      return new Response('amount mismatch');
    }
    if (o.status === 'pending') {
      await sb.from('orders').update({ status: 'paid', pay_ref: String(id) }).eq('id', o.id);
    }
    return new Response('ok');
  } catch (e) {
    console.error(e);
    return new Response('error', { status: 500 });
  }
});
