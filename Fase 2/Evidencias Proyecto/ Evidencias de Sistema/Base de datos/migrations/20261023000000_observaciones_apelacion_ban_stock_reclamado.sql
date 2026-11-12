-- Correcciones de postulaciones (§6.3) y sanciones/pedidos (P1, P3).
--
-- a) Observaciones del administrador: minimo 10 y maximo 2500 caracteres.
--    La columna ya es varchar(2500); el minimo sigue la regla de la casa
--    usada por motivo_pausa/motivo_eliminacion (10..1000). Se valida en la
--    RPC y se respalda con CHECK en ambas tablas para cualquier camino.
-- b) P1: una apelacion APROBADA de un ban permanente debe reactivar la
--    cuenta del vendedor (perfil + productor); antes quedaba bloqueada sin
--    ruta funcional porque reactivar_cuenta_permanente exige estado 'activa'.
-- c) P3: cancelar un pedido desde 'reclamado' repone el inventario (la venta
--    ya desconto el stock al pasar por 'pagado').

begin;

-- a) §6.3: límites de observaciones_admin.
alter table public.postulaciones_vendedores
  add constraint ck_postulacion_observaciones_largo
  check (observaciones_admin is null
    or char_length(btrim(observaciones_admin)) between 10 and 2500);
alter table public.postulaciones_revisiones
  add constraint ck_revision_observaciones_largo
  check (observaciones_admin is null
    or char_length(btrim(observaciones_admin)) between 10 and 2500);

create or replace function public.resolver_postulacion_vendedor(
  p_postulacion_id uuid, p_estado public.estado_postulacion_vendedor,
  p_observaciones text default null, p_codigo_comercio_mall text default null
) returns public.postulaciones_vendedores
language plpgsql security definer set search_path = '' as $$
declare v_resultado public.postulaciones_vendedores;
begin
  if auth.uid() is null or not private.es_admin_actual() then
    raise exception using errcode = '42501', message = 'Solo un administrador puede resolver postulaciones';
  end if;
  if p_estado is null or p_estado not in ('aprobada', 'rechazada') then
    raise exception 'La resolucion debe ser aprobada o rechazada';
  end if;
  if p_estado = 'rechazada' and nullif(btrim(p_observaciones), '') is null then
    raise exception 'El rechazo requiere observaciones para el solicitante';
  end if;
  if p_estado = 'aprobada' and nullif(btrim(p_codigo_comercio_mall), '') is null then
    raise exception 'La aprobacion requiere el codigo de comercio Mall de Transbank';
  end if;
  if nullif(btrim(p_observaciones), '') is not null
    and char_length(btrim(p_observaciones)) < 10 then
    raise exception 'Las observaciones deben tener entre 10 y 2500 caracteres';
  end if;
  if char_length(coalesce(p_observaciones, '')) > 2500 then
    raise exception 'Las observaciones no pueden exceder 2500 caracteres';
  end if;
  update public.postulaciones_vendedores
    set estado = p_estado, observaciones_admin = p_observaciones,
        codigo_comercio_mall = nullif(btrim(p_codigo_comercio_mall), '')
    where id = p_postulacion_id and estado = 'en_revision' returning * into v_resultado;
  if not found then raise exception 'No existe una postulacion en revision con ese ID'; end if;
  return v_resultado;
end;
$$;
revoke all on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text, text) from public, anon;
grant execute on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text, text) to authenticated, service_role;

-- b) P1: apelación aprobada de ban permanente reactiva la cuenta.
create or replace function public.sincronizar_apelacion_sancion_al_resolver()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_accion public.accion_sancion;
  v_productor uuid;
begin
  if new."estado" <> old."estado" then
    perform set_config('cutuco.sancion_sync', 'true', true);

    if new."estado" = 'aprobada' then
      -- Apelación aceptada: sanción resuelta según regla confirmada.
      select s."accion", s."productor_id" into v_accion, v_productor
        from public."sanciones" s where s."id" = new."sancion_id";
      update public."sanciones"
         set "estado" = 'resuelta'::public."estado_sancion",
             "resuelta_en" = coalesce("resuelta_en", now())
       where "id" = new."sancion_id";
      -- Un ban permanente aceptado en apelación vuelve a activar la cuenta:
      -- sin esto el vendedor quedaba bloqueado sin ruta de reactivación.
      if v_accion = 'ban_permanente' and not exists (
        select 1 from public."sanciones" s2
        where s2."productor_id" = v_productor and s2."id" <> new."sancion_id"
          and s2."estado" in ('activa'::public."estado_sancion", 'apelada'::public."estado_sancion")
      ) then
        update public."perfiles" p
           set "activo" = true
          from public."productores" pr
         where pr."id" = v_productor and p."id" = pr."perfil_id"
           and p."eliminado_en" is null;
        update public."productores" set "activo" = true where "id" = v_productor;
      end if;
    elsif new."estado" = 'rechazada' then
      -- Apelación rechazada: la sanción vuelve a estar activa
      update public."sanciones"
         set "estado" = 'activa'::public."estado_sancion"
       where "id" = new."sancion_id"
         and "estado" = 'apelada'::public."estado_sancion";
    end if;
  end if;

  return new;
end;
$$;

-- c) P3: cancelar desde 'reclamado' repone el inventario descontado.
-- Reescritura de validar_transicion_pedido (vigente en
-- 20261010010000_webpay_mall_postulaciones.sql:152-240) agregando
-- 'reclamado' a los estados que reponen stock al cancelar.
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
    -- Solo se repone stock si el pedido ya lo habia descontado (pagado,
    -- en_preparacion o reclamado: todos pasaron por 'pagado') y no se ha
    -- repuesto antes.
    if old."estado" in ('pagado', 'en_preparacion', 'reclamado')
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

commit;
