/**
 * Migra dependências para apenas 3 unidades e remove as demais.
 * Tabelas tratadas:
 *  - students (unit_id)        [RESTRICT]
 *  - invoices (unit_id)        [RESTRICT]
 *  - expenses (unit_id)        [RESTRICT]
 *  - whatsapp_outbox (unit_id) [RESTRICT]
 *  - plans (unit_id)           [CASCADE] -> atualizamos para preservar
 *  - professionals (unit_ids[])          -> filtramos para mantidas; se vazio, atribuimos uma mantida
 *  - recurrences (units_applicable[])    -> filtramos; se vazio, atribuimos mantidas
 *  - classes (unit_id)         [CASCADE] -> opcional: serão apagadas ao remover unidades não mantidas
 *
 * Escolha das 3 unidades mantidas:
 *  - Se passar --keep=<id1,id2,id3>, usa exatamente essas
 *  - Caso contrário, escolhe as 3 com maior número de invoices; desempate por students, depois por created_at
 *
 * Uso:
 *  node backend/scripts/migrate-and-trim-units.js               # dry-run
 *  node backend/scripts/migrate-and-trim-units.js --apply       # aplica migração e remove unidades
 *  node backend/scripts/migrate-and-trim-units.js --keep=a,b,c  # define explicitamente as 3 unidades
 */

/* eslint-disable no-console */
require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') })
const { supabase } = require('../src/supabase')

function ensureEnv() {
  const ok = process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!ok) {
    throw new Error('SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY ausente (backend/.env)')
  }
}

async function fetchUnits() {
  const { data, error } = await supabase.from('units').select('id, name, created_at')
  if (error) throw new Error('Falha ao buscar units: ' + error.message)
  return data || []
}

async function countBy(table, column) {
  const { data, error } = await supabase
    .from(table)
    .select(`${column}`)
  if (error) throw new Error(`Falha ao contar ${table}: ` + error.message)
  const counts = new Map()
  for (const row of data || []) {
    const id = row[column]
    if (!id) continue
    counts.set(id, (counts.get(id) || 0) + 1)
  }
  return counts
}

function pickTop3(units, countsPri, countsSec) {
  const score = (id) => (countsPri.get(id) || 0) * 1_000_000 + (countsSec.get(id) || 0)
  const sorted = [...units].sort((a, b) => {
    const sa = score(a.id)
    const sb = score(b.id)
    if (sb !== sa) return sb - sa
    // desempate por created_at (mais antigos primeiro)
    return new Date(a.created_at) - new Date(b.created_at)
  })
  return sorted.slice(0, 3)
}

function parseKeepArg() {
  const arg = process.argv.find((a) => a.startsWith('--keep='))
  if (!arg) return null
  const list = arg.replace('--keep=', '').split(',').map((s) => s.trim()).filter(Boolean)
  if (list.length !== 3) throw new Error('Passe exatamente 3 IDs em --keep=<id1,id2,id3>')
  return list
}

function makeMapping(notKeptIds, keptIds) {
  const map = new Map()
  let i = 0
  for (const id of notKeptIds) {
    map.set(id, keptIds[i % keptIds.length])
    i++
  }
  return map
}

async function updateRestrictTable(table, column, mapping) {
  let total = 0
  for (const [oldId, newId] of mapping.entries()) {
    const { error, count } = await supabase
      .from(table)
      .update({ [column]: newId })
      .eq(column, oldId)
      .select(column, { count: 'exact' })
    if (error) throw new Error(`Falha ao atualizar ${table}: ` + error.message)
    total += count || 0
  }
  return total
}

async function migrateProfessionals(keptSet) {
  const { data: list, error } = await supabase.from('professionals').select('id, unit_ids')
  if (error) throw new Error('Falha ao buscar professionals: ' + error.message)
  let changed = 0
  for (const p of list || []) {
    const curr = Array.isArray(p.unit_ids) ? p.unit_ids : []
    const filtered = curr.filter((id) => keptSet.has(id))
    const next = filtered.length > 0 ? filtered : [...keptSet].slice(0, 1)
    // Atualiza apenas se mudou
    const same = next.length === curr.length && next.every((v, idx) => v === curr[idx])
    if (!same) {
      const { error: upErr } = await supabase.from('professionals').update({ unit_ids: next }).eq('id', p.id)
      if (upErr) throw new Error('Falha ao atualizar professional: ' + upErr.message)
      changed++
    }
  }
  return changed
}

