import { useState } from 'react';
import { formatEther, formatUnits, maxUint256, parseEther, type Address, type Hex } from 'viem';
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { hookAbi, registryAbi } from '../../lib/abis';
import { erc20Abi } from '../../lib/deployment';
import { REQUIRED_CHAIN } from '../../lib/wagmi';
import { Addr, Btn, Field, Note, Panel, Row, TxState } from './ui';

export function StakeAndQuote({ registry, poolId }: { registry: Address; poolId: Hex }) {
	const { address } = useAccount();
	const [stakeAmount, setStakeAmount] = useState('0.1');
	const [price, setPrice] = useState('');
	const [minutes, setMinutes] = useState('5');

	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const base = { address: registry, abi: registryAbi, chainId: REQUIRED_CHAIN.id } as const;

	const { data: stake } = useReadContract({
		...base,
		functionName: 'stakeOf',
		args: address ? [address] : undefined,
		query: { enabled: !!address, refetchInterval: 8000 },
	});
	const { data: minStake } = useReadContract({ ...base, functionName: 'MIN_STAKE' });
	const { data: quote } = useReadContract({
		...base,
		functionName: 'quoteOf',
		args: address ? [poolId, address] : undefined,
		query: { enabled: !!address, refetchInterval: 8000 },
	});

	const q = quote as readonly [bigint, bigint] | undefined;
	const staked = (stake as bigint | undefined) ?? 0n;
	const min = (minStake as bigint | undefined) ?? 0n;
	const belowMin = min > 0n && staked < min;

	return (
		<Panel
			title="Your position"
			hint="Stake ETH, then post the price you believe this pair is worth. The hook scores that belief against each incoming swap."
		>
			<Row label="staked">
				<span className="mono">{formatEther(staked)} ETH</span>
			</Row>
			<Row label="minimum">
				<span className="mono">{formatEther(min)} ETH</span>
			</Row>
			<Row label="your quote">
				{q && q[1] > 0n ? (
					<span className="mono">
						{q[0].toString()} · expires {new Date(Number(q[1]) * 1000).toLocaleTimeString()}
					</span>
				) : (
					<span className="dim">none</span>
				)}
			</Row>

			{belowMin && <Note tone="warn">Stake is below MIN_STAKE — your quotes will not count as live.</Note>}

			<div className="controls">
				<Field label="stake / unstake (ETH)" value={stakeAmount} onChange={setStakeAmount} mono />
				<div className="btn-row">
					<Btn
						primary
						busy={isPending}
						disabled={!address}
						onClick={() => {
							reset();
							writeContract({ ...base, gas: 120_000n, functionName: 'stake', value: parseEther(stakeAmount || '0') });
						}}
					>
						stake
					</Btn>
					<Btn
						disabled={!address}
						onClick={() => {
							reset();
							writeContract({ ...base, gas: 150_000n, functionName: 'unstake', args: [parseEther(stakeAmount || '0')] });
						}}
					>
						unstake
					</Btn>
				</div>
			</div>

			<div className="controls">
				<Field label="price, wad (1e18 = 1.0)" value={price} onChange={setPrice} placeholder="1000000000000000000" mono />
				<Field label="expires in (minutes, max 5)" value={minutes} onChange={setMinutes} mono />
				<div className="btn-row">
					<Btn
						primary
						busy={isPending}
						disabled={!address || !price}
						onClick={() => {
							reset();
							const expiry = BigInt(Math.floor(Date.now() / 1000) + Number(minutes || '1') * 60);
							writeContract({ ...base, gas: 300_000n, functionName: 'postQuote', args: [poolId, BigInt(price), expiry] });
						}}
					>
						post quote
					</Btn>
					<Btn
						disabled={!address}
						onClick={() => {
							reset();
							writeContract({ ...base, gas: 200_000n, functionName: 'withdrawQuote', args: [poolId] });
						}}
					>
						withdraw quote
					</Btn>
				</div>
			</div>

			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</Panel>
	);
}

export function HookInventoryPanel({
	hook,
	currency0,
	currency1,
}: {
	hook: Address;
	currency0: Address;
	currency1: Address;
}) {
	const { address } = useAccount();
	const [amount, setAmount] = useState('1000');
	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const base = { address: hook, abi: hookAbi, query: { refetchInterval: 8000 } } as const;
	const bufferC0 = useReadContract({ ...base, functionName: 'buffer', args: [currency0] });
	const bufferC1 = useReadContract({ ...base, functionName: 'buffer', args: [currency1] });
	const invC0 = useReadContract({ ...base, functionName: 'inventory', args: [currency0] });
	const invC1 = useReadContract({ ...base, functionName: 'inventory', args: [currency1] });
	const spentC0 = useReadContract({ ...base, functionName: 'spent', args: [currency0] });
	const spentC1 = useReadContract({ ...base, functionName: 'spent', args: [currency1] });

	const cells = [
		{ label: 'buffer c0', q: bufferC0 },
		{ label: 'buffer c1', q: bufferC1 },
		{ label: 'inventory c0', q: invC0 },
		{ label: 'inventory c1', q: invC1 },
		{ label: 'spent c0', q: spentC0 },
		{ label: 'spent c1', q: spentC1 },
	];

	const fund = (c: Address) => {
		reset();
		writeContract({
			chainId: REQUIRED_CHAIN.id,
			gas: 90_000n,
			address: c,
			abi: erc20Abi,
			functionName: 'approve',
			args: [hook, maxUint256],
		});
		writeContract({
			chainId: REQUIRED_CHAIN.id,
			gas: 120_000n,
			address: hook,
			abi: hookAbi,
			functionName: 'fundBuffer',
			args: [c, parseEther(amount || '0')],
		});
	};

	return (
		<Panel
			title="Hook inventory"
			hint="The hook's shared capital. It fills part of an away-from-fair swap from buffer, holds the acquired token as inventory, and refills the buffer when a solver sweeps. spent is the cost basis of the current inventory."
		>
			{cells.map((cell) => (
				<Row key={cell.label} label={cell.label}>
					<span className="mono">
						{cell.q.data !== undefined ? formatUnits(cell.q.data as bigint, 18) : '—'}
					</span>
				</Row>
			))}

			<div className="controls">
				<Field label="fund buffer (18 dp)" value={amount} onChange={setAmount} mono />
				<div className="btn-row">
					<Btn primary busy={isPending} disabled={!address} onClick={() => fund(currency0)}>
						fund c0
					</Btn>
					<Btn busy={isPending} disabled={!address} onClick={() => fund(currency1)}>
						fund c1
					</Btn>
				</div>
			</div>
			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</Panel>
	);
}
