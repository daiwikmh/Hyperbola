import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';
import { WagmiProvider, useAccount, useChainId, useConnect, useDisconnect, useSwitchChain } from 'wagmi';
import { EMPTY, isAddress, poolKeyFrom, useDeployment, type Deployment } from '../../lib/deployment';
import { sortCurrencies, toPoolId } from '../../lib/pool';
import { chains, config, poolManagerByChain } from '../../lib/wagmi';
import { AuctionPreview, LvrPanel } from './Auction';
import { StakeAndQuote, VaultPanel } from './Arbitrageur';
import { QuoteBook } from './QuoteBook';
import { Addr, Btn, Field, Note, Panel, Row } from './ui';

const queryClient = new QueryClient();

export default function Dashboard() {
	return (
		<WagmiProvider config={config}>
			<QueryClientProvider client={queryClient}>
				<Inner />
			</QueryClientProvider>
		</WagmiProvider>
	);
}

function Inner() {
	const { deployment, save, loaded } = useDeployment();
	if (!loaded) return null;
	return <Body deployment={deployment} save={save} />;
}

function Body({ deployment, save }: { deployment: Deployment; save: (d: Deployment) => void }) {
	const poolKey = poolKeyFrom(deployment);
	const poolId = poolKey ? toPoolId(poolKey) : null;

	return (
		<div className="dash">
			<Header />
			<div className="grid">
				<Config deployment={deployment} save={save} poolId={poolId} />

				{poolKey && poolId && isAddress(deployment.hook) ? (
					<AuctionPreview hook={deployment.hook} poolKey={poolKey} />
				) : (
					<Panel title="Auction preview" wide>
						<Note>Set the hook address and both pool currencies to preview an auction.</Note>
					</Panel>
				)}

				{poolId && isAddress(deployment.registry) ? (
					<QuoteBook registry={deployment.registry} poolId={poolId} />
				) : (
					<Panel title="Quote book" wide>
						<Note>Set the registry address and pool currencies to read the book.</Note>
					</Panel>
				)}

				{poolId && isAddress(deployment.registry) && (
					<StakeAndQuote registry={deployment.registry} poolId={poolId} />
				)}

				{isAddress(deployment.vault) && isAddress(deployment.pool.currency0) && isAddress(deployment.pool.currency1) && (
					<VaultPanel
						vault={deployment.vault}
						currency0={deployment.pool.currency0}
						currency1={deployment.pool.currency1}
					/>
				)}

				{poolKey && isAddress(deployment.hook) && <LvrPanel hook={deployment.hook} poolKey={poolKey} />}
			</div>
		</div>
	);
}

function Header() {
	const { address, isConnected } = useAccount();
	const { connect, connectors, isPending } = useConnect();
	const { disconnect } = useDisconnect();
	const chainId = useChainId();
	const { switchChain } = useSwitchChain();

	return (
		<header className="dash-bar">
			<a className="mark" href="/">
				Hyberbola
			</a>
			<span className="dash-title">hook console</span>

			<div className="dash-actions">
				<select
					className="mono"
					value={chainId}
					onChange={(e) => switchChain({ chainId: Number(e.target.value) as (typeof chains)[number]['id'] })}
				>
					{chains.map((c) => (
						<option key={c.id} value={c.id}>
							{c.name}
						</option>
					))}
				</select>

				{isConnected ? (
					<>
						<span className="mono dim">
							<Addr value={address} />
						</span>
						<Btn onClick={() => disconnect()}>disconnect</Btn>
					</>
				) : (
					<Btn
						primary
						busy={isPending}
						disabled={connectors.length === 0}
						onClick={() => connectors[0] && connect({ connector: connectors[0] })}
					>
						connect wallet
					</Btn>
				)}
			</div>
		</header>
	);
}

function Config({
	deployment,
	save,
	poolId,
}: {
	deployment: Deployment;
	save: (d: Deployment) => void;
	poolId: string | null;
}) {
	const chainId = useChainId();
	const [draft, setDraft] = useState(deployment);
	const poolManager = poolManagerByChain[chainId];

	const set = (patch: Partial<Deployment>) => setDraft({ ...draft, ...patch });
	const setPool = (patch: Partial<Deployment['pool']>) => setDraft({ ...draft, pool: { ...draft.pool, ...patch } });

	const sortWarning =
		isAddress(draft.pool.currency0) &&
		isAddress(draft.pool.currency1) &&
		BigInt(draft.pool.currency0) >= BigInt(draft.pool.currency1);

	return (
		<Panel
			title="Deployment"
			hint="Nothing is deployed yet — run script/Deploy.s.sol, then paste the three addresses it logs. Saved to this browser only."
			wide
		>
			<div className="controls">
				<Field label="hook" value={draft.hook} onChange={(v) => set({ hook: v as never })} placeholder="0x…" mono />
				<Field
					label="registry"
					value={draft.registry}
					onChange={(v) => set({ registry: v as never })}
					placeholder="0x…"
					mono
				/>
				<Field label="vault" value={draft.vault} onChange={(v) => set({ vault: v as never })} placeholder="0x…" mono />
			</div>

			<div className="controls">
				<Field
					label="currency0"
					value={draft.pool.currency0}
					onChange={(v) => setPool({ currency0: v as never })}
					placeholder="0x…"
					mono
				/>
				<Field
					label="currency1"
					value={draft.pool.currency1}
					onChange={(v) => setPool({ currency1: v as never })}
					placeholder="0x…"
					mono
				/>
				<Field label="fee" value={draft.pool.fee} onChange={(v) => setPool({ fee: v })} mono />
				<Field
					label="tickSpacing"
					value={draft.pool.tickSpacing}
					onChange={(v) => setPool({ tickSpacing: v })}
					mono
				/>
			</div>

			{sortWarning && (
				<Note tone="warn">
					currency0 must sort below currency1 or the pool id will not match.{' '}
					<button
						type="button"
						className="link"
						onClick={() => {
							const [a, b] = sortCurrencies(draft.pool.currency0 as never, draft.pool.currency1 as never);
							setPool({ currency0: a, currency1: b });
						}}
					>
						swap them
					</button>
				</Note>
			)}

			<div className="btn-row">
				<Btn primary onClick={() => save(draft)}>
					save
				</Btn>
				<Btn
					onClick={() => {
						setDraft(EMPTY);
						save(EMPTY);
					}}
				>
					clear
				</Btn>
			</div>

			<Row label="pool id">
				{poolId ? <span className="mono">{poolId}</span> : <span className="dim">incomplete</span>}
			</Row>
			<Row label="PoolManager">
				{poolManager ? <Addr value={poolManager} /> : <span className="dim">unknown for this chain</span>}
			</Row>
		</Panel>
	);
}
