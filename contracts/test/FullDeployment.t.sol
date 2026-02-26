// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/BubbleNFT.sol";
import "../src/BubbleToken.sol";
import "../src/BubbleFarm.sol";
import "../src/GPUUpgrade.sol";
import "../src/FactionWar.sol";
import "../src/GameController.sol";

/// @title FullDeployment End-to-End Tests
/// @notice Simulates the exact Deploy.s.sol mainnet flow:
///   - Deployer keeps ownership of BubbleNFT and BubbleToken
///   - Farm, GPU, War ownership transferred to GameController
///   - Manual wiring (NOT initializeGame) for NFT, Token auth, Farm/GPU contracts
///   - startGame via OPERATOR_ROLE to activate farming (requires _contractsSet only)
contract FullDeploymentTest is Test {
    // -----------------------------------------------------------------------
    // Contracts
    // -----------------------------------------------------------------------
    BubbleNFT public nft;
    BubbleToken public token;
    BubbleFarm public farm;
    GPUUpgrade public gpu;
    FactionWar public war;
    GameController public controller;

    // -----------------------------------------------------------------------
    // Actors
    // -----------------------------------------------------------------------
    address public deployer = makeAddr("deployer");
    address public player1 = makeAddr("player1");
    address public player2 = makeAddr("player2");
    address public player3 = makeAddr("player3");
    address public nobody = makeAddr("nobody");

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    string[10] companyNames = [
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

    uint256 constant BASE_YIELD_PER_DAY = 10_000 * 1e18;
    uint256 constant ONE_DAY = 86400;

    // -----------------------------------------------------------------------
    // Deploy + Wire (mirrors Deploy.s.sol EXACTLY)
    // -----------------------------------------------------------------------

    /// @dev Deploys and wires contracts exactly as Deploy.s.sol.
    /// Does NOT call initializeGame() — all wiring is manual.
    /// Then starts the game so farming is active for most tests.
    function setUp() public {
        vm.startPrank(deployer);

        // --- Deploy all 6 contracts ---
        nft = new BubbleNFT(companyNames);
        token = new BubbleToken();
        farm = new BubbleFarm();
        gpu = new GPUUpgrade();
        war = new FactionWar();
        controller = new GameController();

        // --- Wire GameController (stores addresses) ---
        controller.setContracts(
            address(nft),
            address(token),
            address(farm),
            address(gpu),
            address(war)
        );

        // --- Manual wiring (deployer is owner of all contracts at this point) ---

        // NFT: set gameController so mint() calls controller.registerMint()
        nft.setGameController(address(controller));

        // Token: authorize controller, farm, and gpu for mint/burn/consumeCredits
        token.setAuthorized(address(controller), true);
        token.setAuthorized(address(farm), true);
        token.setAuthorized(address(gpu), true);

        // Farm: set contract references
        farm.setContracts(address(nft), address(token), address(gpu));

        // GPU: set contract references
        gpu.setContracts(address(nft), address(token));

        // --- Transfer ownership of Farm, GPU, War to Controller ---
        // Deployer keeps NFT and Token ownership (for withdraw, setAuthorized, setDexPair)
        farm.transferOwnership(address(controller));
        gpu.transferOwnership(address(controller));
        war.transferOwnership(address(controller));

        // --- Grant OPERATOR_ROLE to deployer ---
        controller.grantRole(controller.OPERATOR_ROLE(), deployer);

        // --- Initialize dynamic pricing ---
        nft.initializePricing(block.timestamp);

        vm.stopPrank();

        // --- Start the game ---
        vm.prank(deployer);
        controller.startGame(block.timestamp);

        // --- Fund players ---
        vm.deal(player1, 100 ether);
        vm.deal(player2, 100 ether);
        vm.deal(player3, 100 ether);
    }

    // =======================================================================
    //  HELPERS
    // =======================================================================

    /// @dev Mint an NFT for a player from a given company, returning the tokenId.
    function _mintNFT(address player, uint256 companyId) internal returns (uint256 tokenId) {
        uint256 price = nft.getMintPrice(companyId);
        vm.prank(player);
        nft.mint{value: price}(companyId, price);
        uint256 localIndex = nft.companySupply(companyId);
        tokenId = companyId * 10000 + localIndex;
    }

    /// @dev Advance time by a number of seconds.
    function _advanceTime(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    /// @dev Build a single-leaf merkle tree and return (root, proof).
    ///      Uses double-hashing to prevent second-preimage attacks.
    ///      Includes roundId in the leaf to prevent cross-round proof reuse.
    function _singleLeafMerkle(
        uint256 roundId,
        address player,
        uint256 amount
    ) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = keccak256(bytes.concat(keccak256(abi.encode(roundId, player, amount))));
        proof = new bytes32[](0);
    }

    /// @dev Build a two-leaf merkle tree and return (root, proofForLeafA, proofForLeafB).
    ///      Uses double-hashing to prevent second-preimage attacks.
    ///      Includes roundId in the leaf to prevent cross-round proof reuse.
    function _twoLeafMerkle(
        uint256 roundId,
        address playerA,
        uint256 amountA,
        address playerB,
        uint256 amountB
    )
        internal
        pure
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        bytes32 leafA = keccak256(bytes.concat(keccak256(abi.encode(roundId, playerA, amountA))));
        bytes32 leafB = keccak256(bytes.concat(keccak256(abi.encode(roundId, playerB, amountB))));

        // Sort leaves for standard merkle tree ordering
        if (uint256(leafA) <= uint256(leafB)) {
            root = keccak256(abi.encodePacked(leafA, leafB));
        } else {
            root = keccak256(abi.encodePacked(leafB, leafA));
        }

        proofA = new bytes32[](1);
        proofA[0] = leafB;

        proofB = new bytes32[](1);
        proofB[0] = leafA;
    }

    // =======================================================================
    //  TEST 1: Deployment Wiring Verification
    // =======================================================================

    /// @notice Verifies every aspect of the Deploy.s.sol wiring:
    ///   - All 6 contracts deployed (non-zero addresses)
    ///   - Controller stores correct addresses
    ///   - NFT.gameController == controller
    ///   - Token.authorized for controller, farm, gpu
    ///   - Farm.owner == controller
    ///   - GPU.owner == controller
    ///   - War.owner == controller
    ///   - Deployer keeps NFT and Token ownership
    ///   - Deployer has OPERATOR_ROLE and DEFAULT_ADMIN_ROLE
    function test_deploymentWiring() public view {
        // All 6 contracts are deployed (non-zero)
        assertTrue(address(nft) != address(0), "NFT not deployed");
        assertTrue(address(token) != address(0), "Token not deployed");
        assertTrue(address(farm) != address(0), "Farm not deployed");
        assertTrue(address(gpu) != address(0), "GPU not deployed");
        assertTrue(address(war) != address(0), "War not deployed");
        assertTrue(address(controller) != address(0), "Controller not deployed");

        // Controller stores correct addresses
        assertEq(controller.bubbleNFT(), address(nft), "Controller NFT mismatch");
        assertEq(controller.bubbleToken(), address(token), "Controller Token mismatch");
        assertEq(controller.bubbleFarm(), address(farm), "Controller Farm mismatch");
        assertEq(controller.gpuUpgrade(), address(gpu), "Controller GPU mismatch");
        assertEq(controller.factionWar(), address(war), "Controller War mismatch");

        // NFT.gameController == controller
        assertEq(nft.gameController(), address(controller), "NFT gameController mismatch");

        // Token authorization: controller, farm, gpu
        assertTrue(token.authorized(address(controller)), "Controller not authorized on Token");
        assertTrue(token.authorized(address(farm)), "Farm not authorized on Token");
        assertTrue(token.authorized(address(gpu)), "GPU not authorized on Token");

        // Ownership: Farm, GPU, War owned by Controller
        assertEq(farm.owner(), address(controller), "Farm owner not Controller");
        assertEq(gpu.owner(), address(controller), "GPU owner not Controller");
        assertEq(war.owner(), address(controller), "War owner not Controller");

        // Ownership: NFT and Token remain with deployer
        assertEq(nft.owner(), deployer, "NFT owner should be deployer");
        assertEq(token.owner(), deployer, "Token owner should be deployer");

        // Deployer roles on Controller
        assertTrue(
            controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), deployer),
            "Deployer missing DEFAULT_ADMIN_ROLE"
        );
        assertTrue(
            controller.hasRole(controller.OPERATOR_ROLE(), deployer),
            "Deployer missing OPERATOR_ROLE"
        );

        // Game is started and farming is active
        assertTrue(controller.gameStarted(), "Game not started");
        assertTrue(farm.farmingActive(), "Farming not active");
        assertGt(farm.startTime(), 0, "Start time not set");
    }

    // =======================================================================
    //  TEST 2: Mint Auto-Registers in Farm
    // =======================================================================

    /// @notice After deployment wiring + startGame, minting an NFT should
    ///   automatically register it in BubbleFarm via the chain:
    ///   NFT.mint() -> controller.registerMint() -> farm.registerNFT()
    ///   No manual registerNFT call should be needed.
    function test_mintAutoRegistersFarm() public {
        // Mint an NFT — the auto-registration chain should fire
        uint256 tokenId = _mintNFT(player1, 0); // Company 0 (SkynetAI, USA)

        // Verify the NFT was minted to player1
        assertEq(nft.ownerOf(tokenId), player1, "NFT not minted to player1");
        assertEq(tokenId, 1, "First mint of company 0 should be tokenId 1");

        // Verify the farm registered the NFT (lastClaimTime > 0)
        uint256 lastClaim = farm.lastClaimTime(tokenId);
        assertGt(lastClaim, 0, "Farm did not auto-register NFT (lastClaimTime == 0)");
        assertEq(lastClaim, block.timestamp, "lastClaimTime should be current block.timestamp");

        // Verify yield starts accruing after time passes
        _advanceTime(ONE_DAY);
        uint256 pending = farm.pendingYield(tokenId);
        assertApproxEqRel(pending, BASE_YIELD_PER_DAY, 0.01e18, "1-day yield incorrect");
    }

    // =======================================================================
    //  TEST 3: Full Game Lifecycle
    // =======================================================================

    /// @notice End-to-end lifecycle test:
    ///   1. Deploy + wire + startGame (done in setUp)
    ///   2. Player1 mints USA NFT (company 0)
    ///   3. Player2 mints China NFT (company 5)
    ///   4. Advance 1 day -> both claim ~10,000 BUBBLE each
    ///   5. Advance 5 more days -> Player1 claims and upgrades GPU to tier 1
    ///   6. Advance 1 day -> Player1 earns 15,000/day (1.5x), Player2 still 10,000/day
    ///   7. Player1 pays maintenance
    ///   8. Player2 at tier 0 has nothing to maintain
    ///   9. Operator starts faction round with 10 BNB
    ///  10. Operator finalizes with merkle root
    ///  11. Player1 claims prize, waits 3.5 days, withdraws half
    ///  12. Wait full 7 days, withdraw rest
    function test_fullGameLifecycle() public {
        // --- Step 2: Player1 mints USA NFT (company 0) ---
        uint256 p1Token = _mintNFT(player1, 0);
        assertEq(nft.ownerOf(p1Token), player1, "P1 NFT ownership");
        assertEq(nft.getCompanyFaction(0), 0, "Company 0 should be USA faction");

        // --- Step 3: Player2 mints China NFT (company 5) ---
        uint256 p2Token = _mintNFT(player2, 5);
        assertEq(nft.ownerOf(p2Token), player2, "P2 NFT ownership");
        assertEq(nft.getCompanyFaction(5), 1, "Company 5 should be China faction");

        // --- Step 4: Advance 1 day, both claim ~10,000 BUBBLE ---
        _advanceTime(ONE_DAY);

        uint256 p1Pending = farm.pendingYield(p1Token);
        uint256 p2Pending = farm.pendingYield(p2Token);
        assertApproxEqRel(p1Pending, BASE_YIELD_PER_DAY, 0.01e18, "P1 day-1 yield");
        assertApproxEqRel(p2Pending, BASE_YIELD_PER_DAY, 0.01e18, "P2 day-1 yield");

        vm.prank(player1);
        farm.claim(p1Token);
        vm.prank(player2);
        farm.claim(p2Token);

        assertApproxEqRel(token.balanceOf(player1), BASE_YIELD_PER_DAY, 0.01e18, "P1 balance after day-1 claim");
        assertApproxEqRel(token.balanceOf(player2), BASE_YIELD_PER_DAY, 0.01e18, "P2 balance after day-1 claim");

        // --- Step 5: Advance 5 more days, Player1 claims and upgrades to tier 1 ---
        _advanceTime(5 * ONE_DAY);

        vm.prank(player1);
        farm.claim(p1Token);

        // Player1 should have ~60,000 BUBBLE total (1 day + 5 days at 10k/day)
        uint256 p1Balance = token.balanceOf(player1);
        assertApproxEqRel(p1Balance, 60_000e18, 0.01e18, "P1 balance after 6 days");
        assertGt(p1Balance, 50_000e18, "P1 must have enough for tier 1 upgrade (50,000)");

        // Upgrade to tier 1 (costs 50,000 BUBBLE, no credits)
        vm.prank(player1);
        gpu.upgrade(p1Token);

        assertEq(gpu.gpuTier(p1Token), 1, "P1 GPU should be tier 1");
        assertEq(gpu.getEffectiveTier(p1Token), 1, "P1 effective tier should be 1");

        // Player1 balance reduced by upgrade cost
        uint256 p1BalanceAfterUpgrade = token.balanceOf(player1);
        assertApproxEqRel(
            p1BalanceAfterUpgrade,
            p1Balance - 50_000e18,
            0.01e18,
            "P1 balance after upgrade"
        );

        // --- Step 6: Advance 1 day, verify different yield rates ---
        _advanceTime(ONE_DAY);

        // Player1 at tier 1 (1.5x): 15,000/day
        uint256 p1YieldTier1 = farm.pendingYield(p1Token);
        assertApproxEqRel(p1YieldTier1, 15_000e18, 0.01e18, "P1 tier-1 yield should be 15,000/day");

        // Player2 at tier 0 (1x): 10,000/day (accumulated 6 days unclaimed)
        // Player2 claimed at day 1, so 5 days of farming + 1 more day = 6 days unclaimed
        uint256 p2YieldDay7 = farm.pendingYield(p2Token);
        assertApproxEqRel(p2YieldDay7, 60_000e18, 0.01e18, "P2 should have 6 days of tier-0 yield");

        // Claim for both
        vm.prank(player1);
        farm.claim(p1Token);
        vm.prank(player2);
        farm.claim(p2Token);

        // --- Step 7: Player1 pays maintenance (before 7-day deadline) ---
        // Maintenance period is 7 days from upgrade. We are 1 day past upgrade.
        // Player1 has enough BUBBLE from claims.
        vm.prank(player1);
        gpu.payMaintenance(p1Token);

        // Verify tier is still 1 after maintenance
        assertEq(gpu.getEffectiveTier(p1Token), 1, "P1 tier should still be 1 after maintenance");

        // --- Step 8: Player2 at tier 0 has nothing to maintain (no-op) ---
        assertEq(gpu.getEffectiveTier(p2Token), 0, "P2 should be at tier 0");
        // Calling payMaintenance for tier 0 would revert with "No GPU to maintain"
        vm.expectRevert("No GPU to maintain");
        vm.prank(player2);
        gpu.payMaintenance(p2Token);

        // --- Step 9: Operator starts faction round with 10 BNB prize ---
        vm.deal(deployer, 100 ether);
        vm.prank(deployer);
        controller.startFactionRound{value: 10 ether}();

        // Verify round was created
        FactionWar.Round memory round = war.getRound(1);
        assertEq(round.prizePool, 10 ether, "Round prize pool should be 10 BNB");
        assertGt(round.startTime, 0, "Round start time should be set");
        assertFalse(round.finalized, "Round should not be finalized yet");

        // --- Step 10: Operator finalizes with merkle root ---
        // Player1 gets 2 BNB prize (single-leaf merkle for simplicity)
        uint256 prizeAmount = 2 ether;
        (bytes32 merkleRoot, bytes32[] memory proof) = _singleLeafMerkle(1, player1, prizeAmount);

        vm.prank(deployer);
        controller.finalizeFactionRound(1, merkleRoot);

        round = war.getRound(1);
        assertTrue(round.finalized, "Round should be finalized");
        assertEq(round.merkleRoot, merkleRoot, "Merkle root mismatch");

        // --- Step 11: Player1 claims prize, waits 3.5 days, withdraws half ---
        uint256 p1NativeBalBefore = player1.balance;

        vm.prank(player1);
        war.claimPrize(1, prizeAmount, proof);

        // Immediately after claim: nothing vested yet
        (uint256 vested, uint256 withdrawable) = war.getVestedAmount(1, player1);
        assertEq(vested, 0, "No vesting immediately after claim");
        assertEq(withdrawable, 0, "Nothing withdrawable immediately");

        // Wait 3.5 days (half of vesting period)
        _advanceTime(3.5 days);

        (vested, withdrawable) = war.getVestedAmount(1, player1);
        assertApproxEqRel(vested, prizeAmount / 2, 0.01e18, "Half should be vested at 3.5 days");
        assertApproxEqRel(withdrawable, prizeAmount / 2, 0.01e18, "Half should be withdrawable");

        // Withdraw the vested half
        vm.prank(player1);
        war.withdrawVested(1);

        uint256 withdrawn1 = player1.balance - p1NativeBalBefore;
        assertApproxEqRel(withdrawn1, prizeAmount / 2, 0.01e18, "Should have withdrawn ~1 BNB");

        // --- Step 12: Wait full 7 days from claim, withdraw rest ---
        _advanceTime(3.5 days); // Now at 7 days total from claim

        (vested, withdrawable) = war.getVestedAmount(1, player1);
        assertEq(vested, prizeAmount, "Full amount should be vested");
        assertApproxEqRel(withdrawable, prizeAmount / 2, 0.01e18, "Remaining half withdrawable");

        vm.prank(player1);
        war.withdrawVested(1);

        uint256 totalWithdrawn = player1.balance - p1NativeBalBefore;
        assertApproxEqRel(totalWithdrawn, prizeAmount, 0.01e18, "Should have withdrawn full prize");
    }

    // =======================================================================
    //  TEST 4: burnFrom Requires No Allowance
    // =======================================================================

    /// @notice Verifies that authorized callers (GPU) can burnFrom without the
    ///   user calling approve(). This is the audit fix where _spendAllowance was
    ///   removed from burnFrom.
    function test_burnFromNoAllowanceNeeded() public {
        // Mint an NFT and farm enough BUBBLE for an upgrade
        uint256 tokenId = _mintNFT(player1, 0);
        _advanceTime(6 * ONE_DAY);
        vm.prank(player1);
        farm.claim(tokenId);

        uint256 balanceBefore = token.balanceOf(player1);
        assertGt(balanceBefore, 50_000e18, "Need at least 50k BUBBLE");

        // Verify player1 has NOT approved the GPU contract
        assertEq(
            token.allowance(player1, address(gpu)),
            0,
            "Allowance should be 0 - no approve() called"
        );

        // GPU upgrade calls burnFrom internally — should succeed without approval
        vm.prank(player1);
        gpu.upgrade(tokenId);

        // Verify tokens were burned
        uint256 balanceAfter = token.balanceOf(player1);
        assertEq(balanceAfter, balanceBefore - 50_000e18, "Tokens should be burned without allowance");
        assertEq(gpu.gpuTier(tokenId), 1, "GPU should be tier 1");
    }

    // =======================================================================
    //  TEST 5: GPU Upgrade with Efficiency Credits
    // =======================================================================

    /// @notice Tests the efficiency credit system end-to-end:
    ///   1. Set dexPair on token
    ///   2. Transfer tokens from the DEX pair address to player (earns credits)
    ///   3. Player upgrades GPU — credits reduce the actual burn cost
    ///   4. Verify credits were consumed correctly
    function test_gpuUpgradeWithCredits() public {
        // Step 1: Set a mock DEX pair address
        address dexPair = makeAddr("dexPair");
        vm.prank(deployer); // deployer still owns token
        token.setDexPair(dexPair);
        assertEq(token.dexPair(), dexPair, "DEX pair not set");

        // Step 2: Mint tokens to the DEX pair, then transfer to player1
        // This simulates a "buy from DEX" which awards 50% efficiency credits
        uint256 buyAmount = 100_000e18;
        vm.prank(address(controller)); // controller is authorized to mint
        token.mint(dexPair, buyAmount);

        // Transfer from dexPair to player1 — triggers _update hook, awarding credits
        vm.prank(dexPair);
        token.transfer(player1, buyAmount);

        // Verify credits were earned: 50% of buyAmount = 50,000e18
        uint256 expectedCredits = (buyAmount * 50) / 100;
        assertEq(
            token.efficiencyCredits(player1),
            expectedCredits,
            "Credits should be 50% of buy amount"
        );

        // Step 3: Mint an NFT for player1 and verify they can upgrade with credits
        uint256 tokenId = _mintNFT(player1, 0);

        uint256 balanceBefore = token.balanceOf(player1);
        uint256 creditsBefore = token.efficiencyCredits(player1);

        // Upgrade to tier 1 (costs 50,000 BUBBLE normally)
        // With credits: creditsNeededForFull = 50_000e18 * 100 / 150 = 33_333.33e18
        // Player has 50_000e18 credits >= creditsNeededForFull
        // So creditsUsed = creditsNeededForFull, actualBurn = creditsNeededForFull
        vm.prank(player1);
        gpu.upgrade(tokenId);

        uint256 balanceAfter = token.balanceOf(player1);
        uint256 creditsAfter = token.efficiencyCredits(player1);
        uint256 upgradeCost = 50_000e18;
        uint256 creditsNeededForFull = (upgradeCost * 100) / 150;

        // With full credits coverage: actualBurn = creditsNeededForFull (less than 50k)
        uint256 actualBurn = creditsNeededForFull;
        assertEq(
            balanceBefore - balanceAfter,
            actualBurn,
            "Should burn less tokens when using credits"
        );
        assertLt(actualBurn, upgradeCost, "Credit discount should reduce burn cost");
        assertEq(
            creditsBefore - creditsAfter,
            creditsNeededForFull,
            "Credits consumed should equal creditsNeededForFull"
        );
        assertEq(gpu.gpuTier(tokenId), 1, "GPU should be tier 1");
    }

    // =======================================================================
    //  TEST 6: Maintenance Downgrade Cascade
    // =======================================================================

    /// @notice Tests multiple tier upgrades then maintenance decay:
    ///   1. Player farms enough for multiple upgrades
    ///   2. Upgrade to tier 3
    ///   3. Miss 2 maintenance periods (14 days)
    ///   4. Effective tier should be 1 (3 - 2 = 1)
    ///   5. Anyone can call enforceDowngrade to update stored tier
    ///   6. Upgrade requires maintenance current (no debt laundering)
    function test_maintenanceDowngradeCascade() public {
        // Mint NFT
        uint256 tokenId = _mintNFT(player1, 0);

        // Farm for a long time to accumulate enough BUBBLE for tier 3
        // Tier 1: 50,000, Tier 2: 150,000, Tier 3: 400,000
        // Total needed: 600,000 BUBBLE. At 10k/day = 60 days of farming.
        _advanceTime(65 * ONE_DAY);
        vm.prank(player1);
        farm.claim(tokenId);

        uint256 balance = token.balanceOf(player1);
        assertGt(balance, 600_000e18, "Need at least 600k BUBBLE for tier 3");

        // Upgrade tier 0 -> 1
        vm.prank(player1);
        gpu.upgrade(tokenId);
        assertEq(gpu.gpuTier(tokenId), 1, "Should be tier 1");
        assertEq(gpu.getEffectiveTier(tokenId), 1, "Effective tier 1");

        // Pay maintenance to keep tier 1, then upgrade again
        // (maintenance is set on upgrade, so we can upgrade immediately)
        // Upgrade tier 1 -> 2
        vm.prank(player1);
        gpu.upgrade(tokenId);
        assertEq(gpu.gpuTier(tokenId), 2, "Should be tier 2");
        assertEq(gpu.getEffectiveTier(tokenId), 2, "Effective tier 2");

        // Upgrade tier 2 -> 3
        vm.prank(player1);
        gpu.upgrade(tokenId);
        assertEq(gpu.gpuTier(tokenId), 3, "Should be tier 3");
        assertEq(gpu.getEffectiveTier(tokenId), 3, "Effective tier 3");

        // Miss 2 maintenance periods (14 days without paying)
        _advanceTime(14 days);

        // Effective tier = storedTier - missedPeriods = 3 - 2 = 1
        assertEq(
            gpu.getEffectiveTier(tokenId),
            1,
            "Effective tier should be 1 after missing 2 periods"
        );

        // Stored tier is still 3 (lazy evaluation — not yet enforced)
        assertEq(gpu.gpuTier(tokenId), 3, "Stored tier should still be 3");

        // Cannot upgrade when maintenance is lapsed (M-3 fix)
        vm.prank(player1);
        vm.expectRevert("Pay maintenance first");
        gpu.upgrade(tokenId);

        // Anyone can call enforceDowngrade
        vm.prank(nobody);
        gpu.enforceDowngrade(tokenId);

        // After enforceDowngrade (without timer reset), stored tier is set to
        // the effective tier at call time (1). But since lastMaintenanceTime
        // is NOT reset, the elapsed time still exceeds the new stored tier,
        // so effective tier drops to 0.
        assertEq(gpu.gpuTier(tokenId), 1, "Stored tier should now be 1");
        assertEq(gpu.getEffectiveTier(tokenId), 0, "Effective tier should be 0 (timer not reset)");

        // Player must pay maintenance to restore their tier
        vm.prank(player1);
        farm.claim(tokenId);

        // Verify farming yield reflects tier 0 (1x) since maintenance wasn't paid
        _advanceTime(ONE_DAY);
        uint256 pending = farm.pendingYield(tokenId);
        assertApproxEqRel(pending, 10_000e18, 0.01e18, "Yield should be 10,000/day at tier 0");
    }

    // =======================================================================
    //  TEST 7: Emergency Pause
    // =======================================================================

    /// @notice Admin pauses the game, farming stops, no yield accrues during pause.
    function test_emergencyPause() public {
        // Mint an NFT and start earning
        uint256 tokenId = _mintNFT(player1, 0);

        // Advance 1 day, verify yield accrued
        _advanceTime(ONE_DAY);
        uint256 pendingBefore = farm.pendingYield(tokenId);
        assertApproxEqRel(pendingBefore, BASE_YIELD_PER_DAY, 0.01e18, "Should have 1 day yield");

        // Claim the yield before pause
        vm.prank(player1);
        farm.claim(tokenId);
        uint256 balanceAfterClaim = token.balanceOf(player1);
        assertApproxEqRel(balanceAfterClaim, BASE_YIELD_PER_DAY, 0.01e18, "Claimed 1 day yield");

        // Admin pauses
        vm.prank(deployer);
        controller.emergencyPause();

        // Verify farming is inactive
        assertFalse(farm.farmingActive(), "Farming should be inactive after pause");

        // Advance another day — no yield should accrue
        _advanceTime(ONE_DAY);
        uint256 pendingDuringPause = farm.pendingYield(tokenId);
        assertEq(pendingDuringPause, 0, "No yield should accrue during pause");

        // Balance should not change (nothing to claim)
        vm.expectRevert("Nothing to claim");
        vm.prank(player1);
        farm.claim(tokenId);

        assertEq(
            token.balanceOf(player1),
            balanceAfterClaim,
            "Balance should be unchanged during pause"
        );
    }

    // =======================================================================
    //  TEST 8: Cannot Re-wire After setContracts
    // =======================================================================

    /// @notice setContracts on GameController can only be called once.
    ///   The second call should revert with "Contracts already set".
    function test_cannotRewireAfterSet() public {
        // Attempt to call setContracts again (deployer has DEFAULT_ADMIN_ROLE)
        vm.prank(deployer);
        vm.expectRevert("Contracts already set");
        controller.setContracts(
            address(nft),
            address(token),
            address(farm),
            address(gpu),
            address(war)
        );
    }

    // =======================================================================
    //  TEST 9: Only NFT Can Call registerMint on Controller
    // =======================================================================

    /// @notice Only BubbleNFT can call controller.registerMint().
    ///   All other callers should be rejected.
    function test_onlyNFTCanRegisterMint() public {
        // Random address cannot call registerMint
        vm.prank(nobody);
        vm.expectRevert("Only BubbleNFT");
        controller.registerMint(1);

        // Deployer (admin + operator) cannot call registerMint
        vm.prank(deployer);
        vm.expectRevert("Only BubbleNFT");
        controller.registerMint(1);

        // Player cannot call registerMint
        vm.prank(player1);
        vm.expectRevert("Only BubbleNFT");
        controller.registerMint(1);

        // Controller itself cannot call registerMint
        vm.prank(address(controller));
        vm.expectRevert("Only BubbleNFT");
        controller.registerMint(1);

        // Farm cannot call registerMint
        vm.prank(address(farm));
        vm.expectRevert("Only BubbleNFT");
        controller.registerMint(1);

        // Only the NFT contract can (verified implicitly by test_mintAutoRegistersFarm)
    }

    // =======================================================================
    //  TEST 10: Batch Claim via claimMultiple
    // =======================================================================

    /// @notice Player mints 3 NFTs from different companies and claims
    ///   all yield at once via claimMultiple.
    function test_batchClaim() public {
        // Mint 3 NFTs from different USA companies (player1 is USA-locked)
        uint256 token0 = _mintNFT(player1, 0); // USA - SkynetAI
        uint256 token1 = _mintNFT(player1, 3); // USA - Neural Bro Labs
        uint256 token2 = _mintNFT(player1, 4); // USA - Rug Intelligence (was company 7)

        // Verify all three are registered (auto-registration via NFT -> Controller -> Farm)
        assertGt(farm.lastClaimTime(token0), 0, "Token0 not registered");
        assertGt(farm.lastClaimTime(token1), 0, "Token1 not registered");
        assertGt(farm.lastClaimTime(token2), 0, "Token2 not registered");

        // Advance 3 days
        _advanceTime(3 * ONE_DAY);

        // Check individual pending yields (all at tier 0 = 10,000/day)
        uint256 p0 = farm.pendingYield(token0);
        uint256 p1 = farm.pendingYield(token1);
        uint256 p2 = farm.pendingYield(token2);

        assertApproxEqRel(p0, 30_000e18, 0.01e18, "Token0: 3 days at 10k/day");
        assertApproxEqRel(p1, 30_000e18, 0.01e18, "Token1: 3 days at 10k/day");
        assertApproxEqRel(p2, 30_000e18, 0.01e18, "Token2: 3 days at 10k/day");

        // Batch claim all three at once
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = token0;
        tokenIds[1] = token1;
        tokenIds[2] = token2;

        uint256 balBefore = token.balanceOf(player1);
        assertEq(balBefore, 0, "Should start with 0 BUBBLE");

        vm.prank(player1);
        farm.claimMultiple(tokenIds);

        // Total yield: 3 NFTs * 3 days * 10,000/day = 90,000 BUBBLE
        uint256 balAfter = token.balanceOf(player1);
        assertApproxEqRel(
            balAfter,
            90_000e18,
            0.01e18,
            "Batch claim should yield ~90,000 BUBBLE"
        );

        // Verify all lastClaimTimes were updated
        assertEq(farm.lastClaimTime(token0), block.timestamp, "Token0 claim time not updated");
        assertEq(farm.lastClaimTime(token1), block.timestamp, "Token1 claim time not updated");
        assertEq(farm.lastClaimTime(token2), block.timestamp, "Token2 claim time not updated");

        // No pending yield remaining
        assertEq(farm.pendingYield(token0), 0, "Token0 should have 0 pending");
        assertEq(farm.pendingYield(token1), 0, "Token1 should have 0 pending");
        assertEq(farm.pendingYield(token2), 0, "Token2 should have 0 pending");
    }

    // =======================================================================
    //  BONUS: Additional Edge Case Tests
    // =======================================================================

    /// @notice Verify token ID encoding: companyId * 10000 + localIndex
    function test_tokenIdEncoding() public {
        // First mint of company 0: tokenId = 0 * 10000 + 1 = 1
        uint256 t0 = _mintNFT(player1, 0);
        assertEq(t0, 1, "Company 0, first mint = tokenId 1");

        // Second mint of company 0: tokenId = 0 * 10000 + 2 = 2
        // player3 mints USA company 0 (separate player, gets locked to USA)
        uint256 t1 = _mintNFT(player3, 0);
        assertEq(t1, 2, "Company 0, second mint = tokenId 2");

        // First mint of company 5: tokenId = 5 * 10000 + 1 = 50001
        // player2 mints China (gets locked to China)
        uint256 t2 = _mintNFT(player2, 5);
        assertEq(t2, 50001, "Company 5, first mint = tokenId 50001");

        // First mint of company 9: tokenId = 9 * 10000 + 1 = 90001
        // player2 stays China
        uint256 t3 = _mintNFT(player2, 9);
        assertEq(t3, 90001, "Company 9, first mint = tokenId 90001");

        // Decode back to company
        assertEq(nft.getCompanyIdFromToken(t0), 0, "tokenId 1 -> company 0");
        assertEq(nft.getCompanyIdFromToken(t2), 5, "tokenId 50001 -> company 5");
        assertEq(nft.getCompanyIdFromToken(t3), 9, "tokenId 90001 -> company 9");
    }

    /// @notice Verify bonding curve: price increases with each mint.
    ///   After a mint, lastMintTimestamp resets so getMintPrice == getBondingPrice.
    function test_bondingCurve() public {
        uint256 price0 = nft.getMintPrice(0);
        assertEq(price0, 0.01 ether, "First mint should be BASE_PRICE");

        // Mint one (resets lastMintTimestamp)
        _mintNFT(player1, 0);

        // Right after mint, effective price == bonding price (no decay)
        uint256 price1 = nft.getMintPrice(0);
        uint256 bonding1 = nft.getBondingPrice(0);
        assertEq(price1, bonding1, "Price should equal bonding price right after mint");
        assertEq(price1, 0.01 ether + 25336700000000, "Second mint bonding price should increase by PRICE_INCREMENT");
        assertGt(price1, price0, "Price should increase after mint");
    }

    /// @notice End-to-end test for dynamic pricing with time decay:
    ///   1. Verify prices start at bonding curve
    ///   2. Time passes -> prices decay toward MIN_PRICE
    ///   3. Mint resets decay for that company only
    ///   4. Other companies continue decaying independently
    ///   5. Verify faction balancing (idle faction is cheaper)
    function test_dynamicPricingEndToEnd() public {
        // --- Step 1: All companies start at bonding curve ---
        for (uint256 i = 0; i < 10; i++) {
            assertEq(
                nft.getMintPrice(i),
                nft.getBondingPrice(i),
                "Should start at bonding price"
            );
        }

        // --- Step 2: Advance 30 minutes, prices should decay ---
        _advanceTime(30 minutes);

        uint256 decayedPrice0 = nft.getMintPrice(0);
        uint256 bondingPrice0 = nft.getBondingPrice(0);
        assertLt(decayedPrice0, bondingPrice0, "Price should be below bonding after 30min");

        // --- Step 3: Mint company 0 (USA), resets its decay ---
        vm.prank(player1);
        nft.mint{value: decayedPrice0}(0, decayedPrice0);

        uint256 priceAfterMint0 = nft.getMintPrice(0);
        uint256 bondingAfterMint0 = nft.getBondingPrice(0);
        assertEq(priceAfterMint0, bondingAfterMint0, "Company 0 should reset to bonding after mint");

        // --- Step 4: Company 5 (China) continues decaying ---
        uint256 decayedPrice5 = nft.getMintPrice(5);
        uint256 bondingPrice5 = nft.getBondingPrice(5);
        assertLt(decayedPrice5, bondingPrice5, "Company 5 should still be decayed");

        // --- Step 5: Faction balancing ---
        // Company 0 (USA) has higher supply and was just minted (no decay)
        // Company 5 (China) has 0 supply and has been decaying for 30min
        assertGt(priceAfterMint0, decayedPrice5, "Active USA company should cost more than idle China");

        // --- Advance a lot of time, verify floor ---
        _advanceTime(48 hours);
        for (uint256 i = 0; i < 10; i++) {
            assertEq(
                nft.getMintPrice(i),
                nft.MIN_PRICE(),
                "All companies should be at MIN_PRICE after long idle"
            );
        }

        // --- Mint at floor price ---
        uint256 minPrice = nft.MIN_PRICE();
        vm.prank(player2);
        nft.mint{value: minPrice}(5, minPrice);

        // Company 5 should jump back to bonding curve
        uint256 price5After = nft.getMintPrice(5);
        assertEq(price5After, nft.getBondingPrice(5), "Should reset to bonding after mint at floor");
        assertGt(price5After, minPrice, "Bonding price should be above MIN_PRICE");
    }

    /// @notice Verify excess payment is refunded on mint.
    function test_mintRefundsExcess() public {
        uint256 price = nft.getMintPrice(0);
        uint256 overpay = 1 ether; // Way more than needed

        uint256 balBefore = player1.balance;

        vm.prank(player1);
        nft.mint{value: overpay}(0, overpay);

        uint256 balAfter = player1.balance;
        // Player should only have paid the exact mint price
        assertEq(balBefore - balAfter, price, "Only exact price should be deducted");
    }

    /// @notice Verify the operator can mint tokens for LP seeding.
    function test_operatorMintTokens() public {
        uint256 amount = 1_000_000e18;

        vm.prank(deployer);
        controller.mintTokens(deployer, amount);

        assertEq(token.balanceOf(deployer), amount, "Operator should receive minted tokens");
    }

    /// @notice Verify that endGame stops farming.
    function test_endGameStopsFarming() public {
        uint256 tokenId = _mintNFT(player1, 0);

        _advanceTime(ONE_DAY);

        // Claim 1 day of yield
        vm.prank(player1);
        farm.claim(tokenId);
        uint256 balDay1 = token.balanceOf(player1);
        assertApproxEqRel(balDay1, BASE_YIELD_PER_DAY, 0.01e18);

        // End the game
        vm.prank(deployer);
        controller.endGame();
        assertTrue(controller.gameEnded(), "Game should be ended");
        assertFalse(farm.farmingActive(), "Farming should be inactive");

        // Advance time — no more yield
        _advanceTime(ONE_DAY);
        assertEq(farm.pendingYield(tokenId), 0, "No yield after game ended");
    }
}
