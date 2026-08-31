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

import {RediSwapSandwichHook} from "../src/RediSwapSandwichHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {ArbitrageurVault} from "../src/ArbitrageurVault.sol";

contract RediSwapLVRTest is Deployers {
    using StateLibrary for IPoolManager;

    QuoteRegistry registry;
    RediSwapSandwichHook hook;
    ArbitrageurVault vault;

    int24 constant TICK_SPACING = 60;

    address arbHigh = makeAddr("arbHigh");
    address arbLow = makeAddr("arbLow");

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

        PoolId id;
        (key, id) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TICK_SPACING, SQRT_PRICE_1_1);
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000 ether, salt: 0}),
            ""
        );

        vm.deal(arbHigh, 1 ether);
        vm.deal(arbLow, 1 ether);
        _fundArbitrageur(arbHigh, 50_000 ether, 50_000 ether);
        _fundArbitrageur(arbLow, 50_000 ether, 50_000 ether);
    }

    function _fundArbitrageur(address arb, uint256 amount0, uint256 amount1) internal {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token0.transfer(arb, amount0);
        token1.transfer(arb, amount1);
        vm.startPrank(arb);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(currency0, amount0);
        vault.deposit(currency1, amount1);
        vm.stopPrank();
    }

    function _postQuote(address arb, uint256 priceWad) internal {
        vm.startPrank(arb);
        registry.stake{value: 0.1 ether}();
        registry.postQuote(key.toId(), priceWad, block.timestamp + 1 minutes);
        vm.stopPrank();
    }

    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    function test_settleLVR_noQuoters_isNoop() public {
        uint160 before = _sqrtPrice();
        hook.settleLVR(key);
        assertEq(_sqrtPrice(), before);
    }

    function test_settleLVR_singleHighQuoter_movesPriceTowardBelief() public {
        _postQuote(arbHigh, 1.10e18);

        uint160 before = _sqrtPrice();
        hook.settleLVR(key);
        uint160 afterPrice = _sqrtPrice();

        assertTrue(afterPrice > before);
    }

    function test_settleLVR_singleLowQuoter_movesPriceTowardBelief() public {
        _postQuote(arbLow, 0.90e18);

        uint160 before = _sqrtPrice();
        hook.settleLVR(key);
        uint160 afterPrice = _sqrtPrice();

        assertTrue(afterPrice < before);
    }

    function test_settleLVR_winnerIsMoreExtremeBelief_paysLPs() public {
        _postQuote(arbHigh, 1.20e18);
        _postQuote(arbLow, 1.01e18);

        uint256 vaultBalBefore0 = vault.balanceOf(arbHigh, currency0);
        uint256 vaultBalBefore1 = vault.balanceOf(arbHigh, currency1);

        hook.settleLVR(key);

        uint256 vaultBalAfter0 = vault.balanceOf(arbHigh, currency0);
        uint256 vaultBalAfter1 = vault.balanceOf(arbHigh, currency1);

        assertTrue(vaultBalAfter0 != vaultBalBefore0 || vaultBalAfter1 != vaultBalBefore1);
        assertTrue(_sqrtPrice() > SQRT_PRICE_1_1);
    }

    function test_settleLVR_isIdempotent_secondCallIsNoop() public {
        _postQuote(arbHigh, 1.10e18);

        hook.settleLVR(key);
        uint160 afterFirst = _sqrtPrice();

        hook.settleLVR(key);
        uint160 afterSecond = _sqrtPrice();

        assertEq(afterFirst, afterSecond);
    }

    function test_settleLVR_permissionless_anyoneCanCall() public {
        _postQuote(arbHigh, 1.10e18);

        vm.prank(makeAddr("randomKeeper"));
        hook.settleLVR(key);

        assertTrue(_sqrtPrice() > SQRT_PRICE_1_1);
    }
}
