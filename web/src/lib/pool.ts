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

export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint): number {
	const q96 = 2 ** 96;
	const r = Number(sqrtPriceX96) / q96;
	return r * r;
}

export function priceToSqrtPriceX96(price: number): bigint {
	return BigInt(Math.floor(Math.sqrt(price) * 2 ** 96));
}
