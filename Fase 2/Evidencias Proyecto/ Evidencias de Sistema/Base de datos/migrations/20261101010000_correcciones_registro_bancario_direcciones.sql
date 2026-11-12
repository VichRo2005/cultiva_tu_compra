-- Correcciones BACKEND/BD de la iteración de auditoría (2026-11).
--
-- Cubre, en una sola migración posterior a 20261031000000:
--   * HAL-REG-001/004/006: teléfono obligatorio, dirección con número
--     opcional/alfanumérico, depto_oficina y referencia opcionales.
--   * HAL-REG-012/013/014: cuenta bancaria de 7 a 12 dígitos conservada como
--     texto, unicidad compuesta y prohibición de cuentas de terceros.
--   * REG-CLI-017/REG-CONF-001: el alta de Auth crea perfil, dirección y
--     borrador de postulación desde la metadata, de forma tolerante.
--   * HAL-VEN-005: slug del nombre comercial tolerante a símbolos y colisiones.
--   * HAL-VEN-014/026: pausa del productor con justificación por defecto y
--     límites numéricos de producto documentados.
--   * HAL-VEN-016: intento de edición de producto ajeno devuelve 403 funcional
--     (SQLSTATE 42501) en lugar de PGRST116.
--   * HAL-CLI-021/HAL-VEN-006: se oculta el árbol "Alimentos para mascotas" y
--     se eliminan duplicados de categorías sin borrar historial.
--   * HAL-CLI-022: se retira el acceso activo a la tabla histórica de
--     evidencias.
--   * HAL-VEN-019: se persiste emitido_en y vence_en = emitido_en + 10.
--
-- No edita migraciones anteriores. Es idempotente en lo posible para poder
-- ensayarse con db reset.

begin;

-- ============================================================================
-- A) DATOS BANCARIOS
-- ============================================================================

alter table public."datos_bancarios"
  add column if not exists "numero_cuenta_hash" bytea,
  add column if not exists "numero_cuenta_digitos" smallint;

comment on column public."datos_bancarios"."numero_cuenta_hash" is
  'HMAC-SHA256 del número normalizado, calculado por el backend con BANK_ENCRYPTION_KEY. Permite detectar duplicados sin guardar el número en claro.';
comment on column public."datos_bancarios"."numero_cuenta_digitos" is
  'Cantidad de dígitos del número de cuenta (7..12). El número en sí viaja cifrado y nunca se expone en logs.';

alter table public."datos_bancarios"
  add constraint "ck_dato_bancario_hash_largo" check (
    "numero_cuenta_hash" is null or octet_length("numero_cuenta_hash") = 32
  ),
  add constraint "ck_dato_bancario_digitos" check (
    "numero_cuenta_digitos" is null or "numero_cuenta_digitos" between 7 and 12
  ),
  add constraint "ck_dato_bancario_hash_coherente" check (
    "numero_cuenta_hash" is null or "numero_cuenta_digitos" is not null
  );

-- Unicidad compuesta: banco + tipo de cuenta + número normalizado + RUT
-- normalizado del titular. Solo entre cuentas activas y solo cuando el
-- backend entregó la huella (las filas legacy sin huella no bloquean).
create unique index if not exists "uq_datos_bancarios_cuenta_duplicada"
  on public."datos_bancarios" (
    lower(btrim("banco")),
    lower(replace(btrim("tipo_cuenta"), ' ', '_')),
    "numero_cuenta_hash",
    upper(replace(btrim("rut_titular"), '.', ''))
  )
  where "activo" and "numero_cuenta_hash" is not null;

comment on index public."uq_datos_bancarios_cuenta_duplicada" is
  'HAL-REG-013: impide registrar dos veces la misma cuenta (banco+tipo+número+RUT del titular) entre cuentas activas.';

