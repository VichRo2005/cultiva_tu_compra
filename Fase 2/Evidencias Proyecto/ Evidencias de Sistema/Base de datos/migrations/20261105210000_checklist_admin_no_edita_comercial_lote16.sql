-- Lote 16 (Administración y cobros), CK-0266:
-- La edición de la información COMERCIAL del producto (nombre, descripción,
-- precio, stock, unidad, categoría, fecha de cosecha) queda reservada al
-- vendedor dueño. El admin puede operar el estado (activo/eliminado_en/motivo)
-- pero no editar datos comerciales por PostgREST.
-- El backend (service_role/postgres/sin JWT) y los triggers internos
-- (checkout ajusta stock) quedan excluidos como en proteger_campos_internos.
begin;

create or replace function public.proteger_edicion_comercial_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  v_jwt := current_setting('request.jwt.claims', true);
  if v_jwt is null
     or pg_trigger_depth() > 1
     or current_user in ('postgres', 'service_role') then
    return new;
  end if;

  -- Actor autenticado que NO es el vendedor del producto (p. ej. admin):
  if not (select private.es_productor_actual(new."productor_id")) then
    if new."nombre" is distinct from old."nombre"
       or new."descripcion" is distinct from old."descripcion"
       or new."precio" is distinct from old."precio"
       or new."stock" is distinct from old."stock"
       or new."unidad_medida" is distinct from old."unidad_medida"
       or new."categoria_id" is distinct from old."categoria_id"
       or new."fecha_cosecha" is distinct from old."fecha_cosecha" then
      raise exception 'Solo el vendedor puede editar la información comercial del producto';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_proteger_edicion_comercial_producto" on public."productos";
create trigger "trg_proteger_edicion_comercial_producto"
  before update on public."productos"
  for each row execute function public.proteger_edicion_comercial_producto();

commit;
