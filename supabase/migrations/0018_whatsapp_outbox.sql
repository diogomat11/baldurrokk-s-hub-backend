-- 0018_whatsapp_outbox.sql — Fila de envio de WhatsApp (outbox) e funções

-- Enum de status da saída WhatsApp
DO $$ BEGIN
  CREATE TYPE whatsapp_status_enum AS ENUM ('Pending', 'Sent', 'Failed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela outbox para mensagens de WhatsApp
CREATE TABLE IF NOT EXISTS public.whatsapp_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid REFERENCES public.invoices (id) ON DELETE CASCADE,
  student_id uuid REFERENCES public.students (id) ON DELETE CASCADE,
  unit_id uuid REFERENCES public.units (id) ON DELETE RESTRICT,
  phone text NOT NULL,
  message text NOT NULL,
  status whatsapp_status_enum NOT NULL DEFAULT 'Pending',
  attempts int NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Trigger updated_at
DO $$ BEGIN
  CREATE TRIGGER set_whatsapp_outbox_updated_at
  BEFORE UPDATE ON public.whatsapp_outbox
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Índices úteis
CREATE INDEX IF NOT EXISTS idx_whatsapp_outbox_status ON public.whatsapp_outbox (status);
CREATE INDEX IF NOT EXISTS idx_whatsapp_outbox_created_at ON public.whatsapp_outbox (created_at);
-- RLS e policies
ALTER TABLE public.whatsapp_outbox ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY whatsapp_outbox_admin_full ON public.whatsapp_outbox
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY whatsapp_outbox_finance_select ON public.whatsapp_outbox
    FOR SELECT TO authenticated
    USING (public.is_finance() OR public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY whatsapp_outbox_finance_insert ON public.whatsapp_outbox
    FOR INSERT TO authenticated
    WITH CHECK (public.is_finance() OR public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- View: itens pendentes
CREATE OR REPLACE VIEW public.v_whatsapp_outbox_pending AS
SELECT * FROM public.whatsapp_outbox WHERE status = 'Pending' ORDER BY created_at ASC;
-- Função: enfileirar envio de WhatsApp para fatura
CREATE OR REPLACE FUNCTION public.queue_invoice_whatsapp(
  p_invoice_id uuid,
  p_phone_override text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec_inv RECORD;
  rec_st RECORD;
  v_phone text;
  v_msg text;
  v_outbox_id uuid;
BEGIN
  SELECT * INTO rec_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % not found', p_invoice_id; END IF;

  SELECT * INTO rec_st FROM public.students WHERE id = rec_inv.student_id;

  v_phone := COALESCE(NULLIF(p_phone_override, ''), NULLIF(rec_st.guardian_phone, ''));
  IF v_phone IS NULL THEN
    RAISE EXCEPTION 'Guardian phone not found for student %', rec_st.id;
  END IF;

  v_msg := public.render_whatsapp_invoice_message(p_invoice_id);

  INSERT INTO public.whatsapp_outbox(invoice_id, student_id, unit_id, phone, message, status)
  VALUES (p_invoice_id, rec_st.id, rec_st.unit_id, v_phone, v_msg, 'Pending')
  RETURNING id INTO v_outbox_id;

  RETURN v_outbox_id;
END;
$$;
-- Funções: marcar como enviado ou falha (para integração/processador)
CREATE OR REPLACE FUNCTION public.mark_whatsapp_sent(
  p_outbox_id uuid,
  p_sent_at timestamptz DEFAULT now()
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.whatsapp_outbox
    SET status = 'Sent', last_attempt_at = p_sent_at, attempts = attempts + 1, updated_at = now(), error = NULL
    WHERE id = p_outbox_id;
END;
$$;
CREATE OR REPLACE FUNCTION public.mark_whatsapp_failed(
  p_outbox_id uuid,
  p_error text,
  p_attempted_at timestamptz DEFAULT now()
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.whatsapp_outbox
    SET status = 'Failed', last_attempt_at = p_attempted_at, attempts = attempts + 1, updated_at = now(), error = p_error
    WHERE id = p_outbox_id;
END;
$$;