-- Normalización de nombres para comparar titular vs. postulante sin depender
-- de tildes, mayúsculas ni del orden de las palabras.
create or replace function private.normalizar_nombre_bancario(p_texto text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(regexp_replace(
    translate(
      lower(coalesce(p_texto, '')),
      'áéíóúüñàèìòùäëïöüâêîôûç',
      'aeiouunaeiouaeiouaeiouaec'
    ),
    '[^a-z0-9]+', ' ', 'g'
  ));
$$;

create or replace function private.nombres_bancarios_equivalentes(p_a text, p_b text)
returns boolean
language sql
stable
set search_path = ''
as $$
  with a as (
    select array_agg(distinct token order by token) as tokens
    from regexp_split_to_table(private.normalizar_nombre_bancario(p_a), ' ') as token
    where token <> ''
  ), b as (
    select array_agg(distinct token order by token) as tokens
    from regexp_split_to_table(private.normalizar_nombre_bancario(p_b), ' ') as token
    where token <> ''
  )
  select coalesce(
    (select tokens from a) is not distinct from (select tokens from b)
      and (select tokens from a) is not null,
    false
  );
$$;

create or replace function public.validar_datos_bancarios()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_rut text;
  v_body text;
  v_dv text;
  v_total integer;
  v_resto integer;
  v_esperado text;
  v_post public."postulaciones_vendedores"%rowtype;
  v_perfil public."perfiles"%rowtype;
  v_validar_titular boolean :=
    coalesce(current_setting('cutuco.validar_titular_bancario', true), 'false') = 'true';
  v_requiere_hash boolean;
begin
  -- Las filas legacy pueden tener datos que hoy no cumplen las reglas nuevas.
  -- Desactivar/reemplazar una cuenta (o actualizar otra columna) no debe
  -- revalidar el contenido antiguo. Sólo se valida al insertar o cuando cambia
  -- un dato bancario propiamente tal.
  if tg_op = 'UPDATE' and not (
    new."banco" is distinct from old."banco"
    or new."tipo_cuenta" is distinct from old."tipo_cuenta"
    or new."titular_cuenta" is distinct from old."titular_cuenta"
    or new."rut_titular" is distinct from old."rut_titular"
    or new."numero_cuenta_hash" is distinct from old."numero_cuenta_hash"
    or new."numero_cuenta_digitos" is distinct from old."numero_cuenta_digitos"
  ) then
    return new;
  end if;

  new."banco" := btrim(coalesce(new."banco", ''));
  if char_length(new."banco") = 0 then
    raise exception 'El banco es obligatorio';
  end if;

  new."tipo_cuenta" := lower(replace(btrim(coalesce(new."tipo_cuenta", '')), ' ', '_'));
  if new."tipo_cuenta" not in (
    'cuenta_corriente', 'cuenta_vista', 'cuenta_ahorro', 'cuenta_rut', 'chequera_electronica'
  ) then
    raise exception 'El tipo de cuenta no es válido';
  end if;

  new."titular_cuenta" := btrim(coalesce(new."titular_cuenta", ''));
  if char_length(new."titular_cuenta") < 3 then
    raise exception 'El nombre del titular es obligatorio';
  end if;

  -- RUT normalizado y dígito verificador módulo 11.
  v_rut := upper(replace(btrim(coalesce(new."rut_titular", '')), '.', ''));
  if v_rut !~ '^[0-9]{1,8}-[0-9K]$' then
    raise exception 'El RUT del titular no es válido';
  end if;
  v_body := split_part(v_rut, '-', 1);
  v_dv := split_part(v_rut, '-', 2);
  if v_body::integer = 0 then
    raise exception 'El RUT del titular no es válido';
  end if;
  v_total := 0;
  for v_resto in 1..char_length(v_body) loop
    v_total := v_total
      + substr(v_body, char_length(v_body) - v_resto + 1, 1)::integer
      * ((v_resto - 1) % 6 + 2);
  end loop;
  v_resto := 11 - (v_total % 11);
  v_esperado := case when v_resto = 11 then '0' when v_resto = 10 then 'K' else v_resto::text end;
  if v_dv <> v_esperado then
    raise exception 'El dígito verificador del RUT del titular no es válido';
  end if;
  new."rut_titular" := v_rut;

  if tg_op = 'INSERT' then
    v_requiere_hash := true;
  else
    v_requiere_hash := (new."activo" and old."activo" is not true)
      or new."numero_cuenta_hash" is distinct from old."numero_cuenta_hash"
      or new."numero_cuenta_digitos" is distinct from old."numero_cuenta_digitos";
  end if;

  if new."numero_cuenta_hash" is not null then
    if octet_length(new."numero_cuenta_hash") <> 32 then
      raise exception 'La huella del número de cuenta no es válida';
    end if;
    if new."numero_cuenta_digitos" is null
       or new."numero_cuenta_digitos" not between 7 and 12 then
      raise exception 'El número de cuenta debe tener entre 7 y 12 dígitos';
    end if;
  end if;

  if v_requiere_hash
     and (new."numero_cuenta_hash" is null or new."numero_cuenta_digitos" is null) then
    raise exception 'No se pudo validar el número de cuenta bancaria';
  end if;

  if new."activo" and new."numero_cuenta_hash" is not null then
    if exists (
      select 1
      from public."datos_bancarios" d
      where d."id" <> new."id"
        and d."activo"
        and lower(btrim(d."banco")) = lower(new."banco")
        and lower(replace(btrim(d."tipo_cuenta"), ' ', '_')) = new."tipo_cuenta"
        and d."numero_cuenta_hash" = new."numero_cuenta_hash"
        and upper(replace(btrim(d."rut_titular"), '.', '')) = new."rut_titular"
    ) then
      raise exception 'Ya existe una cuenta bancaria registrada con los mismos datos';
    end if;
  end if;

  -- Prohibición de cuentas de terceros. El backend enciende la GUC sólo
  -- después de validar la sesión; el seed/herramientas directas no la encienden.
  if v_validar_titular then
    select po.* into v_post
    from public."postulaciones_vendedores" po
    where po."perfil_id" = new."perfil_id"
    order by (po."estado" = 'aprobada') desc, po."creado_en" desc
    limit 1;

    if found and v_post."tipo_de_persona" is not null then
      select pf.* into v_perfil from public."perfiles" pf where pf."id" = new."perfil_id";

      if v_post."tipo_de_persona" = 'natural' then
        if v_post."rut_solicitante" is null
           or upper(replace(v_post."rut_solicitante", '.', '')) <> new."rut_titular" then
          raise exception 'La cuenta bancaria debe estar a nombre del postulante: el RUT del titular no coincide';
        end if;
        if v_perfil."id" is not null and not private.nombres_bancarios_equivalentes(
          new."titular_cuenta",
          v_perfil."nombre" || ' ' || coalesce(v_perfil."apellido", '')
        ) then
          raise exception 'La cuenta bancaria debe estar a nombre del postulante: el titular no coincide con su nombre completo';
        end if;
      elsif v_post."tipo_de_persona" = 'juridica' then
        if v_post."rut_solicitante" is null
           or upper(replace(v_post."rut_solicitante", '.', '')) <> new."rut_titular" then
          raise exception 'La cuenta bancaria debe estar a nombre de la empresa: el RUT del titular no coincide';
        end if;
        if not private.nombres_bancarios_equivalentes(
          new."titular_cuenta", v_post."nombre_comercial_solicitado"
        ) then
          raise exception 'La cuenta bancaria debe estar a nombre de la empresa postulante';
        end if;
        if v_post."estado" = 'aprobada'
           and v_post."certificado_titularidad_bancaria" is null then
          raise exception 'Falta el certificado de titularidad bancaria de la empresa';
        end if;
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_validar_datos_bancarios" on public."datos_bancarios";
create trigger "trg_validar_datos_bancarios"
  before insert or update on public."datos_bancarios"
  for each row execute function public.validar_datos_bancarios();

-- ============================================================================
-- B) TELÉFONO OBLIGATORIO Y ALTA DESDE METADATA DE AUTH
-- ============================================================================

