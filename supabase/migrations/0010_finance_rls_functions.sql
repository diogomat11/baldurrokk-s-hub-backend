-- 0010_finance_rls_functions.sql — RLS granular e funções de financeiro

-- Funções auxiliares de papel
CREATE OR REPLACE FUNCTION public.is_manager()
RETURNS boolean AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role = 'Gerente'
  );
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION public.is_finance()
RETURNS boolean AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role = 'Financeiro'
  );
$$ LANGUAGE sql STABLE;
-- Ajuste de schema: recibo/arquivo de comprovante na fatura
DO $$ BEGIN
  ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS receipt_url text;
EXCEPTION WHEN others THEN NULL; END $$;
-- Função: geração de mensalidades para alunos ativos
CREATE OR REPLACE FUNCTION public.generate_invoices_for_active_students(
  p_generation_date date DEFAULT current_date,
  p_due_day int DEFAULT 5
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
  v_month_start date := date_trunc('month', p_generation_date)::date;
  v_month_last_day date := (date_trunc('month', p_generation_date) + interval '1 month - 1 day')::date;
  v_due_date date := v_month_start + (LEAST(p_due_day, EXTRACT(day FROM v_month_last_day)::int) - 1);
  rec_student RECORD;
  v_total numeric(12,2);
  v_rec_discount numeric(5,2) := 0;
  v_prop_discount numeric(5,2) := 0;
  v_discount_amount numeric(12,2);
  v_net numeric(12,2);
  v_first_invoice boolean;
BEGIN
  FOR rec_student IN
    SELECT s.*, p.value AS plan_value
    FROM public.students s
    LEFT JOIN public.plans p ON p.id = s.plan_id
    WHERE s.status = 'Ativo' AND p.id IS NOT NULL
  LOOP
    v_total := COALESCE(rec_student.plan_value, 0);
    IF v_total = 0 THEN CONTINUE; END IF;

    -- Desconto por recorrência (se ativa e aplicável à unidade)
    v_rec_discount := COALESCE((
      SELECT r.discount_percent
      FROM public.recurrences r
      WHERE r.id = rec_student.recurrence_id
        AND (r.start_date IS NULL OR r.start_date <= p_generation_date)
        AND (r.end_date IS NULL OR r.end_date >= p_generation_date)
        AND (r.units_applicable IS NULL OR rec_student.unit_id = ANY(r.units_applicable))
    ), 0);

    -- Desconto proporcional vigente no período
    v_prop_discount := COALESCE((
      SELECT p2.discount_percent
      FROM public.proportionals p2
      WHERE p_generation_date BETWEEN p2.start_period AND p2.end_period
      ORDER BY p2.discount_percent DESC
      LIMIT 1
    ), 0);

    v_discount_amount := v_total * (LEAST(v_rec_discount + v_prop_discount, 100) / 100.0);
    v_net := v_total - v_discount_amount;

    -- Primeira mensalidade? Vencimento = data de geração
    SELECT NOT EXISTS (SELECT 1 FROM public.invoices i WHERE i.student_id = rec_student.id)
      INTO v_first_invoice;

    INSERT INTO public.invoices(
      student_id, unit_id, plan_id, recurrence_id,
      due_date, amount_total, amount_discount, amount_net,
      payment_method, status, issued_at
    ) VALUES (
      rec_student.id, rec_student.unit_id, rec_student.plan_id, rec_student.recurrence_id,
      CASE WHEN v_first_invoice THEN p_generation_date ELSE v_due_date END,
      v_total, v_discount_amount, v_net,
      rec_student.payment_method, 'Aberta', now()
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
-- Função: marcar mensalidade como paga (gera adiantamento quando pagamento em dinheiro)
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
SET search_path = public
AS $$
DECLARE
  rec_inv RECORD;
BEGIN
  SELECT * INTO rec_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % not found', p_invoice_id; END IF;

  UPDATE public.invoices
    SET status = 'Paga', paid_at = p_paid_at, payment_method = p_payment_method, receipt_url = p_receipt_url, updated_at = now()
    WHERE id = p_invoice_id;

  IF p_payment_method = 'Dinheiro' AND p_professional_id IS NOT NULL THEN
    INSERT INTO public.advances(entity_type, entity_id, unit_id, amount, advance_date, status)
    VALUES ('Equipe', p_professional_id, rec_inv.unit_id, rec_inv.amount_net, p_paid_at::date, 'Aberta');
  END IF;
END;
$$;
-- RLS granular: invoices
DO $$ BEGIN
  CREATE POLICY invoices_manager_select ON public.invoices
    FOR SELECT TO authenticated
    USING (public.is_manager() AND unit_id IN (SELECT id FROM public.units WHERE manager_user_id = auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY invoices_manager_update ON public.invoices
    FOR UPDATE TO authenticated
    USING (public.is_manager() AND unit_id IN (SELECT id FROM public.units WHERE manager_user_id = auth.uid()))
    WITH CHECK (public.is_manager() AND unit_id IN (SELECT id FROM public.units WHERE manager_user_id = auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY invoices_finance_select ON public.invoices
    FOR SELECT TO authenticated
    USING (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- RLS granular: expenses
DO $$ BEGIN
  CREATE POLICY expenses_manager_select ON public.expenses
    FOR SELECT TO authenticated
    USING (public.is_manager() AND unit_id IN (SELECT id FROM public.units WHERE manager_user_id = auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY expenses_finance_select ON public.expenses
    FOR SELECT TO authenticated
    USING (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- RLS granular: advances
DO $$ BEGIN
  CREATE POLICY advances_manager_select ON public.advances
    FOR SELECT TO authenticated
    USING (public.is_manager() AND unit_id IN (SELECT id FROM public.units WHERE manager_user_id = auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY advances_finance_select ON public.advances
    FOR SELECT TO authenticated
    USING (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- RLS granular: repasses (sem vínculo direto de unidade; liberar leitura para Financeiro)
DO $$ BEGIN
  CREATE POLICY repasses_finance_select ON public.repasses
    FOR SELECT TO authenticated
    USING (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
