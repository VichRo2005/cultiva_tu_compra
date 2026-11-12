-- HAL-CLI-010, HAL-VEN-018, HAL-VEN-028 y HAL-VEN-029.
--
-- * El pago crea el envío en 'preparacion' pero deja el pedido en 'pagado' y
--   preparado_en en NULL. La preparación se registra con una acción real del
--   vendedor (RPC marcar_pedido_en_preparacion).
-- * El cliente recibe el código y se lo entrega al vendedor. El vendedor ya no
--   puede leer codigo_verificacion: se revoca el SELECT de esa columna y el
--   cliente/admin la obtienen por RPC. El vendedor la confirma con
--   verificar_codigo_entrega_vendedor (idempotente).
-- * La cancelación del vendedor es una RPC con motivo obligatorio (1..1000) y
--   propaga 'cancelado' (no 'fallido') a pedido y envío.
-- * La justificación de entrega fallida se limita a 1000 caracteres con
--   mensaje funcional en español.

begin;

-- ------------------------------------------------------------------
-- 1) Columnas nuevas
-- ------------------------------------------------------------------
alter table public."pedidos"
  add column if not exists "motivo_cancelacion" text,
  add column if not exists "cancelado_por" uuid references public."perfiles"("id") on delete set null;

alter table public."envios"
  add column if not exists "preparado_en" timestamptz,
  add column if not exists "cancelado_en" timestamptz,
  add column if not exists "motivo_cancelacion" text;

-- Texto con CHECK de longitud: así el trigger puede responder en español antes
-- del error técnico de "value too long for type character varying" (HAL-VEN-028
-- y HAL-VEN-029).
alter table public."pedidos"
  alter column "motivo_cancelacion" type text;
alter table public."envios"
  alter column "motivo_fallo" type text,
  alter column "motivo_cancelacion" type text;

comment on column public."envios"."preparado_en" is
  'HAL-CLI-010: fecha real en que el vendedor marcó el pedido en preparación. NULL hasta esa acción.';
comment on column public."envios"."motivo_cancelacion" is
  'HAL-VEN-029: justificación de cancelación del vendedor, distinta de motivo_fallo.';
comment on column public."pedidos"."motivo_cancelacion" is
  'HAL-VEN-029: motivo de cancelación visible para cliente y vendedor.';
comment on column public."pedidos"."cancelado_por" is
  'Perfil que canceló el pedido (normalmente el vendedor; administración también puede).';

alter table public."pedidos"
  add constraint "ck_pedido_cancelacion_largo" check (
    "motivo_cancelacion" is null or char_length(btrim("motivo_cancelacion")) between 1 and 1000
  );

alter table public."envios"
  add constraint "ck_envio_cancelacion_coherente" check (
    "estado" <> 'cancelado'::public."estado_envio"
    or (
      "cancelado_en" is not null
      and "motivo_cancelacion" is not null
      and char_length(btrim("motivo_cancelacion")) between 1 and 1000
    )
  ),
  add constraint "ck_envio_fallo_motivo_largo" check (
    "motivo_fallo" is null or char_length("motivo_fallo") <= 1000
  );

-- ------------------------------------------------------------------
-- 2) El pago no genera preparación automática
-- ------------------------------------------------------------------
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
      "pedido_id", "repartidor_id", "estado", "tarifa_fija", "preparado_en"
    ) values (
      new."id",
      v_repartidor_id,
      'preparacion'::public."estado_envio",
      new."tarifa_delivery",
      null
    )
    on conflict ("pedido_id") do nothing;

    -- HAL-CLI-010: el pedido permanece 'pagado'. La transición a
    -- 'en_preparacion' la ejecuta el vendedor con marcar_pedido_en_preparacion.
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------------
-- 3) Máquina de estados del envío (incluye cancelado)
-- ------------------------------------------------------------------
create or replace function public.validar_transicion_envio()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_perfil_productor uuid;
  v_operacion_interna boolean :=
    coalesce(current_setting('cutuco.operacion_interna', true), 'false') = 'true';
