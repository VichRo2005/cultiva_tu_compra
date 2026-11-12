alter table public.productos
  add column motivo_eliminacion text;

comment on column public.productos.motivo_eliminacion is
  'Justificación registrada al eliminar lógicamente el producto.';

create or replace function public.controlar_estado_producto()
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
    if old.eliminado_en is null or new.motivo_eliminacion is distinct from old.motivo_eliminacion then
      new.motivo_eliminacion := btrim(new.motivo_eliminacion);
      if char_length(coalesce(new.motivo_eliminacion, '')) not between 10 and 1000 then
        raise exception 'La justificación de eliminación debe tener entre 10 y 1000 caracteres';
      end if;
    end if;
    new.motivo_pausa := null;
  else
    new.motivo_eliminacion := null;
    if new.activo then
      new.motivo_pausa := null;
    elsif old.activo or new.motivo_pausa is distinct from old.motivo_pausa then
      new.motivo_pausa := btrim(new.motivo_pausa);
      if char_length(coalesce(new.motivo_pausa, '')) not between 10 and 1000 then
        raise exception 'La justificación de pausa debe tener entre 10 y 1000 caracteres';
      end if;
    end if;
  end if;
  return new;
end;
$$;
