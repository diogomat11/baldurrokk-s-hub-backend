-- 0027_financial_improvements.sql

-- 1. Create table for payment proofs
CREATE TABLE IF NOT EXISTS public.payment_proofs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid REFERENCES public.invoices (id) ON DELETE CASCADE,
  repass_id uuid REFERENCES public.repasses (id) ON DELETE CASCADE,
  url text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT check_reference CHECK (
    (invoice_id IS NOT NULL AND repass_id IS NULL) OR
    (invoice_id IS NULL AND repass_id IS NOT NULL)
  )
);
ALTER TABLE public.payment_proofs ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY payment_proofs_admin_full ON public.payment_proofs FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 2. Add origin_month to repasses
ALTER TABLE public.repasses ADD COLUMN IF NOT EXISTS origin_month date;

-- 3. Update generate_invoices_for_active_students
CREATE OR REPLACE FUNCTION public.generate_invoices_for_active_students(p_generation_date date DEFAULT current_date, p_due_day integer DEFAULT 10)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_count integer := 0;
  v_student record;
  v_plan record;
  v_due_date date;
  v_today date := CURRENT_DATE;
  v_target_due_date date;
BEGIN
  -- Determine due date logic
  -- If p_due_day is passed, construct date from p_generation_date's month
  -- Logic requirement: due date is 10th. If today > 10th, due date = today + 1
  -- We'll assume p_due_day is typically 10 from frontend, but we enforce the rule here.
  
  v_target_due_date := make_date(EXTRACT(year FROM p_generation_date)::int, EXTRACT(month FROM p_generation_date)::int, 10);
  
  -- Check if generating for current month and past the 10th
  IF EXTRACT(month FROM v_today) = EXTRACT(month FROM p_generation_date) AND EXTRACT(year FROM v_today) = EXTRACT(year FROM p_generation_date) THEN
      IF EXTRACT(day FROM v_today) > 10 THEN
          v_target_due_date := v_today + 1;
      END IF;
  END IF;
  
  v_due_date := v_target_due_date;

  FOR v_student IN
    SELECT s.id, s.unit_id, s.plan_id, s.recurrence_id, s.payment_method
    FROM public.students s
    WHERE s.status = 'Ativo'
    AND s.plan_id IS NOT NULL
  LOOP
    -- DUPLICATE CHECK: Skip if active invoice exists for this student in this month
    -- We check if there is an invoice for same student, same month/year of due_date, that is NOT Cancelled
    PERFORM 1 FROM public.invoices i
    WHERE i.student_id = v_student.id
      AND EXTRACT(month FROM i.due_date) = EXTRACT(month FROM v_due_date)
      AND EXTRACT(year FROM i.due_date) = EXTRACT(year FROM v_due_date)
      AND i.status != 'Cancelada';
      
    IF NOT FOUND THEN
        SELECT * INTO v_plan FROM public.plans WHERE id = v_student.plan_id;
        
        IF v_plan IS NOT NULL THEN
          INSERT INTO public.invoices (student_id, unit_id, plan_id, recurrence_id, due_date, amount_total, amount_net, payment_method, status)
          VALUES (v_student.id, v_student.unit_id, v_student.plan_id, v_student.recurrence_id, v_due_date, v_plan.value, v_plan.value, COALESCE(v_student.payment_method, 'PIX'), 'Aberta');
          v_count := v_count + 1;
        END IF;
    END IF;
  END LOOP;
  RETURN v_count;
END;
$function$;

-- 4. Update mark_invoice_paid to handle proofs and advances
CREATE OR REPLACE FUNCTION public.mark_invoice_paid(p_invoice_id uuid, p_payment_method payment_method_enum, p_paid_at timestamptz DEFAULT now(), p_receipt_url text DEFAULT NULL, p_professional_id uuid DEFAULT NULL)
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
