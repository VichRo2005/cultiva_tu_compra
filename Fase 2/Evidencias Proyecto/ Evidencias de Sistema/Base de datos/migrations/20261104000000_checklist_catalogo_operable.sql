-- La lectura pública de un producto exige que la tienda y su perfil puedan operar.
-- El dueño y el administrador conservan acceso a productos pausados para gestionarlos.
create or replace function private.productor_operable(p_productor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.productores pr
    join public.perfiles pf on pf.id = pr.perfil_id
    where pr.id = p_productor_id
      and pr.activo
      and not pr.servicio_suspendido
      and pf.activo
  );
$$;

revoke all on function private.productor_operable(uuid) from public;
grant execute on function private.productor_operable(uuid) to anon, authenticated;

drop policy if exists "productos_select_publico" on public.productos;
create policy "productos_select_publico"
  on public.productos for select to anon, authenticated
  using (
    activo = true
    and eliminado_en is null
    and (select private.productor_operable(productor_id))
  );

drop policy if exists "productos_select_vendedor_admin" on public.productos;
create policy "productos_select_vendedor_admin"
  on public.productos for select to authenticated
  using (
    (select private.es_productor_actual(productor_id))
    or (select private.es_admin_actual())
  );

drop policy if exists "imagenes_productos_select_publico" on public.imagenes_productos;
create policy "imagenes_productos_select_publico"
  on public.imagenes_productos for select to anon, authenticated
  using (exists (
    select 1
    from public.productos p
    where p.id = producto_id
      and p.activo = true
      and p.eliminado_en is null
      and (select private.productor_operable(p.productor_id))
  ));

comment on function private.productor_operable(uuid) is
  'Estado público de operación: productor y perfil activos, sin suspensión del servicio.';
