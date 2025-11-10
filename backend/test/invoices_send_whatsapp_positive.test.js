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

// Teste positivo: cria dados mínimos (network, unit, student, invoice) e envia via invoices/:id
// Requer Supabase configurado; usa provider 'stub' e bypass por x-api-key
test('Invoices: positivo 200 com dados reais e x-api-key (stub provider)', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');
  const apiKey = process.env.API_KEY || 'dev-key';

  // 1) Criar network
  const netName = `Net Test ${Date.now()}`;
  const { data: netRows, error: netErr } = await supabase
    .from('networks')
    .insert({ name: netName, description: 'Test Network' })
    .select('id')
    .limit(1);
  assert.ok(!netErr, `Erro network: ${netErr && netErr.message}`);
  const networkId = netRows && netRows[0] && netRows[0].id;
  assert.ok(networkId, 'networkId ausente');

  // 2) Criar unit
  const unitName = `Unidade Test ${Date.now()}`;
  const { data: unitRows, error: unitErr } = await supabase
    .from('units')
    .insert({ network_id: networkId, name: unitName, repass_type: 'Percentual', repass_value: 0 })
    .select('id')
    .limit(1);
  assert.ok(!unitErr, `Erro unit: ${unitErr && unitErr.message}`);
  const unitId = unitRows && unitRows[0] && unitRows[0].id;
  assert.ok(unitId, 'unitId ausente');

  // 3) Criar student
  const { data: stuRows, error: stuErr } = await supabase
    .from('students')
    .insert({ name: 'Aluno Teste', start_date: isoDateTodayPlus(-7), unit_id: unitId, payment_method: 'PIX', guardian_phone: '+5511991112222' })
    .select('id')
    .limit(1);
  assert.ok(!stuErr, `Erro student: ${stuErr && stuErr.message}`);
  const studentId = stuRows && stuRows[0] && stuRows[0].id;
  assert.ok(studentId, 'studentId ausente');

  // 4) Criar invoice (usar due_date futuro, amounts e payment_method obrigatórios)
  const dueDate = isoDateTodayPlus(3);
  const { data: invRows, error: invErr } = await supabase
    .from('invoices')
    .insert({ student_id: studentId, unit_id: unitId, due_date: dueDate, amount_total: 100, amount_discount: 10, amount_net: 90, payment_method: 'PIX', status: 'Aberta' })
    .select('id')
    .limit(1);
  assert.ok(!invErr, `Erro invoice: ${invErr && invErr.message}`);
  const invoiceId = invRows && invRows[0] && invRows[0].id;
  assert.ok(invoiceId, 'invoiceId ausente');

  // 5) Chamar rota com override de phone e x-api-key (bypass RBAC)
  const res = await jfetch(`${BASE}/invoices/${invoiceId}/send-whatsapp`, {
    method: 'POST',
    body: JSON.stringify({ phone: '+5511880000000' }),
    headers: { 'x-api-key': apiKey },
  });
  assert.strictEqual(res.status, 200);
  assert.ok(res.data && res.data.status === 'Sent');
  assert.ok(res.data && res.data.outboxId, 'outboxId ausente');

  // 6) Verificar status Sent na outbox
  const { data: outboxRow, error: outErr } = await supabase
    .from('whatsapp_outbox')
    .select('id,status')
    .eq('id', res.data.outboxId)
    .maybeSingle();
  assert.ok(!outErr, `Erro outbox fetch: ${outErr && outErr.message}`);
  assert.ok(outboxRow && outboxRow.status === 'Sent', 'outbox não está Sent');
});