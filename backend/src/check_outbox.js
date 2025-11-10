require('dotenv').config();
const { supabase } = require('./supabase');

async function main() {
  const { data, error } = await supabase
    .from('whatsapp_outbox')
    .select('id, invoice_id, phone, status, attempts, last_attempt_at, error, created_at, updated_at')
    .order('created_at', { ascending: false })
    .limit(5);
  if (error) throw error;
  console.log('[outbox] latest 5:');
  for (const row of data) {
    console.log({
      id: row.id,
      invoice_id: row.invoice_id,
      phone: row.phone,
      status: row.status,
      attempts: row.attempts,
      last_attempt_at: row.last_attempt_at,
      error: row.error,
      created_at: row.created_at,
      updated_at: row.updated_at,
    });
  }
}

main().catch((err) => {
  console.error('[outbox] error', err);
  process.exit(1);
});