create or replace function public.exigir_telefono_perfil()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Sólo se aplica a escrituras directas desde PostgREST como usuario
  -- autenticado. El alta de Auth (SECURITY DEFINER, postgres) y el seed deben
  -- poder crear perfiles legacy sin romper la creación de la cuenta.
  if current_user <> 'authenticated' then
    return new;
  end if;
  if new."rol" not in ('cliente', 'vendedor') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if pg_trigger_depth() = 1
       and nullif(btrim(coalesce(new."telefono", '')), '') is null then
      raise exception 'El teléfono es obligatorio para crear la cuenta';
    end if;
  elsif new."telefono" is distinct from old."telefono" then
    if nullif(btrim(coalesce(new."telefono", '')), '') is null then
      raise exception 'El teléfono es obligatorio y no puede quedar vacío';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_exigir_telefono_perfil" on public."perfiles";
create trigger "trg_exigir_telefono_perfil"
  before insert or update of "telefono" on public."perfiles"
  for each row execute function public.exigir_telefono_perfil();

-- Alta tolerante: perfil + dirección principal + borrador de postulación desde
-- la metadata que envía auth.signUp (REG-CLI-017/REG-CONF-001). Los documentos
-- NO se crean aquí: se suben después de confirmar/iniciar sesión.
create or replace function public.manejar_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta jsonb := coalesce(new."raw_user_meta_data", '{}'::jsonb);
  v_perfil uuid;
  v_comuna_id uuid;
  v_telefono text;
  v_calle text;
  v_numero text;
  v_depto text;
  v_referencia text;
  v_tipo_registro text;
  v_nombre_comercial text;
  v_descripcion text;
  v_rut text;
  v_tipo_persona text;
