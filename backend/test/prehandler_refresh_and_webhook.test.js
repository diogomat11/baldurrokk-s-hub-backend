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
  return { status: res.status, data, text, headers: res.headers };
}

function toB64Url(obj) {
  const json = typeof obj === 'string' ? obj : JSON.stringify(obj);
  const b64 = Buffer.from(json).toString('base64');
  return b64.replace(/=+$/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}
function makeJwt(payload) {
  const header = { alg: 'none', typ: 'JWT' };
  return `${toB64Url(header)}.${toB64Url(payload)}.`;
}
function randomEmail(prefix = 'auto') {
  return `${prefix}.${Date.now()}@test.com`;
}

// Auto-refresh: cria usuário, login para obter refresh_token, envia token com exp <5min
// Espera x-new-access-token no header de resposta
test('PreHandler: auto-refresh em atividade retorna x-new-access-token', async () => {
  if (!HAVE_SUPABASE) return;
  const email = randomEmail('refresh');
  const password = '12345678';

  // signup
  const sres = await jfetch(`${BASE}/auth/signup`, {
    method: 'POST',
    body: JSON.stringify({ email, password, name: 'Auto Refresh' }),
  });
  assert.ok(sres.status === 201 || sres.status === 200, `signup falhou: ${sres.status}`);

  // login
  const lres = await jfetch(`${BASE}/auth/login`, {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
  assert.strictEqual(lres.status, 200);
  const refreshToken = lres.data && lres.data.refresh_token;
  const userId = lres.data && lres.data.user && lres.data.user.id;
  assert.ok(refreshToken, 'refresh_token ausente');

  // token com exp em ~60s
  const now = Math.floor(Date.now() / 1000);
  const nearExp = now + 60;
  const nearExpToken = makeJwt({ sub: userId || 'user', exp: nearExp });

  const apiKey = process.env.API_KEY || 'dev-key';
  const send = await jfetch(`${BASE}/test/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511999998888', message: 'Teste auto-refresh' }),
    headers: {
      Authorization: `Bearer ${nearExpToken}`,
      'x-refresh-token': refreshToken,
      'x-api-key': apiKey,
    },
  });
  assert.strictEqual(send.status, 200);
  const newToken = send.headers.get('x-new-access-token');
  assert.ok(newToken, 'x-new-access-token ausente');
  assert.ok(String(newToken).split('.').length === 3, 'novo token não parece JWT');
});

// Webhook GET: comportamento depende da presença de WHATSAPP_VERIFY_TOKEN
// - Se existir, deve retornar challenge com 200
// - Se não existir, deve retornar 403
test('Webhook GET: subscribe retorna 200 com challenge se token confere; senão 403', async () => {
  const challenge = 'abc123';
  const verify = process.env.WHATSAPP_VERIFY_TOKEN || null;
  const url = `${BASE}/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=${verify || 'wrong'}&hub.challenge=${challenge}`;
  const res = await jfetch(url, { method: 'GET' });
  if (verify) {
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.text, challenge);
  } else {
    assert.strictEqual(res.status, 403);
  }
});

// Webhook POST: sem assinatura (ou strict=false) deve retornar 200
test('Webhook POST: sem assinatura retorna 200 (strict=false)', async () => {
  const res = await jfetch(`${BASE}/webhook/whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ entry: [{ id: 'test' }] }),
    headers: { 'x-hub-signature-256': 'sha256=invalid' },
  });
  assert.strictEqual(res.status, 200);
  assert.ok(res.data && res.data.ok === true);
});