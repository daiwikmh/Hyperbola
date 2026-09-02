// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract QuoteRegistryTest is Test {
    QuoteRegistry registry;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        registry = new QuoteRegistry();
        poolId = PoolId.wrap(bytes32(uint256(1)));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function _stakeAndQuote(address who, uint256 price) internal {
        vm.startPrank(who);
        registry.stake{value: 1 ether}();
        registry.postQuote(poolId, price, block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function test_stake_increasesBalance() public {
        vm.prank(alice);
        registry.stake{value: 1 ether}();
        assertEq(registry.stakeOf(alice), 1 ether);
    }

    function test_postQuote_revertsBelowMinStake() public {
        vm.startPrank(alice);
        registry.stake{value: 0.05 ether}();
        vm.expectRevert(QuoteRegistry.InsufficientStake.selector);
        registry.postQuote(poolId, 100, block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function test_postQuote_revertsOnExpiryTooFar() public {
        vm.startPrank(alice);
        registry.stake{value: 1 ether}();
        vm.expectRevert(QuoteRegistry.InvalidExpiry.selector);
        registry.postQuote(poolId, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_singleQuoter_bestForXForY_secondPriceIsZero() public {
        _stakeAndQuote(alice, 4);

        (bool found, address winner, uint256 winnerPrice, address secondQuoter, uint256 secondPrice) =
            registry.bestForXForY(poolId);
        assertTrue(found);
        assertEq(winner, alice);
        assertEq(winnerPrice, 4);
        assertEq(secondQuoter, address(0));
        assertEq(secondPrice, 0);
    }

    function test_threeQuoters_bestForXForY_pickHighestAndSecondHighest() public {
        _stakeAndQuote(alice, 4);
        _stakeAndQuote(bob, 7);
        _stakeAndQuote(carol, 2);

        (bool found, address winner, uint256 winnerPrice, address secondQuoter, uint256 secondPrice) =
            registry.bestForXForY(poolId);
        assertTrue(found);
        assertEq(winner, bob);
        assertEq(winnerPrice, 7);
        assertEq(secondQuoter, alice);
        assertEq(secondPrice, 4);
    }

    function test_threeQuoters_bestForYForX_pickLowestAndSecondLowest() public {
        _stakeAndQuote(alice, 4);
        _stakeAndQuote(bob, 7);
        _stakeAndQuote(carol, 2);

        (bool found, address winner, uint256 winnerPrice, address secondQuoter, uint256 secondPrice) =
            registry.bestForYForX(poolId);
        assertTrue(found);
        assertEq(winner, carol);
        assertEq(winnerPrice, 2);
        assertEq(secondQuoter, alice);
        assertEq(secondPrice, 4);
    }

    function test_expiredQuote_isExcluded() public {
        _stakeAndQuote(alice, 4);
        _stakeAndQuote(bob, 7);

        vm.warp(block.timestamp + 2 minutes);

        (bool found, address winner, uint256 winnerPrice,, uint256 secondPrice) = registry.bestForXForY(poolId);
        assertFalse(found);
        assertEq(winner, address(0));
        assertEq(winnerPrice, 0);
        assertEq(secondPrice, 0);
    }

    function test_unstakeBelowMinInvalidatesQuote() public {
        _stakeAndQuote(alice, 4);
        _stakeAndQuote(bob, 7);

        vm.prank(bob);
        registry.unstake(0.95 ether);

        (bool found, address winner,,,) = registry.bestForXForY(poolId);
        assertTrue(found);
        assertEq(winner, alice);
    }

    function test_withdrawQuote_removesFromRanking() public {
        _stakeAndQuote(alice, 4);
        _stakeAndQuote(bob, 7);

        vm.prank(bob);
        registry.withdrawQuote(poolId);

        (bool found, address winner, uint256 winnerPrice,,) = registry.bestForXForY(poolId);
        assertTrue(found);
        assertEq(winner, alice);
        assertEq(winnerPrice, 4);

        address[] memory active = registry.activeQuoters(poolId);
        assertEq(active.length, 1);
        assertEq(active[0], alice);
    }

    function test_noQuoters_returnsNotFound() public view {
        (bool found,,,,) = registry.bestForXForY(poolId);
        assertFalse(found);
    }

    function testFuzz_bestForXForY_matchesBruteForce(uint256[5] memory rawPrices) public {
        address[5] memory arbs = [alice, bob, carol, makeAddr("dave"), makeAddr("eve")];
        uint256[5] memory prices;
        for (uint256 i = 0; i < 5; i++) {
            prices[i] = (rawPrices[i] % 999) + 1;
            vm.deal(arbs[i], 1 ether);
            _stakeAndQuote(arbs[i], prices[i]);
        }

        uint256 bestVal;
        uint256 bestIdx;
        uint256 secondVal;
        uint256 secondIdx;
        for (uint256 i = 0; i < 5; i++) {
            if (prices[i] > bestVal) {
                secondVal = bestVal;
                secondIdx = bestIdx;
                bestVal = prices[i];
                bestIdx = i;
            } else if (prices[i] > secondVal) {
                secondVal = prices[i];
                secondIdx = i;
            }
        }

        (bool found, address winner, uint256 winnerPrice, address secondQuoter, uint256 secondPrice) =
            registry.bestForXForY(poolId);
        assertTrue(found);
        assertEq(winner, arbs[bestIdx]);
        assertEq(winnerPrice, bestVal);
        assertEq(secondPrice, secondVal);
        if (secondVal > 0) assertEq(secondQuoter, arbs[secondIdx]);
    }

    function testFuzz_bestForYForX_matchesBruteForce(uint256[5] memory rawPrices) public {
        address[5] memory arbs = [alice, bob, carol, makeAddr("dave"), makeAddr("eve")];
        uint256[5] memory prices;
        for (uint256 i = 0; i < 5; i++) {
            prices[i] = (rawPrices[i] % 999) + 1;
            vm.deal(arbs[i], 1 ether);
            _stakeAndQuote(arbs[i], prices[i]);
        }

        uint256 bestVal = type(uint256).max;
        uint256 bestIdx;
        uint256 secondVal = type(uint256).max;
        uint256 secondIdx;
        for (uint256 i = 0; i < 5; i++) {
            if (prices[i] < bestVal) {
                secondVal = bestVal;
                secondIdx = bestIdx;
                bestVal = prices[i];
                bestIdx = i;
            } else if (prices[i] < secondVal) {
                secondVal = prices[i];
                secondIdx = i;
            }
        }
        if (secondVal == type(uint256).max) secondVal = 0;

        (bool found, address winner, uint256 winnerPrice, address secondQuoter, uint256 secondPrice) =
            registry.bestForYForX(poolId);
        assertTrue(found);
        assertEq(winner, arbs[bestIdx]);
        assertEq(winnerPrice, bestVal);
        assertEq(secondPrice, secondVal);
        if (secondVal > 0) assertEq(secondQuoter, arbs[secondIdx]);
    }

    function test_updateQuote_overwritesPrice() public {
        _stakeAndQuote(alice, 4);

        vm.prank(alice);
        registry.postQuote(poolId, 9, block.timestamp + 1 minutes);

        (, address winner, uint256 winnerPrice,,) = registry.bestForXForY(poolId);
        assertEq(winner, alice);
        assertEq(winnerPrice, 9);

        address[] memory active = registry.activeQuoters(poolId);
        assertEq(active.length, 1);
    }
}
