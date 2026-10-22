// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Recibo} from "./Recibo.sol";

/// @title SaludChain
/// @author Equipo SaludChain
/// @notice Campañas de donación para gastos médicos con custodia en el contrato (escrow).
///         El dinero queda dentro del contrato: se libera al destinatario solo si se alcanza
///         la meta; si el plazo vence sin alcanzarla, cada donante recupera su aporte.
///         Una vez alcanzada la meta, el destinatario tiene {PLAZO_RETIRO} para retirar. Si no lo
///         hace en ese plazo (por ejemplo, porque su dirección es un contrato que rechaza ETH),
///         los donantes recuperan su aporte: los fondos nunca quedan bloqueados.
/// @dev Roles: `DEFAULT_ADMIN_ROLE` administra a los verificadores; `VERIFICADOR_ROLE`
///      aprueba campañas y fija el monto aprobado. Cada donación emite un NFT de comprobante
///      en el contrato {Recibo}. Esquema "todo o nada". El estado `Vencida` es derivado:
///      nunca se guarda, se calcula en {estadoActual}.
///      Línea de tiempo de una campaña: `verificar` fija `plazo` (fin del período de donación);
///      al alcanzarse la meta, `donar` vuelve a fijar `plazo` (fin de la ventana de retiro).
///      `retirar` solo es válido hasta `plazo` inclusive y `reclamarDevolucion` solo después, de modo
///      que nunca pueden ejecutarse ambas en el mismo instante.
///      Invariante: el saldo del contrato es igual a la suma de `recaudado` de las campañas que no están Liberadas.
contract SaludChain is AccessControl, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 TIPOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Estados posibles de una campaña.
    /// @dev `Vencida` solo aparece como resultado de {estadoActual}; nunca se almacena.
    enum Estado {
        Pendiente, // creada, esperando verificación
        Activa, // verificada, acepta donaciones hasta el plazo
        Cumplida, // meta alcanzada, cerrada a nuevas donaciones; el destinatario puede retirar hasta el plazo
        Liberada, // fondos retirados por el destinatario
        Vencida // venció el plazo sin alcanzar la meta, o sin retirar tras alcanzarla (derivado)
    }

    /// @notice Datos de una campaña.
    /// @dev `destinatario`, `estado`, `duracion` y `plazo` ocupan juntos un solo slot de almacenamiento
    ///      (20 + 1 + 4 + 5 = 30 bytes). `uint32` alcanza para `DURACION_MAXIMA` (180 días) y `uint40` para
    ///      marcas de tiempo hasta el año 36812.
    /// @param destinatario Dirección que cobra los fondos si se cumple la meta (paciente, clínica o proveedor).
    /// @param estado Estado almacenado de la campaña.
    /// @param duracion Duración en segundos que tendrá la campaña una vez verificada.
    /// @param plazo Marca de tiempo límite: fin del período de donación (si está Activa) o fin de la
    ///        ventana de retiro (si está Cumplida). Vale 0 hasta que se verifica.
    /// @param meta Monto objetivo en wei. Al verificar pasa a ser el monto aprobado.
    /// @param recaudado Monto actualmente custodiado para la campaña, en wei.
    /// @param hashDocs Huella (hash) de la documentación médica guardada fuera de la cadena.
    struct Campania {
        address destinatario;
        Estado estado;
        uint32 duracion;
        uint40 plazo;
        uint256 meta;
        uint256 recaudado;
        bytes32 hashDocs;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTES
    //////////////////////////////////////////////////////////////*/

    /// @notice Rol de quien puede aprobar campañas (médico habilitado en producción).
    bytes32 public constant VERIFICADOR_ROLE = keccak256("VERIFICADOR_ROLE");

    /// @notice Duración mínima permitida para una campaña.
    uint32 public constant DURACION_MINIMA = 1 hours;

    /// @notice Duración máxima permitida para una campaña.
    uint32 public constant DURACION_MAXIMA = 180 days;

    /// @notice Tiempo que tiene el destinatario para retirar, contado desde que se alcanza la meta.
    ///         Pasado ese plazo, los donantes pueden recuperar su aporte con {reclamarDevolucion}.
    uint32 public constant PLAZO_RETIRO = 30 days;

    /*//////////////////////////////////////////////////////////////
                                 ESTADO
    //////////////////////////////////////////////////////////////*/

    /// @notice Contrato NFT que emite los comprobantes de donación.
    Recibo public immutable RECIBO;

    /// @dev Cantidad de campañas creadas (el último identificador usado).
    uint256 private _cantidadCampanias;

    /// @dev Campañas por identificador (los identificadores empiezan en 1).
    mapping(uint256 campaniaId => Campania campania) private _campanias;

    /// @dev Monto aportado por cada donante a cada campaña (para poder devolverlo).
    mapping(uint256 campaniaId => mapping(address donante => uint256 monto)) private _aportes;

    /*//////////////////////////////////////////////////////////////
                                EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Se creó una campaña (queda Pendiente de verificación).
    /// @param campaniaId Identificador de la campaña.
    /// @param creador Quien la creó.
    /// @param destinatario Quien cobrará los fondos si se cumple la meta.
    /// @param meta Monto solicitado en wei.
    /// @param duracion Duración en segundos una vez verificada.
    /// @param hashDocs Huella de la documentación médica (fuera de la cadena).
    event CampaniaCreada(
        uint256 indexed campaniaId,
        address indexed creador,
        address indexed destinatario,
        uint256 meta,
        uint32 duracion,
        bytes32 hashDocs
    );

    /// @notice Un verificador aprobó una campaña.
    /// @param campaniaId Identificador de la campaña.
    /// @param verificador Quien la aprobó.
    /// @param montoAprobado Monto aprobado, que pasa a ser la meta.
    /// @param plazo Marca de tiempo límite para donar.
    event CampaniaVerificada(
        uint256 indexed campaniaId, address indexed verificador, uint256 montoAprobado, uint40 plazo
    );

    /// @notice Se registró una donación.
    /// @param campaniaId Identificador de la campaña.
    /// @param donante Quien donó.
    /// @param monto Monto donado en wei.
    /// @param reciboId Identificador del NFT de comprobante emitido.
    event DonacionRecibida(
        uint256 indexed campaniaId, address indexed donante, uint256 monto, uint256 reciboId
    );

    /// @notice La campaña alcanzó su meta y se cerró a nuevas donaciones.
    /// @dev Desde este momento corre la ventana de retiro de {PLAZO_RETIRO}.
    /// @param campaniaId Identificador de la campaña.
    /// @param recaudado Monto total recaudado en wei.
    event CampaniaCumplida(uint256 indexed campaniaId, uint256 recaudado);

    /// @notice El destinatario retiró los fondos de una campaña cumplida.
    /// @param campaniaId Identificador de la campaña.
    /// @param destinatario Quien cobró.
    /// @param monto Monto transferido en wei.
    event FondosLiberados(uint256 indexed campaniaId, address indexed destinatario, uint256 monto);

    /// @notice Un donante recuperó su aporte de una campaña vencida.
    /// @param campaniaId Identificador de la campaña.
    /// @param donante Quien recuperó su aporte.
    /// @param monto Monto devuelto en wei.
    event DonacionDevuelta(uint256 indexed campaniaId, address indexed donante, uint256 monto);

    /*//////////////////////////////////////////////////////////////
                                ERRORES
    //////////////////////////////////////////////////////////////*/

    /// @notice La campaña no existe.
    /// @param campaniaId Identificador consultado.
    error CampaniaInexistente(uint256 campaniaId);

    /// @notice La operación no es válida en el estado actual de la campaña.
    /// @param campaniaId Identificador de la campaña.
    /// @param estado Estado en que se encuentra.
    error EstadoInvalido(uint256 campaniaId, Estado estado);

    /// @notice Alguna dirección requerida es la dirección cero.
    error DireccionInvalida();

    /// @notice La meta debe ser mayor que cero.
    error MetaInvalida();

    /// @notice La duración está fuera del rango permitido.
    /// @param duracion Duración recibida en segundos.
    error DuracionInvalida(uint32 duracion);

    /// @notice La huella de la documentación no puede ser vacía.
    error HashDocsInvalido();

    /// @notice El monto aprobado debe ser mayor que cero y no superar la meta solicitada.
    /// @param montoAprobado Monto recibido.
    /// @param metaSolicitada Meta solicitada por quien creó la campaña.
    error MontoAprobadoInvalido(uint256 montoAprobado, uint256 metaSolicitada);

    /// @notice La donación debe ser mayor que cero.
    error MontoCero();

    /// @notice La campaña ya superó su plazo para recibir donaciones.
    /// @param campaniaId Identificador de la campaña.
    error PlazoVencido(uint256 campaniaId);

    /// @notice La donación superaría la meta de la campaña.
    /// @param faltante Monto que todavía falta para llegar a la meta, en wei.
    error ExcedeMeta(uint256 faltante);

    /// @notice Quien llama no es el destinatario de la campaña.
    /// @param campaniaId Identificador de la campaña.
    error NoEsDestinatario(uint256 campaniaId);

    /// @notice Ya pasó la ventana de retiro: los fondos solo pueden recuperarlos los donantes.
    /// @param campaniaId Identificador de la campaña.
    error VentanaDeRetiroVencida(uint256 campaniaId);

    /// @notice La devolución no está disponible: el plazo todavía no venció o la campaña no está en un
    ///         estado reembolsable (Pendiente o ya Liberada).
    /// @param campaniaId Identificador de la campaña.
    error DevolucionNoDisponible(uint256 campaniaId);

    /// @notice Quien llama no tiene aportes para devolver en esta campaña.
    /// @param campaniaId Identificador de la campaña.
    error SinAportes(uint256 campaniaId);

    /// @notice Falló la transferencia de ETH.
    error TransferenciaFallida();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Despliega SaludChain y, junto con él, el contrato de recibos NFT.
    /// @param admin Dirección que administra los roles (puede agregar o quitar verificadores).
    /// @param verificador Primera dirección habilitada para verificar campañas.
    constructor(address admin, address verificador) {
        if (admin == address(0) || verificador == address(0)) revert DireccionInvalida();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VERIFICADOR_ROLE, verificador);
        RECIBO = new Recibo(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                          FUNCIONES PRINCIPALES
    //////////////////////////////////////////////////////////////*/

    /// @notice Crea una campaña de donación. Queda Pendiente hasta que un verificador la apruebe.
    /// @dev Los documentos médicos NO se guardan on-chain: solo su huella (`hashDocs`).
    ///      Solo se escriben los campos distintos de cero: el storage de una campaña nueva está en cero,
    ///      lo que equivale a `estado = Pendiente`, `plazo = 0` y `recaudado = 0`.
    /// @param destinatario Quien cobrará los fondos si se cumple la meta.
    /// @param meta Monto solicitado en wei.
    /// @param duracion Duración en segundos que tendrá la campaña una vez verificada.
    /// @param hashDocs Huella de la documentación médica guardada fuera de la cadena.
    /// @return campaniaId Identificador de la campaña creada.
    function crearCampania(address destinatario, uint256 meta, uint32 duracion, bytes32 hashDocs)
        external
        returns (uint256 campaniaId)
    {
        if (destinatario == address(0)) revert DireccionInvalida();
        if (meta == 0) revert MetaInvalida();
        if (duracion < DURACION_MINIMA || duracion > DURACION_MAXIMA) revert DuracionInvalida(duracion);
        if (hashDocs == bytes32(0)) revert HashDocsInvalido();

        // No puede desbordar: haría falta crear 2**256 campañas.
        unchecked {
            campaniaId = _cantidadCampanias + 1;
        }
        _cantidadCampanias = campaniaId;

        Campania storage c = _campanias[campaniaId];
        c.destinatario = destinatario;
        c.duracion = duracion;
        c.meta = meta;
        c.hashDocs = hashDocs;

        emit CampaniaCreada(campaniaId, msg.sender, destinatario, meta, duracion, hashDocs);
    }

    /// @notice Aprueba una campaña y fija el monto aprobado, que pasa a ser la meta.
    /// @dev Solo `VERIFICADOR_ROLE`. El monto aprobado nunca puede superar lo solicitado.
    ///      El plazo para donar empieza a correr desde la verificación.
    /// @param campaniaId Identificador de la campaña.
    /// @param montoAprobado Monto aprobado en wei (mayor que cero y menor o igual a la meta solicitada).
    function verificar(uint256 campaniaId, uint256 montoAprobado) external onlyRole(VERIFICADOR_ROLE) {
        Campania storage c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        Estado estado = c.estado;
        if (estado != Estado.Pendiente) revert EstadoInvalido(campaniaId, estado);
        uint256 metaSolicitada = c.meta;
        if (montoAprobado == 0 || montoAprobado > metaSolicitada) {
            revert MontoAprobadoInvalido(montoAprobado, metaSolicitada);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 plazo = uint40(block.timestamp + c.duracion); // uint40 alcanza hasta el año 36812

        c.estado = Estado.Activa;
        c.meta = montoAprobado;
        c.plazo = plazo;

        emit CampaniaVerificada(campaniaId, msg.sender, montoAprobado, plazo);
    }

    /// @notice Dona ETH a una campaña activa y recibe un NFT de comprobante.
    /// @dev No acepta donaciones que superen la meta: la campaña nunca recauda más de lo aprobado.
    ///      Al alcanzar la meta la campaña pasa a Cumplida y empieza la ventana de retiro de {PLAZO_RETIRO}.
    ///      Sigue el patrón checks-effects-interactions: el estado se actualiza antes de emitir el recibo.
    /// @param campaniaId Identificador de la campaña.
    /// @return reciboId Identificador del NFT de comprobante emitido.
    function donar(uint256 campaniaId) external payable nonReentrant returns (uint256 reciboId) {
        Campania storage c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        Estado estado = c.estado;
        if (estado != Estado.Activa) revert EstadoInvalido(campaniaId, estado);
        if (block.timestamp > c.plazo) revert PlazoVencido(campaniaId);
        if (msg.value == 0) revert MontoCero();

        uint256 meta = c.meta;
        uint256 recaudado = c.recaudado;

        // `recaudado <= meta` siempre: `verificar` deja `recaudado = 0` y acá nunca se supera la meta.
        uint256 faltante;
        unchecked {
            faltante = meta - recaudado;
        }
        if (msg.value > faltante) revert ExcedeMeta(faltante);

        // No desborda: `msg.value <= faltante`, por lo tanto el resultado es `<= meta`.
        uint256 nuevoRecaudado;
        unchecked {
            nuevoRecaudado = recaudado + msg.value;
        }
        c.recaudado = nuevoRecaudado;

        bool cumplida = nuevoRecaudado == meta;
        if (cumplida) {
            c.estado = Estado.Cumplida;
            // forge-lint: disable-next-line(unsafe-typecast)
            c.plazo = uint40(block.timestamp + PLAZO_RETIRO); // empieza la ventana de retiro
        }

        // No desborda: el aporte de un donante es parte de `recaudado`, que ya es `<= meta`.
        unchecked {
            _aportes[campaniaId][msg.sender] += msg.value;
        }

        reciboId = RECIBO.emitir(msg.sender, campaniaId, msg.value);

        emit DonacionRecibida(campaniaId, msg.sender, msg.value, reciboId);
        if (cumplida) emit CampaniaCumplida(campaniaId, nuevoRecaudado);
    }

    /// @notice El destinatario retira los fondos de una campaña cumplida, dentro de la ventana de retiro.
    /// @dev Pull payment: el contrato nunca envía fondos por su cuenta. Marca la campaña como
    ///      Liberada antes de transferir (checks-effects-interactions) y está protegido contra reentrada.
    ///      Solo se puede retirar hasta `plazo` inclusive; pasado ese momento, los donantes pueden
    ///      recuperar su aporte con {reclamarDevolucion}.
    ///      Si `destinatario` es un contrato que rechaza ETH, la transferencia revierte y la campaña
    ///      queda Cumplida; al vencer la ventana de retiro los donantes recuperan sus aportes, por lo que
    ///      los fondos no quedan bloqueados.
    /// @param campaniaId Identificador de la campaña.
    function retirar(uint256 campaniaId) external nonReentrant {
        Campania storage c = _campanias[campaniaId];
        address destinatario = c.destinatario;
        if (destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        if (msg.sender != destinatario) revert NoEsDestinatario(campaniaId);
        Estado estado = c.estado;
        if (estado != Estado.Cumplida) revert EstadoInvalido(campaniaId, estado);
        if (block.timestamp > c.plazo) revert VentanaDeRetiroVencida(campaniaId);

        uint256 monto = c.recaudado;
        c.estado = Estado.Liberada;

        emit FondosLiberados(campaniaId, destinatario, monto);

        (bool ok,) = payable(destinatario).call{value: monto}("");
        if (!ok) revert TransferenciaFallida();
    }

    /// @notice Un donante recupera su aporte de una campaña que ya no puede cobrarse.
    /// @dev Esquema "todo o nada". Aplica a campañas Activas cuyo plazo de donación venció sin alcanzar
    ///      la meta, y a campañas Cumplidas cuya ventana de retiro venció sin que el destinatario retirara.
    ///      La devolución está atada a la dirección que donó, no al NFT. Cada devolución reduce `recaudado`;
    ///      una campaña vencida nunca vuelve a poder retirarse.
    /// @param campaniaId Identificador de la campaña.
    function reclamarDevolucion(uint256 campaniaId) external nonReentrant {
        Campania storage c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        Estado estado = c.estado;
        bool reembolsable = estado == Estado.Activa || estado == Estado.Cumplida;
        if (!reembolsable || block.timestamp <= c.plazo) revert DevolucionNoDisponible(campaniaId);

        uint256 monto = _aportes[campaniaId][msg.sender];
        if (monto == 0) revert SinAportes(campaniaId);

        _aportes[campaniaId][msg.sender] = 0;
        // No puede dar underflow: la suma de los aportes es igual a `recaudado`, y `monto` es uno de ellos.
        unchecked {
            c.recaudado -= monto;
        }

        emit DonacionDevuelta(campaniaId, msg.sender, monto);

        (bool ok,) = payable(msg.sender).call{value: monto}("");
        if (!ok) revert TransferenciaFallida();
    }

    /*//////////////////////////////////////////////////////////////
                               CONSULTAS
    //////////////////////////////////////////////////////////////*/

    /// @notice Cantidad total de campañas creadas (los identificadores van de 1 a este valor).
    /// @return cantidad Cantidad de campañas.
    function totalCampanias() external view returns (uint256 cantidad) {
        return _cantidadCampanias;
    }

    /// @notice Devuelve los datos almacenados de una campaña.
    /// @param campaniaId Identificador de la campaña.
    /// @return datos Datos de la campaña tal como están guardados (el estado nunca es `Vencida`).
    function campania(uint256 campaniaId) external view returns (Campania memory datos) {
        datos = _campanias[campaniaId];
        if (datos.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
    }

    /// @notice Estado efectivo de una campaña, incluyendo `Vencida` (derivado del plazo).
    /// @dev Devuelve `Vencida` para una campaña Activa que superó su plazo de donación y para una Cumplida
    ///      que superó su ventana de retiro sin ser retirada.
    /// @param campaniaId Identificador de la campaña.
    /// @return estado Estado actual.
    function estadoActual(uint256 campaniaId) external view returns (Estado estado) {
        Campania storage c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        estado = c.estado;
        if ((estado == Estado.Activa || estado == Estado.Cumplida) && block.timestamp > c.plazo) {
            return Estado.Vencida;
        }
    }

    /// @notice Monto que un donante aportó (y puede recuperar si la campaña vence) en una campaña.
    /// @param campaniaId Identificador de la campaña.
    /// @param donante Dirección del donante.
    /// @return monto Monto aportado en wei.
    function aporteDe(uint256 campaniaId, address donante) external view returns (uint256 monto) {
        return _aportes[campaniaId][donante];
    }
}
