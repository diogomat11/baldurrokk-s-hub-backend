require('dotenv').config();
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
  const category = process.env.EXPENSE_CATEGORY || 'Material';
  const description = process.env.EXPENSE_DESCRIPTION || 'Bolas de treino';
  const amount = parseFloat(process.env.EXPENSE_AMOUNT || '350');
  const { start: defaultStart } = monthBounds(new Date());
  const expenseDate = process.env.EXPENSE_DATE || defaultStart;

  console.log('[seed:expense] params', { unitName, category, description, amount, expenseDate });

  const { data: unit, error: unitErr } = await supabase
    .from('units')
    .select('id,name')
    .eq('name', unitName)
    .limit(1)
    .maybeSingle();
  if (unitErr) throw new Error(unitErr.message);
  if (!unit) {
    console.error('[seed:expense] unit not found', unitName);
    process.exit(1);
  }

  const { data: inserted, error: insErr } = await supabase
    .from('expenses')
    .insert({ unit_id: unit.id, category, description, amount, expense_date: expenseDate, status: 'Aberta' })
    .select('id');
  if (insErr) throw insErr;

  console.log('[seed:expense] created', inserted?.[0]?.id || null);
})();