begin
  if new."repartidor_id" is distinct from old."repartidor_id" then
    raise exception 'El repartidor de un envio no puede cambiar en el MVP';
  end if;

  select pr."perfil_id"
    into v_perfil_productor
  from public."pedidos" p
  join public."productores" pr on pr."id" = p."productor_id"
  where p."id" = new."pedido_id";

  if v_perfil_productor is null or new."repartidor_id" <> v_perfil_productor then
    raise exception 'En el MVP el repartidor del envio debe ser el productor del pedido';
  end if;

  if new."estado" = old."estado" then
    return new;
  end if;

  if not (
    (old."estado" = 'preparacion' and new."estado" in ('en_transito', 'fallido', 'cancelado'))
    or (old."estado" = 'en_transito' and new."estado" in ('entregado', 'fallido', 'cancelado'))
  ) then
    raise exception 'Transicion de envio no permitida: % -> %', old."estado", new."estado";
  end if;

  if new."estado" = 'cancelado' then
    if not v_operacion_interna then
      raise exception 'La cancelacion del envio solo puede realizarse mediante la RPC autorizada';
    end if;
    new."motivo_cancelacion" := btrim(coalesce(new."motivo_cancelacion", ''));
    if char_length(new."motivo_cancelacion") not between 1 and 1000 then
      raise exception 'La justificacion de cancelacion debe tener entre 1 y 1000 caracteres';
    end if;
    new."cancelado_en" := coalesce(new."cancelado_en", now());
    new."motivo_fallo" := null;
    new."fallido_en" := null;
  end if;

  if new."estado" = 'en_transito' and old."estado" = 'preparacion' then
    new."codigo_verificacion" := public.generar_codigo_verificacion();
    new."codigo_verificado_en" := null;
    new."despachado_en" := coalesce(new."despachado_en", now());
    new."preparado_en" := coalesce(new."preparado_en", now());
    new."motivo_fallo" := null;
    new."fallido_en" := null;
  end if;

  if new."estado" = 'fallido' and old."estado" is distinct from 'fallido' then
    new."motivo_fallo" := btrim(coalesce(new."motivo_fallo", ''));
    if char_length(new."motivo_fallo") not between 1 and 1000 then
      raise exception 'La justificacion de la entrega fallida debe tener entre 1 y 1000 caracteres';
    end if;
    new."fallido_en" := coalesce(new."fallido_en", now());
  end if;

  if new."estado" = 'entregado' and old."estado" = 'en_transito' then
    if new."codigo_verificado_en" is null then
      raise exception 'El codigo de entrega debe verificarse antes de marcar el envio como entregado';
    end if;
    new."entregado_en" := coalesce(new."entregado_en", now());
    new."motivo_fallo" := null;
    new."fallido_en" := null;
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------------
-- 4) Código de entrega: el cliente lo recibe, el vendedor lo confirma
-- ------------------------------------------------------------------
create or replace function public.obtener_codigo_entrega(p_envio_id uuid)
returns varchar(12)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_codigo varchar(12);
  v_cliente uuid;
begin
  select e."codigo_verificacion", p."cliente_id"
    into v_codigo, v_cliente
  from public."envios" e
  join public."pedidos" p on p."id" = e."pedido_id"
  where e."id" = p_envio_id;

  if not found then
    raise exception 'Envio inexistente';
  end if;
  if v_cliente <> (select auth.uid()) and not (select private.es_admin_actual()) then
    raise exception using
      errcode = '42501',
      message = 'Solo el cliente del pedido puede ver el codigo de entrega';
  end if;
  return v_codigo;
end;
$$;

