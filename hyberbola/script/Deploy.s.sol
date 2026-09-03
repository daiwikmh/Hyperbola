// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {RediSwapHook} from "../src/RediSwapHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";

contract DeployScript is Script {
    using PoolIdLibrary for PoolKey;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant MINT = 5_000_000 ether;
    uint256 constant BUFFER = 25_000 ether;

    function run() external {
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        address modifyLiquidityRouter = vm.envAddress("MODIFY_LIQUIDITY_ROUTER");
        uint256 maxFillBps = vm.envOr("MAX_FILL_BPS", uint256(3000));
        uint256 hookEdgeBps = vm.envOr("HOOK_EDGE_BPS", uint256(2000));
        int256 liquidity = vm.envOr("LIQUIDITY", int256(300_000 ether));

        vm.startBroadcast();

        (Currency currency0, Currency currency1) = _deployTokens();
        QuoteRegistry registry = new QuoteRegistry(vm.envOr("MIN_STAKE", uint256(0.1 ether)));

        bytes32 salt = _mineSalt(poolManagerAddress, address(registry), maxFillBps, hookEdgeBps);
        RediSwapHook hook =
            new RediSwapHook{salt: salt}(IPoolManager(poolManagerAddress), registry, maxFillBps, hookEdgeBps);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundBuffer(currency0, BUFFER);
        hook.fundBuffer(currency1, BUFFER);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        _openPool(IPoolManager(poolManagerAddress), modifyLiquidityRouter, key, liquidity);

        vm.stopBroadcast();

        _report(poolManagerAddress, address(registry), address(hook), key);
    }

    function _deployTokens() internal returns (Currency currency0, Currency currency1) {
        MockERC20 usdc = new MockERC20("Test USDC", "USDC", 18);
        MockERC20 dai = new MockERC20("Test DAI", "DAI", 18);
        usdc.mint(msg.sender, MINT);
        dai.mint(msg.sender, MINT);
        (currency0, currency1) = address(usdc) < address(dai)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(dai)))
            : (Currency.wrap(address(dai)), Currency.wrap(address(usdc)));
    }

    function _openPool(IPoolManager poolManager, address router, PoolKey memory key, int256 liquidity) internal {
        poolManager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(key.currency0)).approve(router, type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(router, type(uint256).max);
        PoolModifyLiquidityTest(router)
            .modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: liquidity,
                salt: 0
            }),
                ""
            );
    }

    function _report(address poolManager, address registry, address hook, PoolKey memory key) internal pure {
        console2.log("POOL_MANAGER=%s", poolManager);
        console2.log("REGISTRY=%s", registry);
        console2.log("HOOK=%s", hook);
        console2.log("CURRENCY0=%s", Currency.unwrap(key.currency0));
        console2.log("CURRENCY1=%s", Currency.unwrap(key.currency1));
        console2.log("FEE=%s", uint256(FEE));
        console2.log("TICK_SPACING=%s", uint256(uint24(TICK_SPACING)));
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _mineSalt(address poolManagerAddress, address registryAddress, uint256 maxFillBps, uint256 hookEdgeBps)
        internal
        view
        returns (bytes32)
    {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCodeWithArgs = abi.encodePacked(
            type(RediSwapHook).creationCode, abi.encode(poolManagerAddress, registryAddress, maxFillBps, hookEdgeBps)
        );

        for (uint256 i; i < 200_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xFF), CREATE2_DEPLOYER, salt, keccak256(creationCodeWithArgs))
                        )
                    )
                )
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) {
                return salt;
            }
        }
        revert("DeployScript: could not find salt");
    }
}
