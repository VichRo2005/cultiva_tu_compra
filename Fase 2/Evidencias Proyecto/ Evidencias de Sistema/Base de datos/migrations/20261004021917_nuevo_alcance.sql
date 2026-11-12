-- ============================================================
-- CuTuCo - DDL completo del nuevo alcance
-- PostgreSQL 16 / Supabase
-- Migracion limpia para supabase/migrations/
-- ============================================================

create extension if not exists pgcrypto;
create schema if not exists private;

-- ============================================================
-- SECCION 1: TIPOS ENUM
-- ============================================================

create type public."rol_usuario" as enum (
  'cliente',
  'vendedor',
  'admin'
);

create type public."estado_postulacion_vendedor" as enum (
  'pendiente_aprobacion',
  'aprobada',
  'rechazada'
);

create type public."unidad_medida_producto" as enum (
  'kg',
  'g',
  'unidad',
  'bandeja',
  'caja',
  'litro',
  'ml',
  'docena'
);

create type public."estado_pedido" as enum (
  'creado',
  'pagado',
  'en_preparacion',
  'completado',
  'reclamado',
  'cancelado'
);

create type public."estado_pago" as enum (
  'creado',
  'autorizado',
  'retenido',
  'liberado',
  'reembolsado',
  'rechazado'
);

create type public."estado_envio" as enum (
  'preparacion',
  'en_transito',
  'entregado',
  'fallido'
);

create type public."estado_reclamo" as enum (
  'abierto',
  'en_revision',
  'resuelto',
  'rechazado'
);

create type public."tipo_sancion" as enum (
  'amonestacion',
  'suspension'
);

create type public."accion_sancion" as enum (
  'ninguna',
  'suspender',
  'ban_permanente'
);

create type public."estado_sancion" as enum (
  'activa',
  'apelada',
  'resuelta',
  'cancelada',
  'expirada'
);

create type public."estado_apelacion" as enum (
  'pendiente',
  'aprobada',
  'rechazada'
);

create type public."tipo_payout" as enum (
  'pago_productor',
  'devolucion_cliente',
  'reembolso_parcial',
  'ajuste_manual'
);

create type public."estado_payout" as enum (
  'pendiente',
  'procesando',
  'pagado',
  'fallido',
  'revertido',
  'cancelado',
  'rechazado'
);

-- ============================================================
-- SECCION 2: TABLAS BASE
-- ============================================================

create table public."regiones" (
  "id" uuid primary key default gen_random_uuid(),
  "codigo" varchar(10) not null unique,
  "nombre" varchar(120) not null unique,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now()
);

create table public."comunas" (
  "id" uuid primary key default gen_random_uuid(),
  "region_id" uuid not null references public."regiones"("id") on delete restrict,
  "codigo" varchar(10) not null unique,
  "nombre" varchar(120) not null,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "uq_comuna_region_nombre" unique ("region_id", "nombre"),
  constraint "uq_comuna_id_region" unique ("id", "region_id")
);

-- ============================================================
-- SECCION 3: USUARIOS Y PRODUCTORES
-- ============================================================

create table public."perfiles" (
  "id" uuid primary key references auth.users(id) on delete cascade,
  "nombre" varchar(100) not null,
  "apellido" varchar(100),
  "telefono" varchar(30),
  "rol" public."rol_usuario" not null default 'cliente',
  "activo" boolean not null default true,
  "intentos_login_fallidos" smallint not null default 0,
  "bloqueado_hasta" timestamptz,
  "es_super_admin" boolean not null default false,
  "es_protegido" boolean not null default false,
  "ultimo_acceso_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_perfil_intentos_no_negativos" check ("intentos_login_fallidos" >= 0),
  constraint "ck_super_admin_debe_ser_protegido" check (not "es_super_admin" or "es_protegido"),
  constraint "ck_perfil_bloqueo_coherente" check (
    "bloqueado_hasta" is null or "bloqueado_hasta" > "creado_en"
  ),
  constraint "ck_super_admin_es_admin_activo" check (
  not "es_super_admin" or ("rol" = 'admin'::public."rol_usuario" and "activo" = true)
)
);

create table public."direcciones" (
  "id" uuid primary key default gen_random_uuid(),
  "perfil_id" uuid not null references public."perfiles"("id") on delete cascade,
  "etiqueta" varchar(50) not null default 'Casa',
  "comuna_id" uuid not null references public."comunas"("id") on delete restrict,
  "calle" varchar(255) not null,
  "numero" varchar(20),
  "depto_oficina" varchar(50),
  "referencia" varchar(500),
  "es_principal" boolean not null default false,
  "activo" boolean not null default true,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_direccion_calle_no_vacia" check (length(btrim("calle")) > 0),
  constraint "ck_direccion_etiqueta_no_vacia" check (length(btrim("etiqueta")) > 0),
  constraint "ck_direccion_principal_activa" check (not "es_principal" or "activo")
);

create table public."postulaciones_vendedores" (
  "id" uuid primary key default gen_random_uuid(),
  "perfil_id" uuid not null references public."perfiles"("id") on delete cascade,
  "nombre_comercial_solicitado" varchar(160) not null,
  "descripcion" varchar(2000),
  "estado" public."estado_postulacion_vendedor" not null default 'pendiente_aprobacion',
  "observaciones_admin" varchar(2500),
  "revisado_por" uuid references public."perfiles"("id") on delete set null,
  "revisado_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_postulacion_revisada" check (
    ("estado" = 'pendiente_aprobacion' and "revisado_por" is null and "revisado_en" is null)
    or ("estado" in ('aprobada', 'rechazada') and "revisado_por" is not null and "revisado_en" is not null)
  )
);

create table public."productores" (
  "id" uuid primary key default gen_random_uuid(),
  "perfil_id" uuid not null unique references public."perfiles"("id") on delete restrict,
  "nombre_comercial" varchar(160) not null unique,
  "slug" varchar(200) not null default '',
  "descripcion" varchar(2000),
  "activo" boolean not null default true,
  "aprobado_en" timestamptz not null default now(),
  "puntaje_reputacion" numeric(3,2) not null default 5.00,
  "cantidad_evaluaciones" integer not null default 0,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_productor_slug_formato" check ("slug" ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint "ck_productor_puntaje" check ("puntaje_reputacion" between 1.00 and 5.00),
  constraint "ck_productor_cantidad_eval" check ("cantidad_evaluaciones" >= 0)
);

create table public."datos_bancarios" (
  "id" uuid primary key default gen_random_uuid(),
  "perfil_id" uuid not null references public."perfiles"("id") on delete cascade,
  "banco" varchar(120) not null,
  "tipo_cuenta" varchar(80) not null,
  "numero_cuenta_cifrado" bytea not null,
  "titular_cuenta" varchar(160) not null,
  "rut_titular" varchar(20) not null,
  "activo" boolean not null default true,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now()
);

-- ============================================================
-- SECCION 4: COBERTURAS (SOLO REGIONAL)
-- ============================================================

-- La cobertura territorial ya no se modela como N:M productor-region.
-- El productor queda representado por una unica direccion activa y la
-- cobertura se valida comparando su region con la region del snapshot
-- de direccion almacenado en el pedido.

-- ============================================================
-- SECCION 5: CATALOGO
-- ============================================================

create table public."categorias" (
  "id" uuid primary key default gen_random_uuid(),
  "categoria_padre_id" uuid references public."categorias"("id") on delete restrict,
  "nombre" varchar(120) not null,
  "slug" varchar(140) not null unique,
  "es_sistema" boolean not null default false,
  "eliminado_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_categoria_no_autopadre" check (
    "categoria_padre_id" is null or "categoria_padre_id" <> "id"
  )
);

insert into public."categorias" (
  "id", "categoria_padre_id", "nombre", "slug", "es_sistema"
) values (
  '00000000-0000-0000-0000-000000000001',
  null,
  'Sin Categoría',
  'sin-categoria',
  true
);