begin
  v_telefono := nullif(btrim(coalesce(v_meta ->> 'telefono', '')), '');
  v_calle := nullif(btrim(coalesce(v_meta ->> 'calle', '')), '');
  v_numero := nullif(btrim(coalesce(v_meta ->> 'numero', '')), '');
  v_depto := nullif(btrim(coalesce(v_meta ->> 'depto_oficina', '')), '');
  v_referencia := nullif(btrim(coalesce(v_meta ->> 'referencia', '')), '');
  v_tipo_registro := lower(coalesce(v_meta ->> 'tipo_registro', 'cliente'));
  v_nombre_comercial := nullif(btrim(coalesce(v_meta ->> 'nombre_comercial', '')), '');
  v_descripcion := nullif(btrim(coalesce(v_meta ->> 'descripcion', '')), '');
  v_rut := nullif(btrim(coalesce(v_meta ->> 'rut_solicitante', '')), '');
  v_tipo_persona := lower(coalesce(v_meta ->> 'tipo_persona', ''));

  begin
    v_comuna_id := nullif(btrim(coalesce(v_meta ->> 'comuna_id', '')), '')::uuid;
  exception when others then
    v_comuna_id := null;
  end;

  insert into public."perfiles" ("id", "nombre", "apellido", "telefono", "rol", "activo")
  values (
    new."id",
    left(coalesce(nullif(btrim(v_meta ->> 'nombre'), ''), 'Usuario'), 100),
    left(nullif(btrim(coalesce(v_meta ->> 'apellido', '')), ''), 100),
    left(v_telefono, 30),
    'cliente'::public."rol_usuario",
    true
  )
  on conflict ("id") do nothing
  returning "id" into v_perfil;

  if v_perfil is null then
    return new;
  end if;

  -- Dirección principal: sólo si la comuna existe y hay calle. Cualquier
  -- restricción de dirección se ignora para no bloquear el alta de Auth.
  begin
    if v_calle is not null
       and v_comuna_id is not null
       and exists (select 1 from public."comunas" c where c."id" = v_comuna_id) then
      insert into public."direcciones" (
        "perfil_id", "etiqueta", "comuna_id", "calle", "numero",
        "depto_oficina", "referencia", "es_principal", "activo"
      ) values (
        new."id", 'Casa', v_comuna_id, left(v_calle, 255),
        left(v_numero, 20), left(v_depto, 50), left(v_referencia, 500),
        true, true
      );
    end if;
  exception when others then
    null;
  end;

  -- Borrador de postulación: sólo para registro de vendedor con nombre
  -- comercial. Los documentos y el envío a revisión siguen siendo posteriores.
  begin
    if v_tipo_registro = 'vendedor'
       and v_nombre_comercial is not null
       and not exists (
         select 1 from public."postulaciones_vendedores" po
         where po."perfil_id" = new."id"
       ) then
      if v_rut is not null and v_rut !~ '^[0-9]{7,8}-[0-9K]$' then
        v_rut := null;
      end if;
      if v_tipo_persona not in ('natural', 'juridica') then
        v_tipo_persona := null;
      end if;

      insert into public."postulaciones_vendedores" (
        "perfil_id", "nombre_comercial_solicitado", "descripcion",
        "estado", "rut_solicitante", "tipo_de_persona"
      ) values (
        new."id",
        left(v_nombre_comercial, 160),
        left(v_descripcion, 2000),
        'borrador'::public."estado_postulacion_vendedor",
        v_rut,
        v_tipo_persona::public."tipo_persona"
      );
    end if;
  exception when others then
    null;
  end;

  return new;
