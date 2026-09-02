// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {RediSwapSandwichHook} from "../src/RediSwapSandwichHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {ArbitrageurVault} from "../src/ArbitrageurVault.sol";

contract DeployScript is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        int24 frontrunTicks = int24(vm.envOr("FRONTRUN_TICKS", int256(0)));

        vm.startBroadcast();

        QuoteRegistry registry = new QuoteRegistry();
        ArbitrageurVault vault = new ArbitrageurVault();

        bytes32 salt = _mineSalt(poolManagerAddress, address(registry), address(vault), frontrunTicks);

        RediSwapSandwichHook hook =
            new RediSwapSandwichHook{salt: salt}(IPoolManager(poolManagerAddress), registry, vault, frontrunTicks);

        vault.setHook(address(hook));

        vm.stopBroadcast();

        console2.log("PoolManager:", poolManagerAddress);
        console2.log("QuoteRegistry:", address(registry));
        console2.log("ArbitrageurVault:", address(vault));
        console2.log("RediSwapSandwichHook:", address(hook));
    }

    function _mineSalt(address poolManagerAddress, address registryAddress, address vaultAddress, int24 frontrunTicks)
        internal
        view
        returns (bytes32)
    {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCodeWithArgs = abi.encodePacked(
            type(RediSwapSandwichHook).creationCode,
            abi.encode(poolManagerAddress, registryAddress, vaultAddress, frontrunTicks)
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
