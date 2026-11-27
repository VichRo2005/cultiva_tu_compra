-- Auditoría de seguridad 2026-11-14 (informe: work/db-audit-2026-11-14.md).
-- Solo DDL de privilegios/límites: no toca datos de negocio, ni RLS, ni políticas
-- de storage existentes.
--
-- Hallazgo [MEDIO]: TRUNCATE (junto con REFERENCES/TRIGGER) otorgado a los roles
-- cliente anon/authenticated en tablas de public. Detectado con arwdDxtm en:
-- alertas_stock, coberturas_productor, documentos_identidad, historial_precios y
-- pagos_servicio. RLS no cubre TRUNCATE, así que se revoca en TODAS las tablas de
-- public (no solo en las 5 del informe) para dejar el estado explícito y cubrir
-- cualquier otra tabla con ACL amplio.
--
-- Seguridad de la operación: REFERENCES/TRIGGER los utiliza internamente el
-- owner de la tabla (postgres) para mantener FKs y triggers existentes; revocarlos
-- SOLO de anon/authenticated no rompe ninguna FK (postgres y service_role
-- conservan arwdDxtm). Las vistas (relkind 'v') quedan fuera porque TRUNCATE no
-- aplica a vistas.
-- Causa raíz: el ACL por defecto del esquema public (pg_default_acl para el rol
-- postgres) concede arwdDxtm a anon/authenticated en tablas nuevas.
--
-- Hallazgo [BAJO]: el bucket público product-images no tenía file_size_limit ni
-- allowed_mime_types. Se acota a 5 MiB (5242880 bytes) y a jpeg/png/webp,
-- coherente con DC-10 y con la práctica de producto (vendedor-documentos usa
-- 10 MiB con lista cerrada de mimes).

begin;

do $$
declare
  t record;
begin
  for t in
    select c.oid, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p', 'f')  -- tablas ordinarias, particionadas y externas
  loop
    if has_table_privilege('anon', t.oid, 'TRUNCATE')
       or has_table_privilege('authenticated', t.oid, 'TRUNCATE') then
      execute format('revoke truncate on table public.%I from anon, authenticated', t.relname);
    end if;
    if has_table_privilege('anon', t.oid, 'REFERENCES')
       or has_table_privilege('authenticated', t.oid, 'REFERENCES')
       or has_table_privilege('anon', t.oid, 'TRIGGER')
       or has_table_privilege('authenticated', t.oid, 'TRIGGER') then
      execute format('revoke references, trigger on table public.%I from anon, authenticated', t.relname);
    end if;
  end loop;
end;
$$;

-- Bucket product-images: límite de 5 MiB y solo imágenes (DC-10).
update storage.buckets
set file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'product-images';

commit;