end;
$$;

-- ============================================================================
-- C) DIRECCIONES: NÚMERO OPCIONAL/ALFANUMÉRICO, DEPTO Y REFERENCIA OPCIONALES
-- ============================================================================

create or replace function public.validar_direccion_entrega()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_numero text := nullif(btrim(coalesce(new."numero", '')), '');
  v_depto text := nullif(btrim(coalesce(new."depto_oficina", '')), '');
  v_referencia text := nullif(btrim(coalesce(new."referencia", '')), '');
begin
  if tg_op = 'INSERT' or new."numero" is distinct from old."numero" then
    if v_numero is not null then
      if char_length(v_numero) > 20 then
        raise exception 'El número de domicilio no puede superar 20 caracteres';
      end if;
      if v_numero ~ '[[:cntrl:]]' then
        raise exception 'El número de domicilio contiene caracteres inválidos';
      end if;
      if v_numero !~ '[[:alnum:]]' then
        raise exception 'El número de domicilio debe contener letras o números';
      end if;
    end if;
    new."numero" := v_numero;
  end if;

  if tg_op = 'INSERT' or new."depto_oficina" is distinct from old."depto_oficina" then
    if v_depto is not null then
      if char_length(v_depto) > 50 then
        raise exception 'El departamento u oficina no puede superar 50 caracteres';
      end if;
      if v_depto ~ '[[:cntrl:]]' then
        raise exception 'El departamento u oficina contiene caracteres inválidos';
      end if;
    end if;
    new."depto_oficina" := v_depto;
  end if;

  if tg_op = 'INSERT' or new."referencia" is distinct from old."referencia" then
    if v_referencia is not null then
      if char_length(v_referencia) > 500 then
        raise exception 'La referencia no puede superar 500 caracteres';
      end if;
      if v_referencia ~ '[[:cntrl:]]' then
        raise exception 'La referencia contiene caracteres inválidos';
      end if;
    end if;
    new."referencia" := v_referencia;
  end if;

  return new;
end;
$$;

comment on column public."direcciones"."numero" is
  'Número de domicilio opcional (HAL-REG-006). Admite valores alfanuméricos; no exige dígitos.';
comment on column public."direcciones"."depto_oficina" is
  'Complemento opcional (depto, oficina, parcela, local). Máximo 50 caracteres (HAL-REG-004).';
comment on column public."direcciones"."referencia" is
  'Referencia opcional de entrega. Máximo 500 caracteres; ya no se exige mínimo.';

-- Los topes se validan en el trigger con mensajes funcionales. Para que un
-- valor excedido no falle antes en el cast de varchar, se usan columnas text
-- con CHECK de longitud (mismo límite funcional de 20/50/500).
alter table public."direcciones"
  alter column "numero" type text,
  alter column "depto_oficina" type text,
  alter column "referencia" type text;

alter table public."direcciones"
  add constraint "ck_direccion_numero_largo"
    check ("numero" is null or char_length(btrim("numero")) <= 20),
  add constraint "ck_direccion_depto_largo"
    check ("depto_oficina" is null or char_length(btrim("depto_oficina")) <= 50),
  add constraint "ck_direccion_referencia_largo"
    check ("referencia" is null or char_length(btrim("referencia")) <= 500);

-- ============================================================================
-- D) PRODUCTOS: SLUG, PAUSA, LÍMITES NUMÉRICOS Y PROPIEDAD
-- ============================================================================

-- HAL-VEN-005: normalizar en INSERT y UPDATE, con fallback y deduplicación.
-- Un nombre compuesto sólo por símbolos nunca deja el slug vacío ni rompe el
-- CHECK de formato.
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
  if tg_op = 'INSERT' then
    if btrim(coalesce(new."slug", '')) = '' then
      v_base := public.normalizar_slug(new."nombre_comercial", 'productor');
    else
      v_base := public.normalizar_slug(new."slug", 'productor');
    end if;
  elsif new."slug" is distinct from old."slug"
        or new."nombre_comercial" is distinct from old."nombre_comercial" then
    if btrim(coalesce(new."slug", '')) = '' then
      v_base := public.normalizar_slug(new."nombre_comercial", 'productor');
    else
      v_base := public.normalizar_slug(new."slug", 'productor');
    end if;
  else
    v_base := public.normalizar_slug(new."slug", 'productor');
  end if;

  -- Cualquier entrada sin letras/números cae al fallback funcional.
  if btrim(coalesce(v_base, '')) = '' then
    v_base := 'productor';
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

