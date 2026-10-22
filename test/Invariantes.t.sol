// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SaludChain} from "../src/SaludChain.sol";

/// @title Receptor que rechaza ETH
/// @notice Contrato auxiliar usado como destinatario de campañas: no tiene `receive` ni `fallback`.
/// @dev Permite que el fuzzer ejercite el caso del destinatario que no puede cobrar.
contract ReceptorQueRechaza {
    /// @notice Llama a `retirar` desde este contrato (que es el destinatario de la campaña).
    /// @param sc Contrato SaludChain.
    /// @param id Identificador de la campaña.
    function intentarRetirar(SaludChain sc, uint256 id) external {
        sc.retirar(id);
    }
}

/// @title Manejador de invariantes de SaludChain
/// @notice Ejecuta secuencias aleatorias de acciones válidas (y también inválidas, que revierten) sobre SaludChain.
/// @dev Foundry llama a estas funciones en cualquier orden. Los reverts se ignoran: lo que importa es que, ocurra lo
///      que ocurra, las invariantes de {InvariantesSaludChain} se mantengan.
contract ManejadorSaludChain is Test {
    /// @notice Contrato bajo prueba.
    SaludChain public immutable SC;

    /// @notice Cuenta con rol de verificador.
    address public immutable VERIFICADOR;

    /// @notice Destinatario común de las campañas (una billetera normal que sí acepta ETH).
    address public immutable DESTINATARIO_EOA;

    /// @notice Cuentas que donan y reclaman devoluciones.
    address[] public actores;

    /// @notice Identificadores de las campañas creadas por el manejador.
    uint256[] public ids;

    /// @notice Destinatario de cada campaña.
    mapping(uint256 id => address destinatario) public destinatarioDe;

    /// @notice Indica si el destinatario de la campaña es un contrato que rechaza ETH.
    mapping(uint256 id => bool rechaza) public rechazaDe;

    /// @notice Prepara las cuentas con saldo.
    /// @param sc Contrato SaludChain.
    /// @param verificador Cuenta con rol de verificador.
    constructor(SaludChain sc, address verificador) {
        SC = sc;
        VERIFICADOR = verificador;
        DESTINATARIO_EOA = makeAddr("destinatarioEOA");
        for (uint256 i = 0; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actores.push(a);
            vm.deal(a, 1_000 ether);
        }
    }

    /// @dev Elige un identificador de campaña a partir de un número aleatorio.
    function _id(uint256 azar) internal view returns (bool hay, uint256 id) {
        if (ids.length == 0) return (false, 0);
        return (true, ids[azar % ids.length]);
    }

    /// @notice Crea una campaña; a veces con un destinatario que rechaza ETH.
    /// @param metaAzar Número aleatorio para la meta.
    /// @param duracionAzar Número aleatorio para la duración.
    /// @param rechaza Si es `true`, el destinatario es un contrato que rechaza ETH.
    function crear(uint96 metaAzar, uint32 duracionAzar, bool rechaza) external {
        uint256 meta = bound(metaAzar, 1, 50 ether);
        uint32 duracion = uint32(bound(duracionAzar, SC.DURACION_MINIMA(), SC.DURACION_MAXIMA()));
        address destinatario = rechaza ? address(new ReceptorQueRechaza()) : DESTINATARIO_EOA;
        uint256 id = SC.crearCampania(destinatario, meta, duracion, keccak256(abi.encode(ids.length)));
        ids.push(id);
        destinatarioDe[id] = destinatario;
        rechazaDe[id] = rechaza;
    }

    /// @notice Verifica una campaña aprobando un monto aleatorio (hasta la meta solicitada).
    /// @param azar Número aleatorio para elegir la campaña.
    /// @param montoAzar Número aleatorio para el monto aprobado.
    function verificar(uint256 azar, uint96 montoAzar) external {
        (bool hay, uint256 id) = _id(azar);
        if (!hay) return;
        uint256 monto = bound(montoAzar, 1, SC.campania(id).meta);
        vm.prank(VERIFICADOR);
        SC.verificar(id, monto);
    }

    /// @notice Dona un monto aleatorio desde una cuenta aleatoria.
    /// @param azar Número aleatorio para elegir la campaña.
    /// @param actorAzar Número aleatorio para elegir al donante.
    /// @param montoAzar Número aleatorio para el monto.
    function donar(uint256 azar, uint256 actorAzar, uint96 montoAzar) external {
        (bool hay, uint256 id) = _id(azar);
        if (!hay) return;
        address actor = actores[actorAzar % actores.length];
        uint256 monto = bound(montoAzar, 1, SC.campania(id).meta);
        vm.prank(actor);
        SC.donar{value: monto}(id);
    }

    /// @notice El destinatario intenta retirar.
    /// @param azar Número aleatorio para elegir la campaña.
    function retirar(uint256 azar) external {
        (bool hay, uint256 id) = _id(azar);
        if (!hay) return;
        if (rechazaDe[id]) {
            ReceptorQueRechaza(destinatarioDe[id]).intentarRetirar(SC, id);
        } else {
            vm.prank(destinatarioDe[id]);
            SC.retirar(id);
        }
    }

    /// @notice Un donante intenta recuperar su aporte.
    /// @param azar Número aleatorio para elegir la campaña.
    /// @param actorAzar Número aleatorio para elegir al donante.
    function reclamar(uint256 azar, uint256 actorAzar) external {
        (bool hay, uint256 id) = _id(azar);
        if (!hay) return;
        vm.prank(actores[actorAzar % actores.length]);
        SC.reclamarDevolucion(id);
    }

    /// @notice Avanza el reloj entre 0 y 60 días.
    /// @param segundos Número aleatorio de segundos.
    function avanzar(uint32 segundos) external {
        vm.warp(block.timestamp + bound(segundos, 0, 60 days));
    }
}

/// @title Invariantes de SaludChain
/// @notice Propiedades que deben cumplirse después de cualquier secuencia de operaciones.
contract InvariantesSaludChain is Test {
    /// @dev Contrato bajo prueba.
    SaludChain internal sc;

    /// @dev Manejador que genera las secuencias aleatorias.
    ManejadorSaludChain internal manejador;

    /// @notice Despliega SaludChain y el manejador, y lo fija como único objetivo del fuzzer.
    function setUp() public {
        sc = new SaludChain(makeAddr("admin"), makeAddr("verificador"));
        manejador = new ManejadorSaludChain(sc, makeAddr("verificador"));
        targetContract(address(manejador));
    }

    /// @notice El saldo del contrato es siempre igual a la suma de `recaudado` de las campañas no Liberadas.
    /// @dev Garantiza que nunca queda ETH "huérfano" ni se promete más de lo que hay en custodia.
    function invariant_SaldoIgualASumaRecaudadoDeCampaniasNoLiberadas() public view {
        uint256 suma;
        uint256 n = sc.totalCampanias();
        for (uint256 i = 1; i <= n; ++i) {
            SaludChain.Campania memory c = sc.campania(i);
            if (c.estado != SaludChain.Estado.Liberada) suma += c.recaudado;
        }
        assertEq(address(sc).balance, suma);
    }

    /// @notice Nunca se recauda más de la meta aprobada.
    function invariant_RecaudadoNuncaSuperaLaMeta() public view {
        uint256 n = sc.totalCampanias();
        for (uint256 i = 1; i <= n; ++i) {
            SaludChain.Campania memory c = sc.campania(i);
            assertLe(c.recaudado, c.meta);
        }
    }
}
