-- Ajustes em alunos: CPF do responsável e data de saída

ALTER TABLE IF EXISTS public.alunos
  ADD COLUMN IF NOT EXISTS cpf_responsavel character varying(14);

ALTER TABLE IF EXISTS public.alunos
  ADD COLUMN IF NOT EXISTS data_saida date;

CREATE INDEX IF NOT EXISTS idx_alunos_data_saida ON public.alunos (data_saida);