// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IBubbleNFT.sol";
import "./interfaces/IBubbleToken.sol";

contract GPUUpgrade is Ownable, ReentrancyGuard {
    uint256 public constant MAINTENANCE_PERIOD = 7 days;

    uint256[6] public UPGRADE_COSTS = [
        0,
        50_000 * 1e18,
        150_000 * 1e18,
        400_000 * 1e18,
        1_000_000 * 1e18,
        2_500_000 * 1e18
    ];

    uint256[6] public MAINTENANCE_COSTS = [
        0,
        2_500 * 1e18,
        10_000 * 1e18,
        30_000 * 1e18,
        75_000 * 1e18,
        200_000 * 1e18
    ];

    IBubbleNFT public bubbleNFT;
    IBubbleToken public bubbleToken;

    mapping(uint256 => uint8) public gpuTier;
    mapping(uint256 => uint256) public lastMaintenanceTime;
    mapping(uint256 => uint256) public tierUpgradeTime;
    bool private _contractsSet;

    event GPUUpgraded(uint256 indexed tokenId, address indexed owner, uint8 newTier, uint256 cost);
    event MaintenancePaid(uint256 indexed tokenId, address indexed owner, uint8 tier, uint256 cost);
    event TierDowngraded(uint256 indexed tokenId, uint8 oldTier, uint8 newTier);
    event ContractsSet(address indexed nft, address indexed token);

    constructor() Ownable(msg.sender) {}

    function setContracts(address _nft, address _token) external onlyOwner {
        require(!_contractsSet, "Already set");
        _contractsSet = true;
        bubbleNFT = IBubbleNFT(_nft);
        bubbleToken = IBubbleToken(_token);
        emit ContractsSet(_nft, _token);
    }

    function upgrade(uint256 tokenId) external nonReentrant {
        require(address(bubbleNFT) != address(0), "Contracts not set");
        require(bubbleNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");

        uint8 currentTier = getEffectiveTier(tokenId);
        require(currentTier < 5, "Already max tier");

        uint8 storedTier = gpuTier[tokenId];
        require(currentTier == storedTier, "Pay maintenance first");

        uint8 nextTier = currentTier + 1;
        uint256 upgradeCost = UPGRADE_COSTS[nextTier];

        uint256 playerCredits = bubbleToken.efficiencyCredits(msg.sender);
        uint256 actualBurn;
        uint256 creditsUsed;

        if (playerCredits > 0) {
            uint256 creditsNeededForFull = (upgradeCost * 100) / 150;

            if (playerCredits >= creditsNeededForFull) {
                creditsUsed = creditsNeededForFull;
                actualBurn = creditsNeededForFull;
            } else {
                creditsUsed = playerCredits;
                uint256 coveredByCredits = (playerCredits * 150) / 100;
                uint256 remainder = upgradeCost - coveredByCredits;
                actualBurn = playerCredits + remainder;
            }
        } else {
            actualBurn = upgradeCost;
        }

        require(bubbleToken.balanceOf(msg.sender) >= actualBurn, "Insufficient BUBBLE");

        if (creditsUsed > 0) {
            bubbleToken.consumeCredits(msg.sender, creditsUsed);
        }

        bubbleToken.burnFrom(msg.sender, actualBurn);

        gpuTier[tokenId] = nextTier;
        lastMaintenanceTime[tokenId] = block.timestamp;
        tierUpgradeTime[tokenId] = block.timestamp;

        emit GPUUpgraded(tokenId, msg.sender, nextTier, actualBurn);
    }

    function payMaintenance(uint256 tokenId) external nonReentrant {
        require(address(bubbleNFT) != address(0), "Contracts not set");
        require(bubbleNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");

        uint8 effectiveTier = getEffectiveTier(tokenId);
        uint8 storedTier = gpuTier[tokenId];

        if (effectiveTier < storedTier) {
            emit TierDowngraded(tokenId, storedTier, effectiveTier);
            gpuTier[tokenId] = effectiveTier;
        }

        require(effectiveTier > 0, "No GPU to maintain");

        uint256 cost = MAINTENANCE_COSTS[effectiveTier];
        require(bubbleToken.balanceOf(msg.sender) >= cost, "Insufficient BUBBLE");

        bubbleToken.burnFrom(msg.sender, cost);
        lastMaintenanceTime[tokenId] = block.timestamp;

        emit MaintenancePaid(tokenId, msg.sender, effectiveTier, cost);
    }

    function getEffectiveTier(uint256 tokenId) public view returns (uint8) {
        uint8 storedTier = gpuTier[tokenId];
        if (storedTier == 0) return 0;

        uint256 lastMaint = lastMaintenanceTime[tokenId];
        if (lastMaint == 0) return storedTier;

        uint256 elapsed = block.timestamp - lastMaint;
        uint256 missedPeriods = elapsed / MAINTENANCE_PERIOD;

        if (missedPeriods == 0) return storedTier;
        if (missedPeriods >= storedTier) return 0;

        return storedTier - uint8(missedPeriods);
    }

    function enforceDowngrade(uint256 tokenId) external {
        uint8 effectiveTier = getEffectiveTier(tokenId);
        uint8 storedTier = gpuTier[tokenId];

        require(effectiveTier < storedTier, "No downgrade needed");

        gpuTier[tokenId] = effectiveTier;

        emit TierDowngraded(tokenId, storedTier, effectiveTier);
    }

    function getMaintenanceDeadline(uint256 tokenId) public view returns (uint256) {
        return lastMaintenanceTime[tokenId] + MAINTENANCE_PERIOD;
    }
}
