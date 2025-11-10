-- Migração: adicionar CPF do responsável e data de saída
-- Compatível com os dois esquemas de naming (students vs alunos)

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'students'
  ) THEN
    ALTER TABLE public.students
      ADD COLUMN IF NOT EXISTS guardian_cpf text;

    ALTER TABLE public.students
      ADD COLUMN IF NOT EXISTS leaving_date date;

    CREATE INDEX IF NOT EXISTS idx_students_leaving_date ON public.students (leaving_date);
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'alunos'
  ) THEN
    ALTER TABLE public.alunos
      ADD COLUMN IF NOT EXISTS cpf_responsavel text;

    ALTER TABLE public.alunos
      ADD COLUMN IF NOT EXISTS data_saida date;

    CREATE INDEX IF NOT EXISTS idx_alunos_data_saida ON public.alunos (data_saida);
  END IF;
END $$;
