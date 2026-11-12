-- Usuarios: suspensión reversible y eliminación permanente lógica.
-- No se borran perfiles, auth.users ni relaciones históricas.
begin;

alter table public.perfiles
  add column eliminado_en timestamptz,
  add column eliminado_por uuid references public.perfiles(id) on delete restrict,
  add constraint ck_perfil_eliminado_inactivo check (eliminado_en is null or not activo),
  add constraint ck_perfil_eliminacion_auditada check (
    (eliminado_en is null) = (eliminado_por is null)
  );

comment on column public.perfiles.eliminado_en is
  'Baja permanente lógica; fecha asignada por la BD, inmutable y sin reactivación.';
comment on column public.perfiles.eliminado_por is
  'Administrador autenticado que confirmó la baja permanente.';

create function private.validar_eliminacion_perfil()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.eliminado_en is not null or new.eliminado_por is not null then
      raise exception using errcode = '23514', message = 'Un perfil nuevo no puede tener una eliminacion registrada';
    end if;
    return new;
  end if;

  if old.eliminado_en is not null then
    if new.eliminado_en is distinct from old.eliminado_en
      or new.eliminado_por is distinct from old.eliminado_por or new.activo then
      raise exception using errcode = '23514', message = 'La eliminacion permanente no se puede revertir ni reactivar';
    end if;
    return new;
  end if;

  if new.eliminado_en is not null then
    if not (select private.es_admin_actual()) or (select auth.uid()) is null then
      raise exception using errcode = '42501', message = 'Solo un administrador autenticado puede eliminar una cuenta';
    end if;
    if old.es_protegido or old.es_super_admin or old.id = (select auth.uid()) then
      raise exception using errcode = '42501', message = 'No se puede eliminar una cuenta protegida ni la propia cuenta';
    end if;
    new.activo := false;
    new.eliminado_en := transaction_timestamp();
    new.eliminado_por := (select auth.uid());
  elsif new.eliminado_por is not null then
    raise exception using errcode = '23514', message = 'El administrador de eliminacion requiere una baja permanente';
  end if;
  return new;
end;
$$;

-- Orden alfabético: valida la eliminación antes de las protecciones existentes.
create trigger trg_00_validar_eliminacion_perfil
before insert or update on public.perfiles
for each row execute function private.validar_eliminacion_perfil();

create function private.sincronizar_estado_productor_perfil()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.productores
    set activo = new.activo
    where perfil_id = new.id and activo is distinct from new.activo;
  return new;
end;
$$;

create trigger trg_sincronizar_estado_productor_perfil
after update on public.perfiles
for each row
when (old.activo is distinct from new.activo or old.eliminado_en is distinct from new.eliminado_en)
execute function private.sincronizar_estado_productor_perfil();

-- Evita reactivar la tienda directamente, incluso mediante un JWT anterior
-- o el trigger de aprobación de postulaciones. Serializa con la baja del perfil.
create function private.validar_productor_perfil_eliminado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_eliminado_en timestamptz;
begin
  if new.activo then
    select eliminado_en into v_eliminado_en
      from public.perfiles where id = new.perfil_id for update;
    if v_eliminado_en is not null then
      raise exception using errcode = '23514', message = 'El productor de una cuenta eliminada no se puede reactivar';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_validar_productor_perfil_eliminado
before insert or update on public.productores
for each row execute function private.validar_productor_perfil_eliminado();

revoke all on function private.validar_eliminacion_perfil() from public, anon, authenticated;
revoke all on function private.sincronizar_estado_productor_perfil() from public, anon, authenticated;
revoke all on function private.validar_productor_perfil_eliminado() from public, anon, authenticated;
-- El panel administra bajas lógicas. La API autenticada no permite DELETE físico.
revoke delete on public.perfiles from authenticated;

commit;
