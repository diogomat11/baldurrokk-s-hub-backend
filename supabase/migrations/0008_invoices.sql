-- 0008_invoices.sql — mensalidades (invoices)

-- Enum de status da fatura
DO $$ BEGIN
  CREATE TYPE invoice_status_enum AS ENUM ('Aberta', 'Paga', 'Cancelada', 'Vencida');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela invoices
CREATE TABLE IF NOT EXISTS public.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id uuid NOT NULL REFERENCES public.students (id) ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES public.units (id) ON DELETE RESTRICT,
  plan_id uuid REFERENCES public.plans (id) ON DELETE SET NULL,
  recurrence_id uuid REFERENCES public.recurrences (id) ON DELETE SET NULL,
  due_date date NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT now(),
  paid_at timestamptz,
  amount_total numeric(12,2) NOT NULL,
  amount_discount numeric(12,2) NOT NULL DEFAULT 0,
  amount_net numeric(12,2) NOT NULL,
  payment_method payment_method_enum NOT NULL,
  status invoice_status_enum NOT NULL DEFAULT 'Aberta',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_invoices_updated_at
  BEFORE UPDATE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
-- Admin tem acesso total inicialmente (políticas granulares por unidade serão adicionadas depois)
DO $$ BEGIN
  CREATE POLICY invoices_admin_full ON public.invoices
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Índices úteis
CREATE INDEX IF NOT EXISTS idx_invoices_student_id ON public.invoices (student_id);
CREATE INDEX IF NOT EXISTS idx_invoices_unit_id ON public.invoices (unit_id);
CREATE INDEX IF NOT EXISTS idx_invoices_due_date ON public.invoices (due_date);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON public.invoices (status);
