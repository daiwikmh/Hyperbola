// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @notice Potential function and per-trade value from "RediSwap: MEV Redistribution
///         Mechanism for CFMMs" — Mengqian Zhang, Sen Yang, Fan Zhang (Yale),
///         arXiv:2410.18434 (2024). φ(x, y, v) = xv + y − 2√(kv); Δφ = Δx·v + Δy.
library RediSwapMath {
    using FixedPointMathLib for uint256;

    enum Direction {
        XForY,
        YForX
    }

    struct Trade {
        Direction direction;
        uint256 amountIn;
        uint256 amountOut;
    }

    function limitState(uint256 k, Trade memory trade) internal pure returns (uint256 xl, uint256 yl) {
        if (trade.direction == Direction.XForY) {
            uint256 a = trade.amountOut;
            uint256 b = trade.amountOut * trade.amountIn;
            uint256 discriminant = b * b + 4 * a * k * trade.amountIn;
            xl = (discriminant.sqrt() - b) / (2 * a);
            yl = k / xl;
        } else {
            uint256 a = trade.amountOut;
            uint256 b = trade.amountOut * trade.amountIn;
            uint256 discriminant = b * b + 4 * a * k * trade.amountIn;
            yl = (discriminant.sqrt() - b) / (2 * a);
            xl = k / yl;
        }
    }

    function tradeImpact(Trade memory trade) internal pure returns (int256 deltaX, int256 deltaY) {
        if (trade.direction == Direction.XForY) {
            deltaX = int256(trade.amountIn);
            deltaY = -int256(trade.amountOut);
        } else {
            deltaX = -int256(trade.amountOut);
            deltaY = int256(trade.amountIn);
        }
    }

    function deltaPotential(int256 deltaX, int256 deltaY, uint256 v) internal pure returns (int256) {
        return deltaX * int256(v) + deltaY;
    }

    function tradeValue(Trade memory trade, uint256 v) internal pure returns (uint256) {
        (int256 deltaX, int256 deltaY) = tradeImpact(trade);
        int256 deltaPhi = deltaPotential(deltaX, deltaY, v);
        return deltaPhi > 0 ? uint256(deltaPhi) : 0;
    }

    function potentialValue(uint256 k, uint256 x, uint256 y, uint256 v) internal pure returns (uint256) {
        uint256 xTermPlusY = x * v + y;
        uint256 noArb = 2 * (k * v).sqrt();
        return xTermPlusY > noArb ? xTermPlusY - noArb : 0;
    }

    function maxMEV(uint256 phi0, uint256[] memory tradeValues) internal pure returns (uint256 total) {
        total = phi0;
        for (uint256 i = 0; i < tradeValues.length; i++) {
            total += tradeValues[i];
        }
    }

    uint256 internal constant WAD = 1e18;

    function deltaPotentialWad(int256 deltaX, int256 deltaY, uint256 priceWad) internal pure returns (int256) {
        return (deltaX * int256(priceWad)) / int256(WAD) + deltaY;
    }

    function potentialValueWad(uint256 k, uint256 x, uint256 y, uint256 priceWad) internal pure returns (uint256) {
        uint256 xTermPlusY = (x * priceWad) / WAD + y;
        uint256 noArb = (2 * (k * priceWad).sqrt()) / 1e9;
        return xTermPlusY > noArb ? xTermPlusY - noArb : 0;
    }

    function tradeValueWad(Trade memory trade, uint256 priceWad) internal pure returns (uint256) {
        (int256 deltaX, int256 deltaY) = tradeImpact(trade);
        int256 deltaPhi = deltaPotentialWad(deltaX, deltaY, priceWad);
        return deltaPhi > 0 ? uint256(deltaPhi) : 0;
    }

    function winnerAndSecondPrice(uint256[] memory values)
        internal
        pure
        returns (uint256 winnerIndex, uint256 winnerValue, uint256 secondValue)
    {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] > winnerValue) {
                secondValue = winnerValue;
                winnerValue = values[i];
                winnerIndex = i;
            } else if (values[i] > secondValue) {
                secondValue = values[i];
            }
        }
    }
}
