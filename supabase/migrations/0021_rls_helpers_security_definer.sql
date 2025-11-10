-- 0021_rls_helpers_security_definer.sql — Corrige recursão nas funções auxiliares de RLS

BEGIN;
-- Tornar funções auxiliares de papel SECURITY DEFINER para evitar recursão em RLS
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role = 'Admin'
  );
$$;
CREATE OR REPLACE FUNCTION public.is_manager()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role = 'Gerente'
  );
$$;
CREATE OR REPLACE FUNCTION public.is_finance()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role = 'Financeiro'
  );
$$;
COMMIT;