# Análisis estático con Slither

- Herramienta: Slither 0.11.6 (102 detectores), sobre el código propio (`src/`); se excluyen `lib/`, `test/` y `script/`.
- Comando: `slither . --filter-paths "lib|test|script" > docs/slither.txt 2>&1` (en Windows, desde WSL).
- Versión analizada: código con la ventana de retiro (`PLAZO_RETIRO`) y el struct `Campania` empaquetado.
- Resultado: **9 hallazgos, todos de severidad baja o informativa**. No hay hallazgos de reentrada, de envío de ETH a destino arbitrario, de variables sin inicializar ni de control de acceso. El log completo está en [`slither.txt`](slither.txt).

## Hallazgos y tratamiento

| # | Detector | Dónde | Tratamiento | Justificación |
|---|---|---|---|---|
| 1 | `timestamp` (5 ocurrencias) | `donar`, `retirar`, `reclamarDevolucion`, `campania`, `estadoActual` | **Aceptado** (y un falso positivo) | Los plazos se miden en horas o días: la duración mínima de una campaña es 1 hora y la ventana de retiro es de 30 días. Un validador solo puede mover `block.timestamp` unos segundos, lo que no cambia el resultado de negocio. Los bordes están definidos en una sola dirección (`retirar` y `donar` valen hasta `plazo` inclusive; `reclamarDevolucion` solo después), así que en ningún instante se pueden hacer a la vez el retiro y la devolución; está probado con tests de borde exacto y con fuzzing (`testFuzz_RetiroYDevolucionNoSeSolapan`). En `campania` el hallazgo es un falso positivo: solo compara `destinatario == address(0)`, que no depende del tiempo. |
| 2 | `low-level-calls` (2 ocurrencias) | `retirar`, `reclamarDevolucion`: `call{value: ...}("")` | **Aceptado** | `call` es la forma recomendada de enviar ETH (`transfer` fija un límite de gas que puede romper pagos a contratos). Se mitiga con: resultado verificado (`TransferenciaFallida`), patrón checks-effects-interactions (el estado se actualiza antes de enviar), `ReentrancyGuard` y test de reentrada (`test_Retirar_BloqueaReentrada`). Si el destinatario rechaza el pago, los fondos no quedan trabados: al vencer la ventana de retiro los donantes los recuperan (`test_Devolucion_DestinatarioQueRechazaLosDonantesRecuperanTodo`). |
| 3 | `naming-convention` (2 ocurrencias) | `Recibo.SALUDCHAIN`, `SaludChain.RECIBO` | **Aceptado** (estilo) | Variables `immutable` en mayúsculas, convención habitual de la guía de estilo de Solidity y de OpenZeppelin. No afecta la seguridad. |

Respecto del análisis anterior desapareció `incorrect-equality` (la comparación de enum en `estadoActual` ya no lo dispara) y se agregó `retirar` a `timestamp`, por el control de la ventana de retiro.

## Consideraciones de diseño relacionadas (no son hallazgos de Slither)

- **Igualdad `nuevoRecaudado == meta` en `donar`:** es intencional y segura. Cada donación se limita a lo que falta para la meta (`ExcedeMeta`), y lo recaudado se lleva con contabilidad interna, por lo que ETH enviado a la fuerza al contrato (por ejemplo con `selfdestruct` de otro contrato) no puede alterar la cuenta.
- **`arbitrary-send-eth`:** no se reportó. El destinatario de `retirar` es el definido al crear la campaña, y solo él puede llamar a la función; `reclamarDevolucion` solo le paga a quien llama, y solo lo que aportó.
- **Aritmética `unchecked`:** cada bloque está respaldado por un invariante documentado en el código (`recaudado <= meta`; la suma de los aportes es igual a `recaudado`). Los invariantes de `test/Invariantes.t.sol` lo comprueban con secuencias aleatorias.
- El código de OpenZeppelin (`lib/`) queda fuera de alcance.

Ningún hallazgo relevante de seguridad ni de optimización quedó sin tratar.
