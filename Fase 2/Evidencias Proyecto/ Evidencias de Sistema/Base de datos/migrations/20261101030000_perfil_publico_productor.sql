-- HAL-CLI-005/HAL-CLI-006 — lectura pública del perfil del productor.
--
-- Las tablas `perfiles` y `evaluaciones_reputacion` tienen RLS que sólo permite
-- al propio usuario o al administrador. El catálogo y la ficha pública del
-- productor se consultan como `anon`, así que PostgREST respondía 401 y el
-- perfil quedaba sin nombre/calificaciones (además de "Sin evaluaciones" aún
-- con reseñas). Estas RPC exponen únicamente los campos públicos del productor
-- ACTIVO y sus evaluaciones, sin abrir las tablas.
--
-- No se exponen correo, RUT, dirección ni datos internos. El teléfono es el
-- dato de contacto comercial que el perfil público ya mostraba; si el proyecto
-- decide ocultarlo, se elimina de la proyección sin cambiar el resto.

begin;

create or replace function public.perfil_publico_productor(p_productor_id uuid)
returns table (
  id uuid,
  nombre varchar,
  apellido varchar,
  telefono varchar,
  creado_en timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p."id", p."nombre", p."apellido", p."telefono", p."creado_en"
  from public."productores" pr
  join public."perfiles" p on p."id" = pr."perfil_id"
  where pr."id" = p_productor_id
    and pr."activo" = true
    and p."eliminado_en" is null
  limit 1;
$$;

comment on function public.perfil_publico_productor(uuid) is
  'HAL-CLI-005/006: campos públicos del perfil de un productor activo, sin datos internos.';

create or replace function public.evaluaciones_publicas_productor(
  p_productor_id uuid,
  p_limit integer default 6
)
returns table (
  id uuid,
  puntaje smallint,
  comentario varchar,
  creado_en timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select e."id", e."puntaje", e."comentario", e."creado_en"
  from public."evaluaciones_reputacion" e
  join public."productores" pr on pr."id" = e."productor_id"
  where e."productor_id" = p_productor_id
    and pr."activo" = true
  order by e."creado_en" desc
  limit least(greatest(coalesce(p_limit, 6), 1), 20);
$$;

comment on function public.evaluaciones_publicas_productor(uuid, integer) is
  'HAL-CLI-005: reseñas públicas de un productor activo; no expone cliente_id ni pedido_id.';

revoke all on function public.perfil_publico_productor(uuid) from public;
revoke all on function public.evaluaciones_publicas_productor(uuid, integer) from public;
grant execute on function public.perfil_publico_productor(uuid) to anon, authenticated, service_role;
grant execute on function public.evaluaciones_publicas_productor(uuid, integer) to anon, authenticated, service_role;

commit;
