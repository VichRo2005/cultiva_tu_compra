-- Recupera solicitudes ya completas que quedaron en borrador por una versión
-- previa del flujo. Una postulación con todos los antecedentes obligatorios
-- no debe desaparecer de Aprobaciones ni seguir siendo editable por quien la
-- envió: se convierte en «en_revision» y entra en la cola administrativa.
begin;

update public.postulaciones_vendedores
   set estado = 'en_revision',
       actualizado_en = now()
 where estado = 'borrador'
   and rut_solicitante is not null
   and tipo_de_persona is not null
   and documento_identidad is not null
   and certificado_inicio_actividades_o_carnet_representante is not null
   and certificado_titularidad_bancaria is not null
   and comprobante_domicilio is not null;

commit;
