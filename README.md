# SaludChain

Plataforma de **donaciones para gastos médicos** sobre Ethereum con custodia en contrato (escrow): el dinero queda dentro del contrato, se libera al destinatario solo si se alcanza la meta aprobada y, si el plazo vence sin alcanzarla, cada donante recupera su aporte ("todo o nada"). Cada donación emite un NFT de comprobante.

> Trabajo Final del curso EthKipu 2026 – Ethereum Avanzado (Nivel 2). Red de despliegue: **Sepolia (testnet)**.

## ¿Qué hace y cómo está armado?

Dos contratos que interactúan entre sí:

| Contrato | Rol |
|---|---|
| `SaludChain.sol` | Campañas, donaciones, verificación, retiro y devolución. Usa `AccessControl` (roles) y `ReentrancyGuard` de OpenZeppelin. |
| `Recibo.sol` | NFT ERC-721 con el comprobante de cada donación. Solo `SaludChain` puede emitirlo (lo crea en su constructor). |

**Roles:** beneficiario/creador (crea la campaña), verificador (aprueba y fija el monto máximo), donante.

**Estados de una campaña:** `Pendiente → Activa → Cumplida → Liberada`; o `Vencida` (derivado, no se guarda): el plazo de donación venció sin alcanzar la meta, **o** se alcanzó la meta pero el destinatario no retiró dentro de los 30 días (`PLAZO_RETIRO`). En ambos casos cada donante recupera su aporte.

**Flujo principal:**
1. `crearCampania(destinatario, meta, duracion, hashDocs)` → queda **Pendiente** (solo se guarda la huella de la documentación, nunca datos médicos).
2. `verificar(id, montoAprobado)` (solo `VERIFICADOR_ROLE`) → **Activa**; el monto aprobado pasa a ser la meta y arranca el plazo.
3. `donar(id)` (payable) → suma al recaudado y emite el NFT `Recibo`. No acepta más de lo que falta para la meta; al llegar a ella la campaña pasa a **Cumplida** y se cierra.
4. `retirar(id)` → el destinatario cobra (pull payment) dentro de los **30 días** posteriores a alcanzar la meta. Pasa a **Liberada**.
5. `reclamarDevolucion(id)` → cada donante recupera su aporte si venció el plazo sin llegar a la meta, o si venció la ventana de retiro sin que el destinatario cobrara. `retirar` y `reclamarDevolucion` nunca pueden ejecutarse en el mismo instante: el retiro vale hasta el `plazo` inclusive y la devolución solo después.

Buenas prácticas aplicadas: NatSpec completo (contratos, script y tests), eventos, custom errors, patrón checks-effects-interactions, `ReentrancyGuard`, contabilidad interna (no depende de `address(this).balance`), una lectura y una escritura de storage por variable en cada función, y los fondos nunca quedan bloqueados (ver «Seguridad»).

### ¿Por qué se dona en ETH y no en una stablecoin?

Es una decisión de diseño del MVP, y también la limitación económica más importante:

- **Por qué ETH hoy:** es la moneda nativa de la red, así que donar es una sola transacción (sin `approve` previo ni token adicional), el contrato es más simple y tiene menos superficie de ataque, y no depende de ningún emisor externo.
- **Qué cuesta:** el valor del ETH varía entre que se dona y que el destinatario retira, y la meta está expresada en ETH. Para un gasto médico, que normalmente se presupuesta en moneda fuerte, lo lógico es una moneda estable.
- **Mejora prevista (roadmap):** aceptar una stablecoin ERC-20 (USDC, DAI, USDT u otra) con metas expresadas en dólares, usando `SafeERC20` (USDT no sigue el estándar al pie de la letra). Opcionalmente, un *price feed* de Chainlink (ETH/USD) para mostrar y valuar en dólares las donaciones hechas en ETH. Ojo: Chainlink aporta el precio, no hace el cambio de moneda; convertir ETH en stablecoin automáticamente requeriría además un exchange descentralizado (por ejemplo Uniswap), con sus propios riesgos (comisiones, deslizamiento de precio, liquidez).
- **Qué hay que considerar al elegir la stablecoin:** USDC y USDT dependen de un emisor centralizado que puede congelar fondos; DAI es más descentralizada pero está respaldada por colateral. En Sepolia no hay una stablecoin oficial de referencia, por lo que las pruebas usarían un token de prueba.

