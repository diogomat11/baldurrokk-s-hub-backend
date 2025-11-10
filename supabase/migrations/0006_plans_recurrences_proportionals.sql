-- 0006_plans_recurrences_proportionals.sql — planos, recorrências e proporcionalidades

-- Enum para tipo de recorrência
DO $$ BEGIN
  CREATE TYPE recurrence_type_enum AS ENUM ('Anual', 'Semestral', 'Trimestral', 'Mensal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela de planos
CREATE TABLE IF NOT EXISTS public.plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  unit_id uuid NOT NULL REFERENCES public.units (id) ON DELETE CASCADE,
  frequency_per_week int NOT NULL DEFAULT 1,
  value numeric(12,2) NOT NULL,
  start_date date,
  end_date date,
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_plans_updated_at
  BEFORE UPDATE ON public.plans
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY plans_admin_full ON public.plans
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_plans_unit_id ON public.plans (unit_id);
CREATE INDEX IF NOT EXISTS idx_plans_status ON public.plans (status);
-- Tabela de recorrências
CREATE TABLE IF NOT EXISTS public.recurrences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type recurrence_type_enum NOT NULL,
  discount_percent numeric(5,2) NOT NULL DEFAULT 0,
  start_date date,
  end_date date,
  units_applicable uuid[] NOT NULL DEFAULT '{}',
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_recurrences_updated_at
  BEFORE UPDATE ON public.recurrences
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.recurrences ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY recurrences_admin_full ON public.recurrences
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_recurrences_type ON public.recurrences (type);
CREATE INDEX IF NOT EXISTS idx_recurrences_status ON public.recurrences (status);
-- Tabela de proporcionalidade
CREATE TABLE IF NOT EXISTS public.proportionals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  start_period date NOT NULL,
  end_period date NOT NULL,
  discount_percent numeric(5,2) NOT NULL DEFAULT 0,
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_proportionals_updated_at
  BEFORE UPDATE ON public.proportionals
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.proportionals ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY proportionals_admin_full ON public.proportionals
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_proportionals_status ON public.proportionals (status);
