const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();
const crypto = require('crypto');

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
  return { status: res.status, data, text, headers: res.headers };
}

function makeSignature(secret, body) {
  const hmac = crypto.createHmac('sha256', secret)
    .update(JSON.stringify(body || {}))
    .digest('hex');
  return `sha256=${hmac}`;
}

test('Webhook POST estrito: 200 com assinatura correta; 403 com incorreta', async () => {
  const secret = process.env.META_APP_SECRET || null;
  const strict = String(process.env.STRICT_WEBHOOK_SIGNATURE || 'false') === 'true';
  if (!secret || !strict) return;

  const body = { entry: [{ id: 'abc', changes: [{ field: 'messages' }] }] };
  const goodSig = makeSignature(secret, body);
  const badSig = 'sha256=deadbeef';

  const okRes = await jfetch(`${BASE}/webhook/whatsapp`, {
    method: 'POST',
    body: JSON.stringify(body),
    headers: { 'x-hub-signature-256': goodSig },
  });
  assert.strictEqual(okRes.status, 200);
  assert.ok(okRes.data && okRes.data.ok === true);

  const badRes = await jfetch(`${BASE}/webhook/whatsapp`, {
    method: 'POST',
    body: JSON.stringify(body),
    headers: { 'x-hub-signature-256': badSig },
  });
  assert.strictEqual(badRes.status, 403);
  assert.ok(badRes.data && badRes.data.error === 'invalid_signature');
});