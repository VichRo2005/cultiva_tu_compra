-- Durable private checkout; public payments remain successful store receipts only.
begin;
create table private.webpay_checkouts (
  id uuid primary key,
  cliente_id uuid not null references public.perfiles(id),
  buy_order varchar(26) not null unique check (buy_order like 'M%'),
  session_id varchar(61) not null,
  token_ws varchar(255) unique,
  snapshot jsonb not null,
  respuesta jsonb,
  resultado jsonb,
  creado_en timestamptz not null default now(),
  confirmado_en timestamptz
);
create table private.webpay_ordenes (
  buy_order varchar(26) primary key check (buy_order ~ '^[SF]'),
  checkout_id uuid not null references private.webpay_checkouts(id)
);
revoke all on private.webpay_checkouts, private.webpay_ordenes from public, anon, authenticated;
grant select, insert, update on private.webpay_checkouts to service_role;
grant select, insert on private.webpay_ordenes to service_role;

alter table public.pedidos
  add column checkout_id uuid references private.webpay_checkouts(id),
  add column documento_tributario jsonb not null default '{"tipo":"boleta","rut":"66666666-6"}',
  add constraint ck_pedido_documento check (
    (documento_tributario->>'tipo' = 'boleta' and documento_tributario->>'rut' = '66666666-6')
    or (documento_tributario->>'tipo' = 'factura'
      and length(btrim(coalesce(documento_tributario->>'rut_empresa',''))) > 0
      and length(btrim(coalesce(documento_tributario->>'razon_social',''))) > 0
      and length(btrim(coalesce(documento_tributario->>'giro',''))) > 0
      and length(btrim(coalesce(documento_tributario->>'direccion_tributaria',''))) > 0)
  );
create unique index uq_pedido_checkout_productor on public.pedidos(checkout_id, productor_id);
alter table public.pagos add column monto_fee_descontado numeric(12,2) not null default 0
  check (monto_fee_descontado >= 0);
comment on column public.pagos.monto_fee_descontado is
  'Fee separado del importe enviado a la tienda, redondeado a CLP entero. Cero en pagos anteriores.';
create or replace function private.validar_registro_webpay()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_total numeric;
  v_comercio text;
  v_estado public.estado_pedido;
  v_fee numeric;
  v_checkout uuid;
begin
  if tg_op <> 'INSERT' then
    raise exception 'El comprobante autorizado es inmutable';
  end if;
  select p.total, pr.codigo_comercio_mall, p.estado, p.monto_fee_plataforma, p.checkout_id
    into v_total, v_comercio, v_estado, v_fee, v_checkout
    from public.pedidos p join public.productores pr on pr.id = p.productor_id
    where p.id = new.pedido_id for update of p;
  if v_checkout is not null then
    select tienda->'detail'->>'commerce_code' into v_comercio
    from private.webpay_checkouts c, jsonb_array_elements(c.snapshot->'tiendas') tienda
    where c.id = v_checkout and tienda->'detail'->>'buy_order' = new.buy_order;
    if new.monto_fee_descontado <> round(v_fee, 0) then
      raise exception 'El fee debe coincidir con el checkout';
    end if;
  elsif new.monto_fee_descontado <> 0 then
    raise exception 'Un fee separado requiere un checkout Mall';
  end if;
  if v_estado is null or v_estado <> 'creado' or new.monto is distinct from (v_total - new.monto_fee_descontado) then
    raise exception 'El pago requiere un pedido creado y el importe exacto de su total';
  end if;
  if new.codigo_comercio is null or new.codigo_comercio is distinct from v_comercio
    or new.codigo_comercio !~ '^[0-9]{12}$'
    or nullif(btrim(new.token_ws), '') is null
    or nullif(btrim(new.buy_order), '') is null
    or nullif(btrim(new.buy_order_mall), '') is null
    or nullif(btrim(new.session_id), '') is null
    or nullif(btrim(new.codigo_autorizacion), '') is null
    or new.codigo_respuesta is distinct from '0' or new.autorizado_en is null then
    raise exception 'Faltan los identificadores y la autorizacion de Webpay Mall';
  end if;
  -- Solo el detail de este pedido: nunca el array completo del checkout.
  if jsonb_typeof(new.respuesta_webpay) is distinct from 'object'
    or new.respuesta_webpay ? 'details'
    or new.respuesta_webpay->>'status' is distinct from 'AUTHORIZED'
    or new.respuesta_webpay->'response_code' is distinct from '0'::jsonb
    or new.respuesta_webpay->>'commerce_code' is distinct from new.codigo_comercio
    or new.respuesta_webpay->>'buy_order' is distinct from new.buy_order
    or new.respuesta_webpay->>'authorization_code' is distinct from new.codigo_autorizacion
    or new.respuesta_webpay->'amount' is distinct from to_jsonb(new.monto) then
    raise exception 'El detail Webpay debe corresponder a una subtransaccion AUTHORIZED con response_code 0';
  end if;
  return new;
end;
$$;
create or replace function public.crear_envio_al_pagar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_repartidor_id uuid;
begin
  if new."estado" = 'pagado' and old."estado" is distinct from new."estado" then
    select pr."perfil_id"
      into v_repartidor_id
    from public."productores" pr
    where pr."id" = new."productor_id";

    if v_repartidor_id is null then
      raise exception 'El pedido no tiene un productor valido para crear el envio';
    end if;

    insert into public."envios" (
      "pedido_id",
      "repartidor_id",
      "estado",
      "tarifa_fija"
    ) values (
      new."id",
      v_repartidor_id,
      'preparacion'::public."estado_envio",
      new."tarifa_delivery"
    );

    -- Preserve legacy seed behavior; new Mall orders stay paid.
    if new.checkout_id is null then
    update public."pedidos"
       set "estado" = 'en_preparacion'::public."estado_pedido"
     where "id" = new."id"
       and "estado" = 'pagado'::public."estado_pedido";
    end if;
  end if;

  return new;
end;
$$;
create function private.proteger_documento_checkout()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.checkout_id is distinct from old.checkout_id
    or new.documento_tributario is distinct from old.documento_tributario then
    raise exception 'El checkout y documento tributario del pedido son inmutables';
  end if;
  return new;
end;
$$;
create trigger trg_proteger_documento_checkout before update on public.pedidos
for each row execute function private.proteger_documento_checkout();
revoke all on function private.proteger_documento_checkout() from public, anon, authenticated;
commit;
