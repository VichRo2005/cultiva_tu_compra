-- Servicio mensual de la plataforma para vendedores.
--
-- Reglas de negocio (MVP, documentadas en docs/servicio-plataforma.md):
--   * Cuota mensual fija: CLP $9.900.
--   * Cada cuota vence 10 días después de ser emitida.
--   * Se conceden 5 días de gracia; al día 16 sin pago se suspende la venta.
--   * Transferencia: si el número de operación tiene formato válido se valida
--     de inmediato; si no, queda pendiente de revisión del administrador.
--   * Webpay: se marca pagada sólo con el commit autorizado de Transbank.
--   * Una cuota pendiente en revisión no suspende; una rechazada o vencida sí.
--   * El pago/reactivación vuelve a habilitar la venta automáticamente.

begin;

-- ------------------------------------------------------------------
-- 1) Estado del servicio en el productor
-- ------------------------------------------------------------------
alter table public."productores"
  add column if not exists "servicio_suspendido" boolean not null default false,
  add column if not exists "servicio_suspendido_en" timestamptz;

create index if not exists "idx_productores_servicio_suspendido"
  on public."productores" ("servicio_suspendido")
  where "servicio_suspendido" = true;

-- ------------------------------------------------------------------
-- 2) Cuotas y pagos del servicio
-- ------------------------------------------------------------------
create table if not exists public."pagos_servicio" (
  "id" uuid primary key default gen_random_uuid(),
  "productor_id" uuid not null references public."productores"("id")
    on delete cascade on update cascade,
  "periodo" date not null,
  "monto" numeric(10,0) not null,
  "vence_en" date not null,
  "estado" text not null default 'pendiente',
  "metodo" text,
  "referencia" varchar(80),
  "observaciones" varchar(1000),
  "buy_order" varchar(40) unique,
  "token_ws" varchar(255) unique,
  "pagado_en" timestamptz,
  "revisado_por" uuid references public."perfiles"("id") on delete set null,
  "revisado_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_pago_servicio_monto" check ("monto" > 0),
  constraint "ck_pago_servicio_estado" check (
    "estado" in ('pendiente', 'pendiente_revision', 'pagado', 'rechazado')
  ),
  constraint "ck_pago_servicio_metodo" check (
    "metodo" is null or "metodo" in ('transferencia', 'webpay')
  ),
  constraint "uq_pago_servicio_periodo" unique ("productor_id", "periodo")
);

create index if not exists "idx_pagos_servicio_productor_periodo"
  on public."pagos_servicio" ("productor_id", "periodo" desc);

create index if not exists "idx_pagos_servicio_pendientes"
  on public."pagos_servicio" ("estado", "vence_en")
  where "estado" in ('pendiente', 'pendiente_revision', 'rechazado');

alter table public."pagos_servicio" enable row level security;

create policy "pagos_servicio_select_propio_admin"
  on public."pagos_servicio" for select to authenticated
  using (
    (select private.es_productor_actual("productor_id"))
    or (select private.es_admin_actual())
  );

revoke insert, update, delete on public."pagos_servicio" from anon, authenticated;
grant select on public."pagos_servicio" to authenticated;

-- Trigger de actualizado_en.
drop trigger if exists "trg_actualizado_en_pagos_servicio" on public."pagos_servicio";
create trigger "trg_actualizado_en_pagos_servicio"
  before update on public."pagos_servicio"
  for each row execute function public.actualizar_actualizado_en();

