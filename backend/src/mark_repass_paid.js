require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { supabase } = require('./supabase');

function monthBounds(date = new Date()) {
  const y = date.getUTCFullYear();
  const m = date.getUTCMonth();
  const start = new Date(Date.UTC(y, m, 1));
  const end = new Date(Date.UTC(y, m + 1, 0));
  const iso = (d) => d.toISOString();
  return { start: iso(start), end: iso(end) };
}

function contentTypeByExt(ext) {
  const e = (ext || '').toLowerCase();
  if (e === '.jpg' || e === '.jpeg') return 'image/jpeg';
  if (e === '.png') return 'image/png';
  if (e === '.pdf') return 'application/pdf';
  return 'application/octet-stream';
}

async function resolveEntityId(entityType, unitName, professionalName) {
  if (entityType === 'Unidade') {
    const { data: unit, error } = await supabase
      .from('units')
      .select('id,name')
      .eq('name', unitName)
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    if (!unit) throw new Error(`Unit not found: ${unitName}`);
    return unit.id;
  }
  if (entityType === 'Equipe') {
    if (!professionalName) throw new Error('PROFESSIONAL_NAME required for Equipe');
    const { data: prof, error } = await supabase
      .from('professionals')
      .select('id,name')
      .eq('name', professionalName)
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    if (!prof) throw new Error(`Professional not found: ${professionalName}`);
    return prof.id;
  }
  throw new Error('Invalid REPASS_ENTITY: use "Unidade" or "Equipe"');
}

(async () => {
  const entityType = process.env.REPASS_ENTITY || 'Unidade'; // 'Unidade' | 'Equipe'
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const professionalName = process.env.PROFESSIONAL_NAME || null;
  const repassId = process.env.REPASS_ID || null;
  const paidAt = process.env.PAID_AT || new Date().toISOString();
  const receiptPath = process.env.RECEIPT_PATH || null;
  const { start: defStartIso, end: defEndIso } = monthBounds(new Date());
  const start = process.env.START_DATE || defStartIso.slice(0, 10);
  const end = process.env.END_DATE || defEndIso.slice(0, 10);

  console.log('[repasses:pay] params', { entityType, unitName, professionalName, repassId, start, end, paidAt, receiptPath });

  try {
    let targetRepassId = repassId;

    if (!targetRepassId) {
      const entityId = await resolveEntityId(entityType, unitName, professionalName);
      const { data: repasses, error } = await supabase
        .from('repasses')
        .select('id,status,period_start,period_end')
        .eq('entity_type', entityType)
        .eq('entity_id', entityId)
        .eq('status', 'Aberta')
        .gte('period_start', start)
        .lte('period_end', end)
        .order('created_at', { ascending: false })
        .limit(1);
      if (error) throw error;
      if (!repasses || repasses.length === 0) {
        throw new Error('No open repass found for filters');
      }
      targetRepassId = repasses[0].id;
    }

    let receiptUrl = null;
    if (receiptPath) {
      const absPath = path.isAbsolute(receiptPath) ? receiptPath : path.resolve(receiptPath);
      const exists = fs.existsSync(absPath);
      if (!exists) throw new Error(`Receipt file not found: ${absPath}`);
      const buf = fs.readFileSync(absPath);
      const ext = path.extname(absPath) || '.bin';
      const contentType = contentTypeByExt(ext);
      const objectKey = `receipts/${targetRepassId}${ext}`;
      const { error: upErr } = await supabase.storage.from('repasses').upload(objectKey, buf, {
        contentType,
        upsert: true,
      });
      if (upErr) throw upErr;
      receiptUrl = `/storage/v1/object/repasses/${objectKey}`;
      console.log('[repasses:pay] receipt uploaded', { objectKey, contentType });
    }

    const { error: rpcErr } = await supabase.rpc('mark_repass_paid', {
      p_repass_id: targetRepassId,
      p_paid_at: paidAt,
      p_receipt_url: receiptUrl,
    });
    if (rpcErr) throw rpcErr;

    console.log('[repasses:pay] marked paid', { repass_id: targetRepassId, paid_at: paidAt, receipt_url: receiptUrl });
  } catch (err) {
    console.error('[repasses:pay] ERROR', {
      message: err?.message,
      details: err?.details,
      hint: err?.hint,
      code: err?.code,
    });
    process.exit(1);
  }
})();