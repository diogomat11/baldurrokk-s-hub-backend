-- 0032_repass_logic_v2.sql

-- 1. Add Repasse Config to Professionals
DO $$ BEGIN
    ALTER TABLE public.professionals ADD COLUMN repass_type repass_type_enum NOT NULL DEFAULT 'Fixo';
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE public.professionals ADD COLUMN repass_value numeric(12,2) NOT NULL DEFAULT 0; -- Stores % or Fixed Amnt
EXCEPTION WHEN duplicate_column THEN NULL; END $$;


-- 2. Update generate_repass_preview to use Repasse Config
DROP FUNCTION IF EXISTS public.generate_repass_preview(date, text, uuid);

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
  movement_count int,
  repass_type text, -- Return the model used
  repass_base_value numeric -- The configured value (fixed or %)
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH target_entities AS (
    SELECT 
      p.id, p.name, 'Profissional'::text as type, 
      p.repass_type::text, 
      COALESCE(p.repass_value, 0) as config_value
      -- Note: Professionals also have 'salary' but we use repass_value for consistency or as overwrite?
      -- If repass_value is 0 and type is Fixo, maybe fallback to salary?
      -- Let's stick to repass_value for now (User must config).
    FROM public.professionals p
    WHERE (p_entity_type IN ('Profissional', 'Ambos', 'Equipe'))
      AND (p_entity_id IS NULL OR p.id = p_entity_id)
    UNION ALL
    SELECT 
      u.id, u.name, 'Unidade'::text as type, 
      u.repass_type::text, 
      COALESCE(u.repass_value, 0) as config_value
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
    CASE 
      WHEN t.repass_type = 'Fixo' THEN 
        (t.config_value + COALESCE(m.sum_bonus, 0) - COALESCE(m.sum_advance, 0))
      ELSE -- Percentual
        ( (COALESCE(i.sum_invoices, 0) * t.config_value / 100.0) + COALESCE(m.sum_bonus, 0) - COALESCE(m.sum_advance, 0) )
    END as final_value,
    COALESCE(i.count_invoices, 0)::int as invoice_count,
    COALESCE(m.count_movements, 0)::int as movement_count,
    t.repass_type,
    t.config_value as repass_base_value
  FROM target_entities t
  LEFT JOIN invoices_calc i ON t.id = i.entity_id
  LEFT JOIN movements_calc m ON t.id = m.entity_id;
END;
$$;


-- 3. Update confirm_repass to use Repasse Config
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
  v_repass_type text;
  v_repass_value numeric;
BEGIN
  IF p_entity_type = 'Profissional' THEN
    v_type_enum := 'Equipe';
    SELECT repass_type::text, COALESCE(repass_value, 0) INTO v_repass_type, v_repass_value
    FROM public.professionals WHERE id = p_entity_id;
  ELSE
    v_type_enum := 'Unidade';
    SELECT repass_type::text, COALESCE(repass_value, 0) INTO v_repass_type, v_repass_value
    FROM public.units WHERE id = p_entity_id;
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
    -- Note: We mark them PAGA here. User asked to update status "when repasse is paid".
    -- But if we don't mark Paga here, they show up in next preview?
    -- Solution: Keep 'Paga' here to "Lock" them.
    -- If user wants "Another status update when Paid", maybe we change this to 'Processando'?
    -- But schema constraint is status_enum ('Aberta', 'Paga', 'Cancelada').
    -- So 'Paga' is the detailed state. 'Repasse Paga' is the aggregate state.
    -- If Repasse is 'Aberta', movements are linked and 'Paga'.
    -- The user request "lançamentos status atualizado" might mean:
    -- "Please ensure they ARE updated". Currently they ARE updated to 'Paga' here.
    -- I will stick to this unless they want strict double-confirm.
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

  -- 4. Calculate Finals (Logic V2)
  IF v_repass_type = 'Fixo' THEN
      -- Gross = Fixed. (Invoices ignored for calc, but linked for reference)
      -- Actually, if Gross is just Fixed, do we report Total Invoices as Gross? No.
      -- Gross = Fixed Value.
      v_final_value := v_repass_value + v_total_bonuses - v_total_advances;
      -- Update Repasse Gross to be Fixed Value (so UI shows Fixed).
      -- But we lose visibility of "Total Invoices Linked".
      -- We can store Invoices Total in a separate column? Or just implied?
      -- 'gross_value' usually implies Revenue.
      -- If Fixed, Repasse Value IS the Gross Commission.
      -- I will set gross_value = v_repass_value.
      
      UPDATE public.repasses
      SET gross_value = v_repass_value,
          advance_deduction = v_total_advances,
          net_value = v_final_value
      WHERE id = v_repass_id;
  ELSE
      -- Percentual
      -- Gross = Invoices * Pct/100
      v_final_value := (v_total_invoices * v_repass_value / 100.0) + v_total_bonuses - v_total_advances;
      
      UPDATE public.repasses
      SET gross_value = (v_total_invoices * v_repass_value / 100.0), -- Adjusted Gross
          advance_deduction = v_total_advances,
          net_value = v_final_value
      WHERE id = v_repass_id;
  END IF;

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
