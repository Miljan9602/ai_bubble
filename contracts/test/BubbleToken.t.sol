// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/BubbleToken.sol";

contract BubbleTokenTest is Test {
    BubbleToken public token;
    address public owner;
    address public gameController = makeAddr("gameController");
    address public dexPair = makeAddr("dexPair");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        owner = address(this);
        token = new BubbleToken();
        token.setGameController(gameController);
        token.setDexPair(dexPair);
    }

    // === Basic ERC20 Tests ===

    function test_nameAndSymbol() public view {
        assertEq(token.name(), "AI Bubble");
        assertEq(token.symbol(), "BUBBLE");
    }

    function test_mintByGameController() public {
        vm.prank(gameController);
        token.mint(alice, 1000e18);
        assertEq(token.balanceOf(alice), 1000e18);
    }

    function test_revertMintNotController() public {
        vm.prank(alice);
        vm.expectRevert(BubbleToken.NotAuthorized.selector);
        token.mint(alice, 1000e18);
    }

    // === Efficiency Credits Tests ===

    function test_creditsOnDexBuy() public {
        // Simulate a DEX buy: transfer from dexPair to alice (above min threshold)
        vm.prank(gameController);
        token.mint(dexPair, 10000e18);

        vm.prank(dexPair);
        token.transfer(alice, 1000e18);

        // Credits should be 1000e18 * 50 / 100 = 500e18
        assertEq(token.efficiencyCredits(alice), 500e18);
    }

    function test_noCreditsOnDustTransfer() public {
        // Transfers below MIN_CREDIT_TRANSFER (1000 BUBBLE) should NOT earn credits
        vm.prank(gameController);
        token.mint(dexPair, 10000e18);

        vm.prank(dexPair);
        token.transfer(alice, 999e18); // Below 1000 threshold

        assertEq(token.efficiencyCredits(alice), 0, "Dust transfer should not earn credits");
    }

    function test_creditsCappedAtMax() public {
        // Credits should be capped at MAX_CREDITS (5,000,000 BUBBLE)
        uint256 maxCredits = token.MAX_CREDITS();

        // Transfer a massive amount to exceed the cap
        // To get 5M credits at 50%, need 10M BUBBLE transfer
        uint256 bigAmount = 12_000_000e18; // Would give 6M credits without cap
        vm.prank(gameController);
        token.mint(dexPair, bigAmount);

        vm.prank(dexPair);
        token.transfer(alice, bigAmount);

        assertEq(token.efficiencyCredits(alice), maxCredits, "Credits should be capped at MAX_CREDITS");
    }

    function test_creditsCapEnforcedAcrossMultipleTransfers() public {
        uint256 maxCredits = token.MAX_CREDITS();

        // First transfer: get close to cap
        uint256 amount1 = 9_000_000e18; // 4.5M credits
        vm.prank(gameController);
        token.mint(dexPair, amount1);
        vm.prank(dexPair);
        token.transfer(alice, amount1);
        assertEq(token.efficiencyCredits(alice), 4_500_000e18);

        // Second transfer: would push over cap, should be clamped
        uint256 amount2 = 2_000_000e18; // Would add 1M credits
        vm.prank(gameController);
        token.mint(dexPair, amount2);
        vm.prank(dexPair);
        token.transfer(alice, amount2);

        assertEq(token.efficiencyCredits(alice), maxCredits, "Credits should cap at MAX_CREDITS");
    }

    function test_noCreditsOnRegularTransfer() public {
        vm.prank(gameController);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.transfer(bob, 500e18);

        assertEq(token.efficiencyCredits(bob), 0);
    }

    function test_creditsAccumulate() public {
        vm.prank(gameController);
        token.mint(dexPair, 10000e18);

        // First buy
        vm.prank(dexPair);
        token.transfer(alice, 1000e18);
        assertEq(token.efficiencyCredits(alice), 500e18);

        // Second buy
        vm.prank(dexPair);
        token.transfer(alice, 2000e18);
        assertEq(token.efficiencyCredits(alice), 1500e18); // 500 + 1000
    }

    // === getEffectiveBalance Tests ===

    function test_effectiveBalanceFullCredits() public {
        // Give alice 500e18 credits
        vm.prank(gameController);
        token.mint(dexPair, 10000e18);
        vm.prank(dexPair);
        token.transfer(alice, 1000e18);

        // 1000 amount needs 500 credits for full 1.5x
        // Alice has exactly 500 credits → full 1.5x
        uint256 effective = token.getEffectiveBalance(alice, 1000e18);
        assertEq(effective, 1500e18, "Should get 1.5x with full credits");
    }

    function test_effectiveBalancePartialCredits() public {
        vm.prank(gameController);
        token.mint(dexPair, 10000e18);
        vm.prank(dexPair);
        token.transfer(alice, 2000e18); // Above threshold: 1000e18 credits

        // 5000 amount needs 2500 credits for full, alice has 1000
        uint256 effective = token.getEffectiveBalance(alice, 5000e18);
        assertEq(effective, 6000e18, "Should get partial credit bonus");
    }

    function test_effectiveBalanceNoCredits() public view {
        uint256 effective = token.getEffectiveBalance(alice, 1000e18);
        assertEq(effective, 1000e18, "No credits = no bonus");
    }

    // === consumeCredits Tests ===

    function test_consumeCredits() public {
        vm.prank(gameController);
        token.mint(dexPair, 10000e18);
        vm.prank(dexPair);
        token.transfer(alice, 1000e18);

        assertEq(token.efficiencyCredits(alice), 500e18);

        vm.prank(gameController);
        token.consumeCredits(alice, 200e18);
        assertEq(token.efficiencyCredits(alice), 300e18);
    }

    function test_revertConsumeInsufficientCredits() public {
        vm.prank(gameController);
        vm.expectRevert(BubbleToken.InsufficientCredits.selector);
        token.consumeCredits(alice, 100e18);
    }

    // === Burn Tests ===

    function test_burnOwnTokens() public {
        vm.prank(gameController);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.burn(400e18);
        assertEq(token.balanceOf(alice), 600e18);
    }

    function test_burnFromWithAllowance() public {
        vm.prank(gameController);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.approve(gameController, 500e18);

        vm.prank(gameController);
        token.burnFrom(alice, 500e18);
        assertEq(token.balanceOf(alice), 500e18);
    }

    // === Fuzz Tests ===

    function testFuzz_creditsProportionalToBuy(uint256 amount) public {
        amount = bound(amount, 1000e18, 1_000_000_000e18); // Must be >= MIN_CREDIT_TRANSFER

        vm.prank(gameController);
        token.mint(dexPair, amount);

        vm.prank(dexPair);
        token.transfer(alice, amount);

        uint256 expectedCredits = (amount * 50) / 100;
        if (expectedCredits > token.MAX_CREDITS()) {
            expectedCredits = token.MAX_CREDITS();
        }
        assertEq(token.efficiencyCredits(alice), expectedCredits);
    }

    function testFuzz_effectiveBalanceNeverLessThanAmount(
        uint256 amount,
        uint256 credits
    ) public {
        amount = bound(amount, 1, 1_000_000_000e18);
        credits = bound(credits, 0, token.MAX_CREDITS());

        // Give alice some credits directly by simulating DEX buys
        // Buy amount must be >= MIN_CREDIT_TRANSFER to earn credits
        if (credits > 0) {
            uint256 buyAmount = (credits * 100) / 50; // reverse: credits = buy * 50/100
            if (buyAmount >= token.MIN_CREDIT_TRANSFER()) {
                vm.prank(gameController);
                token.mint(dexPair, buyAmount);
                vm.prank(dexPair);
                token.transfer(alice, buyAmount);
            }
        }

        uint256 effective = token.getEffectiveBalance(alice, amount);
        assertGe(effective, amount, "Effective balance should never be less than amount");
    }
}
