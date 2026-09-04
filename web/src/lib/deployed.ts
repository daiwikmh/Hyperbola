import { unichainSepolia } from 'wagmi/chains';
import type { Deployment } from './deployment';

// Filled in from `forge script script/Deploy.s.sol` output. One deployment per chain.
// v3 (RediSwapHook). poolId 0xfca21fb9e8d4c0e372a4f46e57b970b2772466145c4daa5de918bbd5d10507df
export const deployedByChain: Record<number, Deployment | undefined> = {
	[unichainSepolia.id]: {
		hook: '0xB9C04898F52398940Dfe5923d1d868edE4238088',
		registry: '0x91A563B7d85892993214CAd4C289f85f376F2273',
		vault: '',
		pool: {
			currency0: '0x6038835cC4312CEc700006451E4f95Cd9E7326aB',
			currency1: '0xB33Dc012a2fb318992c076A67F88B50Da9E18286',
			fee: '3000',
			tickSpacing: '60',
		},
	},
};
