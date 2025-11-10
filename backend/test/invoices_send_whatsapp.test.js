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

function toBase64UrlBytes(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
function b64uJson(obj) { return toBase64UrlBytes(Buffer.from(JSON.stringify(obj))); }
function makeJwt(payloadObj) {
  const header = { alg: 'none', typ: 'JWT' };
  const h = b64uJson(header);
  const p = b64uJson(payloadObj);
  return `${h}.${p}.`;
}

// Gate RBAC: token inválido sem pontos -> 401
test('Invoices: token inválido sem pontos -> 401', async () => {
  const res = await jfetch(`${BASE}/invoices/999999/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511990000000' }),
    headers: { Authorization: 'Bearer invalidtokenwithoutdots' },
  });
  assert.strictEqual(res.status, 401);
});

// Gate RBAC: decodeJwt com sub inexistente -> 403 (sem role ou supabase)
test('Invoices: decodeJwt com sub inexistente -> 403', async () => {
  const now = Math.floor(Date.now() / 1000);
  const token = makeJwt({ sub: `user_${Date.now()}`, exp: now + 3600 });
  const res = await jfetch(`${BASE}/invoices/999999/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511990000001' }),
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.strictEqual(res.status, 403);
});

// Bypass via x-api-key: sem Supabase configurado ou invoice inexistente -> 400
// (O preHandler é bypassado e o handler falha ao enfileirar)
test('Invoices: bypass x-api-key -> 400 (sem Supabase ou invoice inválida)', async () => {
  const apiKey = process.env.API_KEY || 'dev-key';
  const res = await jfetch(`${BASE}/invoices/999999/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511990000002' }),
    headers: { 'x-api-key': apiKey },
  });
  assert.strictEqual(res.status, 400);
});