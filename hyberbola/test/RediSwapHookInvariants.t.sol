// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {RediSwapHook} from "../src/RediSwapHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";

contract RediSwapHookInvariants is StdInvariant, Deployers {
    QuoteRegistry registry;
    RediSwapHook hook;
    Handler handler;

    int24 constant TS = 60;
    uint256 constant MAX_FILL_BPS = 3000;
    uint256 constant HOOK_EDGE_BPS = 2000;

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
        hook.fundBuffer(currency0, 20_000 ether);
        hook.fundBuffer(currency1, 20_000 ether);

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TS, SQRT_PRICE_1_1);
        _addLiquidity(key);

        handler = new Handler(registry, hook, swapRouter, key, currency0, currency1);
        MockERC20(Currency.unwrap(currency0)).transfer(address(handler), 400_000 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(address(handler), 400_000 ether);
        handler.init();

        targetContract(address(handler));
    }

    function _addLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TS),
                tickUpper: TickMath.maxUsableTick(TS),
                liquidityDelta: 400_000 ether,
                salt: 0
            }),
            ""
        );
    }

    // the hook physically holds at least what its ledger claims, in both currencies
    function invariant_hookSolvent() public view {
        assertGe(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook)),
            hook.buffer(currency0) + hook.inventory(currency0)
        );
        assertGe(
            MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook)),
            hook.buffer(currency1) + hook.inventory(currency1)
        );
    }

    // spent is only ever non-zero alongside inventory on the same currency
    function invariant_costBasisTracksInventory() public view {
        if (hook.inventory(currency0) == 0) assertEq(hook.spent(currency0), 0);
        if (hook.inventory(currency1) == 0) assertEq(hook.spent(currency1), 0);
    }
}

contract Handler is Test {
    using PoolIdLibrary for PoolKey;

    QuoteRegistry immutable registry;
    RediSwapHook immutable hook;
    PoolSwapTest immutable router;
    PoolKey poolKey;
    Currency c0;
    Currency c1;

    address[3] quoters;

    constructor(
        QuoteRegistry _registry,
        RediSwapHook _hook,
        PoolSwapTest _router,
        PoolKey memory _poolKey,
        Currency _c0,
        Currency _c1
    ) {
        registry = _registry;
        hook = _hook;
        router = _router;
        poolKey = _poolKey;
        c0 = _c0;
        c1 = _c1;
    }

    function init() external {
        MockERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        for (uint256 i; i < 3; i++) {
            quoters[i] = address(uint160(uint256(keccak256(abi.encode("quoter", i)))));
            vm.deal(quoters[i], 10 ether);
            vm.prank(quoters[i]);
            registry.stake{value: 1 ether}();
        }
    }

    function requote(uint256 who, uint256 priceWad) external {
        who = bound(who, 0, 2);
        priceWad = bound(priceWad, 0.6e18, 1.6e18);
        vm.prank(quoters[who]);
        registry.postQuote(poolKey.toId(), priceWad, block.timestamp + 4 minutes);
    }

    function swap(uint256 amount, bool zeroForOne) external {
        amount = bound(amount, 0.01 ether, 8_000 ether);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try router.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function sweep(bool sellZero) external {
        try hook.sweepInventory(poolKey, sellZero, "") {} catch {}
    }

    function fund(uint256 amount, bool zero) external {
        amount = bound(amount, 1 ether, 5_000 ether);
        hook.fundBuffer(zero ? c0 : c1, amount);
    }
}
