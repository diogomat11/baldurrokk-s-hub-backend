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
  const { start: defaultStart, end: defaultEnd } = monthBounds(new Date());
  const start = process.env.START_DATE || defaultStart;
  const end = process.env.END_DATE || defaultEnd;

  console.log('[gen:unit_repasses] params', { unitName, start, end });

  try {
    const { data, error } = await supabase.rpc('generate_unit_fixed_repasses', {
      p_period_start: start,
      p_period_end: end,
    });

    if (error) {
      console.error('[gen:unit_repasses] RPC error', {
        message: error.message,
        details: error.details,
        hint: error.hint,
        code: error.code,
      });
      process.exit(1);
    }

    console.log('[gen:unit_repasses] generated count', data);
  } catch (err) {
    console.error('[gen:unit_repasses] Unhandled error', {
      message: err?.message,
      stack: err?.stack,
    });
    process.exit(1);
  }
})();