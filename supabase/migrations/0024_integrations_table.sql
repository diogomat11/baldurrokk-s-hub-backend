-- 0024_integrations_table.sql — Tabela de integrações (templates WhatsApp, PIX etc.)

-- Cria tabela de integrações
CREATE TABLE IF NOT EXISTS public.integrations (
  id text PRIMARY KEY,
  whatsapp_template text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Trigger para manter updated_at
DO $$ BEGIN
  CREATE TRIGGER set_integrations_updated_at
  BEFORE UPDATE ON public.integrations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Habilita RLS e políticas
ALTER TABLE public.integrations ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY integrations_admin_full ON public.integrations
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY integrations_finance_select ON public.integrations
    FOR SELECT TO authenticated
    USING (public.is_finance() OR public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Comentários informativos
COMMENT ON TABLE public.integrations IS 'Configurações diversas e templates (WhatsApp, PIX). Chave primária textual ex.: whatsapp:cobranca:mensalidade, banking:pix';
COMMENT ON COLUMN public.integrations.whatsapp_template IS 'Conteúdo do template WhatsApp (texto) ou payload JSON para integrações como banking:pix';