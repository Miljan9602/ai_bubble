// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGPUUpgrade {
    function getEffectiveTier(uint256 tokenId) external view returns (uint8);
    function setContracts(address nft, address token) external;
}
