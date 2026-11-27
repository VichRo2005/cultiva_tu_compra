-- Paginación y filtro por estrellas para las reseñas públicas de una tienda.
--
-- La vista pública carga páginas pequeñas dentro de un contenedor con scroll.
-- Se mantiene la proyección mínima: no se exponen identificadores ni datos de
-- contacto del cliente.
begin;

drop function if exists public.evaluaciones_publicas_productor(uuid, integer);

create function public.evaluaciones_publicas_productor(
  p_productor_id uuid,
  p_limit integer default 11,
  p_offset integer default 0,
  p_puntaje smallint default null
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
    and (
      p_puntaje is null
      or (p_puntaje between 1 and 5 and e.puntaje = p_puntaje)
    )
  order by e.creado_en desc, e.id desc
  limit least(greatest(coalesce(p_limit, 11), 1), 20)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

comment on function public.evaluaciones_publicas_productor(uuid, integer, integer, smallint) is
  'Reseñas públicas paginadas de un productor activo, con filtro opcional por puntaje. Devuelve sólo puntaje, comentario, fecha, nombre de pila y avatar público del cliente.';

revoke all on function public.evaluaciones_publicas_productor(uuid, integer, integer, smallint) from public;
grant execute on function public.evaluaciones_publicas_productor(uuid, integer, integer, smallint)
  to anon, authenticated, service_role;

commit;
