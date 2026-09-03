// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {QuoteRegistry} from "../src/QuoteRegistry.sol";

// One run gets the pool demo-ready: deepen liquidity (from PRIVATE_KEY) and stand up a
// quoter per ARB_KEYS entry. Then the only wallet interaction left is the swap itself.
//   ARB_KEYS=0xkeyA,0xkeyB   QUOTE_PRICES=1050000000000000000,1020000000000000000
//   EXTRA_LIQUIDITY=100000000000000000000000   (optional; deployer must hold that much)
contract SeedDemoScript is Script {
    using PoolIdLibrary for PoolKey;

    uint256 constant MINT = 200_000 ether;

    function run() external {
        QuoteRegistry registry = QuoteRegistry(vm.envAddress("REGISTRY"));
        Currency currency0 = Currency.wrap(vm.envAddress("CURRENCY0"));
        Currency currency1 = Currency.wrap(vm.envAddress("CURRENCY1"));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: uint24(vm.envUint("FEE")),
            tickSpacing: int24(int256(vm.envUint("TICK_SPACING"))),
            hooks: IHooks(vm.envAddress("HOOK"))
        });
        PoolId poolId = key.toId();

        uint256 funderKey = vm.envOr("PRIVATE_KEY", uint256(0));
        _deepen(key, funderKey);
        _quoters(registry, key, poolId, funderKey);

        console2.logBytes32(PoolId.unwrap(poolId));
    }

    function _deepen(PoolKey memory key, uint256 funderKey) internal {
        int256 extra = vm.envOr("EXTRA_LIQUIDITY", int256(0));
        if (extra == 0 || funderKey == 0) return;

        address router = vm.envAddress("MODIFY_LIQUIDITY_ROUTER");
        int24 spacing = key.tickSpacing;

        vm.startBroadcast(funderKey);
        MockERC20(Currency.unwrap(key.currency0)).approve(router, type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(router, type(uint256).max);
        PoolModifyLiquidityTest(router)
            .modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(spacing),
                tickUpper: TickMath.maxUsableTick(spacing),
                liquidityDelta: extra,
                salt: 0
            }),
                ""
            );
        vm.stopBroadcast();
        console2.log("added liquidity %s", uint256(extra));
    }

    function _quoters(QuoteRegistry registry, PoolKey memory key, PoolId poolId, uint256 funderKey) internal {
        uint256[] memory keys = vm.envUint("ARB_KEYS", ",");
        uint256[] memory prices = vm.envUint("QUOTE_PRICES", ",");
        require(keys.length == prices.length, "ARB_KEYS / QUOTE_PRICES length mismatch");

        uint256 minStake = registry.MIN_STAKE();
        uint256 expiry = block.timestamp + registry.MAX_QUOTE_DURATION();
        uint256 gasFloat = minStake + 0.003 ether;
        Currency c0 = key.currency0;
        Currency c1 = key.currency1;

        for (uint256 i; i < keys.length; i++) {
            address arb = vm.addr(keys[i]);

            if (arb.balance < gasFloat && funderKey != 0) {
                vm.broadcast(funderKey);
                payable(arb).transfer(gasFloat - arb.balance);
            }

            vm.startBroadcast(keys[i]);
            registry.stake{value: minStake}();
            registry.postQuote(poolId, prices[i], expiry);
            vm.stopBroadcast();

            console2.log("quoter %s @ %s", arb, prices[i]);
        }
    }
}
