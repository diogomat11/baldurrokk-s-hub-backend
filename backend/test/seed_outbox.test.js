const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();

const BASE = process.env.BASE_URL || 'http://localhost:3001';
const HAVE_SUPABASE = Boolean(process.env.SUPABASE_URL && (process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY) && process.env.SUPABASE_SERVICE_ROLE_KEY);

async function jfetch(url, opts = {}) {
  const res = await fetch(url, {
    ...opts,
    headers: {
      'content-type': 'application/json',
      ...(opts.headers || {}),
    },
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch {}
  return { status: res.status, data, headers: res.headers };
}

test('Seed Outbox: positivo 200 com x-api-key insere Pending', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');
  const apiKey = process.env.API_KEY || 'dev-key';

  const res = await jfetch(`${BASE}/test/seed-outbox`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511997776666', message: 'Mensagem seed outbox' }),
    headers: { 'x-api-key': apiKey },
  });
  assert.strictEqual(res.status, 200);
  assert.ok(res.data && res.data.id, 'id ausente');
  assert.strictEqual(res.data.status, 'Queued');

  const outboxId = res.data.id;
  const { data: row, error } = await supabase
    .from('whatsapp_outbox')
    .select('id,status,phone,message')
    .eq('id', outboxId)
    .maybeSingle();
  assert.ok(!error, `Erro ao buscar outbox: ${error && error.message}`);
  assert.ok(row && row.status === 'Pending', 'status diferente de Pending');
});