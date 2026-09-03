import { unichainSepolia } from 'wagmi/chains';
import type { Address } from 'viem';

// Uniswap v4 periphery — VERIFY on the chain explorer before a real deployment.
// https://developers.uniswap.org/contracts/v4/deployments
type V4Addresses = {
	poolManager: Address;
	swapRouter: Address; // PoolSwapTest
	modifyLiquidityRouter: Address; // PoolModifyLiquidityTest
	stateView: Address;
};

export const v4ByChain: Record<number, V4Addresses> = {
	[unichainSepolia.id]: {
		poolManager: '0x00b036b58a818b1bc34d502d3fe730db729e62ac',
		swapRouter: '0x9140a78c1a137c7ff1c151ec8231272af78a99a4',
		modifyLiquidityRouter: '0x5fa728c0a5cfd51bee4b060773f50554c0c8a7ab',
		stateView: '0xc199f1072a74d4e905aba1a84d9a45e2546b6222',
	},
};

const poolKeyComponents = [
	{ name: 'currency0', type: 'address' },
	{ name: 'currency1', type: 'address' },
	{ name: 'fee', type: 'uint24' },
	{ name: 'tickSpacing', type: 'int24' },
	{ name: 'hooks', type: 'address' },
] as const;

export const swapRouterAbi = [
	{
		type: 'function',
		name: 'swap',
		stateMutability: 'payable',
		inputs: [
			{ name: 'key', type: 'tuple', components: poolKeyComponents },
			{
				name: 'params',
				type: 'tuple',
				components: [
					{ name: 'zeroForOne', type: 'bool' },
					{ name: 'amountSpecified', type: 'int256' },
					{ name: 'sqrtPriceLimitX96', type: 'uint160' },
				],
			},
			{
				name: 'testSettings',
				type: 'tuple',
				components: [
					{ name: 'takeClaims', type: 'bool' },
					{ name: 'settleUsingBurn', type: 'bool' },
				],
			},
			{ name: 'hookData', type: 'bytes' },
		],
		outputs: [{ name: 'delta', type: 'int256' }],
	},
] as const;

export const modifyLiquidityRouterAbi = [
	{
		type: 'function',
		name: 'modifyLiquidity',
		stateMutability: 'payable',
		inputs: [
			{ name: 'key', type: 'tuple', components: poolKeyComponents },
			{
				name: 'params',
				type: 'tuple',
				components: [
					{ name: 'tickLower', type: 'int24' },
					{ name: 'tickUpper', type: 'int24' },
					{ name: 'liquidityDelta', type: 'int256' },
					{ name: 'salt', type: 'bytes32' },
				],
			},
			{ name: 'hookData', type: 'bytes' },
		],
		outputs: [{ name: 'delta', type: 'int256' }],
	},
] as const;

export const stateViewAbi = [
	{
		type: 'function',
		name: 'getSlot0',
		stateMutability: 'view',
		inputs: [{ name: 'poolId', type: 'bytes32' }],
		outputs: [
			{ name: 'sqrtPriceX96', type: 'uint160' },
			{ name: 'tick', type: 'int24' },
			{ name: 'protocolFee', type: 'uint24' },
			{ name: 'lpFee', type: 'uint24' },
		],
	},
	{
		type: 'function',
		name: 'getLiquidity',
		stateMutability: 'view',
		inputs: [{ name: 'poolId', type: 'bytes32' }],
		outputs: [{ name: 'liquidity', type: 'uint128' }],
	},
] as const;
