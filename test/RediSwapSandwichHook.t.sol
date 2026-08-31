// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {RediSwapSandwichHook} from "../src/RediSwapSandwichHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {ArbitrageurVault} from "../src/ArbitrageurVault.sol";

contract RediSwapSandwichHookTest is Deployers {
    using StateLibrary for IPoolManager;

    QuoteRegistry registry;

    RediSwapSandwichHook noopHook;
    RediSwapSandwichHook fallbackHook;
    RediSwapSandwichHook auctionHook;

    ArbitrageurVault noopVault;
    ArbitrageurVault fallbackVault;
    ArbitrageurVault auctionVault;

    PoolKey noopKey;
    PoolKey fallbackKey;
    PoolKey auctionKey;

    int24 constant TICK_SPACING = 60;
    int24 constant FALLBACK_TICKS = 600;

    address arbHigh = makeAddr("arbHigh");
    address arbMid = makeAddr("arbMid");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        registry = new QuoteRegistry();

        (noopHook, noopVault) = _deployHookAndVault(0);
        (fallbackHook, fallbackVault) = _deployHookAndVault(FALLBACK_TICKS);
        (auctionHook, auctionVault) = _deployHookAndVault(0);

        noopKey = _initFullRangePool(noopHook);
        fallbackKey = _initFullRangePool(fallbackHook);
        auctionKey = _initFullRangePool(auctionHook);

        MockERC20(Currency.unwrap(currency0)).transfer(address(fallbackHook), 500 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(address(fallbackHook), 500 ether);

        vm.deal(arbHigh, 1 ether);
        vm.deal(arbMid, 1 ether);
        _fundArbitrageur(arbHigh, auctionVault, 50_000 ether, 50_000 ether);
        _fundArbitrageur(arbMid, auctionVault, 50_000 ether, 50_000 ether);
    }

    function _deployHookAndVault(int24 frontrunTicks) internal returns (RediSwapSandwichHook hook, ArbitrageurVault vault) {
        vault = new ArbitrageurVault();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCodeWithArgs = abi.encodePacked(
            type(RediSwapSandwichHook).creationCode, abi.encode(manager, registry, vault, frontrunTicks)
        );

        bytes32 salt;
        address predicted;
        for (uint256 i; i < 200_000; i++) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), address(this), salt, keccak256(creationCodeWithArgs)))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) break;
        }

        hook = new RediSwapSandwichHook{salt: salt}(manager, registry, vault, frontrunTicks);
        require(address(hook) == predicted, "hook address mismatch");

        vault.setHook(address(hook));
    }

    function _initFullRangePool(RediSwapSandwichHook hook) internal returns (PoolKey memory key) {
        PoolId id;
        (key, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TICK_SPACING, SQRT_PRICE_1_1);

        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000 ether, salt: 0}),
            ""
        );
    }

    function _fundArbitrageur(address arb, ArbitrageurVault vault, uint256 amount0, uint256 amount1) internal {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        token0.transfer(arb, amount0);
        token1.transfer(arb, amount1);

        vm.startPrank(arb);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(currency0, amount0);
        vault.deposit(currency1, amount1);
        vm.stopPrank();
    }

    function _postQuote(address arb, PoolId poolId, uint256 priceWad) internal {
        vm.startPrank(arb);
        registry.stake{value: 0.1 ether}();
        registry.postQuote(poolId, priceWad, block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    function _swapWithSlippage(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 toleranceBps)
        internal
        returns (BalanceDelta)
    {
        uint160 current = _sqrtPrice(key);
        uint160 limit = zeroForOne
            ? uint160((uint256(current) * (10_000 - toleranceBps)) / 10_000)
            : uint160((uint256(current) * (10_000 + toleranceBps)) / 10_000);

        return swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_noop_matchesPlainSwap() public {
        uint160 before = _sqrtPrice(noopKey);

        BalanceDelta delta = swap(noopKey, true, -1 ether, "");

        assertTrue(delta.amount1() > 0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(noopHook)), 0);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(noopHook)), 0);
        assertTrue(_sqrtPrice(noopKey) < before);
    }

    function test_fallback_roundTripsPoolPrice() public {
        uint160 before = _sqrtPrice(fallbackKey);
        swap(fallbackKey, true, -1 ether, "");
        assertEq(_sqrtPrice(fallbackKey), before);
    }

    function test_fallback_hurtsUserVersusNoop() public {
        BalanceDelta noopDelta = swap(noopKey, true, -1 ether, "");
        BalanceDelta fallbackDelta = swap(fallbackKey, true, -1 ether, "");

        assertTrue(fallbackDelta.amount1() > 0);
        assertTrue(fallbackDelta.amount1() < noopDelta.amount1());
    }

    function test_auction_noQuoters_isNoop() public {
        BalanceDelta noopDelta = swap(noopKey, true, -1 ether, "");
        BalanceDelta auctionDelta = swap(auctionKey, true, -1 ether, "");

        assertEq(auctionDelta.amount0(), noopDelta.amount0());
        assertEq(auctionDelta.amount1(), noopDelta.amount1());
    }

    function test_auction_singleQuoter_sandwichesWithNoRefund() public {
        _postQuote(arbHigh, auctionKey.toId(), 1.05e18);

        uint160 before = _sqrtPrice(auctionKey);
        uint256 arbBefore0 = auctionVault.balanceOf(arbHigh, currency0);
        uint256 arbBefore1 = auctionVault.balanceOf(arbHigh, currency1);

        BalanceDelta noopDelta = swap(noopKey, true, -1 ether, "");
        BalanceDelta auctionDelta = _swapWithSlippage(auctionKey, true, -1 ether, 200);

        assertEq(_sqrtPrice(auctionKey), before);
        assertTrue(auctionDelta.amount1() > 0);
        assertTrue(auctionDelta.amount1() < noopDelta.amount1());

        uint256 arbAfter0 = auctionVault.balanceOf(arbHigh, currency0);
        uint256 arbAfter1 = auctionVault.balanceOf(arbHigh, currency1);
        assertTrue(arbAfter0 != arbBefore0 || arbAfter1 != arbBefore1);
    }

    function test_auction_twoQuoters_userGetsRefundFromSecondPrice() public {
        _postQuote(arbHigh, auctionKey.toId(), 1.05e18);
        _postQuote(arbMid, auctionKey.toId(), 1.02e18);

        BalanceDelta soloDelta;
        {
            uint256 snapshot = vm.snapshotState();
            vm.prank(arbMid);
            registry.withdrawQuote(auctionKey.toId());
            soloDelta = swap(auctionKey, true, -1 ether, "");
            vm.revertToState(snapshot);
        }

        BalanceDelta refundedDelta = swap(auctionKey, true, -1 ether, "");

        assertTrue(refundedDelta.amount1() > soloDelta.amount1());
    }
}
