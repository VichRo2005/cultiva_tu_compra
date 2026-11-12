-- CK-0466/0497: publicar comuna real, sin calle, número ni referencia privada.
begin;
create or replace function public.ubicaciones_publicas_productores(p_perfil_ids uuid[])
returns table (perfil_id uuid, comuna_id uuid, nombre varchar, region_id uuid)
language sql stable security definer set search_path = '' as $$
  select pr.perfil_id, c.id, c.nombre, c.region_id
  from public.productores pr
  join public.perfiles pf on pf.id=pr.perfil_id
  join lateral (
    select d.comuna_id from public.direcciones d
    where d.perfil_id=pr.perfil_id and d.activo
    order by d.es_principal desc, d.id limit 1
  ) d on true
  join public.comunas c on c.id=d.comuna_id
  where pr.perfil_id=any(p_perfil_ids)
    and pr.activo and not pr.servicio_suspendido
    and pr.codigo_comercio_mall is not null
    and pf.activo and pf.eliminado_en is null;
$$;
revoke all on function public.ubicaciones_publicas_productores(uuid[]) from public;
grant execute on function public.ubicaciones_publicas_productores(uuid[]) to anon, authenticated, service_role;
commit;
