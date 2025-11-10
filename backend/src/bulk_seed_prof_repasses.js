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

function randFloat(min, max) { return Math.round((Math.random() * (max - min) + min) * 100) / 100; }

async function ensureUnit(unitName) {
  const { data, error } = await supabase
    .from('units')
    .select('id,name')
    .eq('name', unitName)
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new Error(`Unit not found: ${unitName}`);
  return data;
}

async function ensureClass(unitId) {
  const { data, error } = await supabase
    .from('classes')
    .select('id,teacher_ids')
    .eq('unit_id', unitId)
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  if (data) return data;

  const { data: created, error: cErr } = await supabase
    .from('classes')
    .insert({ unit_id: unitId, name: 'Turma Bulk - Auto', category: 'Futebol', vacancies: 50, status: 'Ativa', schedule: 'Seg/Qua 18:00', teacher_ids: [] })
    .select('id,teacher_ids')
    .maybeSingle();
  if (cErr) throw cErr;
  return created;
}

async function ensureProfessional(unitId, name) {
  const { data, error } = await supabase
    .from('professionals')
    .select('id,name,unit_ids')
    .eq('name', name)
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  if (data) {
    const unitIds = Array.isArray(data.unit_ids) ? data.unit_ids : [];
    if (!unitIds.includes(unitId)) {
      const { error: upErr } = await supabase
        .from('professionals')
        .update({ unit_ids: [...unitIds, unitId] })
        .eq('id', data.id);
      if (upErr) throw upErr;
    }
    return data;
  }
  const { data: created, error: cErr } = await supabase
    .from('professionals')
    .insert({ name, role_position: 'Professor', unit_ids: [unitId], status: 'Ativo' })
    .select('id,name,unit_ids')
    .maybeSingle();
  if (cErr) throw cErr;
  return created;
}

async function ensureNegotiation(profId, repassType, repassValue, startDate) {
  const { data: existing, error: exErr } = await supabase
    .from('negotiations')
    .select('id')
    .eq('type', 'Equipe')
    .eq('entity_id', profId)
    .eq('status', 'Ativo')
    .limit(1)
    .maybeSingle();
  if (exErr) throw exErr;
  if (existing) return existing;

  const { data, error } = await supabase
    .from('negotiations')
    .insert({ type: 'Equipe', entity_id: profId, repass_type: repassType, repass_value: repassValue, start_date: startDate, status: 'Ativo' })
    .select('id')
    .maybeSingle();
  if (error) throw error;
  return data;
}

(async () => {
  try {
    const unitName = process.env.UNIT_NAME || 'Unidade Centro';
    const count = parseInt(process.env.COUNT || '10', 10);
    const repassType = process.env.REPASS_TYPE || 'Fixo';
    const repMin = parseFloat(process.env.REPASS_VALUE_MIN || '100');
    const repMax = parseFloat(process.env.REPASS_VALUE_MAX || '300');
    const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
    const start = process.env.START_DATE || defaultStart;
    const end = process.env.END_DATE || defaultEnd;

    console.log('[bulk:repasses] params', { unitName, count, repassType, repMin, repMax, start, end });

    const unit = await ensureUnit(unitName);
    let klass = await ensureClass(unit.id);

    const teacherIds = Array.isArray(klass.teacher_ids) ? [...klass.teacher_ids] : [];

    for (let i = 1; i <= count; i++) {
      const name = `Professor Bulk ${i}`;
      const prof = await ensureProfessional(unit.id, name);
      const repValue = randFloat(repMin, repMax);
      await ensureNegotiation(prof.id, repassType, repValue, start);

      if (!teacherIds.includes(prof.id)) teacherIds.push(prof.id);
    }

    const { error: tErr } = await supabase
      .from('classes')
      .update({ teacher_ids: teacherIds })
      .eq('id', klass.id);
    if (tErr) throw tErr;

    const { data: genRes, error: genErr } = await supabase
      .rpc('generate_professional_repasses', { p_period_start: start, p_period_end: end });
    if (genErr) throw genErr;

    console.log('[bulk:repasses] generate result', genRes);
  } catch (err) {
    console.error('[bulk:repasses] ERROR', {
      message: err?.message,
      details: err?.details,
      hint: err?.hint,
      code: err?.code,
    });
    process.exit(1);
  }
})();