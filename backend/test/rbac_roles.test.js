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

// decodeJwt deve aceitar Base64URL sem padding -> RBAC chega a 403 (não 401)
test('decodeJwt: Base64URL sem padding com sub -> 403 em RBAC', async () => {
  const now = Math.floor(Date.now() / 1000);
  const token = makeJwt({ sub: `user_${Date.now()}`, exp: now + 3600 });
  const res = await jfetch(`${BASE}/test/seed-outbox`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511991234567', message: 'RBAC decode test' }),
    headers: { Authorization: `Bearer ${token}` },
  });
  // 403 confirma que decodeJwt extraiu sub; 401 indicaria falha ao extrair sub
  assert.strictEqual(res.status, 403);
});

// decodeJwt: sem sub -> 401 (unauthorized)
test('decodeJwt: payload sem sub -> 401 em RBAC', async () => {
  const now = Math.floor(Date.now() / 1000);
  const token = makeJwt({ exp: now + 3600 });
  const res = await jfetch(`${BASE}/test/seed-outbox`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511997654321', message: 'RBAC no sub test' }),
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.strictEqual(res.status, 401);
});

// RBAC positivo por papel (Financeiro) se Supabase estiver configurado
test('RBAC positivo: role Financeiro permite POST /test/send-whatsapp (200)', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');
  // signup/login
  const email = `role_fin_${Date.now()}_${Math.floor(Math.random()*1e6)}@test.local`;
  const password = '12345678';
  const name = 'RBAC Role Test';

  const signup = await jfetch(`${BASE}/auth/signup`, { method: 'POST', body: JSON.stringify({ email, password, name }) });
  assert.ok([201, 200].includes(signup.status));

  const login = await jfetch(`${BASE}/auth/login`, { method: 'POST', body: JSON.stringify({ email, password }) });
  assert.strictEqual(login.status, 200);
  const accessToken = login.data?.access_token;
  const userId = login.data?.user?.id || signup.data?.user_id || null;
  assert.ok(accessToken);
  assert.ok(userId);

  // atualizar role para Financeiro
  const { data: updData, error: updErr } = await supabase.from('users').update({ role: 'Financeiro' }).eq('id', userId).select('id, role').maybeSingle();
  assert.ok(!updErr, `Erro ao atualizar role: ${updErr && updErr.message}`);
  assert.strictEqual(String(updData.role), 'Financeiro');

  // acesso à rota com RBAC positivo (sem x-api-key)
  const allowed = await jfetch(`${BASE}/test/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511990001122', message: 'RBAC positive' }),
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  assert.strictEqual(allowed.status, 200);
});

// RBAC positivo por papel (Admin)
test('RBAC positivo: role Admin permite POST /test/send-whatsapp (200)', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');
  const email = `role_admin_${Date.now()}_${Math.floor(Math.random()*1e6)}@test.local`;
  const password = '12345678';
  const name = 'RBAC Role Admin';

  const signup = await jfetch(`${BASE}/auth/signup`, { method: 'POST', body: JSON.stringify({ email, password, name }) });
  assert.ok([201, 200].includes(signup.status));

  const login = await jfetch(`${BASE}/auth/login`, { method: 'POST', body: JSON.stringify({ email, password }) });
  assert.strictEqual(login.status, 200);
  const accessToken = login.data?.access_token;
  const userId = login.data?.user?.id || signup.data?.user_id || null;
  assert.ok(accessToken);
  assert.ok(userId);

  const { data: updData, error: updErr } = await supabase.from('users').update({ role: 'Admin' }).eq('id', userId).select('id, role').maybeSingle();
  assert.ok(!updErr, `Erro ao atualizar role: ${updErr && updErr.message}`);
  assert.strictEqual(String(updData.role), 'Admin');

  const allowed = await jfetch(`${BASE}/test/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511990001133', message: 'RBAC admin positive' }),
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  assert.strictEqual(allowed.status, 200);
});

// RBAC positivo por papel (Gerente)
test('RBAC positivo: role Gerente permite POST /test/send-whatsapp (200)', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');
  const email = `role_ger_${Date.now()}_${Math.floor(Math.random()*1e6)}@test.local`;
  const password = '12345678';
  const name = 'RBAC Role Gerente';

  const signup = await jfetch(`${BASE}/auth/signup`, { method: 'POST', body: JSON.stringify({ email, password, name }) });
  assert.ok([201, 200].includes(signup.status));

  const login = await jfetch(`${BASE}/auth/login`, { method: 'POST', body: JSON.stringify({ email, password }) });
  assert.strictEqual(login.status, 200);
  const accessToken = login.data?.access_token;
  const userId = login.data?.user?.id || signup.data?.user_id || null;
  assert.ok(accessToken);
  assert.ok(userId);

  const { data: updData, error: updErr } = await supabase.from('users').update({ role: 'Gerente' }).eq('id', userId).select('id, role').maybeSingle();
  assert.ok(!updErr, `Erro ao atualizar role: ${updErr && updErr.message}`);
  assert.strictEqual(String(updData.role), 'Gerente');

  const allowed = await jfetch(`${BASE}/test/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511990001144', message: 'RBAC gerente positive' }),
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  assert.strictEqual(allowed.status, 200);
});

// decodeJwt: token inválido sem pontos -> 401
test('decodeJwt: token inválido sem pontos -> 401 em RBAC', async () => {
  const res = await jfetch(`${BASE}/test/seed-outbox`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511998880000', message: 'invalid token format' }),
    headers: { Authorization: 'Bearer invalidtokenwithoutdots' },
  });
  assert.strictEqual(res.status, 401);
});

// decodeJwt: payload base64 inválido -> 401
test('decodeJwt: payload base64 inválido -> 401 em RBAC', async () => {
  const badHeader = toBase64UrlBytes(Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })));
  const badPayload = '***not-base64***';
  const token = `${badHeader}.${badPayload}.`;
  const res = await jfetch(`${BASE}/test/seed-outbox`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511998880001', message: 'invalid base64 payload' }),
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.strictEqual(res.status, 401);
});