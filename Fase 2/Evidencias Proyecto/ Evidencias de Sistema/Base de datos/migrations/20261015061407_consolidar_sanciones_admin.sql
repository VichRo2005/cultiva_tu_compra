-- Reglas confirmadas: aprobación resuelve; rechazo conserva reactivación de la sanción.
-- No se modifica auth.users. Los efectos de cuenta permanecen en la BD.
begin;
create or replace function public.sincronizar_apelacion_sancion_al_resolver()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new."estado" <> old."estado" then
    perform set_config('cutuco.sancion_sync', 'true', true);

    if new."estado" = 'aprobada' then
      -- Apelación aceptada: sanción resuelta según regla confirmada.
      update public."sanciones"
         set "estado" = 'resuelta'::public."estado_sancion",
             "resuelta_en" = coalesce("resuelta_en", now())
       where "id" = new."sancion_id";
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
create or replace function public.aplicar_efecto_sancion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_otra_suspension boolean;
begin
  if new."estado" = 'activa' and new."accion" in ('suspender', 'ban_permanente') then
    update public."productores"
       set "activo" = false
     where "id" = new."productor_id";

    if new."accion" = 'ban_permanente' then
      update public."perfiles" p
         set "activo" = false
       from public."productores" pr
       where pr."id" = new."productor_id"
         and p."id" = pr."perfil_id";
    end if;

  elsif new."estado" in ('resuelta', 'cancelada', 'expirada')
        and new."accion" <> 'ban_permanente' then
    -- Revisar TODAS las sanciones vigentes (activa o apelada), no solo activa
    select exists (
      select 1
      from public."sanciones" s
      where s."productor_id" = new."productor_id"
        and s."id" <> new."id"
        and s."estado" in ('activa'::public."estado_sancion", 'apelada'::public."estado_sancion")
    ) into v_otra_suspension;

    if not v_otra_suspension then
      update public."productores"
         set "activo" = true
       where "id" = new."productor_id"
       and exists (select 1 from public.perfiles p
                   where p.id = public.productores.perfil_id and p.activo and p.eliminado_en is null);
    end if;
  end if;

  return new;
end;
$$;

-- Serializa por productor y evita bans duplicados incluso desde dos sesiones.
create function public.validar_ban_admin()
returns trigger language plpgsql set search_path = '' as $$
begin
  perform 1 from public.productores where id = new.productor_id for update;
  if new.accion = 'ban_permanente' and new.estado in ('activa', 'apelada') and exists (
    select 1 from public.sanciones s where s.productor_id = new.productor_id
    and s.id <> new.id and s.accion = 'ban_permanente' and s.estado in ('activa', 'apelada')
  ) then
    raise exception 'El usuario ya tiene un ban permanente activo';
  end if;
  return new;
end;
$$;
create trigger trg_validar_ban_admin before insert or update on public.sanciones
for each row execute function public.validar_ban_admin();
revoke all on function public.validar_ban_admin() from public, anon, authenticated;

-- Operación indivisible: una excepción revierte las tres actualizaciones.
create function public.reactivar_cuenta_permanente(p_sancion_id uuid)
returns public.sanciones language plpgsql security invoker set search_path = '' as $$
declare
  v_sancion public.sanciones;
  v_perfil_id uuid;
begin
  if not (select private.es_admin_actual()) then
    raise exception 'Solo un administrador puede reactivar la cuenta';
  end if;
  select * into strict v_sancion from public.sanciones where id = p_sancion_id;
  select perfil_id into strict v_perfil_id from public.productores
    where id = v_sancion.productor_id for update;
  select * into strict v_sancion from public.sanciones where id = p_sancion_id for update;
  if v_sancion.accion <> 'ban_permanente' or v_sancion.estado <> 'activa' then
    raise exception 'La sancion no es un ban permanente activo';
  end if;
  if exists (select 1 from public.sanciones where productor_id = v_sancion.productor_id
    and id <> p_sancion_id and estado in ('activa', 'apelada')) then
    raise exception 'El usuario tiene otras sanciones vigentes';
  end if;
  update public.perfiles set activo = true where id = v_perfil_id;
  update public.productores set activo = true where id = v_sancion.productor_id;
  update public.sanciones set estado = 'resuelta', resuelta_en = now()
    where id = p_sancion_id returning * into v_sancion;
  return v_sancion;
end;
$$;
revoke all on function public.reactivar_cuenta_permanente(uuid) from public, anon;
grant execute on function public.reactivar_cuenta_permanente(uuid) to authenticated;
comment on table public.apelaciones is
'Apelacion del vendedor: pendiente cambia sancion a apelada; aprobada a resuelta; rechazada a activa.';
commit;
