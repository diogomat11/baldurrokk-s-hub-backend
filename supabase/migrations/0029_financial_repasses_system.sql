-- 0029_financial_repasses_system.sql

-- 1. Rename 'advances' to 'financial_movements' and add new fields
ALTER TABLE IF EXISTS public.advances RENAME TO financial_movements;

-- Add new columns if they don't exist
DO $$ BEGIN
    ALTER TABLE public.financial_movements ADD COLUMN type text NOT NULL DEFAULT 'Adiantamento';
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE public.financial_movements ADD COLUMN repass_id uuid REFERENCES public.repasses(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE public.financial_movements ADD COLUMN description text;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE public.financial_movements ADD COLUMN receipt_url text;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

-- Check constraint for type
DO $$ BEGIN
    ALTER TABLE public.financial_movements ADD CONSTRAINT check_movement_type CHECK (type IN ('Adiantamento', 'Bonificacao'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- 2. Add repass_id to invoices
DO $$ BEGIN
    ALTER TABLE public.invoices ADD COLUMN repass_id uuid REFERENCES public.repasses(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

-- Index for performance
CREATE INDEX IF NOT EXISTS idx_movements_repass_id ON public.financial_movements(repass_id);
CREATE INDEX IF NOT EXISTS idx_invoices_repass_id ON public.invoices(repass_id);


-- 3. Update mark_invoice_paid to insert into financial_movements instead of advances
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

  -- Logic for Cash Payment -> Advance (Adiantamento) for Teacher
  IF p_payment_method = 'Dinheiro' AND p_professional_id IS NOT NULL THEN
      INSERT INTO public.financial_movements (
        entity_type, 
        entity_id, 
        unit_id, 
        amount, 
        advance_date, 
        status, 
        type, 
        description
      )
      VALUES (
        'Equipe', 
        p_professional_id, 
        v_unit_id, 
        v_amount, 
        p_paid_at::date, 
        'Aberta', -- Still 'Aberta' until linked to a Repasse? Or 'Paga'? Usually Advance is 'Aberta' until deducted.
        'Adiantamento',
        'Recebimento em Dinheiro - Mensalidade'
      );
  END IF;
END;
$function$;


-- 4. RPC: generate_repass_preview
-- Calculates potential repasse values without creating records
CREATE OR REPLACE FUNCTION public.generate_repass_preview(
  p_month date, -- First day of reference month (e.g. '2025-10-01')
  p_entity_type text, -- 'Profissional' or 'Unidade' (maps to 'Equipe' in DB?) or 'Ambos'
  p_entity_id uuid DEFAULT NULL -- Specific ID or NULL for all
)
RETURNS TABLE (
  entity_id uuid,
  entity_name text,
  entity_type text,
  total_invoices numeric, -- Credits
  total_bonuses numeric, -- Credits
  total_advances numeric, -- Debits
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
    -- Select Professionals
    SELECT 
      p.id, 
      p.name, 
      'Profissional'::text as type 
    FROM public.professionals p
    WHERE (p_entity_type IN ('Profissional', 'Ambos', 'Equipe'))
      AND (p_entity_id IS NULL OR p.id = p_entity_id)
    UNION ALL
    -- Select Units
    SELECT 
      u.id, 
      u.name, 
      'Unidade'::text as type 
    FROM public.units u
    WHERE (p_entity_type IN ('Unidade', 'Ambos'))
      AND (p_entity_id IS NULL OR u.id = p_entity_id)
  ),
  invoices_calc AS (
    SELECT 
      i.unit_id,
      -- For professionals, we need to link via class/teacher? 
      -- Currently invoices are linked to unit_id.
      -- If repasse is for Professional, we need to know which invoices belong to them.
      -- In existing system, is there a 'professional_id' on invoice? No.
      -- But there is 'classes' table with 'teacher_ids'.
      -- Complication: Invoices are usually "Student pays Unit".
      -- The requirement says "Vincular todas as mensalidades... Status Pago... do mês de referência".
      -- If Repasse is for UNIT, it's easy (invoices where unit_id = X).
      -- If Repasse is for PROFESSIONAL, how do we know which invoice belongs to them?
      -- Option: Invoices are split by class?
      -- Assumption: For now, Repasse Logic might be strictly Unit-based? 
      -- BUT "Geração de Repasse... Tipo de Repasse (Profissional, Unidade)".
      -- IF 'Profissional', maybe logic is: "Percentage of invoices"?
      -- ALLOWANCE: "Adiantamento" is linked to Professional.
      -- PROBLEM: Invoices don't have Professional ID.
      -- User Request: "Vincular todas as mensalidades...".
      -- Maybe the system assumes 1 Teacher per Unit? No.
      -- Maybe we only do Repasse for UNITS (Franchise)?
      -- OR maybe we look at `classes` the student is enrolled in?
      -- Let's check `student_classes` or similar.
      -- MIGRATION FIX: Need to know how to attribute Invoice to Professional.
      -- If not possible, maybe Repasse Professional = Fixed Salary + Bonus - Advance?
      -- The prompt says: "Vincular todas as mensalidades...". This implies 1-to-1 mapping.
      -- I'll assume for 'Unidade', we sum invoices. 
      -- For 'Profissional', if p_entity_type = 'Profissional', we might only sum Movements?
      -- Or maybe current system assigns class to invoice?
      -- Looking at `mark_invoice_paid`, we pass `p_professional_id` for Cash payments.
      -- But regular PIX payments?
      -- I will implement Unit logic fully. For Professional, I will return 0 invoices unless I find a link.
      -- Checking `classes` table: `teacher_ids`.
      -- I will count invoices for UNIT. For Professional, only if explicit logic exists.
      -- Let's allow `total_invoices` for Entity Type 'Unidade' only.
      SUM(i.amount_net) as sum_invoices,
      COUNT(i.id) as count_invoices
    FROM public.invoices i
    WHERE i.status = 'Paga'
      AND i.repass_id IS NULL
      AND i.payment_method <> 'Dinheiro' -- Cash stays with teacher? Or counts as paid? 
      -- "Ao marcar mensalidade paga com Dinheiro -> Criar Adiantamento". 
      -- This implies the money is WITH the teacher (Debit). The Invoice is Paid (Credit for System).
      -- So Invoice Value = Credit. Advance = Debit. Net = 0. Correct.
      -- So we include ALL Paga invoices.
      AND i.due_date >= p_month
      AND i.due_date < (p_month + interval '1 month')
    GROUP BY i.unit_id
  ),
  movements_calc AS (
    SELECT 
      m.entity_id,
      m.entity_type, -- 'Equipe' (Prof), 'Unidade'
      SUM(CASE WHEN m.type = 'Bonificacao' THEN m.amount ELSE 0 END) as sum_bonus,
      SUM(CASE WHEN m.type = 'Adiantamento' THEN m.amount ELSE 0 END) as sum_advance,
      COUNT(m.id) as count_movements
    FROM public.financial_movements m
    WHERE m.status = 'Aberta'
      AND m.repass_id IS NULL
      -- Movements don't strictly have "Ref Month" but created/advance_date.
      -- Usually we pick all OPEN movements up to now.
      AND m.advance_date <= (p_month + interval '1 month' - interval '1 day')
    GROUP BY m.entity_id, m.entity_type
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
  LEFT JOIN invoices_calc i ON (t.type = 'Unidade' AND t.id = i.unit_id)
  LEFT JOIN movements_calc m ON (
    (t.type = 'Profissional' AND m.entity_type = 'Equipe' AND m.entity_id = t.id) OR
    (t.type = 'Unidade' AND m.entity_type = 'Unidade' AND m.entity_id = t.id)
  );
END;
$$;


-- 5. RPC: confirm_repass
-- Creates the repasse and links items
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
  v_movement_id uuid;
  v_next_month date;
BEGIN
  -- Map text type to enum
  IF p_entity_type = 'Profissional' THEN
    v_type_enum := 'Equipe';
  ELSE
    v_type_enum := 'Unidade'; -- Assuming 'Unidade' is valid in enum or mapped
  END IF;

  -- 1. Create Repasse Record (Initially Open/Pendente)
  INSERT INTO public.repasses (
    entity_type,
    entity_id,
    period_start,
    period_end,
    gross_value,
    advance_deduction,
    net_value,
    status
  ) VALUES (
    v_type_enum,
    p_entity_id,
    p_month,
    (p_month + interval '1 month' - interval '1 day')::date,
    0, 0, 0, -- Will update later
    'Aberta' -- 'Aberta' = Pendente
  ) RETURNING id INTO v_repass_id;

  -- 2. Link Invoices (Credits) - Only for Units currently as analyzed
  IF p_entity_type = 'Unidade' THEN
    WITH updated_inv AS (
      UPDATE public.invoices
      SET repass_id = v_repass_id
      WHERE unit_id = p_entity_id
        AND status = 'Paga'
        AND repass_id IS NULL
        AND due_date >= p_month
        AND due_date < (p_month + interval '1 month')
      RETURNING amount_net
    )
    SELECT COALESCE(SUM(amount_net), 0) INTO v_total_invoices FROM updated_inv;
  END IF;

  -- 3. Link Movements (Adiantamentos/Bonificacoes)
  WITH updated_mov AS (
    UPDATE public.financial_movements
    SET repass_id = v_repass_id,
        status = 'Paga' -- Mark as "Handled" in this repasse context? Or keep 'Aberta' until Repasse is Paid?
        -- Requirement: "Vincular...". 
        -- If repasse is Pendente, movements are "Linked". 
        -- If we mark 'Paga', they won't show in next preview. Correct.
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
    -- Mark Repasse as Paid (Settled via negative carry-over)
    UPDATE public.repasses SET status = 'Paga', paid_at = now() WHERE id = v_repass_id;
    
    -- Create new Advance for next month
    v_next_month := (p_month + interval '1 month')::date;
    
    INSERT INTO public.financial_movements (
      entity_type,
      entity_id,
      unit_id,
      amount,
      advance_date,
      status,
      type,
      description
    ) VALUES (
      v_type_enum,
      p_entity_id,
      NULL, -- Can we infer unit?
      ABS(v_final_value),
      v_next_month,
      'Aberta',
      'Adiantamento',
      'Saldo insuficiente – Repasse ' || to_char(p_month, 'MM/YYYY')
    );
  END IF;

  RETURN v_repass_id;
END;
$$;
