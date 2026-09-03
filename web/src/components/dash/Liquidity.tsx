import { useState } from 'react';
import { maxUint256, parseUnits, type Address } from 'viem';
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { erc20Abi } from '../../lib/deployment';
import type { PoolKey } from '../../lib/pool';
import { modifyLiquidityRouterAbi, stateViewAbi, v4ByChain } from '../../lib/v4';
import { REQUIRED_CHAIN } from '../../lib/wagmi';
import { Note, Panel, Row, TxState } from './ui';

const MIN_TICK = -887272;
const MAX_TICK = 887272;

function usableTick(tick: number, spacing: number): number {
	return Math.trunc(tick / spacing) * spacing;
}

export function LiquidityPanel({ poolKey, poolId }: { poolKey: PoolKey; poolId: `0x${string}` }) {
	const { address, isConnected, chainId } = useAccount();
	const wrongNet = isConnected && chainId !== REQUIRED_CHAIN.id;
	const v4 = v4ByChain[REQUIRED_CHAIN.id];
	const router = v4.modifyLiquidityRouter;

	const [amount, setAmount] = useState('100');
	const wanted = (() => {
		try {
			return parseUnits(amount || '0', 18);
		} catch {
			return 0n;
		}
	})();

	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const { data: liquidity } = useReadContract({
		address: v4?.stateView,
		abi: stateViewAbi,
		functionName: 'getLiquidity',
		args: [poolId],
		query: { enabled: !!v4?.stateView, refetchInterval: 8000 },
	});
	const allow0 = useAllowance(poolKey.currency0, router);
	const allow1 = useAllowance(poolKey.currency1, router);

	const approveMissing: Address | null =
		wanted > 0n && allow0 < wanted ? poolKey.currency0 : wanted > 0n && allow1 < wanted ? poolKey.currency1 : null;

	const modify = (sign: 1n | -1n) => {
		reset();
		writeContract({
			chainId: REQUIRED_CHAIN.id,
			gas: 4_000_000n,
			address: router,
			abi: modifyLiquidityRouterAbi,
			functionName: 'modifyLiquidity',
			args: [
				poolKey,
				{
					tickLower: usableTick(MIN_TICK, poolKey.tickSpacing),
					tickUpper: usableTick(MAX_TICK, poolKey.tickSpacing),
					liquidityDelta: sign * wanted,
					salt: '0x0000000000000000000000000000000000000000000000000000000000000000',
				},
				'0x',
			],
		});
	};

	return (
		<Panel
			title="Liquidity"
			hint="Full-range position via PoolSwapTest's sibling PoolModifyLiquidityTest. Node 0 of the flow needs this to be non-zero."
		>
			<Row label="pool liquidity">
				<span className="mono">{liquidity !== undefined ? liquidity.toString() : '—'}</span>
			</Row>

			{wrongNet && <Note tone="warn">Wallet is on the wrong network — switch to {REQUIRED_CHAIN.name}.</Note>}

			<div className="controls">
				<label className="field">
					<span>liquidity delta (×1e18)</span>
					<input className="mono" value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
				</label>
				<div className="btn-row">
					{approveMissing ? (
						<button
							type="button"
							className="btn btn-primary"
							disabled={!address || wrongNet}
							onClick={() => {
								reset();
								writeContract({
									chainId: REQUIRED_CHAIN.id,
									gas: 120_000n,
									address: approveMissing,
									abi: erc20Abi,
									functionName: 'approve',
									args: [router, maxUint256],
								});
							}}
						>
							{isPending ? 'pending…' : `approve ${approveMissing === poolKey.currency0 ? 'currency0' : 'currency1'}`}
						</button>
					) : (
						<button
							type="button"
							className="btn btn-primary"
							disabled={!address || wrongNet || wanted === 0n}
							onClick={() => modify(1n)}
						>
							{isPending ? 'pending…' : 'add'}
						</button>
					)}
					<button
						type="button"
						className="btn"
						disabled={!address || wrongNet || wanted === 0n}
						onClick={() => modify(-1n)}
					>
						remove
					</button>
				</div>
			</div>

			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</Panel>
	);
}

function useAllowance(token: Address, spender?: Address): bigint {
	const { address } = useAccount();
	const { data } = useReadContract({
		address: token,
		abi: erc20Abi,
		functionName: 'allowance',
		args: address && spender ? [address, spender] : undefined,
		query: { enabled: !!address && !!spender, refetchInterval: 8000 },
	});
	return (data as bigint | undefined) ?? 0n;
}
