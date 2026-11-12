-- ============================================================
-- CuTuCo — Tablas y columnas heredadas para la GALERÍA DE DESARROLLO
-- ============================================================
-- Contexto:
--   La galería de desarrollo (`VITE_DEV_GALLERY`, carpeta `frontend/src/dev/`)
--   permite recorrer TODAS las ventanas creadas del producto, incluidas las que
--   salieron del alcance del ERS vigente, para revisarlas sin recorrer el flujo
--   completo.
--
--   La migración `20261004021917_nuevo_alcance.sql` retiró del esquema varias
--   entidades del prototipo anterior (cobertura por comuna, documentos de
--   identidad, historial de precios, alertas de stock y evidencias por envío) y
--   algunas columnas que consumían esas ventanas. Este archivo las vuelve a
--   declarar para que la galería pueda renderizarlas con datos.
--
-- IMPORTANTE:
--   * Nada de lo declarado aquí forma parte del alcance vigente del ERS:
--     RF-008 (historial de precios), RF-010 (alertas de stock), RF-013, RF-015
--     (retención del carnet), RF-016 y la cobertura por comuna están fuera.
--   * No se elimina ni se modifica ninguna definición de las migraciones
--     anteriores: sólo se agregan tablas y columnas nuevas.
--   * Todo está marcado con el comentario `HERRAMIENTA DE DESARROLLO` para que
--     se pueda retirar más adelante sin tocar el resto del esquema.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Cobertura por comuna del prototipo anterior (RF-009 v1)
--    El alcance vigente compara sólo regiones (productores.region_id).
-- ------------------------------------------------------------
create table if not exists public."coberturas_productor" (
  "id" uuid primary key default gen_random_uuid(),
  "productor_id" uuid not null references public."productores"("id") on delete cascade,
  "tipo_cobertura" varchar(20) not null default 'region',
  "region_id" uuid references public."regiones"("id") on delete cascade,
  "comuna_id" uuid references public."comunas"("id") on delete cascade,
  "activo" boolean not null default true,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_cobertura_tipo" check ("tipo_cobertura" in ('region', 'comuna')),
  constraint "ck_cobertura_destino" check (
    ("tipo_cobertura" = 'region' and "region_id" is not null and "comuna_id" is null)
    or ("tipo_cobertura" = 'comuna' and "comuna_id" is not null and "region_id" is null)
  )
);

comment on table public."coberturas_productor" is
  'HERRAMIENTA DE DESARROLLO: cobertura por comuna del prototipo anterior, usada sólo por la galería de vistas. Fuera del alcance del ERS vigente (RF-009 v2 compara regiones).';

create index if not exists "idx_coberturas_productor"
  on public."coberturas_productor" ("productor_id");

create index if not exists "idx_coberturas_region"
  on public."coberturas_productor" ("region_id");

-- ------------------------------------------------------------
-- 2. Documentos de identidad (RF-015, fuera del alcance)
-- ------------------------------------------------------------
create table if not exists public."documentos_identidad" (
  "id" uuid primary key default gen_random_uuid(),
  "postulacion_id" uuid references public."postulaciones_vendedores"("id") on delete cascade,
  "perfil_id" uuid references public."perfiles"("id") on delete cascade,
  "tipo" varchar(20) not null,
  "ruta_storage" varchar(500) not null,
  "nombre_archivo" varchar(255) not null,
  "mime_type" varchar(100) not null,
  "tamano_bytes" bigint not null default 0,
  "metadatos" jsonb not null default '{}'::jsonb,
  "subido_en" timestamptz not null default now(),
  "expira_en" timestamptz,
  "eliminado_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  constraint "ck_documento_tipo" check ("tipo" in ('frente', 'dorso'))
);

comment on table public."documentos_identidad" is
  'HERRAMIENTA DE DESARROLLO: documentos de identidad del prototipo anterior (RF-015). La galería los muestra; el flujo vigente de RF-021 no pide carnet.';

create index if not exists "idx_documentos_postulacion"
  on public."documentos_identidad" ("postulacion_id");

