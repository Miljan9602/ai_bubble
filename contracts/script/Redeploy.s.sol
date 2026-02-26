// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/BubbleNFT.sol";
import "../src/BubbleToken.sol";
import "../src/BubbleFarm.sol";
import "../src/GPUUpgrade.sol";
import "../src/FactionWar.sol";
import "../src/GameController.sol";

/**
 * @title Redeploy script — keeps existing BubbleToken, redeploys everything else.
 *
 * Prerequisites:
 *   - Set EXISTING_BUBBLE_TOKEN in .env to the deployed BubbleToken address
 *   - Set OLD_FARM, OLD_GPU, OLD_CONTROLLER in .env to deauthorize them
 *   - Deployer must still own BubbleToken (setAuthorized is onlyOwner)
 */
contract RedeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Existing BubbleToken to keep
        address existingToken = vm.envAddress("EXISTING_BUBBLE_TOKEN");

        // Old contract addresses to deauthorize on the token
        address oldFarm = vm.envAddress("OLD_FARM");
        address oldGpu = vm.envAddress("OLD_GPU");
        address oldController = vm.envAddress("OLD_CONTROLLER");

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

        BubbleToken token = BubbleToken(existingToken);

        // =====================================================================
        // 1. Deauthorize old contracts on BubbleToken
        // =====================================================================
        token.setAuthorized(oldFarm, false);
        token.setAuthorized(oldGpu, false);
        token.setAuthorized(oldController, false);

        // =====================================================================
        // 2. Deploy 5 new contracts (BubbleToken stays)
        // =====================================================================
        BubbleNFT nft = new BubbleNFT(companyNames);
        BubbleFarm farm = new BubbleFarm();
        GPUUpgrade gpu = new GPUUpgrade();
        FactionWar war = new FactionWar();
        GameController controller = new GameController();

        // =====================================================================
        // 3. Register contract addresses on new GameController
        // =====================================================================
        controller.setContracts(
            address(nft),
            existingToken,
            address(farm),
            address(gpu),
            address(war)
        );

        // =====================================================================
        // 4. Wire contracts (deployer owns all new contracts at this point)
        // =====================================================================

        // NFT: set gameController so mint() calls registerMint()
        nft.setGameController(address(controller));

        // Token: authorize NEW contracts
        token.setAuthorized(address(controller), true);
        token.setAuthorized(address(farm), true);
        token.setAuthorized(address(gpu), true);

        // Farm: wire its dependencies
        farm.setContracts(address(nft), existingToken, address(gpu));

        // GPU: wire its dependencies
        gpu.setContracts(address(nft), existingToken);

        // =====================================================================
        // 5. Transfer ownership to GameController
        // =====================================================================
        farm.transferOwnership(address(controller));
        gpu.transferOwnership(address(controller));
        war.transferOwnership(address(controller));

        // NFT and Token remain owned by deployer

        // =====================================================================
        // 6. Grant OPERATOR_ROLE to deployer
        // =====================================================================
        controller.grantRole(controller.OPERATOR_ROLE(), deployer);

        // =====================================================================
        // 7. Initialize dynamic pricing (sets lastMintTimestamp for all companies)
        // =====================================================================
        nft.initializePricing(block.timestamp);

        // =====================================================================
        // 8. Start the game
        // =====================================================================
        controller.startGame(block.timestamp);

        vm.stopBroadcast();

        // =====================================================================
        // Log results
        // =====================================================================
        console.log("=== AI.Bubble Redeploy Complete ===");
        console.log("");
        console.log("BubbleNFT (NEW):      ", address(nft));
        console.log("BubbleToken (KEPT):   ", existingToken);
        console.log("BubbleFarm (NEW):     ", address(farm));
        console.log("GPUUpgrade (NEW):     ", address(gpu));
        console.log("FactionWar (NEW):     ", address(war));
        console.log("GameController (NEW): ", address(controller));
        console.log("");
        console.log("Old contracts deauthorized on BubbleToken.");
        console.log("Game started: farming active.");
        console.log("");
        console.log("=== Post-Redeploy Steps ===");
        console.log("1. Update .env with NEW contract addresses above");
        console.log("2. Set INDEXER_START_BLOCK to this deploy block");
        console.log("3. DEX pair is still set on BubbleToken - no change needed");
        console.log("4. Restart the indexer: pnpm indexer");
    }
}
