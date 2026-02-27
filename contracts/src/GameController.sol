// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IBubbleNFT.sol";
import "./interfaces/IBubbleToken.sol";
import "./interfaces/IBubbleFarm.sol";
import "./interfaces/IGPUUpgrade.sol";
import "./interfaces/IFactionWar.sol";

contract GameController is AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant MAX_OPERATOR_MINT = 100_000_000 * 1e18; // L-09: 100M cap
    uint256 public operatorMinted;

    address public bubbleNFT;
    address public bubbleToken;
    address public bubbleFarm;
    address public gpuUpgrade;
    address public factionWar;

    bool public gameStarted;
    bool public gameEnded;
    uint256 public gameStartTime;
    uint256 public gameEndTime;

    bool private _contractsSet;
    bool private _initialized;

    event GameStarted(uint256 startTime);
    event GameEnded(uint256 endTime);
    event ContractsSet(address nft, address token, address farm, address gpu, address war);
    event MintRegistered(uint256 indexed tokenId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setContracts(
        address _nft,
        address _token,
        address _farm,
        address _gpu,
        address _war
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!_contractsSet, "Contracts already set");
        require(
            _nft != address(0) &&
            _token != address(0) &&
            _farm != address(0) &&
            _gpu != address(0) &&
            _war != address(0),
            "Zero address"
        );

        bubbleNFT = _nft;
        bubbleToken = _token;
        bubbleFarm = _farm;
        gpuUpgrade = _gpu;
        factionWar = _war;
        _contractsSet = true;

        emit ContractsSet(_nft, _token, _farm, _gpu, _war);
    }

    function initializeGame() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_contractsSet, "Contracts not set");
        require(!_initialized, "Already initialized");

        IBubbleNFT(bubbleNFT).setGameController(address(this));
        IBubbleToken(bubbleToken).setGameController(address(this));
        IBubbleToken(bubbleToken).setAuthorized(bubbleFarm, true);
        IBubbleToken(bubbleToken).setAuthorized(gpuUpgrade, true);
        IBubbleFarm(bubbleFarm).setContracts(bubbleNFT, bubbleToken, gpuUpgrade);
        IGPUUpgrade(gpuUpgrade).setContracts(bubbleNFT, bubbleToken);

        _initialized = true;
    }

    function startGame(uint256 startTime) external onlyRole(OPERATOR_ROLE) {
        require(_contractsSet, "Contracts not set");
        require(!gameStarted, "Already started");

        gameStarted = true;
        gameStartTime = startTime;

        IBubbleFarm(bubbleFarm).setStartTime(startTime);
        IBubbleFarm(bubbleFarm).setFarmingActive(true);

        emit GameStarted(startTime);
    }

    function endGame() external onlyRole(OPERATOR_ROLE) {
        require(gameStarted, "Not started");
        require(!gameEnded, "Already ended");

        gameEnded = true;
        gameEndTime = block.timestamp;

        IBubbleFarm(bubbleFarm).setFarmingActive(false);

        emit GameEnded(gameEndTime);
    }

    function registerMint(uint256 tokenId) external {
        require(msg.sender == bubbleNFT, "Only BubbleNFT");
        IBubbleFarm(bubbleFarm).registerNFT(tokenId);
        emit MintRegistered(tokenId);
    }

    function startFactionRound() external payable onlyRole(OPERATOR_ROLE) nonReentrant {
        IFactionWar(factionWar).startRound{value: msg.value}();
    }

    function finalizeFactionRound(uint256 roundId, bytes32 merkleRoot) external onlyRole(OPERATOR_ROLE) {
        IFactionWar(factionWar).finalizeRound(roundId, merkleRoot);
    }

    function mintTokens(address to, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(to != address(0), "Zero address");
        require(amount > 0, "Zero amount");
        require(operatorMinted + amount <= MAX_OPERATOR_MINT, "Operator mint cap exceeded");
        operatorMinted += amount;
        IBubbleToken(bubbleToken).mint(to, amount);
    }

    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        IBubbleFarm(bubbleFarm).setFarmingActive(false);
    }

    /// @notice Resume farming after an emergency pause (L-08 fix).
    /// @dev Gated by DEFAULT_ADMIN_ROLE (not OPERATOR) since pausing is admin-only.
    function resumeFarming() external onlyRole(DEFAULT_ADMIN_ROLE) {
        IBubbleFarm(bubbleFarm).setFarmingActive(true);
    }
}
