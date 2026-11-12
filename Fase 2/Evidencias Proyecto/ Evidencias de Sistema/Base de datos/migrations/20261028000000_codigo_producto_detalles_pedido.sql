-- Codigo comercial del producto en cada detalle de pedido para que la boleta/factura
-- y los PDFs muestren el identificador estable (PRD-XXXXXX) visible al vendedor y al cliente.
begin;

alter table public.detalles_pedido
  add column if not exists codigo_producto varchar(24);

-- Backfill solo para pedidos aún en estado 'creado' (los confirmados ya tienen su
-- estado congelado y el código se capturará en pedidos nuevos).
update public.detalles_pedido d
   set codigo_producto = p.codigo_producto
  from public.productos p, public.pedidos ped
 where p.id = d.producto_id
   and ped.id = d.pedido_id
   and d.codigo_producto is null
   and ped.estado = 'creado';

comment on column public.detalles_pedido.codigo_producto is
  'Codigo comercial del producto (PRD-XXXXXX) capturado al momento de la compra.';

commit;