async function migrateRecurrences(keptIds) {
  const keptSet = new Set(keptIds)
  const { data: list, error } = await supabase.from('recurrences').select('id, units_applicable')
  if (error) throw new Error('Falha ao buscar recurrences: ' + error.message)
  let changed = 0
  for (const r of list || []) {
    const curr = Array.isArray(r.units_applicable) ? r.units_applicable : []
    const filtered = curr.filter((id) => keptSet.has(id))
    const next = filtered.length > 0 ? filtered : keptIds
    const same = next.length === curr.length && next.every((v, idx) => v === curr[idx])
    if (!same) {
      const { error: upErr } = await supabase.from('recurrences').update({ units_applicable: next }).eq('id', r.id)
      if (upErr) throw new Error('Falha ao atualizar recurrence: ' + upErr.message)
      changed++
    }
  }
  return changed
}

async function migrateAndTrim() {
  ensureEnv()
  const APPLY = process.argv.includes('--apply') || process.argv.includes('--yes')
  const keepArg = parseKeepArg()

  const units = await fetchUnits()
  if (units.length === 0) {
    console.log('[migrate] Não há unidades cadastradas. Nada a fazer.')
    return
  }

  let kept
  if (keepArg) {
    const keepSet = new Set(keepArg)
    kept = units.filter(u => keepSet.has(u.id))
    if (kept.length !== 3) throw new Error('Algum ID passado em --keep não existe na tabela units')
  } else {
    const invCounts = await countBy('invoices', 'unit_id')
    const stuCounts = await countBy('students', 'unit_id')
    kept = pickTop3(units, invCounts, stuCounts)
  }

  const keptIds = kept.map(u => u.id)
  const keptSet = new Set(keptIds)
  const notKept = units.filter(u => !keptSet.has(u.id))
  const notKeptIds = notKept.map(u => u.id)

  console.log('[migrate] Mantidas (3):')
  console.table(kept.map(k => ({ id: k.id, name: k.name })))
  console.log(`[migrate] Demais a migrar/remover: ${notKept.length}`)

  if (notKept.length === 0) {
    console.log('[migrate] Já há apenas 3 unidades. Nada a fazer.')
    return
  }

  const mapping = makeMapping(notKeptIds, keptIds)

  // Dry-run counters
  let counts = {}

  // Tabelas de chave unit_id com RESTRICT
  counts.students = await updateRestrictTable('students', 'unit_id', mapping)
  counts.invoices = await updateRestrictTable('invoices', 'unit_id', mapping)
  counts.expenses = await updateRestrictTable('expenses', 'unit_id', mapping)
  counts.whatsapp_outbox = await updateRestrictTable('whatsapp_outbox', 'unit_id', mapping)

  // Atualizar planos (CASCADE, mas queremos preservar)
  counts.plans = await updateRestrictTable('plans', 'unit_id', mapping)

  // Arrays: equipe/profissionais e recorrências
  counts.professionals = await migrateProfessionals(keptSet)
  counts.recurrences = await migrateRecurrences(keptIds)

  console.log('[migrate] Registros atualizados por tabela:')
  console.table(Object.entries(counts).map(([k, v]) => ({ table: k, updated: v })))

  if (!APPLY) {
    console.log('\n[migrate] Dry-run concluído. Use --apply para executar remoção das unidades não mantidas.')
    return
  }

  console.log('[migrate] Removendo unidades não mantidas...')
  const { data: removed, error: delErr } = await supabase.from('units').delete().in('id', notKeptIds).select('id, name')
  if (delErr) throw new Error('Falha ao remover units: ' + delErr.message)
  console.log(`[migrate] Remoção concluída. Unidades removidas: ${removed.length}`)
  console.table(removed.map(r => ({ id: r.id, name: r.name })))
}

migrateAndTrim().catch((err) => {
  console.error('[migrate] Erro:', err.message)
  process.exit(1)
})