-- 0016_repasses_receipts_storage.sql — anexos/recibos de repasses (Storage + função)

-- Criar bucket de Storage para comprovantes de repasses
INSERT INTO storage.buckets (id, name, public)
VALUES ('repasses', 'repasses', false)
ON CONFLICT (id) DO NOTHING;
-- Policies de Storage para o bucket 'repasses'
DO $$ BEGIN
  CREATE POLICY repasses_receipts_finance_select ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'repasses' AND (public.is_finance() OR public.is_admin()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY repasses_receipts_finance_insert ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'repasses' AND (public.is_finance() OR public.is_admin()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY repasses_receipts_admin_update ON storage.objects
    FOR UPDATE TO authenticated
    USING (bucket_id = 'repasses' AND public.is_admin())
    WITH CHECK (bucket_id = 'repasses' AND public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY repasses_receipts_admin_delete ON storage.objects
    FOR DELETE TO authenticated
    USING (bucket_id = 'repasses' AND public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Campo de recibo no repasse
DO $$ BEGIN
  ALTER TABLE public.repasses ADD COLUMN IF NOT EXISTS receipt_url text;
EXCEPTION WHEN others THEN NULL; END $$;
-- Função: marcar repasse pago com recibo (atualiza e loga auditoria)
CREATE OR REPLACE FUNCTION public.mark_repass_paid(
  p_repass_id uuid,
  p_paid_at timestamptz DEFAULT now(),
  p_receipt_url text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec_r RECORD;
BEGIN
  SELECT * INTO rec_r FROM public.repasses WHERE id = p_repass_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Repass % not found', p_repass_id; END IF;

  UPDATE public.repasses
    SET status = 'Paga', paid_at = p_paid_at, receipt_url = p_receipt_url, updated_at = now()
    WHERE id = p_repass_id;

  -- Log auditoria com recibo
  PERFORM public.log_finance_event(
    'RepassPaid', rec_r.entity_type, rec_r.entity_id,
    NULL, p_repass_id, rec_r.net_value,
    'Repasse marcado como pago',
    jsonb_build_object(
      'period_start', rec_r.period_start,
      'period_end', rec_r.period_end,
      'receipt_url', p_receipt_url
    )
  );
END;
$$;
-- Wrapper de compatibilidade (2 argumentos) chama a versão com recibo NULL
CREATE OR REPLACE FUNCTION public.mark_repass_paid(
  p_repass_id uuid,
  p_paid_at timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.mark_repass_paid(p_repass_id, p_paid_at, NULL);
END;
$$;
