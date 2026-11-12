-- Lote 15 (Moderación y sanciones):
--   CK-0401: el motivo de la sanción se valida también en servidor/BD
--            (no vacío ni solo espacios, tope 2500) y se normaliza con btrim.
--   CK-0215: private.expirar_suspensiones_vencidas() marca 'expirada' las
--            suspensiones activas cuyo fin_en ya pasó; el trigger
--            trg_aplicar_efecto_sancion (AFTER UPDATE of estado) reactiva al
--            productor cuando no quedan otras suspensiones vigentes.
-- El seed sólo inserta motivos válidos, así la restricción valida sin fallar.
begin;

alter table public.sanciones
  drop constraint if exists ck_sancion_motivo_no_vacio,
  add constraint ck_sancion_motivo_no_vacio
    check (char_length(btrim(motivo, E' \t\n\r')) between 1 and 2500);

create or replace function public.normalizar_sancion_manual()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- CK-0401: motivo obligatorio y no solo espacios/whitespace, también en servidor.
  new.motivo := btrim(coalesce(new.motivo, ''), E' \t\n\r');
  if new.motivo = '' then
    raise exception 'La sancion requiere un motivo no vacio';
  end if;

  -- Bypass interno: lo usan los triggers de sincronización de apelaciones.
  if current_setting('cutuco.sancion_sync', true) = 'true' then
    return new;
  end if;

  if not (select private.es_admin_actual()) then
    raise exception 'Solo un administrador puede crear o modificar una sancion';
  end if;

  perform 1
  from public."productores"
  where "id" = new."productor_id"
  for update;

  if not found then
    raise exception 'Productor inexistente para sancion';
  end if;

  if new."tipo" = 'amonestacion' then
    if new."accion" <> 'ninguna' then
      raise exception 'Una amonestacion usa accion ninguna';
    end if;

    select count(*) + 1
      into v_count
    from public."sanciones" s
    where s."productor_id" = new."productor_id"
      and s."tipo" = 'amonestacion'
      and s."id" <> new."id";

    new."numero_amonestacion" := v_count;
    new."duracion_dias" := null;
    new."fin_en" := null;
  elsif new."accion" = 'suspender' then
    if new."duracion_dias" is null or new."duracion_dias" <= 0 then
      raise exception 'Una suspension requiere una duracion positiva';
    end if;

    new."fin_en" := coalesce(new."fin_en", new."inicio_en" + make_interval(days => new."duracion_dias"));
    new."numero_amonestacion" := null;
  elsif new."accion" = 'ban_permanente' then
    new."fin_en" := null;
    new."numero_amonestacion" := null;
    new."duracion_dias" := null;
  end if;

  if new."impuesta_por" is null then
    new."impuesta_por" := (select auth.uid());
  end if;

  return new;
end;
$$;

-- CK-0215: expira suspensiones vencidas. Lo invoca el backend (service_role)
-- al leer/escribir sanciones; el efecto de reactivación lo aplica el trigger.
create or replace function private.expirar_suspensiones_vencidas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expiradas integer;
begin
  update public.sanciones
     set estado = 'expirada'
   where estado = 'activa'
     and accion = 'suspender'
     and fin_en is not null
     and fin_en <= now();
  get diagnostics v_expiradas = row_count;
  return v_expiradas;
end;
$$;

revoke all on function private.expirar_suspensiones_vencidas() from public, anon, authenticated;
grant execute on function private.expirar_suspensiones_vencidas() to service_role;

commit;
