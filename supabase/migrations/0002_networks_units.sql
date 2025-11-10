-- 0002_networks_units.sql — redes e unidades

-- Enum de tipo de repasse
DO $$ BEGIN
  CREATE TYPE repass_type_enum AS ENUM ('Percentual', 'Fixo');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela networks
CREATE TABLE IF NOT EXISTS public.networks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_networks_updated_at
  BEFORE UPDATE ON public.networks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.networks ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY networks_admin_full ON public.networks
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela units
CREATE TABLE IF NOT EXISTS public.units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id uuid NOT NULL REFERENCES public.networks (id) ON DELETE CASCADE,
  manager_user_id uuid REFERENCES public.users (id) ON DELETE SET NULL,
  name text NOT NULL,
  address text,
  city text,
  state text,
  cep text,
  phone text,
  email text,
  repass_type repass_type_enum NOT NULL DEFAULT 'Percentual',
  repass_value numeric(12,2) NOT NULL DEFAULT 0,
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_units_updated_at
  BEFORE UPDATE ON public.units
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;
-- Admin tem acesso total (simplificação inicial); políticas por unidade serão adicionadas em fases seguintes
DO $$ BEGIN
  CREATE POLICY units_admin_full ON public.units
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Índices úteis
CREATE INDEX IF NOT EXISTS idx_units_network_id ON public.units (network_id);
CREATE INDEX IF NOT EXISTS idx_units_status ON public.units (status);