drop trigger if exists "trg_generar_slug_productor" on public."productores";
create trigger "trg_generar_slug_productor"
  before insert or update of "nombre_comercial", "slug" on public."productores"
  for each row execute function public.generar_slug_productor();

-- HAL-VEN-014: si el productor pausa su propio producto sin justificación, se
-- registra una justificación funcional. El administrador sí debe escribir la
-- suya (la UI de administración ya la envía).
create or replace function public.controlar_estado_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_productor_activo boolean;
  v_es_dueno boolean := false;
  v_es_admin boolean := false;
begin
  if old."eliminado_en" is not null and
     (new."activo" is distinct from old."activo"
      or new."eliminado_en" is distinct from old."eliminado_en") then
    raise exception 'Un producto eliminado no puede cambiar de estado';
  end if;

  if new."activo" is distinct from old."activo"
     or new."eliminado_en" is distinct from old."eliminado_en" then
    select p."activo" into v_productor_activo
      from public."productores" p
      where p."id" = old."productor_id"
      for share;
    if v_productor_activo is distinct from true then
      raise exception 'No se puede cambiar el estado de un producto de un productor desactivado';
    end if;
  end if;

  v_es_admin := private.es_admin_actual();
  select exists (
    select 1 from public."productores" p
    where p."id" = old."productor_id" and p."perfil_id" = auth.uid()
  ) into v_es_dueno;

  if not new."activo" and old."activo"
     and nullif(btrim(coalesce(new."motivo_pausa", '')), '') is null
     and v_es_dueno and not v_es_admin then
    new."motivo_pausa" := 'Pausado manualmente por el productor';
  end if;

  if new."eliminado_en" is not null then
    if new."activo" then
      raise exception 'Un producto eliminado debe estar inactivo';
    end if;
    if old."eliminado_en" is null
       or new."motivo_eliminacion" is distinct from old."motivo_eliminacion" then
      new."motivo_eliminacion" := btrim(new."motivo_eliminacion");
      if char_length(coalesce(new."motivo_eliminacion", '')) not between 10 and 1000 then
        raise exception 'La justificación de eliminación debe tener entre 10 y 1000 caracteres';
      end if;
    end if;
    new."motivo_pausa" := null;
  else
    new."motivo_eliminacion" := null;
    if new."activo" then
      new."motivo_pausa" := null;
    elsif old."activo" or new."motivo_pausa" is distinct from old."motivo_pausa" then
      new."motivo_pausa" := btrim(new."motivo_pausa");
      if char_length(coalesce(new."motivo_pausa", '')) not between 10 and 1000 then
        raise exception 'La justificación de pausa debe tener entre 10 y 1000 caracteres';
      end if;
    end if;
  end if;

  return new;
end;
$$;

-- HAL-VEN-026: límites técnicos derivados del tipo de columna.
-- precio numeric(12,2)  -> máximo 9.999.999.999,99 CLP
-- stock  numeric(12,3)  -> máximo 999.999.999,999 unidades
alter table public."productos"
  add constraint "ck_producto_precio_maximo"
    check ("precio" <= 9999999999.99),
  add constraint "ck_producto_stock_maximo"
    check ("stock" <= 999999999.999),
  add constraint "ck_producto_stock_reservado_maximo"
    check ("stock_reservado" <= 999999999.999);

comment on constraint "ck_producto_precio_maximo" on public."productos" is
  'HAL-VEN-026: máximo técnico de numeric(12,2) para precio en CLP.';
comment on constraint "ck_producto_stock_maximo" on public."productos" is
  'HAL-VEN-026: máximo técnico de numeric(12,3) para stock.';
comment on constraint "ck_producto_stock_reservado_maximo" on public."productos" is
  'HAL-VEN-026: máximo técnico de numeric(12,3) para stock reservado.';

