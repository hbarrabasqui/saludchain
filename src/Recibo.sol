// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Recibo de donación de SaludChain
/// @author Equipo SaludChain
/// @notice NFT (ERC-721) que funciona como comprobante de cada donación realizada en SaludChain.
/// @dev Solo el contrato SaludChain que lo creó puede emitir recibos. Los datos del recibo
///      (campaña, monto, fecha) quedan guardados on-chain y se exponen en `tokenURI`.
contract Recibo is ERC721 {
    /// @notice Datos que respaldan un recibo.
    /// @param campaniaId Identificador de la campaña a la que se donó.
    /// @param monto Monto donado en wei.
    /// @param fecha Marca de tiempo (segundos) en la que se emitió el recibo.
    struct Datos {
        uint256 campaniaId;
        uint256 monto;
        uint64 fecha;
    }

    /// @notice Dirección del contrato SaludChain autorizado a emitir recibos.
    address public immutable SALUDCHAIN;

    /// @dev Último identificador de recibo emitido.
    uint256 private _ultimoId;

    /// @dev Datos de cada recibo, por identificador.
    mapping(uint256 reciboId => Datos datos) private _datos;

    /// @notice Se emitió un recibo nuevo.
    /// @param reciboId Identificador del recibo (tokenId).
    /// @param donante Dirección que recibe el recibo.
    /// @param campaniaId Campaña a la que se donó.
    /// @param monto Monto donado en wei.
    event ReciboEmitido(uint256 indexed reciboId, address indexed donante, uint256 indexed campaniaId, uint256 monto);

    /// @notice Quien llamó no es el contrato SaludChain autorizado.
    error SoloSaludChain();

    /// @notice La dirección de SaludChain no puede ser la dirección cero.
    error DireccionInvalida();

    /// @notice El recibo consultado no existe.
    /// @param reciboId Identificador consultado.
    error ReciboInexistente(uint256 reciboId);

    /// @param saludChain Dirección del contrato SaludChain autorizado a emitir recibos.
    constructor(address saludChain) ERC721("Recibo SaludChain", "RSC") {
        if (saludChain == address(0)) revert DireccionInvalida();
        SALUDCHAIN = saludChain;
    }

    /// @notice Emite un recibo a favor de un donante.
    /// @dev Solo puede llamarlo SaludChain. Usa `_mint` (no `_safeMint`) para no ceder
    ///      el control a contratos receptores durante la donación.
    /// @param donante Dirección que recibe el recibo.
    /// @param campaniaId Campaña a la que se donó.
    /// @param monto Monto donado en wei.
    /// @return reciboId Identificador del recibo emitido.
    function emitir(address donante, uint256 campaniaId, uint256 monto) external returns (uint256 reciboId) {
        if (msg.sender != SALUDCHAIN) revert SoloSaludChain();

        reciboId = _ultimoId + 1;
        _ultimoId = reciboId;
        // forge-lint: disable-next-line(unsafe-typecast)
        _datos[reciboId] = Datos({campaniaId: campaniaId, monto: monto, fecha: uint64(block.timestamp)}); // uint64 alcanza para siglos

        _mint(donante, reciboId);
        emit ReciboEmitido(reciboId, donante, campaniaId, monto);
    }

    /// @notice Devuelve los datos de un recibo.
    /// @param reciboId Identificador del recibo.
    /// @return Datos del recibo (campaña, monto y fecha).
    function datosDe(uint256 reciboId) external view returns (Datos memory) {
        if (_ownerOf(reciboId) == address(0)) revert ReciboInexistente(reciboId);
        return _datos[reciboId];
    }

    /// @notice Metadatos del recibo codificados on-chain (JSON en base64).
    /// @param reciboId Identificador del recibo.
    /// @return URI de datos con nombre, descripción y atributos del recibo.
    function tokenURI(uint256 reciboId) public view override returns (string memory) {
        if (_ownerOf(reciboId) == address(0)) revert ReciboInexistente(reciboId);
        Datos memory d = _datos[reciboId];

        string memory json = string.concat(
            '{"name":"Recibo SaludChain #',
            Strings.toString(reciboId),
            '","description":"Comprobante de donacion en SaludChain","attributes":[',
            '{"trait_type":"Campania","value":',
            Strings.toString(d.campaniaId),
            '},{"trait_type":"Monto (wei)","value":"',
            Strings.toString(d.monto),
            '"},{"trait_type":"Fecha","display_type":"date","value":',
            Strings.toString(d.fecha),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