create table public."productos" (
  "id" uuid primary key default gen_random_uuid(),
  "productor_id" uuid not null references public."productores"("id") on delete restrict,
  "categoria_id" uuid references public."categorias"("id") on delete set null,
  "nombre" varchar(180) not null,
  "slug" varchar(200) not null default '',
  "descripcion" varchar(2000),
  "precio" numeric(12,2) not null,
  "stock" numeric(12,3) not null default 0,
  "unidad_medida" public."unidad_medida_producto" not null,
  "fecha_cosecha" date,
  "activo" boolean not null default true,
  "eliminado_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_producto_slug_formato" check ("slug" ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint "ck_producto_precio_no_negativo" check ("precio" >= 0),
  constraint "ck_producto_stock_no_negativo" check ("stock" >= 0)
);

create table public."imagenes_productos" (
  "id" uuid primary key default gen_random_uuid(),
  "producto_id" uuid not null references public."productos"("id") on delete cascade,
  "ruta_storage" varchar(500) not null unique,
  "nombre_archivo" varchar(255) not null,
  "mime_type" varchar(100) not null,
  "tamano_bytes" bigint not null,
  "texto_alternativo" varchar(255),
  "posicion" smallint not null default 1,
  "es_principal" boolean not null default false,
  "metadatos" jsonb not null default '{}'::jsonb,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_imagen_producto_tamano" check ("tamano_bytes" > 0),
  constraint "ck_imagen_producto_posicion" check ("posicion" > 0),
  constraint "uq_imagen_producto_posicion" unique ("producto_id", "posicion")
);

create table public."configuracion_logistica" (
  "id" smallint primary key default 1,
  "tarifa_delivery_defecto" numeric(12,2) not null default 3500.00,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_config_logistica_id_unico" check ("id" = 1),
  constraint "ck_config_tarifa_delivery" check ("tarifa_delivery_defecto" >= 0)
);

insert into public."configuracion_logistica" (
  "id", "tarifa_delivery_defecto"
) values (
  1, 3500.00
);

create table public."palabras_prohibidas" (
  "id" uuid primary key default gen_random_uuid(),
  "palabra" varchar(120) not null,
  "activo" boolean not null default true,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_palabra_no_vacia" check (length(btrim("palabra")) > 0),
  constraint "ck_palabra_sin_wildcards" check (
    position('%' in "palabra") = 0
    and position('_' in "palabra") = 0
  )
);

-- ============================================================
-- SECCION 6: PEDIDOS, PAGOS, ENVIOS, PAYOUTS
-- ============================================================

create table public."pedidos" (
  "id" uuid primary key default gen_random_uuid(),
  "codigo_pedido" varchar(40) not null unique,
  "cliente_id" uuid not null references public."perfiles"("id") on delete restrict,
  "productor_id" uuid not null references public."productores"("id") on delete restrict,
  "region_entrega_id" uuid not null references public."regiones"("id") on delete restrict,
  "comuna_entrega_id" uuid not null references public."comunas"("id") on delete restrict,
  "direccion_entrega" varchar(500) not null,
  "referencia_entrega" varchar(500),
  "nombre_destinatario" varchar(160) not null,
  "telefono_destinatario" varchar(30) not null,
  "estado" public."estado_pedido" not null default 'creado',
  "subtotal_productos" numeric(12,2) not null default 0,
  "tarifa_delivery" numeric(12,2) not null default 3500.00,
  "porcentaje_fee_plataforma" numeric(5,4) not null default 0.0500,
  "monto_fee_plataforma" numeric(12,2) not null default 0,
  "total" numeric(12,2) not null default 3500.00,
  "monto_retenido" numeric(12,2) not null default 0,
  "monto_liquidar_productor" numeric(12,2) not null default 3500.00,
  "confirmado_cliente_en" timestamptz,
  "liberable_desde_en" timestamptz,
  "payout_ejecutado_en" timestamptz,
  "inventario_repuesto_en" timestamptz,
  "cancelado_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_pedido_direccion_no_vacia" check (length(btrim("direccion_entrega")) > 0),
  constraint "ck_pedido_subtotal" check ("subtotal_productos" >= 0),
  constraint "ck_pedido_delivery" check ("tarifa_delivery" >= 0),
  constraint "ck_pedido_fee_porcentaje" check ("porcentaje_fee_plataforma" between 0 and 1),
  constraint "ck_pedido_fee_monto" check ("monto_fee_plataforma" >= 0),
  constraint "ck_pedido_total" check ("total" >= 0),
  constraint "ck_pedido_retenido" check ("monto_retenido" >= 0 and "monto_retenido" <= "total"),
  constraint "ck_pedido_total_coherente" check (
    "total" = round("subtotal_productos" + "tarifa_delivery", 2)
  ),
  constraint "ck_pedido_liquidar_coherente" check (
    "monto_liquidar_productor" = greatest("total" - "monto_fee_plataforma", 0)
  ),
  constraint "ck_pedido_fee_coherente" check (
    "monto_fee_plataforma" = round("subtotal_productos" * "porcentaje_fee_plataforma", 2)
  )
);

create table public."envios" (
  "id" uuid primary key default gen_random_uuid(),
  "pedido_id" uuid not null unique references public."pedidos"("id") on delete cascade,
  "repartidor_id" uuid not null references public."perfiles"("id") on delete restrict,
  "estado" public."estado_envio" not null default 'preparacion',
  "tarifa_fija" numeric(12,2) not null default 3500.00,
  "codigo_verificacion" varchar(12),
  "codigo_verificado_en" timestamptz,
  "despachado_en" timestamptz,
  "entregado_en" timestamptz,
  "fallido_en" timestamptz,
  "motivo_fallo" varchar(1000),
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_envio_tarifa" check ("tarifa_fija" >= 0),
  constraint "ck_envio_codigo_verificado_coherente" check (
    "codigo_verificado_en" is null or "codigo_verificacion" is not null
  ),
  constraint "ck_envio_fallo_fecha" check (
    "fallido_en" is null or "fallido_en" >= "creado_en"
  ),
  constraint "ck_envio_fallo_motivo" check (
    ("estado" <> 'fallido' or length(btrim(coalesce("motivo_fallo", ''))) > 0)
    and ("estado" = 'fallido' or "motivo_fallo" is null)
  )
);

create table public."detalles_pedido" (
  "id" uuid primary key default gen_random_uuid(),
  "pedido_id" uuid not null references public."pedidos"("id") on delete cascade,
  "producto_id" uuid references public."productos"("id") on delete set null,
  "producto_nombre" varchar(180) not null,
  "precio_unitario" numeric(12,2) not null,
  "cantidad" numeric(12,3) not null,
  "subtotal" numeric(12,2) not null,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_detalle_precio" check ("precio_unitario" >= 0),
  constraint "ck_detalle_cantidad" check ("cantidad" > 0),
  constraint "ck_detalle_subtotal" check (
    "subtotal" = round("precio_unitario" * "cantidad", 2)
  )
);

create table public."pagos" (
  "id" uuid primary key default gen_random_uuid(),
  "pedido_id" uuid not null unique references public."pedidos"("id") on delete restrict,
  "buy_order" varchar(80) not null unique,
  "token_ws" varchar(255) unique,
  "estado" public."estado_pago" not null default 'creado',
  "monto" numeric(12,2) not null,
  "codigo_autorizacion" varchar(80),
  "codigo_respuesta" varchar(40),
  "respuesta_webpay" jsonb not null default '{}'::jsonb,
  "creado_en" timestamptz not null default now(),
  "autorizado_en" timestamptz,
  "retenido_en" timestamptz,
  "liberado_en" timestamptz,
  "reembolsado_en" timestamptz,
  constraint "ck_pago_monto" check ("monto" > 0)
);

create table public."payouts" (
  "id" uuid primary key default gen_random_uuid(),
  "beneficiario_id" uuid not null references public."perfiles"("id") on delete restrict,
  "pedido_id" uuid references public."pedidos"("id") on delete restrict,
  "tipo" public."tipo_payout" not null,
  "monto" numeric(12,2) not null,
  "estado" public."estado_payout" not null default 'pendiente',
  "referencia_externa" varchar(255),
  "comprobante_ruta" varchar(500),
  "notas" varchar(3000),
  "ejecutado_por" uuid references public."perfiles"("id") on delete set null,
  "ejecutado_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_payout_monto" check ("monto" > 0),
  constraint "ck_payout_tipo_pedido" check (
    ("tipo" = 'ajuste_manual' and "pedido_id" is null)
    or
    ("tipo" in ('pago_productor', 'devolucion_cliente', 'reembolso_parcial') and "pedido_id" is not null)
  ),
  constraint "ck_payout_ejecucion_coherente" check (
    ("estado" = 'pagado' and "ejecutado_por" is not null and "ejecutado_en" is not null)
    or "estado" <> 'pagado'
  )
);

create unique index "uq_payout_pedido_tipo"
  on public."payouts" ("pedido_id", "tipo")
  where "pedido_id" is not null;

-- ============================================================
-- SECCION 7: RECLAMOS, EVALUACIONES, SANCIONES
-- ============================================================

create table public."reclamos" (
  "id" uuid primary key default gen_random_uuid(),
  "pedido_id" uuid not null references public."pedidos"("id") on delete restrict,
  "cliente_id" uuid not null references public."perfiles"("id") on delete restrict,
  "motivo" varchar(160) not null,
  "descripcion" varchar(2500) not null,
  "estado" public."estado_reclamo" not null default 'abierto',
  "respuesta_productor" varchar(2500),
  "resuelto_por" uuid references public."perfiles"("id") on delete set null,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  "resuelto_en" timestamptz
);

create table public."evaluaciones_reputacion" (
  "id" uuid primary key default gen_random_uuid(),
  "pedido_id" uuid not null unique references public."pedidos"("id") on delete restrict,
  "productor_id" uuid not null references public."productores"("id") on delete restrict,
  "cliente_id" uuid not null references public."perfiles"("id") on delete restrict,
  "puntaje" smallint not null,
  "comentario" varchar(2000),
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_evaluacion_puntaje" check ("puntaje" between 1 and 5)
);

create table public."sanciones" (
  "id" uuid primary key default gen_random_uuid(),
  "productor_id" uuid not null references public."productores"("id") on delete restrict,
  "tipo" public."tipo_sancion" not null,
  "accion" public."accion_sancion" not null default 'ninguna',
  "estado" public."estado_sancion" not null default 'activa',
  "numero_amonestacion" integer,
  "motivo" varchar(2500) not null,
  "duracion_dias" integer,
  "inicio_en" timestamptz not null default now(),
  "fin_en" timestamptz,
  "impuesta_por" uuid references public."perfiles"("id") on delete set null,
  "resuelta_en" timestamptz,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  constraint "ck_sancion_amonestacion_numero" check (
    ("tipo" = 'amonestacion' and "numero_amonestacion" is not null and "numero_amonestacion" > 0)
    or
    ("tipo" <> 'amonestacion' and "numero_amonestacion" is null)
  ),
  constraint "ck_sancion_duracion" check (
    "duracion_dias" is null or "duracion_dias" > 0
  ),
  constraint "ck_sancion_fechas" check (
    "fin_en" is null or "fin_en" >= "inicio_en"
  ),
  constraint "ck_sancion_accion_coherente" check (
    ("accion" = 'ninguna' and "tipo" = 'amonestacion')
    or ("accion" = 'suspender' and "tipo" = 'suspension' and "duracion_dias" is not null)
    or ("accion" = 'ban_permanente' and "tipo" = 'suspension' and "fin_en" is null)
  )
);

create table public."apelaciones" (
  "id" uuid primary key default gen_random_uuid(),
  "sancion_id" uuid not null references public."sanciones"("id") on delete restrict,
  "productor_id" uuid not null references public."productores"("id") on delete restrict,
  "solicitante_id" uuid not null references public."perfiles"("id") on delete restrict,
  "fundamento" varchar(3000) not null,
  "estado" public."estado_apelacion" not null default 'pendiente',
  "resolucion" varchar(3000),
  "resuelto_por" uuid references public."perfiles"("id") on delete set null,
  "creado_en" timestamptz not null default now(),
  "actualizado_en" timestamptz not null default now(),
  "resuelto_en" timestamptz
);

-- ============================================================
-- SECCION 8: MODERACION (PALABRAS PROHIBIDAS)
-- ============================================================

-- La blacklist se administra desde el panel administrativo.
-- La deteccion se hace mediante LIKE case-insensitive en textos de negocio.

-- ============================================================
-- SECCION 9: FOREIGN KEYS
-- ============================================================

-- Todas las claves foraneas se declaran inline en las tablas para que
-- el esquema nazca completo, sin ALTER TABLE estructurales posteriores.

-- ============================================================
-- SECCION 10: INDICES
-- ============================================================

create unique index "uq_super_admin"
  on public."perfiles" ("es_super_admin")
  where "es_super_admin" = true;

create unique index "uq_datos_bancarios_activos"
  on public."datos_bancarios" ("perfil_id")
  where "activo" = true;

create unique index "uq_postulacion_pendiente_por_perfil"
  on public."postulaciones_vendedores" ("perfil_id")
  where "estado" = 'pendiente_aprobacion';

create unique index "uq_imagen_producto_principal"
  on public."imagenes_productos" ("producto_id")
  where "es_principal" = true;

create unique index "uq_palabra_prohibida_lower"
  on public."palabras_prohibidas" (lower("palabra"));

create unique index "uq_apelacion_pendiente_sancion"
  on public."apelaciones" ("sancion_id")
  where "estado" = 'pendiente';

create unique index "uq_producto_slug"
  on public."productos" (lower("slug"));

create unique index "uq_productor_slug"
  on public."productores" (lower("slug"));

create unique index "uq_direccion_principal_activa"
  on public."direcciones" ("perfil_id")
  where "es_principal" = true and "activo" = true;

create index "idx_direcciones_perfil_activas"
  on public."direcciones" ("perfil_id", "activo")
  where "activo" = true;

create index "idx_direcciones_comuna"
  on public."direcciones" using btree ("comuna_id");

create index "idx_comunas_region_id"
  on public."comunas" using btree ("region_id");

create index "idx_comunas_nombre"
  on public."comunas" using btree (lower("nombre"));

create index "idx_perfiles_rol"
  on public."perfiles" using btree ("rol");

create index "idx_perfiles_activo"
  on public."perfiles" using btree ("activo");

create index "idx_perfiles_bloqueado_hasta"
  on public."perfiles" using btree ("bloqueado_hasta")
  where "bloqueado_hasta" is not null;

create index "idx_postulaciones_perfil"
  on public."postulaciones_vendedores" using btree ("perfil_id");

create index "idx_postulaciones_estado"
  on public."postulaciones_vendedores" using btree ("estado");

create index "idx_productores_perfil"
  on public."productores" using btree ("perfil_id");

create index "idx_productores_activos"
  on public."productores" using btree ("activo")
  where "activo" = true;

create index "idx_productores_nombre_comercial"
  on public."productores" using btree (lower("nombre_comercial"));

create index "idx_categorias_padre"
  on public."categorias" using btree ("categoria_padre_id");

create index "idx_categorias_activas"
  on public."categorias" using btree ("eliminado_en")
  where "eliminado_en" is null;

create index "idx_productos_productor"
  on public."productos" using btree ("productor_id");

create index "idx_productos_categoria"
  on public."productos" using btree ("categoria_id");

create index "idx_productos_activos"
  on public."productos" using btree ("activo", "eliminado_en", "categoria_id")
  where "activo" = true and "eliminado_en" is null;

create index "idx_productos_buscador_nombre"
  on public."productos" using btree (lower("nombre"));

create index "idx_imagenes_productos_producto"
  on public."imagenes_productos" using btree ("producto_id", "posicion");

create index "idx_pedidos_cliente_fecha"
  on public."pedidos" using btree ("cliente_id", "creado_en" desc);

create index "idx_pedidos_productor_estado"
  on public."pedidos" using btree ("productor_id", "estado", "creado_en" desc);

create index "idx_pedidos_region_estado"
  on public."pedidos" using btree ("region_entrega_id", "estado", "creado_en" desc);

create index "idx_pedidos_liberables"
  on public."pedidos" ("liberable_desde_en")
  where "liberable_desde_en" is not null;

create index "idx_pedidos_payout_pendiente"
  on public."pedidos" ("liberable_desde_en")
  where "payout_ejecutado_en" is null;

create index "idx_envios_repartidor_estado"
  on public."envios" using btree ("repartidor_id", "estado", "creado_en" desc);

create index "idx_envios_estado"
  on public."envios" using btree ("estado", "creado_en" desc);

create index "idx_detalles_pedido"
  on public."detalles_pedido" using btree ("pedido_id");

create index "idx_detalles_producto"
  on public."detalles_pedido" using btree ("producto_id");

create index "idx_pagos_estado_fecha"
  on public."pagos" using btree ("estado", "creado_en" desc);

create index "idx_pagos_retenidos"
  on public."pagos" using btree ("retenido_en")
  where "estado" = 'retenido';

create index "idx_payouts_beneficiario_estado"
  on public."payouts" using btree ("beneficiario_id", "estado", "creado_en" desc);

create index "idx_payouts_pedido"
  on public."payouts" using btree ("pedido_id");

create index "idx_payouts_estado"
  on public."payouts" using btree ("estado", "creado_en" desc);

create index "idx_payouts_tipo_estado"
  on public."payouts" ("tipo", "estado", "creado_en" desc);

create index "idx_reclamos_pedido"
  on public."reclamos" using btree ("pedido_id");

create index "idx_reclamos_cliente_estado"
  on public."reclamos" using btree ("cliente_id", "estado");

create unique index "uq_reclamo_abierto_por_pedido"
  on public."reclamos" ("pedido_id")
  where "estado" in ('abierto', 'en_revision');

create index "idx_evaluaciones_productor_fecha"
  on public."evaluaciones_reputacion" using btree ("productor_id", "creado_en" desc);

create index "idx_evaluaciones_cliente"
  on public."evaluaciones_reputacion" using btree ("cliente_id", "creado_en" desc);

create index "idx_sanciones_productor_estado"
  on public."sanciones" using btree ("productor_id", "estado", "inicio_en" desc);

create index "idx_apelaciones_productor_estado"
  on public."apelaciones" using btree ("productor_id", "estado", "creado_en" desc);

create index "idx_datos_bancarios_perfil"
  on public."datos_bancarios" using btree ("perfil_id");

-- ============================================================
-- SECCION 11: FUNCIONES AUXILIARES PRIVADAS
-- ============================================================

create or replace function private.es_admin_actual()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce(
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
      ''
    ) = 'service_role'
    or exists (
      select 1
      from public."perfiles" p
      where p."id" = (select auth.uid())
        and p."rol" = 'admin'::public."rol_usuario"
        and p."activo" = true
    );
$$;

create or replace function private.es_super_admin_actual()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce(
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
      ''
    ) = 'service_role'
    or exists (
      select 1
      from public."perfiles" p
      where p."id" = (select auth.uid())
        and p."rol" = 'admin'::public."rol_usuario"
        and p."es_super_admin" = true
        and p."activo" = true
    );
$$;

create or replace function private.es_productor_actual(p_productor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public."productores" p
    join public."perfiles" pf on pf."id" = p."perfil_id"
    where p."id" = p_productor_id
      and p."perfil_id" = (select auth.uid())
      and p."activo" = true
      and pf."rol" = 'vendedor'::public."rol_usuario"
      and pf."activo" = true
  );
$$;

create or replace function private.es_productor_actual_de_producto(p_producto_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public."productos" p
    join public."productores" pr on pr."id" = p."productor_id"
    join public."perfiles" pf on pf."id" = pr."perfil_id"
    where p."id" = p_producto_id
      and pr."perfil_id" = (select auth.uid())
      and pr."activo" = true
      and pf."rol" = 'vendedor'::public."rol_usuario"
      and pf."activo" = true
  );
$$;

create or replace function private.puede_acceder_pedido(p_pedido_id uuid)
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
      from public."pedidos" p
      join public."productores" pr on pr."id" = p."productor_id"
      where p."id" = p_pedido_id
        and (
          p."cliente_id" = (select auth.uid())
          or pr."perfil_id" = (select auth.uid())
        )
    );
