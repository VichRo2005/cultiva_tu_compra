-- Separado para que PostgreSQL confirme el nuevo valor antes de usarlo.
alter type public.estado_postulacion_vendedor add value 'borrador' before 'pendiente_aprobacion';
