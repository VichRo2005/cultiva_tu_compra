-- Lote 19 (CK-0407): unicidad de correo a nivel servidor.
-- GoTrue valida formato y rechaza correos ocupados en su capa; la restricción
-- física vive en auth.users. Si el esquema aún no trae índice único sobre el
-- correo (p. ej. entornos efímeros de QA), aquí se crea. En producción
-- Supabase ya existe y el chequeo evita duplicarlo.

do $$
begin
  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'auth'
      and tablename = 'users'
      and indexdef ilike '%unique%'
      and indexdef ilike '%email%'
  ) then
    execute 'create unique index if not exists uq_auth_users_email on auth.users (lower(email::text))';
  end if;
  if exists (select 1 from pg_indexes where schemaname='auth' and indexname='uq_auth_users_email') then
    execute 'comment on index auth.uq_auth_users_email is ''CK-0407: un correo solo puede pertenecer a una cuenta (insensible a mayusculas).''';
  end if;
end $$;
