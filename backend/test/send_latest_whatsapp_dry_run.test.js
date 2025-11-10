const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();
const path = require('node:path');
const { execFile } = require('node:child_process');

const HAVE_SUPABASE = Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);

function isoDateToday() {
  const d = new Date();
  return d.toISOString().slice(0, 10);
}

// Roda o script send_latest_whatsapp.js em DRY-RUN com dados mínimos sem depender da API
// O teste só executa se o Supabase estiver configurado
test('send_latest_whatsapp: dry-run com seed mínimo', async () => {
  if (!HAVE_SUPABASE) return;
  const { supabase } = require('../src/supabase');

  const unitName = `Unit DryRun ${Date.now()}`;
  const netName = `Net DryRun ${Date.now()}`;

  // Seed básico: network, unit, student, invoice
  const { data: netRows, error: netErr } = await supabase
    .from('networks')
    .insert({ name: netName, description: 'DryRun Network' })
    .select('id')
    .limit(1);
  assert.ok(!netErr, `Erro network: ${netErr && netErr.message}`);
  const networkId = netRows && netRows[0] && netRows[0].id;
  assert.ok(networkId, 'networkId ausente');

  const { data: unitRows, error: unitErr } = await supabase
    .from('units')
    .insert({ network_id: networkId, name: unitName, repass_type: 'Percentual', repass_value: 0 })
    .select('id')
    .limit(1);
  assert.ok(!unitErr, `Erro unit: ${unitErr && unitErr.message}`);
  const unitId = unitRows && unitRows[0] && unitRows[0].id;
  assert.ok(unitId, 'unitId ausente');

  const { data: stuRows, error: stuErr } = await supabase
    .from('students')
    .insert({ name: 'Aluno DryRun', start_date: isoDateToday(), unit_id: unitId, payment_method: 'PIX', guardian_phone: '+5511987654321' })
    .select('id')
    .limit(1);
  assert.ok(!stuErr, `Erro student: ${stuErr && stuErr.message}`);
  const studentId = stuRows && stuRows[0] && stuRows[0].id;
  assert.ok(studentId, 'studentId ausente');

  const { data: invRows, error: invErr } = await supabase
    .from('invoices')
    .insert({ student_id: studentId, unit_id: unitId, due_date: isoDateToday(), amount_total: 100, amount_discount: 0, amount_net: 100, payment_method: 'PIX', status: 'Aberta' })
    .select('id')
    .limit(1);
  assert.ok(!invErr, `Erro invoice: ${invErr && invErr.message}`);
  const invoiceId = invRows && invRows[0] && invRows[0].id;
  assert.ok(invoiceId, 'invoiceId ausente');

  // Executa script em DRY-RUN e valida logs
  const env = {
    ...process.env,
    DRY_RUN_SEND: 'true',
    UNIT_NAME: unitName,
    ONLY_OPEN: 'false',
    LIMIT: '2',
    LOG_DETAILS: 'false',
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
});