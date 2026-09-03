// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {QuoteRegistry} from "./QuoteRegistry.sol";

/// @notice A sweep winner may implement this to hedge the inventory atomically before paying.
interface ISweepCallback {
    function onSweep(Currency sold, uint256 amount, Currency paid, uint256 owed, bytes calldata data) external;
}

/// @notice Conditional partial-fill counterparty with a vanilla floor. When a swap pushes
///         the pool price to the far side of the competitive belief region, the hook fills
///         part of the order from its own buffer at a price between the pool and the
///         runner-up belief — strictly better for the swapper than the pool alone. The
///         acquired inventory is later auctioned to solvers via `sweepInventory`; proceeds
///         refill the buffer and the surplus is donated to LPs. The hook never worsens a
///         fill and never touches a swap that is moving price toward the belief region.
contract RediSwapHook {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    QuoteRegistry public immutable registry;

    /// @notice Largest fraction of an order the hook fills from its buffer.
    uint256 public immutable maxFillBps;
    /// @notice Margin the hook keeps between the pool price and the runner-up belief.
    uint256 public immutable hookEdgeBps;

    mapping(Currency => uint256) public buffer;
    mapping(Currency => uint256) public inventory;
    mapping(Currency => uint256) public spent;

    uint256 private _entered;

    struct Decision {
        bool intervene;
        uint256 fillIn;
        uint256 fillOut;
        uint256 hookPriceWad;
        uint160 vanillaEndSqrtPriceX96;
        uint160 fairSqrtPriceX96;
        address winner;
        uint256 winnerPriceWad;
        uint256 secondPriceWad;
        Currency inputCurrency;
        Currency outputCurrency;
    }

    event Filled(PoolId indexed poolId, address indexed swapper, uint256 fillIn, uint256 fillOut, uint256 hookPriceWad);
    event Swept(
        PoolId indexed poolId,
        address indexed keeper,
        Currency indexed sold,
        uint256 amount,
        uint256 proceeds,
        uint256 donated
    );

    error NotPoolManager();
    error NativeCurrencyUnsupported();
    error NothingToSweep();

    constructor(IPoolManager _poolManager, QuoteRegistry _registry, uint256 _maxFillBps, uint256 _hookEdgeBps) {
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        poolManager = _poolManager;
        registry = _registry;
        maxFillBps = _maxFillBps;
        hookEdgeBps = _hookEdgeBps;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        require(_entered == 0, "reentrant");
        _entered = 1;
        _;
        _entered = 0;
    }

    // ---------------------------------------------------------------- buffer

    function fundBuffer(Currency currency, uint256 amount) external nonReentrant {
        IERC20Minimal(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        buffer[currency] += amount;
    }

    // ---------------------------------------------------------------- swap path

    function beforeSwap(address swapper, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Decision memory d = _decide(key, params);
        if (!d.intervene) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        poolManager.take(d.inputCurrency, address(this), d.fillIn);
        inventory[d.inputCurrency] += d.fillIn;
        spent[d.inputCurrency] += d.fillOut;

        buffer[d.outputCurrency] -= d.fillOut;
        poolManager.sync(d.outputCurrency);
        d.outputCurrency.transfer(address(poolManager), d.fillOut);
        poolManager.settle();

        emit Filled(key.toId(), swapper, d.fillIn, d.fillOut, d.hookPriceWad);

        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(d.fillIn)), -int128(int256(d.fillOut))), 0);
    }

    function preview(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        view
        returns (Decision memory d)
    {
        d = _decide(key, params);

        PoolId poolId = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        uint128 liq = poolManager.getLiquidity(poolId);
        if (liq == 0 || params.amountSpecified >= 0) return d;

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amtLessFee = amountIn - FullMath.mulDiv(amountIn, key.fee, 1_000_000);
        d.vanillaEndSqrtPriceX96 = _simEnd(sqrtP, liq, amtLessFee, params.zeroForOne);
        if (d.secondPriceWad != 0) d.fairSqrtPriceX96 = _wadToSqrt(d.secondPriceWad);
    }

    function _decide(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        view
        returns (Decision memory d)
    {
        if (params.amountSpecified >= 0) return d;
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();

        d.inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        d.outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        PoolId poolId = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        if (poolManager.getLiquidity(poolId) == 0) return d;

        (bool found, address w1, uint256 v1, address second, uint256 v2raw) =
            params.zeroForOne ? registry.bestForXForY(poolId) : registry.bestForYForX(poolId);
        if (!found) return d;

        uint256 v2 = second == address(0) ? v1 : v2raw;
        d.winner = w1;
        d.winnerPriceWad = v1;
        d.secondPriceWad = v2;

        uint256 poolPx = _sqrtToWad(sqrtP);

        // the belief region must sit on the swapper's favourable side of the pool price,
        // i.e. the swap is filling them at a price the solver market thinks is too poor.
        if (params.zeroForOne ? v2 <= poolPx : v2 >= poolPx) return d;

        uint256 hookPx = params.zeroForOne
            ? poolPx + FullMath.mulDiv(v2 - poolPx, BPS - hookEdgeBps, BPS)
            : poolPx - FullMath.mulDiv(poolPx - v2, BPS - hookEdgeBps, BPS);

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 fillIn = FullMath.mulDiv(amountIn, maxFillBps, BPS);
        uint256 fillOut =
            params.zeroForOne ? FullMath.mulDiv(fillIn, hookPx, WAD) : FullMath.mulDiv(fillIn, WAD, hookPx);

        uint256 cap = buffer[d.outputCurrency];
        if (fillOut > cap) {
            fillOut = cap;
            fillIn = params.zeroForOne ? FullMath.mulDiv(fillOut, WAD, hookPx) : FullMath.mulDiv(fillOut, hookPx, WAD);
        }
        if (fillIn == 0 || fillOut == 0) return d;

        d.hookPriceWad = hookPx;
        d.fillIn = fillIn;
        d.fillOut = fillOut;
        d.intervene = true;
    }

    // ---------------------------------------------------------------- inventory auction

    function sweepInventory(PoolKey calldata key, bool sellZero, bytes calldata callbackData) external nonReentrant {
        Currency sold = sellZero ? key.currency0 : key.currency1;
        Currency paid = sellZero ? key.currency1 : key.currency0;
        uint256 inv = inventory[sold];
        if (inv == 0) revert NothingToSweep();

        PoolId poolId = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        uint256 spot = _sqrtToWad(sqrtP);

        (bool found,, uint256 v1, address second, uint256 v2raw) =
            sellZero ? registry.bestForXForY(poolId) : registry.bestForYForX(poolId);
        if (!found) revert NothingToSweep();
        uint256 vWad = second == address(0) ? v1 : v2raw;
        // the solver pays at least the current pool rate for the inventory
        vWad = sellZero ? (vWad < spot ? spot : vWad) : (vWad > spot ? spot : vWad);

        uint256 proceeds = sellZero ? FullMath.mulDiv(inv, vWad, WAD) : FullMath.mulDiv(inv, WAD, vWad);
        uint256 cost = spent[sold];
        if (proceeds <= cost) revert NothingToSweep();

        inventory[sold] = 0;
        spent[sold] = 0;

        IERC20Minimal(Currency.unwrap(sold)).transfer(msg.sender, inv);
        if (callbackData.length != 0) {
            ISweepCallback(msg.sender).onSweep(sold, inv, paid, proceeds, callbackData);
        }
        IERC20Minimal(Currency.unwrap(paid)).transferFrom(msg.sender, address(this), proceeds);

        buffer[paid] += cost;
        uint256 donation = proceeds - cost;
        poolManager.unlock(abi.encode(key, paid, donation));

        emit Swept(poolId, msg.sender, sold, inv, proceeds, donation);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolKey memory key, Currency c, uint256 amount) = abi.decode(data, (PoolKey, Currency, uint256));
        bool isZero = Currency.unwrap(c) == Currency.unwrap(key.currency0);
        poolManager.donate(key, isZero ? amount : 0, isZero ? 0 : amount, "");
        poolManager.sync(c);
        c.transfer(address(poolManager), amount);
        poolManager.settle();
        return "";
    }

    // ---------------------------------------------------------------- math

    function _simEnd(uint160 sqrtP, uint128 liq, uint256 amtIn, bool zeroForOne) internal pure returns (uint160) {
        uint256 l = uint256(liq);
        if (zeroForOne) {
            uint256 next = FullMath.mulDiv(l << 96, sqrtP, (l << 96) + amtIn * sqrtP);
            return next < TickMath.MIN_SQRT_PRICE ? TickMath.MIN_SQRT_PRICE : uint160(next);
        }
        uint256 up = uint256(sqrtP) + FullMath.mulDiv(amtIn, 1 << 96, l);
        return up > TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE : uint160(up);
    }

    function _sqrtToWad(uint160 s) internal pure returns (uint256) {
        uint256 p = FullMath.mulDiv(s, s, 1 << 96);
        return FullMath.mulDiv(p, WAD, 1 << 96);
    }

    function _wadToSqrt(uint256 priceWad) internal pure returns (uint160) {
        uint256 s = (FixedPointMathLib.sqrt(priceWad) * (1 << 96)) / 1e9;
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE;
        return uint160(s);
    }
}
