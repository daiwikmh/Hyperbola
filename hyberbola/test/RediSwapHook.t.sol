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
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {RediSwapHook} from "../src/RediSwapHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";

contract RediSwapHookTest is Deployers {
    using StateLibrary for IPoolManager;

    QuoteRegistry registry;
    RediSwapHook hook;
    PoolKey plainKey;

    int24 constant TS = 60;
    uint256 constant MAX_FILL_BPS = 3000;
    uint256 constant HOOK_EDGE_BPS = 2000;

    address arbHi = makeAddr("arbHi");
    address arbLo = makeAddr("arbLo");
    address keeper = makeAddr("keeper");
    address swapper = makeAddr("swapper");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        registry = new QuoteRegistry(0.1 ether);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creation = abi.encodePacked(
            type(RediSwapHook).creationCode, abi.encode(manager, registry, MAX_FILL_BPS, HOOK_EDGE_BPS)
        );
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 200_000; i++) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), address(this), salt, keccak256(creation)))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) break;
        }
        hook = new RediSwapHook{salt: salt}(manager, registry, MAX_FILL_BPS, HOOK_EDGE_BPS);
        require(address(hook) == predicted, "salt");

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundBuffer(currency0, 5_000 ether);
        hook.fundBuffer(currency1, 5_000 ether);

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TS, SQRT_PRICE_1_1);
        (plainKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, TS, SQRT_PRICE_1_1);
        _addLiquidity(key);
        _addLiquidity(plainKey);

        MockERC20(Currency.unwrap(currency0)).transfer(swapper, 50_000 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(swapper, 50_000 ether);
        MockERC20(Currency.unwrap(currency0)).transfer(keeper, 50_000 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(keeper, 50_000 ether);

        vm.startPrank(swapper);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(keeper);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.deal(arbHi, 1 ether);
        vm.deal(arbLo, 1 ether);
    }

    function _addLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TS),
                tickUpper: TickMath.maxUsableTick(TS),
                liquidityDelta: 200_000 ether,
                salt: 0
            }),
            ""
        );
    }

    function _quote(address who, uint256 priceWad) internal {
        vm.startPrank(who);
        registry.stake{value: 0.1 ether}();
        registry.postQuote(key.toId(), priceWad, block.timestamp + 3 minutes);
        vm.stopPrank();
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(swapper);
        return swapRouter.swap(
            k,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _price(PoolKey memory k) internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(k.toId());
    }

    function test_noQuoters_matchesPlain() public {
        BalanceDelta a = _swap(plainKey, true, -1_000 ether);
        BalanceDelta b = _swap(key, true, -1_000 ether);
        assertEq(a.amount1(), b.amount1());
    }

    function test_towardFair_notIntervened() public {
        _quote(arbHi, 0.95e18);
        _quote(arbLo, 0.92e18);
        BalanceDelta a = _swap(plainKey, true, -1_000 ether);
        BalanceDelta b = _swap(key, true, -1_000 ether);
        assertEq(a.amount1(), b.amount1());
        assertEq(hook.inventory(currency0), 0);
    }

    function test_awayFromFair_swapperBeatsVanilla() public {
        _quote(arbHi, 1.05e18);
        _quote(arbLo, 1.02e18);

        BalanceDelta plain = _swap(plainKey, true, -1_000 ether);
        BalanceDelta hooked = _swap(key, true, -1_000 ether);

        uint256 plainOut = uint256(int256(plain.amount1()));
        uint256 hookedOut = uint256(int256(hooked.amount1()));
        emit log_named_uint("plain out ", plainOut);
        emit log_named_uint("hooked out", hookedOut);

        assertGt(hookedOut, plainOut);
        assertGt(hook.inventory(currency0), 0);
    }

    function test_oneForZero_awayFromFair_beatsVanilla() public {
        _quote(arbHi, 0.98e18);
        _quote(arbLo, 0.95e18);

        BalanceDelta plain = _swap(plainKey, false, -1_000 ether);
        BalanceDelta hooked = _swap(key, false, -1_000 ether);

        assertGt(uint256(int256(hooked.amount0())), uint256(int256(plain.amount0())));
        assertGt(hook.inventory(currency1), 0);
    }

    function test_sweep_refillsBufferAndClears() public {
        _quote(arbHi, 1.05e18);
        _quote(arbLo, 1.02e18);
        _swap(key, true, -1_000 ether);

        uint256 bufBefore = hook.buffer(currency1);
        assertGt(hook.inventory(currency0), 0);

        vm.prank(keeper);
        hook.sweepInventory(key, true, "");

        assertEq(hook.inventory(currency0), 0);
        assertEq(hook.spent(currency0), 0);
        assertGe(hook.buffer(currency1), bufBefore);
    }

    function testFuzz_swapperVanillaOrBetter(uint256 amountIn, uint256 v1, uint256 v2, bool zeroForOne) public {
        amountIn = bound(amountIn, 0.01 ether, 10_000 ether);
        v1 = bound(v1, 0.7e18, 1.5e18);
        v2 = bound(v2, 0.7e18, 1.5e18);
        _quote(arbHi, v1);
        _quote(arbLo, v2);

        BalanceDelta plain = _swap(plainKey, zeroForOne, -int256(amountIn));
        BalanceDelta hooked = _swap(key, zeroForOne, -int256(amountIn));

        int128 plainOut = zeroForOne ? plain.amount1() : plain.amount0();
        int128 hookOut = zeroForOne ? hooked.amount1() : hooked.amount0();
        assertGe(hookOut, plainOut);
    }

    function testFuzz_hookSolvent(uint256 amountIn, uint256 v1, uint256 v2, bool zeroForOne) public {
        amountIn = bound(amountIn, 0.01 ether, 10_000 ether);
        v1 = bound(v1, 0.7e18, 1.5e18);
        v2 = bound(v2, 0.7e18, 1.5e18);
        _quote(arbHi, v1);
        _quote(arbLo, v2);
        _swap(key, zeroForOne, -int256(amountIn));

        assertGe(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook)),
            hook.buffer(currency0) + hook.inventory(currency0)
        );
        assertGe(
            MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook)),
            hook.buffer(currency1) + hook.inventory(currency1)
        );
    }

    function test_hookSolvent() public {
        _quote(arbHi, 1.05e18);
        _quote(arbLo, 1.02e18);
        _swap(key, true, -1_000 ether);

        assertGe(
            hook.buffer(currency0) + hook.inventory(currency0),
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook))
        );
        assertGe(
            hook.buffer(currency1) + hook.inventory(currency1),
            MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook))
        );
    }
}
