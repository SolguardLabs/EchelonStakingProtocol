# Política de seguridad

La seguridad de Echelon Staking Protocol incluye la custodia del principal, la disponibilidad de
salidas, la contabilidad de recompensas, el control de acceso y la integridad de las reservas.
Agradecemos los reportes responsables que permitan investigar y corregir un riesgo antes de hacerlo
público.

## Versiones compatibles

La rama principal y la última versión publicada reciben correcciones de seguridad. Las revisiones
anteriores, bifurcaciones y despliegues modificados no se consideran compatibles salvo indicación
expresa de sus responsables.

## Alcance

Se consideran dentro de alcance:

- contratos Solidity en `src/`;
- scripts oficiales de despliegue y configuración;
- errores que permitan perder, bloquear o asignar incorrectamente principal o recompensas;
- elusión de roles, pausas, retardos o límites económicos;
- desajustes de solvencia, contabilidad de pesos, *epochs*, penalizaciones o *slashing*;
- reentrada, llamadas externas inseguras y comportamientos inesperados de tokens compatibles.

Quedan fuera de alcance los ataques de ingeniería social, denegación de servicio contra
infraestructura ajena al repositorio, claves comprometidas, fallos de terceros y hallazgos que solo
afecten a código modificado por un desplegador.

## Cómo reportar

No abras un *issue* público ni publiques una prueba de concepto mientras el caso esté en proceso.
Utiliza un aviso privado de seguridad de GitHub (**Security > Advisories > New draft security
advisory**) e incluye:

1. versión, commit y contratos afectados;
2. impacto y condiciones necesarias para reproducirlo;
3. pasos de reproducción o una prueba mínima;
4. estimación de severidad y activos en riesgo;
5. cualquier mitigación temporal o corrección sugerida.

No incluyas claves privadas, frases semilla ni datos personales. Si el repositorio no tiene los
avisos privados habilitados, contacta de forma privada con sus mantenedores y solicita un canal
cifrado antes de compartir detalles técnicos.

## Proceso de respuesta

El objetivo operativo es:

- confirmar la recepción en un máximo de 3 días laborables;
- realizar una primera clasificación en un máximo de 7 días laborables;
- mantener al reportante informado durante la investigación;
- acordar una fecha de divulgación tras disponer de mitigación y corrección.

Los plazos pueden variar según complejidad, dependencias y coordinación con despliegues. Se solicita
un periodo inicial de confidencialidad de 90 días, salvo riesgo activo que requiera una respuesta
más rápida. La atribución se ofrecerá cuando el reportante la desee y resulte legalmente posible.

## Clasificación orientativa

- **Crítica:** pérdida directa y generalizada de fondos o control administrativo sin privilegios.
- **Alta:** pérdida material, insolvencia, bloqueo prolongado o elusión relevante de controles.
- **Media:** impacto económico limitado o degradación que requiere condiciones específicas.
- **Baja:** defensa en profundidad, observabilidad o impacto sin riesgo directo para activos.

La severidad final considera explotabilidad, privilegios, alcance, detectabilidad y posibilidad de
recuperación.

## Buenas prácticas de despliegue

- Separar gobierno, gestión de recompensas, guardián y *slasher*.
- Usar multifirma, *timelock* y procedimientos documentados de rotación de claves.
- Verificar contratos y parámetros en cadena antes de transferir privilegios.
- Monitorizar principal, peso total, liquidez de recompensas y saldo contabilizado de la reserva.
- Ensayar pausas, cancelaciones y recuperación operativa antes de habilitar depósitos.
- Someter cada versión y migración a revisión independiente.

Ninguna auditoría elimina por completo el riesgo. Los despliegues con activos reales deben imponer
límites prudentes y contar con un plan de respuesta a incidentes.
