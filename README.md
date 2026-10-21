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

**Estados de una campaña:** `Pendiente → Activa → Cumplida → Liberada`; o `Vencida` (derivado: plazo vencido sin alcanzar la meta → devolución).

**Flujo principal:**
1. `crearCampania(destinatario, meta, duracion, hashDocs)` → queda **Pendiente** (solo se guarda la huella de la documentación, nunca datos médicos).
2. `verificar(id, montoAprobado)` (solo `VERIFICADOR_ROLE`) → **Activa**; el monto aprobado pasa a ser la meta y arranca el plazo.
3. `donar(id)` (payable) → suma al recaudado y emite el NFT `Recibo`. No acepta más de lo que falta para la meta; al llegar a ella la campaña pasa a **Cumplida** y se cierra.
4. `retirar(id)` → el destinatario cobra (pull payment). Pasa a **Liberada**.
5. Si venció el plazo sin llegar a la meta: `reclamarDevolucion(id)` → cada donante recupera su aporte.

Buenas prácticas aplicadas: NatSpec completo, eventos, custom errors, patrón checks-effects-interactions, `ReentrancyGuard`, contabilidad interna (no depende de `address(this).balance`), una lectura y una escritura de storage por variable en cada función.

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
```

## Análisis estático (Slither)

```bash
pip install slither-analyzer
slither . --filter-paths "lib|test|script" > docs/slither.txt 2>&1
```

Los hallazgos y su tratamiento (corregido / falso positivo / aceptado con justificación) están en `docs/slither.md`.

## Seguridad

### Known limitations

**Destinatario que rechaza ETH.** Al liberar los fondos, `SaludChain` envía ETH a la dirección `destinatario` de la campaña. Si esa dirección es un contrato sin función `receive()`/`fallback()` payable, o uno que revierte al recibir ETH, la transferencia falla y la transacción de retiro revierte. Los fondos no se pierden: permanecen custodiados en el contrato, porque el revert deshace todo el cambio de estado. Sin embargo, no pueden liberarse a ese destinatario.

**Solución procedimental (mitigación):**
1. **Validación previa a la verificación:** antes de ejecutar `verificar()`, el `VERIFICADOR_ROLE` confirma que el `destinatario` puede recibir ETH. Para eso se usa preferentemente una cuenta EOA (wallet) del hospital o del beneficiario, o se realiza una transferencia de prueba de un monto mínimo en Sepolia.
2. **No se verifican campañas** cuyo destinatario sea un contrato que no garantice la recepción de ETH.
3. **Ante una falla en la liberación,** los fondos quedan en el contrato y el caso se escala al equipo para su resolución. Las devoluciones a donantes siguen disponibles si la campaña vence.

**Mejora futura:** migrar la liberación al patrón *pull over push* (withdrawal pattern), para que el destinatario retire sus fondos en lugar de recibirlos por envío directo.

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

Red: **Sepolia** (chainId 11155111). Bloque de despliegue: `11937714`. Transacción de despliegue: [`0xeb6b9e77…38251e`](https://sepolia.etherscan.io/tx/0xeb6b9e77c09109764065a2b160254e7ff91d1d8087b7963e930a1f51cb38251e).

| Contrato | Dirección | Código verificado |
|---|---|---|
| SaludChain | [`0x8c4D2F8CBe606E03eF5c4Bc39C7543f675F86058`](https://sepolia.etherscan.io/address/0x8c4D2F8CBe606E03eF5c4Bc39C7543f675F86058#code) | Sí (Etherscan) |
| Recibo | [`0x3Cf2bcF022fe4f07d21460bD04a3593f2AfbAD27`](https://sepolia.etherscan.io/address/0x3Cf2bcF022fe4f07d21460bD04a3593f2AfbAD27#code) | Sí (Etherscan) |

Admin: `0x21E352E3C94190403b389DF072b1aFF049b4F9D4` · Verificador inicial (al desplegar): `0x0B0729677a5793422D070C17aC66B485FaD108c4`. Verificador actual: `0x8e0aDf95F6B26Ed9E32461086d8289c60a7d851a` (ver «Transacciones reales»).

## Transacciones reales del flujo principal

Flujo completo de la campaña #1 en Sepolia (meta 0,01 ETH), con tres cuentas distintas:

| Paso | Cuenta | Transacción |
|---|---|---|
| Crear campaña | Kipu_2 (creador/destinatario) `0x0B07…08c4` | [`0x53127fab…285c80`](https://sepolia.etherscan.io/tx/0x53127fab4d6f38262e105c66499b7206a0071edf56eafc34f0057cab0d285c80) |
| Verificar (aprobar 0,01 ETH) | Kipu_3 (verificador) `0x8e0a…d851a` | [`0x948984b2…d0211d`](https://sepolia.etherscan.io/tx/0x948984b29107aebaa23317db616f8fb5ce67d5ef2db5175d5c47078432d0211d) |
| Donar 0,01 ETH (emite NFT Recibo #1) | Kipu_1 (donante/admin) `0x21E3…F9D4` | [`0x78782296…c8d6`](https://sepolia.etherscan.io/tx/0x78782296655600cca593d5e088758e842c87793698e3d27abe68b95f37b7c8d6) |
| Retirar fondos | Kipu_2 (destinatario) | [`0x9dc7d388…cdcac`](https://sepolia.etherscan.io/tx/0x9dc7d388ad161d6d4cbbe5dff7adc79a33290bd014f76e3f6bb68413c8fcdcac) |

Gestión de roles (el admin le dio el rol de verificador a Kipu_3 y se lo quitó a Kipu_2, que era el verificador inicial del despliegue):
[`grantRole`](https://sepolia.etherscan.io/tx/0xd04ae3bca4eb50c02269329d929f05b0d5cfaf30ecfcd42a5e3fb3dbc47f87a0) · [`revokeRole`](https://sepolia.etherscan.io/tx/0x8a0afb1f3efa2bcf72ceca88b523083cc7fcb5b6d33058bb782445d34b6af0fe).

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
| Financiero | Volatilidad de ETH entre el inicio de campaña y el retiro | Alto | Alerta en UI sobre cotización. Planificado: migración a stablecoins (USDC/USDT) con oráculo Chainlink. |
| Seguridad Smart Contracts | Vulnerabilidades de reentrancia o manipulación de balances | Crítico | Uso de `ReentrancyGuard`, patrón *Checks-Effects-Interactions*, contabilidad interna desacoplada de `address(this).balance` y análisis estático con Slither. |
| Operativo / Fraude | Colusión o falsificación de presupuestos médicos | Alto | Implementación de `hashDocs` para cotejo pericial y rol `VERIFICADOR_ROLE`. En roadmap: firma criptográfica de profesionales matriculados. |
| Legal / Compliance | Cumplimiento tributario y origen de fondos en montos elevados | Medio | Trazabilidad pública de transacciones en Explorer; la plataforma no custodia claves ni fondos (es meramente una interfaz no permisionada). |

_

## Roadmap

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