-- ------------------------------------------------------------------
-- 3) Emisión de cuotas
-- ------------------------------------------------------------------
create or replace function private.crear_cuota_servicio(p_productor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_periodo date := date_trunc('month', current_date)::date;
begin
  insert into public."pagos_servicio" (productor_id, periodo, monto, vence_en)
  values (p_productor_id, v_periodo, 9900, current_date + 10)
  on conflict (productor_id, periodo) do nothing;
end;
$$;

create or replace function public.crear_cuota_servicio_productor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.crear_cuota_servicio(new."id");
  return new;
end;
$$;

drop trigger if exists "trg_crear_cuota_servicio_productor" on public."productores";
create trigger "trg_crear_cuota_servicio_productor"
  after insert on public."productores"
  for each row execute function public.crear_cuota_servicio_productor();

-- ------------------------------------------------------------------
-- 4) Estado y suspensión
-- ------------------------------------------------------------------
create or replace function private.estado_servicio(p_productor_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (select 1 from public."productores" where id = p_productor_id) then 'sin_productor'
    when exists (
      select 1 from public."pagos_servicio"
      where productor_id = p_productor_id and estado = 'pendiente_revision'
    ) then 'pendiente_revision'
    when exists (
      select 1 from public."pagos_servicio"
      where productor_id = p_productor_id
        and estado in ('pendiente', 'rechazado')
        and vence_en + 5 < current_date
    ) then 'vencido'
    when exists (
      select 1 from public."pagos_servicio"
      where productor_id = p_productor_id and estado in ('pendiente', 'rechazado')
    ) then 'pendiente'
    else 'al_dia'
  end;
$$;

create or replace function private.sincronizar_morosidad_productor(p_productor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_suspendido boolean;
begin
  select exists (
    select 1 from public."pagos_servicio"
    where productor_id = p_productor_id
      and estado in ('pendiente', 'rechazado')
      and vence_en + 5 < current_date
  ) into v_suspendido;

  update public."productores"
     set servicio_suspendido = v_suspendido,
         servicio_suspendido_en = case
           when v_suspendido then coalesce(servicio_suspendido_en, now())
           else null
         end
   where id = p_productor_id;
end;
$$;

-- El vendedor no puede tocar su propio flag de suspensión por PostgREST.
create or replace function public.proteger_servicio_productor()
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
  if new."servicio_suspendido" is distinct from old."servicio_suspendido"
     or new."servicio_suspendido_en" is distinct from old."servicio_suspendido_en" then
    raise exception 'El estado del servicio solo puede cambiarlo el sistema';
  end if;
  return new;
end;
$$;

drop trigger if exists "trg_proteger_servicio_productor" on public."productores";
create trigger "trg_proteger_servicio_productor"
  before update on public."productores"
  for each row execute function public.proteger_servicio_productor();

-- ------------------------------------------------------------------
-- 5) Consulta del vendedor
-- ------------------------------------------------------------------
create or replace function public.mi_servicio()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_productor uuid;
begin
  select id into v_productor from public."productores" where perfil_id = auth.uid();
  if v_productor is null then
    return jsonb_build_object('estado', 'sin_productor');
  end if;

  perform private.crear_cuota_servicio(v_productor);
  perform private.sincronizar_morosidad_productor(v_productor);

  return jsonb_build_object(
    'productor_id', v_productor,
    'estado', private.estado_servicio(v_productor),
    'monto_mensual', 9900,
    'dias_vencimiento', 10,
    'dias_gracia', 5,
    'cuota', (
      select to_jsonb(c) from (
        select id, periodo, monto, vence_en, estado, metodo, referencia,
               pagado_en, observaciones
        from public."pagos_servicio"
        where productor_id = v_productor
        order by periodo desc
        limit 1
      ) c
    ),
    'historial', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.periodo desc)
      from (
        select id, periodo, monto, vence_en, estado, metodo, referencia,
               pagado_en, observaciones
        from public."pagos_servicio"
        where productor_id = v_productor
        order by periodo desc
        limit 24
      ) h
    ), '[]'::jsonb)
  );
end;
$$;

