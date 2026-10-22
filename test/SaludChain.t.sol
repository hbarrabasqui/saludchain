// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SaludChain} from "../src/SaludChain.sol";
import {Recibo} from "../src/Recibo.sol";

/// @title Destinatario malicioso
/// @notice Contrato auxiliar de prueba que, al recibir fondos, intenta volver a llamar a `retirar`.
/// @dev Sirve para comprobar que `retirar` está protegido contra reentrada.
contract DestinatarioMalicioso {
    /// @dev Contrato SaludChain atacado.
    SaludChain private immutable _SC;

    /// @dev Campaña sobre la que se intenta la reentrada.
    uint256 private _id;

    /// @notice Pasa a `true` cuando el segundo retiro (reentrada) fue rechazado.
    bool public reentroFallo;

    /// @notice Crea el atacante apuntando a un contrato SaludChain.
    /// @param sc Contrato SaludChain atacado.
    constructor(SaludChain sc) {
        _SC = sc;
    }

    /// @notice Inicia el retiro desde este contrato (que es el destinatario de la campaña).
    /// @param id Identificador de la campaña.
    function atacar(uint256 id) external {
        _id = id;
        _SC.retirar(id);
    }

    /// @notice Al recibir ETH intenta reentrar a `retirar` y registra si fue rechazado.
    receive() external payable {
        try _SC.retirar(_id) {}
        catch {
            reentroFallo = true;
        }
    }
}

/// @title Destinatario que rechaza todo pago
/// @notice Contrato auxiliar de prueba sin función `receive` ni `fallback`: cualquier envío de ETH revierte.
/// @dev Sirve para probar `TransferenciaFallida` y que los fondos nunca quedan bloqueados.
contract DestinatarioQueRechaza {
    /// @notice Llama a `retirar` desde este contrato (que es el destinatario de la campaña).
    /// @param sc Contrato SaludChain.
    /// @param id Identificador de la campaña.
    function intentarRetirar(SaludChain sc, uint256 id) external {
        sc.retirar(id);
    }
}

/// @title Donante que rechaza reembolsos
/// @notice Contrato auxiliar de prueba que dona a una campaña pero no puede recibir ETH de vuelta.
/// @dev Sirve para probar `TransferenciaFallida` en {SaludChain.reclamarDevolucion}.
contract DonanteQueRechaza {
    /// @notice Dona a la campaña usando el ETH que envía quien llama.
    /// @param sc Contrato SaludChain.
    /// @param id Identificador de la campaña.
    function donar(SaludChain sc, uint256 id) external payable {
        sc.donar{value: msg.value}(id);
    }

    /// @notice Intenta recuperar el aporte (el reembolso fallará porque este contrato rechaza ETH).
    /// @param sc Contrato SaludChain.
    /// @param id Identificador de la campaña.
    function reclamar(SaludChain sc, uint256 id) external {
        sc.reclamarDevolucion(id);
    }
}

