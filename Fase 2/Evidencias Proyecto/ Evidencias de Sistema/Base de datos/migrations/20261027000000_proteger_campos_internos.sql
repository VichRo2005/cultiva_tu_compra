-- Endurecimiento de campos internos y flujos de moderación.
--
-- Contexto de auditoría:
--   1) `productos` tiene UPDATE a nivel de fila para el vendedor. Sin una guardia
--      de columnas, un vendedor podía escribir `stock_reservado` por PostgREST y
--      alterar las retenciones del checkout (sobreventa o bloqueo de stock).
--   2) `productores.region_id` es una columna derivada de la dirección; la RLS
--      permitía al vendedor cambiarla y falsear su cobertura regional.
--   3) La política de INSERT de `reclamos` sólo validaba propiedad del pedido:
--      el cliente podía insertar un reclamo ya "resuelto" y saltarse el índice
--      de un reclamo abierto por pedido.
--   4) Una sanción admitía más de una apelación (el índice único sólo cubría las
--      pendientes), contra la regla de RF-026.
--
-- No se ejecutó contra PostgreSQL en esta sesión (Docker/Supabase detenidos):
-- queda registrado como cambio pendiente de aplicar y probar con
-- `supabase db reset`.

begin;

-- ------------------------------------------------------------------
-- 1) Campos internos de productos
-- ------------------------------------------------------------------
create or replace function public.proteger_campos_internos_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
begin
  v_jwt := current_setting('request.jwt.claims', true);

  -- Sin JWT (seed / backend), con service_role/postgres o dentro de otro trigger
  -- (reservas y checkout) se permite. Sólo se bloquea la escritura directa de un
  -- usuario autenticado por PostgREST.
  if v_jwt is null
     or pg_trigger_depth() > 1
     or current_user in ('postgres', 'service_role') then
    return new;
  end if;

  if new."stock_reservado" is distinct from old."stock_reservado" then
    raise exception 'El stock reservado solo puede modificarlo el checkout';
  end if;
  if new."productor_id" is distinct from old."productor_id"
     or new."codigo_producto" is distinct from old."codigo_producto" then
    raise exception 'La identidad comercial del producto es inmutable';
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_proteger_campos_internos_producto" on public."productos";
create trigger "trg_proteger_campos_internos_producto"
  before update on public."productos"
  for each row execute function public.proteger_campos_internos_producto();

-- ------------------------------------------------------------------
-- 2) Región derivada del productor
-- ------------------------------------------------------------------
create or replace function public.proteger_region_productor()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
begin
  v_jwt := current_setting('request.jwt.claims', true);

  if v_jwt is null
     or pg_trigger_depth() > 1
     or current_user in ('postgres', 'service_role') then
    return new;
  end if;

  if new."region_id" is distinct from old."region_id" then
    raise exception 'La region del productor se deriva de su direccion activa';
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_proteger_region_productor" on public."productores";
create trigger "trg_proteger_region_productor"
  before update on public."productores"
  for each row execute function public.proteger_region_productor();

-- ------------------------------------------------------------------
-- 3) Un reclamo nace abierto y no se puede falsear su resolución.
--    Cuando está resuelto/rechazado, el vendedor ya no puede editar su respuesta.
-- ------------------------------------------------------------------
create or replace function public.proteger_flujo_reclamo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new."estado" is distinct from 'abierto'
       or new."resuelto_por" is not null
       or new."resuelto_en" is not null then
      raise exception 'Un reclamo debe registrarse abierto y sin resolucion';
    end if;
    return new;
  end if;

  if old."estado" in ('resuelto', 'rechazado')
     and new."respuesta_productor" is distinct from old."respuesta_productor" then
    raise exception 'El reclamo ya fue cerrado y su respuesta no puede modificarse';
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_proteger_flujo_reclamo" on public."reclamos";
create trigger "trg_proteger_flujo_reclamo"
  before insert or update on public."reclamos"
  for each row execute function public.proteger_flujo_reclamo();

-- ------------------------------------------------------------------
-- 4) Apelaciones
-- ------------------------------------------------------------------
-- La regla vigente es una apelación PENDIENTE por sanción (índice
-- `uq_apelacion_pendiente_sancion`); tras una resolución rechazada el vendedor
-- puede volver a apelar, como ya prueba la suite de integración. Por eso NO se
-- agrega una unicidad absoluta por sanción.

commit;
