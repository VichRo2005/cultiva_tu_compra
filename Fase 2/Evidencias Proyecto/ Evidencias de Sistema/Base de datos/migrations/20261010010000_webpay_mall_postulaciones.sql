-- Webpay Mall. Compatible con PostgreSQL 16+.
-- Migracion incremental: no modifica los placeholders de galeria.
begin;

drop trigger trg_validar_transicion_pago on public.pagos;
drop trigger trg_sincronizar_escrow_pago on public.pagos;
drop trigger trg_crear_payout_al_completar on public.pedidos;
drop trigger trg_validar_payout on public.payouts;
drop trigger trg_sincronizar_payout_pedido on public.payouts;
drop function public.registrar_payout_pagado(uuid, text, text);
drop function public.registrar_devolucion_cliente(uuid, numeric, text, boolean);
drop function public.validar_transicion_pago();
drop function public.sincronizar_escrow_pago();
drop function public.crear_payout_al_completar();
drop function public.validar_payout();
drop function public.sincronizar_payout_pedido();
-- La policy de SELECT depende del helper.
drop policy payouts_select_beneficiario_admin on public.payouts;
drop function private.puede_acceder_payout(uuid);
drop table public.payouts;
drop type public.tipo_payout;
drop type public.estado_payout;

-- Estos campos pertenecian a pedidos, no a productores.
alter table public.pedidos
  drop column monto_retenido,
  drop column monto_liquidar_productor,
  drop column liberable_desde_en,
  drop column payout_ejecutado_en;

-- pagos conserva solo comprobantes exitosos. Se descartan los intentos
-- creados/rechazados sin crear una tabla auxiliar de archivo.
delete from public.pagos where estado in ('creado', 'rechazado');
alter table public.pagos
  drop constraint pagos_buy_order_key,
  drop constraint pagos_token_ws_key,
  drop column estado,
  drop column retenido_en,
  drop column liberado_en,
  drop column reembolsado_en,
  add column buy_order_mall varchar(80),
  add column codigo_comercio varchar(12),
  add column session_id varchar(61);
drop type public.estado_pago;
-- NULL identifica informacion ausente en registros anteriores al cambio.
alter table public.pagos add constraint uq_pago_subtransaccion
  unique (token_ws, codigo_comercio, buy_order);
create index idx_pagos_orden_mall on public.pagos(buy_order_mall);
drop policy pagos_write_admin on public.pagos;
revoke insert, update, delete on public.pagos from anon, authenticated;
grant select, insert on public.pagos to service_role;
revoke update, delete, truncate on public.pagos from service_role;

alter table public.productores
  add column rut_oficial varchar(12),
  add column codigo_comercio_mall varchar(12),
  add constraint ck_productor_rut_formato check (rut_oficial ~ '^[0-9]{7,8}-[0-9K]$'),
  add constraint ck_productor_comercio_formato check (codigo_comercio_mall ~ '^[0-9]{12}$');
-- Intencionalmente SIN UNIQUE: los comercios de integracion se reutilizan.
comment on column public.productores.codigo_comercio_mall is
  'Comercio hijo Webpay Mall. Nullable hasta su configuracion por administracion/backend; no es unico.';

create function private.validar_registro_webpay()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_total numeric;
  v_comercio text;
  v_estado public.estado_pedido;
begin
  if tg_op <> 'INSERT' then
    raise exception 'El comprobante autorizado es inmutable';
  end if;
  select p.total, pr.codigo_comercio_mall, p.estado
    into v_total, v_comercio, v_estado
    from public.pedidos p join public.productores pr on pr.id = p.productor_id
    where p.id = new.pedido_id for update of p;
  if not found or v_estado <> 'creado' or new.monto is distinct from v_total then
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
create trigger trg_validar_registro_webpay before insert or update or delete on public.pagos
  for each row execute function private.validar_registro_webpay();
revoke all on function private.validar_registro_webpay() from public, anon, authenticated;
comment on table public.pagos is
  'Comprobante exitoso por pedido/subtransaccion. Token y orden Mall pueden compartirse; solo backend inserta. Registros Plus historicos conservan metadatos Mall NULL.';
