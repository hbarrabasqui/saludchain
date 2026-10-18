// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SaludChain} from "../src/SaludChain.sol";

/// @title Script de despliegue de SaludChain
/// @notice Despliega SaludChain (que a su vez despliega el contrato Recibo).
/// @dev Variables de entorno: `ADMIN_ADDRESS` (obligatoria) y `VERIFICADOR_ADDRESS` (opcional;
///      si falta, el admin también es verificador). La clave que firma se pasa por línea de
///      comandos (`--account` o `--private-key`), nunca se escribe en el repositorio.
contract Deploy is Script {
    /// @notice Ejecuta el despliegue.
    /// @return saludChain Contrato SaludChain desplegado.
    function run() external returns (SaludChain saludChain) {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address verificador = vm.envOr("VERIFICADOR_ADDRESS", admin);

        vm.startBroadcast();
        saludChain = new SaludChain(admin, verificador);
        vm.stopBroadcast();

        console.log("SaludChain:", address(saludChain));
        console.log("Recibo:    ", address(saludChain.RECIBO()));
        console.log("Admin:     ", admin);
        console.log("Verificador:", verificador);
    }
}
