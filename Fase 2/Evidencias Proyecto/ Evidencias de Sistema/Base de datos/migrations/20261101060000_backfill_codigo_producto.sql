-- Completa codigo_producto en los detalles históricos.
--
-- La migración previa (codigo_producto_detalles_pedido) sólo hizo backfill de
-- los pedidos en estado 'creado'. Los pedidos ya pagados quedaron con la
-- columna en NULL y la interfaz/no mostraba el código comercial (PRD-XXXXXX).
--
-- Se desactivan los triggers de validación y de recálculo de totales durante el
-- backfill porque los pedidos históricos ya no están en estado 'creado'.
-- Idempotente: sólo toca filas con codigo_producto NULL.

ALTER TABLE public.detalles_pedido DISABLE TRIGGER "trg_validar_detalle_pedido";
ALTER TABLE public.detalles_pedido DISABLE TRIGGER "trg_recalcular_totales_pedido";

UPDATE public.detalles_pedido AS d
   SET codigo_producto = p.codigo_producto
  FROM public.productos AS p
 WHERE p.id = d.producto_id
   AND d.codigo_producto IS NULL
   AND p.codigo_producto IS NOT NULL;

ALTER TABLE public.detalles_pedido ENABLE TRIGGER "trg_validar_detalle_pedido";
ALTER TABLE public.detalles_pedido ENABLE TRIGGER "trg_recalcular_totales_pedido";
