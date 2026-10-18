# Análisis estático con Slither

- Herramienta: Slither 0.11.6 (102 detectores), sobre el código propio (`src/`); se excluyen `lib/`, `test/` y `script/`.
- Comando: `slither . --filter-paths "lib|test|script" > docs/slither.txt 2>&1`
- Resultado: **9 hallazgos, todos de severidad baja o informativa**. No hay hallazgos de reentrada, de envío de ETH a destino arbitrario, de variables sin inicializar ni de control de acceso. El log completo está en [`slither.txt`](slither.txt).

## Hallazgos y tratamiento

| # | Detector | Dónde | Tratamiento | Justificación |
|---|---|---|---|---|
| 1 | `incorrect-equality` | `estadoActual`: `c.estado == Estado.Activa` | **Falso positivo** | Es la comparación de un valor de enum, no de un saldo ni de un monto manipulable. Slither alerta por igualdades estrictas en general. |
| 2 | `timestamp` (4 ocurrencias) | `donar`, `reclamarDevolucion`, `campania`, `estadoActual` | **Aceptado** | El plazo de una campaña se mide en horas o días (mínimo 1 hora). Un validador solo puede mover `block.timestamp` unos segundos, lo que no cambia el resultado de negocio. En `campania` el hallazgo es un falso positivo (solo compara `destinatario == address(0)`, que no depende del tiempo); en `estadoActual` lo mismo aplica a esa comparación, y la del plazo queda aceptada. |
| 3 | `low-level-calls` (2 ocurrencias) | `retirar`, `reclamarDevolucion`: `call{value: ...}("")` | **Aceptado** | `call` es la forma recomendada de enviar ETH (`transfer` fija un límite de gas que puede romper pagos a contratos). Se mitiga con: resultado verificado (`TransferenciaFallida`), patrón checks-effects-interactions (el estado se actualiza antes de enviar), `ReentrancyGuard` y test de reentrada (`test_Retirar_BloqueaReentrada`). |
| 4 | `naming-convention` (2 ocurrencias) | `Recibo.SALUDCHAIN`, `SaludChain.RECIBO` | **Aceptado** (estilo) | Variables `immutable` en mayúsculas, convención habitual de la guía de estilo de Solidity y de OpenZeppelin. No afecta la seguridad. |

## Consideraciones de diseño relacionadas (no son hallazgos de Slither)

- **Igualdad `nuevoRecaudado == meta` en `donar`:** es intencional y segura. Cada donación se limita a lo que falta para la meta (`ExcedeMeta`), y lo recaudado se lleva con contabilidad interna, por lo que ETH enviado a la fuerza al contrato (por ejemplo con `selfdestruct` de otro contrato) no puede alterar la cuenta.
- **`arbitrary-send-eth`:** no se reportó. El destinatario de `retirar` es el definido al crear la campaña, y solo él puede llamar a la función.
- El código de OpenZeppelin (`lib/`) queda fuera de alcance.

Ningún hallazgo relevante de seguridad ni de optimización quedó sin tratar.
