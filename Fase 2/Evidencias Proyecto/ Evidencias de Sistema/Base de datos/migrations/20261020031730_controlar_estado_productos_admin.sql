alter table public.productos
  add column motivo_pausa text;

comment on column public.productos.motivo_pausa is
  'Motivo registrado al pausar un producto; se limpia al publicarlo o eliminarlo.';

alter table public.productos
  add constraint productos_eliminados_inactivos
  check (eliminado_en is null or activo = false);

create function public.controlar_estado_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_productor_activo boolean;
begin
  if old.eliminado_en is not null and
     (new.activo is distinct from old.activo or new.eliminado_en is distinct from old.eliminado_en) then
    raise exception 'Un producto eliminado no puede cambiar de estado';
  end if;

  if new.activo is distinct from old.activo or new.eliminado_en is distinct from old.eliminado_en then
    select p.activo into v_productor_activo
      from public.productores p
      where p.id = old.productor_id
      for share;
    if v_productor_activo is distinct from true then
      raise exception 'No se puede cambiar el estado de un producto de un productor desactivado';
    end if;
  end if;

  if new.eliminado_en is not null then
    if new.activo then
      raise exception 'Un producto eliminado debe estar inactivo';
    end if;
    new.motivo_pausa := null;
  elsif new.activo then
    new.motivo_pausa := null;
  elsif old.activo and not new.activo and nullif(btrim(new.motivo_pausa), '') is null then
    raise exception 'Debe registrar un motivo para pausar el producto';
  end if;

  if new.motivo_pausa is not null then
    new.motivo_pausa := nullif(btrim(new.motivo_pausa), '');
  end if;
  return new;
end;
$$;

create trigger controlar_estado_producto
before update on public.productos
for each row execute function public.controlar_estado_producto();
