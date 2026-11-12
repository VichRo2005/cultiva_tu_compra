-- CK-0128/0129: el ajuste manual no puede consumir stock reservado.
-- Conserva la excepción existente para operaciones internas del checkout.
begin;
create or replace function public.proteger_campos_internos_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
begin
  v_jwt := current_setting('request.jwt.claims', true);
  if v_jwt is null
     or pg_trigger_depth() > 1
     or current_user in ('postgres', 'service_role') then
    return new;
  end if;

  if new.stock_reservado is distinct from old.stock_reservado then
    raise exception 'El stock reservado solo puede modificarlo el checkout';
  end if;
  if new.productor_id is distinct from old.productor_id
     or new.codigo_producto is distinct from old.codigo_producto then
    raise exception 'La identidad comercial del producto es inmutable';
  end if;
  if new.stock is distinct from old.stock and new.stock < old.stock_reservado then
    raise exception 'El stock no puede ser menor que las unidades reservadas en compras pendientes';
  end if;
  return new;
end;
$$;
commit;
