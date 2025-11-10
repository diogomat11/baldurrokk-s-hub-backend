-- 0003_classes.sql — turmas (classes)

-- Tabela classes
CREATE TABLE IF NOT EXISTS public.classes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.units (id) ON DELETE CASCADE,
  name text NOT NULL,
  category text,
  vacancies int NOT NULL DEFAULT 0,
  status status_enum NOT NULL DEFAULT 'Ativo',
  schedule jsonb NOT NULL,
  teacher_ids uuid[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  CREATE TRIGGER set_classes_updated_at
  BEFORE UPDATE ON public.classes
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.classes ENABLE ROW LEVEL SECURITY;
-- Admin full access (futuras políticas por unidade/equipe serão adicionadas)
DO $$ BEGIN
  CREATE POLICY classes_admin_full ON public.classes
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Índices úteis
CREATE INDEX IF NOT EXISTS idx_classes_unit_id ON public.classes (unit_id);
CREATE INDEX IF NOT EXISTS idx_classes_status ON public.classes (status);
