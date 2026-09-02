import { useState } from 'react';
import { parseUnits, type Address } from 'viem';
import { useReadContract, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { hookAbi } from '../../lib/abis';
import { sqrtPriceX96ToPrice, swapPriceLimit, type PoolKey } from '../../lib/pool';
import { Addr, Btn, Field, Note, Panel, Row, TxState } from './ui';

type AuctionResult = {
	proceed: boolean;
	targetSqrtPriceX96: bigint;
	primaryWinner: Address;
	primaryPaymentDue: bigint;
	hasSecondary: boolean;
	secondaryWinner: Address;
	inputCurrency: Address;
	outputCurrency: Address;
};

export function AuctionPreview({ hook, poolKey }: { hook: Address; poolKey: PoolKey }) {
	const [amountIn, setAmountIn] = useState('1');
	const [zeroForOne, setZeroForOne] = useState(true);

	const amount = (() => {
		try {
			return parseUnits(amountIn || '0', 18);
		} catch {
			return 0n;
		}
	})();

	const params = {
		zeroForOne,
		amountSpecified: -amount,
		sqrtPriceLimitX96: swapPriceLimit(zeroForOne),
	} as const;

	const { data, error, isFetching } = useReadContract({
		address: hook,
		abi: hookAbi,
		functionName: 'previewAuction',
		args: [poolKey, params],
		query: { enabled: amount > 0n, refetchInterval: 8000, retry: false },
	});

	const result = data as AuctionResult | undefined;

	return (
		<Panel
			title="Auction preview"
			hint="Calls previewAuction on the hook — the same _evaluateAuction the pool runs inside beforeSwap. Read-only, so it costs nothing to ask."
			wide
		>
			<div className="controls">
				<Field label="amount in (18 dp)" value={amountIn} onChange={setAmountIn} mono />
				<label className="field">
					<span>direction</span>
					<select
						className="mono"
						value={zeroForOne ? '0' : '1'}
						onChange={(e) => setZeroForOne(e.target.value === '0')}
					>
						<option value="0">zeroForOne — X for Y</option>
						<option value="1">oneForZero — Y for X</option>
					</select>
				</label>
			</div>

			{error && (
				<Note tone="warn">
					previewAuction reverted — {error.message.split('\n')[0]}. A division-by-zero here means the pool has no
					active liquidity: _limitStateSqrtPrice divides by the raw liquidity, which is only guarded in its scaled
					copy.
				</Note>
			)}

			{!error && result && (
				<>
					<Row label="proceeds">
						{result.proceed ? (
							<span className="ok">yes — a bundle would run</span>
						) : (
							<span className="dim">no — no live quote values this trade above zero</span>
						)}
					</Row>
					<Row label="winner">
						<Addr value={result.primaryWinner} />
					</Row>
					<Row label="pays (second price)">
						<span className="mono">{result.primaryPaymentDue.toString()}</span>
					</Row>
					<Row label="backup bidder">
						{result.hasSecondary ? <Addr value={result.secondaryWinner} /> : <span className="dim">none</span>}
					</Row>
					<Row label="limit state target">
						<span className="mono">
							{result.targetSqrtPriceX96.toString()}
							{result.targetSqrtPriceX96 > 0n && (
								<span className="dim"> · price ≈ {sqrtPriceX96ToPrice(result.targetSqrtPriceX96).toPrecision(8)}</span>
							)}
						</span>
					</Row>
					<Row label="input / output">
						<span>
							<Addr value={result.inputCurrency} /> → <Addr value={result.outputCurrency} />
						</span>
					</Row>
					{result.proceed && result.primaryPaymentDue === 0n && (
						<Note tone="warn">
							Only one live bidder, so the second price is zero — the winner sandwiches with no refund to the
							swapper. This is the single-quoter case the tests cover.
						</Note>
					)}
				</>
			)}

			{isFetching && !result && !error && <Note>reading…</Note>}
			{amount === 0n && <Note>Enter an amount to preview.</Note>}
		</Panel>
	);
}

export function LvrPanel({ hook, poolKey }: { hook: Address; poolKey: PoolKey }) {
	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const { data: frontrunTicks } = useReadContract({ address: hook, abi: hookAbi, functionName: 'frontrunTicks' });

	return (
		<Panel
			title="Rebalance (LVR)"
			hint="Permissionless. Auctions the right to move the pool to the winner's believed price, scored on φ = xv + y − 2√(kv). The payment is donated straight to LPs."
		>
			<Row label="fallback frontrun">
				<span className="mono">
					{frontrunTicks !== undefined ? `${frontrunTicks} ticks` : '—'}
					{frontrunTicks === 0 && <span className="dim"> · disabled</span>}
				</span>
			</Row>

			{frontrunTicks !== undefined && frontrunTicks !== 0 && (
				<Note tone="warn">
					A non-zero fallback front-runs even with no bidders, which is worse for the swapper than doing nothing.
					It exists for testing.
				</Note>
			)}

			<div className="btn-row">
				<Btn
					primary
					busy={isPending}
					onClick={() => {
						reset();
						writeContract({ address: hook, abi: hookAbi, functionName: 'settleLVR', args: [poolKey] });
					}}
				>
					settleLVR
				</Btn>
			</div>

			<Note>No-op when no quoter's belief implies positive potential, so calling it when nothing is stale is safe.</Note>
			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</Panel>
	);
}
