-- Las cantidades comerciales de un producto se expresan con como máximo un
-- decimal en formulario, catálogo, API y base de datos. Los importes CLP se
-- mantienen enteros porque Webpay no acepta centavos.
begin;

alter table public.productos
  drop constraint if exists ck_producto_minimo_multiplo_incremento,
  drop constraint if exists ck_producto_unidad_discreta_reglas_enteras;

alter table public.productos
  alter column stock type numeric(12,1) using round(stock, 1),
  alter column incremento_venta type numeric(12,1) using round(incremento_venta, 1),
  alter column cantidad_minima_compra type numeric(12,1) using round(cantidad_minima_compra, 1);

-- Tras redondear el incremento, el mínimo se eleva al siguiente múltiplo
-- válido. Con ello nunca se ofrece una cantidad que el checkout rechazaría.
update public.productos
set cantidad_minima_compra = ceil(cantidad_minima_compra / incremento_venta)
  * incremento_venta
where mod(cantidad_minima_compra, incremento_venta) <> 0;

alter table public.productos
  add constraint ck_producto_minimo_multiplo_incremento
    check (mod(cantidad_minima_compra, incremento_venta) = 0),
  add constraint ck_producto_unidad_discreta_reglas_enteras
    check (
      unidad_medida in ('kg', 'g', 'litro', 'ml')
      or (
        incremento_venta = trunc(incremento_venta)
        and cantidad_minima_compra = trunc(cantidad_minima_compra)
      )
    );

comment on column public.productos.stock is
  'Stock comercial del producto, con un máximo de un decimal.';
comment on column public.productos.incremento_venta is
  'Incremento de compra del producto, con un máximo de un decimal.';
comment on column public.productos.cantidad_minima_compra is
  'Compra mínima del producto, con un máximo de un decimal y múltiplo del incremento.';

create or replace function public.validar_limites_numericos_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.precio < 0 or new.precio > 999999 or new.precio <> trunc(new.precio) then
    raise exception 'El precio debe ser un entero entre 0 y 999.999 CLP';
  end if;
  if new.stock < 0 or new.stock > 999999999.9 or new.stock <> round(new.stock, 1) then
    raise exception 'El stock debe tener como máximo un decimal';
  end if;
  if new.incremento_venta <= 0 or new.incremento_venta <> round(new.incremento_venta, 1) then
    raise exception 'El incremento de venta debe tener como máximo un decimal';
  end if;
  if new.cantidad_minima_compra <= 0
     or new.cantidad_minima_compra <> round(new.cantidad_minima_compra, 1) then
    raise exception 'La compra mínima debe tener como máximo un decimal';
  end if;
  if new.stock_reservado < 0 or new.stock_reservado > 999999999.999 then
    raise exception 'El stock reservado debe estar entre 0 y 999.999.999,999 unidades';
  end if;
  return new;
end;
$$;

commit;
