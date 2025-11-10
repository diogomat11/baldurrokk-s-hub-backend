-- 0014_finance_audit_hooks.sql — conectar auditoria às funções financeiras

-- Reescrever funções para registrar eventos em finance_events via log_finance_event

-- Hook: gerar mensalidades (InvoiceGenerated)
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
  v_inv_id uuid;
BEGIN
  FOR rec_student IN
    SELECT s.*, p.value AS plan_value
    FROM public.students s
    LEFT JOIN public.plans p ON p.id = s.plan_id
    WHERE s.status = 'Ativo' AND p.id IS NOT NULL
  LOOP
    v_total := COALESCE(rec_student.plan_value, 0);
    IF v_total = 0 THEN CONTINUE; END IF;

    v_rec_discount := COALESCE((
      SELECT r.discount_percent
      FROM public.recurrences r
      WHERE r.id = rec_student.recurrence_id
        AND (r.start_date IS NULL OR r.start_date <= p_generation_date)
        AND (r.end_date IS NULL OR r.end_date >= p_generation_date)
        AND (r.units_applicable IS NULL OR rec_student.unit_id = ANY(r.units_applicable))
    ), 0);

    v_prop_discount := COALESCE((
      SELECT p2.discount_percent
      FROM public.proportionals p2
      WHERE p_generation_date BETWEEN p2.start_period AND p2.end_period
      ORDER BY p2.discount_percent DESC
      LIMIT 1
    ), 0);

    v_discount_amount := v_total * (LEAST(v_rec_discount + v_prop_discount, 100) / 100.0);
    v_net := v_total - v_discount_amount;

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
    ) RETURNING id INTO v_inv_id;

    -- Log auditoria
    PERFORM public.log_finance_event(
      'InvoiceGenerated', 'Unidade', rec_student.unit_id,
      v_inv_id, NULL, v_net,
      'Mensalidade gerada',
      jsonb_build_object(
        'student_id', rec_student.id,
        'generation_date', p_generation_date,
        'first_invoice', v_first_invoice,
        'plan_id', rec_student.plan_id,
        'recurrence_id', rec_student.recurrence_id
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
-- Hook: marcar mensalidade paga (InvoicePaid) + adiantamento (AdvanceCreated)
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
  v_adv_id uuid;
BEGIN
  SELECT * INTO rec_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % not found', p_invoice_id; END IF;

  UPDATE public.invoices
    SET status = 'Paga', paid_at = p_paid_at, payment_method = p_payment_method, receipt_url = p_receipt_url, updated_at = now()
    WHERE id = p_invoice_id;

  -- Log de pagamento da fatura
  PERFORM public.log_finance_event(
    'InvoicePaid', 'Unidade', rec_inv.unit_id,
    p_invoice_id, NULL, rec_inv.amount_net,
    'Fatura marcada como paga',
    jsonb_build_object(
      'payment_method', p_payment_method,
      'receipt_url', p_receipt_url
    )
  );

  IF p_payment_method = 'Dinheiro' AND p_professional_id IS NOT NULL THEN
    INSERT INTO public.advances(entity_type, entity_id, unit_id, amount, advance_date, status)
    VALUES ('Equipe', p_professional_id, rec_inv.unit_id, rec_inv.amount_net, p_paid_at::date, 'Aberta')
    RETURNING id INTO v_adv_id;

    -- Log de adiantamento gerado
    PERFORM public.log_finance_event(
      'AdvanceCreated', 'Equipe', p_professional_id,
      p_invoice_id, NULL, rec_inv.amount_net,
      'Adiantamento gerado por pagamento em dinheiro',
      jsonb_build_object(
        'advance_id', v_adv_id,
        'unit_id', rec_inv.unit_id,
        'advance_date', p_paid_at::date
      )
    );
  END IF;
END;
$$;
-- Hook: repasse fixo por unidade (RepassGenerated)
CREATE OR REPLACE FUNCTION public.generate_unit_fixed_repasses(
  p_period_start date,
  p_period_end date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
  rec_unit RECORD;
  v_adv_sum numeric(12,2);
  v_gross numeric(12,2);
  v_net numeric(12,2);
  v_rep_id uuid;
BEGIN
  FOR rec_unit IN
    SELECT u.id, u.repass_value
    FROM public.units u
    WHERE u.status = 'Ativo' AND u.repass_type = 'Fixo' AND u.repass_value > 0
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.repasses r
      WHERE r.entity_type = 'Unidade'
        AND r.entity_id = rec_unit.id
        AND r.period_start = p_period_start
        AND r.period_end = p_period_end
    ) THEN
      CONTINUE;
    END IF;

    v_gross := rec_unit.repass_value;

    SELECT COALESCE(SUM(a.amount), 0)
      INTO v_adv_sum
      FROM public.advances a
      WHERE a.entity_type = 'Unidade'
        AND a.entity_id = rec_unit.id
        AND a.advance_date BETWEEN p_period_start AND p_period_end;

    v_net := GREATEST(v_gross - v_adv_sum, 0);

    INSERT INTO public.repasses(
      entity_type, entity_id, negotiation_id,
      period_start, period_end,
      gross_value, advance_deduction, net_value,
      status
    ) VALUES (
      'Unidade', rec_unit.id, NULL,
      p_period_start, p_period_end,
      v_gross, v_adv_sum, v_net,
      'Aberta'
    ) RETURNING id INTO v_rep_id;

    -- Log auditoria
    PERFORM public.log_finance_event(
      'RepassGenerated', 'Unidade', rec_unit.id,
      NULL, v_rep_id, v_net,
      'Repasse fixo gerado',
      jsonb_build_object(
        'period_start', p_period_start,
        'period_end', p_period_end
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
-- Hook: repasse por negociação de equipe (RepassGenerated)
CREATE OR REPLACE FUNCTION public.generate_professional_repasses(
  p_period_start date,
  p_period_end date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
  rec_n RECORD;
  v_base_sum numeric(12,2);
  v_gross numeric(12,2);
  v_adv_sum numeric(12,2);
  v_net numeric(12,2);
  v_rep_id uuid;
BEGIN
  FOR rec_n IN
    SELECT n.*
    FROM public.negotiations n
    WHERE n.type = 'Equipe'
      AND n.status = 'Ativo'
      AND (n.start_date IS NULL OR n.start_date <= p_period_end)
      AND (n.end_date IS NULL OR n.end_date >= p_period_start)
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.repasses r
      WHERE r.entity_type = 'Equipe'
        AND r.entity_id = rec_n.entity_id
        AND r.negotiation_id = rec_n.id
        AND r.period_start = p_period_start
        AND r.period_end = p_period_end
    ) THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(SUM(i.amount_net), 0)
      INTO v_base_sum
      FROM public.invoices i
      JOIN public.students s ON s.id = i.student_id
      LEFT JOIN public.classes c ON c.id = s.class_id
      WHERE i.status = 'Paga'
        AND i.paid_at::date BETWEEN p_period_start AND p_period_end
        AND c.id IS NOT NULL
        AND rec_n.entity_id = ANY(c.teacher_ids);

    IF rec_n.repass_type = 'Fixo' THEN
      v_gross := COALESCE(rec_n.repass_value, 0);
    ELSE
      v_gross := ROUND(COALESCE(v_base_sum, 0) * COALESCE(rec_n.repass_value, 0) / 100.0, 2);
    END IF;

    SELECT COALESCE(SUM(a.amount), 0)
      INTO v_adv_sum
      FROM public.advances a
      WHERE a.entity_type = 'Equipe'
        AND a.entity_id = rec_n.entity_id
        AND a.advance_date BETWEEN p_period_start AND p_period_end;

    v_net := GREATEST(COALESCE(v_gross,0) - COALESCE(v_adv_sum,0), 0);

    INSERT INTO public.repasses(
      entity_type, entity_id, negotiation_id,
      period_start, period_end,
      gross_value, advance_deduction, net_value,
      status
    ) VALUES (
      'Equipe', rec_n.entity_id, rec_n.id,
      p_period_start, p_period_end,
      v_gross, v_adv_sum, v_net,
      'Aberta'
    ) RETURNING id INTO v_rep_id;

    -- Log auditoria
    PERFORM public.log_finance_event(
      'RepassGenerated', 'Equipe', rec_n.entity_id,
      NULL, v_rep_id, v_net,
      'Repasse equipe gerado',
      jsonb_build_object(
        'period_start', p_period_start,
        'period_end', p_period_end,
        'negotiation_id', rec_n.id,
        'repass_type', rec_n.repass_type,
        'repass_value', rec_n.repass_value
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
-- Hook: marcar repasse pago (RepassPaid)
CREATE OR REPLACE FUNCTION public.mark_repass_paid(
  p_repass_id uuid,
  p_paid_at timestamptz DEFAULT now()
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
    SET status = 'Paga', paid_at = p_paid_at, updated_at = now()
    WHERE id = p_repass_id;

  -- Log auditoria
  PERFORM public.log_finance_event(
    'RepassPaid', rec_r.entity_type, rec_r.entity_id,
    NULL, p_repass_id, rec_r.net_value,
    'Repasse marcado como pago',
    jsonb_build_object(
      'period_start', rec_r.period_start,
      'period_end', rec_r.period_end
    )
  );
END;
$$;
