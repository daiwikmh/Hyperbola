import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';
import { WagmiProvider, useAccount, useChainId, useConnect, useDisconnect, useSwitchChain } from 'wagmi';
import { deployedByChain } from '../../lib/deployed';
import { EMPTY, isAddress, poolKeyFrom, useDeployment, type Deployment } from '../../lib/deployment';
import { sortCurrencies, toPoolId } from '../../lib/pool';
import { REQUIRED_CHAIN, config, poolManagerByChain } from '../../lib/wagmi';
import { DecisionPreview, SweepPanel } from './Auction';
import { HookInventoryPanel, StakeAndQuote } from './Arbitrageur';
import { Faucet } from './Faucet';
import { Flow } from './Flow';
import { LiquidityPanel } from './Liquidity';
import { QuoteBook } from './QuoteBook';
import { SwapCard } from './SwapCard';
import { Addr, Btn, Field, Note, Panel, Row } from './ui';

// React 19 dev serializes prop diffs; bigint props otherwise throw.
type WithToJSON = { toJSON?: () => string };
if (typeof (BigInt.prototype as WithToJSON).toJSON !== 'function') {
	(BigInt.prototype as WithToJSON).toJSON = function (this: bigint) {
		return this.toString();
	};
}

export type Page = 'swap' | 'pools' | 'positions' | 'transactions';

const NAV: [Page, string][] = [
	['swap', 'Swap'],
	['pools', 'Pools'],
	['positions', 'Positions'],
	['transactions', 'Transactions'],
];

const queryClient = new QueryClient({
	defaultOptions: {
		queries: {
			queryKeyHashFn: (key) =>
				JSON.stringify(key, (_, v) => (typeof v === 'bigint' ? `#bigint:${v}` : v)),
		},
	},
});

export default function ConsolePage({ page }: { page: Page }) {
	return (
		<WagmiProvider config={config}>
			<QueryClientProvider client={queryClient}>
				<Shell page={page} />
			</QueryClientProvider>
		</WagmiProvider>
	);
}

function Shell({ page }: { page: Page }) {
	const { deployment, save, loaded } = useDeployment();
	const poolKey = poolKeyFrom(deployment);
	const poolId = poolKey ? toPoolId(poolKey) : null;

	return (
		<>
			<Nav page={page} />
			<WrongNetwork />
			<main className="console">{loaded && <Content page={page} deployment={deployment} save={save} poolKey={poolKey} poolId={poolId} />}</main>
			<Footer />
		</>
	);
}

function Content({
	page,
	deployment,
	save,
	poolKey,
	poolId,
}: {
	page: Page;
	deployment: Deployment;
	save: (d: Deployment) => void;
	poolKey: ReturnType<typeof poolKeyFrom>;
	poolId: `0x${string}` | null;
}) {
	if (page === 'swap') {
		return (
			<section>
				<h1 className="page-h">Swap</h1>
				<p className="page-sub">One trade, shown as the pool experiences it — the decision, the partial fill, your execution.</p>
				{poolKey && poolId && isAddress(deployment.hook) ? (
					<div className="hero">
						<SwapCard poolKey={poolKey} poolId={poolId} />
						<Flow
							hook={deployment.hook}
							registry={isAddress(deployment.registry) ? deployment.registry : undefined}
							poolKey={poolKey}
							poolId={poolId}
						/>
					</div>
				) : (
					<Panel title="No deployment" hint="Set the pool on the Pools page — or switch to Unichain Sepolia to load the live one." />
				)}
			</section>
		);
	}

	if (page === 'pools') {
		return (
			<section className="legacy">
				<h1 className="page-h">Pools</h1>
				<p className="page-sub">The deployment this console reads, and the liquidity behind it.</p>
				<div className="grid">
					<Config deployment={deployment} save={save} poolId={poolId} />
					{poolKey && poolId && <LiquidityPanel poolKey={poolKey} poolId={poolId} />}
				</div>
			</section>
		);
	}

	if (page === 'positions') {
		const currencies =
			isAddress(deployment.pool.currency0) && isAddress(deployment.pool.currency1)
				? { c0: deployment.pool.currency0, c1: deployment.pool.currency1 }
				: null;
		return (
			<section>
				<h1 className="page-h">Positions</h1>
				<p className="page-sub">
					To make the hook do something visible on a swap: mint tokens, stake, and post a price you believe (try
					1.05). Two quoters at different prices set the belief region; a swap that pushes price to the far side of
					it gets a partial fill from the hook's buffer.
				</p>
				<div className="grid">
					{currencies && <Faucet currency0={currencies.c0} currency1={currencies.c1} />}
					{poolId && isAddress(deployment.registry) ? (
						<StakeAndQuote registry={deployment.registry} poolId={poolId} />
					) : (
						<Panel title="Stake & quote" hint="Set the registry on the Pools page first." />
					)}
					{isAddress(deployment.hook) &&
					isAddress(deployment.pool.currency0) &&
					isAddress(deployment.pool.currency1) ? (
						<HookInventoryPanel
							hook={deployment.hook}
							currency0={deployment.pool.currency0}
							currency1={deployment.pool.currency1}
						/>
					) : (
						<Panel title="Hook inventory" hint="Set the hook and both currencies on the Pools page first." />
					)}
				</div>
			</section>
		);
	}

	return (
		<section>
			<h1 className="page-h">Transactions</h1>
			<p className="page-sub">The decision the hook runs inside beforeSwap, and the permissionless inventory sweep.</p>
			<div className="grid">
				{poolId && isAddress(deployment.registry) ? (
					<QuoteBook registry={deployment.registry} poolId={poolId} />
				) : (
					<Panel title="Quote book" wide>
						<Note>Set the registry on the Pools page first.</Note>
					</Panel>
				)}
				{poolKey && isAddress(deployment.hook) && <DecisionPreview hook={deployment.hook} poolKey={poolKey} />}
				{poolKey && isAddress(deployment.hook) && <SweepPanel hook={deployment.hook} poolKey={poolKey} />}
			</div>
		</section>
	);
}