create or replace function public.validar_limites_numericos_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new."precio" < 0 or new."precio" > 9999999999.99 then
    raise exception 'El precio debe estar entre 0 y 9.999.999.999,99 CLP';
  end if;
  if new."stock" < 0 or new."stock" > 999999999.999 then
    raise exception 'El stock debe estar entre 0 y 999.999.999,999 unidades';
  end if;
  if new."stock_reservado" < 0 or new."stock_reservado" > 999999999.999 then
    raise exception 'El stock reservado debe estar entre 0 y 999.999.999,999 unidades';
  end if;
  return new;
end;
$$;

drop trigger if exists "z_trg_validar_limites_numericos_producto" on public."productos";
create trigger "z_trg_validar_limites_numericos_producto"
  before insert or update on public."productos"
  for each row execute function public.validar_limites_numericos_producto();

-- HAL-VEN-016: el UPDATE ajeno debe fallar con 42501 (PostgREST -> 403) y un
-- mensaje funcional, no con PGRST116 por "0 filas". Para que el trigger se
-- ejecute, la policy USING permite intentar la fila; el WITH CHECK y el trigger
-- siguen impidiendo la escritura.
create or replace function public.validar_propiedad_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
  v_uid uuid;
begin
  v_jwt := current_setting('request.jwt.claims', true);
  if v_jwt is null or current_user in ('postgres', 'service_role') then
    return new;
  end if;
  if private.es_admin_actual() then
    return new;
  end if;

  v_uid := auth.uid();
  if v_uid is null or not exists (
    select 1
    from public."productos" p
    join public."productores" pr on pr."id" = p."productor_id"
    where p."id" = new."id" and pr."perfil_id" = v_uid
  ) then
    raise exception using
      errcode = '42501',
      message = 'No puedes modificar un producto que no te pertenece';
  end if;

  return new;
end;
$$;

drop trigger if exists "a_trg_validar_propiedad_producto" on public."productos";
create trigger "a_trg_validar_propiedad_producto"
  before update on public."productos"
  for each row execute function public.validar_propiedad_producto();

drop policy if exists "productos_update_vendedor_admin" on public."productos";
create policy "productos_update_intento_autenticado"
  on public."productos" for update to authenticated
  using (true)
  with check (
    (select private.es_productor_actual("productor_id"))
    or (select private.es_admin_actual())
  );

-- ============================================================================
-- E) CATÁLOGO: FUERA "ALIMENTOS PARA MASCOTAS" Y DUPLICADOS
-- ============================================================================

-- 1) Categorías duplicadas por nombre (incluye variantes de mayúsculas y
--    "Sin categoría"/"Sin Categoría"): se conserva una y se hace baja lógica
--    del resto. El trigger reasigna los productos a "Sin Categoría" y no se
--    borra ningún dato histórico.
do $$
declare
  r record;
  v_keep uuid;
  v_id uuid;
begin
  for r in
    select lower(btrim("nombre")) as nombre_norm
    from public."categorias"
    where "eliminado_en" is null
    group by lower(btrim("nombre"))
    having count(*) > 1
  loop
    select c."id" into v_keep
    from public."categorias" c
    where c."eliminado_en" is null
      and lower(btrim(c."nombre")) = r.nombre_norm
    order by c."es_sistema" desc, c."creado_en", c."id"
    limit 1;

    -- Una fila por sentencia: el trigger reasigna hijos en la misma tabla y
    -- PostgreSQL no permite modificar dos veces la misma tupla en un UPDATE
    -- multi-fila.
    for v_id in
      select c."id" from public."categorias" c
      where c."eliminado_en" is null
        and lower(btrim(c."nombre")) = r.nombre_norm
        and c."id" <> v_keep
    loop
      update public."categorias"
         set "eliminado_en" = now()
       where "id" = v_id;
    end loop;
  end loop;
end;
$$;

-- 2) Árbol "Alimentos para mascotas" (padre, subcategorías y sinónimos).
do $$
declare
  v_id uuid;
begin
  for v_id in
    select c."id"
    from public."categorias" c
    where c."eliminado_en" is null
      and c."es_sistema" = false
      and (
        lower(btrim(c."nombre")) = 'alimentos para mascotas'
        or lower(btrim(c."slug")) in (
          'alimentos-mascotas', 'mascotas-alimentos', 'mascotas-snacks'
        )
      )
  loop
    update public."categorias"
       set "eliminado_en" = now()
     where "id" = v_id;
  end loop;
