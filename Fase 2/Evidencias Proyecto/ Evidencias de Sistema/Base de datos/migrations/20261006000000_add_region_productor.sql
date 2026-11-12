-- ============================================================
-- CuTuCo — Cobertura regional explícita del productor (RF-009)
-- ============================================================
-- Contexto:
--   RF-009 define la cobertura comparando la región del Cliente con la región
--   del productor (`id_region`). La migración
--   `20261004021917_nuevo_alcance.sql` dejó la cobertura "implícita" en la
--   dirección activa del productor, por lo que el frontend debía resolverla con
--   consultas adicionales para poder filtrar el catálogo.
--
-- Esta migración NO elimina ni reemplaza nada del esquema anterior: agrega una
-- columna derivada `productores.region_id`, la rellena desde la dirección
-- activa existente y la mantiene sincronizada con un trigger, para que la
-- comparación de RF-009 sea una lectura directa y filtrable desde PostgREST.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columna derivada
-- ------------------------------------------------------------
alter table public."productores"
  add column if not exists "region_id" uuid references public."regiones"("id") on delete set null;

create index if not exists "idx_productores_region"
  on public."productores" ("region_id");

comment on column public."productores"."region_id" is
  'Región de cobertura del productor (RF-009). Derivada de su dirección activa; la mantiene el trigger trg_sincronizar_region_productor.';

-- ------------------------------------------------------------
-- 2. Relleno inicial desde la dirección activa
-- ------------------------------------------------------------
update public."productores" pr
   set "region_id" = c."region_id"
  from public."direcciones" d
  join public."comunas" c on c."id" = d."comuna_id"
 where d."perfil_id" = pr."perfil_id"
   and d."activo" = true
   and pr."region_id" is distinct from c."region_id";

-- ------------------------------------------------------------
-- 3. Sincronización con la dirección activa
-- ------------------------------------------------------------
create or replace function public.sincronizar_region_productor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_perfil_id uuid;
begin
  v_perfil_id := coalesce(new."perfil_id", old."perfil_id");
  if v_perfil_id is null then
    return coalesce(new, old);
  end if;

  update public."productores" pr
     set "region_id" = (
           select c."region_id"
             from public."direcciones" d
             join public."comunas" c on c."id" = d."comuna_id"
            where d."perfil_id" = v_perfil_id
              and d."activo" = true
            order by d."es_principal" desc, d."creado_en" asc
            limit 1
         )
   where pr."perfil_id" = v_perfil_id;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sincronizar_region_productor on public."direcciones";
create trigger trg_sincronizar_region_productor
  after insert or update of "comuna_id", "activo", "es_principal" or delete
  on public."direcciones"
  for each row
  execute function public.sincronizar_region_productor();

-- La creación del productor (al aprobar la postulación) también fija la región.
create or replace function public.fijar_region_productor_nuevo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new."region_id" is null then
    select c."region_id"
      into new."region_id"
      from public."direcciones" d
      join public."comunas" c on c."id" = d."comuna_id"
     where d."perfil_id" = new."perfil_id"
       and d."activo" = true
     order by d."es_principal" desc, d."creado_en" asc
     limit 1;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_fijar_region_productor on public."productores";
create trigger trg_fijar_region_productor
  before insert on public."productores"
  for each row
  execute function public.fijar_region_productor_nuevo();

-- Permiso de lectura de la nueva columna para el catálogo público: las
-- políticas RLS de `productores` ya cubren las filas, no hace falta una nueva.
