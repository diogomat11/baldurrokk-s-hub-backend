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
  const entityType = process.env.ADVANCE_ENTITY || 'Unidade'; // 'Unidade' | 'Equipe'
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const professionalName = process.env.PROFESSIONAL_NAME || null;
  const onlyOpen = String(process.env.ONLY_OPEN || 'false') === 'true';
  const startEnv = process.env.START_DATE || null;
  const endEnv = process.env.END_DATE || null;
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = startEnv || defaultStart;
  const end = endEnv || defaultEnd;

  console.log('[export:advances] params', { entityType, unitName, professionalName, start, end, onlyOpen });

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
      console.error('[export:advances] unit not found', unitName);
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
        console.error('[export:advances] professional not found', professionalName);
        process.exit(1);
      }
      filterEntityId = prof.id;
      entityLabel = prof.name;
    } else {
      entityLabel = 'Todos_Profissionais';
    }
  } else {
    console.error('[export:advances] invalid ADVANCE_ENTITY, use "Unidade" or "Equipe"');
    process.exit(1);
  }

  let advQuery = supabase
    .from('advances')
    .select('entity_type, entity_id, unit_id, amount, advance_date, status, created_at, updated_at')
    .eq('entity_type', entityType)
    .gte('advance_date', start)
    .lte('advance_date', end)
    .order('advance_date', { ascending: true });
  if (filterEntityId) advQuery = advQuery.eq('entity_id', filterEntityId);
  if (onlyOpen) advQuery = advQuery.eq('status', 'Aberta');

  const { data: advances, error: advErr } = await advQuery;
  if (advErr) throw new Error(advErr.message);
  if (!advances || advances.length === 0) {
    console.log('[export:advances] no advances in range');
    process.exit(0);
  }

  // Resolve names for professionals and units
  let profMap = new Map();
  if (entityType === 'Equipe') {
    if (!filterEntityId) {
      const profIds = [...new Set(advances.map((a) => a.entity_id))];
      if (profIds.length) {
        const { data: profs, error: profsErr } = await supabase
          .from('professionals')
          .select('id,name')
          .in('id', profIds);
        if (profsErr) throw new Error(profsErr.message);
        profMap = new Map((profs || []).map((p) => [p.id, p.name]));
      }
    } else {
      profMap.set(filterEntityId, entityLabel);
    }
  }

  const unitIds = [...new Set(advances.map((a) => a.unit_id).filter(Boolean))];
  let unitMap = new Map();
  if (unitIds.length) {
    const { data: units, error: unitsErr } = await supabase
      .from('units')
      .select('id,name')
      .in('id', unitIds);
    if (unitsErr) throw new Error(unitsErr.message);
    unitMap = new Map((units || []).map((u) => [u.id, u.name]));
  }

  const rows = advances.map((a) => {
    const entityName = entityType === 'Unidade' ? entityLabel : (profMap.get(a.entity_id) || entityLabel);
    const unitNameResolved = a.unit_id ? (unitMap.get(a.unit_id) || '') : '';
    return {
      entity_type: a.entity_type,
      entity_name: entityName || '',
      unit_name: unitNameResolved || '',
      amount: a.amount,
      advance_date: a.advance_date,
      status: a.status,
      created_at: a.created_at,
      updated_at: a.updated_at,
    };
  });

  const headers = [
    'entity_type',
    'entity_name',
    'unit_name',
    'amount',
    'advance_date',
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

  const entitySafe = entityType.replace(/[^a-zA-Z0-9_-]+/g, '_');
  const labelSafe = (entityLabel || '').replace(/[^a-zA-Z0-9_-]+/g, '_');
  const outFile = path.join(__dirname, '..', 'tmp', `advances_${entitySafe}_${labelSafe}_${start}_to_${end}.csv`);
  await fs.promises.mkdir(path.dirname(outFile), { recursive: true });
  await fs.promises.writeFile(outFile, csv, 'utf8');

  console.log('[export:advances] written', outFile, 'rows=', rows.length);
})();