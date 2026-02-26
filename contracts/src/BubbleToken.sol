// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BubbleToken is ERC20, Ownable {
    address public dexPair;
    mapping(address => bool) public authorized;
    mapping(address => uint256) public efficiencyCredits;
    uint256 public constant CREDIT_MULTIPLIER = 50;
    uint256 public constant MIN_CREDIT_TRANSFER = 1000 * 1e18; // Minimum 1,000 BUBBLE to earn credits
    uint256 public constant MAX_CREDITS = 5_000_000 * 1e18; // Cap at 5M credits

    event EfficiencyCreditsEarned(address indexed player, uint256 credits);
    event EfficiencyCreditsConsumed(address indexed player, uint256 credits);
    event DexPairSet(address indexed pair);
    event AuthorizedSet(address indexed account, bool status);

    error NotAuthorized();
    error InsufficientCredits();

    modifier onlyAuthorized() {
        if (!authorized[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor() ERC20("AI Bubble", "BUBBLE") Ownable(msg.sender) {}

    function setDexPair(address _pair) external onlyOwner {
        dexPair = _pair;
        emit DexPairSet(_pair);
    }

    function setAuthorized(address account, bool status) external onlyOwner {
        authorized[account] = status;
        emit AuthorizedSet(account, status);
    }

    // Kept for backward compat with GameController.initializeGame()
    function setGameController(address _controller) external onlyOwner {
        authorized[_controller] = true;
        emit AuthorizedSet(_controller, true);
    }

    function mint(address to, uint256 amount) external onlyAuthorized {
        _mint(to, amount);
    }

    function consumeCredits(address player, uint256 amount) external onlyAuthorized {
        if (efficiencyCredits[player] < amount) revert InsufficientCredits();
        efficiencyCredits[player] -= amount;
        emit EfficiencyCreditsConsumed(player, amount);
    }

    function burnFrom(address account, uint256 amount) external onlyAuthorized {
        _burn(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function getEffectiveBalance(address player, uint256 amount) external view returns (uint256) {
        uint256 maxBonus = (amount * CREDIT_MULTIPLIER) / 100;
        uint256 availableCredits = efficiencyCredits[player];

        if (availableCredits >= maxBonus) {
            return (amount * 150) / 100;
        }
        return amount + availableCredits;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (from == dexPair && to != address(0) && dexPair != address(0)) {
            if (value >= MIN_CREDIT_TRANSFER) {
                uint256 credits = (value * CREDIT_MULTIPLIER) / 100;
                uint256 currentCredits = efficiencyCredits[to];
                if (currentCredits + credits > MAX_CREDITS) {
                    credits = MAX_CREDITS - currentCredits;
                }
                if (credits > 0) {
                    efficiencyCredits[to] += credits;
                    emit EfficiencyCreditsEarned(to, credits);
                }
            }
        }
    }
}
