// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract FactionWar is Ownable, ReentrancyGuard {
    struct Round {
        bytes32 merkleRoot;
        uint256 prizePool;
        uint256 totalClaimed; // M-06: track total claimed to isolate round funds
        uint256 startTime;
        uint256 endTime;
        bool finalized;
    }

    struct Claim {
        uint256 totalAmount;
        uint256 claimedAmount;
        uint256 vestingStart;
    }

    uint256 public constant VESTING_DURATION = 7 days;
    uint256 public constant RECOVERY_DELAY = 30 days;
    uint256 public constant MIN_PRIZE_POOL = 0.1 ether;
    uint256 public currentRound;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => Claim)) public claims;

    event RoundStarted(uint256 indexed roundId, uint256 prizePool);
    event RoundFinalized(uint256 indexed roundId, bytes32 merkleRoot);
    event PrizeClaimed(uint256 indexed roundId, address indexed player, uint256 amount);
    event VestedWithdrawn(uint256 indexed roundId, address indexed player, uint256 amount);
    event FundsRecovered(uint256 indexed roundId, address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    function startRound() external payable onlyOwner {
        require(msg.value >= MIN_PRIZE_POOL, "Prize pool too small");
        currentRound++;
        Round storage r = rounds[currentRound];
        r.prizePool = msg.value;
        r.startTime = block.timestamp;
        emit RoundStarted(currentRound, msg.value);
    }

    function finalizeRound(uint256 roundId, bytes32 merkleRoot) external onlyOwner {
        Round storage r = rounds[roundId];
        require(r.startTime != 0, "Round does not exist");
        require(!r.finalized, "Already finalized");
        require(merkleRoot != bytes32(0), "Invalid root");

        r.merkleRoot = merkleRoot;
        r.finalized = true;
        r.endTime = block.timestamp;
        emit RoundFinalized(roundId, merkleRoot);
    }

    function addPrizePool(uint256 roundId) external payable onlyOwner {
        require(msg.value > 0, "Must send value");
        Round storage r = rounds[roundId];
        require(r.startTime != 0, "Round does not exist");
        require(!r.finalized, "Round already finalized");
        r.prizePool += msg.value;
    }

    function claimPrize(
        uint256 roundId,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        Round storage r = rounds[roundId];
        require(r.finalized, "Round not finalized");

        Claim storage c = claims[roundId][msg.sender];
        require(c.totalAmount == 0, "Already claimed");

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(roundId, msg.sender, amount))));
        require(MerkleProof.verify(proof, r.merkleRoot, leaf), "Invalid proof");

        c.totalAmount = amount;
        c.vestingStart = block.timestamp;
        emit PrizeClaimed(roundId, msg.sender, amount);
    }

    function withdrawVested(uint256 roundId) external nonReentrant {
        Claim storage c = claims[roundId][msg.sender];
        require(c.totalAmount > 0, "No claim found");

        uint256 elapsed = block.timestamp - c.vestingStart;
        uint256 vestedTotal;

        if (elapsed >= VESTING_DURATION) {
            vestedTotal = c.totalAmount;
        } else {
            vestedTotal = (c.totalAmount * elapsed) / VESTING_DURATION;
        }

        uint256 withdrawable = vestedTotal - c.claimedAmount;
        require(withdrawable > 0, "Nothing to withdraw");

        // M-06: Enforce per-round fund isolation — never withdraw more than the round's prizePool
        Round storage r = rounds[roundId];
        uint256 remainingPool = r.prizePool - r.totalClaimed;
        if (withdrawable > remainingPool) {
            withdrawable = remainingPool;
        }
        require(withdrawable > 0, "Round pool exhausted");

        c.claimedAmount += withdrawable;
        r.totalClaimed += withdrawable;

        (bool success, ) = payable(msg.sender).call{value: withdrawable}("");
        require(success, "Transfer failed");

        emit VestedWithdrawn(roundId, msg.sender, withdrawable);
    }

    /// @notice Recover unclaimed funds from a finalized round after a 30-day timelock.
    /// @dev M-06: Only recovers (prizePool - totalClaimed) for the specific round,
    ///      not the entire contract balance, preventing cross-round fund drainage.
    /// @param roundId The round to recover funds from.
    /// @param to The address to send recovered funds to.
    function recoverUnclaimedFunds(uint256 roundId, address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        Round storage r = rounds[roundId];
        require(r.finalized, "Round not finalized");
        require(block.timestamp > r.endTime + RECOVERY_DELAY, "Recovery too early");

        uint256 recoverable = r.prizePool - r.totalClaimed;
        require(recoverable > 0, "No funds to recover");

        // Mark as fully claimed so it can't be recovered twice
        r.totalClaimed = r.prizePool;

        (bool success, ) = to.call{value: recoverable}("");
        require(success, "Transfer failed");

        emit FundsRecovered(roundId, to, recoverable);
    }

    function getVestedAmount(
        uint256 roundId,
        address player
    ) public view returns (uint256 vested, uint256 withdrawable) {
        Claim storage c = claims[roundId][player];
        if (c.totalAmount == 0) return (0, 0);

        uint256 elapsed = block.timestamp - c.vestingStart;

        if (elapsed >= VESTING_DURATION) {
            vested = c.totalAmount;
        } else {
            vested = (c.totalAmount * elapsed) / VESTING_DURATION;
        }

        withdrawable = vested - c.claimedAmount;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }
}
