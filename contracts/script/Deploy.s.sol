// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/BubbleNFT.sol";
import "../src/BubbleToken.sol";
import "../src/BubbleFarm.sol";
import "../src/GPUUpgrade.sol";
import "../src/FactionWar.sol";
import "../src/GameController.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        string[10] memory companyNames = [
            "SkynetAI",
            "GPT-420",
            "BrainDump.io",
            "Neural Bro Labs",
            "Rug Intelligence",
            "DeepFraud",
            "BaiduBubble",
            "AlibabaGPT",
            "WeChatBot3000",
            "Great Wall AI"
        ];

        vm.startBroadcast(deployerPrivateKey);

        // =====================================================================
        // 1. Deploy all 6 contracts (deployer owns everything initially)
        // =====================================================================
        BubbleNFT nft = new BubbleNFT(companyNames);
        BubbleToken token = new BubbleToken();
        BubbleFarm farm = new BubbleFarm();
        GPUUpgrade gpu = new GPUUpgrade();
        FactionWar war = new FactionWar();
        GameController controller = new GameController();

        // =====================================================================
        // 2. Register contract addresses on GameController
        // =====================================================================
        controller.setContracts(
            address(nft),
            address(token),
            address(farm),
            address(gpu),
            address(war)
        );

        // =====================================================================
        // 3. Wire contracts manually (deployer still owns all contracts)
        //    We do this instead of initializeGame() because ownership transfer
        //    order matters — deployer must wire before transferring ownership.
        // =====================================================================

        // NFT: set gameController so mint() calls registerMint()
        nft.setGameController(address(controller));

        // Token: authorize GameController, BubbleFarm, and GPUUpgrade
        token.setAuthorized(address(controller), true);
        token.setAuthorized(address(farm), true);
        token.setAuthorized(address(gpu), true);

        // Farm: wire its dependencies
        farm.setContracts(address(nft), address(token), address(gpu));

        // GPU: wire its dependencies
        gpu.setContracts(address(nft), address(token));

        // =====================================================================
        // 4. Transfer ownership to GameController
        //    After this, only GameController can manage these contracts.
        // =====================================================================
        farm.transferOwnership(address(controller));
        gpu.transferOwnership(address(controller));
        war.transferOwnership(address(controller));

        // NFT and Token use setGameController pattern (not Ownable transfer)
        // Their admin functions (withdraw, setAuthorized) remain with deployer

        // =====================================================================
        // 5. Grant OPERATOR_ROLE to deployer on GameController
        //    This allows the deployer to call startGame(), endGame(), etc.
        // =====================================================================
        controller.grantRole(controller.OPERATOR_ROLE(), vm.addr(deployerPrivateKey));

        // =====================================================================
        // 6. Mint initial liquidity tokens to deployer
        //    100M $BUBBLE for DEX liquidity pool (BUBBLE/SEI pair)
        // =====================================================================
        uint256 INITIAL_LIQUIDITY = 100_000_000 ether; // 100M tokens (18 decimals)
        controller.mintTokens(vm.addr(deployerPrivateKey), INITIAL_LIQUIDITY);

        // =====================================================================
        // 7. Initialize dynamic pricing (sets lastMintTimestamp for all companies)
        // =====================================================================
        nft.initializePricing(block.timestamp);

        // =====================================================================
        // 8. Start the game (activates farming)
        // =====================================================================
        controller.startGame(block.timestamp);

        vm.stopBroadcast();

        // =====================================================================
        // Log all deployed addresses
        // =====================================================================
        console.log("=== AI.Bubble Deployment Complete ===");
        console.log("");
        console.log("BubbleNFT:      ", address(nft));
        console.log("BubbleToken:    ", address(token));
        console.log("BubbleFarm:     ", address(farm));
        console.log("GPUUpgrade:     ", address(gpu));
        console.log("FactionWar:     ", address(war));
        console.log("GameController: ", address(controller));
        console.log("");
        console.log("Liquidity:      ", INITIAL_LIQUIDITY / 1 ether, "BUBBLE minted to deployer");
        console.log("Pricing:         dynamic decay initialized");
        console.log("Game started:    farming active");
        console.log("");
        console.log("=== Post-Deploy Steps ===");
        console.log("1. Update .env with contract addresses above");
        console.log("2. Set INDEXER_START_BLOCK to the deploy block number");
        console.log("3. Provide BUBBLE/SEI liquidity on DragonSwap");
        console.log("4. Set DEX pair: token.setDexPair(pairAddress)");
        console.log("5. Start the indexer: pnpm indexer");
    }
}
