import { useState } from 'react';
import { formatUnits, parseUnits, type Address } from 'viem';
import { useReadContract, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { hookAbi } from '../../lib/abis';
import { sqrtPriceX96ToPrice, swapPriceLimit, type PoolKey } from '../../lib/pool';
import { REQUIRED_CHAIN } from '../../lib/wagmi';
import { Addr, Btn, Field, Note, Panel, Row, TxState } from './ui';

type Decision = {
	intervene: boolean;
	fillIn: bigint;
	fillOut: bigint;
	hookPriceWad: bigint;
	vanillaEndSqrtPriceX96: bigint;
	fairSqrtPriceX96: bigint;
	winner: Address;
	winnerPriceWad: bigint;
	secondPriceWad: bigint;
	inputCurrency: Address;
	outputCurrency: Address;
};

export function DecisionPreview({ hook, poolKey }: { hook: Address; poolKey: PoolKey }) {
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
		functionName: 'preview',
		args: [poolKey, params],
		query: { enabled: amount > 0n, refetchInterval: 8000, retry: false },
	});

	const d = data as Decision | undefined;

	return (
		<Panel
			title="beforeSwap decision"
			hint="Calls preview on the hook — the same _decide the pool runs inside beforeSwap. Read-only, so it costs nothing to ask."
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

			{error && <Note tone="warn">preview reverted — {error.message.split('\n')[0]}.</Note>}

			{!error && d && (
				<>
					<Row label="intervene">
						{d.intervene ? (
							<span className="ok">yes — hook fills part of this order</span>
						) : (
							<span className="dim">no — swap runs vanilla, hook stays out</span>
						)}
					</Row>
					<Row label="winner">
						<Addr value={d.winner} />
					</Row>
					<Row label="winner belief (wad)">
						<span className="mono">{d.winnerPriceWad.toString()}</span>
					</Row>
					<Row label="runner-up belief (wad)">
						<span className="mono">
							{d.secondPriceWad > 0n ? d.secondPriceWad.toString() : 'none — lone bidder'}
						</span>
					</Row>
					<Row label="hook fill price">
						<span className="mono">
							{d.hookPriceWad > 0n ? Number(formatUnits(d.hookPriceWad, 18)).toPrecision(8) : '—'}
						</span>
					</Row>
					<Row label="fill in / out">
						<span className="mono">
							{Number(formatUnits(d.fillIn, 18)).toFixed(4)} → {Number(formatUnits(d.fillOut, 18)).toFixed(4)}
						</span>
					</Row>
					<Row label="vanilla end price">
						<span className="mono">
							{d.vanillaEndSqrtPriceX96 > 0n
								? sqrtPriceX96ToPrice(d.vanillaEndSqrtPriceX96).toPrecision(8)
								: '—'}
						</span>
					</Row>
					<Row label="fair edge price">
						<span className="mono">
							{d.fairSqrtPriceX96 > 0n ? sqrtPriceX96ToPrice(d.fairSqrtPriceX96).toPrecision(8) : '—'}
						</span>
					</Row>
					<Row label="input / output">
						<span>
							<Addr value={d.inputCurrency} /> → <Addr value={d.outputCurrency} />
						</span>
					</Row>
					{d.intervene && d.secondPriceWad === 0n && (
						<Note tone="warn">
							Only one live bidder — the hook prices the fill against that lone belief.
						</Note>
					)}
				</>
			)}

			{isFetching && !d && !error && <Note>reading…</Note>}
			{amount === 0n && <Note>Enter an amount to preview.</Note>}
		</Panel>
	);
}

export function SweepPanel({ hook, poolKey }: { hook: Address; poolKey: PoolKey }) {
	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const c0 = useReadContract({
		address: hook,
		abi: hookAbi,
		functionName: 'inventory',
		args: [poolKey.currency0],
		query: { refetchInterval: 8000 },
	});
	const c1 = useReadContract({
		address: hook,
		abi: hookAbi,
		functionName: 'inventory',
		args: [poolKey.currency1],
		query: { refetchInterval: 8000 },
	});

	const sweep = (sellZero: boolean) => {
		reset();
		writeContract({
			chainId: REQUIRED_CHAIN.id,
			gas: 600_000n,
			address: hook,
			abi: hookAbi,
			functionName: 'sweepInventory',
			args: [poolKey, sellZero, '0x'],
		});
	};

	return (
		<Panel
			title="Sweep inventory"
			hint="Permissionless. A solver buys the hook's accumulated inventory at the runner-up belief, hedges it externally, and keeps φ₁ − φ₂. Proceeds refill the buffer; the surplus is donated to LPs."
		>
			<Row label="inventory currency0">
				<span className="mono">{c0.data !== undefined ? formatUnits(c0.data as bigint, 18) : '—'}</span>
			</Row>
			<Row label="inventory currency1">
				<span className="mono">{c1.data !== undefined ? formatUnits(c1.data as bigint, 18) : '—'}</span>
			</Row>
			<div className="btn-row">
				<Btn primary busy={isPending} onClick={() => sweep(true)}>
					sweep c0
				</Btn>
				<Btn busy={isPending} onClick={() => sweep(false)}>
					sweep c1
				</Btn>
			</div>

			<Note>Reverts with NothingToSweep when there is no inventory or the belief no longer clears the cost basis.</Note>
			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</Panel>
	);
}
