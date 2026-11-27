-- REG-VEN-015: el registro público "Quiero vender" corre sin sesión (rol anon) y
-- la RLS impide leer postulaciones_vendedores (SELECT sólo para authenticated).
-- Esta RPC expone únicamente un booleano con la disponibilidad del RUT, sin
-- revelar filas ni datos de postulantes (el contrato mantiene la tabla privada
-- para anon y terceros).
begin;
create or replace function public.rut_solicitante_disponible(p_rut text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (
    select 1
    from public.postulaciones_vendedores
    where rut_solicitante = p_rut
  )
$$;
revoke all on function public.rut_solicitante_disponible(text) from public;
grant execute on function public.rut_solicitante_disponible(text) to anon, authenticated, service_role;
comment on function public.rut_solicitante_disponible(text) is
  'REG-VEN-015: true si el RUT aún no está asociado a ninguna postulación. SECURITY DEFINER para que anon (registro sin sesión) consulte la disponibilidad sin exponer datos de la tabla.';
commit;
