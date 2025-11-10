const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();

const BASE = process.env.BASE_URL || 'http://localhost:3001';
const API_KEY = process.env.API_KEY || 'dev-key';
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

function makeFakeJwt(sub = `test_${Date.now()}`) {
  const h = { alg: 'none', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const p = { sub, exp: now + 3600 };
  const b64u = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  return `${b64u(h)}.${b64u(p)}.`; // assinatura vazia
}

// Fluxo principal de auth + RBAC (executa apenas se Supabase configurado)
test('Auth + RBAC flow (health, signup, login, rbac 403, bypass 200, refresh, logout)', async () => {
  if (!HAVE_SUPABASE) {
    // Supabase não configurado: testar RBAC no teste dedicado abaixo
    return;
  }

  // Health/debug
  {
    const health = await jfetch(`${BASE}/health`);
    assert.strictEqual(health.status, 200);
    assert.strictEqual(health.data.ok, true);

    const debug = await jfetch(`${BASE}/debug/env`);
    assert.strictEqual(debug.status, 200);
  }

  // Signup/Login
  const email = `rbac_node_${Date.now()}_${Math.floor(Math.random() * 1e6)}@test.local`;
  const password = '12345678';
  const name = 'RBAC Node Test';

  {
    const signup = await jfetch(`${BASE}/auth/signup`, { method: 'POST', body: JSON.stringify({ email, password, name }) });
    assert.ok([201, 200].includes(signup.status));
  }
  let accessToken, refreshToken;
  {
    const login = await jfetch(`${BASE}/auth/login`, { method: 'POST', body: JSON.stringify({ email, password }) });
    assert.strictEqual(login.status, 200);
    accessToken = login.data?.access_token;
    refreshToken = login.data?.refresh_token;
    assert.ok(accessToken, 'access_token deve existir');
    assert.ok(refreshToken, 'refresh_token deve existir');
  }

  // RBAC negativo: deve retornar 403
  {
    const rbacNeg = await jfetch(`${BASE}/test/seed-outbox`, {
      method: 'POST',
      body: JSON.stringify({ phone: '+5511999999999', message: 'RBAC test' }),
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    assert.strictEqual(rbacNeg.status, 403);
  }

  // Bypass via x-api-key: 200
  {
    const bypass = await jfetch(`${BASE}/test/seed-outbox`, {
      method: 'POST',
      body: JSON.stringify({ phone: '+551199998888', message: 'Stub queue' }),
      headers: { 'x-api-key': API_KEY },
    });
    assert.strictEqual(bypass.status, 200);
  }

  // Envio stub direto
  {
    const sendStub = await jfetch(`${BASE}/test/send-whatsapp`, {
      method: 'POST',
      body: JSON.stringify({ phone: '+5511999990000', message: 'Stub send' }),
      headers: { 'x-api-key': API_KEY },
    });
    assert.strictEqual(sendStub.status, 200);
  }

  // Refresh
  {
    const refresh = await jfetch(`${BASE}/auth/refresh`, { method: 'POST', body: JSON.stringify({ refresh_token: refreshToken }) });
    assert.strictEqual(refresh.status, 200);
    assert.ok(refresh.data?.access_token, 'novo access_token deve existir');
  }

  // Logout
  {
    const logout = await jfetch(`${BASE}/auth/logout`, { method: 'POST', body: JSON.stringify({}), headers: { Authorization: `Bearer ${accessToken}` } });
    assert.strictEqual(logout.status, 200);
    assert.strictEqual(logout.data?.ok, true);
  }
});

// Teste RBAC-only (sem Supabase): negativo 403 e bypass 200
test('RBAC-only: 403 sem permissão e 200 com x-api-key', async () => {
  // Health
  const health = await jfetch(`${BASE}/health`);
  assert.strictEqual(health.status, 200);

  // Token falso para forçar sub e checagem de role -> 403
  const fakeToken = makeFakeJwt('rbac-ci-user');
  const rbacNeg = await jfetch(`${BASE}/test/seed-outbox`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+551100000000', message: 'RBAC-only test' }),
    headers: { Authorization: `Bearer ${fakeToken}` },
  });
  assert.strictEqual(rbacNeg.status, 403);

  // Bypass via API key
  const bypass = await jfetch(`${BASE}/test/seed-outbox`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+551199998888', message: 'Stub queue' }),
    headers: { 'x-api-key': API_KEY },
  });
  assert.strictEqual(bypass.status, 200);
});