import { formatUnits, parseUnits, type Address } from 'viem';
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { erc20Abi } from '../../lib/deployment';
import { REQUIRED_CHAIN } from '../../lib/wagmi';
import { Btn, Note, Panel, Row, TxState } from './ui';

const AMOUNT = parseUnits('100000', 18);

export function Faucet({ currency0, currency1 }: { currency0: Address; currency1: Address }) {
	const { address, isConnected, chainId } = useAccount();
	const wrongNet = isConnected && chainId !== REQUIRED_CHAIN.id;

	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const bal0 = useBalance(currency0, address);
	const bal1 = useBalance(currency1, address);
	const sym0 = useSymbol(currency0);
	const sym1 = useSymbol(currency1);

	const mint = (token: Address) => {
		reset();
		writeContract({
			chainId: REQUIRED_CHAIN.id,
			gas: 120_000n,
			address: token,
			abi: erc20Abi,
			functionName: 'mint',
			args: [address as Address, AMOUNT],
		});
	};

	return (
		<Panel title="Faucet" hint="These are mock test tokens with an open mint. Grab some to trade or to fund an arbitrageur.">
			<Row label={sym0 ?? 'currency0'}>
				<span className="mono">{bal0 !== undefined ? Number(formatUnits(bal0, 18)).toFixed(2) : '—'}</span>
			</Row>
			<Row label={sym1 ?? 'currency1'}>
				<span className="mono">{bal1 !== undefined ? Number(formatUnits(bal1, 18)).toFixed(2) : '—'}</span>
			</Row>

			{wrongNet && <Note tone="warn">Wallet is on the wrong network.</Note>}

			<div className="btn-row">
				<Btn primary busy={isPending} disabled={!address || wrongNet} onClick={() => mint(currency0)}>
					mint 100k {sym0 ?? ''}
				</Btn>
				<Btn busy={isPending} disabled={!address || wrongNet} onClick={() => mint(currency1)}>
					mint 100k {sym1 ?? ''}
				</Btn>
			</div>

			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</Panel>
	);
}

function useBalance(token: Address, owner?: Address) {
	const { data } = useReadContract({
		address: token,
		abi: erc20Abi,
		functionName: 'balanceOf',
		args: owner ? [owner] : undefined,
		query: { enabled: !!owner, refetchInterval: 8000 },
	});
	return data as bigint | undefined;
}

function useSymbol(token: Address) {
	const { data } = useReadContract({ address: token, abi: erc20Abi, functionName: 'symbol' });
	return data as string | undefined;
}
