// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IGameController.sol";

contract BubbleNFT is ERC721, Ownable, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY_PER_COMPANY = 7500;
    uint256 public constant NUM_COMPANIES = 10;
    /// @dev Companies 0-4 are USA (faction 1), companies 5-9 are China (faction 2).
    uint256 public constant USA_COMPANY_THRESHOLD = 5;
    uint256 public constant BASE_PRICE = 0.01 ether;
    uint256 public constant MAX_PRICE = 0.20 ether;
    uint256 public constant PRICE_INCREMENT = 25336700000000; // (0.19 ether) / 7499
    uint256 public constant MIN_PRICE = 0.005 ether;
    uint256 public constant DECAY_RATE = 2_777_777_777_778; // wei/sec ≈ 0.01 ether/hour

    mapping(uint256 => uint256) public companySupply;
    mapping(uint256 => string) public companyName;
    mapping(uint256 => uint256) public lastMintTimestamp;
    mapping(address => uint8) private _walletFaction; // 0 = not chosen, 1 = USA, 2 = China

    address public gameController;
    bool public pricingInitialized;
    uint256 private _totalMintedCount;

    event CompanyMinted(
        uint256 indexed companyId,
        uint256 indexed tokenId,
        address indexed minter,
        uint256 price,
        uint256 bondingPrice,
        uint256 decayAmount
    );

    event FactionLocked(address indexed wallet, uint8 faction);
    event GameControllerSet(address indexed controller);

    constructor(
        string[10] memory _companyNames
    ) ERC721("AI.Bubble", "BUBBLE") Ownable(msg.sender) {
        for (uint256 i = 0; i < NUM_COMPANIES; i++) {
            companyName[i] = _companyNames[i];
        }
    }

    function mint(uint256 companyId, uint256 maxPrice) external payable nonReentrant {
        require(companyId < NUM_COMPANIES, "Invalid company ID");

        // Faction lock: first mint locks wallet, subsequent mints must match
        uint8 companyFaction = companyId < USA_COMPANY_THRESHOLD ? 1 : 2; // 1 = USA, 2 = China
        uint8 existingFaction = _walletFaction[msg.sender];
        if (existingFaction == 0) {
            _walletFaction[msg.sender] = companyFaction;
            emit FactionLocked(msg.sender, companyFaction);
        } else {
            require(existingFaction == companyFaction, "Wrong faction");
        }

        uint256 currentSupply = companySupply[companyId];
        require(currentSupply < MAX_SUPPLY_PER_COMPANY, "Company sold out");

        uint256 price = getMintPrice(companyId);
        require(price <= maxPrice, "Price exceeds maxPrice");
        require(msg.value >= price, "Insufficient payment");

        uint256 localIndex = currentSupply + 1;
        uint256 tokenId = companyId * 10000 + localIndex;

        // Compute decay for event before resetting timestamp
        uint256 bPrice = getBondingPrice(companyId);
        uint256 decayAmt = bPrice > price ? bPrice - price : 0;

        // --- Effects: all state updates ---
        companySupply[companyId] = localIndex;
        lastMintTimestamp[companyId] = block.timestamp;
        _totalMintedCount++;

        // Mint the token before any external calls (checks-effects-interactions)
        _mint(msg.sender, tokenId);

        // --- Interactions: external calls after state is finalized ---

        // Register in BubbleFarm via GameController so yield tracking starts
        if (gameController != address(0)) {
            IGameController(gameController).registerMint(tokenId);
        }

        emit CompanyMinted(companyId, tokenId, msg.sender, price, bPrice, decayAmt);

        // Refund excess payment (last external call)
        if (msg.value > price) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - price}("");
            require(success, "Refund failed");
        }
    }

    function getMintPrice(uint256 companyId) public view returns (uint256) {
        require(companyId < NUM_COMPANIES, "Invalid company ID");
        uint256 bPrice = getBondingPrice(companyId);

        uint256 lastMint = lastMintTimestamp[companyId];
        if (lastMint == 0) {
            // Pricing not initialized or no mint yet — return bonding price
            return bPrice;
        }

        uint256 elapsed = block.timestamp - lastMint;
        uint256 decay = elapsed * DECAY_RATE;

        if (decay >= bPrice - MIN_PRICE) {
            return MIN_PRICE;
        }
        return bPrice - decay;
    }

    function getBondingPrice(uint256 companyId) public view returns (uint256) {
        require(companyId < NUM_COMPANIES, "Invalid company ID");
        uint256 currentSupply = companySupply[companyId];
        return BASE_PRICE + (currentSupply * PRICE_INCREMENT);
    }

    function getLastMintTimestamp(uint256 companyId) external view returns (uint256) {
        require(companyId < NUM_COMPANIES, "Invalid company ID");
        return lastMintTimestamp[companyId];
    }

    function initializePricing(uint256 startTimestamp) external onlyOwner {
        require(!pricingInitialized, "Pricing already initialized");
        pricingInitialized = true;
        for (uint256 i = 0; i < NUM_COMPANIES; i++) {
            lastMintTimestamp[i] = startTimestamp;
        }
    }

    /// @notice Returns the faction for a company. 1 = USA (companies 0-4), 2 = China (companies 5-9).
    /// @dev Uses the same encoding as _walletFaction and mint() for consistency (M-03 fix).
    function getCompanyFaction(uint256 companyId) public pure returns (uint8) {
        require(companyId < NUM_COMPANIES, "Invalid company ID");
        return companyId < USA_COMPANY_THRESHOLD ? 1 : 2;
    }

    function getCompanyIdFromToken(uint256 tokenId) public pure returns (uint256) {
        return tokenId / 10000;
    }

    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
    }

    function setGameController(address _gameController) external onlyOwner {
        require(gameController == address(0), "Already set");
        require(_gameController != address(0), "Zero address");
        gameController = _gameController;
        emit GameControllerSet(_gameController);
    }

    function totalMinted() public view returns (uint256) {
        return _totalMintedCount;
    }

    function getWalletFaction(address wallet) external view returns (uint8) {
        return _walletFaction[wallet]; // 0=none, 1=USA, 2=China
    }

    /// @dev Soulbound: only minting (from == address(0)) is allowed, all transfers blocked.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        require(from == address(0), "Soulbound: non-transferable");
        return super._update(to, tokenId, auth);
    }
}