function useWrongNetwork() {
	const { isConnected, chainId } = useAccount();
	return isConnected && chainId !== undefined && chainId !== REQUIRED_CHAIN.id;
}

function WrongNetwork() {
	const wrong = useWrongNetwork();
	const { switchChain, isPending } = useSwitchChain();
	if (!wrong) return null;
	return (
		<div className="net-banner">
			<span>
				Wrong network. Every contract is on {REQUIRED_CHAIN.name} — switch your wallet to continue.
			</span>
			<button
				type="button"
				className="btn btn-primary"
				disabled={isPending}
				onClick={() => switchChain({ chainId: REQUIRED_CHAIN.id })}
			>
				{isPending ? 'Switching…' : `Switch to ${REQUIRED_CHAIN.name}`}
			</button>
		</div>
	);
}

function Nav({ page }: { page: Page }) {
	const { address, isConnected } = useAccount();
	const { connect, connectors, isPending } = useConnect();
	const { disconnect } = useDisconnect();
	const { switchChain } = useSwitchChain();
	const wrong = useWrongNetwork();

	return (
		<header className="nav">
			<a className="nav-mark" href="/">
				Hyberbola
			</a>
			<nav className="nav-links">
				{NAV.map(([id, label]) => (
					<a key={id} href={`/${id}`} aria-current={id === page ? 'page' : undefined}>
						{label}
					</a>
				))}
			</nav>
			<input className="nav-search" placeholder="Search pools, tokens…" disabled aria-hidden />
			<div className="nav-right">
				{wrong ? (
					<button type="button" className="btn nav-net-warn" onClick={() => switchChain({ chainId: REQUIRED_CHAIN.id })}>
						⚠ {REQUIRED_CHAIN.name}
					</button>
				) : (
					<span className="chain-pill">{REQUIRED_CHAIN.name}</span>
				)}
				{isConnected ? (
					<>
						<span className="mono dim">
							<Addr value={address} />
						</span>
						<Btn onClick={() => disconnect()}>Disconnect</Btn>
					</>
				) : (
					<Btn
						primary
						busy={isPending}
						disabled={connectors.length === 0}
						onClick={() => connectors[0] && connect({ connector: connectors[0] })}
					>
						Connect
					</Btn>
				)}
			</div>
		</header>
	);
}

function Footer() {
	return (
		<footer className="console-foot">
			<span>
				{REQUIRED_CHAIN.name.toUpperCase()} · CHAIN ID {REQUIRED_CHAIN.id}
			</span>
			<span className="dim">Hyberbola · Uniswap v4 hook</span>
		</footer>
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
	const known = deployedByChain[chainId];

	const set = (patch: Partial<Deployment>) => setDraft({ ...draft, ...patch });
	const setPool = (patch: Partial<Deployment['pool']>) => setDraft({ ...draft, pool: { ...draft.pool, ...patch } });

	const sortWarning =
		isAddress(draft.pool.currency0) &&
		isAddress(draft.pool.currency1) &&
		BigInt(draft.pool.currency0) >= BigInt(draft.pool.currency1);

	return (
		<Panel
			title="Deployment"
			hint="Auto-loaded on Unichain Sepolia. Otherwise run script/Deploy.s.sol and paste the addresses it prints. Saved to this browser only."
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
				{known && (
					<Btn
						onClick={() => {
							setDraft(known);
							save(known);
						}}
					>
						load {REQUIRED_CHAIN.id === chainId ? REQUIRED_CHAIN.name : 'chain'}
					</Btn>
				)}
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
