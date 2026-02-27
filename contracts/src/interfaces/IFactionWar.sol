// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFactionWar {
    function startRound() external payable;
    function finalizeRound(uint256 roundId, bytes32 merkleRoot) external;
    function recoverUnclaimedFunds(uint256 roundId, address payable to) external;
}