$$;

create or replace function private.puede_acceder_envio(p_envio_id uuid)
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
      from public."envios" e
      join public."pedidos" p on p."id" = e."pedido_id"
      join public."productores" pr on pr."id" = p."productor_id"
      where e."id" = p_envio_id
        and (
          p."cliente_id" = (select auth.uid())
          or e."repartidor_id" = (select auth.uid())
          or pr."perfil_id" = (select auth.uid())
        )
    );
$$;

create or replace function private.puede_acceder_payout(p_payout_id uuid)
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
      from public."payouts" p
      where p."id" = p_payout_id
        and p."beneficiario_id" = (select auth.uid())
    );
$$;

create or replace function private.puede_acceder_postulacion(p_postulacion_id uuid)
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
      from public."postulaciones_vendedores" p
      where p."id" = p_postulacion_id
        and p."perfil_id" = (select auth.uid())
    );
$$;

create or replace function private.puede_acceder_datos_bancarios(p_perfil_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_perfil_id = (select auth.uid());
$$;

create or replace function private.es_productor_propietario(p_productor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public."productores" p
    where p."id" = p_productor_id
      and p."perfil_id" = (select auth.uid())
  );
$$;



revoke all on schema private from public;
grant usage on schema private to authenticated;
grant execute on function private.es_admin_actual() to authenticated;
grant execute on function private.es_super_admin_actual() to authenticated;
grant execute on function private.es_productor_actual(uuid) to authenticated;
grant execute on function private.es_productor_actual_de_producto(uuid) to authenticated;
grant execute on function private.puede_acceder_pedido(uuid) to authenticated;
grant execute on function private.puede_acceder_envio(uuid) to authenticated;
grant execute on function private.puede_acceder_payout(uuid) to authenticated;
grant execute on function private.puede_acceder_postulacion(uuid) to authenticated;
grant execute on function private.puede_acceder_datos_bancarios(uuid) to authenticated;

-- ============================================================
-- SECCION 12: FUNCIONES PUBLICAS DE NEGOCIO
-- ============================================================

create or replace function public.actualizar_actualizado_en()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new."actualizado_en" := now();
  return new;
end;
$$;

create or replace function public.manejar_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public."perfiles" (
    "id",
    "nombre",
    "apellido",
    "rol",
    "activo"
  ) values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'nombre', 'Usuario'),
    nullif(new.raw_user_meta_data ->> 'apellido', ''),
    'cliente'::public."rol_usuario",
    true
  )
  on conflict ("id") do nothing;

  return new;
end;
$$;

create or replace function public.proteger_admin_base()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
begin
  v_jwt := current_setting('request.jwt.claims', true);

  if tg_op = 'DELETE' then
    if (old."es_protegido" or old."es_super_admin") and v_jwt is not null and current_user <> 'service_role' then
      raise exception 'El Administrador Base protegido no puede eliminarse desde la API';
    end if;
    return old;
  end if;

  if (old."es_protegido" or old."es_super_admin") and new is distinct from old and v_jwt is not null and current_user <> 'service_role' then
    -- Solo el propio superadmin puede modificar su fila, y solo si mantiene invariantes
    if not (
      (select private.es_super_admin_actual())
      and new."id" = old."id"
      and new."es_protegido" = old."es_protegido"
      and new."es_super_admin" = old."es_super_admin"
      and new."rol" = 'admin'::public."rol_usuario"
      and new."activo" = true
    ) then
      raise exception 'El Administrador Base protegido no puede modificarse desde la API';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.validar_cambios_seguridad_perfil()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new."rol" is distinct from old."rol"
     and not (select private.es_admin_actual()) then
    raise exception 'Solo un administrador puede cambiar el rol';
  end if;

  if (new."es_super_admin" is distinct from old."es_super_admin"
      or new."es_protegido" is distinct from old."es_protegido")
     and not (select private.es_super_admin_actual()) then
    raise exception 'Solo el Administrador Base puede modificar atributos de proteccion';
  end if;

  if (new."intentos_login_fallidos" is distinct from old."intentos_login_fallidos"
      or new."bloqueado_hasta" is distinct from old."bloqueado_hasta"
      or new."ultimo_acceso_en" is distinct from old."ultimo_acceso_en")
     and current_setting('request.jwt.claims', true) is not null
     and current_user <> 'service_role' then
    raise exception 'Los controles de autenticacion solo pueden modificarse desde el backend';
  end if;

  if new."activo" is distinct from old."activo"
     and not (select private.es_admin_actual())
     and current_setting('request.jwt.claims', true) is not null
     and current_user <> 'service_role' then
    raise exception 'Solo un administrador puede cambiar el estado activo de la cuenta';
  end if;

  return new;
end;
$$;

create or replace function public.validar_postulacion_estado()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new."estado" is distinct from old."estado" then
    if not (select private.es_admin_actual()) then
      raise exception 'Solo un administrador puede resolver una postulacion';
    end if;

    if new."estado" not in ('aprobada', 'rechazada') then
      raise exception 'El estado de una postulacion solo puede resolverse como aprobada o rechazada';
    end if;

    new."revisado_en" := coalesce(new."revisado_en", now());
    new."revisado_por" := coalesce(new."revisado_por", (select auth.uid()));
  end if;

  if new."estado" = 'pendiente_aprobacion' and (new."revisado_por" is not null or new."revisado_en" is not null) then
    raise exception 'Una postulacion pendiente no puede tener datos de revision';
  end if;

  return new;
end;
$$;

create or replace function public.activar_productor_aprobado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_direcciones_activas integer;
begin
  if new."estado" = 'aprobada' and old."estado" is distinct from new."estado" then
    select count(*)::integer
      into v_direcciones_activas
    from public."direcciones" d
    where d."perfil_id" = new."perfil_id"
      and d."activo" = true;

    if v_direcciones_activas <> 1 then
      raise exception 'La cuenta del vendedor debe tener exactamente una direccion activa antes de ser aprobada';
    end if;

    insert into public."productores" (
      "perfil_id",
      "nombre_comercial",
      "slug",
      "descripcion",
      "activo",
      "aprobado_en"
    ) values (
      new."perfil_id",
      new."nombre_comercial_solicitado",
      '',
      new."descripcion",
      true,
      coalesce(new."revisado_en", now())
    )
    on conflict ("perfil_id") do update
      set "nombre_comercial" = excluded."nombre_comercial",
          "descripcion" = excluded."descripcion",
          "activo" = true,
          "aprobado_en" = excluded."aprobado_en";

    update public."perfiles"
       set "rol" = 'vendedor'::public."rol_usuario",
           "activo" = true
     where "id" = new."perfil_id";
  end if;

  return new;
end;
$$;

create or replace function public.validar_direccion()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_es_productor boolean;
  v_otras_activas integer;
begin
  if tg_op = 'DELETE' then
    if old."perfil_id" <> (select auth.uid()) then
      raise exception 'Solo el propietario puede eliminar una direccion';
    end if;

    select exists (
      select 1 from public."productores" pr
      where pr."perfil_id" = old."perfil_id"
    ) into v_es_productor;

    if v_es_productor and old."activo" then
      select count(*)::integer
        into v_otras_activas
      from public."direcciones" d
      where d."perfil_id" = old."perfil_id"
        and d."activo" = true
        and d."id" <> old."id";

      if v_otras_activas = 0 then
        raise exception 'Un productor debe conservar exactamente una direccion activa';
      end if;
    end if;

    return old;
  end if;

  if new."perfil_id" <> (select auth.uid()) then
    raise exception 'Solo el propietario puede crear o modificar sus direcciones';
  end if;

  select exists (
    select 1 from public."productores" pr
    where pr."perfil_id" = new."perfil_id"
  ) into v_es_productor;

  if v_es_productor and new."activo" then
    select count(*)::integer
      into v_otras_activas
    from public."direcciones" d
    where d."perfil_id" = new."perfil_id"
      and d."activo" = true
      and d."id" <> new."id";

    if v_otras_activas > 0 then
      raise exception 'Un productor solo puede tener una direccion activa';
    end if;
  end if;

  if v_es_productor and not new."activo" then
    select count(*)::integer
      into v_otras_activas
    from public."direcciones" d
    where d."perfil_id" = new."perfil_id"
      and d."activo" = true
      and d."id" <> new."id";

    if v_otras_activas = 0 then
      raise exception 'Un productor debe conservar exactamente una direccion activa';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.normalizar_slug(p_texto text, p_fallback text)
