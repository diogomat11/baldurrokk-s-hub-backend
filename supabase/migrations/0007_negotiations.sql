-- 0007_negotiations.sql — negociações de repasse

-- Enum para tipo de entidade na negociação
DO $$ BEGIN
  CREATE TYPE negotiation_entity_enum AS ENUM ('Unidade', 'Equipe');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Tabela negotiations
CREATE TABLE IF NOT EXISTS public.negotiations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type negotiation_entity_enum NOT NULL,
  entity_id uuid NOT NULL,
  repass_type repass_type_enum NOT NULL,
  repass_value numeric(12,2) NOT NULL DEFAULT 0,
  start_date date NOT NULL,
  end_date date,
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_negotiations_updated_at
  BEFORE UPDATE ON public.negotiations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.negotiations ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY negotiations_admin_full ON public.negotiations
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Índices úteis
CREATE INDEX IF NOT EXISTS idx_negotiations_type ON public.negotiations (type);
CREATE INDEX IF NOT EXISTS idx_negotiations_status ON public.negotiations (status);
CREATE INDEX IF NOT EXISTS idx_negotiations_entity_id ON public.negotiations (entity_id);
