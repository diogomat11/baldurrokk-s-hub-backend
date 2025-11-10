require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { supabase } = require('./supabase');

function monthBounds(date = new Date()) {
  const y = date.getUTCFullYear();
  const m = date.getUTCMonth();
  const start = new Date(Date.UTC(y, m, 1));
  const end = new Date(Date.UTC(y, m + 1, 0));
  const iso = (d) => d.toISOString().slice(0, 10);
  return { start: iso(start), end: iso(end) };
}

(async () => {
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const onlyOpen = String(process.env.ONLY_OPEN || 'false') === 'true';
  const startEnv = process.env.START_DATE || null;
  const endEnv = process.env.END_DATE || null;
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = startEnv || defaultStart;
  const end = endEnv || defaultEnd;

  console.log('[export:expenses] params', { unitName, start, end, onlyOpen });

  const { data: unit, error: unitErr } = await supabase
    .from('units')
    .select('id,name')
    .eq('name', unitName)
    .limit(1)
    .maybeSingle();
  if (unitErr) throw new Error(unitErr.message);
  if (!unit) {
    console.error('[export:expenses] unit not found', unitName);
    process.exit(1);
  }

  let expQuery = supabase
    .from('expenses')
    .select('id, unit_id, category, description, amount, expense_date, status, created_at, updated_at')
    .eq('unit_id', unit.id)
    .gte('expense_date', start)
    .lte('expense_date', end)
    .order('expense_date', { ascending: true });
  if (onlyOpen) expQuery = expQuery.eq('status', 'Aberta');

  const { data: expenses, error: expErr } = await expQuery;
  if (expErr) throw new Error(expErr.message);
  if (!expenses || expenses.length === 0) {
    console.log('[export:expenses] no expenses in range');
    process.exit(0);
  }

  const rows = expenses.map((e) => ({
    expense_id: e.id,
    unit_name: unit.name,
    category: e.category || '',
    description: e.description || '',
    amount: e.amount,
    expense_date: e.expense_date,
    status: e.status,
    created_at: e.created_at,
    updated_at: e.updated_at,
  }));

  const headers = [
    'expense_id',
    'unit_name',
    'category',
    'description',
    'amount',
    'expense_date',
    'status',
    'created_at',
    'updated_at',
  ];
  const toCsvRow = (obj) => headers
    .map((h) => {
      const v = obj[h];
      const s = v === null || v === undefined ? '' : String(v);
      const needsQuote = s.includes(',') || s.includes('"') || s.includes('\n');
      const escaped = s.replace(/"/g, '""');
      return needsQuote ? `"${escaped}"` : escaped;
    })
    .join(',');

  const csv = [headers.join(','), ...rows.map(toCsvRow)].join('\n');

  const outNameSafe = unit.name.replace(/[^a-zA-Z0-9_-]+/g, '_');
  const outFile = path.join(__dirname, '..', 'tmp', `expenses_${outNameSafe}_${start}_to_${end}.csv`);
  await fs.promises.mkdir(path.dirname(outFile), { recursive: true });
  await fs.promises.writeFile(outFile, csv, 'utf8');

  console.log('[export:expenses] written', outFile, 'rows=', rows.length);
})();