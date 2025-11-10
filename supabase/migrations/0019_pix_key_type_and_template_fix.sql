-- 0019_pix_key_type_and_template_fix.sql — Tipo da chave PIX e correção do template WhatsApp

-- Enum para tipo de chave PIX
DO $$ BEGIN
  CREATE TYPE pix_key_type_enum AS ENUM ('phone', 'cpf', 'cnpj', 'email', 'random');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Adiciona coluna pix_key_type em public.settings
DO $$ BEGIN
  ALTER TABLE public.settings ADD COLUMN pix_key_type pix_key_type_enum;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- Função auxiliar para detectar tipo da chave PIX
CREATE OR REPLACE FUNCTION public.detect_pix_key_type(p_key text)
RETURNS pix_key_type_enum
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s text := COALESCE(p_key, '');
  digits text := regexp_replace(COALESCE(p_key, ''), '\\D', '', 'g');
BEGIN
  IF s = '' THEN RETURN NULL; END IF;
  IF s ~ '.+@.+\\..+' THEN RETURN 'email'; END IF;
  IF length(digits) = 11 THEN RETURN 'cpf'; END IF;
  IF length(digits) = 14 THEN RETURN 'cnpj'; END IF;
  IF length(digits) BETWEEN 10 AND 15 THEN RETURN 'phone'; END IF;
  RETURN 'random';
END;
$$;
-- Popula pix_key_type com base na chave existente, se estiver nulo
UPDATE public.settings s
SET pix_key_type = public.detect_pix_key_type(s.pix_key), updated_at = now()
WHERE s.pix_key IS NOT NULL AND s.pix_key_type IS NULL;
-- Corrige função de renderização para incluir {{pix_key}} e {{month}}
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
  v_month text;
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
  v_month := to_char(rec_inv.due_date, 'MM/YYYY');

  v_msg := v_template;
  v_msg := replace(v_msg, '{{student_name}}', COALESCE(rec_st.name, ''));
  v_msg := replace(v_msg, '{{due_date}}', to_char(rec_inv.due_date, 'DD/MM/YYYY'));
  v_msg := replace(v_msg, '{{amount}}', v_amount);
  v_msg := replace(v_msg, '{{invoice_id}}', p_invoice_id::text);
  v_msg := replace(v_msg, '{{pix_key}}', COALESCE(v_pix, ''));
  v_msg := replace(v_msg, '{{month}}', COALESCE(v_month, ''));

  RETURN v_msg;
END;
$$;
