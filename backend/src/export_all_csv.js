require('dotenv').config();
const path = require('path');
const { spawn } = require('child_process');

function runNode(scriptRelPath, envVars, label) {
  return new Promise((resolve) => {
    const scriptPath = path.join(__dirname, scriptRelPath);
    const start = Date.now();
    const child = spawn('node', [scriptPath], {
      env: { ...process.env, ...envVars },
      stdio: 'inherit',
    });
    child.on('exit', (code) => {
      const ms = Date.now() - start;
      console.log(`[export:all] ${label} exit code=${code} duration=${ms}ms`);
      resolve({ code, ms, label });
    });
  });
}

(async () => {
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const { start: defaultStart, end: defaultEnd } = (() => {
    const d = new Date();
    const y = d.getUTCFullYear();
    const m = d.getUTCMonth();
    const s = new Date(Date.UTC(y, m, 1)).toISOString().slice(0, 10);
    const e = new Date(Date.UTC(y, m + 1, 0)).toISOString().slice(0, 10);
    return { start: s, end: e };
  })();
  const start = process.env.START_DATE || defaultStart;
  const end = process.env.END_DATE || defaultEnd;
  const onlyOpen = String(process.env.ONLY_OPEN || 'false') === 'true';

  console.log('[export:all] params', { unitName, start, end, onlyOpen });

  const results = [];

  // Invoices
  results.push(await runNode('export_invoices_csv.js', {
    UNIT_NAME: unitName,
    START_DATE: start,
    END_DATE: end,
    ONLY_OPEN: String(onlyOpen),
  }, 'invoices'));

  // Expenses
  results.push(await runNode('export_expenses_csv.js', {
    UNIT_NAME: unitName,
    START_DATE: start,
    END_DATE: end,
    ONLY_OPEN: String(onlyOpen),
  }, 'expenses'));

  // Repasses (Equipe - todos profissionais)
  results.push(await runNode('export_repasses_csv.js', {
    REPASS_ENTITY: 'Equipe',
    UNIT_NAME: unitName,
    PROFESSIONAL_NAME: '',
    START_DATE: start,
    END_DATE: end,
    ONLY_OPEN: String(onlyOpen),
  }, 'repasses_equipe'));

  // Repasses (Unidade)
  results.push(await runNode('export_repasses_csv.js', {
    REPASS_ENTITY: 'Unidade',
    UNIT_NAME: unitName,
    START_DATE: start,
    END_DATE: end,
    ONLY_OPEN: String(onlyOpen),
  }, 'repasses_unidade'));

  console.log('[export:all] summary');
  for (const r of results) {
    console.log(` - ${r.label}: code=${r.code} time=${r.ms}ms`);
  }
})();