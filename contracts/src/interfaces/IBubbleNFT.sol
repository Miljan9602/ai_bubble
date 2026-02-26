// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBubbleNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getCompanyIdFromToken(uint256 tokenId) external pure returns (uint256);
    function setGameController(address controller) external;
    function getMintPrice(uint256 companyId) external view returns (uint256);
    function getBondingPrice(uint256 companyId) external view returns (uint256);
    function getLastMintTimestamp(uint256 companyId) external view returns (uint256);
    function initializePricing(uint256 startTimestamp) external;
    function getWalletFaction(address wallet) external view returns (uint8);
    function withdraw() external;
}