returns varchar(200)
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_slug text;
begin
  v_slug := lower(btrim(coalesce(p_texto, '')));
  v_slug := translate(v_slug, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN');
  v_slug := regexp_replace(v_slug, '[^a-z0-9]+', '-', 'g');
  v_slug := regexp_replace(v_slug, '(^-|-$)', '', 'g');

  if v_slug = '' then
    v_slug := p_fallback;
  end if;

  return left(v_slug, 200);
end;
$$;

create or replace function public.generar_slug_producto()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base text;
  v_slug text;
  v_n integer := 1;
  v_max_base integer;
begin
  if btrim(coalesce(new."slug", '')) = '' then
    v_base := public.normalizar_slug(new."nombre", 'producto');
  else
    v_base := public.normalizar_slug(new."slug", 'producto');
  end if;

  v_slug := v_base;
  while exists (
    select 1
    from public."productos" p
    where lower(p."slug") = lower(v_slug)
      and p."id" <> coalesce(new."id", '00000000-0000-0000-0000-000000000000'::uuid)
  ) loop
    v_n := v_n + 1;
    v_max_base := greatest(1, 200 - length('-' || v_n::text));
    v_slug := left(v_base, v_max_base) || '-' || v_n::text;
  end loop;

  new."slug" := v_slug;
  return new;
end;
$$;

create or replace function public.generar_slug_productor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base text;
  v_slug text;
  v_n integer := 1;
  v_max_base integer;
begin
  if btrim(coalesce(new."slug", '')) = '' then
    v_base := public.normalizar_slug(new."nombre_comercial", 'productor');
  else
    v_base := public.normalizar_slug(new."slug", 'productor');
  end if;

  v_slug := v_base;
  while exists (
    select 1
    from public."productores" p
    where lower(p."slug") = lower(v_slug)
      and p."id" <> coalesce(new."id", '00000000-0000-0000-0000-000000000000'::uuid)
  ) loop
    v_n := v_n + 1;
    v_max_base := greatest(1, 200 - length('-' || v_n::text));
    v_slug := left(v_base, v_max_base) || '-' || v_n::text;
  end loop;

  new."slug" := v_slug;
  return new;
end;
$$;

create or replace function public.validar_jerarquia_categoria()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_encontrado boolean;
begin
  if new."categoria_padre_id" is null then
    return new;
  end if;

  if new."categoria_padre_id" = new."id" then
    raise exception 'Una categoria no puede ser su propio padre';
  end if;

  select exists (
    with recursive ascendientes as (
      select c."id", c."categoria_padre_id"
      from public."categorias" c
      where c."id" = new."categoria_padre_id"
      union all
      select c."id", c."categoria_padre_id"
      from public."categorias" c
      join ascendientes a on a."categoria_padre_id" = c."id"
    )
    select 1 from ascendientes where "id" = new."id"
  ) into v_encontrado;

  if v_encontrado then
    raise exception 'La jerarquia de categorias generaria un ciclo';
  end if;

  if exists (
    select 1
    from public."categorias" c
    where c."id" = new."categoria_padre_id"
      and c."eliminado_en" is not null
  ) then
    raise exception 'No se puede usar una categoria eliminada como padre';
  end if;

  return new;
end;
$$;

create or replace function public.reasignar_categoria_eliminada()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sin_categoria uuid := '00000000-0000-0000-0000-000000000001';
begin
  if new."eliminado_en" is not null and old."eliminado_en" is null then
    if new."es_sistema" then
      raise exception 'La categoria del sistema no puede eliminarse logicamente';
    end if;

    with recursive descendientes as (
      select c."id"
      from public."categorias" c
      where c."id" = new."id"
      union all
      select c."id"
      from public."categorias" c
      join descendientes d on c."categoria_padre_id" = d."id"
    )
    update public."productos" p
       set "categoria_id" = v_sin_categoria
     where p."categoria_id" in (select "id" from descendientes);

    with recursive descendientes as (
      select c."id"
      from public."categorias" c
      where c."id" = new."id"
      union all
      select c."id"
      from public."categorias" c
      join descendientes d on c."categoria_padre_id" = d."id"
    )
    update public."categorias" c
       set "categoria_padre_id" = v_sin_categoria
     where c."id" in (select "id" from descendientes)
       and c."id" <> new."id";

    new."categoria_padre_id" := v_sin_categoria;
  end if;

  return new;
end;
$$;

create or replace function public.contiene_palabra_prohibida(p_texto text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public."palabras_prohibidas" b
    where b."activo" = true
      and lower(coalesce(p_texto, '')) like '%' || lower(b."palabra") || '%'
  );
$$;

create or replace function public.validar_texto_moderado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_json jsonb := to_jsonb(new);
  v_campo text;
  v_texto text;
  v_campos text[];
begin
  v_campos := case tg_table_name
    when 'productos' then array['nombre', 'descripcion']
    when 'productores' then array['nombre_comercial', 'descripcion']
    when 'postulaciones_vendedores' then array['nombre_comercial_solicitado', 'descripcion']
    when 'evaluaciones_reputacion' then array['comentario']
    when 'reclamos' then array['motivo', 'descripcion', 'respuesta_productor']
    when 'apelaciones' then array['fundamento']
    else array[]::text[]
  end;

  foreach v_campo in array v_campos loop
    v_texto := v_json ->> v_campo;
    if public.contiene_palabra_prohibida(v_texto) then
      raise exception 'El texto contiene una palabra prohibida por la moderacion';
    end if;
  end loop;

  return new;
end;
$$;

create or replace function public.obtener_tarifa_delivery_defecto()
returns numeric(12,2)
language sql
stable
security definer
set search_path = ''
as $$
  select "tarifa_delivery_defecto"
  from public."configuracion_logistica"
  where "id" = 1;
$$;

create or replace function public.validar_cobertura_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_region_productor uuid;
  v_region_comuna uuid;
begin
  select c."region_id"
    into v_region_comuna
  from public."comunas" c
  where c."id" = new."comuna_entrega_id";

  if v_region_comuna is null or v_region_comuna <> new."region_entrega_id" then
    raise exception 'La comuna de entrega no pertenece a la region del snapshot del pedido';
  end if;

  select c."region_id"
    into v_region_productor
  from public."productores" pr
  join public."direcciones" d
    on d."perfil_id" = pr."perfil_id"
   and d."activo" = true
  join public."comunas" c
    on c."id" = d."comuna_id"
  where pr."id" = new."productor_id"
  limit 1;

  if v_region_productor is null then
    raise exception 'El productor no tiene una direccion activa registrada';
  end if;

  if new."region_entrega_id" <> v_region_productor then
    raise exception 'La region de entrega no coincide con la region del productor (AFC es regional)';
  end if;

  return new;
end;
$$;

create or replace function public.validar_detalle_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_productor_pedido uuid;
  v_estado_pedido public."estado_pedido";
  v_productor_producto uuid;
  v_producto_activo boolean;
  v_producto_eliminado timestamptz;
  v_nombre_actual varchar(180);
  v_precio_actual numeric(12,2);
begin
  select p."productor_id", p."estado"
    into v_productor_pedido, v_estado_pedido
  from public."pedidos" p
  where p."id" = new."pedido_id";

  if v_productor_pedido is null then
    raise exception 'Pedido inexistente';
  end if;

  if v_estado_pedido <> 'creado' then
    raise exception 'Los items solo pueden modificarse mientras el pedido esta en estado creado';
  end if;

  select p."productor_id", p."activo", p."eliminado_en", p."nombre", p."precio"
    into v_productor_producto, v_producto_activo, v_producto_eliminado, v_nombre_actual, v_precio_actual
  from public."productos" p
  where p."id" = new."producto_id";

  if v_productor_producto is null then
    raise exception 'Producto inexistente';
  end if;

  if v_productor_producto <> v_productor_pedido then
    raise exception 'El producto no pertenece al productor del pedido';
  end if;

  if not v_producto_activo or v_producto_eliminado is not null then
    raise exception 'El producto no esta activo para compra';
  end if;

  new."producto_nombre" := coalesce(nullif(new."producto_nombre", ''), v_nombre_actual);
  new."precio_unitario" := coalesce(new."precio_unitario", v_precio_actual);
  new."subtotal" := round(new."precio_unitario" * new."cantidad", 2);

  return new;
end;
$$;

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
         "total" = v_total,
         "monto_liquidar_productor" = greatest(v_total - v_fee, 0)
   where "id" = p_pedido_id;
end;
$$;

create or replace function public.trg_recalcular_totales_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform public.recalcular_totales_pedido(coalesce(new."pedido_id", old."pedido_id"));
  return coalesce(new, old);
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
  if v_jwt is null or v_es_admin or current_user = 'service_role' then
    return new;
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
        and p."estado" = 'retenido'
    ) then
      raise exception 'No se puede marcar el pedido como pagado sin pago retenido';
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
      "pedido_id",
      "repartidor_id",
      "estado",
      "tarifa_fija"
    ) values (
      new."id",
      v_repartidor_id,
      'preparacion'::public."estado_envio",
      new."tarifa_delivery"
    );

    update public."pedidos"
       set "estado" = 'en_preparacion'::public."estado_pedido"
     where "id" = new."id"
       and "estado" = 'pagado'::public."estado_pedido";
  end if;

  return new;
end;
$$;

create or replace function public.generar_codigo_verificacion()
returns varchar(12)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hex text;
begin
  -- Compatibilidad con Supabase Cloud (extensions) y local (public)
  begin
    v_hex := encode(extensions.gen_random_bytes(8), 'hex');
  exception when others then
    v_hex := encode(public.gen_random_bytes(8), 'hex');
  end;

  return upper(substr(v_hex, 1, 12));
end;
$$;



create or replace function public.validar_transicion_envio()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_perfil_productor uuid;
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
    (old."estado" = 'preparacion' and new."estado" in ('en_transito', 'fallido'))
    or (old."estado" = 'en_transito' and new."estado" in ('entregado', 'fallido'))
  ) then
    raise exception 'Transicion de envio no permitida: % -> %', old."estado", new."estado";
  end if;

  if new."estado" = 'en_transito' and old."estado" = 'preparacion' then
    new."codigo_verificacion" := public.generar_codigo_verificacion();
    new."codigo_verificado_en" := null;
    new."despachado_en" := coalesce(new."despachado_en", now());
    new."motivo_fallo" := null;
    new."fallido_en" := null;
  end if;

  if new."estado" = 'fallido' and old."estado" is distinct from 'fallido' then
    if length(btrim(coalesce(new."motivo_fallo", ''))) = 0 then
      raise exception 'Un envio fallido requiere motivo_fallo';
    end if;
    new."motivo_fallo" := btrim(new."motivo_fallo");
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
           "confirmado_cliente_en" = coalesce("confirmado_cliente_en", new."entregado_en"),
           "liberable_desde_en" = coalesce("liberable_desde_en", new."entregado_en")
     where "id" = new."pedido_id"
       and "estado" in (
         'pagado'::public."estado_pedido",
         'en_preparacion'::public."estado_pedido"
       );
  end if;

  return new;
end;
$$;
create or replace function public.validar_transicion_pago()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new."estado" <> old."estado" then
    if not (
      (old."estado" = 'creado' and new."estado" in ('autorizado', 'rechazado'))
      or (old."estado" = 'autorizado' and new."estado" in ('retenido', 'reembolsado'))
      or (old."estado" = 'retenido' and new."estado" in ('liberado', 'reembolsado'))
      or (old."estado" = 'liberado' and new."estado" = 'reembolsado')
    ) then
      raise exception 'Transicion de pago no permitida: % -> %', old."estado", new."estado";
    end if;
  end if;

  if new."estado" = 'autorizado' then
    new."autorizado_en" := coalesce(new."autorizado_en", now());
  elsif new."estado" = 'retenido' then
    new."retenido_en" := coalesce(new."retenido_en", now());
  elsif new."estado" = 'liberado' then
    new."liberado_en" := coalesce(new."liberado_en", now());
  elsif new."estado" = 'reembolsado' then
    new."reembolsado_en" := coalesce(new."reembolsado_en", now());
  end if;

  return new;
end;
$$;

create or replace function public.sincronizar_escrow_pago()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new."estado" = 'retenido' and old."estado" is distinct from new."estado" then
    update public."pedidos"
       set "monto_retenido" = "total"
     where "id" = new."pedido_id";
  elsif new."estado" = 'liberado' and old."estado" is distinct from new."estado" then
    update public."pedidos"
       set "monto_retenido" = 0
     where "id" = new."pedido_id";
  elsif new."estado" = 'reembolsado' and old."estado" is distinct from new."estado" then
    update public."pedidos"
       set "monto_retenido" = 0
     where "id" = new."pedido_id";
  end if;

  return new;
end;
$$;

