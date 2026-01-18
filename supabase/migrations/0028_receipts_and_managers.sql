-- 0028_receipts_and_managers.sql

-- 1. Create 'receipts' storage bucket for generic financial proofs
INSERT INTO storage.buckets (id, name, public)
VALUES ('receipts', 'receipts', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Policies for 'receipts' bucket
DO $$ BEGIN
  CREATE POLICY receipts_select_all ON storage.objects
    FOR SELECT TO public
    USING (bucket_id = 'receipts');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY receipts_insert_authenticated ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'receipts');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY receipts_update_admin ON storage.objects
    FOR UPDATE TO authenticated
    USING (bucket_id = 'receipts' AND public.is_admin())
    WITH CHECK (bucket_id = 'receipts' AND public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY receipts_delete_admin ON storage.objects
    FOR DELETE TO authenticated
    USING (bucket_id = 'receipts' AND public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 2. Add manager_ids to units table
ALTER TABLE public.units ADD COLUMN IF NOT EXISTS manager_ids uuid[] DEFAULT '{}';
CREATE INDEX IF NOT EXISTS idx_units_manager_ids ON public.units USING GIN (manager_ids);

-- 3. Add receipt_url to invoices
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS receipt_url text;

-- 4. Update list_invoices_for_month to include receipt_url
DROP FUNCTION IF EXISTS public.list_invoices_for_month(date, uuid, invoice_status_enum);

CREATE OR REPLACE FUNCTION public.list_invoices_for_month(
  p_month date,
  p_unit_id uuid DEFAULT NULL,
  p_status invoice_status_enum DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  student_id uuid,
  student_name text,
  unit_id uuid,
  unit_name text,
  status invoice_status_enum,
  due_date date,
  amount_total numeric(12,2),
  amount_discount numeric(12,2),
  amount_net numeric(12,2),
  receipt_url text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    i.id,
    i.student_id,
    s.name AS student_name,
    i.unit_id,
    u.name AS unit_name,
    (
      CASE
        WHEN i.status <> 'Paga' AND i.status <> 'Cancelada' AND i.due_date < current_date THEN 'Vencida'
        ELSE i.status
      END
    )::invoice_status_enum AS status,
    i.due_date,
    i.amount_total,
    i.amount_discount,
    i.amount_net,
    i.receipt_url
  FROM public.invoices i
  LEFT JOIN public.students s ON s.id = i.student_id
  LEFT JOIN public.units u ON u.id = i.unit_id
  WHERE i.due_date >= date_trunc('month', p_month)::date
    AND i.due_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
    AND (p_unit_id IS NULL OR i.unit_id = p_unit_id)
    AND (p_status IS NULL OR i.status = p_status)
  ORDER BY i.due_date ASC;
$$;

-- 5. Update mark_invoice_paid to save receipt_url in invoices table too
CREATE OR REPLACE FUNCTION public.mark_invoice_paid(
  p_invoice_id uuid,
  p_payment_method payment_method_enum,
  p_paid_at timestamptz DEFAULT now(),
  p_receipt_url text DEFAULT NULL,
  p_professional_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_amount numeric;
  v_unit_id uuid;
BEGIN
  UPDATE public.invoices
  SET status = 'Paga',
      payment_method = p_payment_method,
      paid_at = p_paid_at,
      receipt_url = p_receipt_url,
      updated_at = now()
  WHERE id = p_invoice_id
  RETURNING amount_net, unit_id INTO v_amount, v_unit_id;

  IF p_receipt_url IS NOT NULL THEN
    INSERT INTO public.payment_proofs (invoice_id, url) VALUES (p_invoice_id, p_receipt_url);
  END IF;

  -- Logic for Cash Payment -> Advance for Teacher
  IF p_payment_method = 'Dinheiro' AND p_professional_id IS NOT NULL THEN
      INSERT INTO public.advances (entity_type, entity_id, unit_id, amount, advance_date, status)
      VALUES ('Equipe', p_professional_id, v_unit_id, v_amount, p_paid_at::date, 'Aberta');
  END IF;
END;
$function$;
