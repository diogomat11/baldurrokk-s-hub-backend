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

async function ensureProfessional(name, unitId) {
  const { data: prof, error: findErr } = await supabase
    .from('professionals')
    .select('id,name')
    .eq('name', name)
    .limit(1)
    .maybeSingle();
  if (findErr && findErr.message !== 'supabase_not_configured') throw findErr;
  if (prof) return prof;
  const { data: created, error: insErr } = await supabase
    .from('professionals')
    .insert({ name, role_position: 'Professor', salary: 0, unit_ids: [unitId], status: 'Ativo' })
    .select('id,name')
    .maybeSingle();
  if (insErr) throw insErr;
  return created;
}

async function linkTeacherToAnyClass(unitId, teacherId) {
  const { data: classes, error: classErr } = await supabase
    .from('classes')
    .select('id,teacher_ids')
    .eq('unit_id', unitId)
    .limit(1);
  if (classErr) throw classErr;
  const cls = (classes || [])[0];
  if (!cls) return; // no class to link, skip
  const current = Array.isArray(cls.teacher_ids) ? cls.teacher_ids : [];
  if (current.includes(teacherId)) return;
  const next = [...current, teacherId];
  const { error: updErr } = await supabase
    .from('classes')
    .update({ teacher_ids: next })
    .eq('id', cls.id);
  if (updErr) throw updErr;
}

async function ensureNegotiationForProfessional(profId, repassType, repassValue, startDate) {
  const { data: existing, error: findErr } = await supabase
    .from('negotiations')
    .select('id')
    .eq('type', 'Equipe')
    .eq('entity_id', profId)
    .eq('status', 'Ativo')
    .limit(1)
    .maybeSingle();
  if (findErr) throw findErr;
  if (existing) return existing.id;
  const { data: created, error: insErr } = await supabase
    .from('negotiations')
    .insert({ type: 'Equipe', entity_id: profId, repass_type: repassType, repass_value: repassValue, start_date: startDate, end_date: null, status: 'Ativo' })
    .select('id')
    .maybeSingle();
  if (insErr) throw insErr;
  return created.id;
}

(async () => {
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const professionalName = process.env.PROFESSIONAL_NAME || 'Professor Demo';
  const repassType = process.env.REPASS_TYPE || 'Fixo'; // 'Fixo' | 'Percentual'
  const repassValue = parseFloat(process.env.REPASS_VALUE || '200');
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = process.env.START_DATE || defaultStart;
  const end = process.env.END_DATE || defaultEnd;

  console.log('[gen:repasses] params', { unitName, professionalName, repassType, repassValue, start, end });

  const { data: unit, error: unitErr } = await supabase
    .from('units')
    .select('id,name')
    .eq('name', unitName)
    .limit(1)
    .maybeSingle();
  if (unitErr) throw new Error(unitErr.message);
  if (!unit) {
    console.error('[gen:repasses] unit not found', unitName);
    process.exit(1);
  }

  const prof = await ensureProfessional(professionalName, unit.id);
  await linkTeacherToAnyClass(unit.id, prof.id);
  await ensureNegotiationForProfessional(prof.id, repassType, repassValue, start);

  const genRes = await supabase.rpc('generate_professional_repasses', {
    p_period_start: start,
    p_period_end: end,
  });
  if (genRes.error) throw genRes.error;
  console.log('[gen:repasses] generated count', genRes.data);
})();