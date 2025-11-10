-- 0013_finance_views_audit.sql — views de conciliação e auditoria financeira

-- Enum de eventos financeiros
DO $$ BEGIN
  CREATE TYPE finance_event_type_enum AS ENUM (
    'InvoiceGenerated',
    'InvoicePaid',
    'AdvanceCreated',
    'RepassGenerated',
    'RepassPaid'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela de auditoria financeira
CREATE TABLE IF NOT EXISTS public.finance_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type finance_event_type_enum NOT NULL,
  entity_type negotiation_entity_enum,
  entity_id uuid,
  related_invoice_id uuid REFERENCES public.invoices (id) ON DELETE SET NULL,
  related_repass_id uuid REFERENCES public.repasses (id) ON DELETE SET NULL,
  amount numeric(12,2),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  note text,
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_finance_events_created_at
  BEFORE UPDATE ON public.finance_events
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.finance_events ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY finance_events_admin_full ON public.finance_events
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY finance_events_finance_select ON public.finance_events
    FOR SELECT TO authenticated
    USING (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY finance_events_finance_insert ON public.finance_events
    FOR INSERT TO authenticated
    WITH CHECK (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_finance_events_occurred_at ON public.finance_events (occurred_at);
CREATE INDEX IF NOT EXISTS idx_finance_events_event_type ON public.finance_events (event_type);
-- Função utilitária para registrar eventos
CREATE OR REPLACE FUNCTION public.log_finance_event(
  p_event_type finance_event_type_enum,
  p_entity_type negotiation_entity_enum,
  p_entity_id uuid,
  p_related_invoice_id uuid DEFAULT NULL,
  p_related_repass_id uuid DEFAULT NULL,
  p_amount numeric(12,2) DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.finance_events(event_type, entity_type, entity_id, related_invoice_id, related_repass_id, amount, occurred_at, note, metadata)
  VALUES (p_event_type, p_entity_type, p_entity_id, p_related_invoice_id, p_related_repass_id, p_amount, now(), p_note, COALESCE(p_metadata, '{}'));
END;
$$;
-- View de conciliação de repasses por período/entidade
CREATE OR REPLACE VIEW public.v_repasses_conciliation AS
SELECT
  r.entity_type,
  r.entity_id,
  r.period_start,
  r.period_end,
  SUM(r.gross_value) AS gross_total,
  SUM(r.advance_deduction) AS advances_total,
  SUM(r.net_value) AS net_total,
  SUM(CASE WHEN r.status = 'Paga' THEN r.net_value ELSE 0 END) AS paid_total,
  COUNT(*) AS repass_count,
  COALESCE((
    SELECT SUM(a.amount)
    FROM public.advances a
    WHERE a.entity_type = r.entity_type
      AND a.entity_id = r.entity_id
      AND a.advance_date BETWEEN r.period_start AND r.period_end
  ), 0) AS computed_advances_sum,
  COALESCE((
    SELECT SUM(a.amount)
    FROM public.advances a
    WHERE a.entity_type = r.entity_type
      AND a.entity_id = r.entity_id
      AND a.advance_date BETWEEN r.period_start AND r.period_end
  ), 0) - SUM(r.advance_deduction) AS advances_diff
FROM public.repasses r
GROUP BY r.entity_type, r.entity_id, r.period_start, r.period_end;
-- View de base de faturamento por profissional (faturas pagas associadas a turmas do profissional)
CREATE OR REPLACE VIEW public.v_invoices_by_teacher AS
SELECT
  p.id AS professional_id,
  i.id AS invoice_id,
  i.paid_at::date AS paid_date,
  i.amount_net
FROM public.invoices i
JOIN public.students s ON s.id = i.student_id
LEFT JOIN public.classes c ON c.id = s.class_id
JOIN public.professionals p ON p.id = ANY(c.teacher_ids)
WHERE i.status = 'Paga';
