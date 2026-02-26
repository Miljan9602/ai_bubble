// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IBubbleNFT.sol";
import "./interfaces/IBubbleToken.sol";
import "./interfaces/IGPUUpgrade.sol";

contract BubbleFarm is Ownable, ReentrancyGuard {
    event YieldClaimed(uint256 indexed tokenId, address indexed owner, uint256 amount);
    event NFTRegistered(uint256 indexed tokenId);
    event FarmingActiveChanged(bool active);
    event StartTimeSet(uint256 startTime);
    event ContractsSet(address indexed nft, address indexed token, address indexed gpuUpgrade);

    IBubbleNFT public bubbleNFT;
    IBubbleToken public bubbleToken;
    IGPUUpgrade public gpuUpgrade;

    uint256 public constant BASE_YIELD_PER_DAY = 10_000 * 1e18;
    uint16[6] public TIER_MULTIPLIERS = [100, 150, 200, 300, 500, 800];

    mapping(uint256 => uint256) public lastClaimTime;
    bool public farmingActive;
    uint256 public startTime;
    bool private _contractsSet;

    constructor() Ownable(msg.sender) {}

    function claim(uint256 tokenId) external nonReentrant {
        require(bubbleNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");

        uint256 amount = _claimInternal(tokenId);
        require(amount > 0, "Nothing to claim");

        bubbleToken.mint(msg.sender, amount);
        emit YieldClaimed(tokenId, msg.sender, amount);
    }

    function claimMultiple(uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length <= 50, "Too many tokens");
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(bubbleNFT.ownerOf(tokenIds[i]) == msg.sender, "Not NFT owner");

            uint256 amount = _claimInternal(tokenIds[i]);
            if (amount > 0) {
                emit YieldClaimed(tokenIds[i], msg.sender, amount);
            }
            totalAmount += amount;
        }

        require(totalAmount > 0, "Nothing to claim");
        bubbleToken.mint(msg.sender, totalAmount);
    }

    function registerNFT(uint256 tokenId) external {
        require(
            msg.sender == address(bubbleNFT) || msg.sender == owner(),
            "Not authorized"
        );
        require(lastClaimTime[tokenId] == 0, "Already registered");
        lastClaimTime[tokenId] = block.timestamp;
        emit NFTRegistered(tokenId);
    }

    function pendingYield(uint256 tokenId) public view returns (uint256) {
        uint256 lastClaim = lastClaimTime[tokenId];
        if (lastClaim == 0) return 0;
        if (!farmingActive || block.timestamp < startTime) return 0;

        uint8 tier = gpuUpgrade.getEffectiveTier(tokenId);
        uint16 multiplier = TIER_MULTIPLIERS[tier];
        uint256 elapsed = block.timestamp - lastClaim;

        return (elapsed * BASE_YIELD_PER_DAY * multiplier) / (100 * 86400);
    }

    function setFarmingActive(bool active) external onlyOwner {
        farmingActive = active;
        emit FarmingActiveChanged(active);
    }

    function setStartTime(uint256 _startTime) external onlyOwner {
        startTime = _startTime;
        emit StartTimeSet(_startTime);
    }

    function setContracts(address _nft, address _token, address _gpuUpgrade) external onlyOwner {
        require(!_contractsSet, "Already set");
        _contractsSet = true;
        bubbleNFT = IBubbleNFT(_nft);
        bubbleToken = IBubbleToken(_token);
        gpuUpgrade = IGPUUpgrade(_gpuUpgrade);
        emit ContractsSet(_nft, _token, _gpuUpgrade);
    }

    function _claimInternal(uint256 tokenId) internal returns (uint256 amount) {
        amount = pendingYield(tokenId);
        if (amount > 0) {
            lastClaimTime[tokenId] = block.timestamp;
        }
    }
}