create or replace function public.verificar_codigo_entrega(
  p_envio_id uuid,
  p_codigo text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pedido_id uuid;
  v_cliente_id uuid;
  v_codigo text;
begin
  if p_codigo is null or btrim(p_codigo) = '' then
    raise exception 'El codigo de entrega no puede ser nulo o vacio';
  end if;

  select e."pedido_id", p."cliente_id", e."codigo_verificacion"
    into v_pedido_id, v_cliente_id, v_codigo
  from public."envios" e
  join public."pedidos" p on p."id" = e."pedido_id"
  where e."id" = p_envio_id
  for update of e;

  if v_pedido_id is null then
    raise exception 'Envio inexistente';
  end if;

  if v_cliente_id <> (select auth.uid()) and not (select private.es_admin_actual()) then
    raise exception 'Solo el cliente del pedido o un administrador puede verificar el codigo';
  end if;

  -- IS DISTINCT FROM evita que un NULL pase silenciosamente
  if v_codigo is null or upper(btrim(p_codigo)) is distinct from v_codigo then
    raise exception 'Codigo de entrega invalido';
  end if;

  if exists (
    select 1 from public."envios" e
    where e."id" = p_envio_id and e."estado" <> 'en_transito'
  ) then
    raise exception 'El codigo solo puede verificarse durante el estado en_transito';
  end if;

  perform set_config('cutuco.operacion_interna', 'true', true);

  update public."envios"
     set "codigo_verificado_en" = coalesce("codigo_verificado_en", now())
   where "id" = p_envio_id;

  return true;
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
     set "confirmado_cliente_en" = coalesce("confirmado_cliente_en", now()),
         "liberable_desde_en" = coalesce("liberable_desde_en", now())
   where "id" = p_pedido_id;

  return true;
end;
$$;

create or replace function public.crear_payout_al_completar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_beneficiario_id uuid;
begin
  if new."estado" = 'completado' and old."estado" is distinct from new."estado" then
    select pr."perfil_id"
      into v_beneficiario_id
    from public."productores" pr
    where pr."id" = new."productor_id";

    if v_beneficiario_id is null then
      raise exception 'No se encontro el perfil del productor para crear el payout';
    end if;

    insert into public."payouts" (
      "beneficiario_id",
      "pedido_id",
      "tipo",
      "monto",
      "estado"
    ) values (
      v_beneficiario_id,
      new."id",
      'pago_productor'::public."tipo_payout",
      new."monto_liquidar_productor",
      'pendiente'::public."estado_payout"
    )
    on conflict do nothing;
  end if;

  return new;
end;
$$;

create or replace function public.validar_payout()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cliente_id uuid;
  v_productor_perfil_id uuid;
begin
  if new."pedido_id" is not null then
    select p."cliente_id", pr."perfil_id"
      into v_cliente_id, v_productor_perfil_id
    from public."pedidos" p
    join public."productores" pr on pr."id" = p."productor_id"
    where p."id" = new."pedido_id";

    if v_cliente_id is null then
      raise exception 'Pedido inexistente para payout';
    end if;

    if new."tipo" = 'pago_productor' and new."beneficiario_id" <> v_productor_perfil_id then
      raise exception 'El beneficiario del payout de productor no coincide con el productor del pedido';
    end if;

    if new."tipo" in ('devolucion_cliente', 'reembolso_parcial') and new."beneficiario_id" <> v_cliente_id then
      raise exception 'El beneficiario del payout de devolucion no coincide con el cliente del pedido';
    end if;
  end if;

  if new."tipo" = 'ajuste_manual' and new."pedido_id" is not null then
    raise exception 'Un ajuste manual no puede asociarse a un pedido';
  end if;

  -- Bloqueo de pago: aplica a INSERT y UPDATE
  if new."estado" = 'pagado'
     and current_setting('cutuco.operacion_interna', true) is distinct from 'true'
     and current_user <> 'service_role' then
    raise exception 'El payout solo puede marcarse como pagado mediante la RPC de administracion';
  end if;

  if new."tipo" = 'pago_productor' and new."pedido_id" is not null then
    if not exists (
      select 1 from public."pedidos" p
      where p."id" = new."pedido_id"
        and new."monto" = p."monto_liquidar_productor"
    ) then
      raise exception 'El monto del payout al productor debe coincidir con el monto_liquidar_productor del pedido';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.sincronizar_payout_pedido()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new."estado" = 'pagado' and old."estado" is distinct from new."estado" then
    if new."tipo" = 'pago_productor' then
      update public."pedidos"
         set "payout_ejecutado_en" = coalesce("payout_ejecutado_en", new."ejecutado_en", now())
       where "id" = new."pedido_id";

      perform set_config('cutuco.operacion_interna', 'true', true);

      update public."pagos"
         set "estado" = 'liberado'::public."estado_pago"
       where "pedido_id" = new."pedido_id"
         and "estado" = 'retenido'::public."estado_pago";
    elsif new."tipo" in ('devolucion_cliente', 'reembolso_parcial') then
      perform set_config('cutuco.operacion_interna', 'true', true);

      update public."pagos"
         set "estado" = 'reembolsado'::public."estado_pago"
       where "pedido_id" = new."pedido_id"
         and "estado" in ('retenido'::public."estado_pago", 'liberado'::public."estado_pago");
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.registrar_payout_pagado(
  p_payout_id uuid,
  p_referencia text,
  p_notas text
)
returns public."payouts"
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payout public."payouts"%rowtype;
  v_resultado public."payouts"%rowtype;
begin
  if not (select private.es_admin_actual()) then
    raise exception 'Solo un administrador puede registrar un payout pagado';
  end if;

  select *
    into v_payout
  from public."payouts"
  where "id" = p_payout_id
  for update;

  if not found then
    raise exception 'Payout inexistente';
  end if;

  if v_payout."estado" not in ('pendiente', 'procesando') then
    raise exception 'Solo un payout pendiente o en procesamiento puede marcarse como pagado';
  end if;

  -- Bloquear liquidacion al productor si hay reclamos abiertos o en revision
  if v_payout."tipo" = 'pago_productor' and v_payout."pedido_id" is not null then
    if exists (
      select 1 from public."reclamos" r
      where r."pedido_id" = v_payout."pedido_id"
        and r."estado" in (
          'abierto'::public."estado_reclamo",
          'en_revision'::public."estado_reclamo"
        )
    ) then
      raise exception 'No se puede liquidar al productor mientras exista un reclamo abierto o en revision';
    end if;
  end if;

  if v_payout."tipo" = 'pago_productor' then
    if not exists (
      select 1 from public."pagos" p
      where p."pedido_id" = v_payout."pedido_id"
        and p."estado" = 'retenido'::public."estado_pago"
    ) then
      raise exception 'El payout al productor solo puede pagarse mientras el pago del pedido esta retenido';
    end if;
  elsif v_payout."tipo" in ('devolucion_cliente', 'reembolso_parcial') then
    if not exists (
      select 1 from public."pagos" p
      where p."pedido_id" = v_payout."pedido_id"
        and p."estado" in ('retenido'::public."estado_pago", 'liberado'::public."estado_pago")
    ) then
      raise exception 'La devolucion solo puede pagarse mientras el pago esta retenido o liberado';
    end if;
  end if;

  perform set_config('cutuco.operacion_interna', 'true', true);

  update public."payouts"
     set "estado" = 'pagado'::public."estado_payout",
         "referencia_externa" = p_referencia,
         "notas" = p_notas,
         "ejecutado_por" = (select auth.uid()),
         "ejecutado_en" = now()
   where "id" = p_payout_id
  returning * into v_resultado;

  return v_resultado;
end;
$$;
create or replace function public.proteger_campos_reclamo()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
  v_es_admin boolean;
  v_es_productor boolean;
begin
  v_jwt := current_setting('request.jwt.claims', true);
  v_es_admin := (select private.es_admin_actual());

  if v_jwt is null or v_es_admin or current_user = 'service_role' then
    return new;
  end if;

  -- El productor solo puede escribir respuesta_productor.
  -- Cualquier otro cambio en columnas administrativas se rechaza.
  if new."pedido_id" is distinct from old."pedido_id"
     or new."cliente_id" is distinct from old."cliente_id"
     or new."motivo" is distinct from old."motivo"
     or new."descripcion" is distinct from old."descripcion"
     or new."estado" is distinct from old."estado"
     or new."resuelto_por" is distinct from old."resuelto_por"
     or new."resuelto_en" is distinct from old."resuelto_en" then
    raise exception 'Solo un administrador puede modificar los campos administrativos del reclamo';
  end if;

  return new;
end;
$$;

create or replace function public.registrar_devolucion_cliente(
  p_pedido_id uuid,
  p_monto numeric(12,2),
  p_motivo text,
  p_parcial boolean
)
returns public."payouts"
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cliente_id uuid;
  v_total numeric(12,2);
  v_reembolsado numeric(12,2);
  v_tipo public."tipo_payout";
  v_resultado public."payouts"%rowtype;
begin
  if not (select private.es_admin_actual()) then
    raise exception 'Solo un administrador puede registrar una devolucion';
  end if;

  if p_monto <= 0 then
    raise exception 'El monto de devolucion debe ser mayor que cero';
  end if;

  select "cliente_id", "total"
    into v_cliente_id, v_total
  from public."pedidos"
  where "id" = p_pedido_id
  for update;

  if v_cliente_id is null then
    raise exception 'Pedido inexistente';
  end if;

  select coalesce(sum("monto"), 0)
    into v_reembolsado
  from public."payouts"
  where "pedido_id" = p_pedido_id
    and "tipo" in ('devolucion_cliente', 'reembolso_parcial')
    and "estado" in ('pendiente', 'procesando', 'pagado');

  if v_reembolsado + p_monto > v_total then
    raise exception 'El total acumulado de devoluciones excederia el total del pedido';
  end if;

  if p_parcial then
    if p_monto >= v_total then
      raise exception 'Un reembolso parcial debe ser menor que el total del pedido';
    end if;
    if exists (
      select 1 from public."payouts"
      where "pedido_id" = p_pedido_id
        and "tipo" = 'reembolso_parcial'
    ) then
      raise exception 'Ya existe un reembolso parcial para este pedido';
    end if;
    v_tipo := 'reembolso_parcial'::public."tipo_payout";
  else
    if p_monto <> v_total then
      raise exception 'Una devolucion total debe coincidir con el total del pedido';
    end if;
    v_tipo := 'devolucion_cliente'::public."tipo_payout";
  end if;

  insert into public."payouts" (
    "beneficiario_id",
    "pedido_id",
    "tipo",
    "monto",
    "estado",
    "notas"
  ) values (
    v_cliente_id,
    p_pedido_id,
    v_tipo,
    p_monto,
    'pendiente'::public."estado_payout",
    p_motivo
  )
  returning * into v_resultado;

  return v_resultado;
end;
$$;

create or replace function public.validar_repartidor_envio()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_perfil_productor uuid;
begin
  select pr."perfil_id"
    into v_perfil_productor
  from public."pedidos" p
  join public."productores" pr on pr."id" = p."productor_id"
  where p."id" = new."pedido_id";

  if v_perfil_productor is null or new."repartidor_id" <> v_perfil_productor then
    raise exception 'El repartidor debe ser el perfil del productor del pedido en el MVP';
  end if;

  return new;
end;
$$;

create or replace function public.validar_reclamo()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cliente_id uuid;
begin
  select "cliente_id"
    into v_cliente_id
  from public."pedidos"
  where "id" = new."pedido_id";

  if v_cliente_id is null then
    raise exception 'Pedido inexistente para reclamo';
  end if;

  if new."cliente_id" <> v_cliente_id then
    raise exception 'El cliente del reclamo no coincide con el pedido';
  end if;

  return new;
end;
$$;

create or replace function public.validar_evaluacion_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cliente uuid;
  v_productor uuid;
  v_estado public."estado_pedido";
begin
  select p."cliente_id", p."productor_id", p."estado"
    into v_cliente, v_productor, v_estado
  from public."pedidos" p
  where p."id" = new."pedido_id";

  if v_cliente is null then
    raise exception 'Pedido inexistente para evaluacion';
  end if;

  if v_estado not in ('completado', 'reclamado') then
    raise exception 'Solo se puede evaluar un pedido completado o reclamado';
  end if;

  if new."cliente_id" <> v_cliente or new."productor_id" <> v_productor then
    raise exception 'Cliente/productor de la evaluacion no corresponden al pedido';
  end if;

  return new;
end;
$$;

create or replace function public.actualizar_reputacion_productor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_productor_objetivo uuid;
  v_promedio numeric(3,2);
  v_cantidad integer;
begin
  v_productor_objetivo := coalesce(new."productor_id", old."productor_id");

  select
    coalesce(round(avg(e."puntaje"), 2), 5.00),
    count(*)::integer
    into v_promedio, v_cantidad
  from public."evaluaciones_reputacion" e
  where e."productor_id" = v_productor_objetivo;

  update public."productores"
     set "puntaje_reputacion" = v_promedio,
         "cantidad_evaluaciones" = v_cantidad
   where "id" = v_productor_objetivo;

  return coalesce(new, old);
end;
$$;

create or replace function public.normalizar_sancion_manual()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
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
        and new."accion" = 'suspender' then
    -- Revisar TODAS las sanciones vigentes (activa o apelada), no solo activa
    select exists (
      select 1
      from public."sanciones" s
      where s."productor_id" = new."productor_id"
        and s."id" <> new."id"
        and s."estado" in ('activa'::public."estado_sancion", 'apelada'::public."estado_sancion")
        and s."accion" in ('suspender', 'ban_permanente')
    ) into v_otra_suspension;

    if not v_otra_suspension then
      update public."productores"
         set "activo" = true
       where "id" = new."productor_id";
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.validar_apelacion()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_productor uuid;
begin
  select s."productor_id"
    into v_productor
  from public."sanciones" s
  where s."id" = new."sancion_id";

  if v_productor is null then
    raise exception 'Sancion inexistente';
  end if;

  if new."productor_id" <> v_productor then
    raise exception 'La apelacion no corresponde al productor de la sancion';
  end if;

  if not (select private.es_admin_actual())
     and new."solicitante_id" <> (select auth.uid()) then
    raise exception 'El solicitante no coincide con el usuario autenticado';
  end if;

  if tg_op = 'INSERT' and new."estado" <> 'pendiente' and not (select private.es_admin_actual()) then
    raise exception 'Una apelacion nueva debe quedar pendiente';
  end if;

  return new;
end;
$$;

create or replace function public.sincronizar_apelacion_sancion_al_crear()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new."estado" = 'pendiente' then
    perform set_config('cutuco.sancion_sync', 'true', true);

    update public."sanciones"
       set "estado" = 'apelada'::public."estado_sancion"
     where "id" = new."sancion_id"
       and "estado" = 'activa'::public."estado_sancion";
  end if;

  return new;
end;
$$;

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
      -- Apelación aceptada: la sanción se cancela
      update public."sanciones"
         set "estado" = 'cancelada'::public."estado_sancion",
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


create or replace function public.validar_datos_bancarios()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new."perfil_id" <> (select auth.uid()) then
    raise exception 'Solo el propietario puede gestionar datos bancarios';
  end if;

  if tg_op = 'UPDATE' and old."perfil_id" is distinct from new."perfil_id" then
    raise exception 'El propietario de los datos bancarios no puede cambiar';
  end if;

  if new."numero_cuenta_cifrado" is null then
    raise exception 'El numero de cuenta cifrado es obligatorio';
  end if;

  return new;
end;
$$;

create or replace function public.proteger_datos_criticos_envio()
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
    if new."pedido_id" is distinct from old."pedido_id"
       or new."repartidor_id" is distinct from old."repartidor_id"
       or new."tarifa_fija" is distinct from old."tarifa_fija" then
      raise exception 'Los datos estructurales del envio son inmutables desde la API directa';
    end if;

    if new."estado" = old."estado" then
      if new."codigo_verificacion" is distinct from old."codigo_verificacion"
         or new."codigo_verificado_en" is distinct from old."codigo_verificado_en"
         or new."despachado_en" is distinct from old."despachado_en"
         or new."entregado_en" is distinct from old."entregado_en"
         or new."fallido_en" is distinct from old."fallido_en"
         or new."motivo_fallo" is distinct from old."motivo_fallo" then
        raise exception 'La trazabilidad del envio solo puede cambiar mediante su maquina de estados o RPC autorizadas';
      end if;
    elsif new."codigo_verificado_en" is distinct from old."codigo_verificado_en" then
      raise exception 'El codigo de entrega solo puede verificarse mediante la RPC autorizada';
    end if;
  end if;

  return new;
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
       or new."total" is distinct from old."total"
       or new."monto_retenido" is distinct from old."monto_retenido"
       or new."monto_liquidar_productor" is distinct from old."monto_liquidar_productor"
       or new."payout_ejecutado_en" is distinct from old."payout_ejecutado_en" then
      raise exception 'Los datos de identidad, snapshot y finanzas del pedido son inmutables desde la API directa';
    end if;
  end if;

  return new;
end;
$$;

-- ============================================================
-- SECCION 13: TRIGGERS
-- ============================================================

create trigger "trg_auth_usuario_creado"
after insert on auth.users
for each row execute function public.manejar_nuevo_usuario();

create trigger "trg_proteger_admin_base"
before update or delete on public."perfiles"
for each row execute function public.proteger_admin_base();

create trigger "trg_validar_seguridad_perfil"
before update on public."perfiles"
for each row execute function public.validar_cambios_seguridad_perfil();

create trigger "trg_validar_estado_postulacion"
before update of "estado" on public."postulaciones_vendedores"
for each row execute function public.validar_postulacion_estado();

create trigger "trg_activar_productor_aprobado"
after update of "estado" on public."postulaciones_vendedores"
for each row execute function public.activar_productor_aprobado();

create trigger "trg_validar_direccion"
before insert or update or delete on public."direcciones"
for each row execute function public.validar_direccion();

create trigger "trg_generar_slug_productor"
before insert on public."productores"
for each row execute function public.generar_slug_productor();

create trigger "trg_generar_slug_producto"
before insert on public."productos"
for each row execute function public.generar_slug_producto();

create trigger "trg_validar_jerarquia_categoria"
before insert or update of "categoria_padre_id" on public."categorias"
for each row execute function public.validar_jerarquia_categoria();

create trigger "trg_categoria_soft_delete"
before update of "eliminado_en" on public."categorias"
for each row execute function public.reasignar_categoria_eliminada();

create trigger "trg_moderar_producto"
before insert or update of "nombre", "descripcion" on public."productos"
for each row execute function public.validar_texto_moderado();

create trigger "trg_moderar_productor"
before insert or update of "nombre_comercial", "descripcion" on public."productores"
for each row execute function public.validar_texto_moderado();

create trigger "trg_moderar_postulacion"
before insert or update of "nombre_comercial_solicitado", "descripcion" on public."postulaciones_vendedores"
for each row execute function public.validar_texto_moderado();

create trigger "trg_moderar_evaluacion"
before insert or update of "comentario" on public."evaluaciones_reputacion"
for each row execute function public.validar_texto_moderado();

create trigger "trg_moderar_reclamo"
before insert or update of "motivo", "descripcion", "respuesta_productor" on public."reclamos"
for each row execute function public.validar_texto_moderado();

create trigger "trg_moderar_apelacion"
before insert or update of "fundamento" on public."apelaciones"
for each row execute function public.validar_texto_moderado();

create trigger "trg_validar_cobertura_pedido"
before insert or update of "productor_id", "region_entrega_id", "comuna_entrega_id"
on public."pedidos"
for each row execute function public.validar_cobertura_pedido();

create trigger "trg_validar_detalle_pedido"
before insert or update on public."detalles_pedido"
for each row execute function public.validar_detalle_pedido();

create trigger "trg_recalcular_totales_pedido"
after insert or update or delete on public."detalles_pedido"
for each row execute function public.trg_recalcular_totales_pedido();

create trigger "trg_validar_transicion_pedido"
before update of "estado" on public."pedidos"
for each row execute function public.validar_transicion_pedido();

create trigger "trg_crear_envio_al_pagar"
after update of "estado" on public."pedidos"
for each row execute function public.crear_envio_al_pagar();

create trigger "trg_proteger_campos_criticos_pedido"
before update on public."pedidos"
for each row execute function public.proteger_campos_criticos_pedido();

create trigger "trg_validar_repartidor_envio"
before insert on public."envios"
for each row execute function public.validar_repartidor_envio();

create trigger "trg_validar_transicion_envio"
before update on public."envios"
for each row execute function public.validar_transicion_envio();

create trigger "trg_proteger_datos_criticos_envio"
before update on public."envios"
for each row execute function public.proteger_datos_criticos_envio();

create trigger "trg_sincronizar_envio_entregado"
after update of "estado" on public."envios"
for each row execute function public.sincronizar_envio_entregado();

create trigger "trg_validar_transicion_pago"
before update of "estado" on public."pagos"
for each row execute function public.validar_transicion_pago();

create trigger "trg_sincronizar_escrow_pago"
after update of "estado" on public."pagos"
for each row execute function public.sincronizar_escrow_pago();

create trigger "trg_crear_payout_al_completar"
after update of "estado" on public."pedidos"
for each row execute function public.crear_payout_al_completar();

create trigger "trg_validar_payout"
before insert or update on public."payouts"
for each row execute function public.validar_payout();

create trigger "trg_sincronizar_payout_pedido"
after update of "estado" on public."payouts"
for each row execute function public.sincronizar_payout_pedido();

create trigger "trg_validar_reclamo"
before insert or update on public."reclamos"
for each row execute function public.validar_reclamo();

create trigger "trg_validar_evaluacion"
before insert on public."evaluaciones_reputacion"
for each row execute function public.validar_evaluacion_pedido();

create trigger "trg_actualizar_reputacion"
after insert or update or delete on public."evaluaciones_reputacion"
for each row execute function public.actualizar_reputacion_productor();

create trigger "trg_normalizar_sancion_manual"
before insert or update on public."sanciones"
for each row execute function public.normalizar_sancion_manual();

create trigger "trg_aplicar_efecto_sancion"
after insert or update of "accion", "estado" on public."sanciones"
for each row execute function public.aplicar_efecto_sancion();

create trigger "trg_validar_apelacion"
before insert or update on public."apelaciones"
for each row execute function public.validar_apelacion();

create trigger "trg_apelar_sancion_al_crear"
after insert on public."apelaciones"
for each row execute function public.sincronizar_apelacion_sancion_al_crear();

create trigger "trg_resolver_apelacion_sancion"
after update of "estado" on public."apelaciones"
for each row execute function public.sincronizar_apelacion_sancion_al_resolver();

create trigger "trg_validar_datos_bancarios"
before insert or update on public."datos_bancarios"
for each row execute function public.validar_datos_bancarios();

create trigger "trg_actualizado_en_regiones"
before update on public."regiones"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_comunas"
before update on public."comunas"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_perfiles"
before update on public."perfiles"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_direcciones"
before update on public."direcciones"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_postulaciones_vendedores"
before update on public."postulaciones_vendedores"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_productores"
before update on public."productores"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_datos_bancarios"
before update on public."datos_bancarios"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_categorias"
before update on public."categorias"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_productos"
before update on public."productos"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_imagenes_productos"
before update on public."imagenes_productos"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_configuracion_logistica"
before update on public."configuracion_logistica"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_palabras_prohibidas"
before update on public."palabras_prohibidas"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_pedidos"
before update on public."pedidos"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_envios"
before update on public."envios"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_detalles_pedido"
before update on public."detalles_pedido"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_payouts"
before update on public."payouts"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_reclamos"
before update on public."reclamos"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_evaluaciones_reputacion"
before update on public."evaluaciones_reputacion"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_sanciones"
before update on public."sanciones"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_actualizado_en_apelaciones"
before update on public."apelaciones"
for each row execute function public.actualizar_actualizado_en();

create trigger "trg_proteger_campos_reclamo"
before update on public."reclamos"
for each row execute function public.proteger_campos_reclamo();

create trigger "trg_proteger_campos_operativos_productor"
before update on public."productores"
for each row execute function public.proteger_campos_operativos_productor();

-- ============================================================
-- SECCION 14: RLS POLICIES
-- ============================================================

alter table public."regiones" enable row level security;
alter table public."comunas" enable row level security;
alter table public."perfiles" enable row level security;
alter table public."direcciones" enable row level security;
alter table public."postulaciones_vendedores" enable row level security;
alter table public."productores" enable row level security;
alter table public."datos_bancarios" enable row level security;
alter table public."categorias" enable row level security;
alter table public."productos" enable row level security;
alter table public."imagenes_productos" enable row level security;
alter table public."configuracion_logistica" enable row level security;
alter table public."pedidos" enable row level security;
alter table public."envios" enable row level security;
alter table public."detalles_pedido" enable row level security;
alter table public."pagos" enable row level security;
alter table public."payouts" enable row level security;
alter table public."reclamos" enable row level security;
alter table public."evaluaciones_reputacion" enable row level security;
alter table public."sanciones" enable row level security;
alter table public."apelaciones" enable row level security;
alter table public."palabras_prohibidas" enable row level security;

create policy "regiones_select_publico"
  on public."regiones" for select to anon, authenticated using (true);

create policy "regiones_admin_insert"
  on public."regiones" for insert to authenticated
  with check ((select private.es_admin_actual()));

create policy "regiones_admin_update"
  on public."regiones" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "regiones_admin_delete"
  on public."regiones" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "comunas_select_publico"
  on public."comunas" for select to anon, authenticated using (true);

create policy "comunas_admin_insert"
  on public."comunas" for insert to authenticated
  with check ((select private.es_admin_actual()));

create policy "comunas_admin_update"
  on public."comunas" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "comunas_admin_delete"
  on public."comunas" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "perfiles_select_propio_admin"
  on public."perfiles" for select to authenticated
  using ("id" = (select auth.uid()) or (select private.es_admin_actual()));

create policy "perfiles_insert_propio_cliente"
  on public."perfiles" for insert to authenticated
  with check ("id" = (select auth.uid()) and "rol" = 'cliente');

create policy "perfiles_update_propio_admin"
  on public."perfiles" for update to authenticated
  using ("id" = (select auth.uid()) or (select private.es_admin_actual()))
  with check ("id" = (select auth.uid()) or (select private.es_admin_actual()));

create policy "perfiles_delete_admin_no_protegidos"
  on public."perfiles" for delete to authenticated
  using ((select private.es_admin_actual()) and not "es_protegido" and not "es_super_admin");

create policy "direcciones_select_propias_admin"
  on public."direcciones" for select to authenticated
  using ("perfil_id" = (select auth.uid()) or (select private.es_admin_actual()));

create policy "direcciones_insert_propias"
  on public."direcciones" for insert to authenticated
  with check ("perfil_id" = (select auth.uid()));

create policy "direcciones_update_propias"
  on public."direcciones" for update to authenticated
  using ("perfil_id" = (select auth.uid()))
  with check ("perfil_id" = (select auth.uid()));

create policy "direcciones_delete_propias"
  on public."direcciones" for delete to authenticated
  using ("perfil_id" = (select auth.uid()));

create policy "postulaciones_select_propia_admin"
  on public."postulaciones_vendedores" for select to authenticated
  using ((select private.puede_acceder_postulacion("id")));

drop policy if exists "postulaciones_insert_cliente" on public."postulaciones_vendedores";
create policy "postulaciones_insert_cliente"
  on public."postulaciones_vendedores" for insert to authenticated
  with check (
    "perfil_id" = (select auth.uid())
    and "estado" = 'pendiente_aprobacion'::public."estado_postulacion_vendedor"
    and "revisado_por" is null
    and "revisado_en" is null
    and exists (
      select 1 from public."perfiles" p
      where p."id" = (select auth.uid())
        and p."rol" = 'cliente'::public."rol_usuario"
        and p."activo" = true
    )
  );

create policy "postulaciones_update_propias_admin"
  on public."postulaciones_vendedores" for update to authenticated
  using ("perfil_id" = (select auth.uid()) or (select private.es_admin_actual()))
  with check ("perfil_id" = (select auth.uid()) or (select private.es_admin_actual()));

create policy "postulaciones_delete_admin"
  on public."postulaciones_vendedores" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "productores_select_publico_activos"
  on public."productores" for select to anon, authenticated
  using ("activo" = true);

create policy "productores_select_propio_admin"
  on public."productores" for select to authenticated
  using ("perfil_id" = (select auth.uid()) or (select private.es_admin_actual()) or "activo" = true);

create policy "productores_insert_admin"
  on public."productores" for insert to authenticated
  with check ((select private.es_admin_actual()));

create policy "productores_update_propio_admin"
  on public."productores" for update to authenticated
  using ("perfil_id" = (select auth.uid()) or (select private.es_admin_actual()))
  with check ("perfil_id" = (select auth.uid()) or (select private.es_admin_actual()));

create policy "productores_delete_admin"
  on public."productores" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "datos_bancarios_select_propios"
  on public."datos_bancarios" for select to authenticated
  using ((select private.puede_acceder_datos_bancarios("perfil_id")));

create policy "datos_bancarios_insert_propio"
  on public."datos_bancarios" for insert to authenticated
  with check ("perfil_id" = (select auth.uid()));

create policy "datos_bancarios_update_propio"
  on public."datos_bancarios" for update to authenticated
  using ("perfil_id" = (select auth.uid()))
  with check ("perfil_id" = (select auth.uid()));

create policy "datos_bancarios_delete_propio"
  on public."datos_bancarios" for delete to authenticated
  using ("perfil_id" = (select auth.uid()));

create policy "categorias_select_publico_activas"
  on public."categorias" for select to anon, authenticated
  using ("eliminado_en" is null);

create policy "categorias_insert_admin"
  on public."categorias" for insert to authenticated
  with check ((select private.es_admin_actual()));

create policy "categorias_update_admin"
  on public."categorias" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "categorias_delete_admin_no_sistema"
  on public."categorias" for delete to authenticated
  using ((select private.es_admin_actual()) and not "es_sistema");

create policy "productos_select_publico"
  on public."productos" for select to anon, authenticated
  using ("activo" = true and "eliminado_en" is null);

create policy "productos_insert_vendedor"
  on public."productos" for insert to authenticated
  with check (
    (select private.es_productor_actual("productor_id"))
    and "activo" = true
    and "eliminado_en" is null
  );

create policy "productos_select_vendedor_admin"
  on public."productos" for select to authenticated
  using (
    (select private.es_productor_actual("productor_id"))
    or ("activo" = true and "eliminado_en" is null)
    or (select private.es_admin_actual())
  );

create policy "productos_update_vendedor_admin"
  on public."productos" for update to authenticated
  using ((select private.es_productor_actual("productor_id")) or (select private.es_admin_actual()))
  with check ((select private.es_productor_actual("productor_id")) or (select private.es_admin_actual()));

create policy "productos_delete_admin"
  on public."productos" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "imagenes_productos_select_publico"
  on public."imagenes_productos" for select to anon, authenticated
  using (exists (
    select 1 from public."productos" p
    where p."id" = "producto_id"
      and p."activo" = true
      and p."eliminado_en" is null
  ));

create policy "imagenes_productos_insert_vendedor_admin"
  on public."imagenes_productos" for insert to authenticated
  with check (
    (select private.es_productor_actual_de_producto("producto_id"))
    or (select private.es_admin_actual())
  );

create policy "imagenes_productos_update_vendedor_admin"
  on public."imagenes_productos" for update to authenticated
  using (
    (select private.es_productor_actual_de_producto("producto_id"))
    or (select private.es_admin_actual())
  )
  with check (
    (select private.es_productor_actual_de_producto("producto_id"))
    or (select private.es_admin_actual())
  );

create policy "imagenes_productos_delete_vendedor_admin"
  on public."imagenes_productos" for delete to authenticated
  using (
    (select private.es_productor_actual_de_producto("producto_id"))
    or (select private.es_admin_actual())
  );

create policy "configuracion_logistica_select_autenticados"
  on public."configuracion_logistica" for select to authenticated
  using (true);

create policy "configuracion_logistica_select_anon"
  on public."configuracion_logistica" for select to anon
  using (true);

create policy "configuracion_logistica_admin_write"
  on public."configuracion_logistica" for all to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "pedidos_select_participantes"
  on public."pedidos" for select to authenticated
  using ((select private.puede_acceder_pedido("id")));

create policy "pedidos_insert_service_only"
  on public."pedidos" for insert to authenticated
  with check (current_user = 'service_role');

create policy "pedidos_update_admin"
  on public."pedidos" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "pedidos_delete_admin"
  on public."pedidos" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "envios_select_participantes"
  on public."envios" for select to authenticated
  using ((select private.puede_acceder_envio("id")));

create policy "envios_update_productor_admin"
  on public."envios" for update to authenticated
  using (
    (select private.es_admin_actual())
    or exists (
      select 1
      from public."pedidos" p
      join public."productores" pr on pr."id" = p."productor_id"
      where p."id" = "pedido_id"
        and pr."perfil_id" = (select auth.uid())
    )
  )
  with check (
    (select private.es_admin_actual())
    or exists (
      select 1
      from public."pedidos" p
      join public."productores" pr on pr."id" = p."productor_id"
      where p."id" = "pedido_id"
        and pr."perfil_id" = (select auth.uid())
    )
  );

create policy "detalles_pedido_select_participantes"
  on public."detalles_pedido" for select to authenticated
  using ((select private.puede_acceder_pedido("pedido_id")));

create policy "detalles_pedido_admin_write"
  on public."detalles_pedido" for all to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "pagos_select_admin"
  on public."pagos" for select to authenticated
  using ((select private.es_admin_actual()));

create policy "pagos_write_admin"
  on public."pagos" for all to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "payouts_select_beneficiario_admin"
  on public."payouts" for select to authenticated
  using ((select private.puede_acceder_payout("id")));

create policy "payouts_insert_admin"
  on public."payouts" for insert to authenticated
  with check ((select private.es_admin_actual()));

create policy "payouts_update_admin"
  on public."payouts" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "payouts_delete_admin"
  on public."payouts" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "reclamos_select_participantes"
  on public."reclamos" for select to authenticated
  using (
    "cliente_id" = (select auth.uid())
    or exists (
      select 1
      from public."pedidos" p
      join public."productores" pr on pr."id" = p."productor_id"
      where p."id" = "pedido_id"
        and pr."perfil_id" = (select auth.uid())
    )
    or (select private.es_admin_actual())
  );

create policy "reclamos_insert_cliente"
  on public."reclamos" for insert to authenticated
  with check (
    "cliente_id" = (select auth.uid())
    and exists (
      select 1 from public."pedidos" p
      where p."id" = "pedido_id"
        and p."cliente_id" = (select auth.uid())
    )
  );

drop policy if exists "reclamos_update_productor_admin" on public."reclamos";
create policy "reclamos_update_productor_admin"
  on public."reclamos" for update to authenticated
  using (
    (select private.es_admin_actual())
    or exists (
      select 1
      from public."pedidos" p
      join public."productores" pr on pr."id" = p."productor_id"
      where p."id" = "pedido_id"
        and pr."perfil_id" = (select auth.uid())
    )
  )
  with check (
    (select private.es_admin_actual())
    or exists (
      select 1
      from public."pedidos" p
      join public."productores" pr on pr."id" = p."productor_id"
      where p."id" = "pedido_id"
        and pr."perfil_id" = (select auth.uid())
    )
  );

create policy "reclamos_delete_admin"
  on public."reclamos" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "evaluaciones_select_propio_admin"
  on public."evaluaciones_reputacion" for select to authenticated
  using (
    "cliente_id" = (select auth.uid())
    or (select private.es_productor_actual("productor_id"))
    or (select private.es_admin_actual())
  );

create policy "evaluaciones_insert_cliente"
  on public."evaluaciones_reputacion" for insert to authenticated
  with check (
    "cliente_id" = (select auth.uid())
    and exists (
      select 1 from public."pedidos" p
      where p."id" = "pedido_id"
        and p."cliente_id" = (select auth.uid())
        and p."estado" in ('completado', 'reclamado')
    )
  );

create policy "evaluaciones_update_admin"
  on public."evaluaciones_reputacion" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "evaluaciones_delete_admin"
  on public."evaluaciones_reputacion" for delete to authenticated
  using ((select private.es_admin_actual()));

drop policy if exists "sanciones_select_productor_admin" on public."sanciones";
create policy "sanciones_select_productor_admin"
  on public."sanciones" for select to authenticated
  using (
    (select private.es_admin_actual())
    or (select private.es_productor_propietario("productor_id"))
  );

create policy "sanciones_insert_admin"
  on public."sanciones" for insert to authenticated
  with check ((select private.es_admin_actual()));

create policy "sanciones_update_admin"
  on public."sanciones" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "sanciones_delete_admin"
  on public."sanciones" for delete to authenticated
  using ((select private.es_admin_actual()));

drop policy if exists "apelaciones_select_propias_admin" on public."apelaciones";
create policy "apelaciones_select_propias_admin"
  on public."apelaciones" for select to authenticated
  using (
    "solicitante_id" = (select auth.uid())
    or (select private.es_productor_propietario("productor_id"))
    or (select private.es_admin_actual())
  );

drop policy if exists "apelaciones_insert_vendedor" on public."apelaciones";
create policy "apelaciones_insert_vendedor"
  on public."apelaciones" for insert to authenticated
  with check (
    "solicitante_id" = (select auth.uid())
    and (select private.es_productor_propietario("productor_id"))
  );

create policy "apelaciones_update_admin"
  on public."apelaciones" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "apelaciones_delete_admin"
  on public."apelaciones" for delete to authenticated
  using ((select private.es_admin_actual()));

create policy "palabras_prohibidas_select_admin"
  on public."palabras_prohibidas" for select to authenticated
  using ((select private.es_admin_actual()));

create policy "palabras_prohibidas_insert_admin"
  on public."palabras_prohibidas" for insert to authenticated
  with check ((select private.es_admin_actual()));

create policy "palabras_prohibidas_update_admin"
  on public."palabras_prohibidas" for update to authenticated
  using ((select private.es_admin_actual()))
  with check ((select private.es_admin_actual()));

create policy "palabras_prohibidas_delete_admin"
  on public."palabras_prohibidas" for delete to authenticated
  using ((select private.es_admin_actual()));

-- ============================================================
-- STORAGE: SOLO PRODUCT-IMAGES
-- El schema storage debe existir en Supabase/Supabase CLI.
-- El bucket se registra aqui para que la migracion sea autocontenida.
-- No se crean buckets logisticos o de documentos en el nuevo alcance.
-- ============================================================

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do update
set name = excluded.name,
    public = excluded.public;

create policy "storage_product_images_select_public"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'product-images');

