-- 0031_fix_repass_cash_logic.sql

-- Update generate_repass_preview to INCLUDE Cash invoices
-- Rationale: If paid in Cash, we created an Advance (Debit). 
-- We must show the Invoice (Credit) so that Net = 0.
-- Previously we excluded Cash Invoices, resulting in Net = -Amount.

CREATE OR REPLACE FUNCTION public.generate_repass_preview(
  p_month date,
  p_entity_type text,
  p_entity_id uuid DEFAULT NULL
)
RETURNS TABLE (
  entity_id uuid,
  entity_name text,
  entity_type text,
  total_invoices numeric,
  total_bonuses numeric,
  total_advances numeric,
  final_value numeric,
  invoice_count int,
  movement_count int
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH target_entities AS (
    SELECT p.id, p.name, 'Profissional'::text as type 
    FROM public.professionals p
    WHERE (p_entity_type IN ('Profissional', 'Ambos', 'Equipe'))
      AND (p_entity_id IS NULL OR p.id = p_entity_id)
    UNION ALL
    SELECT u.id, u.name, 'Unidade'::text as type 
    FROM public.units u
    WHERE (p_entity_type IN ('Unidade', 'Ambos'))
      AND (p_entity_id IS NULL OR u.id = p_entity_id)
  ),
  invoices_calc AS (
    SELECT 
      te.id as entity_id,
      SUM(i.amount_net) as sum_invoices,
      COUNT(i.id) as count_invoices
    FROM public.invoices i
    JOIN public.students s ON i.student_id = s.id
    LEFT JOIN public.classes c ON s.class_id = c.id
    CROSS JOIN target_entities te
    WHERE i.status = 'Paga'
      AND i.repass_id IS NULL
      -- REMOVED: AND i.payment_method <> 'Dinheiro'
      AND i.due_date >= p_month
      AND i.due_date < (p_month + interval '1 month')
      AND (
        (te.type = 'Unidade' AND i.unit_id = te.id)
        OR 
        (te.type = 'Profissional' AND c.teacher_ids IS NOT NULL AND te.id = ANY(c.teacher_ids))
      )
    GROUP BY te.id
  ),
  movements_calc AS (
    SELECT 
      m.entity_id,
      SUM(CASE WHEN m.type = 'Bonificacao' THEN m.amount ELSE 0 END) as sum_bonus,
      SUM(CASE WHEN m.type = 'Adiantamento' THEN m.amount ELSE 0 END) as sum_advance,
      COUNT(m.id) as count_movements
    FROM public.financial_movements m
    WHERE m.status = 'Aberta'
      AND m.repass_id IS NULL
      AND m.advance_date <= (p_month + interval '1 month' - interval '1 day')
    GROUP BY m.entity_id
  )
  SELECT 
    t.id,
    t.name,
    t.type,
    COALESCE(i.sum_invoices, 0) as total_invoices,
    COALESCE(m.sum_bonus, 0) as total_bonuses,
    COALESCE(m.sum_advance, 0) as total_advances,
    (COALESCE(i.sum_invoices, 0) + COALESCE(m.sum_bonus, 0) - COALESCE(m.sum_advance, 0)) as final_value,
    COALESCE(i.count_invoices, 0)::int as invoice_count,
    COALESCE(m.count_movements, 0)::int as movement_count
  FROM target_entities t
  LEFT JOIN invoices_calc i ON t.id = i.entity_id
  LEFT JOIN movements_calc m ON t.id = m.entity_id;
END;
$$;


-- Update confirm_repass to INCLUDE Cash invoices
CREATE OR REPLACE FUNCTION public.confirm_repass(
  p_month date,
  p_entity_type text,
  p_entity_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_repass_id uuid;
  v_total_invoices numeric := 0;
  v_total_bonuses numeric := 0;
  v_total_advances numeric := 0;
  v_final_value numeric := 0;
  v_type_enum negotiation_entity_enum;
  v_next_month date;
BEGIN
  IF p_entity_type = 'Profissional' THEN
    v_type_enum := 'Equipe';
  ELSE
    v_type_enum := 'Unidade';
  END IF;

  -- 1. Create Repasse Record
  INSERT INTO public.repasses (
    entity_type, entity_id, period_start, period_end, gross_value, advance_deduction, net_value, status
  ) VALUES (
    v_type_enum, p_entity_id, p_month, (p_month + interval '1 month' - interval '1 day')::date, 0, 0, 0, 'Aberta'
  ) RETURNING id INTO v_repass_id;

  -- 2. Link Invoices
  WITH updated_inv AS (
    UPDATE public.invoices i
    SET repass_id = v_repass_id
    FROM public.students s
    LEFT JOIN public.classes c ON s.class_id = c.id
    WHERE i.student_id = s.id
      AND i.status = 'Paga'
      AND i.repass_id IS NULL
      AND i.due_date >= p_month
      AND i.due_date < (p_month + interval '1 month')
      -- REMOVED: AND i.payment_method <> 'Dinheiro'
      AND (
        (p_entity_type = 'Unidade' AND i.unit_id = p_entity_id)
        OR
        (p_entity_type = 'Profissional' AND c.teacher_ids IS NOT NULL AND p_entity_id = ANY(c.teacher_ids))
      )
    RETURNING i.amount_net
  )
  SELECT COALESCE(SUM(amount_net), 0) INTO v_total_invoices FROM updated_inv;

  -- 3. Link Movements
  WITH updated_mov AS (
    UPDATE public.financial_movements
    SET repass_id = v_repass_id, status = 'Paga'
    WHERE (
        (p_entity_type = 'Profissional' AND entity_type = 'Equipe' AND entity_id = p_entity_id) OR
        (p_entity_type = 'Unidade' AND entity_type = 'Unidade' AND entity_id = p_entity_id)
      )
      AND status = 'Aberta'
      AND repass_id IS NULL
      AND advance_date <= (p_month + interval '1 month' - interval '1 day')
    RETURNING amount, type
  )
  SELECT 
    COALESCE(SUM(CASE WHEN type = 'Bonificacao' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN type = 'Adiantamento' THEN amount ELSE 0 END), 0)
  INTO v_total_bonuses, v_total_advances
  FROM updated_mov;

  -- 4. Calculate Finals
  v_final_value := v_total_invoices + v_total_bonuses - v_total_advances;

  -- Update Repasse
  UPDATE public.repasses
  SET gross_value = v_total_invoices + v_total_bonuses,
      advance_deduction = v_total_advances,
      net_value = v_final_value
  WHERE id = v_repass_id;

  -- 5. Negative Balance Logic
  IF v_final_value < 0 THEN
    UPDATE public.repasses SET status = 'Paga', paid_at = now() WHERE id = v_repass_id;
    v_next_month := (p_month + interval '1 month')::date;
    INSERT INTO public.financial_movements (
      entity_type, entity_id, unit_id, amount, advance_date, status, type, description
    ) VALUES (
      v_type_enum, p_entity_id, NULL, ABS(v_final_value), v_next_month, 'Aberta', 'Adiantamento', 'Saldo insuficiente – Repasse ' || to_char(p_month, 'MM/YYYY')
    );
  END IF;

  RETURN v_repass_id;
END;
$$;
