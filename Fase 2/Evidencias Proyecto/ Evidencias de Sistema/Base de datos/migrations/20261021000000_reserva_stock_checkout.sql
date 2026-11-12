-- Reserva temporal de inventario durante el checkout Webpay Mall (RF-002/RF-005).
--
-- Modelo de inventario:
--   disponible      = stock - stock_reservado
--   stock_reservado = unidades retenidas por checkouts en curso (no vendidas)
--   stock           = unidades fisicas; se descuentan con el trigger
--                     validar_transicion_pedido cuando el pedido pasa a 'pagado'.
--
-- La retencion vive mientras el checkout esta abierto y se libera:
--   * al confirmar (autorizado o rechazado definitivo),
--   * al vencer el plazo configurado RESERVA_STOCK_MINUTOS (backend),
--     mediante private.liberar_reservas_expiradas() que el servidor invoca
--     al iniciar/confirmar; la consistencia queda en la base de datos,
--     nunca en temporizadores del navegador.
begin;

alter table public.productos
  add column stock_reservado numeric(12,3) not null default 0;
alter table public.productos
  add constraint ck_producto_reserva_no_negativa check (stock_reservado >= 0);
comment on column public.productos.stock_reservado is
  'Unidades retenidas temporalmente por checkouts Webpay en curso. Disponible real = stock - stock_reservado; el backend valida esta formula al iniciar el checkout.';

alter table private.webpay_checkouts
  add column reservas_expiran_en timestamptz,
  add column reservas_liberadas_en timestamptz;
comment on column private.webpay_checkouts.reservas_expiran_en is
  'Momento en que la retencion de stock del checkout expira (now() + RESERVA_STOCK_MINUTOS al iniciar).';
comment on column private.webpay_checkouts.reservas_liberadas_en is
  'Marca idempotencia de la liberacion: si no es null, las reservas ya se devolvieron al inventario.';

create table private.checkout_reservas (
  checkout_id uuid not null references private.webpay_checkouts(id) on delete cascade,
  producto_id uuid not null references public.productos(id),
  cantidad numeric(12,3) not null check (cantidad > 0),
  creado_en timestamptz not null default now(),
  primary key (checkout_id, producto_id)
);
create index idx_checkout_reservas_producto on private.checkout_reservas(producto_id);
comment on table private.checkout_reservas is
  'Retencion de unidades por checkout y producto. Solo backend (service_role); el historial queda en el checkout, la posicion en productos es derivada.';
revoke all on private.checkout_reservas from public, anon, authenticated;
grant select, insert, update, delete on private.checkout_reservas to service_role;

-- Liberacion idempotente de TODAS las reservas de un checkout: al confirmarse
-- (pagado), rechazarse en firme o expirar. Bajo el lock del checkout para
-- serializar con cualquier liberacion concurrente.
create function private.liberar_reservas_checkout(p_checkout_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  perform 1 from private.webpay_checkouts
    where id = p_checkout_id for update;

  if not exists (
    select 1 from private.webpay_checkouts
    where id = p_checkout_id and reservas_liberadas_en is null
  ) then
    return;
  end if;

  for r in
    select producto_id, cantidad from private.checkout_reservas
    where checkout_id = p_checkout_id
    order by producto_id
  loop
    update public.productos
       set stock_reservado = stock_reservado - r.cantidad
     where id = r.producto_id;
    delete from private.checkout_reservas
     where checkout_id = p_checkout_id and producto_id = r.producto_id;
  end loop;

  update private.webpay_checkouts
     set reservas_liberadas_en = now()
   where id = p_checkout_id;
end;
$$;
revoke all on function private.liberar_reservas_checkout(uuid) from public, anon, authenticated;
grant execute on function private.liberar_reservas_checkout(uuid) to service_role;

-- Liberacion de reservas vencidas: checkouts abiertos cuyo plazo expiro sin
-- confirmarse. Devuelve la cantidad de checkouts liberados. Segura para
-- invocaciones concurrentes (el lock por checkout decide).
create function private.liberar_reservas_expiradas()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_liberados integer := 0;
  v_id uuid;
begin
  for v_id in
    select id from private.webpay_checkouts
    where reservas_liberadas_en is null
      and reservas_expiran_en is not null
      and reservas_expiran_en < now()
      and confirmado_en is null
    order by id
  loop
    perform private.liberar_reservas_checkout(v_id);
    v_liberados := v_liberados + 1;
  end loop;
  return v_liberados;
end;
$$;
revoke all on function private.liberar_reservas_expiradas() from public, anon, authenticated;
grant execute on function private.liberar_reservas_expiradas() to service_role;

commit;
