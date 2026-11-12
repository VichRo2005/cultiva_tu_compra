-- Normaliza los códigos de pedido históricos al formato comercial visible.
--
-- Los pedidos creados antes del cambio usaban CUTU-YYYYMMDD-<16 hex>, un código
-- largo que el cliente y el vendedor veían como "Pedido CUTU-20261028-3fe3a7...".
-- El formato comercial actual es CTC-YYYYMMDD-XXXXXX.
--
-- Se respetan los códigos de datos de prueba (CUTUCO-E2E-*) porque los fixtures
-- end-to-end los referencian por valor literal.
--
-- Idempotente: tras la primera ejecución no quedan filas que cumplan el patrón.

UPDATE public.pedidos
   SET codigo_pedido = 'CTC-'
                    || to_char(creado_en AT TIME ZONE 'UTC', 'YYYYMMDD')
                    || '-'
                    || upper(substr(md5(id::text), 1, 6))
 WHERE codigo_pedido ~ '^CUTU-[0-9]{8}-[0-9A-Fa-f]+$';
