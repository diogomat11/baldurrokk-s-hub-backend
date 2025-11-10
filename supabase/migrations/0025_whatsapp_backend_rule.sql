-- 0025_whatsapp_backend_rule.sql — Regra backend para template WhatsApp (Mensalidade vs Cobrança)

-- Ajusta a função de renderização para escolher o template conforme vencimento
CREATE OR REPLACE FUNCTION public.render_whatsapp_invoice_message(
  p_invoice_id uuid
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec_inv RECORD;
  rec_st RECORD;
  v_default_template text;
  v_template text;
  v_pix text;
  v_pix_type pix_key_type_enum;
  v_pix_type_label text;
  v_amount text;
  v_month text;
  v_msg text;
  v_is_overdue boolean;
BEGIN
  SELECT * INTO rec_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % not found', p_invoice_id; END IF;

  SELECT * INTO rec_st FROM public.students WHERE id = rec_inv.student_id;

  -- Carrega config padrão (PIX e template legado)
  SELECT s.whatsapp_template_invoice, s.pix_key, s.pix_key_type
    INTO v_default_template, v_pix, v_pix_type
  FROM public.settings s
  ORDER BY s.updated_at DESC
  LIMIT 1;

  -- Determina se está vencida pelo due_date e status não pago/cancelado
  v_is_overdue := (rec_inv.due_date < current_date) AND (rec_inv.status <> 'Paga') AND (rec_inv.status <> 'Cancelada');

  -- Busca template na tabela de integrações
  SELECT i.whatsapp_template
    INTO v_template
  FROM public.integrations i
  WHERE i.id = CASE WHEN v_is_overdue THEN 'whatsapp:cobranca:cobranca' ELSE 'whatsapp:cobranca:mensalidade' END
  LIMIT 1;

  -- Fallbacks
  IF v_template IS NULL THEN
    -- Se não houver template específico em integrations, usa um texto padrão amigável
    IF v_is_overdue THEN
      v_template := 'Olá {{guardian_name}}, segue abaixo valor da mensalidade do aluno(a) {{student_name}}, referente ao mês {{month}} vencido em {{due_date}}.\nAbaixo chave PIX para pagamento {{pix_type}} - {{pix_key}}.\nLembramos que atrasos podem implicar em suspensão das aulas';
    ELSE
      v_template := 'Olá {{guardian_name}}, segue abaixo valor da mensalidade do aluno(a) {{student_name}}, referente ao mês {{month}} vencimento em {{due_date}}, abaixo chave PIX para pagamento {{pix_type}} - {{pix_key}}';
    END IF;
  END IF;

  IF v_default_template IS NULL THEN
    v_default_template := 'Olá {{student_name}}, sua mensalidade de R$ {{amount}} vence em {{due_date}}. Pague via PIX: {{pix_key}}. Fatura: {{invoice_id}}.';
  END IF;

  -- Formata valor (pt-BR típico: 1.234,56) e mês
  v_amount := to_char(rec_inv.amount_net, 'FM999G999G990D00');
  v_month := to_char(rec_inv.due_date, 'MM/YYYY');

  -- Tipo da chave PIX (label amigável)
  IF v_pix_type IS NULL AND v_pix IS NOT NULL THEN
    v_pix_type := public.detect_pix_key_type(v_pix);
  END IF;
  v_pix_type_label := CASE v_pix_type
    WHEN 'phone' THEN 'Telefone'
    WHEN 'cpf' THEN 'CPF'
    WHEN 'cnpj' THEN 'CNPJ'
    WHEN 'email' THEN 'Email'
    WHEN 'random' THEN 'Chave aleatória'
    ELSE 'PIX'
  END;

  -- Preenche variáveis (suporta {{variavel}} e [variavel])
  v_msg := COALESCE(v_template, v_default_template);
  -- Moustache
  v_msg := replace(v_msg, '{{guardian_name}}', COALESCE(rec_st.guardian_name, 'Responsável'));
  v_msg := replace(v_msg, '{{student_name}}', COALESCE(rec_st.name, 'Aluno'));
  v_msg := replace(v_msg, '{{due_date}}', to_char(rec_inv.due_date, 'DD/MM/YYYY'));
  v_msg := replace(v_msg, '{{amount}}', v_amount);
  v_msg := replace(v_msg, '{{pix_key}}', COALESCE(v_pix, ''));
  v_msg := replace(v_msg, '{{pix_type}}', COALESCE(v_pix_type_label, 'PIX'));
  v_msg := replace(v_msg, '{{invoice_id}}', p_invoice_id::text);
  v_msg := replace(v_msg, '{{month}}', COALESCE(v_month, ''));
  -- Brackets (variações)
  v_msg := replace(v_msg, '[responsável]', COALESCE(rec_st.guardian_name, 'Responsável'));
  v_msg := replace(v_msg, '[responsavel]', COALESCE(rec_st.guardian_name, 'Responsável'));
  v_msg := replace(v_msg, '[nomeAluno]', COALESCE(rec_st.name, 'Aluno'));
  v_msg := replace(v_msg, '[nome aluno]', COALESCE(rec_st.name, 'Aluno'));
  v_msg := replace(v_msg, '[aluno]', COALESCE(rec_st.name, 'Aluno'));
  v_msg := replace(v_msg, '[mês]', COALESCE(v_month, ''));
  v_msg := replace(v_msg, '[mes]', COALESCE(v_month, ''));
  v_msg := replace(v_msg, '[dataVencimento]', to_char(rec_inv.due_date, 'DD/MM/YYYY'));
  v_msg := replace(v_msg, '[data_vencimento]', to_char(rec_inv.due_date, 'DD/MM/YYYY'));
  v_msg := replace(v_msg, '[valor]', v_amount);
  v_msg := replace(v_msg, '[tipo chave]', COALESCE(v_pix_type_label, 'PIX'));
  v_msg := replace(v_msg, '[tipo_chave]', COALESCE(v_pix_type_label, 'PIX'));
  v_msg := replace(v_msg, '[chave pix]', COALESCE(v_pix, ''));
  v_msg := replace(v_msg, '[chave_pix]', COALESCE(v_pix, ''));

  RETURN v_msg;
END;
$$;