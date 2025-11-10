-- 0012_professional_repasses.sql — repasses para equipe (negociação fixo/percentual)

-- Função: gerar repasses para profissionais a partir de negociações
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
  rec_n RECORD; -- negociação
  v_base_sum numeric(12,2);
  v_gross numeric(12,2);
  v_adv_sum numeric(12,2);
  v_net numeric(12,2);
BEGIN
  FOR rec_n IN
    SELECT n.*
    FROM public.negotiations n
    WHERE n.type = 'Equipe'
      AND n.status = 'Ativo'
      AND (n.start_date IS NULL OR n.start_date <= p_period_end)
      AND (n.end_date IS NULL OR n.end_date >= p_period_start)
  LOOP
    -- Evitar duplicidade no mesmo período por negociação e profissional
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

    -- Base para percentual: soma das faturas pagas no período dos alunos em turmas onde o profissional leciona
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

    -- Somar adiantamentos para o profissional no período
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
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
-- Função: marcar repasse como pago
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
  UPDATE public.repasses
    SET status = 'Paga', paid_at = p_paid_at, updated_at = now()
    WHERE id = p_repass_id;
END;
$$;
-- Policies de UPDATE para permitir marcação de pago por Financeiro/Admin
DO $$ BEGIN
  CREATE POLICY repasses_finance_update ON public.repasses
    FOR UPDATE TO authenticated
    USING (public.is_finance())
    WITH CHECK (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY repasses_admin_update ON public.repasses
    FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