-- ------------------------------------------------------------
-- 3. Historial de precios (RF-008, fuera del alcance)
-- ------------------------------------------------------------
create table if not exists public."historial_precios" (
  "id" uuid primary key default gen_random_uuid(),
  "producto_id" uuid references public."productos"("id") on delete cascade,
  "region_id" uuid references public."regiones"("id") on delete cascade,
  "precio_anterior" numeric(12,2),
  "precio_nuevo" numeric(12,2) not null,
  "fuente" varchar(20) not null default 'marketplace',
  "referencia_externa" varchar(255),
  "registrado_en" timestamptz not null default now(),
  constraint "ck_historial_fuente" check ("fuente" in ('marketplace', 'referencia'))
);

comment on table public."historial_precios" is
  'HERRAMIENTA DE DESARROLLO: historial de precios del prototipo anterior (RF-008, fuera del alcance). La ventana /precios quedó como pantalla informativa y no consume esta tabla.';

create index if not exists "idx_historial_precio_producto"
  on public."historial_precios" ("producto_id", "registrado_en");

-- ------------------------------------------------------------
-- 4. Alertas de stock (RF-010, fuera del alcance) y umbral por producto
-- ------------------------------------------------------------
create table if not exists public."alertas_stock" (
  "id" uuid primary key default gen_random_uuid(),
  "producto_id" uuid not null references public."productos"("id") on delete cascade,
  "umbral_configurado" numeric(12,3) not null default 5,
  "stock_al_generar" numeric(12,3) not null default 0,
  "atendida_en" timestamptz,
  "notificada" boolean not null default false,
  "creado_en" timestamptz not null default now()
);

comment on table public."alertas_stock" is
  'HERRAMIENTA DE DESARROLLO: avisos de stock bajo del prototipo anterior (RF-010, fuera del alcance). El vendedor revisa su stock a mano en el flujo vigente.';

create index if not exists "idx_alertas_stock_producto"
  on public."alertas_stock" ("producto_id", "atendida_en");

-- Umbral por producto que consumía la ventana retirada de alertas.
alter table public."productos"
  add column if not exists "umbral_bajo" numeric(12,3) not null default 5;

comment on column public."productos"."umbral_bajo" is
  'HERRAMIENTA DE DESARROLLO: umbral de aviso de stock del prototipo anterior (RF-010, fuera del alcance).';

-- Marca de "cosecha del día" que usaba el catálogo anterior (RF-008/RF-010).
alter table public."productos"
  add column if not exists "es_cosecha_mismo_dia" boolean not null default false;

comment on column public."productos"."es_cosecha_mismo_dia" is
  'HERRAMIENTA DE DESARROLLO: sello "Cosecha del día" del prototipo anterior, fuera del alcance vigente.';

-- ------------------------------------------------------------
-- 5. Evidencias por envío (RF-007 versión anterior, fuera del alcance)
-- ------------------------------------------------------------
create table if not exists public."evidencias_envio" (
  "id" uuid primary key default gen_random_uuid(),
  "envio_id" uuid not null references public."envios"("id") on delete cascade,
  "tipo" varchar(20) not null,
  "ruta_storage" varchar(500) not null,
  "nombre_archivo" varchar(255) not null,
  "mime_type" varchar(100) not null,
  "tamano_bytes" bigint not null default 0,
  "metadatos" jsonb not null default '{}'::jsonb,
  "cargado_por" uuid references public."perfiles"("id") on delete set null,
  "creado_en" timestamptz not null default now(),
  constraint "ck_evidencia_tipo" check ("tipo" in ('armado', 'entregado'))
);

comment on table public."evidencias_envio" is
  'HERRAMIENTA DE DESARROLLO: evidencia fotográfica por pedido del prototipo anterior (RF-007 v1). El alcance vigente usa el código de verificación.';

create index if not exists "idx_evidencias_envio"
  on public."evidencias_envio" ("envio_id");

-- ------------------------------------------------------------
-- 6. Campos del score de reputación (RF-006 v1, fuera del alcance) y
--    trazabilidad automática de sanciones (RF-026 v1)
-- ------------------------------------------------------------
alter table public."evaluaciones_reputacion"
  add column if not exists "entrega_a_tiempo" smallint,
  add column if not exists "calidad" smallint,
  add column if not exists "respuesta_reclamos" smallint;

