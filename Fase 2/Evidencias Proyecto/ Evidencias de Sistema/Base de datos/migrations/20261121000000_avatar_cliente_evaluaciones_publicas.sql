-- Avatar y nombre de pila del cliente en evaluaciones públicas.
--
-- El bucket client-avatars ya es público (migración 20261118000000). Esta
-- proyección añade sólo datos de presentación a la RPC de reseñas: no expone
-- IDs, correo, RUT, teléfono, dirección ni el pedido asociado.
begin;

drop function if exists public.evaluaciones_publicas_productor(uuid, integer);

create function public.evaluaciones_publicas_productor(
  p_productor_id uuid,
  p_limit integer default 6
)
returns table (
  id uuid,
  puntaje smallint,
  comentario varchar,
  creado_en timestamptz,
  cliente_nombre varchar,
  cliente_foto_perfil_storage_path varchar
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    e.id,
    e.puntaje,
    e.comentario,
    e.creado_en,
    c.nombre as cliente_nombre,
    c.foto_perfil_storage_path as cliente_foto_perfil_storage_path
  from public.evaluaciones_reputacion e
  join public.productores pr on pr.id = e.productor_id
  left join public.perfiles c on c.id = e.cliente_id and c.eliminado_en is null
  where e.productor_id = p_productor_id
    and pr.activo = true
  order by e.creado_en desc
  limit least(greatest(coalesce(p_limit, 6), 1), 20);
$$;

comment on function public.evaluaciones_publicas_productor(uuid, integer) is
  'Reseñas públicas de un productor activo: devuelve puntaje, comentario, fecha, nombre de pila y avatar público del cliente, sin datos personales ni IDs.';

revoke all on function public.evaluaciones_publicas_productor(uuid, integer) from public;
grant execute on function public.evaluaciones_publicas_productor(uuid, integer)
  to anon, authenticated, service_role;

commit;
