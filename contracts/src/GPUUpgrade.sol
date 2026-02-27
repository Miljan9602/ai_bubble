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
        require(_nft != address(0) && _token != address(0), "Zero address");
        _contractsSet = true;
        bubbleNFT = IBubbleNFT(_nft);
        bubbleToken = IBubbleToken(_token);
        emit ContractsSet(_nft, _token);
    }

    /// @notice Upgrade GPU tier for an NFT. Burns $BUBBLE (with optional efficiency credit discount).
    /// @dev Credit discount math: credits give 1.5x value, so creditsNeededForFull = cost * 100 / 150.
    ///      If player has full credits, actualBurn = creditsNeededForFull (33% cheaper).
    ///      If partial credits, coveredByCredits = credits * 150 / 100, remainder = cost - covered,
    ///      actualBurn = credits + remainder. CEI: state updates before external calls (L-01 fix).
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
            // creditsNeededForFull: amount of credits that fully cover upgradeCost at 1.5x value
            uint256 creditsNeededForFull = (upgradeCost * 100) / 150;

            if (playerCredits >= creditsNeededForFull) {
                creditsUsed = creditsNeededForFull;
                actualBurn = creditsNeededForFull;
            } else {
                creditsUsed = playerCredits;
                // Each credit is worth 1.5x: coveredByCredits = credits * 150 / 100
                uint256 coveredByCredits = (playerCredits * 150) / 100;
                uint256 remainder = upgradeCost - coveredByCredits;
                actualBurn = playerCredits + remainder;
            }
        } else {
            actualBurn = upgradeCost;
        }

        require(bubbleToken.balanceOf(msg.sender) >= actualBurn, "Insufficient BUBBLE");

        // --- Effects: state updates before external calls (CEI pattern, L-01 fix) ---
        gpuTier[tokenId] = nextTier;
        lastMaintenanceTime[tokenId] = block.timestamp;
        tierUpgradeTime[tokenId] = block.timestamp;

        // --- Interactions: external calls after state is finalized ---
        if (creditsUsed > 0) {
            bubbleToken.consumeCredits(msg.sender, creditsUsed);
        }

        bubbleToken.burnFrom(msg.sender, actualBurn);

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
