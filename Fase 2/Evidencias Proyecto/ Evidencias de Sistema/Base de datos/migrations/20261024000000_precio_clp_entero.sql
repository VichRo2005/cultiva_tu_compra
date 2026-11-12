-- Restriccion de precios a pesos enteros (CLP), consistente con Webpay:
-- el checkout exige un total entero (webpay_service._store), y un precio
-- con centavos romperia la compra de productos fraccionables (kg, litro).
-- Los precios existentes del seed y de la operacion son enteros.
begin;

alter table public.productos
  add constraint ck_producto_precio_entero
  check (precio = round(precio));
comment on constraint ck_producto_precio_entero on public.productos is
  'Precio en CLP entero: Webpay Plus no cobra centavos y el total del pedido debe ser integro.';

commit;
