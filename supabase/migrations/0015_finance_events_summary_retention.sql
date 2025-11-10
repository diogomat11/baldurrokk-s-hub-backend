-- 0015_finance_events_summary_retention.sql — resumo por período e retenção de auditoria

-- Índice composto para acelerar agregações por entidade/período
CREATE INDEX IF NOT EXISTS idx_finance_events_entity_period ON public.finance_events(entity_type, entity_id, occurred_at);
-- View mensal: consolida eventos e valores por entidade
CREATE OR REPLACE VIEW public.v_finance_events_monthly AS
SELECT
  e.entity_type,
  e.entity_id,
  date_trunc('month', e.occurred_at)::date AS period_month,
  COUNT(*) FILTER (WHERE e.event_type = 'InvoiceGenerated') AS invoices_generated_count,
  COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'InvoiceGenerated'), 0) AS invoices_generated_amount,
  COUNT(*) FILTER (WHERE e.event_type = 'InvoicePaid') AS invoices_paid_count,
  COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'InvoicePaid'), 0) AS invoices_paid_amount,
  COUNT(*) FILTER (WHERE e.event_type = 'AdvanceCreated') AS advances_created_count,
  COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'AdvanceCreated'), 0) AS advances_created_amount,
  COUNT(*) FILTER (WHERE e.event_type = 'RepassGenerated') AS repasses_generated_count,
  COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'RepassGenerated'), 0) AS repasses_generated_amount,
  COUNT(*) FILTER (WHERE e.event_type = 'RepassPaid') AS repasses_paid_count,
  COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'RepassPaid'), 0) AS repasses_paid_amount
FROM public.finance_events e
GROUP BY e.entity_type, e.entity_id, date_trunc('month', e.occurred_at)::date;
-- Função de resumo por período (parametrizável)
CREATE OR REPLACE FUNCTION public.get_finance_events_summary(
  p_start date,
  p_end date,
  p_entity_type negotiation_entity_enum DEFAULT NULL,
  p_entity_id uuid DEFAULT NULL
)
RETURNS TABLE (
  entity_type negotiation_entity_enum,
  entity_id uuid,
  period_start date,
  period_end date,
  invoices_generated_count int,
  invoices_generated_amount numeric(12,2),
  invoices_paid_count int,
  invoices_paid_amount numeric(12,2),
  advances_created_count int,
  advances_created_amount numeric(12,2),
  repasses_generated_count int,
  repasses_generated_amount numeric(12,2),
  repasses_paid_count int,
  repasses_paid_amount numeric(12,2)
)
LANGUAGE sql STABLE
AS $$
  SELECT
    e.entity_type,
    e.entity_id,
    p_start AS period_start,
    p_end AS period_end,
    COUNT(*) FILTER (WHERE e.event_type = 'InvoiceGenerated') AS invoices_generated_count,
    COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'InvoiceGenerated'), 0) AS invoices_generated_amount,
    COUNT(*) FILTER (WHERE e.event_type = 'InvoicePaid') AS invoices_paid_count,
    COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'InvoicePaid'), 0) AS invoices_paid_amount,
    COUNT(*) FILTER (WHERE e.event_type = 'AdvanceCreated') AS advances_created_count,
    COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'AdvanceCreated'), 0) AS advances_created_amount,
    COUNT(*) FILTER (WHERE e.event_type = 'RepassGenerated') AS repasses_generated_count,
    COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'RepassGenerated'), 0) AS repasses_generated_amount,
    COUNT(*) FILTER (WHERE e.event_type = 'RepassPaid') AS repasses_paid_count,
    COALESCE(SUM(e.amount) FILTER (WHERE e.event_type = 'RepassPaid'), 0) AS repasses_paid_amount
  FROM public.finance_events e
  WHERE e.occurred_at::date BETWEEN p_start AND p_end
    AND (p_entity_type IS NULL OR e.entity_type = p_entity_type)
    AND (p_entity_id IS NULL OR e.entity_id = p_entity_id)
  GROUP BY e.entity_type, e.entity_id
$$;
-- Função de retenção: apaga eventos mais antigos que N meses (somente Admin)
CREATE OR REPLACE FUNCTION public.purge_old_finance_events(
  p_keep_months int DEFAULT 12
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff timestamptz := now() - make_interval(months => GREATEST(p_keep_months, 1));
  v_deleted integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'insufficient_privilege: admin required';
  END IF;

  DELETE FROM public.finance_events WHERE occurred_at < v_cutoff;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted;
END;
$$;
