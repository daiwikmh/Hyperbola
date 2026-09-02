import { useState } from 'react';
import { formatEther, formatUnits, parseEther, parseUnits, type Address, type Hex } from 'viem';
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { registryAbi, vaultAbi } from '../../lib/abis';
import { erc20Abi } from '../../lib/deployment';
import { Addr, Btn, Field, Note, Panel, Row, TxState } from './ui';

export function StakeAndQuote({ registry, poolId }: { registry: Address; poolId: Hex }) {
	const { address } = useAccount();
	const [stakeAmount, setStakeAmount] = useState('0.1');
	const [price, setPrice] = useState('');
	const [minutes, setMinutes] = useState('5');

	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const base = { address: registry, abi: registryAbi } as const;

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
							writeContract({ ...base, functionName: 'stake', value: parseEther(stakeAmount || '0') });
						}}
					>
						stake
					</Btn>
					<Btn
						disabled={!address}
						onClick={() => {
							reset();
							writeContract({ ...base, functionName: 'unstake', args: [parseEther(stakeAmount || '0')] });
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
							writeContract({ ...base, functionName: 'postQuote', args: [poolId, BigInt(price), expiry] });
						}}
					>
						post quote
					</Btn>
					<Btn
						disabled={!address}
						onClick={() => {
							reset();
							writeContract({ ...base, functionName: 'withdrawQuote', args: [poolId] });
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

export function VaultPanel({
	vault,
	currency0,
	currency1,
}: {
	vault: Address;
	currency0: Address;
	currency1: Address;
}) {
	const { address } = useAccount();
	const [token, setToken] = useState<Address>(currency0);
	const [amount, setAmount] = useState('');

	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const { data: decimals } = useReadContract({ address: token, abi: erc20Abi, functionName: 'decimals' });
	const { data: symbol } = useReadContract({ address: token, abi: erc20Abi, functionName: 'symbol' });
	const dp = (decimals as number | undefined) ?? 18;

	const { data: bal0 } = useReadContract({
		address: vault,
		abi: vaultAbi,
		functionName: 'balanceOf',
		args: address ? [address, currency0] : undefined,
		query: { enabled: !!address, refetchInterval: 8000 },
	});
	const { data: bal1 } = useReadContract({
		address: vault,
		abi: vaultAbi,
		functionName: 'balanceOf',
		args: address ? [address, currency1] : undefined,
		query: { enabled: !!address, refetchInterval: 8000 },
	});
	const { data: allowance } = useReadContract({
		address: token,
		abi: erc20Abi,
		functionName: 'allowance',
		args: address ? [address, vault] : undefined,
		query: { enabled: !!address, refetchInterval: 8000 },
	});

	const wanted = amount ? parseUnits(amount, dp) : 0n;
	const needsApproval = wanted > 0n && ((allowance as bigint | undefined) ?? 0n) < wanted;

	return (
		<Panel
			title="Vault"
			hint="Working capital the hook pulls from when you win. It is only ever moved inside a bundle and credited straight back afterwards."
		>
			<Row label="currency0">
				<span className="mono">{bal0 !== undefined ? formatUnits(bal0 as bigint, dp) : '—'}</span>
			</Row>
			<Row label="currency1">
				<span className="mono">{bal1 !== undefined ? formatUnits(bal1 as bigint, dp) : '—'}</span>
			</Row>

			<div className="controls">
				<label className="field">
					<span>token</span>
					<select className="mono" value={token} onChange={(e) => setToken(e.target.value as Address)}>
						<option value={currency0}>currency0</option>
						<option value={currency1}>currency1</option>
					</select>
				</label>
				<Field label={`amount${symbol ? ` (${symbol})` : ''}`} value={amount} onChange={setAmount} mono />
				<div className="btn-row">
					{needsApproval ? (
						<Btn
							primary
							busy={isPending}
							disabled={!address}
							onClick={() => {
								reset();
								writeContract({ address: token, abi: erc20Abi, functionName: 'approve', args: [vault, wanted] });
							}}
						>
							approve
						</Btn>
					) : (
						<Btn
							primary
							busy={isPending}
							disabled={!address || wanted === 0n}
							onClick={() => {
								reset();
								writeContract({ address: vault, abi: vaultAbi, functionName: 'deposit', args: [token, wanted] });
							}}
						>
							deposit
						</Btn>
					)}
					<Btn
						disabled={!address || wanted === 0n}
						onClick={() => {
							reset();
							writeContract({ address: vault, abi: vaultAbi, functionName: 'withdraw', args: [token, wanted] });
						}}
					>
						withdraw
					</Btn>
				</div>
			</div>

			<Row label="vault hook">
				<VaultHook vault={vault} />
			</Row>

			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</Panel>
	);
}

function VaultHook({ vault }: { vault: Address }) {
	const { data } = useReadContract({ address: vault, abi: vaultAbi, functionName: 'hook' });
	return <Addr value={data as string | undefined} />;
}
