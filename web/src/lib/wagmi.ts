import { createClient, http } from 'viem';
import { createConfig } from 'wagmi';
import { anvil, baseSepolia, sepolia, unichainSepolia } from 'wagmi/chains';
import { injected } from 'wagmi/connectors';

export const chains = [unichainSepolia, sepolia, baseSepolia, anvil] as const;

export const poolManagerByChain: Record<number, `0x${string}`> = {
	[unichainSepolia.id]: '0x00B036B58a818B1BC34d502D3fB730Db729e62AC',
	[sepolia.id]: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
	[baseSepolia.id]: '0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408',
};

export const config = createConfig({
	chains,
	connectors: [injected()],
	client({ chain }) {
		const local = chain.id === anvil.id;
		return createClient({
			chain,
			transport: local ? http('http://127.0.0.1:8545') : http(),
			batch: local ? undefined : { multicall: true },
		});
	},
});

declare module 'wagmi' {
	interface Register {
		config: typeof config;
	}
}
