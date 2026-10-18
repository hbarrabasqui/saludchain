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
/// @dev Roles: `DEFAULT_ADMIN_ROLE` administra a los verificadores; `VERIFICADOR_ROLE`
///      aprueba campañas y fija el monto aprobado. Cada donación emite un NFT de comprobante
///      en el contrato {Recibo}. Esquema "todo o nada". El estado `Vencida` es derivado:
///      nunca se guarda, se calcula en {estadoActual}.
contract SaludChain is AccessControl, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 TIPOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Estados posibles de una campaña.
    /// @dev `Vencida` solo aparece como resultado de {estadoActual}; nunca se almacena.
    enum Estado {
        Pendiente, // creada, esperando verificación
        Activa, // verificada, acepta donaciones hasta el plazo
        Cumplida, // meta alcanzada, cerrada a nuevas donaciones
        Liberada, // fondos retirados por el destinatario
        Vencida // venció el plazo sin alcanzar la meta (derivado)
    }

    /// @notice Datos de una campaña.
    /// @param destinatario Dirección que cobra los fondos si se cumple la meta (paciente, clínica o proveedor).
    /// @param estado Estado almacenado de la campaña.
    /// @param duracion Duración en segundos que tendrá la campaña una vez verificada.
    /// @param plazo Marca de tiempo límite para donar (0 hasta que se verifica).
    /// @param meta Monto objetivo en wei. Al verificar pasa a ser el monto aprobado.
    /// @param recaudado Monto actualmente custodiado para la campaña, en wei.
    /// @param hashDocs Huella (hash) de la documentación médica guardada fuera de la cadena.
    struct Campania {
        address destinatario;
        Estado estado;
        uint64 duracion;
        uint64 plazo;
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
    uint64 public constant DURACION_MINIMA = 1 hours;

    /// @notice Duración máxima permitida para una campaña.
    uint64 public constant DURACION_MAXIMA = 180 days;

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
        uint64 duracion,
        bytes32 hashDocs
    );

    /// @notice Un verificador aprobó una campaña.
    /// @param campaniaId Identificador de la campaña.
    /// @param verificador Quien la aprobó.
    /// @param montoAprobado Monto aprobado, que pasa a ser la meta.
    /// @param plazo Marca de tiempo límite para donar.
    event CampaniaVerificada(
        uint256 indexed campaniaId, address indexed verificador, uint256 montoAprobado, uint64 plazo
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
    error DuracionInvalida(uint64 duracion);

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

    /// @notice La campaña todavía no venció o ya alcanzó su meta, por lo que no hay devolución.
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
    /// @param destinatario Quien cobrará los fondos si se cumple la meta.
    /// @param meta Monto solicitado en wei.
    /// @param duracion Duración en segundos que tendrá la campaña una vez verificada.
    /// @param hashDocs Huella de la documentación médica guardada fuera de la cadena.
    /// @return campaniaId Identificador de la campaña creada.
    function crearCampania(address destinatario, uint256 meta, uint64 duracion, bytes32 hashDocs)
        external
        returns (uint256 campaniaId)
    {
        if (destinatario == address(0)) revert DireccionInvalida();
        if (meta == 0) revert MetaInvalida();
        if (duracion < DURACION_MINIMA || duracion > DURACION_MAXIMA) revert DuracionInvalida(duracion);
        if (hashDocs == bytes32(0)) revert HashDocsInvalido();

        campaniaId = _cantidadCampanias + 1;
        _cantidadCampanias = campaniaId;

        _campanias[campaniaId] = Campania({
            destinatario: destinatario,
            estado: Estado.Pendiente,
            duracion: duracion,
            plazo: 0,
            meta: meta,
            recaudado: 0,
            hashDocs: hashDocs
        });

        emit CampaniaCreada(campaniaId, msg.sender, destinatario, meta, duracion, hashDocs);
    }

    /// @notice Aprueba una campaña y fija el monto aprobado, que pasa a ser la meta.
    /// @dev Solo `VERIFICADOR_ROLE`. El monto aprobado nunca puede superar lo solicitado.
    ///      El plazo para donar empieza a correr desde la verificación.
    /// @param campaniaId Identificador de la campaña.
    /// @param montoAprobado Monto aprobado en wei (mayor que cero y menor o igual a la meta solicitada).
    function verificar(uint256 campaniaId, uint256 montoAprobado) external onlyRole(VERIFICADOR_ROLE) {
        Campania memory c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        if (c.estado != Estado.Pendiente) revert EstadoInvalido(campaniaId, c.estado);
        if (montoAprobado == 0 || montoAprobado > c.meta) revert MontoAprobadoInvalido(montoAprobado, c.meta);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 plazo = uint64(block.timestamp) + c.duracion; // uint64 alcanza para siglos

        Campania storage s = _campanias[campaniaId];
        s.estado = Estado.Activa;
        s.meta = montoAprobado;
        s.plazo = plazo;

        emit CampaniaVerificada(campaniaId, msg.sender, montoAprobado, plazo);
    }

    /// @notice Dona ETH a una campaña activa y recibe un NFT de comprobante.
    /// @dev No acepta donaciones que superen la meta: la campaña nunca recauda más de lo aprobado.
    ///      Sigue el patrón checks-effects-interactions: el estado se actualiza antes de emitir el recibo.
    /// @param campaniaId Identificador de la campaña.
    /// @return reciboId Identificador del NFT de comprobante emitido.
    function donar(uint256 campaniaId) external payable nonReentrant returns (uint256 reciboId) {
        Campania memory c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        if (c.estado != Estado.Activa) revert EstadoInvalido(campaniaId, c.estado);
        if (block.timestamp > c.plazo) revert PlazoVencido(campaniaId);
        if (msg.value == 0) revert MontoCero();

        uint256 faltante = c.meta - c.recaudado;
        if (msg.value > faltante) revert ExcedeMeta(faltante);

        uint256 nuevoRecaudado = c.recaudado + msg.value;
        bool cumplida = nuevoRecaudado == c.meta;

        Campania storage s = _campanias[campaniaId];
        s.recaudado = nuevoRecaudado;
        if (cumplida) s.estado = Estado.Cumplida;
        _aportes[campaniaId][msg.sender] += msg.value;

        reciboId = RECIBO.emitir(msg.sender, campaniaId, msg.value);

        emit DonacionRecibida(campaniaId, msg.sender, msg.value, reciboId);
        if (cumplida) emit CampaniaCumplida(campaniaId, nuevoRecaudado);
    }

    /// @notice El destinatario retira los fondos de una campaña cumplida.
    /// @dev Pull payment: el contrato nunca envía fondos por su cuenta. Marca la campaña como
    ///      Liberada antes de transferir (checks-effects-interactions) y está protegido contra reentrada.
    /// @param campaniaId Identificador de la campaña.
    function retirar(uint256 campaniaId) external nonReentrant {
        Campania memory c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        if (msg.sender != c.destinatario) revert NoEsDestinatario(campaniaId);
        if (c.estado != Estado.Cumplida) revert EstadoInvalido(campaniaId, c.estado);

        _campanias[campaniaId].estado = Estado.Liberada;

        emit FondosLiberados(campaniaId, c.destinatario, c.recaudado);

        (bool ok,) = payable(c.destinatario).call{value: c.recaudado}("");
        if (!ok) revert TransferenciaFallida();
    }

    /// @notice Un donante recupera su aporte de una campaña que venció sin alcanzar la meta.
    /// @dev Esquema "todo o nada". La devolución está atada a la dirección que donó, no al NFT.
    /// @param campaniaId Identificador de la campaña.
    function reclamarDevolucion(uint256 campaniaId) external nonReentrant {
        Campania memory c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        if (c.estado != Estado.Activa || block.timestamp <= c.plazo) revert DevolucionNoDisponible(campaniaId);

        uint256 monto = _aportes[campaniaId][msg.sender];
        if (monto == 0) revert SinAportes(campaniaId);

        _aportes[campaniaId][msg.sender] = 0;
        _campanias[campaniaId].recaudado = c.recaudado - monto;

        emit DonacionDevuelta(campaniaId, msg.sender, monto);

        (bool ok,) = payable(msg.sender).call{value: monto}("");
        if (!ok) revert TransferenciaFallida();
    }

    /*//////////////////////////////////////////////////////////////
                               CONSULTAS
    //////////////////////////////////////////////////////////////*/

    /// @notice Cantidad total de campañas creadas (los identificadores van de 1 a este valor).
    /// @return Cantidad de campañas.
    function totalCampanias() external view returns (uint256) {
        return _cantidadCampanias;
    }

    /// @notice Devuelve los datos almacenados de una campaña.
    /// @param campaniaId Identificador de la campaña.
    /// @return Datos de la campaña.
    function campania(uint256 campaniaId) external view returns (Campania memory) {
        Campania memory c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        return c;
    }

    /// @notice Estado efectivo de una campaña, incluyendo `Vencida` (derivado del plazo).
    /// @param campaniaId Identificador de la campaña.
    /// @return Estado actual.
    function estadoActual(uint256 campaniaId) external view returns (Estado) {
        Campania memory c = _campanias[campaniaId];
        if (c.destinatario == address(0)) revert CampaniaInexistente(campaniaId);
        if (c.estado == Estado.Activa && block.timestamp > c.plazo) return Estado.Vencida;
        return c.estado;
    }

    /// @notice Monto que un donante aportó (y puede recuperar si la campaña vence) en una campaña.
    /// @param campaniaId Identificador de la campaña.
    /// @param donante Dirección del donante.
    /// @return Monto aportado en wei.
    function aporteDe(uint256 campaniaId, address donante) external view returns (uint256) {
        return _aportes[campaniaId][donante];
    }
}
