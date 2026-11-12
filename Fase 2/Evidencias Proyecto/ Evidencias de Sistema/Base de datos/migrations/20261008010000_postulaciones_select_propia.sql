-- ============================================================================
-- CuTuCo — El autor puede leer su propia postulación recién creada.
--
-- PROBLEMA QUE RESUELVE (reproducido contra la base local)
--   `postulaciones_vendedores` sólo tenía la policy de SELECT
--   `postulaciones_select_propia_admin`, cuyo predicado es el helper
--   `private.puede_acceder_postulacion(id)`. Ese helper vuelve a consultar
--   `postulaciones_vendedores` para comprobar la propiedad:
--
--     select ... or exists (
--       select 1 from public."postulaciones_vendedores" pv
--       where pv."id" = p_postulacion_id and pv."perfil_id" = (select auth.uid()));
--
--   PostgreSQL evalúa las policies de SELECT al aplicar `RETURNING`, que es lo
--   que emite PostgREST con `Prefer: return=representation` (el `.select()` del
--   cliente JS). La subconsulta usa el snapshot de la sentencia, que NO incluye
--   la fila que se acaba de insertar, así que el helper devuelve false y la
--   inserción falla con 42501:
--
--     POST /rest/v1/postulaciones_vendedores        -> 201 Created  (sin RETURNING)
--     POST /rest/v1/postulaciones_vendedores + Prefer: return=representation
--                                                    -> 42501 (RLS)
--
--   El registro público de vendedor (`crearPostulacion` en
--   `frontend/src/services/registro.js`) usa exactamente esa forma
--   (`.insert(...).select().single()`), de modo que la solicitud se guardaba en
--   la tabla pero el frontend recibía un error y nunca llegaba a guardar los
--   datos bancarios.
--
-- SOLUCIÓN
--   Policy de SELECT ADITIVA con una comparación directa de columna
--   (`perfil_id = auth.uid()`). Al evaluarse sobre la fila nueva, el propietario
--   sí la satisface durante el `RETURNING`. NO amplía el acceso: el alcance es
--   exactamente el mismo que ya concedía `puede_acceder_postulacion` para el
--   propio solicitante (el administrador sigue entrando por la policy
--   existente). No se elimina ni se modifica ninguna policy previa.
-- ============================================================================

create policy "postulaciones_select_propia"
  on public."postulaciones_vendedores" for select to authenticated
  using ((select auth.uid()) = "perfil_id");

comment on policy "postulaciones_select_propia" on public."postulaciones_vendedores" is
  'El solicitante lee su propia postulación, incluida la fila recién insertada durante el RETURNING de PostgREST (RF-021).';
