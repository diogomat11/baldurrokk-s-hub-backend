const test = require('node:test');
const assert = require('node:assert');
require('dotenv').config();

const { supabase } = require('../src/supabase');

const HAVE_SUPABASE = Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);

function isoDate(d = new Date()) {
  return d.toISOString().slice(0, 10);
}
function monthBounds(date = new Date()) {
  const y = date.getUTCFullYear();
  const m = date.getUTCMonth();
  const start = new Date(Date.UTC(y, m, 1));
  const end = new Date(Date.UTC(y, m + 1, 0));
  const iso = (d) => d.toISOString().slice(0, 10);
  return { start: iso(start), end: iso(end) };
}
function round2(n) { return Math.round(Number(n) * 100) / 100; }

// Fluxo completo: gerar mensalidade (com descontos), marcar pago em dinheiro (gera adiantamento),
// e repasse fixo por unidade com conciliação de adiantamentos.
test('Finance Integration: generate invoices, mark paid (cash) -> advance, unit fixed repasses conciliation', async () => {
  if (!HAVE_SUPABASE) return;

  const todayIso = isoDate();
  const { start: periodStart, end: periodEnd } = monthBounds(new Date());
  const uniq = Date.now();

  // 1) Criar entidade mínima para o fluxo
  // network -> unit (Fixo) -> plan -> recurrence (10%) -> proportional (50%) -> professional -> class -> student (Dinheiro)
  const { data: network, error: netErr } = await supabase
    .from('networks')
    .insert({ name: `Net Test ${uniq}`, description: 'Finance integration network' })
    .select('id')
    .maybeSingle();
  assert.ok(!netErr, `Erro ao criar network: ${netErr && netErr.message}`);

  const { data: unit, error: unitErr } = await supabase
    .from('units')
    .insert({ network_id: network.id, name: `Unit Test ${uniq}`, repass_type: 'Fixo', repass_value: 100, status: 'Ativo' })
    .select('id,name,repass_value')
    .maybeSingle();
  assert.ok(!unitErr, `Erro ao criar unit: ${unitErr && unitErr.message}`);

  const { data: plan, error: planErr } = await supabase
    .from('plans')
    .insert({ name: `Plan Test ${uniq}`, unit_id: unit.id, frequency_per_week: 1, value: 120, start_date: periodStart, status: 'Ativo' })
    .select('id,value')
    .maybeSingle();
  assert.ok(!planErr, `Erro ao criar plan: ${planErr && planErr.message}`);

  const { data: rec, error: recErr } = await supabase
    .from('recurrences')
    .insert({ type: 'Mensal', discount_percent: 10, start_date: periodStart, end_date: periodEnd, units_applicable: [unit.id], status: 'Ativo' })
    .select('id,discount_percent,type')
    .maybeSingle();
  assert.ok(!recErr, `Erro ao criar recurrence: ${recErr && recErr.message}`);

  const { data: prop, error: propErr } = await supabase
    .from('proportionals')
    .insert({ start_period: periodStart, end_period: periodEnd, discount_percent: 50, status: 'Ativo' })
    .select('id,discount_percent')
    .maybeSingle();
  assert.ok(!propErr, `Erro ao criar proportional: ${propErr && propErr.message}`);

  const { data: prof, error: profErr } = await supabase
    .from('professionals')
    .insert({ name: `Prof Test ${uniq}`, role_position: 'Professor', unit_ids: [unit.id], status: 'Ativo' })
    .select('id,name')
    .maybeSingle();
  assert.ok(!profErr, `Erro ao criar professional: ${profErr && profErr.message}`);

  const { data: klass, error: classErr } = await supabase
    .from('classes')
    .insert({ unit_id: unit.id, name: `Class Test ${uniq}`, category: 'Finance', vacancies: 20, status: 'Ativo', schedule: 'Seg/Qua 18:00', teacher_ids: [prof.id] })
    .select('id')
    .maybeSingle();
  assert.ok(!classErr, `Erro ao criar class: ${classErr && classErr.message}`);

  const { data: student, error: studErr } = await supabase
    .from('students')
    .insert({
      name: `Aluno FinTest ${uniq}`,
      unit_id: unit.id,
      class_id: klass.id,
      plan_id: plan.id,
      recurrence_id: rec.id,
      start_date: todayIso,
      payment_method: 'Dinheiro',
      status: 'Ativo'
    })
    .select('id')
    .maybeSingle();
  assert.ok(!studErr, `Erro ao criar student: ${studErr && studErr.message}`);

  // 2) Gerar mensalidades via RPC
  const { data: genCount, error: genErr } = await supabase
    .rpc('generate_invoices_for_active_students', { p_generation_date: todayIso, p_due_day: 5 });
  assert.ok(!genErr, `Erro ao gerar mensalidades: ${genErr && genErr.message}`);
  assert.ok((genCount || 0) >= 1, 'Nenhuma mensalidade gerada');

  const { data: invoice, error: invErr } = await supabase
    .from('invoices')
    .select('id,amount_total,amount_discount,amount_net,status,due_date')
    .eq('student_id', student.id)
    .order('issued_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  assert.ok(!invErr, `Erro ao buscar invoice: ${invErr && invErr.message}`);
  assert.ok(invoice, 'Invoice não encontrada');

  const expectedTotal = round2(plan.value);
  const expectedPct = Math.min((rec.discount_percent || 0) + (prop.discount_percent || 0), 100);
  const expectedDiscount = round2(expectedTotal * expectedPct / 100);
  const expectedNet = round2(expectedTotal - expectedDiscount);

  assert.strictEqual(round2(invoice.amount_total), expectedTotal, 'amount_total diferente do plano');
  assert.strictEqual(round2(invoice.amount_discount), expectedDiscount, 'amount_discount incorreto');
  assert.strictEqual(round2(invoice.amount_net), expectedNet, 'amount_net incorreto');
  assert.strictEqual(invoice.status, 'Aberta', 'status da fatura não é Aberta');
  assert.strictEqual(invoice.due_date, todayIso, 'primeira mensalidade deve vencer na data de geração');

  // 3) Marcar como pago em dinheiro -> gera adiantamento para profissional
  const { error: markErr } = await supabase
    .rpc('mark_invoice_paid', {
      p_invoice_id: invoice.id,
      p_payment_method: 'Dinheiro',
      p_paid_at: new Date().toISOString(),
      p_receipt_url: null,
      p_professional_id: prof.id,
    });
  assert.ok(!markErr, `Erro ao marcar pago: ${markErr && markErr.message}`);

  const { data: advRow, error: advErr } = await supabase
    .from('advances')
    .select('id,entity_type,entity_id,amount,advance_date,status')
    .eq('entity_type', 'Equipe')
    .eq('entity_id', prof.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  assert.ok(!advErr, `Erro ao buscar advance: ${advErr && advErr.message}`);
  assert.ok(advRow, 'Adiantamento não criado para profissional');
  assert.strictEqual(round2(advRow.amount), round2(invoice.amount_net), 'Valor do adiantamento difere do líquido da fatura');

  // 4) Conciliação de repasse fixo por unidade: inserir um adiantamento de unidade e gerar repasse
  const { error: unitAdvErr } = await supabase
    .from('advances')
    .insert({ entity_type: 'Unidade', entity_id: unit.id, unit_id: unit.id, amount: 20, advance_date: todayIso, status: 'Aberta' });
  assert.ok(!unitAdvErr, `Erro ao inserir advance de unidade: ${unitAdvErr && unitAdvErr.message}`);

  const { data: genUnitCount, error: genUnitErr } = await supabase
    .rpc('generate_unit_fixed_repasses', { p_period_start: periodStart, p_period_end: periodEnd });
  assert.ok(!genUnitErr, `Erro ao gerar repasses fixos: ${genUnitErr && genUnitErr.message}`);
  assert.ok((genUnitCount || 0) >= 1, 'Nenhum repasse fixo gerado');

  const { data: repass, error: repErr } = await supabase
    .from('repasses')
    .select('id,entity_type,entity_id,gross_value,advance_deduction,net_value,period_start,period_end,status')
    .eq('entity_type', 'Unidade')
    .eq('entity_id', unit.id)
    .eq('period_start', periodStart)
    .eq('period_end', periodEnd)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  assert.ok(!repErr, `Erro ao buscar repasse: ${repErr && repErr.message}`);
  assert.ok(repass, 'Repasse fixo não encontrado');
  assert.strictEqual(round2(repass.gross_value), round2(unit.repass_value), 'gross_value incorreto');
  assert.strictEqual(round2(repass.advance_deduction), 20, 'advance_deduction deve refletir adiantamento de unidade');
  assert.strictEqual(round2(repass.net_value), round2(unit.repass_value - 20), 'net_value incorreto');

  const { data: conc, error: concErr } = await supabase
    .from('v_repasses_conciliation')
    .select('gross_total,advances_total,net_total,computed_advances_sum,advances_diff')
    .eq('entity_type', 'Unidade')
    .eq('entity_id', unit.id)
    .eq('period_start', periodStart)
    .eq('period_end', periodEnd)
    .maybeSingle();
  assert.ok(!concErr, `Erro na view de conciliação: ${concErr && concErr.message}`);
  assert.ok(conc, 'View v_repasses_conciliation não retornou linha');
  assert.strictEqual(round2(conc.advances_total), 20, 'advances_total deve somar adiantamentos');
  assert.strictEqual(round2(conc.computed_advances_sum), 20, 'computed_advances_sum deve somar adiantamentos');
  assert.strictEqual(round2(conc.advances_diff), 0, 'advances_diff deve ser 0');
  assert.strictEqual(round2(conc.gross_total), round2(unit.repass_value), 'gross_total incorreto');
  assert.strictEqual(round2(conc.net_total), round2(unit.repass_value - 20), 'net_total incorreto');
});