import { encodeAbiParameters, keccak256, type Address, type Hex } from 'viem';

export type PoolKey = {
	currency0: Address;
	currency1: Address;
	fee: number;
	tickSpacing: number;
	hooks: Address;
};

const POOL_KEY_TYPES = [
	{ type: 'address' },
	{ type: 'address' },
	{ type: 'uint24' },
	{ type: 'int24' },
	{ type: 'address' },
] as const;

export function toPoolId(key: PoolKey): Hex {
	return keccak256(
		encodeAbiParameters(POOL_KEY_TYPES, [
			key.currency0,
			key.currency1,
			key.fee,
			key.tickSpacing,
			key.hooks,
		]),
	);
}

export function sortCurrencies(a: Address, b: Address): [Address, Address] {
	return BigInt(a) < BigInt(b) ? [a, b] : [b, a];
}

export const MIN_SQRT_PRICE = 4295128739n;
export const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

export function swapPriceLimit(zeroForOne: boolean): bigint {
	return zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n;
}

// Keeps the swap price limit near the current price (~±10%) so a preview or a real
// swap neither invites huge slippage nor sits at an unrealistic extreme.
export function boundedSwapLimit(sqrtPriceX96: bigint, zeroForOne: boolean): bigint {
	const limit = zeroForOne ? (sqrtPriceX96 * 90n) / 100n : (sqrtPriceX96 * 110n) / 100n;
	if (limit <= MIN_SQRT_PRICE) return MIN_SQRT_PRICE + 1n;
	if (limit >= MAX_SQRT_PRICE) return MAX_SQRT_PRICE - 1n;
	return limit;
}

export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint): number {
	const q96 = 2 ** 96;
	const r = Number(sqrtPriceX96) / q96;
	return r * r;
}

export function priceToSqrtPriceX96(price: number): bigint {
	return BigInt(Math.floor(Math.sqrt(price) * 2 ** 96));
}

const Q96 = 2n ** 96n;

// Constant-product estimate for a full-range pool. Ignores tick crossings and the
// hook's front-run — it is the plain-pool baseline the flow compares against.
export function quoteExactInputSingle(
	sqrtPriceX96: bigint,
	liquidity: bigint,
	amountIn: bigint,
	zeroForOne: boolean,
	feePips: number,
): { amountOut: bigint; sqrtPriceX96After: bigint } {
	if (liquidity === 0n || amountIn === 0n) return { amountOut: 0n, sqrtPriceX96After: sqrtPriceX96 };
	const net = (amountIn * BigInt(1_000_000 - feePips)) / 1_000_000n;

	if (zeroForOne) {
		const next = (liquidity * Q96 * sqrtPriceX96) / (liquidity * Q96 + net * sqrtPriceX96);
		const amountOut = (liquidity * (sqrtPriceX96 - next)) / Q96;
		return { amountOut, sqrtPriceX96After: next };
	}
	const next = sqrtPriceX96 + (net * Q96) / liquidity;
	const amountOut = (liquidity * Q96 * (next - sqrtPriceX96)) / (next * sqrtPriceX96);
	return { amountOut, sqrtPriceX96After: next };
}
