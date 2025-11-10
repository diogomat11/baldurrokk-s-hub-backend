-- 0020_whatsapp_dead_letter.sql
-- Adds Dead-letter handling for WhatsApp outbox

BEGIN;
-- Add marker column to outbox for DLQ
ALTER TABLE public.whatsapp_outbox
  ADD COLUMN IF NOT EXISTS dead_letter_at timestamptz;
-- Dead-letter table
CREATE TABLE IF NOT EXISTS public.whatsapp_dead_letter (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outbox_id uuid NOT NULL REFERENCES public.whatsapp_outbox(id) ON DELETE CASCADE,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS whatsapp_dead_letter_outbox_idx ON public.whatsapp_dead_letter(outbox_id);
-- Function to move outbox row to dead-letter
CREATE OR REPLACE FUNCTION public.move_outbox_to_dead_letter(
  p_outbox_id uuid,
  p_reason text DEFAULT NULL
) RETURNS void AS $$
DECLARE
  v_exists boolean;
BEGIN
  -- Idempotent insert: only insert once per outbox_id
  SELECT EXISTS(
    SELECT 1 FROM public.whatsapp_dead_letter WHERE outbox_id = p_outbox_id
  ) INTO v_exists;

  IF NOT v_exists THEN
    INSERT INTO public.whatsapp_dead_letter(outbox_id, reason)
    VALUES (p_outbox_id, p_reason);
  END IF;

  -- Mark original outbox row as dead-lettered
  UPDATE public.whatsapp_outbox
  SET dead_letter_at = COALESCE(dead_letter_at, now()),
      updated_at = now(),
      error = CASE
        WHEN p_reason IS NULL THEN error
        ELSE COALESCE(error, '') || ';dlq=' || p_reason
      END
  WHERE id = p_outbox_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- RLS: allow admin full, finance read
ALTER TABLE public.whatsapp_dead_letter ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  -- Admin full access policy
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'whatsapp_dead_letter' AND policyname = 'whatsapp_dead_letter_admin_full'
  ) THEN
    CREATE POLICY whatsapp_dead_letter_admin_full ON public.whatsapp_dead_letter
      FOR ALL TO authenticated
      USING (auth.role() = 'admin') WITH CHECK (auth.role() = 'admin');
  END IF;

  -- Finance read-only policy
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'whatsapp_dead_letter' AND policyname = 'whatsapp_dead_letter_finance_read'
  ) THEN
    CREATE POLICY whatsapp_dead_letter_finance_read ON public.whatsapp_dead_letter
      FOR SELECT TO authenticated
      USING (auth.role() = 'finance');
  END IF;
END;
$$;
COMMIT;