create policy "storage_product_images_insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'product-images'
    and (
      (select private.es_admin_actual())
      or (select private.es_productor_actual_de_producto((storage.foldername(name))[1]::uuid))
    )
  );

create policy "storage_product_images_update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'product-images'
    and (
      (select private.es_admin_actual())
      or (select private.es_productor_actual_de_producto((storage.foldername(name))[1]::uuid))
    )
  )
  with check (
    bucket_id = 'product-images'
    and (
      (select private.es_admin_actual())
      or (select private.es_productor_actual_de_producto((storage.foldername(name))[1]::uuid))
    )
  );

create policy "storage_product_images_delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'product-images'
    and (
      (select private.es_admin_actual())
      or (select private.es_productor_actual_de_producto((storage.foldername(name))[1]::uuid))
    )
  );

-- ============================================================
-- SECCION 15: GRANTS
-- ============================================================

revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;

grant usage on schema public to anon, authenticated, service_role;

grant usage on schema private to authenticated;
grant usage on schema private to service_role;
grant execute on all functions in schema private to service_role;
grant execute on all functions in schema public to service_role;

grant usage on type public."rol_usuario" to postgres, service_role, authenticated;
grant usage on type public."estado_postulacion_vendedor" to postgres, service_role, authenticated;
grant usage on type public."unidad_medida_producto" to postgres, service_role, authenticated;
grant usage on type public."estado_pedido" to postgres, service_role, authenticated;
grant usage on type public."estado_pago" to postgres, service_role, authenticated;
grant usage on type public."estado_envio" to postgres, service_role, authenticated;
grant usage on type public."estado_reclamo" to postgres, service_role, authenticated;
grant usage on type public."tipo_sancion" to postgres, service_role, authenticated;
grant usage on type public."accion_sancion" to postgres, service_role, authenticated;
grant usage on type public."estado_sancion" to postgres, service_role, authenticated;
grant usage on type public."estado_apelacion" to postgres, service_role, authenticated;
grant usage on type public."tipo_payout" to postgres, service_role, authenticated;
grant usage on type public."estado_payout" to postgres, service_role, authenticated;

