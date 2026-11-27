-- Cuenta destinataria del cobro del servicio mensual.
--
-- La información se administra desde el panel de administración y sólo puede
-- verla un vendedor autenticado que necesita pagar su cuota (o un admin). No
-- se agrega a configuracion_logistica porque esa tabla se publica también a
-- visitantes anónimos para el checkout.
begin;

create table if not exists public.cuenta_transferencia_servicio (
  id smallint primary key default 1,
  banco varchar(120),
  tipo_cuenta varchar(80),
  numero_cuenta varchar(40),
  titular varchar(160),
  rut varchar(16),
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  constraint ck_cuenta_transferencia_servicio_unica check (id = 1),
  constraint ck_cuenta_transferencia_servicio_banco check (
    banco is null or length(btrim(banco)) between 1 and 120
  ),
  constraint ck_cuenta_transferencia_servicio_tipo check (
    tipo_cuenta is null or length(btrim(tipo_cuenta)) between 1 and 80
  ),
  constraint ck_cuenta_transferencia_servicio_numero check (
    numero_cuenta is null or length(btrim(numero_cuenta)) between 1 and 40
  ),
  constraint ck_cuenta_transferencia_servicio_titular check (
    titular is null or length(btrim(titular)) between 1 and 160
  ),
  constraint ck_cuenta_transferencia_servicio_rut check (
    rut is null or length(btrim(rut)) between 1 and 16
  )
);

insert into public.cuenta_transferencia_servicio (id)
values (1)
on conflict (id) do nothing;

create or replace function private.puede_ver_cuenta_transferencia_servicio()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select private.es_admin_actual())
    or exists (
      select 1
      from public.perfiles p
      where p.id = (select auth.uid())
        and p.rol = 'vendedor'::public.rol_usuario
        and p.activo = true
    );
$$;

grant execute on function private.puede_ver_cuenta_transferencia_servicio() to authenticated;

alter table public.cuenta_transferencia_servicio enable row level security;

create policy "cuenta_transferencia_servicio_select_vendedor_admin"
  on public.cuenta_transferencia_servicio for select to authenticated
  using ((select private.puede_ver_cuenta_transferencia_servicio()));

create policy "cuenta_transferencia_servicio_admin_update"
  on public.cuenta_transferencia_servicio for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

grant select, update on public.cuenta_transferencia_servicio to authenticated;

create trigger trg_actualizado_en_cuenta_transferencia_servicio
before update on public.cuenta_transferencia_servicio
for each row execute function public.actualizar_actualizado_en();

comment on table public.cuenta_transferencia_servicio is
  'Cuenta singleton de CuTuCo para recibir transferencias de la cuota mensual. La edita administración y la consultan sólo vendedores y administración.';

commit;
