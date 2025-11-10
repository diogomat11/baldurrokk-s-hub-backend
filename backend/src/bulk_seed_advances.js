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

function randomDateIso(startStr, endStr) {
  const start = new Date(startStr + 'T00:00:00Z');
  const end = new Date(endStr + 'T23:59:59Z');
  const t = start.getTime() + Math.floor(Math.random() * (end.getTime() - start.getTime() + 1));
  const d = new Date(t);
  return d.toISOString().slice(0, 10);
}

function randomAmount(min, max) {
  const v = min + Math.random() * (max - min);
  return Math.round(v * 100) / 100.0;
}

(async () => {
  const entityType = process.env.ADVANCE_ENTITY || 'Unidade'; // 'Unidade' | 'Equipe'
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const professionalName = process.env.PROFESSIONAL_NAME || null;
  const count = Number.parseInt(process.env.COUNT || '1', 10);
  const minAmount = parseFloat(process.env.MIN_AMOUNT || '50');
  const maxAmount = parseFloat(process.env.MAX_AMOUNT || '200');
  const startEnv = process.env.START_DATE || null;
  const endEnv = process.env.END_DATE || null;
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = startEnv || defaultStart;
  const end = endEnv || defaultEnd;

  console.log('[advances:bulk-seed] params', { entityType, unitName, professionalName, count, minAmount, maxAmount, start, end });

  try {
    const { data: unit, error: unitErr } = await supabase
      .from('units')
      .select('id,name')
      .eq('name', unitName)
      .limit(1)
      .maybeSingle();
    if (unitErr) throw new Error(unitErr.message);
    if (!unit) {
      console.error('[advances:bulk-seed] unit not found', unitName);
      process.exit(1);
    }

    let prof = null;
    if (entityType === 'Equipe') {
      const name = professionalName || 'Professor Demo';
      const { data: found, error: profErr } = await supabase
        .from('professionals')
        .select('id,name')
        .eq('name', name)
        .limit(1)
        .maybeSingle();
      if (profErr) throw new Error(profErr.message);
      if (!found) {
        console.error('[advances:bulk-seed] professional not found', name);
        process.exit(1);
      }
      prof = found;
    } else if (entityType !== 'Unidade') {
      console.error('[advances:bulk-seed] invalid ADVANCE_ENTITY, use "Unidade" or "Equipe"');
      process.exit(1);
    }

    const payloads = [];
    for (let i = 0; i < count; i++) {
      const advDate = randomDateIso(start, end);
      const amount = randomAmount(minAmount, maxAmount);
      if (entityType === 'Unidade') {
        payloads.push({
          entity_type: 'Unidade',
          entity_id: unit.id,
          unit_id: unit.id,
          amount,
          advance_date: advDate,
          status: 'Aberta',
        });
      } else {
        payloads.push({
          entity_type: 'Equipe',
          entity_id: prof.id,
          unit_id: unit.id,
          amount,
          advance_date: advDate,
          status: 'Aberta',
        });
      }
    }

    const { data: inserted, error: insErr } = await supabase
      .from('advances')
      .insert(payloads)
      .select('*');
    if (insErr) throw insErr;

    console.log('[advances:bulk-seed] created', Array.isArray(inserted) ? inserted.length : 0);
  } catch (err) {
    console.error('[advances:bulk-seed] ERROR', {
      message: err?.message,
      details: err?.details,
      hint: err?.hint,
      code: err?.code,
    });
    process.exit(1);
  }
})();