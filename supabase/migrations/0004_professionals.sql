-- 0004_professionals.sql — profissionais da equipe técnica

-- Enum para posição do profissional
DO $$ BEGIN
  CREATE TYPE role_position_enum AS ENUM ('Gestor', 'Professor', 'Auxiliar', 'Administrativo');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela professionals
CREATE TABLE IF NOT EXISTS public.professionals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  cpf text,
  role_position role_position_enum NOT NULL,
  salary numeric(12,2) NOT NULL DEFAULT 0,
  specialties text[] NOT NULL DEFAULT '{}',
  phone text,
  email text,
  unit_ids uuid[] NOT NULL DEFAULT '{}',
  hired_at date,
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_professionals_updated_at
  BEFORE UPDATE ON public.professionals
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.professionals ENABLE ROW LEVEL SECURITY;
-- Admin tem acesso total inicialmente
DO $$ BEGIN
  CREATE POLICY professionals_admin_full ON public.professionals
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Índices úteis
CREATE INDEX IF NOT EXISTS idx_professionals_status ON public.professionals (status);
CREATE INDEX IF NOT EXISTS idx_professionals_role_position ON public.professionals (role_position);
