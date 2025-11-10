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
  const entityType = process.env.REPASS_ENTITY || 'Unidade'; // 'Unidade' | 'Equipe'
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const professionalName = process.env.PROFESSIONAL_NAME || null;
  const onlyOpen = String(process.env.ONLY_OPEN || 'false') === 'true';
  const startEnv = process.env.START_DATE || null;
  const endEnv = process.env.END_DATE || null;
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = startEnv || defaultStart;
  const end = endEnv || defaultEnd;

  console.log('[export:repasses] params', { entityType, unitName, professionalName, start, end, onlyOpen });

  let filterEntityId = null;
  let entityLabel = '';

  if (entityType === 'Unidade') {
    const { data: unit, error: unitErr } = await supabase
      .from('units')
      .select('id,name')
      .eq('name', unitName)
      .limit(1)
      .maybeSingle();
    if (unitErr) throw new Error(unitErr.message);
    if (!unit) {
      console.error('[export:repasses] unit not found', unitName);
      process.exit(1);
    }
    filterEntityId = unit.id;
    entityLabel = unit.name;
  } else if (entityType === 'Equipe') {
    if (professionalName) {
      const { data: prof, error: profErr } = await supabase
        .from('professionals')
        .select('id,name')
        .eq('name', professionalName)
        .limit(1)
        .maybeSingle();
      if (profErr) throw new Error(profErr.message);
      if (!prof) {
        console.error('[export:repasses] professional not found', professionalName);
        process.exit(1);
      }
      filterEntityId = prof.id;
      entityLabel = prof.name;
    } else {
      entityLabel = 'Todos_Profissionais';
    }
  } else {
    console.error('[export:repasses] invalid REPASS_ENTITY, use "Unidade" or "Equipe"');
    process.exit(1);
  }

  let repQuery = supabase
    .from('repasses')
    .select('id, entity_type, entity_id, negotiation_id, period_start, period_end, gross_value, advance_deduction, net_value, status, paid_at, receipt_url')
    .eq('entity_type', entityType)
    .gte('period_start', start)
    .lte('period_end', end)
    .order('period_start', { ascending: true });
  if (filterEntityId) repQuery = repQuery.eq('entity_id', filterEntityId);
  if (onlyOpen) repQuery = repQuery.eq('status', 'Aberta');

  const { data: repasses, error: repErr } = await repQuery;
  if (repErr) throw new Error(repErr.message);
  if (!repasses || repasses.length === 0) {
    console.log('[export:repasses] no repasses in range');
    process.exit(0);
  }

  // Resolve entity names for Equipe (multiple) if needed
  let profMap = new Map();
  if (entityType === 'Equipe') {
    if (!filterEntityId) {
      const profIds = [...new Set(repasses.map((r) => r.entity_id))];
      const { data: profs, error: profsErr } = await supabase
        .from('professionals')
        .select('id,name')
        .in('id', profIds);
      if (profsErr) throw new Error(profsErr.message);
      profMap = new Map((profs || []).map((p) => [p.id, p.name]));
    } else {
      // Single professional label already known
      profMap.set(filterEntityId, entityLabel);
    }
  }

  const rows = repasses.map((r) => {
    let entityName = entityLabel;
    if (entityType === 'Equipe') {
      entityName = profMap.get(r.entity_id) || entityLabel;
    }
    return {
      repasse_id: r.id,
      entity_type: r.entity_type,
      entity_name: entityName || '',
      negotiation_id: r.negotiation_id || '',
      period_start: r.period_start,
      period_end: r.period_end,
      gross_value: r.gross_value,
      advance_deduction: r.advance_deduction,
      net_value: r.net_value,
      status: r.status,
      paid_at: r.paid_at || '',
      receipt_url: r.receipt_url || '',
    };
  });

  const headers = [
    'repasse_id',
    'entity_type',
    'entity_name',
    'negotiation_id',
    'period_start',
    'period_end',
    'gross_value',
    'advance_deduction',
    'net_value',
    'status',
    'paid_at',
    'receipt_url',
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

  const entitySafe = entityType.replace(/[^a-zA-Z0-9_-]+/g, '_');
  const labelSafe = (entityLabel || '').replace(/[^a-zA-Z0-9_-]+/g, '_');
  const outFile = path.join(__dirname, '..', 'tmp', `repasses_${entitySafe}_${labelSafe}_${start}_to_${end}.csv`);
  await fs.promises.mkdir(path.dirname(outFile), { recursive: true });
  await fs.promises.writeFile(outFile, csv, 'utf8');

  console.log('[export:repasses] written', outFile, 'rows=', rows.length);
})();