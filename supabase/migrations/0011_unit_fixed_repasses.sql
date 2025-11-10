-- 0011_unit_fixed_repasses.sql — geração de repasses fixos por unidade

-- Função: gerar repasses para unidades com repasse fixo
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
BEGIN
  FOR rec_unit IN
    SELECT u.id, u.repass_value
    FROM public.units u
    WHERE u.status = 'Ativo' AND u.repass_type = 'Fixo' AND u.repass_value > 0
  LOOP
    -- Evitar duplicidade no mesmo período
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
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
-- Policies para permitir inserção via função por Financeiro/Admin
DO $$ BEGIN
  CREATE POLICY repasses_finance_insert ON public.repasses
    FOR INSERT TO authenticated
    WITH CHECK (public.is_finance());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY repasses_admin_insert ON public.repasses
    FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
