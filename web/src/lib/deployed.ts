import { unichainSepolia } from 'wagmi/chains';
import type { Deployment } from './deployment';

// Filled in from `forge script script/Deploy.s.sol` output. One deployment per chain.
// v3 (RediSwapHook). poolId 0x3f322bd0fbc073a392a875298ee5c0cbe97bdb1c0fee6a5ef7ed386316297342
export const deployedByChain: Record<number, Deployment | undefined> = {
	[unichainSepolia.id]: {
		hook: '0x5e2Cd161FbE98325fec1Aa949907716655914088',
		registry: '0x866E9919ee149222f877d3a44d9Eb0FDb97F0662',
		vault: '',
		pool: {
			currency0: '0xb3D7643A75364eb2b3942bD1c4fbaCA02D34ee33',
			currency1: '0xce91739e7dECeB3BfC78D41E3B03aD9208B7A384',
			fee: '3000',
			tickSpacing: '60',
		},
	},
};
