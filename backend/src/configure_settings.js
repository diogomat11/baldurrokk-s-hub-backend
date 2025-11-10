require('dotenv').config();
const { supabase } = require('./supabase');

async function main() {
  const PIX_KEY = process.env.PIX_KEY || 'pix@coelho-fc.com.br';
  const TEMPLATE = process.env.WHATSAPP_TEMPLATE || null;

  // Busca última linha de settings
  const { data: rows, error: selErr } = await supabase
    .from('settings')
    .select('id, pix_key, whatsapp_template_invoice, updated_at')
    .order('updated_at', { ascending: false })
    .limit(1);
  if (selErr) throw selErr;
  const current = rows && rows.length ? rows[0] : null;

  let res;
  if (current) {
    const payload = { pix_key: PIX_KEY };
    if (TEMPLATE) payload.whatsapp_template_invoice = TEMPLATE;
    res = await supabase.from('settings').update(payload).eq('id', current.id).select('*').maybeSingle();
  } else {
    const payload = { pix_key: PIX_KEY };
    if (TEMPLATE) payload.whatsapp_template_invoice = TEMPLATE;
    res = await supabase.from('settings').insert(payload).select('*').maybeSingle();
  }
  if (res.error) throw res.error;
  console.log('[settings] updated', {
    id: res.data.id,
    pix_key: res.data.pix_key,
    template_len: (res.data.whatsapp_template_invoice || '').length,
    updated_at: res.data.updated_at,
  });
}

main().catch((err) => {
  console.error('[settings] error', err);
  process.exit(1);
});