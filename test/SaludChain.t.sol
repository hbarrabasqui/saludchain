// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SaludChain} from "../src/SaludChain.sol";
import {Recibo} from "../src/Recibo.sol";

/// @dev Destinatario malicioso: al recibir fondos intenta volver a llamar a `retirar`.
contract DestinatarioMalicioso {
    SaludChain private immutable _SC;
    uint256 private _id;
    bool public reentroFallo;

    constructor(SaludChain sc) {
        _SC = sc;
    }

    function atacar(uint256 id) external {
        _id = id;
        _SC.retirar(id);
    }

    receive() external payable {
        try _SC.retirar(_id) {}
        catch {
            reentroFallo = true;
        }
    }
}

/// @dev Destinatario que rechaza cualquier pago (para probar TransferenciaFallida).
contract DestinatarioQueRechaza {
    function intentarRetirar(SaludChain sc, uint256 id) external {
        sc.retirar(id);
    }
}

contract SaludChainTest is Test {
    SaludChain internal sc;
    Recibo internal recibo;

    address internal admin = makeAddr("admin");
    address internal verificador = makeAddr("verificador");
    address internal paciente = makeAddr("paciente");
    address internal donante1 = makeAddr("donante1");
    address internal donante2 = makeAddr("donante2");
    address internal intruso = makeAddr("intruso");

    uint256 internal constant META = 10 ether;
    uint64 internal constant DURACION = 30 days;
    bytes32 internal constant HASH_DOCS = keccak256("certificado-medico");

    event CampaniaCreada(
        uint256 indexed campaniaId,
        address indexed creador,
        address indexed destinatario,
        uint256 meta,
        uint64 duracion,
        bytes32 hashDocs
    );
    event DonacionRecibida(uint256 indexed campaniaId, address indexed donante, uint256 monto, uint256 reciboId);
    event CampaniaCumplida(uint256 indexed campaniaId, uint256 recaudado);
    event FondosLiberados(uint256 indexed campaniaId, address indexed destinatario, uint256 monto);
    event DonacionDevuelta(uint256 indexed campaniaId, address indexed donante, uint256 monto);

    function setUp() public {
        sc = new SaludChain(admin, verificador);
        recibo = sc.RECIBO();
        vm.deal(donante1, 100 ether);
        vm.deal(donante2, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _crear() internal returns (uint256 id) {
        vm.prank(paciente);
        id = sc.crearCampania(paciente, META, DURACION, HASH_DOCS);
    }

    function _crearYVerificar() internal returns (uint256 id) {
        id = _crear();
        vm.prank(verificador);
        sc.verificar(id, META);
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR Y CREACION
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_AsignaRolesYDesplegaRecibo() public view {
        assertTrue(sc.hasRole(sc.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(sc.hasRole(sc.VERIFICADOR_ROLE(), verificador));
        assertEq(recibo.SALUDCHAIN(), address(sc));
    }

    function test_Constructor_RevertSiDireccionCero() public {
        vm.expectRevert(SaludChain.DireccionInvalida.selector);
        new SaludChain(address(0), verificador);
        vm.expectRevert(SaludChain.DireccionInvalida.selector);
        new SaludChain(admin, address(0));
    }

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

    function test_CrearCampania_RevertConParametrosInvalidos() public {
        vm.expectRevert(SaludChain.DireccionInvalida.selector);
        sc.crearCampania(address(0), META, DURACION, HASH_DOCS);

        vm.expectRevert(SaludChain.MetaInvalida.selector);
        sc.crearCampania(paciente, 0, DURACION, HASH_DOCS);

        vm.expectRevert(abi.encodeWithSelector(SaludChain.DuracionInvalida.selector, uint64(1 minutes)));
        sc.crearCampania(paciente, META, 1 minutes, HASH_DOCS);

        vm.expectRevert(abi.encodeWithSelector(SaludChain.DuracionInvalida.selector, uint64(181 days)));
        sc.crearCampania(paciente, META, 181 days, HASH_DOCS);

        vm.expectRevert(SaludChain.HashDocsInvalido.selector);
        sc.crearCampania(paciente, META, DURACION, bytes32(0));
    }

    function test_Campania_RevertSiNoExiste() public {
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 99));
        sc.campania(99);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 99));
        sc.estadoActual(99);
    }

    /*//////////////////////////////////////////////////////////////
                              VERIFICACION
    //////////////////////////////////////////////////////////////*/

    function test_Verificar_ActivaYFijaMontoYPlazo() public {
        uint256 id = _crear();
        uint256 aprobado = 8 ether; // el verificador aprueba menos de lo pedido

        vm.prank(verificador);
        sc.verificar(id, aprobado);

        SaludChain.Campania memory c = sc.campania(id);
        assertEq(uint8(c.estado), uint8(SaludChain.Estado.Activa));
        assertEq(c.meta, aprobado, "la meta pasa a ser el monto aprobado");
        assertEq(c.plazo, uint64(block.timestamp) + DURACION);
    }

    function test_Verificar_RevertSiNoEsVerificador() public {
        uint256 id = _crear();
        bytes32 rol = sc.VERIFICADOR_ROLE(); // se lee antes del prank para no consumirlo
        vm.prank(intruso);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, intruso, rol)
        );
        sc.verificar(id, META);
    }

    function test_Verificar_RevertSiMontoSuperaLaMetaSolicitada() public {
        uint256 id = _crear();
        vm.startPrank(verificador);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.MontoAprobadoInvalido.selector, META + 1, META));
        sc.verificar(id, META + 1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.MontoAprobadoInvalido.selector, 0, META));
        sc.verificar(id, 0);
        vm.stopPrank();
    }

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

    function test_Donar_RevertSiNoEstaActiva() public {
        uint256 id = _crear(); // Pendiente: nunca fue verificada
        vm.prank(donante1);
        vm.expectRevert(
            abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Pendiente)
        );
        sc.donar{value: 1 ether}(id);
    }

    function test_Donar_RevertSiMontoCeroOCampaniaInexistente() public {
        uint256 id = _crearYVerificar();
        vm.startPrank(donante1);
        vm.expectRevert(SaludChain.MontoCero.selector);
        sc.donar{value: 0}(id);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 77));
        sc.donar{value: 1 ether}(77);
        vm.stopPrank();
    }

    function test_Donar_RevertSiExcedeLaMeta() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: 9 ether}(id);

        vm.prank(donante2);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.ExcedeMeta.selector, 1 ether));
        sc.donar{value: 2 ether}(id);
    }

    function test_Donar_RevertSiVencioElPlazo() public {
        uint256 id = _crearYVerificar();
        vm.warp(block.timestamp + DURACION + 1);
        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.PlazoVencido.selector, id));
        sc.donar{value: 1 ether}(id);
    }

    function test_Donar_AlLlegarALaMetaCierraLaCampania() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: 6 ether}(id);

        vm.expectEmit(true, false, false, true);
        emit CampaniaCumplida(id, META);
        vm.prank(donante2);
        sc.donar{value: 4 ether}(id);

        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Cumplida));

        // cerrada: ya no acepta más donaciones
        vm.prank(donante1);
        vm.expectRevert(
            abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Cumplida)
        );
        sc.donar{value: 1 wei}(id);
    }

    function test_NoAceptaETHEnviadoDirectamente() public {
        vm.prank(donante1);
        (bool ok,) = address(sc).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /*//////////////////////////////////////////////////////////////
                                RETIRO
    //////////////////////////////////////////////////////////////*/

    function test_FlujoCompleto_CumpleMetaYDestinatarioCobra() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: 6 ether}(id);
        vm.prank(donante2);
        sc.donar{value: 4 ether}(id);

        uint256 antes = paciente.balance;
        vm.expectEmit(true, true, false, true);
        emit FondosLiberados(id, paciente, META);
        vm.prank(paciente);
        sc.retirar(id);

        assertEq(paciente.balance, antes + META);
        assertEq(address(sc).balance, 0);
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Liberada));
    }

    function test_Retirar_RevertSiNoSeAlcanzoLaMeta() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: 5 ether}(id);

        vm.prank(paciente);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Activa));
        sc.retirar(id);
    }

    function test_Retirar_RevertSiNoEsElDestinatario() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: META}(id);

        vm.prank(intruso);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.NoEsDestinatario.selector, id));
        sc.retirar(id);
    }

    function test_Retirar_NoSePuedeRetirarDosVeces() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: META}(id);
        vm.startPrank(paciente);
        sc.retirar(id);
        vm.expectRevert(
            abi.encodeWithSelector(SaludChain.EstadoInvalido.selector, id, SaludChain.Estado.Liberada)
        );
        sc.retirar(id);
        vm.stopPrank();
    }

    function test_Retirar_RevertSiCampaniaInexistente() public {
        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 5));
        sc.retirar(5);
    }

    function test_Retirar_BloqueaReentrada() public {
        DestinatarioMalicioso atacante = new DestinatarioMalicioso(sc);
        vm.prank(paciente);
        uint256 id = sc.crearCampania(address(atacante), META, DURACION, HASH_DOCS);
        vm.prank(verificador);
        sc.verificar(id, META);
        vm.prank(donante1);
        sc.donar{value: META}(id);

        atacante.atacar(id);

        assertTrue(atacante.reentroFallo(), "el segundo retiro debio fallar");
        assertEq(address(atacante).balance, META, "cobra una sola vez");
        assertEq(address(sc).balance, 0);
    }

    function test_Retirar_RevertSiElDestinatarioRechazaElPago() public {
        DestinatarioQueRechaza rechaza = new DestinatarioQueRechaza();
        vm.prank(paciente);
        uint256 id = sc.crearCampania(address(rechaza), META, DURACION, HASH_DOCS);
        vm.prank(verificador);
        sc.verificar(id, META);
        vm.prank(donante1);
        sc.donar{value: META}(id);

        vm.expectRevert(SaludChain.TransferenciaFallida.selector);
        rechaza.intentarRetirar(sc, id);
        // la reversión deja la campaña intacta
        assertEq(uint8(sc.estadoActual(id)), uint8(SaludChain.Estado.Cumplida));
    }

    /*//////////////////////////////////////////////////////////////
                              DEVOLUCION
    //////////////////////////////////////////////////////////////*/

    function test_Devolucion_DespuesDelVencimientoCadaDonanteRecuperaLoSuyo() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: 2 ether}(id);
        vm.prank(donante2);
        sc.donar{value: 3 ether}(id);

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

    function test_Devolucion_RevertAntesDelVencimiento() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: 2 ether}(id);

        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);
    }

    function test_Devolucion_RevertSiLaCampaniaCumplioLaMeta() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: META}(id);
        vm.warp(block.timestamp + DURACION + 1);

        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);
    }

    function test_Devolucion_RevertSinAportesOCampaniaInexistente() public {
        uint256 id = _crearYVerificar();
        vm.warp(block.timestamp + DURACION + 1);

        vm.prank(intruso);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.SinAportes.selector, id));
        sc.reclamarDevolucion(id);

        vm.expectRevert(abi.encodeWithSelector(SaludChain.CampaniaInexistente.selector, 123));
        sc.reclamarDevolucion(123);
    }

    function test_Devolucion_NoSePuedeCobrarDosVeces() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        sc.donar{value: 2 ether}(id);
        vm.warp(block.timestamp + DURACION + 1);

        vm.startPrank(donante1);
        sc.reclamarDevolucion(id);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.SinAportes.selector, id));
        sc.reclamarDevolucion(id);
        vm.stopPrank();
    }

    function test_Devolucion_PendienteNoVerificadaNoPermiteDevolucion() public {
        uint256 id = _crear();
        vm.warp(block.timestamp + 365 days);
        vm.prank(donante1);
        vm.expectRevert(abi.encodeWithSelector(SaludChain.DevolucionNoDisponible.selector, id));
        sc.reclamarDevolucion(id);
    }

    /*//////////////////////////////////////////////////////////////
                                 RECIBO
    //////////////////////////////////////////////////////////////*/

    function test_Recibo_SoloSaludChainPuedeEmitir() public {
        vm.prank(intruso);
        vm.expectRevert(Recibo.SoloSaludChain.selector);
        recibo.emitir(intruso, 1, 1 ether);
    }

    function test_Recibo_ConstructorRevertSiDireccionCero() public {
        vm.expectRevert(Recibo.DireccionInvalida.selector);
        new Recibo(address(0));
    }

    function test_Recibo_TokenURIDevuelveJSONOnChain() public {
        uint256 id = _crearYVerificar();
        vm.prank(donante1);
        uint256 reciboId = sc.donar{value: 1 ether}(id);

        string memory uri = recibo.tokenURI(reciboId);
        assertEq(_comienzaCon(uri, "data:application/json;base64,"), true);
    }

    function test_Recibo_ConsultasRevertSiNoExiste() public {
        vm.expectRevert(abi.encodeWithSelector(Recibo.ReciboInexistente.selector, 9));
        recibo.tokenURI(9);
        vm.expectRevert(abi.encodeWithSelector(Recibo.ReciboInexistente.selector, 9));
        recibo.datosDe(9);
    }

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

    /// @dev Nunca se recauda más que la meta, y el saldo del contrato coincide con lo recaudado.
    function testFuzz_Donar_NuncaSuperaLaMeta(uint96 a, uint96 b) public {
        uint256 id = _crearYVerificar();
        uint256 x = bound(a, 1, META);
        vm.prank(donante1);
        sc.donar{value: x}(id);

        uint256 y = bound(b, 1, META * 2);
        vm.prank(donante2);
        if (y > META - x) {
            vm.expectRevert(abi.encodeWithSelector(SaludChain.ExcedeMeta.selector, META - x));
            sc.donar{value: y}(id);
        } else {
            sc.donar{value: y}(id);
        }

        assertLe(sc.campania(id).recaudado, META);
        assertEq(address(sc).balance, sc.campania(id).recaudado);
    }

    /// @dev La devolución devuelve exactamente lo aportado, sin importar el monto.
    function testFuzz_Devolucion_DevuelveExactamenteLoAportado(uint96 monto) public {
        uint256 id = _crearYVerificar();
        uint256 m = bound(monto, 1, META - 1); // sin llegar a la meta
        vm.prank(donante1);
        sc.donar{value: m}(id);

        vm.warp(block.timestamp + DURACION + 1);
        uint256 antes = donante1.balance;
        vm.prank(donante1);
        sc.reclamarDevolucion(id);

        assertEq(donante1.balance, antes + m);
        assertEq(address(sc).balance, 0);
    }
}
