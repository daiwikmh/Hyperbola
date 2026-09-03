import { useCallback, useEffect, useState } from 'react';
import type { Address } from 'viem';
import { useChainId } from 'wagmi';
import { deployedByChain } from './deployed';
import type { PoolKey } from './pool';

export type Deployment = {
	hook: Address | '';
	registry: Address | '';
	vault: Address | '';
	pool: {
		currency0: Address | '';
		currency1: Address | '';
		fee: string;
		tickSpacing: string;
	};
};

export const EMPTY: Deployment = {
	hook: '',
	registry: '',
	vault: '',
	pool: { currency0: '', currency1: '', fee: '3000', tickSpacing: '60' },
};

const KEY = 'hyberbola.deployment.v1';

export function useDeployment() {
	const chainId = useChainId();
	const [deployment, setDeployment] = useState<Deployment>(EMPTY);
	const [loaded, setLoaded] = useState(false);

	useEffect(() => {
		let stored: Deployment | null = null;
		try {
			const raw = localStorage.getItem(KEY);
			if (raw) stored = { ...EMPTY, ...JSON.parse(raw) };
		} catch {
			/* private mode, blocked storage */
		}
		setDeployment(stored ?? deployedByChain[chainId] ?? EMPTY);
		setLoaded(true);
	}, [chainId]);

	const save = useCallback((next: Deployment) => {
		setDeployment(next);
		try {
			localStorage.setItem(KEY, JSON.stringify(next));
		} catch {
			/* nothing to do */
		}
	}, []);

	return { deployment, save, loaded };
}

export function isAddress(value: string): value is Address {
	return /^0x[0-9a-fA-F]{40}$/.test(value);
}

export function poolKeyFrom(d: Deployment): PoolKey | null {
	if (!isAddress(d.pool.currency0) || !isAddress(d.pool.currency1) || !isAddress(d.hook)) return null;
	const fee = Number(d.pool.fee);
	const tickSpacing = Number(d.pool.tickSpacing);
	if (!Number.isFinite(fee) || !Number.isFinite(tickSpacing)) return null;
	return {
		currency0: d.pool.currency0,
		currency1: d.pool.currency1,
		fee,
		tickSpacing,
		hooks: d.hook,
	};
}

export const erc20Abi = [
	{
		type: 'function',
		name: 'approve',
		stateMutability: 'nonpayable',
		inputs: [
			{ name: 'spender', type: 'address' },
			{ name: 'amount', type: 'uint256' },
		],
		outputs: [{ type: 'bool' }],
	},
	{
		type: 'function',
		name: 'allowance',
		stateMutability: 'view',
		inputs: [
			{ name: 'owner', type: 'address' },
			{ name: 'spender', type: 'address' },
		],
		outputs: [{ type: 'uint256' }],
	},
	{
		type: 'function',
		name: 'balanceOf',
		stateMutability: 'view',
		inputs: [{ name: 'account', type: 'address' }],
		outputs: [{ type: 'uint256' }],
	},
	{
		type: 'function',
		name: 'symbol',
		stateMutability: 'view',
		inputs: [],
		outputs: [{ type: 'string' }],
	},
	{
		type: 'function',
		name: 'decimals',
		stateMutability: 'view',
		inputs: [],
		outputs: [{ type: 'uint8' }],
	},
	{
		type: 'function',
		name: 'mint',
		stateMutability: 'nonpayable',
		inputs: [
			{ name: 'to', type: 'address' },
			{ name: 'value', type: 'uint256' },
		],
		outputs: [],
	},
] as const;
