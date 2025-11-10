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

// Testa MAX_ATTEMPTS=1: outbox Failed com attempts=1 deve ser pulado no retry
// e não deve criar um novo registro de outbox
// Requer Supabase configurado e API rodando
// Usa servidor dedicado na porta 3002
 test('send_latest_whatsapp: MAX_ATTEMPTS=1 faz skip sem novo outbox', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');

  const apiKey = process.env.API_KEY || 'dev-key';
  const unitName = `Unit MaxAttempts ${Date.now()}`;
  const netName = `Net MaxAttempts ${Date.now()}`;
  const port = 3002;
  const baseUrl = `http://localhost:${port}`;

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
      .insert({ name: netName, description: 'MaxAttempts Network' })
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
      .insert({ name: 'Aluno MaxAttempts', start_date: isoDateToday(), unit_id: unitId, payment_method: 'PIX', guardian_phone: '+5511995554443' })
      .select('id').limit(1);
    assert.ok(!stuErr, `Erro student: ${stuErr && stuErr.message}`);
    const studentId = stuRows?.[0]?.id; assert.ok(studentId, 'studentId ausente');

    const { data: invRows, error: invErr } = await supabase
      .from('invoices')
      .insert({ student_id: studentId, unit_id: unitId, due_date: isoDateToday(), amount_total: 80, amount_discount: 0, amount_net: 80, payment_method: 'PIX', status: 'Aberta' })
      .select('id').limit(1);
    assert.ok(!invErr, `Erro invoice: ${invErr && invErr.message}`);
    const invoiceId = invRows?.[0]?.id; assert.ok(invoiceId, 'invoiceId ausente');

    // Criar outbox Failed (attempts=1)
    const { data: outboxId, error: queueErr } = await supabase.rpc('queue_invoice_whatsapp', { p_invoice_id: invoiceId, p_phone_override: null });
    assert.ok(!queueErr, `Erro queue: ${queueErr && queueErr.message}`);
    assert.ok(outboxId, 'outboxId ausente');
    const { error: failErr } = await supabase.rpc('mark_whatsapp_failed', { p_outbox_id: outboxId, p_error: 'network_error' });
    assert.ok(!failErr, `Erro mark_failed: ${failErr && failErr.message}`);

    // Contagem antes
    const { count: beforeCount } = await supabase
      .from('whatsapp_outbox')
      .select('id', { count: 'exact', head: true })
      .eq('invoice_id', invoiceId);

    // Executa script com MAX_ATTEMPTS=1 e retry
    const env = {
      ...process.env,
      RETRY_FAILED: 'true',
      MAX_ATTEMPTS: '1',
      UNIT_NAME: unitName,
      ONLY_OPEN: 'false',
      LIMIT: '1',
      LOG_DETAILS: 'false',
      API_KEY: apiKey,
      PORT: String(port),
      DRY_RUN_SEND: 'false',
    };
    const { stdout } = await new Promise((resolve, reject) => {
      const child = execFile(process.execPath, ['src/send_latest_whatsapp.js'], { cwd: backendDir, env }, (error, stdout, stderr) => {
        if (error) return reject({ error, stdout, stderr });
        resolve({ stdout, stderr });
      });
      setTimeout(() => { try { child.kill('SIGTERM'); } catch {} }, 30000);
    });

    assert.ok(stdout.includes('[send-latest] params'), 'logs params ausente');
    assert.ok(stdout.includes('[send-latest] summary'), 'summary ausente');

    // Contagem depois
    const { count: afterCount } = await supabase
      .from('whatsapp_outbox')
      .select('id', { count: 'exact', head: true })
      .eq('invoice_id', invoiceId);

    assert.strictEqual(afterCount, beforeCount, 'Foi criado novo outbox indevidamente com MAX_ATTEMPTS=1');

    // Último permanece Failed com attempts=1
    const { data: lastRows, error: lastErr } = await supabase
      .from('whatsapp_outbox')
      .select('id,status,attempts')
      .eq('invoice_id', invoiceId)
      .order('created_at', { ascending: false })
      .limit(1);
    assert.ok(!lastErr, `Erro outbox fetch: ${lastErr && lastErr.message}`);
    const last = lastRows && lastRows[0];
    assert.ok(last, 'outbox last ausente');
    assert.strictEqual(last.status, 'Failed', 'Última outbox não está Failed');
    assert.strictEqual(last.attempts, 1, 'Attempts não é 1 em MAX_ATTEMPTS=1');
  } finally {
    try { server.kill('SIGINT'); } catch {}
  }
});