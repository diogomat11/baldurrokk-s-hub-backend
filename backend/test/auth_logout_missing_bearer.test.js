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
  return { status: res.status, data, text };
}

test('Auth/logout: 400 quando falta Bearer token', async () => {
  const res = await jfetch(`${BASE}/auth/logout`, { method: 'POST' });
  assert.strictEqual(res.status, 400);
});