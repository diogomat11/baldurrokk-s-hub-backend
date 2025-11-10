const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();
const path = require('node:path');
const { execFile } = require('node:child_process');
const { spawn } = require('node:child_process');

const HAVE_SUPABASE = Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);

function isoDateToday() {
  const d = new Date();
  return d.toISOString().slice(0, 10);
}

// Testa retry com send_latest_whatsapp: cria invoice com outbox Failed e
// executa o script com RETRY_FAILED=true para reenviar (stub provider ok)
// Requer Supabase configurado e API rodando (npm run dev)
test('send_latest_whatsapp: retryFailed envia invoice com outbox Failed (stub provider)', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');

  const apiKey = process.env.API_KEY || 'dev-key';
  const unitName = `Unit Retry ${Date.now()}`;
  const netName = `Net Retry ${Date.now()}`;
  const port = 3002;
  const baseUrl = `http://localhost:${port}`;
  // Executa servidor dedicado para este teste
  const backendDir = path.resolve(__dirname, '..');
  const server = spawn(process.execPath, ['src/server.js'], {
    cwd: backendDir,
    env: { ...process.env, PORT: String(port), API_KEY: apiKey },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const ready = await waitHealth(baseUrl, 40, 250);
  assert.ok(ready, 'Servidor não respondeu /health');

  try {
  // Seed: network, unit, student, invoice
  const { data: netRows, error: netErr } = await supabase
    .from('networks')
    .insert({ name: netName, description: 'Retry Network' })
    .select('id').limit(1);
  assert.ok(!netErr, `Erro network: ${netErr && netErr.message}`);
  const networkId = netRows?.[0]?.id; assert.ok(networkId, 'networkId ausente');

  const { data: unitRows, error: unitErr } = await supabase
    .from('units')
    .insert({ network_id: networkId, name: unitName, repass_type: 'Percentual', repass_value: 0 })
    .select('id').limit(1);
  assert.ok(!unitErr, `Erro unit: ${unitErr && unitErr.message}`);
  const unitId = unitRows?.[0]?.id; assert.ok(unitId, 'unitId ausente');

  const { data: stuRows, error: stuErr } = await supabase
    .from('students')
    .insert({ name: 'Aluno Retry', start_date: isoDateToday(), unit_id: unitId, payment_method: 'PIX', guardian_phone: '+5511995554443' })
    .select('id').limit(1);
  assert.ok(!stuErr, `Erro student: ${stuErr && stuErr.message}`);
  const studentId = stuRows?.[0]?.id; assert.ok(studentId, 'studentId ausente');

  const { data: invRows, error: invErr } = await supabase
    .from('invoices')
    .insert({ student_id: studentId, unit_id: unitId, due_date: isoDateToday(), amount_total: 80, amount_discount: 0, amount_net: 80, payment_method: 'PIX', status: 'Aberta' })
    .select('id').limit(1);
  assert.ok(!invErr, `Erro invoice: ${invErr && invErr.message}`);
  const invoiceId = invRows?.[0]?.id; assert.ok(invoiceId, 'invoiceId ausente');

  // Criar outbox Failed para a invoice
  const { data: outboxId, error: queueErr } = await supabase.rpc('queue_invoice_whatsapp', { p_invoice_id: invoiceId, p_phone_override: null });
  assert.ok(!queueErr, `Erro queue: ${queueErr && queueErr.message}`);
  assert.ok(outboxId, 'outboxId ausente');
  const { error: failErr } = await supabase.rpc('mark_whatsapp_failed', { p_outbox_id: outboxId, p_error: 'network_error' });
  assert.ok(!failErr, `Erro mark_failed: ${failErr && failErr.message}`);

  // Executa script para retry (não dry-run), limitado à nossa unidade
  const env = {
    ...process.env,
    RETRY_FAILED: 'true',
    MAX_ATTEMPTS: '2',
    UNIT_NAME: unitName,
    ONLY_OPEN: 'false',
    LIMIT: '1',
    LOG_DETAILS: 'false',
    API_KEY: apiKey,
    PORT: String(port),
    DRY_RUN_SEND: 'false',
  };
  const backendDir = path.resolve(__dirname, '..');
  const { stdout } = await new Promise((resolve, reject) => {
    const child = execFile(process.execPath, ['src/send_latest_whatsapp.js'], { cwd: backendDir, env }, (error, stdout, stderr) => {
      if (error) return reject({ error, stdout, stderr });
      resolve({ stdout, stderr });
    });
    setTimeout(() => { try { child.kill('SIGTERM'); } catch {} }, 30000);
  });

  assert.ok(stdout.includes('[send-latest] params'), 'logs params ausente');
  assert.ok(stdout.includes('[send-latest] summary'), 'summary ausente');

  // Verifica que a última outbox da invoice agora está Sent
  const { data: lastRows, error: lastErr } = await supabase
    .from('whatsapp_outbox')
    .select('id,status,attempts')
    .eq('invoice_id', invoiceId)
    .order('created_at', { ascending: false })
    .limit(1);
  assert.ok(!lastErr, `Erro outbox fetch: ${lastErr && lastErr.message}`);
  const last = lastRows && lastRows[0];
  assert.ok(last, 'outbox last ausente');
  assert.ok((last.attempts || 0) >= 1, 'Attempts do envio não incrementou');
  } finally {
    try { server.kill('SIGINT'); } catch {}
  }
});


async function waitHealth(baseUrl, tries = 20, intervalMs = 250) {
  for (let i = 0; i < tries; i++) {
    try {
      const res = await fetch(`${baseUrl}/health`);
      if (res.ok) return true;
    } catch {}
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}