comment on column public.pagos.respuesta_webpay is
  'Detail autorizado de este pedido, no respuesta completa con datos de otros vendedores. Registros Plus previos conservan su respuesta original.';
comment on table public.reclamos is
  'Disputa del cliente para trazabilidad y resolucion administrativa; no ejecuta movimientos de dinero.';

create or replace function public.recalcular_totales_pedido(p_pedido_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subtotal numeric(12,2);
  v_delivery numeric(12,2);
  v_porcentaje numeric(5,4);
  v_fee numeric(12,2);
  v_total numeric(12,2);
begin
  select
    coalesce(sum(d."subtotal"), 0),
    p."tarifa_delivery",
    p."porcentaje_fee_plataforma"
    into v_subtotal, v_delivery, v_porcentaje
  from public."pedidos" p
  left join public."detalles_pedido" d on d."pedido_id" = p."id"
  where p."id" = p_pedido_id
  group by p."id", p."tarifa_delivery", p."porcentaje_fee_plataforma";

  if not found then
    return;
  end if;

  v_fee := round(v_subtotal * v_porcentaje, 2);
  v_total := round(v_subtotal + v_delivery, 2);

  update public."pedidos"
     set "subtotal_productos" = v_subtotal,
         "monto_fee_plataforma" = v_fee,
         "total" = v_total
   where "id" = p_pedido_id;
end;
$$;

create or replace function public.validar_transicion_pedido()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  item_record record;
begin
  if new."estado" = old."estado" then
    return new;
  end if;

  if pg_trigger_depth() > 1 then
    return new;
  end if;

  if not (
    (old."estado" = 'creado' and new."estado" in ('pagado', 'cancelado'))
    or (old."estado" = 'pagado' and new."estado" in ('en_preparacion', 'cancelado'))
    or (old."estado" = 'en_preparacion' and new."estado" = 'cancelado')
    or (old."estado" = 'completado' and new."estado" = 'reclamado')
    or (old."estado" = 'reclamado' and new."estado" in ('completado', 'cancelado'))
  ) then
    raise exception 'Transicion de pedido no permitida: % -> %', old."estado", new."estado";
  end if;

  if new."estado" = 'pagado' then
    if not exists (
      select 1 from public."detalles_pedido" d where d."pedido_id" = new."id"
    ) then
      raise exception 'No se puede marcar el pedido como pagado sin items';
    end if;

    if new."total" <= 0 then
      raise exception 'No se puede marcar el pedido como pagado con total cero';
    end if;

    if not exists (
      select 1 from public."pagos" p
      where p."pedido_id" = new."id"
    ) then
      raise exception 'No se puede marcar el pedido como pagado sin comprobante Webpay autorizado';
    end if;

    -- Descuento de stock por cada linea del pedido.
    -- Si algun producto no tiene stock suficiente, la transicion aborta.
    for item_record in
      select d."producto_id", d."cantidad"
      from public."detalles_pedido" d
      where d."pedido_id" = new."id"
        and d."producto_id" is not null
    loop
      update public."productos" p
         set "stock" = p."stock" - item_record."cantidad"
       where p."id" = item_record."producto_id"
         and p."stock" >= item_record."cantidad";

      if not found then
        raise exception 'Stock insuficiente para el producto %', item_record."producto_id";
      end if;
    end loop;
  end if;

  if new."estado" = 'cancelado' then
    -- Solo se repone stock si el pedido ya lo habia descontado
    -- (estaba en pagado o en_preparacion) y no se ha repuesto antes.
    if old."estado" in ('pagado', 'en_preparacion')
       and old."inventario_repuesto_en" is null then
      for item_record in
        select d."producto_id", d."cantidad"
        from public."detalles_pedido" d
        where d."pedido_id" = new."id"
          and d."producto_id" is not null
      loop
        update public."productos"
           set "stock" = "stock" + item_record."cantidad"
         where "id" = item_record."producto_id";
      end loop;

      new."inventario_repuesto_en" := now();
    end if;

    new."cancelado_en" := coalesce(new."cancelado_en", now());
  end if;

  return new;
end;
$$;

create or replace function public.sincronizar_envio_entregado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new."estado" = 'entregado' and old."estado" is distinct from new."estado" then
    update public."pedidos"
       set "estado" = 'completado'::public."estado_pedido",
           "confirmado_cliente_en" = coalesce("confirmado_cliente_en", new."entregado_en")
     where "id" = new."pedido_id"
       and "estado" in (
         'pagado'::public."estado_pedido",
         'en_preparacion'::public."estado_pedido"
       );
  end if;

  return new;
end;
$$;

create or replace function public.confirmar_recepcion_pedido(p_pedido_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cliente_id uuid;
  v_estado public."estado_pedido";
begin
  select "cliente_id", "estado"
    into v_cliente_id, v_estado
  from public."pedidos"
  where "id" = p_pedido_id
  for update;

  if v_cliente_id is null then
    raise exception 'Pedido inexistente';
  end if;

  if v_cliente_id <> (select auth.uid()) then
    raise exception 'Solo el cliente del pedido puede confirmar la recepcion';
  end if;

  if v_estado <> 'completado' then
    raise exception 'Solo se puede confirmar la recepcion de un pedido completado';
  end if;

  update public."pedidos"
     set "confirmado_cliente_en" = coalesce("confirmado_cliente_en", now())
   where "id" = p_pedido_id;

  return true;
end;
$$;

create or replace function public.proteger_campos_criticos_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
  v_operacion_interna boolean := current_setting('cutuco.operacion_interna', true) = 'true';
begin
  v_jwt := current_setting('request.jwt.claims', true);

  if v_jwt is not null and pg_trigger_depth() = 1 and current_user <> 'service_role' and not v_operacion_interna then
    if new."cliente_id" is distinct from old."cliente_id"
       or new."productor_id" is distinct from old."productor_id"
       or new."region_entrega_id" is distinct from old."region_entrega_id"
       or new."comuna_entrega_id" is distinct from old."comuna_entrega_id"
       or new."nombre_destinatario" is distinct from old."nombre_destinatario"
       or new."telefono_destinatario" is distinct from old."telefono_destinatario"
       or new."direccion_entrega" is distinct from old."direccion_entrega"
       or new."referencia_entrega" is distinct from old."referencia_entrega"
       or new."subtotal_productos" is distinct from old."subtotal_productos"
       or new."tarifa_delivery" is distinct from old."tarifa_delivery"
       or new."porcentaje_fee_plataforma" is distinct from old."porcentaje_fee_plataforma"
       or new."monto_fee_plataforma" is distinct from old."monto_fee_plataforma"
       or new."total" is distinct from old."total" then
      raise exception 'Los datos de identidad, snapshot y finanzas del pedido son inmutables desde la API directa';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.proteger_campos_operativos_productor()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
  v_es_admin boolean;
begin
  v_jwt := current_setting('request.jwt.claims', true);
  v_es_admin := (select private.es_admin_actual());

  -- Si no viene con JWT (seed, backend con service_role sin claims) se permite.
  if current_user in ('postgres', 'service_role') or v_es_admin then
    return new;
  end if;

  if new.rut_oficial is distinct from old.rut_oficial
     or new.codigo_comercio_mall is distinct from old.codigo_comercio_mall
     or new.perfil_id is distinct from old.perfil_id then
    raise exception 'Solo administracion/backend puede cambiar la identidad y el comercio del productor';
  end if;

  if new."activo" is distinct from old."activo" then
    raise exception 'Solo un administrador puede cambiar el estado activo del productor';
  end if;

  if new."puntaje_reputacion" is distinct from old."puntaje_reputacion"
     or new."cantidad_evaluaciones" is distinct from old."cantidad_evaluaciones" then
    raise exception 'La reputacion se calcula automaticamente y no puede modificarse manualmente';
  end if;

  return new;
end;
$$;
commit;