-- Catalogo, geografia y tarifa visibles para visitante.
grant select on public."regiones", public."comunas", public."categorias", public."productores", public."productos", public."imagenes_productos", public."configuracion_logistica" to anon;
grant select on public."regiones", public."comunas", public."categorias", public."productores", public."productos", public."imagenes_productos", public."configuracion_logistica" to authenticated;

-- Operaciones de usuario controladas por RLS.
grant select, insert, update, delete on public."perfiles" to authenticated;
grant select, insert, update, delete on public."direcciones" to authenticated;
grant select, insert, update, delete on public."postulaciones_vendedores" to authenticated;
grant select, insert, update, delete on public."datos_bancarios" to authenticated;
grant select, insert, update, delete on public."productos" to authenticated;
grant select, insert, update, delete on public."imagenes_productos" to authenticated;
grant select, insert, update, delete on public."reclamos" to authenticated;
grant select, insert, update, delete on public."evaluaciones_reputacion" to authenticated;
grant select, insert, update, delete on public."sanciones" to authenticated;
grant select, insert, update, delete on public."apelaciones" to authenticated;
grant select, insert, update, delete on public."palabras_prohibidas" to authenticated;

grant select, update on public."productores" to authenticated;
grant select on public."pedidos", public."envios", public."detalles_pedido", public."pagos" to authenticated;
grant select, insert, update, delete on public."payouts" to authenticated;
grant select, insert, update, delete on public."configuracion_logistica" to authenticated;

