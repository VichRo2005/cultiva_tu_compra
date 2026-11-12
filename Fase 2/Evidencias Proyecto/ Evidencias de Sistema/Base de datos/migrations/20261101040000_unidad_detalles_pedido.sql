-- Snapshot de la unidad de medida en el detalle del pedido.
--
-- El detalle no guardaba la unidad, así que la interfaz mostraba "undefined"
-- al listar los ítems ("1 producto · 1 undefined"). Se congela la unidad al
-- crear el pedido para que el histórico no dependa del producto actual.
--
-- Idempotente: se puede reaplicar sin efectos secundarios.

ALTER TABLE public.detalles_pedido
    ADD COLUMN IF NOT EXISTS unidad varchar(20);

-- Backfill de los detalles existentes con la unidad actual del producto.
--
-- El trigger `trg_validar_detalle_pedido` sólo permite tocar ítems mientras el
-- pedido está en estado `creado`, y `trg_recalcular_totales_pedido` recalcula
-- totales del pedido tras cada cambio. Para un backfill histórico (los pedidos
-- ya están pagados) se desactivan ambos durante la migración —todo dentro de la
-- misma transacción— y se vuelven a activar al final.
ALTER TABLE public.detalles_pedido DISABLE TRIGGER "trg_validar_detalle_pedido";
ALTER TABLE public.detalles_pedido DISABLE TRIGGER "trg_recalcular_totales_pedido";

UPDATE public.detalles_pedido AS d
   SET unidad = p.unidad_medida::text
  FROM public.productos AS p
 WHERE p.id = d.producto_id
   AND d.unidad IS NULL;

ALTER TABLE public.detalles_pedido ENABLE TRIGGER "trg_validar_detalle_pedido";
ALTER TABLE public.detalles_pedido ENABLE TRIGGER "trg_recalcular_totales_pedido";

COMMENT ON COLUMN public.detalles_pedido.unidad IS
    'Unidad de medida congelada al confirmar el pedido (public.unidad_medida_producto).';
