-- Preferencias de entrega efectivas para cada cuenta autenticada. Los valores
-- iniciales mantienen los canales activos para no silenciar cuentas existentes.
begin;

create table public.preferencias_notificacion (
  perfil_id uuid primary key references public.perfiles(id) on delete cascade,
  recibir_correo boolean not null default true,
  recibir_en_plataforma boolean not null default true,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

alter table public.preferencias_notificacion enable row level security;

create policy preferencias_notificacion_select_propias
  on public.preferencias_notificacion for select to authenticated
  using (perfil_id = (select auth.uid()));

create policy preferencias_notificacion_insert_propias
  on public.preferencias_notificacion for insert to authenticated
  with check (perfil_id = (select auth.uid()));

create policy preferencias_notificacion_update_propias
  on public.preferencias_notificacion for update to authenticated
  using (perfil_id = (select auth.uid()))
  with check (perfil_id = (select auth.uid()));

revoke all on public.preferencias_notificacion from public, anon;
grant select, insert, update on public.preferencias_notificacion to authenticated, service_role;

create trigger trg_actualizado_en_preferencias_notificacion
before update on public.preferencias_notificacion
for each row execute function public.actualizar_actualizado_en();

alter table public.pedidos
  add column if not exists correo_comprador_omitido_en timestamptz,
  add column if not exists correo_productor_omitido_en timestamptz;

alter table public.postulaciones_revisiones
  add column if not exists correo_resolucion_omitido_en timestamptz;

comment on table public.preferencias_notificacion is
  'Canales elegidos por cada cuenta para correos operativos y alertas dentro de CuTuCo.';
comment on column public.pedidos.correo_comprador_omitido_en is
  'Instante en que se omitió el correo de compra por preferencia del comprador.';
comment on column public.pedidos.correo_productor_omitido_en is
  'Instante en que se omitió el correo de nuevo pedido por preferencia del productor.';
comment on column public.postulaciones_revisiones.correo_resolucion_omitido_en is
  'Instante en que se omitió el correo de resolución por preferencia del postulante.';

commit;