## Instalación y compilación

Requisitos: [Foundry](https://book.getfoundry.sh/getting-started/installation) (en Windows, usar WSL) y Git.

```bash
git clone <URL-DEL-REPO> saludchain && cd saludchain
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.4.0
forge build
```

## Tests y cobertura

```bash
forge test            # todos los tests deben pasar
forge coverage --report summary
forge test --gas-report
```

**Resultado:** `forge test` muestra **53 tests, todos pasan y 0 fallan**: 51 unitarios y de fuzzing (cada función con un caso de éxito y uno de revert, bordes de tiempo exactos de las ventanas de donación y de retiro), 1 de medición de gas (`MedicionGas`) y 1 suite de invariantes con 2 propiedades. Los invariantes ejecutan secuencias aleatorias de crear, verificar, donar, retirar, devolver y avanzar el tiempo, incluyendo destinatarios que rechazan ETH, y verifican que **el saldo del contrato siempre es igual a la suma de `recaudado` de las campañas no liberadas** y que nunca se recauda más que la meta.

**Cobertura** (`forge coverage --report summary`):

| Archivo | Líneas | Sentencias | Ramas | Funciones |
|---|---|---|---|---|
| `src/SaludChain.sol` | 100,00 % (93/93) | 100,00 % (120/120) | 100,00 % (27/27) | 100,00 % (10/10) |
| `src/Recibo.sol` | 100,00 % (18/18) | 100,00 % (21/21) | 100,00 % (4/4) | 100,00 % (4/4) |
| `script/Deploy.s.sol` | 0 % (0/10) | 0 % (0/11) | — | 0 % (0/1) |
| `test/Invariantes.t.sol` (contratos auxiliares) | 100,00 % (48/48) | 100,00 % (55/55) | 100,00 % (7/7) | 100,00 % (9/9) |
| `test/SaludChain.t.sol` (contratos auxiliares) | 100,00 % (15/15) | 100,00 % (8/8) | 100,00 % (2/2) | 100,00 % (6/6) |
| **Total** | 94,57 % (174/184) | 94,88 % (204/215) | 100,00 % (40/40) | 96,67 % (29/30) |

Foundry también mide los contratos auxiliares definidos dentro de los tests (atacantes, receptores que rechazan ETH, el manejador de invariantes); por eso aparecen en la tabla y en el total. El código del protocolo (`src/`) está cubierto al 100 %; el 0 % corresponde al script de despliegue, que no es lógica del protocolo y se probó contra una red local (anvil); para Sepolia ver la nota sobre el gas en «Despliegue». El requisito del profe (>40 %) se supera con holgura.

### Optimizaciones de gas (medidas)

Medido con un escenario fijo (`test/MedicionGas.t.sol`: dos campañas, tres donaciones, un retiro y una devolución), que se corre igual sobre el código anterior (commit `875331c`) y sobre el actual. Cada llamada se ejecuta como transacción propia, así que los valores son el gas total de una transacción real (incluye el costo base de 21.000):

```bash
forge test --isolate --gas-report --match-contract MedicionGas
```

| Llamada | Antes | Después | Variación |
|---|---|---|---|
| `crearCampania` (primera campaña) | 119.652 | 114.326 | −4,5 % |
| `verificar` | 60.921 | 34.210 | −43,8 % |
| `donar` (primera donación, emite el primer NFT) | 221.032 | 216.273 | −2,2 % |
| `donar` (alcanza la meta) | 191.309 | 186.883 | −2,3 % |
| `retirar` | 46.947 | 40.407 | −13,9 % |
| `reclamarDevolucion` | 43.932 | 38.619 | −12,1 % |
| `estadoActual` (llamada como transacción) | 11.555 | 2.972 | −74,3 % |
| Despliegue (`SaludChain` + `Recibo`) | 2.688.655 | 2.473.484 | −8,0 % |
| Tamaño del contrato (runtime) | 5.838 bytes | 4.843 bytes | −17,0 % |

Versión de Foundry usada: `forge Version: 1.8.5` (commit `51a52c59cf`, compilación del 2026-10-05). Los valores absolutos de gas pueden variar según la versión de Foundry; lo importante son los porcentajes de mejora.

La mayor baja está en `verificar`: con el struct empaquetado, `plazo` comparte slot con `destinatario` y `estado`, que ya tiene datos, así que escribirlo cuesta mucho menos que estrenar un slot vacío. En `donar` la mejora es chica porque la mayor parte del costo es emitir el NFT.

Qué se hizo: (1) no copiar el struct `Campania` entero a memoria: se lee solo cada campo necesario desde un puntero a `storage`, una vez por variable; (2) el struct quedó empaquetado en un solo slot (`destinatario` 20 + `estado` 1 + `duracion` `uint32` 4 + `plazo` `uint40` 5 = 30 bytes); (3) aritmética en `unchecked` solo donde hay un invariante que la hace segura (`faltante = meta - recaudado`, `recaudado + monto` que no supera la meta, `recaudado -= monto` en la devolución, contador de campañas), cada una documentada en el código; (4) al crear una campaña solo se escriben los campos distintos de cero.

## Análisis estático (Slither)

```bash
pip install slither-analyzer
slither . --filter-paths "lib|test|script" > docs/slither.txt 2>&1
```

Los hallazgos y su tratamiento (corregido / falso positivo / aceptado con justificación) están en `docs/slither.md`.

## Seguridad

### Known limitations

**Destinatario que rechaza ETH (resuelto con una ventana de retiro de 30 días).** `retirar(id)` usa el patrón *pull payment*: el pago al destinatario se ejecuta en una transacción separada y no afecta a otras campañas ni a los donantes. Si `destinatario` es un contrato sin `receive()`/`fallback()` payable, o uno que revierte al recibir ETH, la transferencia falla y `retirar` revierte: la campaña queda `Cumplida` con los fondos en custodia. Para que esos fondos **nunca queden bloqueados**, el destinatario tiene `PLAZO_RETIRO` = **30 días** desde que se alcanza la meta. Pasado ese plazo ya no se puede retirar, la campaña pasa a figurar como `Vencida` y **cada donante recupera su aporte** con `reclamarDevolucion(id)`. O cobra el destinatario dentro de los 30 días, o se devuelve a los donantes: nunca hay un estado sin salida. El retiro vale hasta el `plazo` inclusive y la devolución solo después, así que no pueden ejecutarse a la vez.

Cómo se comprobó: `test_Devolucion_DestinatarioQueRechazaLosDonantesRecuperanTodo` (destinatario contrato que rechaza → pasa la ventana → cada donante recupera lo suyo y el contrato queda en cero), pruebas de borde exacto del plazo, fuzzing de devoluciones parciales y un invariante que exige que el saldo del contrato sea siempre igual a la suma de lo recaudado por las campañas no liberadas. En Sepolia no se puede demostrar en vivo porque habría que esperar 30 días: se prueba con `vm.warp` en los tests.

Limitaciones que quedan de este diseño:
- **Un destinatario legítimo que no retira a tiempo pierde el derecho a cobrar**; los donantes recuperan su aporte. Es la contrapartida de que los fondos nunca queden trabados.
- `reclamarDevolucion(id)` también puede fallar si un donante es un contrato que rechaza ETH; en ese caso solo afecta a ese donante y su aporte queda registrado (`test_Devolucion_RevertSiElDonanteRechazaElReembolso`).
- No existe función de rescate ni administrador que pueda mover los fondos: es una decisión de diseño para que nadie pueda disponer de ellos.

**Solución procedimental (complementa la ventana de retiro):**
1. Antes de ejecutar `verificar()`, el `VERIFICADOR_ROLE` confirma que el `destinatario` puede recibir ETH. Para eso se usa preferentemente una wallet EOA del beneficiario o del hospital, o se hace una transferencia de prueba de un monto mínimo en Sepolia.
2. No se verifican campañas cuyo destinatario sea un contrato que no garantice la recepción de ETH.
3. Si igualmente falla la liberación, los fondos quedan en custodia hasta que venza la ventana de retiro; después cada donante los recupera con `reclamarDevolucion`. Con estos controles el caso no debería llegar a esa instancia, y si llega, no hay pérdida de fondos.

## Despliegue y verificación (Sepolia)

```bash
cp .env.example .env     # completar SEPOLIA_RPC_URL, ETHERSCAN_API_KEY, ADMIN_ADDRESS
source .env
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --account <nombre-del-keystore>
# Verificar (SaludChain recibe admin y verificador; Recibo recibe la dirección de SaludChain)
forge verify-contract <DIRECCION_SALUDCHAIN> src/SaludChain.sol:SaludChain --chain sepolia --verifier etherscan \
  --constructor-args $(cast abi-encode "constructor(address,address)" $ADMIN_ADDRESS ${VERIFICADOR_ADDRESS:-$ADMIN_ADDRESS}) --watch
forge verify-contract <DIRECCION_RECIBO> src/Recibo.sol:Recibo --chain sepolia --verifier etherscan \
  --constructor-args $(cast abi-encode "constructor(address)" <DIRECCION_SALUDCHAIN>) --watch
```

> **Nota sobre el gas en Sepolia:** la simulación local de Foundry estima ~3,5 M de gas para el despliegue, pero el nodo de Sepolia exige ~18,8 M (la creación de contratos cuesta más allá). Con `forge script` la transacción sale con el límite subestimado y revierte por `OutOfGas`. Para este despliegue se usó `cast send --create` con `--gas-limit 22000000` (mismo bytecode y mismos argumentos de constructor). `Recibo` lo crea el constructor de `SaludChain`; su dirección se lee con `cast call <SALUDCHAIN> "RECIBO()(address)"`. Verificar con `--verifier etherscan` (el valor por defecto de Foundry es Sourcify).

La clave privada **nunca** se guarda en el repositorio: se usa un keystore de Foundry (`cast wallet import`).

## Frontend

Página estática (HTML + JavaScript + [ethers.js](https://docs.ethers.org/v6/)) en `frontend/`, sin proceso de compilación. Se conecta a los contratos reales mediante MetaMask; sin billetera conectada puede leer las campañas.

**Versión publicada (GitHub Pages):** https://hbarrabasqui.github.io/saludchain/ — alcanza con MetaMask en la red Sepolia.

```bash
# 1. Completar frontend/config.js con las direcciones desplegadas y el bloque de despliegue
# 2. Servir la carpeta (cualquiera de las dos):
python3 -m http.server 8000 --directory frontend      # luego abrir http://localhost:8000
npx serve frontend
```

Pantallas: lista de campañas con estado y barra de progreso (activa, cumplida, vencida, liberada), crear campaña (la huella de la documentación se calcula en el navegador; el archivo no se sube), panel del verificador (aprobar y fijar monto), donar, retirar fondos, recuperar aporte y «Mis recibos» (NFT).

Para operar hace falta MetaMask en la red Sepolia y ETH de prueba. Para la demo conviene usar tres cuentas: creador/destinatario, verificador y donante.

Publicación opcional en GitHub Pages: el workflow `.github/workflows/pages.yml` publica la carpeta `frontend/` (activar en *Settings → Pages → Source: GitHub Actions*).

## Red y direcciones desplegadas

Red: **Sepolia** (chainId 11155111). Despliegue v2 (23/10/2026), bloque `11971361`. Transacción de despliegue: [`0x1bc81cea…3c3687`](https://sepolia.etherscan.io/tx/0x1bc81ceafb269b694a5e26d62c2430df34b3ce62e248666cf12fdd961f3c3687).

| Contrato | Dirección | Código verificado |
|---|---|---|
| SaludChain | [`0x7EA20C63F0B9DD43e715A05eCcef4AB02481b70F`](https://sepolia.etherscan.io/address/0x7EA20C63F0B9DD43e715A05eCcef4AB02481b70F#code) | Sí (Etherscan) |
| Recibo | [`0x5dFA88D4241B389E54859CB513dcfd4218330502`](https://sepolia.etherscan.io/address/0x5dFA88D4241B389E54859CB513dcfd4218330502#code) | Sí (Etherscan) |

Admin: `0x21E352E3C94190403b389DF072b1aFF049b4F9D4` (Kipu_1) · Verificador: `0x8e0aDf95F6B26Ed9E32461086d8289c60a7d851a` (Kipu_3). Ambos se fijaron en el constructor al desplegar.

**El código verificado en Etherscan es idéntico al de este repositorio** (se comparó el SHA-256 de `src/SaludChain.sol` y `src/Recibo.sol` con el código fuente que muestra Etherscan; compilador 0.8.28, optimizador activado con 200 corridas, `evm_version = cancun`).

**Despliegue anterior (v1, reemplazado):** SaludChain `0x8c4D2F8CBe606E03eF5c4Bc39C7543f675F86058` y Recibo `0x3Cf2bcF022fe4f07d21460bD04a3593f2AfbAD27` (18/10/2026). No incluía la ventana de retiro de 30 días: si el destinatario era un contrato que rechazaba ETH, los fondos quedaban bloqueados. Se reemplazó por la v2 para cerrar ese problema de seguridad. Las campañas de prueba de la v1 siguen visibles en Etherscan.

## Transacciones reales del flujo principal

Flujo completo sobre el contrato v2 en Sepolia: una campaña (#1, meta 0,01 ETH, duración de 1 día) creada, verificada, financiada por dos donantes distintos y retirada por su destinatario. Son **exactamente 5 transacciones dirigidas al contrato SaludChain** (`0x7EA20C63…b70F`, desde el bloque 11971361) y **las 5 terminaron con éxito**:

| Paso | Método | Cuenta que la envió | Hash de la transacción | ETH enviado |
|---|---|---|---|---|
| 1 | `crearCampania` | Kipu_2 `0x0B07…08c4` (creador y destinatario) | [`0x99e3e520038f173a186cfec9f85d1843155496b6c4b9ea8f68444dfb6b498d25`](https://sepolia.etherscan.io/tx/0x99e3e520038f173a186cfec9f85d1843155496b6c4b9ea8f68444dfb6b498d25) | — |
| 2 | `verificar` | Kipu_3 `0x8e0a…851a` (verificador) | [`0x521d86b2cf3699954c2740b2a9c640d6b28654587f3f6ef55802edb8df373f20`](https://sepolia.etherscan.io/tx/0x521d86b2cf3699954c2740b2a9c640d6b28654587f3f6ef55802edb8df373f20) | — (aprueba 0,01 ETH) |
| 3 | `donar` | Kipu_1 `0x21E3…F9D4` (donante) | [`0x08b9797a79e73f13e601eaf0feec6d932e56b59c7e602b2a2b198c7eaa0478fd`](https://sepolia.etherscan.io/tx/0x08b9797a79e73f13e601eaf0feec6d932e56b59c7e602b2a2b198c7eaa0478fd) | 0,007 ETH (emite el Recibo #1) |
| 4 | `donar` | Kipu_4, cuarta cuenta `0xF346…59e9` (donante) | [`0x8e5f1a28bde2c1a936a9713e433bc5022852dc0371ad5fe557b59a01c0e0092f`](https://sepolia.etherscan.io/tx/0x8e5f1a28bde2c1a936a9713e433bc5022852dc0371ad5fe557b59a01c0e0092f) | 0,003 ETH (emite el Recibo #2 y cumple la meta) |
| 5 | `retirar` | Kipu_2 `0x0B07…08c4` (destinatario) | [`0xf7696d9934d3ccd243a48f129513dd22104f49533fda72a9e9d2ccdf9c99bb79`](https://sepolia.etherscan.io/tx/0xf7696d9934d3ccd243a48f129513dd22104f49533fda72a9e9d2ccdf9c99bb79) | — (cobra 0,01 ETH) |

**Estado final comprobado en la cadena:**
- La campaña #1 quedó **Liberada**: recaudó 0,01 ETH (100 % de la meta) y el saldo del contrato SaludChain es 0 ETH.
- Se emitieron **2 recibos NFT**, uno por donación: el Recibo #1 a Kipu_1 (0,007 ETH) y el Recibo #2 a Kipu_4 (0,003 ETH). El Recibo #3 no existe.
- El admin (Kipu_1) y el verificador (Kipu_3) se fijaron en el constructor al desplegar, por lo que no hubo transacciones de gestión de roles. La transacción de despliegue está en «Red y direcciones desplegadas».

## ¿Por qué blockchain?

_El crowdfunding tradicional para tratamientos o urgencias médicas enfrenta fricciones críticas: falta de transparencia en la custodia de los fondos, riesgo de desvío hacia fines distintos, comisiones elevadas de intermediarios y la posibilidad de que una campaña recaude fondos insuficientes sin que los donantes puedan recuperarlos.

SaludChain resuelve estos problemas mediante la descentralización y la lógica de contratos inteligentes:

Custodia programable y transparente (Escrow no custodial): Los fondos no son retenidos por una entidad centralizada, plataforma privada ni por el beneficiario por anticipado. Quedan bloqueados en el contrato `SaludChain.sol` bajo la regla determinista de "todo o nada".
Garantía algorítmica de devolución: Si vence el plazo sin alcanzar la meta médica aprobada, el contrato permite a cada donante ejecutar `reclamarDevolucion()` de forma autónoma, sin depender de autorizaciones humanas ni procesos administrativos.
Trazabilidad y comprobante inmutable (NFT Recibo): Cada donación emite automáticamente un comprobante ERC-721 (`Recibo.sol`) en la misma transacción, garantizando la prueba de participación, la contabilidad pública y evitando la adulteración de recibos de donación.
Separación de roles y control de acceso: La incorporación de `VERIFICADOR_ROLE` (vía `AccessControl`) desacopla la creación de la campaña de su validación, impidiendo que metas arbitrarias o no avaladas entren en período de recaudación activa sin un filtro de legitimidad.

_

## Limitaciones conocidas del MVP

- El **verificador es una cuenta de confianza** con un rol en el contrato; en producción debería reemplazarse por la firma de un médico validado contra un registro de matrículas.
- La devolución está atada a la dirección que donó, no al NFT (el recibo es transferible).
- Solo se aceptan donaciones en ETH, sin conversión de moneda local.
- Esquema "todo o nada": no hay liberación parcial ni por hitos.
- Una campaña que nunca se verifica queda Pendiente indefinidamente.
- El destinatario tiene 30 días para retirar una vez cumplida la meta; si no lo hace, los donantes recuperan su aporte (ver «Seguridad → Known limitations»).

_(el resto de las limitaciones se completa en equipo)_

## Marco legal y de riesgos

_Protección de Datos Personales y Sensibles (Ley 25.326 / GDPR)
  Privacidad por diseño (Privacy by Design): Ningún dato de salud (diagnósticos, presupuestos detallados o datos filiatorios del paciente) se sube a la blockchain ni a servidores del frontend. 
  Disociación criptográfica: La función `crearCampania` almacena únicamente un `hashDocs` (Keccak-256) generado localmente en el navegador del usuario. El documento original permanece en poder del paciente/médico, haciendo técnicamente inviable la reconstrucción o filtración de datos de salud a partir del estado on-chain.
Naturaleza Jurídica de los Fondos y Donaciones:
 Las transferencias configuran donaciones sujetas a condición resolutoria expresa (alcanzar la meta dentro del plazo estipulado). El contrato inteligente actúa como una ejecución técnica automatizada de dicha condición (art. 343 y concs. del CCCN).
* **Validez Probatoria del NFT:**
  * El token ERC-721 opera exclusivamente como constancia digital de entrega de fondos (recibo no fungible) y principio de prueba de la liberalidad efectuada; no confiere derechos de propiedad sobre tratamientos ni constituye un activo financiero / valor negociable (security).

### Matriz de Riesgos y Mitigaciones

| Categoría | Riesgo Identificado | Impacto | Mitigación Implementada / Propuesta |
| :--- | :--- | :--- | :--- |
| Financiero | Volatilidad de ETH entre el inicio de campaña y el retiro | Alto | Planificado: aviso en la interfaz sobre la cotización y migración a stablecoins (USDC/USDT) con oráculo Chainlink (hoy no implementado; ver «¿Por qué se dona en ETH y no en una stablecoin?»). |
| Seguridad Smart Contracts | Vulnerabilidades de reentrancia o manipulación de balances | Crítico | Uso de `ReentrancyGuard`, patrón *Checks-Effects-Interactions*, contabilidad interna desacoplada de `address(this).balance` y análisis estático con Slither. |
| Operativo / Fraude | Colusión o falsificación de presupuestos médicos | Alto | Implementación de `hashDocs` para cotejo pericial y rol `VERIFICADOR_ROLE`. En roadmap: firma criptográfica de profesionales matriculados. |
| Legal / Compliance | Cumplimiento tributario y origen de fondos en montos elevados | Medio | Trazabilidad pública de transacciones en Explorer; la plataforma no custodia claves ni fondos (es meramente una interfaz no permisionada). |

_

## Roadmap

[Roadmap de evolución completo (PDF, Pablo Lafargue)](Roadmap%20de%20Salud%20Chain%20Evolution.pdf)

Visión a largo plazo. El MVP implementado corresponde a la Fase 1: el retiro y las devoluciones se hacen por reclamo del destinatario o del donante (no son automáticos) y el contrato ya emite los eventos de auditoría.

_Fase 1: MVP Core (Completado)
- [x] Arquitectura de contratos base (`SaludChain.sol` y `Recibo.sol` ERC-721).
- [x] Control de acceso granular (`AccessControl`) y protección contra reentrancia (`ReentrancyGuard`).
- [x] Lógica de depósito, meta estricta, retiro por *pull payment* y devolución automatizada.
- [x] Suite de tests y cobertura exhaustiva en Foundry.
- [x] Auditoría estática mediante Slither y mitigación de hallazgos.
- [x] Despliegue y verificación en testnet Sepolia.
- [x] Frontend estático Web3 en GitHub Pages con cálculo local de `hashDocs`.

 Fase 2: Robustez Económica y Multi-Token (Corto Plazo)
- [ ] Soporte para donaciones en stablecoins (USDC, USDT, DAI) utilizando la librería `SafeERC20`.
- [ ] Integración de Chainlink Price Feeds (ETH/USD) para fijar metas médicas en moneda estable permitiendo pagos combinados.
- [ ] Mecanismo de cancelación o cierre anticipado justificado por parte del creador o verificador con devolución automática de aportes.

 Fase 3: Identidad y Gobernanza de la Verificación (Mediano Plazo)
- [ ] Descentralización del rol de verificador: reemplazo de la EOA de confianza por un esquema multisig (Safe) o validación criptográfica contra colegios médicos / registros de prestadores de salud.
- [ ] Soporte para liberación de fondos por hitos médicos comprobables (ej. 30% diagnóstico e internación, 70% intervención quirúrgica) mediante aprobación por etapas.
- [ ] Implementación de Soulbound Tokens (SBT) no transferibles para los comprobantes de donación cuando aplique deducción impositiva.

 Fase 4: Escalabilidad y UX (Largo Plazo)
- [ ] Despliegue en redes de Capa 2 (L2) como Arbitrum, Optimism o Base para reducir los costos de gas a fracciones de centavo.
- [ ] Abstracción de Cuentas (ERC-4337 / Paymasters) para habilitar donaciones con tarjetas o moneda local mediante patrocinio de gas (*gasless transactions*).
_
