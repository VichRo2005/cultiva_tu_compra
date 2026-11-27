-- Contacto por email del productor activo.
--
-- El perfil público del vendedor ya exponía teléfono como dato de contacto
-- comercial. Esta migración incorpora el correo del productor (auth.users.email)
-- para que el comprador pueda contactar al vendedor por email desde el detalle
-- de su pedido, sin exponer RUT, dirección ni datos bancarios.
--
-- El correo es un dato de contacto comercial del vendedor publicado en la
-- plataforma; no es un secreto de cuenta (no permite iniciar sesión).

begin;

-- Al agregar la columna `email` cambia el tipo de retorno, así que hay que
-- eliminar la función anterior antes de recrearla (PostgreSQL no permite
-- cambiar el tipo de retorno con CREATE OR REPLACE).
drop function if exists public.perfil_publico_productor(uuid);

create or replace function public.perfil_publico_productor(p_productor_id uuid)
returns table (
  id uuid,
  nombre varchar,
  apellido varchar,
  telefono varchar,
  email varchar,
  creado_en timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p."id", p."nombre", p."apellido", p."telefono", u."email", p."creado_en"
  from public."productores" pr
  join public."perfiles" p on p."id" = pr."perfil_id"
  join auth.users u on u."id" = p."id"
  where pr."id" = p_productor_id
    and pr."activo" = true
    and p."eliminado_en" is null
  limit 1;
$$;

comment on function public.perfil_publico_productor(uuid) is
  'Campos públicos del perfil de un productor activo: nombre, teléfono y correo de contacto comercial, sin datos internos.';

revoke all on function public.perfil_publico_productor(uuid) from public;
grant execute on function public.perfil_publico_productor(uuid) to anon, authenticated, service_role;

commit;
