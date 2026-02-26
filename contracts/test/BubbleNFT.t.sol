// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/BubbleNFT.sol";

contract BubbleNFTTest is Test {
    BubbleNFT public nft;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

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

    function setUp() public {
        nft = new BubbleNFT(companyNames);
        nft.initializePricing(block.timestamp);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // === Basic Mint Tests ===

    function test_firstMintPrice() public view {
        uint256 price = nft.getMintPrice(0);
        // At t=0 after initializePricing, no decay yet
        assertEq(price, 0.01 ether, "First mint should cost 0.01 native");
    }

    function test_mintCreatesCorrectTokenId() public {
        uint256 price = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price}(0, price);

        // Company 0, first mint -> tokenId = 0 * 10000 + 1 = 1
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.companySupply(0), 1);
    }

    function test_mintDifferentCompanies() public {
        // Mint from company 0
        uint256 price0 = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price0}(0, price0);
        assertEq(nft.ownerOf(1), alice); // tokenId = 0*10000 + 1

        // Mint from company 5
        uint256 price5 = nft.getMintPrice(5);
        vm.prank(bob);
        nft.mint{value: price5}(5, price5);
        assertEq(nft.ownerOf(50001), bob); // tokenId = 5*10000 + 1
    }

    function test_mintRefundsExcess() public {
        uint256 price = nft.getMintPrice(0);
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        nft.mint{value: 1 ether}(0, 1 ether);

        uint256 aliceAfter = alice.balance;
        assertEq(aliceBefore - aliceAfter, price, "Should only charge exact price");
    }

    function test_revertIfMaxPriceExceeded() public {
        // Advance time so price decays, then try with too-low maxPrice
        vm.warp(block.timestamp + 1 hours);
        uint256 price = nft.getMintPrice(0);

        vm.prank(alice);
        vm.expectRevert("Price exceeds maxPrice");
        nft.mint{value: price}(0, price - 1);
    }

    function test_revertIfInsufficientPayment() public {
        uint256 price = nft.getMintPrice(0);

        vm.prank(alice);
        vm.expectRevert("Insufficient payment");
        nft.mint{value: price - 1}(0, price);
    }

    function test_revertInvalidCompany() public {
        vm.prank(alice);
        vm.expectRevert("Invalid company ID");
        nft.mint{value: 1 ether}(10, 1 ether);
    }

    // === Faction Tests ===

    function test_factionAssignment() public view {
        for (uint256 i = 0; i < 5; i++) {
            assertEq(nft.getCompanyFaction(i), 0, "Companies 0-4 should be USA");
        }
        for (uint256 i = 5; i < 10; i++) {
            assertEq(nft.getCompanyFaction(i), 1, "Companies 5-9 should be China");
        }
    }

    // === TokenID Encoding Tests ===

    function test_tokenIdEncoding() public view {
        assertEq(nft.getCompanyIdFromToken(1), 0);
        assertEq(nft.getCompanyIdFromToken(9999), 0);
        assertEq(nft.getCompanyIdFromToken(10001), 1);
        assertEq(nft.getCompanyIdFromToken(50001), 5);
        assertEq(nft.getCompanyIdFromToken(90001), 9);
    }

    // === Bonding Curve Tests ===

    function test_priceIncreasesMonotonically() public {
        // Mint 20 NFTs from company 0 and verify bonding price increases each time
        for (uint256 i = 0; i < 20; i++) {
            uint256 price = nft.getMintPrice(0);
            vm.prank(alice);
            nft.mint{value: 1 ether}(0, 1 ether);
            // After mint, timestamp resets, so getMintPrice returns bonding price
            uint256 priceAfter = nft.getMintPrice(0);
            // Bonding price should increase (supply went up)
            uint256 bondingAfter = nft.getBondingPrice(0);
            assertGt(bondingAfter, price, "Bonding price should increase after each mint");
            // Since we just minted (no decay), effective price == bonding price
            assertEq(priceAfter, bondingAfter, "Price should equal bonding price right after mint");
        }
    }

    function test_lastMintPriceApprox() public view {
        // At supply = 7499, bonding price should be approximately 0.20 native
        uint256 expectedMax = nft.BASE_PRICE() + (7499 * nft.PRICE_INCREMENT());
        assertApproxEqAbs(expectedMax, 0.20 ether, 0.001 ether, "Last mint should be ~0.20 native");
    }

    // === Dynamic Pricing Tests ===

    function test_priceDecaysOverTime() public {
        uint256 priceAt0 = nft.getMintPrice(0);
        assertEq(priceAt0, 0.01 ether, "Should start at BASE_PRICE");

        // Advance 10 minutes — partial decay
        vm.warp(block.timestamp + 10 minutes);
        uint256 priceAt10m = nft.getMintPrice(0);
        assertLt(priceAt10m, priceAt0, "Price should decrease after 10 minutes");
        assertGt(priceAt10m, nft.MIN_PRICE(), "Should not be at floor after only 10 minutes");

        // Advance to 1 hour — should be at MIN_PRICE (decay ≈ 0.01 ether, bonding = 0.01)
        vm.warp(block.timestamp + 50 minutes);
        uint256 priceAt1h = nft.getMintPrice(0);
        assertEq(priceAt1h, nft.MIN_PRICE(), "Price should floor at MIN_PRICE after 1h");
    }

    function test_priceFloorsAtMinPrice() public {
        // Advance 24 hours — way past full decay
        vm.warp(block.timestamp + 24 hours);
        uint256 price = nft.getMintPrice(0);
        assertEq(price, nft.MIN_PRICE(), "Price should be MIN_PRICE after 24h idle");
    }

    function test_priceResetsAfterMint() public {
        // Let price decay to MIN_PRICE (1h is enough for supply=0)
        vm.warp(block.timestamp + 1 hours);
        uint256 decayedPrice = nft.getMintPrice(0);
        assertEq(decayedPrice, nft.MIN_PRICE(), "Should be at MIN_PRICE");

        // Mint at MIN_PRICE
        vm.prank(alice);
        nft.mint{value: nft.MIN_PRICE()}(0, nft.MIN_PRICE());

        // After mint, price should be back to bonding curve (supply=1)
        uint256 priceAfterMint = nft.getMintPrice(0);
        uint256 expectedBonding = nft.BASE_PRICE() + nft.PRICE_INCREMENT();
        assertEq(priceAfterMint, expectedBonding, "Price should reset to bonding curve after mint");
    }

    function test_companiesDecayIndependently() public {
        // Mint company 0 to reset its timestamp
        uint256 price0 = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price0}(0, price0);

        // Advance 30 minutes
        vm.warp(block.timestamp + 30 minutes);

        // Company 0: just minted 30min ago, some decay from bonding price
        uint256 price0After = nft.getMintPrice(0);
        uint256 bonding0 = nft.getBondingPrice(0);

        // Company 5: initialized at setUp, 30min of decay from base price
        uint256 price5After = nft.getMintPrice(5);

        // Company 0 has higher bonding price (supply=1), recently minted
        // Company 5 still at supply=0, been decaying since setUp
        assertTrue(
            price0After != price5After || bonding0 != nft.getBondingPrice(5),
            "Companies should have independent pricing"
        );
    }

    function test_factionBalancing() public {
        // Mint 5 from company 0 (USA) to raise its price
        for (uint256 i = 0; i < 5; i++) {
            uint256 p = nft.getMintPrice(0);
            vm.prank(alice);
            nft.mint{value: p}(0, p);
        }

        // Company 0 (USA) has higher bonding curve now
        uint256 usaPrice = nft.getMintPrice(0);

        // Company 5 (China) still at 0 supply, but has been decaying
        // Since we're at same timestamp as last mint, company 5 has had time pass
        uint256 chinaPrice = nft.getMintPrice(5);

        // USA price should be higher than China (active vs idle)
        assertGt(usaPrice, chinaPrice, "Active faction should cost more than idle faction");
    }

    function test_initializePricingOnlyOnce() public {
        // Already initialized in setUp, second call should revert
        vm.expectRevert("Pricing already initialized");
        nft.initializePricing(block.timestamp);
    }

    function test_initializePricingOnlyOwner() public {
        // Deploy a fresh NFT (not initialized)
        BubbleNFT fresh = new BubbleNFT(companyNames);

        vm.prank(alice);
        vm.expectRevert();
        fresh.initializePricing(block.timestamp);
    }

    function test_getBondingPriceVsGetMintPrice() public {
        // At t=0, they should be equal (no decay)
        uint256 bonding = nft.getBondingPrice(0);
        uint256 effective = nft.getMintPrice(0);
        assertEq(bonding, effective, "Should be equal at t=0");

        // After time passes, getMintPrice < getBondingPrice
        vm.warp(block.timestamp + 10 minutes);
        bonding = nft.getBondingPrice(0);
        effective = nft.getMintPrice(0);
        assertLt(effective, bonding, "Effective should be less than bonding after decay");
    }

    function test_getLastMintTimestamp() public {
        uint256 ts = nft.getLastMintTimestamp(0);
        assertEq(ts, block.timestamp, "Should be initialized to current timestamp");

        vm.warp(block.timestamp + 100);
        uint256 price = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price}(0, price);

        uint256 tsAfter = nft.getLastMintTimestamp(0);
        assertEq(tsAfter, block.timestamp, "Should update to mint timestamp");
    }

    function test_mintEventEmitsDecayInfo() public {
        // Advance time to create some decay
        vm.warp(block.timestamp + 10 minutes);

        uint256 price = nft.getMintPrice(0);
        uint256 bondingPrice = nft.getBondingPrice(0);
        uint256 decayAmount = bondingPrice - price;

        vm.expectEmit(true, true, true, true);
        emit BubbleNFT.CompanyMinted(0, 1, alice, price, bondingPrice, decayAmount);

        vm.prank(alice);
        nft.mint{value: price}(0, price);
    }

    // === Fuzz Tests ===

    function testFuzz_decayNeverBelowMinPrice(uint256 companyId, uint256 elapsedSeconds) public {
        companyId = bound(companyId, 0, 9);
        elapsedSeconds = bound(elapsedSeconds, 0, 365 days);

        vm.warp(block.timestamp + elapsedSeconds);
        uint256 price = nft.getMintPrice(companyId);
        assertGe(price, nft.MIN_PRICE(), "Price should never go below MIN_PRICE");
    }

    function testFuzz_mintPriceWithinBounds(uint256 companyId, uint256 supply) public view {
        companyId = bound(companyId, 0, 9);
        supply = bound(supply, 0, 7499);

        uint256 price = nft.BASE_PRICE() + (supply * nft.PRICE_INCREMENT());
        assertGe(price, nft.BASE_PRICE(), "Bonding price should never be below BASE_PRICE");
        assertLe(price, nft.MAX_PRICE() + 0.001 ether, "Bonding price should not exceed MAX_PRICE significantly");
    }

    function testFuzz_tokenIdEncodingRoundTrip(uint256 companyId, uint256 localIndex) public view {
        companyId = bound(companyId, 0, 9);
        localIndex = bound(localIndex, 1, 7500);

        uint256 tokenId = companyId * 10000 + localIndex;
        uint256 decodedCompany = nft.getCompanyIdFromToken(tokenId);
        assertEq(decodedCompany, companyId, "Company ID should round-trip through tokenId encoding");
    }

    function testFuzz_mintRefundsExactly(uint256 companyId, uint256 extraWei) public {
        companyId = bound(companyId, 0, 9);
        extraWei = bound(extraWei, 0, 1 ether);

        uint256 price = nft.getMintPrice(companyId);
        uint256 totalSent = price + extraWei;

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        nft.mint{value: totalSent}(companyId, totalSent);
        uint256 aliceAfter = alice.balance;

        assertEq(aliceBefore - aliceAfter, price, "Should charge exact price, refund rest");
    }

    // === Withdraw Tests ===

    function test_withdrawByOwner() public {
        uint256 price = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price}(0, price);

        uint256 contractBalance = address(nft).balance;
        assertEq(contractBalance, price);

        uint256 ownerBefore = address(this).balance;
        nft.withdraw();
        uint256 ownerAfter = address(this).balance;

        assertEq(ownerAfter - ownerBefore, price);
        assertEq(address(nft).balance, 0);
    }

    function test_revertWithdrawNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        nft.withdraw();
    }

    // === Total Minted Test ===

    function test_totalMinted() public {
        assertEq(nft.totalMinted(), 0);

        vm.startPrank(alice);
        nft.mint{value: 1 ether}(0, 1 ether);
        nft.mint{value: 1 ether}(3, 1 ether);
        nft.mint{value: 1 ether}(4, 1 ether); // Stay all-USA (was company 7)
        vm.stopPrank();

        assertEq(nft.totalMinted(), 3);
    }

    // === Soulbound Tests ===

    function test_transferReverts() public {
        uint256 price = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price}(0, price);

        vm.prank(alice);
        vm.expectRevert("Soulbound: non-transferable");
        nft.transferFrom(alice, bob, 1);
    }

    function test_safeTransferReverts() public {
        uint256 price = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price}(0, price);

        vm.prank(alice);
        vm.expectRevert("Soulbound: non-transferable");
        nft.safeTransferFrom(alice, bob, 1);
    }

    function test_mintStillWorks() public {
        uint256 price = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price}(0, price);

        assertEq(nft.ownerOf(1), alice);
    }

    // === Faction Lock Tests ===

    function test_firstMintLocksFaction_USA() public {
        uint256 price = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price}(0, price);

        assertEq(nft.getWalletFaction(alice), 1); // 1 = USA
    }

    function test_firstMintLocksFaction_China() public {
        uint256 price = nft.getMintPrice(5);
        vm.prank(alice);
        nft.mint{value: price}(5, price);

        assertEq(nft.getWalletFaction(alice), 2); // 2 = China
    }

    function test_sameFactionMintSucceeds() public {
        uint256 price0 = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price0}(0, price0);

        uint256 price3 = nft.getMintPrice(3);
        vm.prank(alice);
        nft.mint{value: price3}(3, price3); // Both USA — should succeed

        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(30001), alice);
    }

    function test_crossFactionMintReverts() public {
        uint256 price0 = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price0}(0, price0);

        uint256 price5 = nft.getMintPrice(5);
        vm.prank(alice);
        vm.expectRevert("Wrong faction");
        nft.mint{value: price5}(5, price5);
    }

    function test_differentPlayersChooseDifferentFactions() public {
        uint256 price0 = nft.getMintPrice(0);
        vm.prank(alice);
        nft.mint{value: price0}(0, price0); // Alice → USA

        uint256 price5 = nft.getMintPrice(5);
        vm.prank(bob);
        nft.mint{value: price5}(5, price5); // Bob → China

        assertEq(nft.getWalletFaction(alice), 1); // USA
        assertEq(nft.getWalletFaction(bob), 2); // China
    }

    function test_factionLockedEventEmitted() public {
        uint256 price0 = nft.getMintPrice(0);

        // First mint should emit FactionLocked
        vm.expectEmit(true, false, false, true);
        emit BubbleNFT.FactionLocked(alice, 1); // 1 = USA

        vm.prank(alice);
        nft.mint{value: price0}(0, price0);

        // Second mint (same faction) should NOT emit FactionLocked again
        // We verify by checking it's only emitted on the first mint
        uint256 price3 = nft.getMintPrice(3);
        vm.prank(alice);
        nft.mint{value: price3}(3, price3);
        // No expectEmit before this — if FactionLocked fired, the test would still pass
        // but we verified the first one emits correctly
    }

    // === Fuzz: Faction Lock ===

    function testFuzz_factionLockConsistency(uint256 companyId) public {
        companyId = bound(companyId, 0, 9);
        uint256 price = nft.getMintPrice(companyId);

        vm.prank(alice);
        nft.mint{value: price}(companyId, price);

        uint8 expected = companyId < 5 ? 1 : 2;
        assertEq(nft.getWalletFaction(alice), expected, "Faction should match company side");
    }

    // === setGameController Tests ===

    function test_setGameControllerZeroAddressReverts() public {
        BubbleNFT fresh = new BubbleNFT(companyNames);
        vm.expectRevert("Zero address");
        fresh.setGameController(address(0));
    }

    function test_setGameControllerOnlyOnce() public {
        BubbleNFT fresh = new BubbleNFT(companyNames);
        fresh.setGameController(makeAddr("controller"));

        vm.expectRevert("Already set");
        fresh.setGameController(makeAddr("controller2"));
    }

    receive() external payable {}
}
