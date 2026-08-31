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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {console2} from "forge-std/console2.sol";

import {RediSwapSandwichHook} from "../src/RediSwapSandwichHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {ArbitrageurVault} from "../src/ArbitrageurVault.sol";

contract RediSwapBacktestTest is Deployers {
    using StateLibrary for IPoolManager;

    QuoteRegistry registry;
    RediSwapSandwichHook hook;
    ArbitrageurVault vault;

    PoolKey plainKey;
    PoolKey hookedKey;

    int24 constant TICK_SPACING = 60;
    uint256 constant ROUNDS = 20;
    uint256 constant VOL_BPS = 250; // ~2.5% per-round shock, roughly matching the paper's calibrated volatility scale

    address plainArb = makeAddr("plainArb");
    address realArbA = makeAddr("realArbA");
    address realArbB = makeAddr("realArbB");
    address trader = makeAddr("trader");

    uint256 seed = 12345;
    uint256 truePriceWad = 1e18;

    uint256 plainUserOutput;
    uint256 hookedUserOutput;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        registry = new QuoteRegistry();
        vault = new ArbitrageurVault();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(RediSwapSandwichHook).creationCode, abi.encode(manager, registry, vault, int24(0)));

        bytes32 salt;
        address predicted;
        for (uint256 i; i < 200_000; i++) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), address(this), salt, keccak256(creationCodeWithArgs)))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) break;
        }

        hook = new RediSwapSandwichHook{salt: salt}(manager, registry, vault, 0);
        require(address(hook) == predicted, "hook address mismatch");
        vault.setHook(address(hook));

        PoolId idPlain;
        (plainKey, idPlain) = initPool(currency0, currency1, IHooks(address(0)), 3000, TICK_SPACING, SQRT_PRICE_1_1);
        PoolId idHooked;
        (hookedKey, idHooked) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TICK_SPACING, SQRT_PRICE_1_1);

        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        modifyLiquidityRouter.modifyLiquidity(
            plainKey,
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000 ether, salt: 0}),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            hookedKey,
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000 ether, salt: 0}),
            ""
        );

        _fundPlainArb();
        _fundVaultArb(realArbA);
        _fundVaultArb(realArbB);
        _fundTrader();
    }

    function _fundPlainArb() internal {
        vm.deal(plainArb, 1 ether);
        MockERC20(Currency.unwrap(currency0)).transfer(plainArb, 200_000 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(plainArb, 200_000 ether);
        vm.startPrank(plainArb);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _fundVaultArb(address arb) internal {
        vm.deal(arb, 1 ether);
        MockERC20(Currency.unwrap(currency0)).transfer(arb, 200_000 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(arb, 200_000 ether);
        vm.startPrank(arb);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vault.deposit(currency0, 200_000 ether);
        vault.deposit(currency1, 200_000 ether);
        registry.stake{value: 0.1 ether}();
        vm.stopPrank();
    }

    function _fundTrader() internal {
        MockERC20(Currency.unwrap(currency0)).transfer(trader, 1000 ether);
        vm.prank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
    }

    function _nextRand() internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed, block.number, "redisim")));
        return seed;
    }

    function _evolvePrice() internal {
        uint256 r = _nextRand();
        int256 shockBps = int256(r % (2 * VOL_BPS + 1)) - int256(VOL_BPS);
        if (shockBps >= 0) {
            truePriceWad = (truePriceWad * (10_000 + uint256(shockBps))) / 10_000;
        } else {
            truePriceWad = (truePriceWad * (10_000 - uint256(-shockBps))) / 10_000;
        }
    }

    function _sqrtPriceFor(uint256 priceWad) internal pure returns (uint160) {
        uint256 sq = (_sqrt(priceWad) * (1 << 96)) / 1e9;
        if (sq < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (sq > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE;
        return uint160(sq);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _currentSqrtPrice(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    function _arbitragePlainPoolToTruePrice() internal {
        uint160 current = _currentSqrtPrice(plainKey);
        uint160 target = _sqrtPriceFor(truePriceWad);
        if (current == target) return;
        bool zeroForOne = target < current;

        vm.prank(plainArb);
        swapRouter.swap(
            plainKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(150_000 ether)),
                sqrtPriceLimitX96: target
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _requoteHookedArbitrageurs() internal {
        uint256 noiseA = (_nextRand() % 41);
        uint256 noiseB = (_nextRand() % 41);
        uint256 priceA = (truePriceWad * (9980 + noiseA)) / 10_000;
        uint256 priceB = (truePriceWad * (9980 + noiseB)) / 10_000;
        if (priceA == 0) priceA = 1;
        if (priceB == 0) priceB = 1;

        vm.prank(realArbA);
        registry.postQuote(hookedKey.toId(), priceA, block.timestamp + 1 minutes);
        vm.prank(realArbB);
        registry.postQuote(hookedKey.toId(), priceB, block.timestamp + 1 minutes);
    }

    function test_backtest_syntheticPricePath_hookedPoolPreservesMoreLPValue() public {
        for (uint256 round = 0; round < ROUNDS; round++) {
            _evolvePrice();
            _arbitragePlainPoolToTruePrice();
            _requoteHookedArbitrageurs();

            uint256 plainOut = _swapTraderExactIn(plainKey, true, 0.1 ether);
            uint256 hookedOut = _swapTraderExactIn(hookedKey, true, 0.1 ether);
            plainUserOutput += plainOut;
            hookedUserOutput += hookedOut;

            if (round % 4 == 3) {
                hook.settleLVR(hookedKey);
            }
        }

        (uint256 plainReserve0, uint256 plainReserve1) = _markedValue(plainKey);
        (uint256 hookedReserve0, uint256 hookedReserve1) = _markedValue(hookedKey);

        uint256 plainValueInCurrency1 = (plainReserve0 * truePriceWad) / 1e18 + plainReserve1;
        uint256 hookedValueInCurrency1 = (hookedReserve0 * truePriceWad) / 1e18 + hookedReserve1;

        console2.log("=== RediSwap synthetic backtest: LP value (20 rounds, ~2.5%% vol) ===");
        console2.log("final true price (WAD):", truePriceWad);
        console2.log("plain pool LP value (in currency1):", plainValueInCurrency1);
        console2.log("hooked pool LP value (in currency1):", hookedValueInCurrency1);
        console2.log("[context only, not apples-to-apples -- plain pool here faces no sandwich at all]");
        console2.log("plain pool cumulative user output:", plainUserOutput);
        console2.log("hooked pool cumulative user output:", hookedUserOutput);

        assertTrue(hookedValueInCurrency1 > plainValueInCurrency1);
    }

    function _swapTraderExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        uint160 current = _currentSqrtPrice(key);
        uint160 limit = zeroForOne
            ? uint160((uint256(current) * 9995) / 10_000)
            : uint160((uint256(current) * 10_005) / 10_000);
        if (limit > TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE;
        if (limit < TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE;

        vm.prank(trader);
        int256 delta0 = swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ).amount1();

        return delta0 > 0 ? uint256(delta0) : 0;
    }

    function _sandwichLikeHook(PoolKey memory key, uint160 originalPrice, uint160 target, uint160 frontrunTarget)
        internal
    {
        vm.startPrank(plainArb);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(200_000 ether)),
                sqrtPriceLimitX96: frontrunTarget
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint160 current = _currentSqrtPrice(key);
        if (current == originalPrice) return;
        vm.startPrank(plainArb);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(200_000 ether)),
                sqrtPriceLimitX96: originalPrice
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_backtest_sameAdversarialPressure_refundStillHelpsUser() public {
        uint256 rounds = 10;
        uint256 unrefundedTotal;
        uint256 refundedTotal;

        for (uint256 round = 0; round < rounds; round++) {
            _evolvePrice();
            _requoteHookedArbitrageurs();

            uint160 originalPrice = _currentSqrtPrice(plainKey);
            uint160 target = uint160((uint256(originalPrice) * 9995) / 10_000);

            RediSwapSandwichHook.AuctionResult memory preview = hook.previewAuction(
                hookedKey,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: target})
            );
            uint160 frontrunTarget = uint160(preview.targetSqrtPriceX96);

            uint256 traderCurrency1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(trader);
            _sandwichLikeHook(plainKey, originalPrice, target, frontrunTarget);
            uint256 unrefundedOut = MockERC20(Currency.unwrap(currency1)).balanceOf(trader) - traderCurrency1Before;
            unrefundedTotal += unrefundedOut;

            refundedTotal += _swapTraderExactIn(hookedKey, true, 0.1 ether);

            if (round % 4 == 3) hook.settleLVR(hookedKey);
        }

        console2.log("=== Same adversarial pressure: sandwich w/o refund vs w/ refund ===");
        console2.log("unrefunded (plain pool, sandwiched, no redistribution):", unrefundedTotal);
        console2.log("refunded   (hooked pool, sandwiched, second-price refund):", refundedTotal);

        assertTrue(refundedTotal > unrefundedTotal);
    }

    function _markedValue(PoolKey memory key) internal view returns (uint256 reserve0, uint256 reserve1) {
        uint128 liquidity = manager.getLiquidity(key.toId());
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        reserve0 = (uint256(liquidity) * (1 << 96)) / sqrtPriceX96;
        reserve1 = (uint256(liquidity) * sqrtPriceX96) / (1 << 96);
    }
}
