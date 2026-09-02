// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RediSwapMath} from "../src/libraries/RediSwapMath.sol";

contract RediSwapMathTest is Test {
    uint256 constant K = 400;

    function _tx1() internal pure returns (RediSwapMath.Trade memory) {
        return RediSwapMath.Trade(RediSwapMath.Direction.XForY, 8, 25);
    }

    function _tx2() internal pure returns (RediSwapMath.Trade memory) {
        return RediSwapMath.Trade(RediSwapMath.Direction.XForY, 30, 12);
    }

    function _tx3() internal pure returns (RediSwapMath.Trade memory) {
        return RediSwapMath.Trade(RediSwapMath.Direction.YForX, 20, 10);
    }

    function test_limitState_tx1() public pure {
        (uint256 xl, uint256 yl) = RediSwapMath.limitState(K, _tx1());
        assertEq(xl, 8);
        assertEq(yl, 50);
    }

    function test_limitState_tx2() public pure {
        (uint256 xl, uint256 yl) = RediSwapMath.limitState(K, _tx2());
        assertEq(xl, 20);
        assertEq(yl, 20);
    }

    function test_limitState_tx3() public pure {
        (uint256 xl, uint256 yl) = RediSwapMath.limitState(K, _tx3());
        assertEq(xl, 20);
        assertEq(yl, 20);
    }

    function test_potentialValue_initialState() public pure {
        uint256 phi0 = RediSwapMath.potentialValue(K, 4, 100, 4);
        assertEq(phi0, 36);
    }

    function test_tradeValue_singleArbitrageur() public pure {
        assertEq(RediSwapMath.tradeValue(_tx1(), 4), 7);
        assertEq(RediSwapMath.tradeValue(_tx2(), 4), 108);
        assertEq(RediSwapMath.tradeValue(_tx3(), 4), 0);
    }

    function test_maxMEV_example1() public pure {
        uint256 phi0 = RediSwapMath.potentialValue(K, 4, 100, 4);

        uint256[] memory values = new uint256[](3);
        values[0] = RediSwapMath.tradeValue(_tx1(), 4);
        values[1] = RediSwapMath.tradeValue(_tx2(), 4);
        values[2] = RediSwapMath.tradeValue(_tx3(), 4);

        assertEq(RediSwapMath.maxMEV(phi0, values), 151);
    }

    function test_twoArbitrageurs_perTradeValues() public pure {
        assertEq(RediSwapMath.tradeValue(_tx1(), 4), 7);
        assertEq(RediSwapMath.tradeValue(_tx1(), 1), 0);

        assertEq(RediSwapMath.tradeValue(_tx2(), 4), 108);
        assertEq(RediSwapMath.tradeValue(_tx2(), 1), 18);

        assertEq(RediSwapMath.tradeValue(_tx3(), 4), 0);
        assertEq(RediSwapMath.tradeValue(_tx3(), 1), 10);
    }

    function test_twoArbitrageurs_initialStateValues() public pure {
        assertEq(RediSwapMath.potentialValue(K, 4, 100, 4), 36);
        assertEq(RediSwapMath.potentialValue(K, 4, 100, 1), 64);
    }

    function test_example3_perTransactionAuction() public pure {
        uint256[] memory tx1Values = new uint256[](2);
        tx1Values[0] = RediSwapMath.tradeValue(_tx1(), 4);
        tx1Values[1] = RediSwapMath.tradeValue(_tx1(), 1);
        (uint256 w1, uint256 winVal1, uint256 secondVal1) = RediSwapMath.winnerAndSecondPrice(tx1Values);
        assertEq(w1, 0);
        assertEq(winVal1, 7);
        assertEq(secondVal1, 0);

        uint256[] memory tx2Values = new uint256[](2);
        tx2Values[0] = RediSwapMath.tradeValue(_tx2(), 4);
        tx2Values[1] = RediSwapMath.tradeValue(_tx2(), 1);
        (uint256 w2, uint256 winVal2, uint256 secondVal2) = RediSwapMath.winnerAndSecondPrice(tx2Values);
        assertEq(w2, 0);
        assertEq(winVal2, 108);
        assertEq(secondVal2, 18);

        uint256[] memory tx3Values = new uint256[](2);
        tx3Values[0] = RediSwapMath.tradeValue(_tx3(), 4);
        tx3Values[1] = RediSwapMath.tradeValue(_tx3(), 1);
        (uint256 w3, uint256 winVal3, uint256 secondVal3) = RediSwapMath.winnerAndSecondPrice(tx3Values);
        assertEq(w3, 1);
        assertEq(winVal3, 10);
        assertEq(secondVal3, 0);
    }

    function test_example3_lvrAuction() public pure {
        uint256[] memory phiValues = new uint256[](2);
        phiValues[0] = RediSwapMath.potentialValue(K, 4, 100, 4);
        phiValues[1] = RediSwapMath.potentialValue(K, 4, 100, 1);

        (uint256 winner, uint256 winnerValue, uint256 secondValue) = RediSwapMath.winnerAndSecondPrice(phiValues);
        assertEq(winner, 1);
        assertEq(winnerValue, 64);
        assertEq(secondValue, 36);
    }
}
