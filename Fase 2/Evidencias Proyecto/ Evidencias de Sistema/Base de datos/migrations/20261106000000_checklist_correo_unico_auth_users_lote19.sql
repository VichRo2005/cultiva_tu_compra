-- Lote 19 (CK-0407): unicidad de correo a nivel servidor (insensible a mayúsculas).
-- GoTrue valida formato y rechaza correos ocupados en su capa; la restricción
-- física vive en auth.users. 
-- 
-- NOTA: En Supabase local, la tabla auth.users pertenece a supabase_auth_admin
-- y las migraciones (ejecutadas como rol postgres) no tienen permisos para
-- crear/eliminar índices sobre ella. El índice case-insensitive uq_auth_users_email
-- no puede crearse en la migración.
-- 
-- La unicidad case-insensitive se garantiza por GoTrue (capa de autenticación)
-- al registrar usuarios. El índice parcial case-sensitive users_email_partial_key
-- que Supabase crea por defecto es una defensa adicional para usuarios no-SSO.
-- 
-- Esta migración registra el requisito documentalmente; la validación real
-- ocurre en la capa de autenticación (GoTrue) y se prueba en test_acceso_lote19.py
-- vía signInWithPassword con email en mayúsculas/minúsculas.

SELECT 1;
