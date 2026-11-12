-- CK-0319 / regresión de 20261104010000: "create or replace function" reinicia
-- el ACL de cada función (vuelve a EXECUTE para PUBLIC) y la migración de
-- privilegios revocó EXECUTE de PUBLIC sobre private. Resultado: service_role
-- (backend de confianza FastAPI/Cloud Run, ver 20261004021917 línea 3517-3518)
-- quedó sin EXECUTE sobre funciones private que el backend llama directamente
-- (private.sincronizar_morosidad_productor, private.crear_cuota_servicio,
-- private.liberar_reservas_checkout, private.liberar_reservas_expiradas).
-- Se reabre EXECUTE sobre private sólo para service_role; anon y authenticated
-- quedan con los grants explícitos y mínimos de 20261104010000.
-- No cambia datos ni políticas RLS; no afecta a clientes del navegador.
begin;

grant execute on all functions in schema private to service_role;

commit;
