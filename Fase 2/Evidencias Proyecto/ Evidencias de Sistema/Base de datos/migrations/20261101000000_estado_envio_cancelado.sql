-- HAL-VEN-029: la cancelación del vendedor debe propagarse al envío como
-- 'cancelado', no como 'fallido'. El valor del enum se agrega en una migración
-- separada porque PostgreSQL no permite usar un valor de enum nuevo dentro de
-- la misma transacción que lo crea.
--
-- La migración siguiente (20261101010000) redefine las funciones que usan este
-- valor. Fecha: posterior a 20261031000000 (catálogo maestro).

alter type public."estado_envio" add value if not exists 'cancelado';
