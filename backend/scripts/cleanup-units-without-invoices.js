/**
 * Remove Unidades sem mensalidades (invoices) e sem referências restritivas.
 * Critérios de deleção:
 *  - Não possui invoices (ON DELETE RESTRICT)
 *  - Não possui students (ON DELETE RESTRICT)
 *  - Não possui expenses (ON DELETE RESTRICT)
 *  - Não possui whatsapp_outbox (ON DELETE RESTRICT)
 *  - classes e recurrences/plans não bloqueiam (CASCADE/SET NULL)
 *
 * Uso:
 *  node backend/scripts/cleanup-units-without-invoices.js         # dry-run
 *  node backend/scripts/cleanup-units-without-invoices.js --apply # executa deleção
 */

/* eslint-disable no-console */
require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') })
const { supabase } = require('../src/supabase')

async function fetchAllUnits() {
  const { data, error } = await supabase.from('units').select('id, name, status')
  if (error) throw new Error('Falha ao buscar units: ' + error.message)
  return data || []
}

async function fetchRestrictiveRefs() {
  const tables = [
    { table: 'invoices', column: 'unit_id' },
    { table: 'students', column: 'unit_id' },
    { table: 'expenses', column: 'unit_id' },
    { table: 'whatsapp_outbox', column: 'unit_id' },
  ]
  const refSet = new Set()
  for (const t of tables) {
    const { data, error } = await supabase.from(t.table).select(`${t.column}`).not(t.column, 'is', null)
    if (error) throw new Error(`Falha ao buscar ${t.table}: ` + error.message)
    for (const row of data || []) {
      if (row[t.column]) refSet.add(row[t.column])
    }
  }
  return refSet
}

async function deleteUnits(ids) {
  if (!ids.length) return { data: [], error: null }
  const { data, error } = await supabase.from('units').delete().in('id', ids).select('id, name')
  if (error) throw new Error('Falha ao deletar units: ' + error.message)
  return { data, error }
}

async function main() {
  const APPLY = process.argv.includes('--apply') || process.argv.includes('--yes')

  const envOk = process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!envOk) {
    console.error('[cleanup] SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY ausente. Configure o backend/.env.')
    process.exit(2)
  }

  console.log('[cleanup] Buscando unidades e referências restritivas...')
  const units = await fetchAllUnits()
  const restrictiveRefs = await fetchRestrictiveRefs()

  const candidates = units.filter(u => !restrictiveRefs.has(u.id))

  console.log(`[cleanup] Total de unidades: ${units.length}`)
  console.log(`[cleanup] Unidades referenciadas (bloqueadas): ${restrictiveRefs.size}`)
  console.log(`[cleanup] Candidatas à deleção (sem mensalidades e sem refs): ${candidates.length}`)

  if (candidates.length === 0) {
    console.log('[cleanup] Nenhuma unidade candidata encontrada. Nada a fazer.')
    return
  }

  console.table(candidates.map(c => ({ id: c.id, name: c.name, status: c.status })))

  if (!APPLY) {
    console.log('\n[cleanup] Dry-run concluído. Use --apply para executar a deleção.')
    return
  }

  console.log('[cleanup] Deletando unidades candidatas...')
  const ids = candidates.map(c => c.id)
  const { data } = await deleteUnits(ids)
  console.log(`[cleanup] Deleção concluída. Removidas: ${data.length}`)
  console.table(data.map(d => ({ id: d.id, name: d.name })))
}

main().catch((err) => {
  console.error('[cleanup] Erro:', err.message)
  process.exit(1)
})