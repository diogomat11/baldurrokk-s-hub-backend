require('dotenv').config();
const { supabase } = require('./supabase');

async function ensureOne(table, match, createPayload) {
  const { data: found, error: findError } = await supabase
    .from(table)
    .select('*')
    .match(match)
    .limit(1)
    .maybeSingle();
  if (findError && findError.message !== 'supabase_not_configured') throw findError;
  if (found) return found;
  const payload = typeof createPayload === 'function' ? await createPayload() : createPayload;
  const { data: inserted, error: insertError } = await supabase
    .from(table)
    .insert(payload)
    .select()
    .maybeSingle();
  if (insertError) throw insertError;
  return inserted;
}

function todayStr(offsetDays = 0) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

function monthBounds(date = new Date()) {
  const y = date.getFullYear();
  const m = date.getMonth();
  const start = new Date(y, m, 1);
  const end = new Date(y, m + 1, 0);
  const toStr = (d) => d.toISOString().slice(0, 10);
  return { startStr: toStr(start), endStr: toStr(end) };
}

async function main() {
  console.log('[seed] starting');
  // Settings for PIX and WhatsApp template
  const settings = await ensureOne('settings', {}, {
    pix_key: process.env.SEED_PIX_KEY || 'chave-pix-dev-000201010212BR.GOV.BCB.PIX12345',
    whatsapp_template_invoice:
      process.env.SEED_WHATSAPP_TEMPLATE ||
      'Olá {{student_name}}, sua mensalidade {{month}} vence em {{due_date}} no valor de R$ {{amount}}. Chave PIX: {{pix_key}}.'
  });
  console.log('[seed] settings ok', settings.id);

  // Network
  const network = await ensureOne('networks', { name: 'Coelho FC' }, {
    name: 'Coelho FC',
    description: 'Rede principal para testes'
  });
  console.log('[seed] network ok', network.id);

  // Unit
  const unit = await ensureOne('units', { name: 'Unidade Centro' }, {
    network_id: network.id,
    manager_user_id: null,
    name: 'Unidade Centro',
    address: 'Rua das Flores, 100',
    city: 'São Paulo',
    state: 'SP',
    cep: '01000-000',
    phone: '+5511999999999',
    email: 'centro@coelho-fc.test',
    repass_type: 'Percentual',
    repass_value: 20,
    status: 'Ativo'
  });
  console.log('[seed] unit ok', unit.id);

  // Class
  const classRow = await ensureOne('classes', { name: 'Turma A - Sub12', unit_id: unit.id }, {
    unit_id: unit.id,
    name: 'Turma A - Sub12',
    category: 'Futsal',
    vacancies: 30,
    status: 'Ativo',
    schedule: [
      { weekday: 'Terça', start: '18:00', end: '19:00' },
      { weekday: 'Quinta', start: '18:00', end: '19:00' }
    ],
    teacher_ids: []
  });
  console.log('[seed] class ok', classRow.id);

  // Plan
  const plan = await ensureOne('plans', { name: 'Plano Mensal', unit_id: unit.id }, {
    name: 'Plano Mensal',
    unit_id: unit.id,
    frequency_per_week: 2,
    value: 120.0,
    start_date: todayStr(-30),
    end_date: null,
    status: 'Ativo'
  });
  console.log('[seed] plan ok', plan.id);

  // Recurrence (Mensal, 10% desconto, aplicável à unidade)
  const recurrence = await ensureOne('recurrences', { type: 'Mensal', status: 'Ativo' }, {
    type: 'Mensal',
    discount_percent: 10,
    start_date: todayStr(-1),
    end_date: null,
    units_applicable: [unit.id],
    status: 'Ativo'
  });
  console.log('[seed] recurrence ok', recurrence.id);

  // Proportional (mês atual, 50% desconto)
  const { startStr: pStart, endStr: pEnd } = monthBounds();
  const proportional = await ensureOne('proportionals', { start_period: pStart, end_period: pEnd }, {
    start_period: pStart,
    end_period: pEnd,
    discount_percent: 50,
    status: 'Ativo'
  });
  console.log('[seed] proportional ok', proportional.id, { start: pStart, end: pEnd });

  // Student 1
  const student = await ensureOne('students', { name: 'Aluno Teste', unit_id: unit.id }, {
    name: 'Aluno Teste',
    cpf: '123.456.789-00',
    birthdate: '2012-05-20',
    unit_id: unit.id,
    class_id: classRow.id,
    plan_id: plan.id,
    start_date: todayStr(-15),
    payment_method: 'PIX',
    guardian_name: 'Responsável Teste',
    guardian_phone: '+5511999999999',
    guardian_email: 'responsavel@coelho-fc.test',
    status: 'Ativo'
  });
  console.log('[seed] student1 ok', student.id);
  if (!student.recurrence_id) {
    const { error: updErr1 } = await supabase.from('students').update({ recurrence_id: recurrence.id }).eq('id', student.id);
    if (updErr1) throw updErr1;
    console.log('[seed] student1 recurrence linked');
  }

  // Student 2
  const student2 = await ensureOne('students', { name: 'Aluno Dois', unit_id: unit.id }, {
    name: 'Aluno Dois',
    cpf: '987.654.321-00',
    birthdate: '2011-04-10',
    unit_id: unit.id,
    class_id: classRow.id,
    plan_id: plan.id,
    start_date: todayStr(-3),
    payment_method: 'PIX',
    guardian_name: 'Outro Responsável',
    guardian_phone: '+5511997777666',
    guardian_email: 'outro.responsavel@coelho-fc.test',
    status: 'Ativo'
  });
  console.log('[seed] student2 ok', student2.id);
  if (!student2.recurrence_id) {
    const { error: updErr2 } = await supabase.from('students').update({ recurrence_id: recurrence.id }).eq('id', student2.id);
    if (updErr2) throw updErr2;
    console.log('[seed] student2 recurrence linked');
  }

  // Generate invoices for active students (finance RPC)
  const dueDay = parseInt(process.env.SEED_DUE_DAY || '5', 10);
  const genDate = todayStr();
  console.log('[seed] generating invoices', { genDate, dueDay });
  const genRes = await supabase.rpc('generate_invoices_for_active_students', {
    p_generation_date: genDate,
    p_due_day: dueDay
  });
  if (genRes.error) throw genRes.error;
  console.log('[seed] invoices generated');

  // Fetch invoice for student1
  const { data: inv1, error: invErr1 } = await supabase
    .from('invoices')
    .select('*')
    .eq('student_id', student.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (invErr1) throw invErr1;
  console.log('[seed] invoice1', inv1?.id || null, { due_date: inv1?.due_date, total: inv1?.amount_total, discount: inv1?.amount_discount, net: inv1?.amount_net });

  // Fetch invoice for student2
  const { data: inv2, error: invErr2 } = await supabase
    .from('invoices')
    .select('*')
    .eq('student_id', student2.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (invErr2) throw invErr2;
  console.log('[seed] invoice2', inv2?.id || null, { due_date: inv2?.due_date, total: inv2?.amount_total, discount: inv2?.amount_discount, net: inv2?.amount_net });

  // Optionally queue WhatsApp outbox for both invoices
  if (process.env.SEED_QUEUE_WHATSAPP === 'true') {
    console.log('[seed] queueing whatsapp outbox for inv1/inv2');
    if (inv1?.id) {
      const qRes1 = await supabase.rpc('queue_invoice_whatsapp', { p_invoice_id: inv1.id, p_phone_override: null });
      if (qRes1.error) throw qRes1.error;
    }
    if (inv2?.id) {
      const qRes2 = await supabase.rpc('queue_invoice_whatsapp', { p_invoice_id: inv2.id, p_phone_override: null });
      if (qRes2.error) throw qRes2.error;
    }
    console.log('[seed] whatsapp queued for available invoices');
  } else {
    console.log('[seed] skipping whatsapp queue (set SEED_QUEUE_WHATSAPP=true to enable)');
  }

  console.log('[seed] done');
}

main().catch((err) => {
  console.error('[seed] error', err);
  process.exit(1);
});