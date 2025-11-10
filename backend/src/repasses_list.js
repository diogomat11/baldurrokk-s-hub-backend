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
  const entityType = process.env.REPASS_ENTITY || 'Unidade'; // 'Unidade' | 'Equipe'
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const professionalName = process.env.PROFESSIONAL_NAME || null;
  const onlyOpen = String(process.env.ONLY_OPEN || 'false') === 'true';
  const startEnv = process.env.START_DATE || null;
  const endEnv = process.env.END_DATE || null;
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = startEnv || defaultStart;
  const end = endEnv || defaultEnd;

  console.log('[repasses:list] params', { entityType, unitName, professionalName, start, end, onlyOpen });

  try {
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
        console.error('[repasses:list] unit not found', unitName);
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
          console.error('[repasses:list] professional not found', professionalName);
          process.exit(1);
        }
        filterEntityId = prof.id;
        entityLabel = prof.name;
      } else {
        entityLabel = 'Todos_Profissionais';
      }
    } else {
      console.error('[repasses:list] invalid REPASS_ENTITY, use "Unidade" or "Equipe"');
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

    // Resolve names for Equipe when listing multiple professionals
    let profMap = new Map();
    if (entityType === 'Equipe') {
      if (!filterEntityId && repasses && repasses.length) {
        const profIds = [...new Set(repasses.map((r) => r.entity_id))];
        const { data: profs, error: profsErr } = await supabase
          .from('professionals')
          .select('id,name')
          .in('id', profIds);
        if (profsErr) throw new Error(profsErr.message);
        profMap = new Map((profs || []).map((p) => [p.id, p.name]));
      } else if (filterEntityId) {
        profMap.set(filterEntityId, entityLabel);
      }
    }

    const rows = (repasses || []).map((r) => {
      const entityName = entityType === 'Unidade' ? entityLabel : (profMap.get(r.entity_id) || entityLabel);
      return {
        repasse_id: r.id,
        entity_type: r.entity_type,
        entity_name: entityName || '',
        period_start: r.period_start,
        period_end: r.period_end,
        gross_value: r.gross_value,
        advance_deduction: r.advance_deduction,
        net_value: r.net_value,
        status: r.status,
        paid_at: r.paid_at || null,
        receipt_url: r.receipt_url || null,
      };
    });

    if (!rows.length) {
      console.log('[repasses:list] no repasses in range');
      process.exit(0);
    }

    console.log('[repasses:list] results:');
    for (const r of rows) {
      console.log(r);
    }
  } catch (err) {
    console.error('[repasses:list] ERROR', {
      message: err?.message,
      details: err?.details,
      hint: err?.hint,
      code: err?.code,
    });
    process.exit(1);
  }
})();