create or replace function public.verificar_codigo_entrega_vendedor(
  p_envio_id uuid,
  p_codigo text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_codigo varchar(12);
  v_estado public."estado_envio";
  v_verificado timestamptz;
  v_productor uuid;
begin
  select e."codigo_verificacion", e."estado", e."codigo_verificado_en", p."productor_id"
    into v_codigo, v_estado, v_verificado, v_productor
  from public."envios" e
  join public."pedidos" p on p."id" = e."pedido_id"
  where e."id" = p_envio_id
  for update of e;

  if not found then
    raise exception 'Envio inexistente';
  end if;

  if not exists (
    select 1 from public."productores" pr
    where pr."id" = v_productor and pr."perfil_id" = (select auth.uid())
  ) then
    raise exception using
      errcode = '42501',
      message = 'Solo el vendedor del pedido puede confirmar la entrega';
  end if;

  -- Idempotente: si ya se verificó, repetir la confirmación no cambia nada.
  if v_verificado is not null then
    return true;
  end if;

  if v_estado <> 'en_transito' then
    raise exception 'El codigo solo puede verificarse durante el estado en_transito';
  end if;

  -- Mensaje genérico para no filtrar el código ni permitir enumeración.
  if v_codigo is null
     or upper(btrim(coalesce(p_codigo, ''))) is distinct from v_codigo then
    raise exception 'Codigo de entrega invalido';
  end if;

  perform set_config('cutuco.operacion_interna', 'true', true);
  update public."envios"
     set "codigo_verificado_en" = coalesce("codigo_verificado_en", now())
   where "id" = p_envio_id;

  return true;
end;
$$;

-- Compatibilidad de nombre: el único rol autorizado es el vendedor. Un cliente
-- que llame a la función histórica recibe un mensaje funcional, no un bypass.
create or replace function public.verificar_codigo_entrega(
  p_envio_id uuid,
  p_codigo text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  return public.verificar_codigo_entrega_vendedor(p_envio_id, p_codigo);
end;
$$;

-- ------------------------------------------------------------------
-- 5) Acción real del vendedor: marcar preparación
-- ------------------------------------------------------------------
create or replace function public.marcar_pedido_en_preparacion(p_pedido_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pedido public."pedidos"%rowtype;
  v_preparado timestamp with time zone;
begin
  select * into v_pedido from public."pedidos" where "id" = p_pedido_id for update;
  if not found then
    raise exception 'Pedido inexistente';
  end if;

  if not exists (
    select 1 from public."productores" pr
    where pr."id" = v_pedido."productor_id" and pr."perfil_id" = (select auth.uid())
  ) then
    raise exception using
      errcode = '42501',
      message = 'Solo el vendedor del pedido puede marcar la preparacion';
  end if;

  if v_pedido."estado" not in ('pagado', 'en_preparacion') then
    raise exception 'Solo se puede marcar en preparacion un pedido pagado';
  end if;

  perform set_config('cutuco.operacion_interna', 'true', true);

  if v_pedido."estado" = 'pagado' then
    update public."pedidos"
       set "estado" = 'en_preparacion'::public."estado_pedido"
     where "id" = p_pedido_id;
  end if;

  update public."envios"
     set "preparado_en" = coalesce("preparado_en", now())
   where "pedido_id" = p_pedido_id;

  select "preparado_en" into v_preparado
  from public."envios" where "pedido_id" = p_pedido_id;

  return jsonb_build_object(
    'ok', true,
    'pedido_id', p_pedido_id,
    'estado', 'en_preparacion',
    'preparado_en', v_preparado
  );
end;
$$;

-- ------------------------------------------------------------------
-- 6) Cancelación del vendedor: pedido + envío con motivo
-- ------------------------------------------------------------------
create or replace function public.cancelar_pedido_vendedor(
  p_pedido_id uuid,
  p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pedido public."pedidos"%rowtype;
  v_motivo text := btrim(coalesce(p_motivo, ''));
  v_envio public."envios"%rowtype;
begin
  select * into v_pedido from public."pedidos" where "id" = p_pedido_id for update;
  if not found then
    raise exception 'Pedido inexistente';
  end if;

  if not exists (
    select 1 from public."productores" pr
    where pr."id" = v_pedido."productor_id" and pr."perfil_id" = (select auth.uid())
  ) then
    raise exception using
      errcode = '42501',
      message = 'Solo el vendedor del pedido puede cancelarlo';
  end if;

  if char_length(v_motivo) not between 1 and 1000 then
    raise exception 'La justificacion de cancelacion debe tener entre 1 y 1000 caracteres';
  end if;

  -- Idempotente: una segunda llamada devuelve el estado final sin duplicar
  -- eventos ni volver a reponer stock.
  if v_pedido."estado" = 'cancelado' then
    return jsonb_build_object(
      'ok', true,
      'pedido_id', p_pedido_id,
      'estado', 'cancelado',
      'motivo_cancelacion', v_pedido."motivo_cancelacion",
      'ya_cancelado', true
    );
  end if;

  if v_pedido."estado" not in ('creado', 'pagado', 'en_preparacion', 'reclamado') then
    raise exception 'No se puede cancelar un pedido en estado %', v_pedido."estado";
  end if;

  perform set_config('cutuco.operacion_interna', 'true', true);

  update public."pedidos"
     set "estado" = 'cancelado'::public."estado_pedido",
         "motivo_cancelacion" = v_motivo,
         "cancelado_por" = (select auth.uid())
   where "id" = p_pedido_id;

  select * into v_envio from public."envios" where "pedido_id" = p_pedido_id;
  if found and v_envio."estado" in ('preparacion', 'en_transito') then
    update public."envios"
       set "estado" = 'cancelado'::public."estado_envio",
           "cancelado_en" = coalesce("cancelado_en", now()),
           "motivo_cancelacion" = v_motivo
     where "id" = v_envio."id";
  end if;

  return jsonb_build_object(
    'ok', true,
    'pedido_id', p_pedido_id,
    'estado', 'cancelado',
    'motivo_cancelacion', v_motivo,
    'ya_cancelado', false
  );
end;
$$;

-- ------------------------------------------------------------------
-- 7) El vendedor no puede leer codigo_verificacion
-- ------------------------------------------------------------------
revoke select on public."envios" from authenticated;
grant select (
  "id", "pedido_id", "repartidor_id", "estado", "tarifa_fija",
  "codigo_verificado_en", "despachado_en", "entregado_en", "fallido_en",
  "motivo_fallo", "creado_en", "actualizado_en", "preparado_en",
  "cancelado_en", "motivo_cancelacion"
) on public."envios" to authenticated;

create or replace view public."envios_sin_codigo"
with (security_invoker = true)
as
select
  "id", "pedido_id", "repartidor_id", "estado", "tarifa_fija",
  "codigo_verificado_en", "despachado_en", "entregado_en", "fallido_en",
  "motivo_fallo", "creado_en", "actualizado_en", "preparado_en",
  "cancelado_en", "motivo_cancelacion"
from public."envios";

comment on view public."envios_sin_codigo" is
  'HAL-VEN-018: envíos sin codigo_verificacion. Respeta RLS y permisos del invocante; el cliente/admin obtienen el código con obtener_codigo_entrega.';

revoke all on public."envios_sin_codigo" from public, anon, authenticated;
grant select on public."envios_sin_codigo" to authenticated, service_role;

-- ------------------------------------------------------------------
-- 8) Permisos de las RPC
-- ------------------------------------------------------------------
revoke all on function public.obtener_codigo_entrega(uuid) from public, anon;
revoke all on function public.verificar_codigo_entrega_vendedor(uuid, text) from public, anon;
revoke all on function public.verificar_codigo_entrega(uuid, text) from public, anon;
revoke all on function public.marcar_pedido_en_preparacion(uuid) from public, anon;
revoke all on function public.cancelar_pedido_vendedor(uuid, text) from public, anon;

grant execute on function public.obtener_codigo_entrega(uuid) to authenticated;
grant execute on function public.verificar_codigo_entrega_vendedor(uuid, text) to authenticated;
grant execute on function public.verificar_codigo_entrega(uuid, text) to authenticated;
grant execute on function public.marcar_pedido_en_preparacion(uuid) to authenticated;
grant execute on function public.cancelar_pedido_vendedor(uuid, text) to authenticated;
grant execute on function public.obtener_codigo_entrega(uuid) to service_role;
grant execute on function public.verificar_codigo_entrega_vendedor(uuid, text) to service_role;
grant execute on function public.marcar_pedido_en_preparacion(uuid) to service_role;
grant execute on function public.cancelar_pedido_vendedor(uuid, text) to service_role;

commit;
