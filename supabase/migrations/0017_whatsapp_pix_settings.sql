-- 0017_whatsapp_pix_settings.sql — Configurações (Pix) e Template WhatsApp

-- Tabela de configurações (pix_key e template de WhatsApp para faturas)
CREATE TABLE IF NOT EXISTS public.settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pix_key text,
  whatsapp_template_invoice text NOT NULL DEFAULT 'Olá {{student_name}}, sua mensalidade de R$ {{amount}} vence em {{due_date}}. Pague via PIX: {{pix_key}}. Fatura: {{invoice_id}}.',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Trigger de atualização de updated_at
DO $$ BEGIN
  CREATE TRIGGER set_settings_updated_at
  BEFORE UPDATE ON public.settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- RLS e Policies
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY settings_admin_full ON public.settings
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY settings_finance_select ON public.settings
    FOR SELECT TO authenticated
    USING (public.is_finance() OR public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Linha padrão: inserir se ainda não existir
INSERT INTO public.settings (pix_key, whatsapp_template_invoice)
SELECT NULL, 'Olá {{student_name}}, sua mensalidade de R$ {{amount}} vence em {{due_date}}. Pague via PIX: {{pix_key}}. Fatura: {{invoice_id}}.'
WHERE NOT EXISTS (SELECT 1 FROM public.settings);
-- Função para renderizar mensagem de WhatsApp da fatura, usando template e chave PIX
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
  v_template text;
  v_pix text;
  v_amount text;
  v_msg text;
BEGIN
  SELECT * INTO rec_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % not found', p_invoice_id; END IF;

  SELECT * INTO rec_st FROM public.students WHERE id = rec_inv.student_id;

  SELECT s.whatsapp_template_invoice, s.pix_key
    INTO v_template, v_pix
  FROM public.settings s
  ORDER BY s.updated_at DESC
  LIMIT 1;

  IF v_template IS NULL THEN
    v_template := 'Olá {{student_name}}, sua mensalidade de R$ {{amount}} vence em {{due_date}}. Pague via PIX: {{pix_key}}. Fatura: {{invoice_id}}.';
  END IF;

  -- Formata valor (pt-BR típico: 1.234,56)
  v_amount := to_char(rec_inv.amount_net, 'FM999G999G990D00');

  v_msg := v_template;
  v_msg := replace(v_msg, '{{student_name}}', COALESCE(rec_st.name, ''));
  v_msg := replace(v_msg, '{{due_date}}', to_char(rec_inv.due_date, 'DD/MM/YYYY'));
  v_msg := replace(v_msg, '{{amount}}', v_amount);
  v_msg := replace(v_msg, '{{pix_key}}', COALESCE(v_pix, ''));
  v_msg := replace(v_msg, '{{invoice_id}}', p_invoice_id::text);

  RETURN v_msg;
END;
$$;
