// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {RediSwapMath} from "./libraries/RediSwapMath.sol";
import {QuoteRegistry} from "./QuoteRegistry.sol";
import {ArbitrageurVault} from "./ArbitrageurVault.sol";

contract RediSwapSandwichHook {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    QuoteRegistry public immutable registry;
    ArbitrageurVault public immutable vault;
    int24 public immutable frontrunTicks;

    struct Bundle {
        bool active;
        address winner;
        Currency outputCurrency;
        uint256 paymentDue;
    }

    struct AuctionResult {
        bool proceed;
        uint256 targetSqrtPriceX96;
        address primaryWinner;
        uint256 primaryPaymentDue;
        bool hasSecondary;
        address secondaryWinner;
        Currency inputCurrency;
        Currency outputCurrency;
    }

    mapping(PoolId => uint160) private _preBundleSqrtPrice;
    mapping(PoolId => Bundle) private _bundle;

    error NotPoolManager();
    error NativeCurrencyUnsupported();

    constructor(IPoolManager _poolManager, QuoteRegistry _registry, ArbitrageurVault _vault, int24 _frontrunTicks) {
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
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        poolManager = _poolManager;
        registry = _registry;
        vault = _vault;
        frontrunTicks = _frontrunTicks;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();

        if (params.amountSpecified >= 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        AuctionResult memory result = _evaluateAuction(poolId, key, params);

        if (result.proceed) {
            bool started = _tryStartBundle(
                key,
                poolId,
                sqrtPriceX96,
                params.zeroForOne,
                result.primaryWinner,
                result.targetSqrtPriceX96,
                result.primaryPaymentDue,
                result.inputCurrency,
                result.outputCurrency
            );
            if (!started && result.hasSecondary) {
                _tryStartBundle(
                    key,
                    poolId,
                    sqrtPriceX96,
                    params.zeroForOne,
                    result.secondaryWinner,
                    result.targetSqrtPriceX96,
                    0,
                    result.inputCurrency,
                    result.outputCurrency
                );
            }
        } else if (frontrunTicks != 0) {
            _runFallbackFrontrun(key, poolId, sqrtPriceX96, params.zeroForOne);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _tryStartBundle(
        PoolKey memory key,
        PoolId poolId,
        uint160 sqrtPriceX96,
        bool zeroForOne,
        address winner,
        uint256 targetSqrtPriceX96,
        uint256 paymentDue,
        Currency inputCurrency,
        Currency outputCurrency
    ) internal returns (bool started) {
        uint256 available = vault.balanceOf(winner, inputCurrency);
        uint256 pulled = vault.pullFor(winner, inputCurrency, available, address(this));
        if (pulled == 0) return false;

        _preBundleSqrtPrice[poolId] = sqrtPriceX96;
        _bundle[poolId] = Bundle({active: true, winner: winner, outputCurrency: outputCurrency, paymentDue: paymentDue});
        _pushPriceTo(key, zeroForOne, uint160(targetSqrtPriceX96));
        started = true;
    }

    function _runFallbackFrontrun(PoolKey memory key, PoolId poolId, uint160 sqrtPriceX96, bool zeroForOne) internal {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 targetTick = zeroForOne ? tick - frontrunTicks : tick + frontrunTicks;
        if (targetTick < TickMath.MIN_TICK) targetTick = TickMath.MIN_TICK;
        if (targetTick > TickMath.MAX_TICK) targetTick = TickMath.MAX_TICK;
        _preBundleSqrtPrice[poolId] = sqrtPriceX96;
        _pushPriceTo(key, zeroForOne, TickMath.getSqrtPriceAtTick(targetTick));
    }

    function previewAuction(PoolKey memory key, IPoolManager.SwapParams memory params)
        external
        view
        returns (AuctionResult memory)
    {
        return _evaluateAuction(key.toId(), key, params);
    }

    function _evaluateAuction(PoolId poolId, PoolKey memory key, IPoolManager.SwapParams memory params)
        internal
        view
        returns (AuctionResult memory result)
    {
        result.inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        result.outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 limitPriceWad = _sqrtPriceX96ToWad(params.sqrtPriceLimitX96);

        RediSwapMath.Trade memory trade;
        bool found;
        address secondQuoter;
        uint256 winnerPriceWad;
        uint256 secondPriceWad;

        if (params.zeroForOne) {
            trade = RediSwapMath.Trade(
                RediSwapMath.Direction.XForY, amountIn, (amountIn * limitPriceWad) / RediSwapMath.WAD
            );
            (found, result.primaryWinner, winnerPriceWad, secondQuoter, secondPriceWad) = registry.bestForXForY(poolId);
        } else {
            trade = RediSwapMath.Trade(
                RediSwapMath.Direction.YForX, amountIn, (amountIn * RediSwapMath.WAD) / limitPriceWad
            );
            (found, result.primaryWinner, winnerPriceWad, secondQuoter, secondPriceWad) = registry.bestForYForX(poolId);
        }

        if (!found) return result;

        uint256 winnerValue = RediSwapMath.tradeValueWad(trade, winnerPriceWad);
        if (winnerValue == 0) return result;

        result.primaryPaymentDue = RediSwapMath.tradeValueWad(trade, secondPriceWad);
        result.targetSqrtPriceX96 = _limitStateSqrtPrice(poolId, trade);
        result.proceed = true;

        if (secondQuoter != address(0) && RediSwapMath.tradeValueWad(trade, secondPriceWad) > 0) {
            result.hasSecondary = true;
            result.secondaryWinner = secondQuoter;
        }
    }

    uint256 internal constant PRECISION_SCALE = 1e9;

    function _limitStateSqrtPrice(PoolId poolId, RediSwapMath.Trade memory trade) internal view returns (uint256) {
        uint256 liquidity = poolManager.getLiquidity(poolId);
        uint256 liquidityScaled = liquidity / PRECISION_SCALE;
        if (liquidityScaled == 0) liquidityScaled = 1;

        RediSwapMath.Trade memory scaledTrade = RediSwapMath.Trade({
            direction: trade.direction, amountIn: _scaleDown(trade.amountIn), amountOut: _scaleDown(trade.amountOut)
        });

        (, uint256 ylScaled) = RediSwapMath.limitState(liquidityScaled * liquidityScaled, scaledTrade);
        uint256 yl = ylScaled * PRECISION_SCALE;
        uint256 sqrtPriceTarget = FullMath.mulDiv(yl, 1 << 96, liquidity);

        if (sqrtPriceTarget < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (sqrtPriceTarget > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE;
        return sqrtPriceTarget;
    }

    function _scaleDown(uint256 amount) internal pure returns (uint256 scaled) {
        scaled = amount / PRECISION_SCALE;
        if (scaled == 0) scaled = 1;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint160 targetSqrtPrice = _preBundleSqrtPrice[poolId];
        Bundle memory bundle = _bundle[poolId];
        delete _preBundleSqrtPrice[poolId];
        delete _bundle[poolId];

        if (targetSqrtPrice == 0) {
            return (this.afterSwap.selector, 0);
        }

        (uint160 currentSqrtPrice,,,) = poolManager.getSlot0(poolId);
        if (currentSqrtPrice != targetSqrtPrice) {
            bool backrunZeroForOne = currentSqrtPrice > targetSqrtPrice;

            if (bundle.active) {
                Currency backrunInputCurrency = backrunZeroForOne ? key.currency0 : key.currency1;
                uint256 topUp = vault.balanceOf(bundle.winner, backrunInputCurrency);
                vault.pullFor(bundle.winner, backrunInputCurrency, topUp, address(this));
            }

            _pushPriceTo(key, backrunZeroForOne, targetSqrtPrice);
        }

        if (!bundle.active) {
            return (this.afterSwap.selector, 0);
        }

        _returnCapitalToVault(key.currency0, bundle.winner);
        _returnCapitalToVault(key.currency1, bundle.winner);

        int128 hookDeltaUnspecified = 0;
        if (bundle.paymentDue > 0) {
            uint256 paid = vault.pullFor(bundle.winner, bundle.outputCurrency, bundle.paymentDue, address(this));
            if (paid > 0) {
                poolManager.sync(bundle.outputCurrency);
                bundle.outputCurrency.transfer(address(poolManager), paid);
                poolManager.settle();
                hookDeltaUnspecified = -int128(uint128(paid));
            }
        }

        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    function _returnCapitalToVault(Currency currency, address winner) internal {
        uint256 amount = currency.balanceOfSelf();
        if (amount == 0) return;
        currency.transfer(address(vault), amount);
        vault.creditFor(winner, currency, amount);
    }

    function _pushPriceTo(PoolKey memory key, bool zeroForOne, uint160 targetSqrtPrice) internal {
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        uint256 available = inputCurrency.balanceOfSelf();
        if (available == 0) return;

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(available), sqrtPriceLimitX96: targetSqrtPrice
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _sqrtPriceX96ToWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return (priceX192 / (1 << 192)) * RediSwapMath.WAD + ((priceX192 % (1 << 192)) * RediSwapMath.WAD) / (1 << 192);
    }

    function _priceWadToSqrtPriceX96(uint256 priceWad) internal pure returns (uint160) {
        uint256 sqrtPriceX96 = (FixedPointMathLib.sqrt(priceWad) * (1 << 96)) / 1e9;
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE;
        return uint160(sqrtPriceX96);
    }

    function settleLVR(PoolKey memory key) external returns (bytes memory) {
        return poolManager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        _settleLVR(key);
        return "";
    }

    struct LVRResult {
        bool proceed;
        address winner;
        uint256 winnerPriceWad;
        uint256 paymentDue;
        bool hasSecondary;
        address secondaryWinner;
        uint256 secondaryPriceWad;
    }

    function _settleLVR(PoolKey memory key) internal {
        PoolId poolId = key.toId();
        LVRResult memory result = _selectLVRWinner(poolId);
        if (!result.proceed) return;

        _executeLVR(key, result);
    }

    function _poolPotentialValues(PoolId poolId, uint256 maxPrice, uint256 minPrice)
        internal
        view
        returns (uint256 phiMax, uint256 phiMin)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 liquidityScaled = poolManager.getLiquidity(poolId) / PRECISION_SCALE;
        if (liquidityScaled == 0) liquidityScaled = 1;
        uint256 kScaled = liquidityScaled * liquidityScaled;
        uint256 x0Scaled = FullMath.mulDiv(liquidityScaled, 1 << 96, sqrtPriceX96);
        uint256 y0Scaled = FullMath.mulDiv(liquidityScaled, sqrtPriceX96, 1 << 96);

        phiMax = maxPrice == 0 ? 0 : RediSwapMath.potentialValueWad(kScaled, x0Scaled, y0Scaled, maxPrice);
        phiMin = minPrice == 0 ? 0 : RediSwapMath.potentialValueWad(kScaled, x0Scaled, y0Scaled, minPrice);
    }

    function _selectLVRWinner(PoolId poolId) internal view returns (LVRResult memory result) {
        (bool foundMax, address maxQuoter, uint256 maxPrice,,) = registry.bestForXForY(poolId);
        (bool foundMin, address minQuoter, uint256 minPrice,,) = registry.bestForYForX(poolId);
        if (!foundMax && !foundMin) return result;

        (uint256 phiMax, uint256 phiMin) =
            _poolPotentialValues(poolId, foundMax ? maxPrice : 0, foundMin ? minPrice : 0);

        bool maxWins = phiMax >= phiMin;
        uint256 winnerPhiScaled = maxWins ? phiMax : phiMin;
        if (winnerPhiScaled == 0) return result;

        result.proceed = true;
        result.winner = maxWins ? maxQuoter : minQuoter;
        result.winnerPriceWad = maxWins ? maxPrice : minPrice;
        result.paymentDue = (maxWins ? phiMin : phiMax) * PRECISION_SCALE;

        bool otherFound = maxWins ? foundMin : foundMax;
        uint256 otherPhi = maxWins ? phiMin : phiMax;
        if (otherFound && otherPhi > 0) {
            result.hasSecondary = true;
            result.secondaryWinner = maxWins ? minQuoter : maxQuoter;
            result.secondaryPriceWad = maxWins ? minPrice : maxPrice;
        }
    }

    function _executeLVR(PoolKey memory key, LVRResult memory result) internal {
        bool started = _tryExecuteLVRCandidate(key, result.winner, result.winnerPriceWad, result.paymentDue);
        if (!started && result.hasSecondary) {
            _tryExecuteLVRCandidate(key, result.secondaryWinner, result.secondaryPriceWad, 0);
        }
    }

    function _tryExecuteLVRCandidate(PoolKey memory key, address winner, uint256 priceWad, uint256 paymentDue)
        internal
        returns (bool started)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint160 targetSqrtPrice = _priceWadToSqrtPriceX96(priceWad);
        bool zeroForOne = targetSqrtPrice < sqrtPriceX96;
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        uint256 available = vault.balanceOf(winner, inputCurrency);
        uint256 pulled = vault.pullFor(winner, inputCurrency, available, address(this));
        if (pulled == 0) return false;

        _pushPriceTo(key, zeroForOne, targetSqrtPrice);
        started = true;

        _returnCapitalToVault(key.currency0, winner);
        _returnCapitalToVault(key.currency1, winner);

        if (paymentDue > 0) {
            _donatePaymentToLPs(key, winner, outputCurrency, paymentDue);
        }
    }

    function _donatePaymentToLPs(PoolKey memory key, address winner, Currency outputCurrency, uint256 paymentDue)
        internal
    {
        uint256 paid = vault.pullFor(winner, outputCurrency, paymentDue, address(this));
        if (paid == 0) return;

        uint256 amount0 = outputCurrency == key.currency0 ? paid : 0;
        uint256 amount1 = outputCurrency == key.currency1 ? paid : 0;
        BalanceDelta donateDelta = poolManager.donate(key, amount0, amount1, "");
        _settle(key.currency0, donateDelta.amount0());
        _settle(key.currency1, donateDelta.amount1());
    }
}
