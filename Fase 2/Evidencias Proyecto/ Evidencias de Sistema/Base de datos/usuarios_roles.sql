-- Evidencia de consulta de usuarios de aplicación y sus roles.
-- Requiere permiso de lectura en auth.users; ejecutar solo en ambiente autorizado.
-- No expone hashes, tokens, teléfonos ni datos bancarios.
SELECT p.id AS perfil_id, u.email, p.rol
FROM public.perfiles AS p
JOIN auth.users AS u ON u.id = p.id
ORDER BY p.rol, u.email;

SELECT p.rol, COUNT(*) AS cantidad_perfiles
FROM public.perfiles AS p
GROUP BY p.rol
ORDER BY p.rol;
