-- Reglas comerciales de cantidad por producto.
--
-- `incremento_venta` define el salto de compra (por ejemplo, 1 kg o 0,250 kg)
-- y `cantidad_minima_compra` el mínimo exigido. Ambas cantidades comparten la
-- precisión de stock (tres decimales) para que puedan representar gramos.
begin;

alter table public.productos
  add column if not exists incremento_venta numeric(12,3),
  add column if not exists cantidad_minima_compra numeric(12,3);

-- Conserva el comportamiento histórico de los productos ya publicados:
-- 0,1 para unidades fraccionables y 1 para unidades discretas.
update public.productos
set
  incremento_venta = case
    when unidad_medida in ('kg', 'g', 'litro', 'ml') then 0.1
    else 1
  end,
  cantidad_minima_compra = case
    when unidad_medida in ('kg', 'g', 'litro', 'ml') then 0.1
    else 1
  end
where incremento_venta is null or cantidad_minima_compra is null;

alter table public.productos
  alter column incremento_venta set default 1,
  alter column incremento_venta set not null,
  alter column cantidad_minima_compra set default 1,
  alter column cantidad_minima_compra set not null;

alter table public.productos
  add constraint ck_producto_incremento_venta_positivo
    check (incremento_venta > 0),
  add constraint ck_producto_cantidad_minima_compra_positiva
    check (cantidad_minima_compra > 0),
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

comment on column public.productos.incremento_venta is
  'Cantidad mínima por incremento de venta. Ej.: 1 para vender por kilo completo o 0,250 para vender de 250 g en 250 g si la unidad es kg.';
comment on column public.productos.cantidad_minima_compra is
  'Cantidad mínima que el cliente puede comprar. Debe ser un múltiplo de incremento_venta.';

commit;
