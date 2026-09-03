import { useMemo, useState } from 'react';
import { formatUnits, parseUnits, type Address } from 'viem';
import { useReadContract } from 'wagmi';
import { hookAbi, registryAbi } from '../../lib/abis';
import { boundedSwapLimit, quoteExactInputSingle, sqrtPriceX96ToPrice, type PoolKey } from '../../lib/pool';
import { stateViewAbi, v4ByChain } from '../../lib/v4';
import { REQUIRED_CHAIN } from '../../lib/wagmi';
import { Addr, Note } from './ui';

type Props = { hook: Address; registry?: Address; poolKey: PoolKey; poolId: `0x${string}` };

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

export function Flow({ hook, registry, poolKey, poolId }: Props) {
	const v4 = v4ByChain[REQUIRED_CHAIN.id];
	const [amountIn, setAmountIn] = useState('1');
	const [zeroForOne, setZeroForOne] = useState(true);

	const amount = useMemo(() => {
		try {
			return parseUnits(amountIn || '0', 18);
		} catch {
			return 0n;
		}
	}, [amountIn]);

	const { data: slot0 } = useReadContract({
		address: v4?.stateView,
		abi: stateViewAbi,
		functionName: 'getSlot0',
		args: [poolId],
		query: { enabled: !!v4?.stateView, refetchInterval: 8000 },
	});
	const sqrtNow = slot0?.[0];
	const params = {
		zeroForOne,
		amountSpecified: -amount,
		sqrtPriceLimitX96: sqrtNow ? boundedSwapLimit(sqrtNow, zeroForOne) : 0n,
	} as const;
	const { data: liquidity } = useReadContract({
		address: v4?.stateView,
		abi: stateViewAbi,
		functionName: 'getLiquidity',
		args: [poolId],
		query: { enabled: !!v4?.stateView, refetchInterval: 8000 },
	});
	const { data: quoters } = useReadContract({
		address: registry,
		abi: registryAbi,
		functionName: 'activeQuoters',
		args: [poolId],
		query: { enabled: !!registry, refetchInterval: 8000 },
	});
	const { data: decision, error: previewError } = useReadContract({
		address: hook,
		abi: hookAbi,
		functionName: 'preview',
		args: [poolKey, params],
		query: { enabled: amount > 0n && !!sqrtNow, refetchInterval: 8000, retry: false },
	});
	const d = decision as Decision | undefined;

	const priceNow = sqrtNow ? sqrtPriceX96ToPrice(sqrtNow) : null;
	const nQuoters = (quoters as readonly Address[] | undefined)?.length ?? 0;
	const runs = !!d?.intervene;

	const vanilla =
		sqrtNow && liquidity !== undefined && amount > 0n
			? quoteExactInputSingle(sqrtNow, liquidity, amount, zeroForOne, poolKey.fee)
			: null;
	const poolLeg =
		runs && sqrtNow && liquidity !== undefined && amount - d!.fillIn > 0n
			? quoteExactInputSingle(sqrtNow, liquidity, amount - d!.fillIn, zeroForOne, poolKey.fee)
			: null;
	const hookedOut = runs && poolLeg ? poolLeg.amountOut + d!.fillOut : null;
	const gain = vanilla && hookedOut !== null ? hookedOut - vanilla.amountOut : null;

	const compact = (v: bigint) => {
		const s = v.toString();
		return s.length > 12 ? `${s.slice(0, 3)}…e${s.length - 1}` : s;
	};
	const f4 = (v: bigint) => Number(formatUnits(v, 18)).toFixed(4);

	return (
		<div className="flow">
			<div className="flow-controls">
				<label className="field">
					<span>trade size (18 dp)</span>
					<input className="mono" value={amountIn} onChange={(e) => setAmountIn(e.target.value)} inputMode="decimal" />
				</label>
				<label className="field">
					<span>direction</span>
					<select className="mono" value={zeroForOne ? '0' : '1'} onChange={(e) => setZeroForOne(e.target.value === '0')}>
						<option value="0">currency0 → currency1</option>
						<option value="1">currency1 → currency0</option>
					</select>
				</label>
			</div>

			{previewError && (
				<Note tone="warn">preview reverted — {previewError.message.split('\n')[0]}.</Note>
			)}

			<ol className="flow-track">
				<Node n="0" title="Pool state" state={priceNow ? 'on' : 'idle'}>
					<Line k="price" v={priceNow ? priceNow.toPrecision(6) : '—'} />
					<Line k="liquidity" v={liquidity !== undefined ? compact(liquidity) : '—'} />
					{liquidity === 0n && <span className="flow-warn">no in-range liquidity</span>}
				</Node>

				<Node n="1" title="beforeSwap · decision" state={runs ? 'on' : amount > 0n ? 'skip' : 'idle'}>
					{runs ? (
						<>
							<Line k="bidders" v={String(nQuoters)} />
							<Line k="winner" v={<Addr value={d!.winner} />} />
							<Line k="runner-up belief" v={d!.secondPriceWad > 0n ? f4(d!.secondPriceWad) : 'lone bidder'} />
							<Line
								k="vanilla end px"
								v={d!.vanillaEndSqrtPriceX96 > 0n ? sqrtPriceX96ToPrice(d!.vanillaEndSqrtPriceX96).toPrecision(6) : '—'}
							/>
							<span className="flow-warn">swap pushes price away from the belief region</span>
						</>
					) : (
						<span className="dim">
							{amount > 0n ? 'belief region is not on your favourable side — hook stays inert' : 'enter a trade'}
						</span>
					)}
				</Node>

				<Node n="2" title="Partial fill" state={runs ? 'on' : 'idle'}>
					{runs ? (
						<>
							<Line k="hook fills" v={`${f4(d!.fillIn)} → ${f4(d!.fillOut)}`} />
							<Line k="fill price" v={Number(formatUnits(d!.hookPriceWad, 18)).toPrecision(6)} />
							<Line k="rest to pool" v={f4(amount - d!.fillIn)} />
						</>
					) : (
						<span className="dim">whole order routes to the pool unchanged</span>
					)}
				</Node>

				<Node n="3" title="Your execution" state={runs ? 'on' : amount > 0n ? 'skip' : 'idle'}>
					<Line k="vanilla out" v={vanilla ? f4(vanilla.amountOut) : '—'} />
					<Line k="hooked out" v={hookedOut !== null ? f4(hookedOut) : runs ? '…' : '—'} />
					{gain !== null && gain > 0n && <span className="flow-ok">+{f4(gain)} vs vanilla</span>}
					{!runs && amount > 0n && <span className="dim">identical to the plain pool</span>}
				</Node>

				<Node n="4" title="Inventory & sweep" state={runs ? 'on' : 'idle'}>
					{runs ? (
						<>
							<Line k="hook holds" v={`${f4(d!.fillIn)} ${zeroForOne ? 'currency0' : 'currency1'}`} />
							<span className="flow-ok">
								a solver sweeps it at the runner-up belief → buffer refilled, surplus donated to LPs
							</span>
						</>
					) : (
						<span className="dim">nothing accrued</span>
					)}
				</Node>
			</ol>

			<div className="flow-ledger">
				<div>
					<span className="flow-ledger-h">On a plain pool</span>
					<Line k="you get" v={vanilla ? f4(vanilla.amountOut) : '—'} />
					<Line k="LPs get" v="swap fee only" />
					<Line k="solver keeps" v="the full mispricing" />
				</div>
				<div className="flow-ledger-lit">
					<span className="flow-ledger-h">On this pool</span>
					<Line k="you get" v={hookedOut !== null ? `${f4(hookedOut)}  ≥ vanilla` : runs ? '…' : '—'} />
					<Line k="LPs get" v={runs ? 'swap fee + sweep surplus' : 'swap fee only'} />
					<Line k="solver keeps" v={runs ? 'φ₁ − φ₂  → 0 as bidders grow' : '—'} />
				</div>
			</div>
		</div>
	);
}

function Node({
	n,
	title,
	state,
	children,
}: {
	n: string;
	title: string;
	state: 'idle' | 'on' | 'skip';
	children: React.ReactNode;
}) {
	return (
		<li className={`flow-node flow-node-${state}`}>
			<span className="flow-node-n">{n}</span>
			<h4>{title}</h4>
			<div className="flow-node-body">{children}</div>
		</li>
	);
}

function Line({ k, v }: { k: string; v: React.ReactNode }) {
	return (
		<div className="flow-line">
			<span className="dim">{k}</span>
			<span className="mono">{v}</span>
		</div>
	);
}