/// @title Pruebas de SaludChain y Recibo
/// @notice Cubre el flujo completo, los bordes de tiempo de la ventana de retiro, el control de acceso,
///         las devoluciones y propiedades con fuzzing.
contract SaludChainTest is Test {
    /// @dev Contrato bajo prueba.
    SaludChain internal sc;

    /// @dev Contrato de recibos NFT desplegado por SaludChain.
    Recibo internal recibo;

    /// @dev Administrador de roles.
    address internal admin = makeAddr("admin");

    /// @dev Cuenta con rol de verificador.
    address internal verificador = makeAddr("verificador");

    /// @dev Creador y destinatario de las campañas de prueba.
    address internal paciente = makeAddr("paciente");

    /// @dev Primer donante.
    address internal donante1 = makeAddr("donante1");

    /// @dev Segundo donante.
    address internal donante2 = makeAddr("donante2");

    /// @dev Cuenta sin permisos.
    address internal intruso = makeAddr("intruso");

    /// @dev Meta usada en las pruebas.
    uint256 internal constant META = 10 ether;

    /// @dev Duración de las campañas de prueba.
    uint32 internal constant DURACION = 30 days;

    /// @dev Huella de documentación de prueba.
    bytes32 internal constant HASH_DOCS = keccak256("certificado-medico");

    /// @dev Copia del evento para poder verificarlo con `expectEmit`.
    event CampaniaCreada(
        uint256 indexed campaniaId,
        address indexed creador,
        address indexed destinatario,
        uint256 meta,
        uint32 duracion,
        bytes32 hashDocs
    );
    /// @dev Copia del evento para poder verificarlo con `expectEmit`.
    event DonacionRecibida(uint256 indexed campaniaId, address indexed donante, uint256 monto, uint256 reciboId);
    /// @dev Copia del evento para poder verificarlo con `expectEmit`.
    event CampaniaCumplida(uint256 indexed campaniaId, uint256 recaudado);
    /// @dev Copia del evento para poder verificarlo con `expectEmit`.
    event FondosLiberados(uint256 indexed campaniaId, address indexed destinatario, uint256 monto);
    /// @dev Copia del evento para poder verificarlo con `expectEmit`.
    event DonacionDevuelta(uint256 indexed campaniaId, address indexed donante, uint256 monto);

    /// @notice Despliega SaludChain y reparte saldo a los donantes.
    function setUp() public {
        sc = new SaludChain(admin, verificador);
        recibo = sc.RECIBO();
        vm.deal(donante1, 100 ether);
        vm.deal(donante2, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Crea una campaña para `paciente`.
    function _crear() internal returns (uint256 id) {
        vm.prank(paciente);
        id = sc.crearCampania(paciente, META, DURACION, HASH_DOCS);
    }

    /// @dev Crea y verifica una campaña por el monto completo.
    function _crearYVerificar() internal returns (uint256 id) {
        id = _crear();
        vm.prank(verificador);
        sc.verificar(id, META);
    }

    /// @dev Dona `monto` a la campaña desde `donante`.
    function _donar(uint256 id, address donante, uint256 monto) internal {
        vm.prank(donante);
        sc.donar{value: monto}(id);
    }

    /// @dev Crea, verifica y completa la meta de una campaña (queda Cumplida con la ventana de retiro abierta).
    function _cumplida() internal returns (uint256 id) {
        id = _crearYVerificar();
        _donar(id, donante1, 6 ether);
        _donar(id, donante2, 4 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR Y CREACION
    //////////////////////////////////////////////////////////////*/

    /// @notice El constructor asigna los roles y despliega el Recibo ligado a SaludChain.
    function test_Constructor_AsignaRolesYDesplegaRecibo() public view {
        assertTrue(sc.hasRole(sc.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(sc.hasRole(sc.VERIFICADOR_ROLE(), verificador));
        assertEq(recibo.SALUDCHAIN(), address(sc));
    }

    /// @notice El constructor revierte si el admin o el verificador son la dirección cero.
    function test_Constructor_RevertSiDireccionCero() public {
        vm.expectRevert(SaludChain.DireccionInvalida.selector);
        new SaludChain(address(0), verificador);
        vm.expectRevert(SaludChain.DireccionInvalida.selector);
        new SaludChain(admin, address(0));
    }

    /// @notice Crear una campaña guarda sus datos (Pendiente, plazo 0) y emite el evento.
    function test_CrearCampania_RegistraDatosYEmiteEvento() public {
        vm.expectEmit(true, true, true, true);
        emit CampaniaCreada(1, paciente, paciente, META, DURACION, HASH_DOCS);
        uint256 id = _crear();

        assertEq(id, 1);
        assertEq(sc.totalCampanias(), 1);
        SaludChain.Campania memory c = sc.campania(id);
        assertEq(c.destinatario, paciente);
        assertEq(c.meta, META);
        assertEq(c.duracion, DURACION);
        assertEq(c.plazo, 0);
        assertEq(c.recaudado, 0);
        assertEq(c.hashDocs, HASH_DOCS);
        assertEq(uint8(c.estado), uint8(SaludChain.Estado.Pendiente));
    }

    /// @notice Crear una campaña revierte con destinatario cero, meta cero, duración fuera de rango o huella vacía.
    function test_CrearCampania_RevertConParametrosInvalidos() public {
        vm.expectRevert(SaludChain.DireccionInvalida.selector);
        sc.crearCampania(address(0), META, DURACION, HASH_DOCS);

        vm.expectRevert(SaludChain.MetaInvalida.selector);
        sc.crearCampania(paciente, 0, DURACION, HASH_DOCS);

        vm.expectRevert(abi.encodeWithSelector(SaludChain.DuracionInvalida.selector, uint32(1 minutes)));
        sc.crearCampania(paciente, META, 1 minutes, HASH_DOCS);

        vm.expectRevert(abi.encodeWithSelector(SaludChain.DuracionInvalida.selector, uint32(181 days)));
        sc.crearCampania(paciente, META, 181 days, HASH_DOCS);

        vm.expectRevert(SaludChain.HashDocsInvalido.selector);
        sc.crearCampania(paciente, META, DURACION, bytes32(0));
    }

    /// @notice Consultar una campaña inexistente revierte.
    function test_Campania_RevertSiNoExiste() public {
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 99));
        sc.campania(99);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 99));
        sc.estadoActual(99);
    }

    /// @notice Las duraciones mínima y máxima exactas son válidas.
    function test_CrearCampania_AceptaLosLimitesDeDuracion() public {
        vm.startPrank(paciente);
        uint256 a = sc.crearCampania(paciente, META, sc.DURACION_MINIMA(), HASH_DOCS);
        uint256 b = sc.crearCampania(paciente, META, sc.DURACION_MAXIMA(), HASH_DOCS);
        vm.stopPrank();
        assertEq(sc.campania(a).duracion, 1 hours);
        assertEq(sc.campania(b).duracion, 180 days);
    }

    /*//////////////////////////////////////////////////////////////
                              VERIFICACION
    //////////////////////////////////////////////////////////////*/

    /// @notice Verificar activa la campaña, fija el monto aprobado como meta y arranca el plazo.
    function test_Verificar_ActivaYFijaMontoYPlazo() public {
        uint256 id = _crear();
        uint256 aprobado = 8 ether; // el verificador aprueba menos de lo pedido

        vm.prank(verificador);
        sc.verificar(id, aprobado);

        SaludChain.Campania memory c = sc.campania(id);
        assertEq(uint8(c.estado), uint8(SaludChain.Estado.Activa));
        assertEq(c.meta, aprobado, "la meta pasa a ser el monto aprobado");
        assertEq(c.plazo, uint40(block.timestamp) + DURACION);
    }

    /// @notice Solo el verificador puede verificar.
    function test_Verificar_RevertSiNoEsVerificador() public {
        uint256 id = _crear();
        bytes32 rol = sc.VERIFICADOR_ROLE(); // se lee antes del prank para no consumirlo
        vm.prank(intruso);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, intruso, rol)
        );
        sc.verificar(id, META);
    }

    /// @notice El monto aprobado no puede ser cero ni superar lo solicitado.
    function test_Verificar_RevertSiMontoSuperaLaMetaSolicitada() public {
        uint256 id = _crear();
        vm.startPrank(verificador);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.MontoAprobadoInvalido.selector, META + 1, META));
        sc.verificar(id, META + 1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.MontoAprobadoInvalido.selector, 0, META));
        sc.verificar(id, 0);
        vm.stopPrank();
    }

    /// @notice No se puede verificar dos veces ni una campaña inexistente.
    function test_Verificar_RevertSiYaVerificadaOInexistente() public {
        uint256 id = _crearYVerificar();
        vm.startPrank(verificador);
        vm.expectRevert(
            abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Activa)
        );
        sc.verificar(id, META);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 42));
        sc.verificar(42, META);
        vm.stopPrank();
    }

    /// @notice El admin puede agregar y quitar verificadores.
    function test_AdminPuedeAgregarYQuitarVerificadores() public {
        bytes32 rol = sc.VERIFICADOR_ROLE();
        vm.prank(admin);
        sc.grantRole(rol, intruso);
        assertTrue(sc.hasRole(rol, intruso));
        vm.prank(admin);
        sc.revokeRole(rol, intruso);
        assertFalse(sc.hasRole(rol, intruso));
    }

    /*//////////////////////////////////////////////////////////////
                               DONACIONES
    //////////////////////////////////////////////////////////////*/

    /// @notice Donar acumula lo recaudado, registra el aporte y emite el NFT de comprobante.
    function test_Donar_AcumulaYEmiteReciboNFT() public {
        uint256 id = _crearYVerificar();

        vm.expectEmit(true, true, false, true);
        emit DonacionRecibida(id, donante1, 3 ether, 1);
        vm.prank(donante1);
        uint256 reciboId = sc.donar{value: 3 ether}(id);

        assertEq(reciboId, 1);
        assertEq(recibo.ownerOf(reciboId), donante1);
        Recibo.Datos memory d = recibo.datosDe(reciboId);
        assertEq(d.campaniaId, id);
        assertEq(d.monto, 3 ether);
        assertEq(sc.campania(id).recaudado, 3 ether);
        assertEq(sc.aporteDe(id, donante1), 3 ether);
        assertEq(address(sc).balance, 3 ether);
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Activa));
    }

    /// @notice No se puede donar a una campaña que no está Activa.
    function test_Donar_RevertSiNoEstaActiva() public {
        uint256 id = _crear(); // Pendiente: nunca fue verificada
        vm.prank(donante1);
        vm.expectRevert(
            abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Pendiente)
        );
        sc.donar{value: 1 ether}(id);
    }

    /// @notice Donar cero o a una campaña inexistente revierte.
    function test_Donar_RevertSiMontoCeroOCampaniaInexistente() public {
        uint256 id = _crearYVerificar();
        vm.startPrank(donante1);
        vm.expectRevert(SaludChain.MontoCero.selector);
        sc.donar{value: 0}(id);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 77));
        sc.donar{value: 1 ether}(77);
        vm.stopPrank();
    }

    /// @notice Una donación que supera lo que falta para la meta revierte y no cambia nada.
    function test_Donar_RevertSiExcedeLaMeta() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, 9 ether);

        vm.prank(donante2);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.ExcedeMeta.selector, 1 ether));
        sc.donar{value: 2 ether}(id);

        assertEq(sc.campania(id).recaudado, 9 ether);
        assertEq(address(sc).balance, 9 ether);
    }

    /// @notice Pasado el plazo de donación ya no se acepta ninguna donación.
    function test_Donar_RevertSiVencioElPlazo() public {
        uint256 id = _crearYVerificar();
        vm.warp(block.timestamp + DURACION + 1);
        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.PlazoVencido.selector, id));
        sc.donar{value: 1 ether}(id);
    }

    /// @notice El último segundo del plazo de donación todavía permite donar.
    function test_Donar_BordeExactoDelPlazoSigueSiendoValido() public {
        uint256 id = _crearYVerificar();
        vm.warp(sc.campania(id).plazo);
        _donar(id, donante1, 1 ether);
        assertEq(sc.campania(id).recaudado, 1 ether);
    }

    /// @notice Al llegar a la meta la campaña pasa a Cumplida y deja de aceptar donaciones.
    function test_Donar_AlLlegarALaMetaCierraLaCampania() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, 6 ether);

        vm.expectEmit(true, false, false, true);
        emit CampaniaCumplida(id, META);
        _donar(id, donante2, 4 ether);

        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Cumplida));

        // cerrada: ya no acepta más donaciones
        vm.prank(donante1);
        vm.expectRevert(
            abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Cumplida)
        );
        sc.donar{value: 1 wei}(id);
    }

    /// @notice Al cumplirse la meta se fija el plazo de retiro en `ahora + PLAZO_RETIRO`.
    function test_Donar_AlCumplirLaMetaFijaLaVentanaDeRetiro() public {
        uint256 id = _crearYVerificar();
        vm.warp(block.timestamp + 5 days); // la meta se cumple 5 días después de verificar
        _donar(id, donante1, META);

        SaludChain.Campania memory c = sc.campania(id);
        assertEq(uint8(c.estado), uint8(SaludChain.Estado.Cumplida));
        assertEq(c.plazo, uint40(block.timestamp) + sc.PLAZO_RETIRO());
        assertEq(sc.PLAZO_RETIRO(), 30 days);
    }

    /// @notice Una donación parcial no modifica el plazo de donación.
    function test_Donar_ParcialNoCambiaElPlazo() public {
        uint256 id = _crearYVerificar();
        uint40 plazoAntes = sc.campania(id).plazo;
        _donar(id, donante1, 1 ether);
        assertEq(sc.campania(id).plazo, plazoAntes);
    }

    /// @notice El contrato no acepta ETH enviado directamente (solo vía `donar`).
    function test_NoAceptaETHEnviadoDirectamente() public {
        vm.prank(donante1);
        (bool ok,) = address(sc).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /*//////////////////////////////////////////////////////////////
                                RETIRO
    //////////////////////////////////////////////////////////////*/

    /// @notice Flujo feliz: se cumple la meta y el destinatario cobra todo.
    function test_FlujoCompleto_CumpleMetaYDestinatarioCobra() public {
        uint256 id = _cumplida();

        uint256 antes = paciente.balance;
        vm.expectEmit(true, true, false, true);
        emit FondosLiberados(id, paciente, META);
        vm.prank(paciente);
        sc.retirar(id);

        assertEq(paciente.balance, antes + META);
        assertEq(address(sc).balance, 0);
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Liberada));
    }

    /// @notice No se puede retirar si no se alcanzó la meta.
    function test_Retirar_RevertSiNoSeAlcanzoLaMeta() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, 5 ether);

        vm.prank(paciente);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Activa));
        sc.retirar(id);
    }

    /// @notice Solo el destinatario puede retirar.
    function test_Retirar_RevertSiNoEsElDestinatario() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, META);

        vm.prank(intruso);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.NoEsDestinatario.selector, id));
        sc.retirar(id);
    }

    /// @notice No se puede retirar dos veces.
    function test_Retirar_NoSePuedeRetirarDosVeces() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, META);
        vm.startPrank(paciente);
        sc.retirar(id);
        vm.expectRevert(
            abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Liberada)
        );
        sc.retirar(id);
        vm.stopPrank();
    }

    /// @notice Retirar de una campaña inexistente revierte.
    function test_Retirar_RevertSiCampaniaInexistente() public {
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 5));
        sc.retirar(5);
    }

    /// @notice Un destinatario que intenta reentrar a `retirar` solo cobra una vez.
    function test_Retirar_BloqueaReentrada() public {
        DestinatarioMalicioso atacante = new DestinatarioMalicioso(sc);
        vm.prank(paciente);
        uint256 id = sc.crearCampania(address(atacante), META, DURACION, HASH_DOCS);
        vm.prank(verificador);
        sc.verificar(id, META);
        _donar(id, donante1, META);

        atacante.atacar(id);

        assertTrue(atacante.reentroFallo(), "el segundo retiro debio fallar");
        assertEq(address(atacante).balance, META, "cobra una sola vez");
        assertEq(address(sc).balance, 0);
    }

    /// @notice Si el destinatario es un contrato que rechaza ETH, el retiro revierte y la campaña no cambia.
    function test_Retirar_RevertSiElDestinatarioRechazaElPago() public {
        DestinatarioQueRechaza rechaza = new DestinatarioQueRechaza();
        vm.prank(paciente);
        uint256 id = sc.crearCampania(address(rechaza), META, DURACION, HASH_DOCS);
        vm.prank(verificador);
        sc.verificar(id, META);
        _donar(id, donante1, META);

        vm.expectRevert(SaludChain.TransferenciaFallida.selector);
        rechaza.intentarRetirar(sc, id);
        // la reversión deja la campaña intacta y los fondos en custodia
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Cumplida));
        assertEq(address(sc).balance, META);
    }

    /*//////////////////////////////////////////////////////////////
                         VENTANA DE RETIRO (30 DIAS)
    //////////////////////////////////////////////////////////////*/

    /// @notice El destinatario puede retirar en el último segundo de la ventana (borde inclusivo).
    function test_Retirar_BordeExactoDelPlazoSigueSiendoValido() public {
        uint256 id = _cumplida();
        vm.warp(sc.campania(id).plazo);

        vm.prank(paciente);
        sc.retirar(id);
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Liberada));
    }

    /// @notice Un segundo después del plazo, el retiro revierte.
    function test_Retirar_RevertSiPasoLaVentana() public {
        uint256 id = _cumplida();
        vm.warp(uint256(sc.campania(id).plazo) + 1);

        vm.prank(paciente);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.VentanaDeRetiroVencida.selector, id));
        sc.retirar(id);
    }

    /// @notice Dentro de la ventana (incluido el borde) los donantes todavía no pueden pedir la devolución.
    function test_Devolucion_RevertDentroDeLaVentanaDeUnaCumplida() public {
        uint256 id = _cumplida();

        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);

        vm.warp(sc.campania(id).plazo); // borde exacto: todavía es del destinatario
        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);
    }

    /// @notice Pasada la ventana, una campaña Cumplida figura como Vencida.
    function test_EstadoActual_CumplidaPasaAVencidaTrasLaVentana() public {
        uint256 id = _cumplida();
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Cumplida));

        vm.warp(sc.campania(id).plazo);
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Cumplida));

        vm.warp(uint256(sc.campania(id).plazo) + 1);
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Vencida));
        // el estado guardado no cambia: `Vencida` es solo derivado
        assertEq(uint8(sc.campania(id).estado), uint8(SaludChain.Estado.Cumplida));
    }

    /// @notice Pasada la ventana sin retiro, cada donante recupera exactamente lo suyo.
    function test_Devolucion_CumplidaFueraDeVentanaPermiteRecuperar() public {
        uint256 id = _cumplida(); // donante1: 6 ether, donante2: 4 ether
        vm.warp(uint256(sc.campania(id).plazo) + 1);

        uint256 antes1 = donante1.balance;
        vm.expectEmit(true, true, false, true);
        emit DonacionDevuelta(id, donante1, 6 ether);
        vm.prank(donante1);
        sc.reclamarDevolucion(id);
        assertEq(donante1.balance, antes1 + 6 ether);

        uint256 antes2 = donante2.balance;
        vm.prank(donante2);
        sc.reclamarDevolucion(id);
        assertEq(donante2.balance, antes2 + 4 ether);

        assertEq(address(sc).balance, 0);
        assertEq(sc.campania(id).recaudado, 0);
    }

    /// @notice Caso central: el destinatario es un contrato que rechaza ETH. El retiro falla, pero al vencer
    ///         la ventana los donantes recuperan todo y el contrato queda en cero.
    function test_Devolucion_DestinatarioQueRechazaLosDonantesRecuperanTodo() public {
        DestinatarioQueRechaza rechaza = new DestinatarioQueRechaza();
        vm.prank(paciente);
        uint256 id = sc.crearCampania(address(rechaza), META, DURACION, HASH_DOCS);
        vm.prank(verificador);
        sc.verificar(id, META);
        _donar(id, donante1, 7 ether);
        _donar(id, donante2, 3 ether);

        // 1) el destinatario no puede cobrar
        vm.expectRevert(SaludChain.TransferenciaFallida.selector);
        rechaza.intentarRetirar(sc, id);
        assertEq(address(sc).balance, META);

        // 2) los donantes todavía no pueden recuperar (la ventana sigue abierta)
        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);

        // 3) vence la ventana: ya no se puede retirar y cada donante recupera lo suyo
        vm.warp(uint256(sc.campania(id).plazo) + 1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.VentanaDeRetiroVencida.selector, id));
        rechaza.intentarRetirar(sc, id);

        uint256 antes1 = donante1.balance;
        uint256 antes2 = donante2.balance;
        vm.prank(donante1);
        sc.reclamarDevolucion(id);
        vm.prank(donante2);
        sc.reclamarDevolucion(id);

        assertEq(donante1.balance, antes1 + 7 ether);
        assertEq(donante2.balance, antes2 + 3 ether);
        assertEq(address(sc).balance, 0, "los fondos no quedan bloqueados");
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Vencida));
    }

    /// @notice Una devolución parcial sobre una Cumplida vencida no reabre el retiro: la campaña sigue sin poder cobrarse.
    function test_Devolucion_ParcialSobreCumplidaNoReabreElRetiro() public {
        uint256 id = _cumplida();
        vm.warp(uint256(sc.campania(id).plazo) + 1);

        vm.prank(donante1);
        sc.reclamarDevolucion(id); // devuelve 6 ether, quedan 4 ether

        assertEq(sc.campania(id).recaudado, 4 ether);
        assertEq(address(sc).balance, 4 ether);

        vm.prank(paciente);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.VentanaDeRetiroVencida.selector, id));
        sc.retirar(id);

        vm.prank(donante2);
        sc.reclamarDevolucion(id);
        assertEq(address(sc).balance, 0);
    }

    /// @notice Una campaña Liberada nunca permite devolución, aunque pase el tiempo.
    function test_Devolucion_RevertSiLaCampaniaYaFueLiberada() public {
        uint256 id = _cumplida();
        vm.prank(paciente);
        sc.retirar(id);
        vm.warp(block.timestamp + 365 days);

        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);
    }

    /*//////////////////////////////////////////////////////////////
                              DEVOLUCION
    //////////////////////////////////////////////////////////////*/

    /// @notice Una campaña Activa que venció sin llegar a la meta devuelve a cada donante lo suyo.
    function test_Devolucion_DespuesDelVencimientoCadaDonanteRecuperaLoSuyo() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, 2 ether);
        _donar(id, donante2, 3 ether);

        vm.warp(block.timestamp + DURACION + 1);
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Vencida));

        uint256 antes1 = donante1.balance;
        vm.expectEmit(true, true, false, true);
        emit DonacionDevuelta(id, donante1, 2 ether);
        vm.prank(donante1);
        sc.reclamarDevolucion(id);
        assertEq(donante1.balance, antes1 + 2 ether);

        uint256 antes2 = donante2.balance;
        vm.prank(donante2);
        sc.reclamarDevolucion(id);
        assertEq(donante2.balance, antes2 + 3 ether);

        assertEq(address(sc).balance, 0);
        assertEq(sc.campania(id).recaudado, 0);
    }

    /// @notice Antes de que venza el plazo no hay devolución.
    function test_Devolucion_RevertAntesDelVencimiento() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, 2 ether);

        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);
    }

    /// @notice Una campaña Pendiente nunca permite devolución.
    function test_Devolucion_PendienteNoVerificadaNoPermiteDevolucion() public {
        uint256 id = _crear();
        vm.warp(block.timestamp + 365 days);
        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);
    }

    /// @notice Sin aportes propios, o con campaña inexistente, la devolución revierte.
    function test_Devolucion_RevertSinAportesOCampaniaInexistente() public {
        uint256 id = _crearYVerificar();
        vm.warp(block.timestamp + DURACION + 1);

        vm.prank(intruso);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.SinAportes.selector, id));
        sc.reclamarDevolucion(id);

        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 123));
        sc.reclamarDevolucion(123);
    }

    /// @notice No se puede cobrar la devolución dos veces.
    function test_Devolucion_NoSePuedeCobrarDosVeces() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, 2 ether);
        vm.warp(block.timestamp + DURACION + 1);

        vm.startPrank(donante1);
        sc.reclamarDevolucion(id);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.SinAportes.selector, id));
        sc.reclamarDevolucion(id);
        vm.stopPrank();
    }

    /// @notice Si el donante es un contrato que rechaza ETH, la devolución revierte y su aporte queda intacto.
    function test_Devolucion_RevertSiElDonanteRechazaElReembolso() public {
        DonanteQueRechaza donante = new DonanteQueRechaza();
        uint256 id = _crearYVerificar();
        donante.donar{value: 2 ether}(sc, id);
        vm.warp(block.timestamp + DURACION + 1);

        vm.expectRevert(SaludChain.TransferenciaFallida.selector);
        donante.reclamar(sc, id);

        assertEq(sc.aporteDe(id, address(donante)), 2 ether, "el aporte sigue registrado");
        assertEq(address(sc).balance, 2 ether);
    }

    /// @notice El borde exacto del plazo de donación todavía no habilita la devolución; un segundo después sí.
    function test_Devolucion_BordeExactoDelPlazoDeDonacion() public {
        uint256 id = _crearYVerificar();
        _donar(id, donante1, 2 ether);

        vm.warp(sc.campania(id).plazo);
        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);

        vm.warp(uint256(sc.campania(id).plazo) + 1);
        vm.prank(donante1);
        sc.reclamarDevolucion(id);
        assertEq(address(sc).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 RECIBO
    //////////////////////////////////////////////////////////////*/

    /// @notice Solo SaludChain puede emitir recibos.
    function test_Recibo_SoloSaludChainPuedeEmitir() public {
        vm.prank(intruso);
        vm.expectRevert(Recibo.SoloSaludChain.selector);
        recibo.emitir(intruso, 1, 1 ether);
    }

    /// @notice El constructor de Recibo rechaza la dirección cero.
    function test_Recibo_ConstructorRevertSiDireccionCero() public {
        vm.expectRevert(Recibo.DireccionInvalida.selector);
        new Recibo(address(0));
    }

    /// @notice `tokenURI` devuelve un JSON codificado en base64 on-chain.
    function test_Recibo_TokenURIDevuelveJSONOnChain() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        uint256 reciboId = sc.donar{value: 1 ether}(id);

        string memory uri = recibo.tokenURI(reciboId);
        assertEq(_comienzaCon(uri, "data:application/json;base64,"), true);
    }

    /// @notice Consultar un recibo inexistente revierte.
    function test_Recibo_ConsultasRevertSiNoExiste() public {
        vm.expectRevert(abi.encodeWithSelector(Recibo.ReciboInexistente.selector, 9));
        recibo.tokenURI(9);
        vm.expectRevert(abi.encodeWithSelector(Recibo.ReciboInexistente.selector, 9));
        recibo.datosDe(9);
    }

    /// @dev Indica si `texto` empieza con `prefijo`.
    function _comienzaCon(string memory texto, string memory prefijo) internal pure returns (bool) {
        bytes memory t = bytes(texto);
        bytes memory p = bytes(prefijo);
        if (t.length < p.length) return false;
        for (uint256 i = 0; i < p.length; ++i) {
            if (t[i] != p[i]) return false;
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Nunca se recauda más que la meta, y el saldo del contrato coincide con lo recaudado.
    function testFuzz_Donar_NuncaSuperaLaMeta(uint96 a, uint96 b) public {
        uint256 id = _crearYVerificar();
        uint256 x = bound(a, 1, META);
        _donar(id, donante1, x);

        uint256 y = bound(b, 1, META * 2);
        vm.prank(donante2);
        if (x == META) {
            // la primera donación ya completó la meta: la campaña está Cumplida y cerrada
            vm.expectRevert(
                abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Cumplida)
            );
            sc.donar{value: y}(id);
        } else if (y > META - x) {
            vm.expectRevert(abi.encodeWithSelector(SaludChain.ExcedeMeta.selector, META - x));
            sc.donar{value: y}(id);
        } else {
            sc.donar{value: y}(id);
        }

        assertLe(sc.campania(id).recaudado, META);
        assertEq(address(sc).balance, sc.campania(id).recaudado);
    }

    /// @notice La devolución devuelve exactamente lo aportado, sin importar el monto.
    function testFuzz_Devolucion_DevuelveExactamenteLoAportado(uint96 monto) public {
        uint256 id = _crearYVerificar();
        uint256 m = bound(monto, 1, META - 1); // sin llegar a la meta
        _donar(id, donante1, m);

        vm.warp(block.timestamp + DURACION + 1);
        uint256 antes = donante1.balance;
        vm.prank(donante1);
        sc.reclamarDevolucion(id);

        assertEq(donante1.balance, antes + m);
        assertEq(address(sc).balance, 0);
    }

    /// @notice Con devoluciones parciales sobre una Cumplida vencida, el saldo del contrato siempre coincide
    ///         con lo recaudado y nadie recupera más de lo que aportó.
    function testFuzz_Devolucion_ParcialesSobreCumplidaConservanElSaldo(uint96 parte, bool primeroDonante2) public {
        uint256 id = _crearYVerificar();
        uint256 x = bound(parte, 1, META - 1);
        _donar(id, donante1, x);
        _donar(id, donante2, META - x);
        vm.warp(uint256(sc.campania(id).plazo) + 1);

        address primero = primeroDonante2 ? donante2 : donante1;
        address segundo = primeroDonante2 ? donante1 : donante2;
        uint256 aportePrimero = sc.aporteDe(id, primero);
        uint256 aporteSegundo = sc.aporteDe(id, segundo);
        uint256 saldoPrimero = primero.balance;

        vm.prank(primero);
        sc.reclamarDevolucion(id);
        assertEq(primero.balance, saldoPrimero + aportePrimero);
        assertEq(sc.campania(id).recaudado, aporteSegundo);
        assertEq(address(sc).balance, aporteSegundo);

        vm.prank(segundo);
        sc.reclamarDevolucion(id);
        assertEq(address(sc).balance, 0);
        assertEq(sc.campania(id).recaudado, 0);
    }

    /// @notice El retiro y la devolución nunca son posibles en el mismo instante, para cualquier marca de tiempo.
    function testFuzz_RetiroYDevolucionNoSeSolapan(uint32 salto) public {
        uint256 id = _cumplida();
        vm.warp(block.timestamp + bound(salto, 0, 90 days));

        bool puedeRetirar;
        vm.prank(paciente);
        try sc.retirar(id) {
            puedeRetirar = true;
        } catch {}

        if (puedeRetirar) {
            // si cobró el destinatario, nadie más puede recuperar nada
            vm.prank(donante1);
            vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
            sc.reclamarDevolucion(id);
        } else {
            // si ya no pudo cobrar, entonces la ventana venció y los donantes sí recuperan
            assertGt(block.timestamp, sc.campania(id).plazo);
            vm.prank(donante1);
            sc.reclamarDevolucion(id);
        }
    }
}
