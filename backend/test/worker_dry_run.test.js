const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const { spawn } = require('node:child_process');
require('dotenv').config();

const HAVE_SUPABASE = Boolean(process.env.SUPABASE_URL && (process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY) && process.env.SUPABASE_SERVICE_ROLE_KEY);

function isoDateTodayPlus(days = 0) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

async function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// Testa o worker em DRY_RUN: cria outbox Pending e verifica marcação Sent
// Requer Supabase configurado
test('Worker: DRY_RUN processa Pending e marca como Sent', async (t) => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');

  // 1) Seed mínimo: network, unit, student, invoice
  const { data: netRows, error: netErr } = await supabase
    .from('networks')
    .insert({ name: `Net Worker ${Date.now()}`, description: 'Net for worker test' })
    .select('id').limit(1);
  assert.ok(!netErr, `Erro network: ${netErr && netErr.message}`);
  const networkId = netRows?.[0]?.id; assert.ok(networkId, 'networkId ausente');

  const { data: unitRows, error: unitErr } = await supabase
    .from('units')
    .insert({ network_id: networkId, name: `Unidade Worker ${Date.now()}`, repass_type: 'Percentual', repass_value: 0 })
    .select('id').limit(1);
  assert.ok(!unitErr, `Erro unit: ${unitErr && unitErr.message}`);
  const unitId = unitRows?.[0]?.id; assert.ok(unitId, 'unitId ausente');

  const { data: stuRows, error: stuErr } = await supabase
    .from('students')
    .insert({ name: 'Aluno Worker', start_date: isoDateTodayPlus(-1), unit_id: unitId, payment_method: 'PIX', guardian_phone: '+5511998887777' })
    .select('id').limit(1);
  assert.ok(!stuErr, `Erro student: ${stuErr && stuErr.message}`);
  const studentId = stuRows?.[0]?.id; assert.ok(studentId, 'studentId ausente');

  const { data: invRows, error: invErr } = await supabase
    .from('invoices')
    .insert({ student_id: studentId, unit_id: unitId, due_date: isoDateTodayPlus(2), amount_total: 50, amount_discount: 5, amount_net: 45, payment_method: 'PIX', status: 'Aberta' })
    .select('id').limit(1);
  assert.ok(!invErr, `Erro invoice: ${invErr && invErr.message}`);
  const invoiceId = invRows?.[0]?.id; assert.ok(invoiceId, 'invoiceId ausente');

  // 2) Enfileira WhatsApp para a fatura
  const { data: outboxId, error: queueErr } = await supabase.rpc('queue_invoice_whatsapp', { p_invoice_id: invoiceId, p_phone_override: null });
  assert.ok(!queueErr, `Erro queue: ${queueErr && queueErr.message}`);
  assert.ok(outboxId, 'outboxId ausente');

  // Tornar nosso item o mais antigo para ser priorizado pelo worker
  await supabase.from('whatsapp_outbox').update({ created_at: '1970-01-01T00:00:00Z' }).eq('id', outboxId);

  const { data: before, error: beforeErr } = await supabase
    .from('whatsapp_outbox')
    .select('id,status,attempts')
    .eq('id', outboxId)
    .maybeSingle();
  assert.ok(!beforeErr, `Erro outbox fetch: ${beforeErr && beforeErr.message}`);
  assert.ok(before && before.status === 'Pending', 'outbox não está Pending');

  // 3) Spawn do worker com DRY_RUN=true e intervalo curto
  const backendDir = path.resolve(__dirname, '..');
  const child = spawn('node', ['src/worker.js'], {
    cwd: backendDir,
    env: {
      ...process.env,
      DRY_RUN: 'true',
      WORKER_INTERVAL_MS: '300',
      WORKER_BATCH_SIZE: '5',
      SUPABASE_URL: process.env.SUPABASE_URL,
      SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
      SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
      VITE_SUPABASE_ANON_KEY: process.env.VITE_SUPABASE_ANON_KEY,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let logs = '';
  child.stdout.on('data', (d) => { logs += d.toString(); });
  child.stderr.on('data', (d) => { logs += d.toString(); });

  // 4) Poll até marcar como Sent ou timeout
  let status = 'Pending';
  let attempts = before.attempts || 0;
  const timeoutMs = 15000;
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    await sleep(500);
    const { data: row, error } = await supabase
      .from('whatsapp_outbox')
      .select('id,status,attempts')
      .eq('id', outboxId)
      .maybeSingle();
    if (!error && row) {
      status = row.status;
      attempts = row.attempts;
      if (status === 'Sent') break;
    }
  }

  try {
    child.kill('SIGINT');
  } catch {}

  assert.strictEqual(status, 'Sent', `Status esperado Sent; logs=\n${logs}`);
  assert.ok((attempts || 0) >= ((before.attempts || 0) + 1), 'Attempts não incrementou');
});