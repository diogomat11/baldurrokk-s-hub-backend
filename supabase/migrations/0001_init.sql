-- 0001_init.sql — enums, função de timestamp e tabela users (perfil) ligada ao auth

-- Extensões úteis
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- Enums de papel e status
DO $$ BEGIN
  CREATE TYPE role_enum AS ENUM ('Admin', 'Gerente', 'Financeiro', 'Equipe', 'Aluno');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE status_enum AS ENUM ('Ativo', 'Inativo');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Função para atualizar updated_at automaticamente
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- Tabela de usuários (perfil) acoplada ao auth.users
CREATE TABLE IF NOT EXISTS public.users (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  name text NOT NULL,
  cpf text,
  phone text,
  email text NOT NULL UNIQUE,
  avatar_url text,
  role role_enum NOT NULL DEFAULT 'Equipe',
  status status_enum NOT NULL DEFAULT 'Ativo',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Trigger de atualização de updated_at
DO $$ BEGIN
  CREATE TRIGGER set_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- RLS e policies iniciais (Admin full; usuário vê seu próprio perfil)
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
-- Helper: checa se usuário atual é Admin
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role = 'Admin'
  );
$$ LANGUAGE sql STABLE;
-- Select: permitir Admin e o próprio usuário
DO $$ BEGIN
  CREATE POLICY users_select_self_or_admin ON public.users
    FOR SELECT TO authenticated
    USING (id = auth.uid() OR public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Insert/Update/Delete: somente Admin
DO $$ BEGIN
  CREATE POLICY users_admin_insert ON public.users
    FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY users_admin_update ON public.users
    FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY users_admin_delete ON public.users
    FOR DELETE TO authenticated
    USING (public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
