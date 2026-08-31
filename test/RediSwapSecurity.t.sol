// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {RediSwapSandwichHook} from "../src/RediSwapSandwichHook.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {ArbitrageurVault} from "../src/ArbitrageurVault.sol";

contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 public feeBips;

    constructor() MockERC20("Fee Token", "FEE", 18) {}

    function setFeeBips(uint256 bips) external {
        feeBips = bips;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;
        uint256 fee = (amount * feeBips) / 10_000;
        uint256 amountAfterFee = amount - fee;

        unchecked {
            balanceOf[to] += amountAfterFee;
        }
        emit Transfer(from, to, amount);
        return true;
    }
}

contract ArbitrageurVaultSecurityTest is Deployers {
    ArbitrageurVault vault;
    MockFeeOnTransferERC20 feeToken;
    Currency feeCurrency;
    address alice = makeAddr("alice");

    function setUp() public {
        vault = new ArbitrageurVault();
        vault.setHook(address(this));

        feeToken = new MockFeeOnTransferERC20();
        feeCurrency = Currency.wrap(address(feeToken));
        feeToken.mint(alice, 1000 ether);

        vm.prank(alice);
        feeToken.approve(address(vault), type(uint256).max);
    }

    function test_deposit_feeOnTransfer_creditsOnlyActualReceived() public {
        feeToken.setFeeBips(500); // 5% fee

        vm.prank(alice);
        vault.deposit(feeCurrency, 100 ether);

        uint256 credited = vault.balanceOf(alice, feeCurrency);
        uint256 actualHeld = feeToken.balanceOf(address(vault));

        assertEq(credited, 95 ether);
        assertEq(credited, actualHeld);
    }

    function test_deposit_noFee_creditsFullAmount() public {
        vm.prank(alice);
        vault.deposit(feeCurrency, 100 ether);

        assertEq(vault.balanceOf(alice, feeCurrency), 100 ether);
    }
}

contract QuoteRegistrySecurityTest is Deployers {
    QuoteRegistry registry;
    PoolId poolId;
    address alice = makeAddr("alice");

    function setUp() public {
        registry = new QuoteRegistry();
        poolId = PoolId.wrap(bytes32(uint256(1)));
        vm.deal(alice, 1 ether);
    }

    function test_postQuote_revertsOnZeroPrice() public {
        vm.startPrank(alice);
        registry.stake{value: 0.1 ether}();
        vm.expectRevert(QuoteRegistry.InvalidPrice.selector);
        registry.postQuote(poolId, 0, block.timestamp + 1 minutes);
        vm.stopPrank();
    }
}

contract RediSwapGriefingTest is Deployers {
    using StateLibrary for IPoolManager;

    QuoteRegistry registry;
    RediSwapSandwichHook hook;
    ArbitrageurVault vault;

    int24 constant TICK_SPACING = 60;

    address griefer = makeAddr("griefer");
    address realArb = makeAddr("realArb");

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

        vm.deal(griefer, 1 ether);
        vm.deal(realArb, 1 ether);

        MockERC20(Currency.unwrap(currency0)).transfer(realArb, 50_000 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(realArb, 50_000 ether);
        vm.startPrank(realArb);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), 50_000 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault), 50_000 ether);
        vault.deposit(currency0, 50_000 ether);
        vault.deposit(currency1, 50_000 ether);
        vm.stopPrank();
    }

    function test_undercapitalizedTopBidder_isSkipped_realArbitrageurStillWins() public {
        // Griefer bonds the minimum stake and posts an extreme, unfundable quote —
        // but deposits zero capital into the vault.
        vm.startPrank(griefer);
        registry.stake{value: 0.1 ether}();
        registry.postQuote(key.toId(), 100e18, block.timestamp + 1 minutes);
        vm.stopPrank();

        // Real arbitrageur posts a modest, genuinely fundable belief.
        vm.startPrank(realArb);
        registry.stake{value: 0.1 ether}();
        registry.postQuote(key.toId(), 1.05e18, block.timestamp + 1 minutes);
        vm.stopPrank();

        uint256 realArbBefore0 = vault.balanceOf(realArb, currency0);
        uint256 realArbBefore1 = vault.balanceOf(realArb, currency1);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: uint160((uint256(SQRT_PRICE_1_1) * 9800) / 10_000)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 realArbAfter0 = vault.balanceOf(realArb, currency0);
        uint256 realArbAfter1 = vault.balanceOf(realArb, currency1);

        assertTrue(realArbAfter0 != realArbBefore0 || realArbAfter1 != realArbBefore1);
        assertEq(vault.balanceOf(griefer, currency0), 0);
        assertEq(vault.balanceOf(griefer, currency1), 0);
    }
}
