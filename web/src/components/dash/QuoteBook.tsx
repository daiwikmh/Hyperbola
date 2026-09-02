import { formatEther, type Address, type Hex } from 'viem';
import { useReadContract, useReadContracts } from 'wagmi';
import { registryAbi } from '../../lib/abis';
import { Addr, Note, Panel } from './ui';

type Props = { registry: Address; poolId: Hex };

export function QuoteBook({ registry, poolId }: Props) {
	const base = { address: registry, abi: registryAbi } as const;

	const { data: quoters } = useReadContract({
		...base,
		functionName: 'activeQuoters',
		args: [poolId],
		query: { refetchInterval: 8000 },
	});

	const list = (quoters ?? []) as readonly Address[];

	const { data: rows, error: rowsError } = useReadContracts({
		contracts: list.flatMap((who) => [
			{ ...base, functionName: 'quoteOf', args: [poolId, who] } as const,
			{ ...base, functionName: 'stakeOf', args: [who] } as const,
			{ ...base, functionName: 'isLive', args: [poolId, who] } as const,
		]),
		query: { enabled: list.length > 0, refetchInterval: 8000 },
	});

	const rowFailure = rowsError ?? rows?.find((r) => r.status === 'failure')?.error;

	const { data: bestX } = useReadContract({
		...base,
		functionName: 'bestForXForY',
		args: [poolId],
		query: { refetchInterval: 8000 },
	});
	const { data: bestY } = useReadContract({
		...base,
		functionName: 'bestForYForX',
		args: [poolId],
		query: { refetchInterval: 8000 },
	});

	const now = BigInt(Math.floor(Date.now() / 1000));

	return (
		<Panel
			title="Quote book"
			hint="Live beliefs posted against this pool. bestForXForY takes the highest price, bestForYForX the lowest — each returns the runner-up too, because that is what the winner pays."
			wide
		>
			{rowFailure && (
				<Note tone="warn">
					Quote detail reads failed — {rowFailure.message.split('\n')[0]}. On a bare anvil this usually means
					Multicall3 is missing at 0xcA11bde05977b3631167028862bE2a173976CA11.
				</Note>
			)}

			{list.length === 0 ? (
				<Note>No quoters registered for this pool yet.</Note>
			) : (
				<table>
					<thead>
						<tr>
							<th>arbitrageur</th>
							<th>price (wad)</th>
							<th>expires in</th>
							<th>stake</th>
							<th>live</th>
						</tr>
					</thead>
					<tbody>
						{list.map((who, i) => {
							const quote = rows?.[i * 3]?.result as readonly [bigint, bigint] | undefined;
							const price = quote?.[0];
							const expiry = quote?.[1];
							const stake = rows?.[i * 3 + 1]?.result as bigint | undefined;
							const live = rows?.[i * 3 + 2]?.result as boolean | undefined;
							const left = expiry !== undefined ? Number(expiry - now) : null;
							return (
								<tr key={who}>
									<td>
										<Addr value={who} />
									</td>
									<td className="mono">{price !== undefined ? price.toString() : '—'}</td>
									<td className="mono">
										{left === null ? '—' : left > 0 ? `${left}s` : <span className="dim">expired</span>}
									</td>
									<td className="mono">{stake !== undefined ? `${formatEther(stake)} ETH` : '—'}</td>
									<td>{live ? <span className="ok">yes</span> : <span className="dim">no</span>}</td>
								</tr>
							);
						})}
					</tbody>
				</table>
			)}

			<div className="best">
				<Best label="best · X for Y" data={bestX} />
				<Best label="best · Y for X" data={bestY} />
			</div>
		</Panel>
	);
}

function Best({
	label,
	data,
}: {
	label: string;
	data?: readonly [boolean, Address, bigint, Address, bigint];
}) {
	if (!data || !data[0]) {
		return (
			<div className="best-card">
				<span className="row-label">{label}</span>
				<Note>no live quote</Note>
			</div>
		);
	}
	const [, winner, winnerPrice, second, secondPrice] = data;
	return (
		<div className="best-card">
			<span className="row-label">{label}</span>
			<div className="row">
				<span className="row-label">winner</span>
				<span className="row-value">
					<Addr value={winner} /> <span className="mono dim">{winnerPrice.toString()}</span>
				</span>
			</div>
			<div className="row">
				<span className="row-label">second</span>
				<span className="row-value">
					<Addr value={second} /> <span className="mono dim">{secondPrice.toString()}</span>
				</span>
			</div>
		</div>
	);
}