comment on column public."evaluaciones_reputacion"."entrega_a_tiempo" is
  'HERRAMIENTA DE DESARROLLO: criterio del score ponderado 40/40/20 (RF-006 v1). El alcance vigente sólo usa `puntaje` (1 a 5).';

alter table public."sanciones"
  add column if not exists "automatica" boolean not null default false,
  add column if not exists "puntaje_disparador" numeric(3,2);

comment on column public."sanciones"."automatica" is
  'HERRAMIENTA DE DESARROLLO: marca de sanción automática por score del prototipo anterior. El alcance vigente aplica sanciones manuales (RF-026 v2).';

-- ------------------------------------------------------------
-- 7. Columnas heredadas de solicitud y agenda
-- ------------------------------------------------------------
alter table public."postulaciones_vendedores"
  add column if not exists "comuna_origen_id" uuid references public."comunas"("id") on delete set null;

comment on column public."postulaciones_vendedores"."comuna_origen_id" is
  'HERRAMIENTA DE DESARROLLO: comuna declarada en la postulación del prototipo anterior. El flujo vigente usa la dirección activa.';

alter table public."perfiles"
  add column if not exists "comuna_principal_id" uuid references public."comunas"("id") on delete set null,
  add column if not exists "direccion_principal" varchar(255);

comment on column public."perfiles"."comuna_principal_id" is
  'HERRAMIENTA DE DESARROLLO: comuna principal del prototipo anterior. El flujo vigente usa `public.direcciones`.';

-- ------------------------------------------------------------
-- 8. Realtime para la galería: coberturas sin RLS restrictiva
-- ------------------------------------------------------------
alter table public."coberturas_productor" enable row level security;
alter table public."documentos_identidad" enable row level security;
alter table public."historial_precios" enable row level security;
alter table public."alertas_stock" enable row level security;
alter table public."evidencias_envio" enable row level security;

-- Lectura pública controlada de las coberturas (el catálogo anterior filtraba
-- por región/comuna) y del historial de precios (navegación invitado).
drop policy if exists "coberturas_select_publico" on public."coberturas_productor";
create policy "coberturas_select_publico"
  on public."coberturas_productor" for select to anon, authenticated
  using (true);

drop policy if exists "coberturas_write_dueno_admin" on public."coberturas_productor";
create policy "coberturas_write_dueno_admin"
  on public."coberturas_productor" for all to authenticated
  using (
    (select private.es_productor_propietario("productor_id"))
    or (select private.es_admin_actual())
  )
  with check (
    (select private.es_productor_propietario("productor_id"))
    or (select private.es_admin_actual())
  );

drop policy if exists "historial_precios_select_publico" on public."historial_precios";
create policy "historial_precios_select_publico"
  on public."historial_precios" for select to anon, authenticated
  using (true);

drop policy if exists "alertas_stock_dueno_admin" on public."alertas_stock";
create policy "alertas_stock_dueno_admin"
  on public."alertas_stock" for all to authenticated
  using (
    (select private.es_productor_actual_de_producto("producto_id"))
    or (select private.es_admin_actual())
  )
  with check (
    (select private.es_productor_actual_de_producto("producto_id"))
    or (select private.es_admin_actual())
  );

drop policy if exists "evidencias_envio_participantes" on public."evidencias_envio";
create policy "evidencias_envio_participantes"
  on public."evidencias_envio" for all to authenticated
  using ((select private.puede_acceder_envio("envio_id")))
  with check ((select private.puede_acceder_envio("envio_id")));

drop policy if exists "documentos_identidad_admin" on public."documentos_identidad";
create policy "documentos_identidad_admin"
  on public."documentos_identidad" for all to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

-- ============================================================
-- 9. Datos de ejemplo para la galería (HERRAMIENTA DE DESARROLLO)
-- ============================================================
-- NOTA: los datos de ejemplo de la galería viven en
-- `supabase/seeds/gallery_dev.sql`, que se carga después de `supabase/seed.sql`
-- (ver `[db.seed] sql_paths` en `supabase/config.toml`). Se mantienen fuera de
-- las migraciones para que la estructura y los datos se puedan revisar por
-- separado.
-- ============================================================
