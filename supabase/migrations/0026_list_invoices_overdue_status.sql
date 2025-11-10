-- 0026_list_invoices_overdue_status.sql — Status derivado Vencida na listagem

-- Ajusta a RPC para marcar faturas vencidas como 'Vencida' quando due_date < hoje e não pagas/canceladas
BEGIN;
CREATE OR REPLACE FUNCTION public.list_invoices_for_month(
  p_month date,
  p_unit_id uuid DEFAULT NULL,
  p_status invoice_status_enum DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  student_id uuid,
  student_name text,
  unit_id uuid,
  unit_name text,
  status invoice_status_enum,
  due_date date,
  amount_total numeric(12,2),
  amount_discount numeric(12,2),
  amount_net numeric(12,2)
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    i.id,
    i.student_id,
    s.name AS student_name,
    i.unit_id,
    u.name AS unit_name,
    (
      CASE
        WHEN i.status <> 'Paga' AND i.status <> 'Cancelada' AND i.due_date < current_date THEN 'Vencida'
        ELSE i.status
      END
    )::invoice_status_enum AS status,
    i.due_date,
    i.amount_total,
    i.amount_discount,
    i.amount_net
  FROM public.invoices i
  LEFT JOIN public.students s ON s.id = i.student_id
  LEFT JOIN public.units u ON u.id = i.unit_id
  WHERE i.due_date >= date_trunc('month', p_month)::date
    AND i.due_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
    AND (p_unit_id IS NULL OR i.unit_id = p_unit_id)
    AND (p_status IS NULL OR i.status = p_status)
  ORDER BY i.due_date ASC;
$$;
COMMIT;