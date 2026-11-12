-- Lote 17 (Servicio mensual), CK-0244:
-- Al día 16 desde la emisión sin pago la tienda queda suspendida
-- (private.sincronizar_morosidad_productor, vence_en + 5 < hoy en America/Santiago).
-- Efectos: los productos se ocultan del catálogo público (20261102020000,
-- 20261104000000) y el checkout rechaza al vendedor suspendido
-- (backend webpay_service). Aquí se bloquea además la PUBLICACIÓN y la
-- EDICIÓN de productos del vendedor suspendido por PostgREST.
-- El admin conserva el control de estado (pausar/publicar/eliminar) y el
-- backend (service_role/postgres/sin JWT) y los triggers internos no se ven
-- afectados (mismo bypass que proteger_campos_internos_producto).
begin;

create or replace function public.bloquear_productos_productor_suspendido()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
  v_suspendido boolean;
begin
  v_jwt := current_setting('request.jwt.claims', true);
  if v_jwt is null
     or pg_trigger_depth() > 1
     or current_user in ('postgres', 'service_role') then
    return new;
  end if;

  -- El admin puede operar el estado del catálogo aunque la tienda esté suspendida.
  if (select private.es_admin_actual()) then
    return new;
  end if;

  select p.servicio_suspendido into v_suspendido
    from public."productores" p
   where p."id" = new."productor_id";

  if coalesce(v_suspendido, false) then
    raise exception 'La tienda está suspendida por deuda del servicio mensual; regulariza el pago para publicar o editar productos';
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_bloquear_productos_productor_suspendido" on public."productos";
create trigger "trg_bloquear_productos_productor_suspendido"
  before insert or update on public."productos"
  for each row execute function public.bloquear_productos_productor_suspendido();

commit;
