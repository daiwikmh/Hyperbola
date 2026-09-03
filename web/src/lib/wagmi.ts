import { createClient, http } from 'viem';
import { createConfig } from 'wagmi';
import { unichainSepolia } from 'wagmi/chains';
import { injected } from 'wagmi/connectors';

// Every contract (hook, registry, vault, pool, tokens) lives on Unichain Sepolia.
export const REQUIRED_CHAIN = unichainSepolia;

export const chains = [unichainSepolia] as const;

export const poolManagerByChain: Record<number, `0x${string}`> = {
	[unichainSepolia.id]: '0x00b036b58a818b1bc34d502d3fe730db729e62ac',
};

export const config = createConfig({
	chains,
	connectors: [injected()],
	client({ chain }) {
		return createClient({
			chain,
			transport: http('https://unichain-sepolia.drpc.org'),
			batch: { multicall: true },
		});
	},
});

declare module 'wagmi' {
	interface Register {
		config: typeof config;
	}
}
