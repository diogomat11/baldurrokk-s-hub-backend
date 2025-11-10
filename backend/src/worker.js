require('dotenv').config();
const { supabase } = require('./supabase');
const { sendWhatsApp } = require('./providers/whatsapp');

const BATCH_SIZE = Number(process.env.WORKER_BATCH_SIZE || 10);
const INTERVAL_MS = Number(process.env.WORKER_INTERVAL_MS || 10000);
const DRY_RUN = String(process.env.DRY_RUN || 'false') === 'true';

function log(...args) {
  console.log('[whatsapp-worker]', ...args);
}

async function processBatch() {
  const { data, error } = await supabase
    .from('v_whatsapp_outbox_pending')
    .select('id, phone, message')
    .limit(BATCH_SIZE);

  if (error) {
    log('Erro ao buscar pendentes:', error.message);
    return;
  }
  if (!data || data.length === 0) {
    log('Sem pendências.');
    return;
  }

  for (const row of data) {
    log('Enviando:', row.id, row.phone);
    let res = { ok: true, provider: 'stub' };
    if (!DRY_RUN) {
      res = await sendWhatsApp({ phone: row.phone, message: row.message });
    }

    if (res.ok) {
      const { error: markErr } = await supabase.rpc('mark_whatsapp_sent', { p_outbox_id: row.id });
      if (markErr) {
        log('Falha ao marcar enviado:', row.id, markErr.message);
      } else {
        log('Enviado com sucesso:', row.id);
      }
    } else {
      const errText = res.error || 'unknown_error';
      const { error: failErr } = await supabase.rpc('mark_whatsapp_failed', { p_outbox_id: row.id, p_error: errText });
      if (failErr) {
        log('Falha ao marcar erro:', row.id, failErr.message);
      } else {
        log('Marcado como falha:', row.id, errText);
      }
    }
  }
}

log(`Inicializando worker (batch=${BATCH_SIZE}, interval=${INTERVAL_MS}ms, dryRun=${DRY_RUN})`);
const timer = setInterval(processBatch, INTERVAL_MS);

process.on('SIGINT', () => {
  log('Encerrando worker...');
  clearInterval(timer);
  process.exit(0);
});