-- ============================================================================
-- CuTuCo — El pago de un pedido es legible por los participantes del pedido.
--
-- PROBLEMA QUE RESUELVE
--   La migración base (`20261004021917_nuevo_alcance.sql`) declara sólo
--   `pagos_select_admin`, de modo que el SELECT de `public.pagos` queda
--   reservado a los administradores. El GRANT de tabla sí existe
--   (`grant select on public."pedidos", public."envios",
--   public."detalles_pedido", public."pagos" to authenticated`), pero la RLS
--   devuelve 0 filas a cualquier otro rol. Verificado contra la base local: un
--   cliente con 5 pedidos lee 5 filas de `pedidos` y 0 de `pagos`.
--
--   Eso rompe las actividades de compra que el mapeo declara por PostgREST:
--     * Historial de compras            -> `pedidos` + `pagos` (RF-002)
--     * Seguimiento del pedido          -> estado de custodia del pago (RF-005)
--     * Payouts del vendedor            -> estado del pago de sus pedidos (RF-014)
--
-- ALCANCE
--   La policy es ADITIVA: no se elimina ni se modifica `pagos_select_admin`
--   (en PostgreSQL las policies permisivas se combinan con OR). El alcance se
--   apoya en el helper ya existente `private.puede_acceder_pedido(uuid)`, que
--   autoriza exactamente a los mismos participantes que `pedidos`:
--   administrador, cliente del pedido y perfil del productor del pedido.
--   No se expone ningún pago ajeno y no se habilita escritura alguna: INSERT,
--   UPDATE y DELETE siguen reservados por `pagos_write_admin` y por el GRANT
--   de sólo lectura a `authenticated`.
-- ============================================================================

create policy "pagos_select_participantes"
  on public."pagos" for select to authenticated
  using ((select private.puede_acceder_pedido("pedido_id")));

comment on policy "pagos_select_participantes" on public."pagos" is
  'El cliente, el productor del pedido y el administrador pueden leer el pago de ese pedido (RF-002, RF-005 y RF-014). La escritura sigue siendo de FastAPI/service_role.';