-- Service role: backend de confianza FastAPI/Cloud Run.
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

-- RPC para clientes/admins.
revoke all on all functions in schema public from public, anon, authenticated;

revoke all on function public.verificar_codigo_entrega(uuid, text) from public, anon;
grant execute on function public.verificar_codigo_entrega(uuid, text) to authenticated;

revoke all on function public.confirmar_recepcion_pedido(uuid) from public, anon;
grant execute on function public.confirmar_recepcion_pedido(uuid) to authenticated;

revoke all on function public.registrar_payout_pagado(uuid, text, text) from public, anon;
grant execute on function public.registrar_payout_pagado(uuid, text, text) to authenticated;

revoke all on function public.registrar_devolucion_cliente(uuid, numeric, text, boolean) from public, anon;
grant execute on function public.registrar_devolucion_cliente(uuid, numeric, text, boolean) to authenticated;

revoke all on function public.obtener_tarifa_delivery_defecto() from public, anon, authenticated;
grant execute on function public.obtener_tarifa_delivery_defecto() to service_role;

revoke all on function public.generar_codigo_verificacion() from public, anon;
grant execute on function public.generar_codigo_verificacion() to authenticated, service_role;

grant execute on function private.es_productor_propietario(uuid) to authenticated;


revoke all on function public.contiene_palabra_prohibida(text) from public, anon, authenticated;
revoke all on function public.validar_texto_moderado() from public, anon, authenticated;
revoke all on function public.normalizar_slug(text, text) from public, anon, authenticated;
revoke all on function public.generar_slug_producto() from public, anon, authenticated;
revoke all on function public.generar_slug_productor() from public, anon, authenticated;
revoke all on function public.actualizar_actualizado_en() from public, anon, authenticated;

-- ============================================================
-- SECCION 16: COMENTARIOS
-- ============================================================

comment on table public."perfiles" is
'Perfil de negocio vinculado 1:1 con auth.users. El auto-registro siempre nace como cliente; FastAPI gestiona bloqueo por intentos fallidos y validacion RBAC. RF-001, RF-004, RF-020, RF-023 y RF-024.';

comment on column public."perfiles"."rol" is
'Rol de negocio: cliente, vendedor o admin. La aprobacion de la postulacion promueve la cuenta a vendedor. RF-001 y RF-021.';

comment on column public."perfiles"."activo" is
'Estado operativo de la cuenta. La cuenta Administrador Base queda protegida frente a modificaciones ordinarias. RF-004 y RF-013.';

comment on table public."direcciones" is
'Plantillas editables de direccion del usuario, sin versionado. Un cliente puede tener varias direcciones; un productor aprobado debe conservar exactamente una direccion activa. El pedido copia un snapshot de la direccion y no mantiene FK a esta tabla. RF-002, RF-003, RF-009, RF-025.';

comment on column public."direcciones"."activo" is
'Indica si la plantilla puede ser seleccionada. Para productores se mantiene exactamente una direccion activa por cuenta.';

comment on table public."productores" is
'Entidad de tienda/productor derivada de una cuenta aprobada como vendedor. La region operativa del productor se obtiene de su unica direccion activa. RF-003, RF-004, RF-006 y RF-009.';

comment on column public."productores"."slug" is
'Identificador amigable para URL y busqueda publica. Se genera automaticamente y se deduplica mediante sufijo numerico.';

comment on table public."postulaciones_vendedores" is
'Postulacion de una cuenta cliente para convertirse en vendedor. No requiere documentos de identidad en el nuevo alcance; la verificacion de antecedentes es manual por administracion. RF-004 y RF-021.';

comment on table public."pedidos" is
'Orden comercial del cliente. Guarda snapshot de direccion, comuna y region al momento del checkout para que cambios posteriores en direcciones no alteren el historico. Los montos financieros quedan protegidos por constraints y triggers. RF-002, RF-005, RF-009 y RF-025.';

comment on column public."pedidos"."direccion_entrega" is
'Snapshot textual de la direccion seleccionada al comprar. No tiene FK a direcciones y no cambia cuando el cliente edita su plantilla.';

comment on column public."pedidos"."comuna_entrega_id" is
'Comuna del snapshot de entrega. Se usa junto con region_entrega_id para mantener la referencia territorial historica del pedido.';

comment on column public."pedidos"."region_entrega_id" is
'Region del snapshot de entrega. La cobertura se valida contra la region de la unica direccion activa del productor. RF-009.';

comment on column public."pedidos"."monto_retenido" is
'Monto bajo custodia del marketplace. Cutuco retiene el 100 por ciento del pago Webpay hasta el payout manual al productor o el reembolso aprobado.';

comment on column public."pedidos"."payout_ejecutado_en" is
'Fecha en que el payout de pago_productor fue registrado como pagado por un administrador. RF-005.';

comment on table public."envios" is
'Entidad logistica desacoplada de la orden comercial. En el MVP cada pedido tiene un envio y el productor es el repartidor. El ciclo fisico se controla aqui y la entrega sincroniza el pedido a completado. RF-025.';

comment on column public."envios"."codigo_verificacion" is
'Codigo de entrega de hasta 12 caracteres generado al iniciar el transito. Sustituye la evidencia fotografica del alcance anterior. RF-007 y RF-025.';

comment on column public."envios"."fallido_en" is
'Fecha en que el envio pasa a fallido.';

comment on column public."envios"."motivo_fallo" is
'Motivo obligatorio cuando el envio se marca como fallido, utilizado para trazabilidad operacional. RF-025.';

comment on table public."pagos" is
'Pago Webpay Plus normal asociado 1:1 al pedido. El marketplace retiene el 100 por ciento hasta que el payout al productor se registra como pagado; las devoluciones usan payouts y luego marcan el pago como reembolsado. RF-005.';

comment on table public."payouts" is
'Registro unificado de pagos al productor, devoluciones al cliente, reembolsos parciales y ajustes manuales. El beneficiario siempre es un perfil y solo los ajustes manuales pueden no tener pedido asociado. RF-005 y RF-004.';

comment on column public."payouts"."comprobante_ruta" is
'Ruta opcional para un futuro comprobante de transferencia bancaria. En el MVP el comprobante puede enviarse por Resend y se conserva la referencia externa y las notas; no existe bucket especifico.';

comment on table public."datos_bancarios" is
'Datos bancarios compartidos por perfiles para futuras salidas de dinero. Solo el propio titular puede ver y modificar sus datos mediante RLS y trigger. numero_cuenta_cifrado es bytea y el cifrado/descifrado lo gestiona FastAPI.';

comment on table public."reclamos" is
'Registro de disputa del cliente para trazabilidad. No modifica automaticamente el estado del pedido ni ejecuta decisiones financieras; el admin puede resolver mediante los flujos de payout. RF-026 y modulo de reclamos.';

comment on table public."evaluaciones_reputacion" is
'Calificacion simple de 1 a 5 por pedido. El productor mantiene un promedio acumulado y no existe ponderacion ni sancion automatica por reputacion. RF-006.';

comment on column public."evaluaciones_reputacion"."puntaje" is
'Puntaje entero entre 1 y 5 otorgado por el cliente por pedido.';

comment on table public."sanciones" is
'Sanciones manuales administradas por un admin. Las amonestaciones se numeran por productor; las suspensiones tienen duracion y ban_permanente desactiva permanentemente la cuenta. RF-026.';

comment on column public."sanciones"."accion" is
'Accion operativa manual: ninguna para amonestacion, suspender para suspension temporal y ban_permanente para bloqueo permanente.';

comment on table public."apelaciones" is
'Apelacion formal del vendedor contra una sancion. Una apelacion pendiente cambia la sancion a apelada; una aprobada la cancela y una rechazada la marca como resuelta. RF-026.';

comment on table public."palabras_prohibidas" is
'Lista administrable de terminos prohibidos. La funcion generica contiene_palabra_prohibida usa LIKE case-insensitive y se aplica a productos, productores, postulaciones, evaluaciones, reclamos y apelaciones. RF-004.';

comment on table public."configuracion_logistica" is
'Configuracion singleton del parametro base de delivery. La tarifa por defecto es 3500 CLP y se congela en pedidos y envios. RF-014 y RF-025.';

comment on table public."productos" is
'Catalogo del productor con slug, nombre, descripcion, precio, stock, unidad de medida y fecha de cosecha informativa. El alcance vigente no incluye alerta de stock bajo ni sello dinamico de cosecha del dia. RF-003, RF-010 y RF-006.';

comment on column public."productos"."slug" is
'Identificador amigable para URL y busqueda publica. Se genera automaticamente desde el nombre si viene vacio y se deduplica mediante sufijo numerico.';

comment on table public."categorias" is
'Categorias y subcategorias jerarquicas. El soft delete reasigna productos afectados y descendientes a Sin Categoria. RF-004 y RF-017.';

comment on table public."imagenes_productos" is
'Metadatos de imagenes del catalogo. Los objetos se almacenan en el bucket publico product-images y su acceso de escritura se controla con RLS sobre storage.objects. RF-003 y RF-022.';

-- ============================================================
-- CHANGELOG DE ESTA REVISION
-- ============================================================

-- 1. Se reemplazo la cobertura N:M por direcciones editables y validacion regional.
-- 2. Los pedidos ahora conservan snapshot de direccion, comuna y region.
-- 3. Se elimino toda dependencia estructural de coberturas por productor.
-- 4. Se restauraron fallido_en y motivo_fallo en envios.
-- 5. La moderacion con blacklist se generalizo a productos, productores,
--    postulaciones, evaluaciones, reclamos y apelaciones.
-- 6. Las apelaciones ahora sincronizan el estado de sanciones.
-- 7. Las sanciones manuales revierten suspensiones segun sanciones activas,
--    mientras ban_permanente nunca reactiva la cuenta.
-- 8. Se agregaron constraints financieros de coherencia y un unico reclamo abierto por pedido.
-- 9. Se ampliaron los estados de payout y sus indices operativos.
-- 10. Se agregaron slugs para productos y productores con deduplicacion numerica.
-- 11. Los datos bancarios quedan visibles y editables solo por el titular.
-- 12. Se preservo product-images como unico bucket del alcance vigente.
-- 13. Se mantuvo el payout manual y se elimino cualquier liberacion automatica o programada.
-- 14. No se inventaron seis campos financieros adicionales en productores: el alcance entregado no define sus nombres, tipos ni semantica; los campos financieros existentes y exigidos se mantienen en pedidos y payouts.

-- ============================================================
-- FIN DEL DDL
-- ============================================================
