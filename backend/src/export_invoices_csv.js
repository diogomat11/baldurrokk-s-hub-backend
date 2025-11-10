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

  console.log('[export] params', { unitName, start, end, onlyOpen });

  const { data: unit, error: unitErr } = await supabase
    .from('units')
    .select('id,name')
    .eq('name', unitName)
    .limit(1)
    .maybeSingle();
  if (unitErr) throw new Error(unitErr.message);
  if (!unit) {
    console.error('[export] unit not found', unitName);
    process.exit(1);
  }

  let invQuery = supabase
    .from('invoices')
    .select('id, student_id, unit_id, status, due_date, amount_total, amount_discount, amount_net, paid_at')
    .eq('unit_id', unit.id)
    .gte('due_date', start)
    .lte('due_date', end)
    .order('due_date', { ascending: true });
  if (onlyOpen) invQuery = invQuery.eq('status', 'Aberta');
  const { data: invoices, error: invErr } = await invQuery;
  if (invErr) throw new Error(invErr.message);
  if (!invoices || invoices.length === 0) {
    console.log('[export] no invoices in range');
    process.exit(0);
  }

  const studentIds = [...new Set(invoices.map((i) => i.student_id))];
  const { data: students, error: stuErr } = await supabase
    .from('students')
    .select('id, name, class_id, guardian_phone')
    .in('id', studentIds);
  if (stuErr) throw new Error(stuErr.message);
  const studentMap = new Map((students || []).map((s) => [s.id, s]));

  const classIds = [...new Set((students || []).map((s) => s.class_id).filter(Boolean))];
  const { data: classes, error: classErr } = await supabase
    .from('classes')
    .select('id, name')
    .in('id', classIds);
  if (classErr) throw new Error(classErr.message);
  const classMap = new Map((classes || []).map((c) => [c.id, c.name]));

  const rows = invoices.map((inv) => {
    const s = studentMap.get(inv.student_id) || {};
    const className = s.class_id ? (classMap.get(s.class_id) || '') : '';
    const dueMonth = (inv.due_date || '').slice(0, 7); // YYYY-MM
    return {
      invoice_id: inv.id,
      student_name: s.name || '',
      class_name: className,
      guardian_phone: s.guardian_phone || '',
      status: inv.status,
      due_date: inv.due_date,
      due_month: dueMonth,
      amount_total: inv.amount_total,
      amount_discount: inv.amount_discount,
      amount_net: inv.amount_net,
      paid_at: inv.paid_at || '',
    };
  });

  const headers = [
    'invoice_id',
    'student_name',
    'class_name',
    'guardian_phone',
    'status',
    'due_date',
    'due_month',
    'amount_total',
    'amount_discount',
    'amount_net',
    'paid_at',
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
  const outFile = path.join(__dirname, '..', 'tmp', `invoices_${outNameSafe}_${start}_to_${end}.csv`);
  await fs.promises.mkdir(path.dirname(outFile), { recursive: true });
  await fs.promises.writeFile(outFile, csv, 'utf8');

  console.log('[export] written', outFile, 'rows=', rows.length);
})();