-- ------------------------------------------------------------------
-- 6) Transferencia del vendedor
-- ------------------------------------------------------------------
create or replace function public.registrar_transferencia_servicio(
  p_referencia text,
  p_observaciones text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_productor uuid;
  v_pago public."pagos_servicio"%rowtype;
  v_auto boolean;
  v_referencia text := btrim(coalesce(p_referencia, ''));
begin
  select id into v_productor from public."productores" where perfil_id = auth.uid();
  if v_productor is null then
    raise exception 'No tienes una tienda de productor activa';
  end if;

  perform private.crear_cuota_servicio(v_productor);
  select * into v_pago
    from public."pagos_servicio"
   where productor_id = v_productor
     and estado in ('pendiente', 'rechazado', 'pendiente_revision')
   order by periodo asc
   limit 1
   for update;
  if not found then
    raise exception 'No hay una cuota pendiente para pagar';
  end if;
  if v_pago.estado = 'pendiente_revision' then
    raise exception 'Tu transferencia ya está pendiente de revisión';
  end if;

  v_auto := v_referencia ~ '^[A-Za-z0-9-]{6,40}$';

  update public."pagos_servicio"
     set metodo = 'transferencia',
         referencia = nullif(v_referencia, ''),
         observaciones = nullif(btrim(coalesce(p_observaciones, '')), ''),
         estado = case when v_auto then 'pagado' else 'pendiente_revision' end,
         pagado_en = case when v_auto then now() else null end,
         revisado_por = null,
         revisado_en = null
   where id = v_pago.id;

  if v_auto then
    update public."productores"
       set servicio_suspendido = false, servicio_suspendido_en = null
     where id = v_productor;
  end if;
  perform private.sincronizar_morosidad_productor(v_productor);

  return jsonb_build_object(
    'pago_id', v_pago.id,
    'estado', case when v_auto then 'pagado' else 'pendiente_revision' end,
    'automatico', v_auto
  );
end;
$$;

-- ------------------------------------------------------------------
-- 7) Revisión administrativa
-- ------------------------------------------------------------------
create or replace function public.resolver_pago_servicio(
  p_pago_id uuid,
  p_estado text,
  p_observaciones text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pago public."pagos_servicio"%rowtype;
begin
  if not private.es_admin_actual() then
    raise exception 'Solo un administrador puede revisar pagos del servicio';
  end if;
  if p_estado not in ('pagado', 'rechazado') then
    raise exception 'Resolución inválida';
  end if;

  select * into v_pago from public."pagos_servicio" where id = p_pago_id for update;
  if not found then
    raise exception 'Pago de servicio inexistente';
  end if;
  if v_pago.estado <> 'pendiente_revision' then
    raise exception 'El pago ya fue revisado o no requiere revisión';
  end if;

  update public."pagos_servicio"
     set estado = p_estado,
         observaciones = nullif(btrim(coalesce(p_observaciones, '')), ''),
         revisado_por = auth.uid(),
         revisado_en = now(),
         pagado_en = case when p_estado = 'pagado' then now() else null end
   where id = p_pago_id;

  if p_estado = 'pagado' then
    update public."productores"
       set servicio_suspendido = false, servicio_suspendido_en = null
     where id = v_pago.productor_id;
  end if;
  perform private.sincronizar_morosidad_productor(v_pago.productor_id);

  return jsonb_build_object('pago_id', p_pago_id, 'estado', p_estado);
end;
$$;

-- ------------------------------------------------------------------
-- 8) Funciones administrativas de resumen y morosidad
-- ------------------------------------------------------------------
create or replace function public.actualizar_morosidad_servicio()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int := 0;
  v_id uuid;
begin
  if not private.es_admin_actual() then
    raise exception 'Solo un administrador puede actualizar la morosidad';
  end if;
  for v_id in select id from public."productores" loop
    perform private.sincronizar_morosidad_productor(v_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.admin_servicio_resumen()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not private.es_admin_actual() then
    raise exception 'Solo un administrador puede ver el resumen del servicio';
  end if;
  for v_id in select id from public."productores" loop
    perform private.crear_cuota_servicio(v_id);
    perform private.sincronizar_morosidad_productor(v_id);
  end loop;

  return coalesce((
    select jsonb_agg(row order by row->>'nombre_comercial')
    from (
      select jsonb_build_object(
        'productor_id', p.id,
        'nombre_comercial', p.nombre_comercial,
        'perfil_id', p.perfil_id,
        'estado', private.estado_servicio(p.id),
        'suspendido', p.servicio_suspendido,
        'cuota', (
          select to_jsonb(c) from (
            select id, periodo, monto, vence_en, estado, metodo, referencia,
                   pagado_en, observaciones
            from public."pagos_servicio"
            where productor_id = p.id
            order by periodo desc
            limit 1
          ) c
        )
      ) as row
      from public."productores" p
    ) s
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.mi_servicio() to authenticated;
grant execute on function public.registrar_transferencia_servicio(text, text) to authenticated;
grant execute on function public.resolver_pago_servicio(uuid, text, text) to authenticated;
grant execute on function public.actualizar_morosidad_servicio() to authenticated;
grant execute on function public.admin_servicio_resumen() to authenticated;
grant execute on function private.crear_cuota_servicio(uuid) to authenticated; -- vía RPC internas? no expuesta
revoke execute on function private.crear_cuota_servicio(uuid) from authenticated;

-- Las cuotas actuales se crean al abrir el panel o al ejecutar el resumen admin.
-- Suspensión inicial coherente para datos existentes.
do $$
declare
  v_id uuid;
begin
  for v_id in select id from public."productores" loop
    perform private.crear_cuota_servicio(v_id);
    perform private.sincronizar_morosidad_productor(v_id);
  end loop;
end $$;

commit;
