const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();

const BASE = process.env.BASE_URL || 'http://localhost:3001';

async function jfetch(url, opts = {}) {
  const res = await fetch(url, {
    ...opts,
    headers: {
      ...(opts.headers || {}),
    },
  });
  const text = await res.text();
  return { status: res.status, text };
}

test('Webhook GET: modo diferente de subscribe retorna 403 sempre', async () => {
  const verify = process.env.WHATSAPP_VERIFY_TOKEN || 'any';
  const res = await jfetch(`${BASE}/webhook/whatsapp?hub.mode=status&hub.verify_token=${verify}&hub.challenge=xyz`, { method: 'GET' });
  assert.strictEqual(res.status, 403);
});