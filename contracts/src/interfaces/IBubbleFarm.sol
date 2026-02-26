// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBubbleFarm {
    function registerNFT(uint256 tokenId) external;
    function setFarmingActive(bool active) external;
    function setStartTime(uint256 startTime) external;
    function setContracts(address nft, address token, address gpuUpgrade) external;
}
