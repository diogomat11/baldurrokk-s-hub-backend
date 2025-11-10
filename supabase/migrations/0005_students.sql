-- 0005_students.sql — alunos

-- Enum para método de pagamento
DO $$ BEGIN
  CREATE TYPE payment_method_enum AS ENUM ('Dinheiro', 'PIX', 'Crédito', 'Débito');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela students
CREATE TABLE IF NOT EXISTS public.students (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  avatar_url text,
  name text NOT NULL,
  birthdate date,
  start_date date NOT NULL,
  cpf text,
  address text,
  guardian_name text,
  guardian_phone text,
  guardian_email text,
  unit_id uuid NOT NULL REFERENCES public.units (id) ON DELETE RESTRICT,
  class_id uuid REFERENCES public.classes (id) ON DELETE SET NULL,
  plan_id uuid,
  payment_method payment_method_enum NOT NULL,
  recurrence_id uuid,
  discount_id uuid,
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_students_updated_at
  BEFORE UPDATE ON public.students
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;
-- Admin tem acesso total inicialmente
DO $$ BEGIN
  CREATE POLICY students_admin_full ON public.students
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Índices úteis
CREATE INDEX IF NOT EXISTS idx_students_name ON public.students (name);
CREATE INDEX IF NOT EXISTS idx_students_unit_id ON public.students (unit_id);
