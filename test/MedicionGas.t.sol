// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SaludChain} from "../src/SaludChain.sol";

/// @title Medición de gas de SaludChain
/// @notice Escenario fijo que llama una vez a cada función principal, para comparar el gas entre versiones.
/// @dev Correr con `forge test --isolate --gas-report --match-contract MedicionGas`: `--isolate` ejecuta cada
///      llamada como una transacción propia (storage frío, costo base incluido), así los números son los de una
///      transacción real. Solo usa la interfaz común a todas las versiones, por lo que el mismo archivo sirve
///      para medir el código anterior (por ejemplo, el commit 875331c) y el actual.
contract MedicionGas is Test {
    /// @notice Crea dos campañas, las verifica, dona, retira la cumplida y reclama la vencida.
    function test_MedicionGas_EscenarioFijo() public {
        address verificador = makeAddr("verificador");
        address destinatario = makeAddr("destinatario");
        address donante1 = makeAddr("donante1");
        address donante2 = makeAddr("donante2");
        vm.deal(donante1, 10 ether);
        vm.deal(donante2, 10 ether);

        SaludChain sc = new SaludChain(makeAddr("admin"), verificador);
        sc.crearCampania(destinatario, 1 ether, 1 days, keccak256("docs 1"));
        sc.crearCampania(destinatario, 1 ether, 1 days, keccak256("docs 2"));
        vm.prank(verificador);
        sc.verificar(1, 1 ether);
        vm.prank(verificador);
        sc.verificar(2, 1 ether);

        vm.prank(donante1);
        sc.donar{value: 0.4 ether}(1); // primera donación: primer recibo NFT
        vm.prank(donante2);
        sc.donar{value: 0.6 ether}(1); // alcanza la meta
        vm.prank(donante1);
        sc.donar{value: 0.3 ether}(2); // parcial en otra campaña

        vm.prank(destinatario);
        sc.retirar(1);

        vm.warp(block.timestamp + 2 days); // la campaña 2 vence sin alcanzar la meta
        sc.estadoActual(2);
        vm.prank(donante1);
        sc.reclamarDevolucion(2);

        assertEq(address(sc).balance, 0);
    }
}
