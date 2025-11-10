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

function randInt(min, max) { return Math.floor(Math.random() * (max - min + 1)) + min; }
function randFloat(min, max) { return Math.round((Math.random() * (max - min) + min) * 100) / 100; }

function randDateStr(startStr, endStr) {
  const s = new Date(startStr);
  const e = new Date(endStr);
  const diff = e - s;
  const offset = Math.floor(Math.random() * (diff + 1));
  const d = new Date(s.getTime() + offset);
  return d.toISOString().slice(0, 10);
}

(async () => {
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const count = parseInt(process.env.COUNT || '50', 10);
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = process.env.START_DATE || defaultStart;
  const end = process.env.END_DATE || defaultEnd;
  const amountMin = parseFloat(process.env.AMOUNT_MIN || '100');
  const amountMax = parseFloat(process.env.AMOUNT_MAX || '500');
  const categoriesEnv = process.env.CATEGORIES || 'Material,Serviços,Transporte,Outros';
  const categories = categoriesEnv.split(',').map((c) => c.trim()).filter(Boolean);

  console.log('[bulk:expenses] params', { unitName, count, start, end, amountMin, amountMax, categories });

  const { data: unit, error: unitErr } = await supabase
    .from('units')
    .select('id,name')
    .eq('name', unitName)
    .limit(1)
    .maybeSingle();
  if (unitErr) throw new Error(unitErr.message);
  if (!unit) {
    console.error('[bulk:expenses] unit not found', unitName);
    process.exit(1);
  }

  const rows = Array.from({ length: count }, () => {
    const cat = categories[randInt(0, categories.length - 1)];
    const desc = `${cat} ${randInt(1, 999)}`;
    const amt = randFloat(amountMin, amountMax);
    const dateStr = randDateStr(start, end);
    return {
      unit_id: unit.id,
      category: cat,
      description: desc,
      amount: amt,
      expense_date: dateStr,
      status: 'Aberta'
    };
  });

  const { data, error } = await supabase
    .from('expenses')
    .insert(rows)
    .select('id');
  if (error) throw error;

  console.log('[bulk:expenses] inserted', data?.length || rows.length);
})();