end;
$$;

-- 3) A partir de aquí no puede quedar más de una categoría visible con el
--    mismo nombre (protege contra futuras cargas del seed histórico).
create unique index if not exists "uq_categoria_nombre_visible"
  on public."categorias" (lower(btrim("nombre")))
  where "eliminado_en" is null;

comment on index public."uq_categoria_nombre_visible" is
  'HAL-CLI-021/HAL-VEN-006: evita duplicados visibles de categorías. Las categorías históricas permanecen con eliminado_en.';

-- ============================================================================
-- F) EVIDENCIAS FOTOGRÁFICAS (FUERA DE ALCANCE)
-- ============================================================================

-- La tabla se conserva como historial, pero ningún rol de la API puede usarla
-- ni escribir en ella. No hay bucket de evidencias activo.
drop policy if exists "evidencias_envio_participantes" on public."evidencias_envio";
revoke all on public."evidencias_envio" from public, anon, authenticated;
grant select on public."evidencias_envio" to service_role;
comment on table public."evidencias_envio" is
  'HISTÓRICA/FUERA DE ALCANCE (HAL-CLI-022): evidencia fotográfica del prototipo anterior. Sin policies ni acceso para anon/authenticated; solo lectura de servicio.';

-- ============================================================================
-- G) SERVICIO MENSUAL: FECHA DE EMISIÓN Y VENCIMIENTO COHERENTES
-- ============================================================================

alter table public."pagos_servicio"
  add column if not exists "emitido_en" date;

update public."pagos_servicio"
   set "emitido_en" = "vence_en" - 10
 where "emitido_en" is null;

alter table public."pagos_servicio"
  alter column "emitido_en" set default current_date,
  alter column "emitido_en" set not null;

alter table public."pagos_servicio"
  add constraint "ck_pago_servicio_fechas_coherentes"
    check ("vence_en" = "emitido_en" + 10);

comment on column public."pagos_servicio"."emitido_en" is
  'HAL-VEN-019: fecha real de emisión de la cuota. vence_en = emitido_en + 10; la gracia vence al día 16 desde emitido_en.';

create or replace function private.crear_cuota_servicio(p_productor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_periodo date := date_trunc('month', current_date)::date;
begin
  insert into public."pagos_servicio" (
    "productor_id", "periodo", "monto", "emitido_en", "vence_en"
  )
  values (p_productor_id, v_periodo, 9900, current_date, current_date + 10)
  on conflict ("productor_id", "periodo") do nothing;
end;
$$;

create or replace function public.mi_servicio()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_productor uuid;
begin
  select "id" into v_productor
  from public."productores"
  where "perfil_id" = auth.uid();
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
        select "id", "periodo", "monto", "emitido_en", "vence_en", "estado",
               "metodo", "referencia", "pagado_en", "observaciones"
        from public."pagos_servicio"
        where "productor_id" = v_productor
        order by "periodo" desc
        limit 1
      ) c
    ),
    'historial', coalesce((
      select jsonb_agg(to_jsonb(h) order by h."periodo" desc)
      from (
        select "id", "periodo", "monto", "emitido_en", "vence_en", "estado",
               "metodo", "referencia", "pagado_en", "observaciones"
        from public."pagos_servicio"
        where "productor_id" = v_productor
        order by "periodo" desc
        limit 24
      ) h
    ), '[]'::jsonb)
  );
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
  for v_id in select "id" from public."productores" loop
    perform private.crear_cuota_servicio(v_id);
    perform private.sincronizar_morosidad_productor(v_id);
  end loop;

  return coalesce((
    select jsonb_agg(row order by row->>'nombre_comercial')
    from (
      select jsonb_build_object(
        'productor_id', p."id",
        'nombre_comercial', p."nombre_comercial",
        'perfil_id', p."perfil_id",
        'estado', private.estado_servicio(p."id"),
        'suspendido', p."servicio_suspendido",
        'cuota', (
          select to_jsonb(c) from (
            select "id", "periodo", "monto", "emitido_en", "vence_en", "estado",
                   "metodo", "referencia", "pagado_en", "observaciones"
            from public."pagos_servicio"
            where "productor_id" = p."id"
            order by "periodo" desc
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
grant execute on function public.admin_servicio_resumen() to authenticated;

commit;
