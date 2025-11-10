-- 20251109090100_alunos_guardian_leaving.sql — ajustes em alunos: CPF do responsável e data de saída

-- Adicionar coluna cpf_responsavel (CPF do responsável pelo aluno) se não existir
ALTER TABLE IF NOT EXISTS public.alunos
  ADD COLUMN IF NOT EXISTS cpf_responsavel character varying(14);

-- Adicionar coluna data_saida (data de saída/cancelamento) se não existir
ALTER TABLE IF NOT EXISTS public.alunos
  ADD COLUMN IF NOT EXISTS data_saida date;

-- Índice para consultas por data de saída
CREATE INDEX IF NOT EXISTS idx_alunos_data_saida ON public.alunos (data_saida);