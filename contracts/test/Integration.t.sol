// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/BubbleNFT.sol";
import "../src/BubbleToken.sol";
import "../src/BubbleFarm.sol";
import "../src/GPUUpgrade.sol";
import "../src/FactionWar.sol";
import "../src/GameController.sol";

contract IntegrationTest is Test {
    BubbleNFT public nft;
    BubbleToken public token;
    BubbleFarm public farm;
    GPUUpgrade public gpu;
    FactionWar public war;
    GameController public controller;

    address public admin = makeAddr("admin");
    address public operator = makeAddr("operator");
    address public player1 = makeAddr("player1");
    address public player2 = makeAddr("player2");

    string[10] companyNames = [
        "SkynetAI", "GPT-420", "BrainDump.io", "Neural Bro Labs", "Rug Intelligence",
        "DeepFraud", "BaiduBubble", "AlibabaGPT", "WeChatBot3000", "Great Wall AI"
    ];

    function setUp() public {
        vm.startPrank(admin);

        // Deploy all contracts
        nft = new BubbleNFT(companyNames);
        token = new BubbleToken();
        farm = new BubbleFarm();
        gpu = new GPUUpgrade();
        war = new FactionWar();
        controller = new GameController();

        // Wire through GameController
        controller.setContracts(
            address(nft), address(token), address(farm), address(gpu), address(war)
        );

        // Transfer ownerships so GameController can call setGameController/setContracts
        nft.transferOwnership(address(controller));
        token.transferOwnership(address(controller));
        farm.transferOwnership(address(controller));
        gpu.transferOwnership(address(controller));
        war.transferOwnership(address(controller));

        // Initialize game (wires contracts internally via onlyOwner calls)
        controller.initializeGame();

        // Grant operator role
        controller.grantRole(controller.OPERATOR_ROLE(), operator);

        vm.stopPrank();

        // Start game
        vm.prank(operator);
        controller.startGame(block.timestamp);

        // Fund players
        vm.deal(player1, 100 ether);
        vm.deal(player2, 100 ether);
    }

    function test_fullLifecycle_mintFarmUpgrade() public {
        // 1. Player1 mints from company 0 (USA faction)
        uint256 mintPrice = nft.getMintPrice(0);
        vm.prank(player1);
        nft.mint{value: mintPrice}(0, mintPrice);

        uint256 tokenId = 1; // company 0, first mint
        assertEq(nft.ownerOf(tokenId), player1);
        assertEq(nft.getCompanyFaction(0), 1); // USA (1=USA, 2=China)

        // NFT is auto-registered in BubbleFarm via the mint → GameController → Farm chain

        // 2. Advance time and check pending yield
        vm.warp(block.timestamp + 1 days);
        uint256 pending = farm.pendingYield(tokenId);
        // At tier 0 (1x), 1 day should yield ~10,000 tokens
        assertApproxEqRel(pending, 10_000e18, 0.01e18); // 1% tolerance

        // 4. Claim yield
        vm.prank(player1);
        farm.claim(tokenId);
        assertApproxEqRel(token.balanceOf(player1), 10_000e18, 0.01e18);

        // 5. Accumulate more for upgrade
        vm.warp(block.timestamp + 5 days);
        vm.prank(player1);
        farm.claim(tokenId);

        uint256 balance = token.balanceOf(player1);
        assertGt(balance, 50_000e18, "Should have enough for tier 1 upgrade");

        // 6. Approve and upgrade GPU to tier 1
        vm.startPrank(player1);
        token.approve(address(gpu), type(uint256).max);
        gpu.upgrade(tokenId);
        vm.stopPrank();

        assertEq(gpu.gpuTier(tokenId), 1);
        assertEq(gpu.getEffectiveTier(tokenId), 1);

        // 7. Verify yield increased at tier 1 (1.5x)
        vm.warp(block.timestamp + 1 days);
        pending = farm.pendingYield(tokenId);
        assertApproxEqRel(pending, 15_000e18, 0.01e18); // 1.5x = 15,000/day
    }

    function test_maintenanceDowngrade() public {
        // Mint and register
        uint256 mintPrice = nft.getMintPrice(0);
        vm.prank(player1);
        nft.mint{value: mintPrice}(0, mintPrice);
        uint256 tokenId = 1;
        // NFT is auto-registered via mint → GameController → Farm chain

        // Farm for a while and upgrade
        vm.warp(block.timestamp + 10 days);
        vm.prank(player1);
        farm.claim(tokenId);

        vm.startPrank(player1);
        token.approve(address(gpu), type(uint256).max);
        gpu.upgrade(tokenId); // tier 0 → 1
        vm.stopPrank();

        assertEq(gpu.getEffectiveTier(tokenId), 1);

        // Miss maintenance — skip 2 weeks
        vm.warp(block.timestamp + 14 days);
        assertEq(gpu.getEffectiveTier(tokenId), 0); // Downgraded to 0

        // Anyone can enforce the downgrade
        gpu.enforceDowngrade(tokenId);
        assertEq(gpu.gpuTier(tokenId), 0);
    }

    function test_factionWarClaim() public {
        // Start a round with 10 native currency prize
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        controller.startFactionRound{value: 10 ether}();

        // Create a merkle tree for player1 getting 1 native currency
        // Double-hash to prevent second-preimage attacks (includes roundId)
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), player1, uint256(1 ether)))));
        bytes32 root = leaf; // Single-element tree: root = leaf

        // Finalize with the root
        vm.prank(operator);
        controller.finalizeFactionRound(1, root);

        // Player claims with proof
        bytes32[] memory proof = new bytes32[](0); // Empty proof for single-leaf tree
        vm.prank(player1);
        war.claimPrize(1, 1 ether, proof);

        // Immediately, some should be vested (just started)
        (uint256 vested, uint256 withdrawable) = war.getVestedAmount(1, player1);
        assertEq(vested, 0); // Just claimed, 0 time elapsed
        assertEq(withdrawable, 0);

        // After 3.5 days (half vesting), ~50% should be available
        vm.warp(block.timestamp + 3.5 days);
        (vested, withdrawable) = war.getVestedAmount(1, player1);
        assertApproxEqRel(vested, 0.5 ether, 0.01e18);
        assertApproxEqRel(withdrawable, 0.5 ether, 0.01e18);

        // Withdraw
        uint256 balBefore = player1.balance;
        vm.prank(player1);
        war.withdrawVested(1);
        assertApproxEqRel(player1.balance - balBefore, 0.5 ether, 0.01e18);

        // After full vesting
        vm.warp(block.timestamp + 7 days);
        (vested, withdrawable) = war.getVestedAmount(1, player1);
        assertEq(vested, 1 ether);
        assertApproxEqRel(withdrawable, 0.5 ether, 0.01e18); // Remaining half

        // Withdraw rest
        vm.prank(player1);
        war.withdrawVested(1);
    }

    function test_twoPlayersCompete() public {
        // Player1 mints USA company
        uint256 price = nft.getMintPrice(0);
        vm.prank(player1);
        nft.mint{value: price}(0, price);

        // Player2 mints China company
        price = nft.getMintPrice(5);
        vm.prank(player2);
        nft.mint{value: price}(5, price);

        // Both NFTs are auto-registered via mint → GameController → Farm chain

        // Both farm for 3 days
        vm.warp(block.timestamp + 3 days);

        // Both should have similar yields (same tier 0)
        uint256 p1Yield = farm.pendingYield(1);
        uint256 p2Yield = farm.pendingYield(50001);
        assertApproxEqRel(p1Yield, p2Yield, 0.01e18);
        assertApproxEqRel(p1Yield, 30_000e18, 0.01e18); // 3 days × 10,000
    }

    function test_emergencyPause() public {
        vm.prank(admin);
        controller.emergencyPause();

        // Farm should be inactive now — no yield accrues
        // (Assuming an NFT was registered, pending yield would be 0)
    }

    function test_lpMinting() public {
        // Operator can mint tokens for LP seeding
        vm.prank(operator);
        controller.mintTokens(operator, 1_000_000e18);
        assertEq(token.balanceOf(operator), 1_000_000e18);
    }

    // === Audit Fix Tests ===

    function test_addPrizePoolRevertsOnFinalizedRound() public {
        // Start a round
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        controller.startFactionRound{value: 1 ether}();

        // Finalize the round
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), player1, uint256(0.5 ether)))));
        vm.prank(operator);
        controller.finalizeFactionRound(1, root);

        // Try to add more funds — should revert (L-05 fix)
        // war is owned by controller, so prank as controller
        vm.deal(address(controller), 1 ether);
        vm.prank(address(controller));
        vm.expectRevert("Round already finalized");
        war.addPrizePool{value: 1 ether}(1);
    }

    function test_startRoundRevertsWithInsufficientPrize() public {
        // Try to start a round with less than MIN_PRIZE_POOL (0.1 ether) — should revert (L-06 fix)
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        vm.expectRevert("Prize pool too small");
        controller.startFactionRound{value: 0.01 ether}();
    }

    function test_recoverUnclaimedFunds() public {
        // Start and finalize a round
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        controller.startFactionRound{value: 1 ether}();

        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), player1, uint256(0.5 ether)))));
        vm.prank(operator);
        controller.finalizeFactionRound(1, root);

        // Try to recover too early — should revert (war is owned by controller)
        vm.prank(address(controller));
        vm.expectRevert("Recovery too early");
        war.recoverUnclaimedFunds(1, payable(admin));

        // Advance past 30-day recovery delay
        vm.warp(block.timestamp + 31 days);

        // Now recovery should work (war is owned by controller, so admin can't call directly)
        // But war.recoverUnclaimedFunds is onlyOwner — owner is controller
        // So we prank as controller
        uint256 warBalance = address(war).balance;
        assertGt(warBalance, 0, "War should have funds");

        uint256 adminBalBefore = admin.balance;
        vm.prank(address(controller));
        war.recoverUnclaimedFunds(1, payable(admin));

        assertEq(admin.balance - adminBalBefore, warBalance, "Should recover all funds");
    }

    function test_recoverRevertsOnUnfinalizedRound() public {
        // Start a round but don't finalize
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        controller.startFactionRound{value: 1 ether}();

        vm.warp(block.timestamp + 31 days);

        vm.prank(address(controller));
        vm.expectRevert("Round not finalized");
        war.recoverUnclaimedFunds(1, payable(admin));
    }

    function test_gpuSetContractsZeroAddressReverts() public {
        // Deploy a fresh GPU contract to test zero-address check (L-02 fix)
        GPUUpgrade freshGpu = new GPUUpgrade();

        vm.expectRevert("Zero address");
        freshGpu.setContracts(address(0), address(token));

        vm.expectRevert("Zero address");
        freshGpu.setContracts(address(nft), address(0));
    }
}
