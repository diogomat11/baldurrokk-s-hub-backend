-- 0009_expenses_advances_repasses.sql — despesas, adiantamentos e repasses

-- Enum de status financeiro genérico
DO $$ BEGIN
  CREATE TYPE finance_status_enum AS ENUM ('Aberta', 'Paga', 'Cancelada');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela expenses (despesas)
CREATE TABLE IF NOT EXISTS public.expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.units (id) ON DELETE RESTRICT,
  category text,
  description text,
  amount numeric(12,2) NOT NULL,
  expense_date date NOT NULL,
  status finance_status_enum NOT NULL DEFAULT 'Aberta',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_expenses_updated_at
  BEFORE UPDATE ON public.expenses
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY expenses_admin_full ON public.expenses
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_expenses_unit_id ON public.expenses (unit_id);
CREATE INDEX IF NOT EXISTS idx_expenses_date ON public.expenses (expense_date);
CREATE INDEX IF NOT EXISTS idx_expenses_status ON public.expenses (status);
-- Tabela advances (adiantamentos)
CREATE TABLE IF NOT EXISTS public.advances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type negotiation_entity_enum NOT NULL,
  entity_id uuid NOT NULL,
  unit_id uuid REFERENCES public.units (id) ON DELETE SET NULL,
  amount numeric(12,2) NOT NULL,
  advance_date date NOT NULL,
  status finance_status_enum NOT NULL DEFAULT 'Aberta',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_advances_updated_at
  BEFORE UPDATE ON public.advances
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.advances ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY advances_admin_full ON public.advances
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_advances_entity_type ON public.advances (entity_type);
CREATE INDEX IF NOT EXISTS idx_advances_entity_id ON public.advances (entity_id);
CREATE INDEX IF NOT EXISTS idx_advances_unit_id ON public.advances (unit_id);
-- Tabela repasses
CREATE TABLE IF NOT EXISTS public.repasses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type negotiation_entity_enum NOT NULL,
  entity_id uuid NOT NULL,
  negotiation_id uuid REFERENCES public.negotiations (id) ON DELETE SET NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  gross_value numeric(12,2) NOT NULL,
  advance_deduction numeric(12,2) NOT NULL DEFAULT 0,
  net_value numeric(12,2) NOT NULL,
  paid_at timestamptz,
  status finance_status_enum NOT NULL DEFAULT 'Aberta',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_repasses_updated_at
  BEFORE UPDATE ON public.repasses
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.repasses ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY repasses_admin_full ON public.repasses
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_repasses_entity_type ON public.repasses (entity_type);
CREATE INDEX IF NOT EXISTS idx_repasses_entity_id ON public.repasses (entity_id);
CREATE INDEX IF NOT EXISTS idx_repasses_period_start ON public.repasses (period_start);
CREATE INDEX IF NOT EXISTS idx_repasses_period_end ON public.repasses (period_end);
CREATE INDEX IF NOT EXISTS idx_repasses_status ON public.repasses (status);
