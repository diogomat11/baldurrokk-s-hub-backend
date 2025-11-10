require('dotenv').config();
const { supabase } = require('./supabase');

(async () => {
  try {
    const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
    const value = parseFloat(process.env.UNIT_REPASS_VALUE || '500');

    console.log('[unit:set-fixed] params', { unitName, value });

    const { data: unit, error: unitErr } = await supabase
      .from('units')
      .select('id,name,repass_type,repass_value,status')
      .eq('name', unitName)
      .limit(1)
      .maybeSingle();
    if (unitErr) throw unitErr;
    if (!unit) {
      console.error('[unit:set-fixed] unit not found', unitName);
      process.exit(1);
    }

    const { data: updated, error: updErr } = await supabase
      .from('units')
      .update({ repass_type: 'Fixo', repass_value: value })
      .eq('id', unit.id)
      .select('id,name,repass_type,repass_value')
      .maybeSingle();
    if (updErr) throw updErr;

    console.log('[unit:set-fixed] updated', {
      before: { repass_type: unit.repass_type, repass_value: unit.repass_value },
      after: { repass_type: updated.repass_type, repass_value: updated.repass_value },
    });
  } catch (err) {
    console.error('[unit:set-fixed] ERROR', {
      message: err?.message,
      details: err?.details,
      hint: err?.hint,
      code: err?.code,
    });
    process.exit(1);
  }
})();