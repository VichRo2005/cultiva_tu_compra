-- Fixes MVP 09-11-2026 (Checklist_MVP_CuTuCo_09_11_2026)
-- 1) RUT opcional en boleta: se elimina el RUT generico fijo 66666666-6.
-- 2) RPC anon/authenticated para verificar disponibilidad de RUT de postulante
--    sin exponer filas (fix 401 al crear cuenta de vendedor).
-- 3) Calificaciones (RF-006): se puede calificar desde que el pedido esta pagado
--    y el cliente puede editar su propia calificacion.

begin;

-- 1) Boletas: el RUT pasa a ser opcional; ya no se fuerza 66666666-6.
alter table public.pedidos
  alter column documento_tributario set default '{"tipo":"boleta"}';

alter table public.pedidos drop constraint if exists ck_pedido_documento;
alter table public.pedidos add constraint ck_pedido_documento check (
  (documento_tributario->>'tipo' = 'boleta')
  or (
    documento_tributario->>'tipo' = 'factura'
    and length(btrim(coalesce(documento_tributario->>'rut_empresa',''))) > 0
    and length(btrim(coalesce(documento_tributario->>'razon_social',''))) > 0
    and length(btrim(coalesce(documento_tributario->>'giro',''))) > 0
    and length(btrim(coalesce(documento_tributario->>'direccion_tributaria',''))) > 0
  )
);

-- 2) Disponibilidad de RUT consultable por anon (pre-registro) sin exponer PII.
create or replace function public.rut_solicitante_disponible(p_rut text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1
    from public.postulaciones_vendedores pv
    where pv.rut_solicitante is not null
      and pv.estado::text <> 'rechazada'
      and regexp_replace(coalesce(pv.rut_solicitante, ''), '[^0-9kK]', '', 'g')
        = regexp_replace(coalesce(p_rut, ''), '[^0-9kK]', '', 'g')
  )
$$;
revoke all on function public.rut_solicitante_disponible(text) from public;
grant execute on function public.rut_solicitante_disponible(text) to anon, authenticated, service_role;

comment on function public.rut_solicitante_disponible(text) is
  'Devuelve true si ningun postulante activo (borrador/en_revision/aprobada/pendiente) usa ese RUT. Solo boolean, sin exponer filas. Usada por el registro de vendedor antes del signUp.';

-- 3) Calificar al vendedor desde que el pedido esta pagado, y poder editar la nota.
drop policy if exists "evaluaciones_insert_cliente" on public.evaluaciones_reputacion;
create policy "evaluaciones_insert_cliente"
  on public.evaluaciones_reputacion for insert to authenticated
  with check (
    "cliente_id" = (select auth.uid())
    and exists (
      select 1 from public.pedidos p
      where p."id" = "pedido_id"
        and p."cliente_id" = (select auth.uid())
        and p."estado"::text in ('pagado', 'en_preparacion', 'completado', 'reclamado')
    )
  );

drop policy if exists "evaluaciones_update_propio_cliente" on public.evaluaciones_reputacion;
create policy "evaluaciones_update_propio_cliente"
  on public.evaluaciones_reputacion for update to authenticated
  using (
    "cliente_id" = (select auth.uid())
    and exists (
      select 1 from public.pedidos p
      where p."id" = "pedido_id"
        and p."cliente_id" = (select auth.uid())
        and p."estado"::text in ('pagado', 'en_preparacion', 'completado', 'reclamado')
    )
  )
  with check (
    "cliente_id" = (select auth.uid())
    and exists (
      select 1 from public.pedidos p
      where p."id" = "pedido_id"
        and p."cliente_id" = (select auth.uid())
        and p."estado"::text in ('pagado', 'en_preparacion', 'completado', 'reclamado')
    )
  );

commit;
