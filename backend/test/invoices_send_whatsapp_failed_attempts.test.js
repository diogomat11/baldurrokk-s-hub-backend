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

function isoDateTodayPlus(days = 0) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

// Valida que falha do provider incrementa attempts (=1) e status Failed
// via invoices/:id/send-whatsapp com override de telefone inválido
// Requer Supabase e dev server rodando em 3001
test('Invoices: Failed incrementa attempts=1 com telefone inválido (stub provider)', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');
  const apiKey = process.env.API_KEY || 'dev-key';

  // 1) Criar network
  const netName = `Net Attempts ${Date.now()}`;
  const { data: netRows, error: netErr } = await supabase
    .from('networks')
    .insert({ name: netName, description: 'Attempts Network' })
    .select('id').limit(1);
  assert.ok(!netErr, `Erro network: ${netErr && netErr.message}`);
  const networkId = netRows?.[0]?.id; assert.ok(networkId, 'networkId ausente');

  // 2) Criar unit
  const unitName = `Unit Attempts ${Date.now()}`;
  const { data: unitRows, error: unitErr } = await supabase
    .from('units')
    .insert({ network_id: networkId, name: unitName, repass_type: 'Percentual', repass_value: 0 })
    .select('id').limit(1);
  assert.ok(!unitErr, `Erro unit: ${unitErr && unitErr.message}`);
  const unitId = unitRows?.[0]?.id; assert.ok(unitId, 'unitId ausente');

  // 3) Criar student (phone válido, vamos override com inválido)
  const { data: stuRows, error: stuErr } = await supabase
    .from('students')
    .insert({ name: 'Aluno Attempts', start_date: isoDateTodayPlus(-3), unit_id: unitId, payment_method: 'PIX', guardian_phone: '+5511991112222' })
    .select('id').limit(1);
  assert.ok(!stuErr, `Erro student: ${stuErr && stuErr.message}`);
  const studentId = stuRows?.[0]?.id; assert.ok(studentId, 'studentId ausente');

  // 4) Criar invoice
  const { data: invRows, error: invErr } = await supabase
    .from('invoices')
    .insert({ student_id: studentId, unit_id: unitId, due_date: isoDateTodayPlus(2), amount_total: 120, amount_discount: 0, amount_net: 120, payment_method: 'PIX', status: 'Aberta' })
    .select('id').limit(1);
  assert.ok(!invErr, `Erro invoice: ${invErr && invErr.message}`);
  const invoiceId = invRows?.[0]?.id; assert.ok(invoiceId, 'invoiceId ausente');

  // 5) Chamar rota com override de telefone inválido
  const res = await jfetch(`${BASE}/invoices/${invoiceId}/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: 'invalid' }),
    headers: { 'x-api-key': apiKey },
  });
  assert.strictEqual(res.status, 502);
  assert.ok(res.data && res.data.status === 'Failed');
  assert.ok(res.data && res.data.outboxId, 'outboxId ausente');
  assert.ok(res.data && res.data.error === 'invalid_phone', 'erro esperado invalid_phone');

  // 6) Verificar attempts=1 e status Failed
  const { data: outboxRow, error: outErr } = await supabase
    .from('whatsapp_outbox')
    .select('id,status,attempts,last_attempt_at,error')
    .eq('id', res.data.outboxId)
    .maybeSingle();
  assert.ok(!outErr, `Erro outbox fetch: ${outErr && outErr.message}`);
  assert.ok(outboxRow && outboxRow.status === 'Failed', 'outbox não está Failed');
  assert.strictEqual(outboxRow.attempts, 1, 'attempts não foi incrementado para 1');
  assert.ok(outboxRow.last_attempt_at, 'last_attempt_at não foi preenchido');
  assert.strictEqual(outboxRow.error, 'invalid_phone');
});