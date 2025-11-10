const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();

const BASE = process.env.BASE_URL || 'http://localhost:3001';

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

// Valida erro de telefone inválido no endpoint de teste
// Não depende de Supabase; provider stub retorna invalid_phone
// Usa x-api-key para bypass do RBAC
test('Test send-whatsapp: telefone inválido retorna 502 e invalid_phone', async () => {
  const apiKey = process.env.API_KEY || 'dev-key';
  const res = await jfetch(`${BASE}/test/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '123', message: 'msg' }),
    headers: { 'x-api-key': apiKey },
  });
  assert.strictEqual(res.status, 502);
  assert.ok(res.data && res.data.status === 'Failed');
  assert.ok(res.data && res.data.error === 'invalid_phone');
});