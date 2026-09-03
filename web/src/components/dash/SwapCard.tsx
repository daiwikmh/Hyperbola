import { useMemo, useState } from 'react';
import { formatUnits, maxUint256, parseUnits, type Address } from 'viem';
import { useAccount, useReadContract, useSwitchChain, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { erc20Abi } from '../../lib/deployment';
import { boundedSwapLimit, quoteExactInputSingle, sqrtPriceX96ToPrice, type PoolKey } from '../../lib/pool';
import { stateViewAbi, swapRouterAbi, v4ByChain } from '../../lib/v4';
import { REQUIRED_CHAIN } from '../../lib/wagmi';
import { Note, TxState } from './ui';

type Props = { poolKey: PoolKey; poolId: `0x${string}` };

export function SwapCard({ poolKey, poolId }: Props) {
	const { address, isConnected, chainId } = useAccount();
	const { switchChain } = useSwitchChain();
	const wrongNet = isConnected && chainId !== REQUIRED_CHAIN.id;
	const v4 = v4ByChain[REQUIRED_CHAIN.id];

	const [payToken, setPayToken] = useState<Address>(poolKey.currency0);
	const [amountIn, setAmountIn] = useState('');
	const [showSettings, setShowSettings] = useState(false);
	const [slippage, setSlippage] = useState('10');

	const zeroForOne = payToken === poolKey.currency0;
	const recvToken = zeroForOne ? poolKey.currency1 : poolKey.currency0;

	const pay = useToken(payToken);
	const recv = useToken(recvToken);

	const amount = useMemo(() => {
		try {
			return parseUnits(amountIn || '0', pay.decimals);
		} catch {
			return 0n;
		}
	}, [amountIn, pay.decimals]);

	const { data: slot0 } = useReadContract({
		address: v4?.stateView,
		abi: stateViewAbi,
		functionName: 'getSlot0',
		args: [poolId],
		query: { enabled: !!v4?.stateView, refetchInterval: 8000 },
	});
	const { data: liquidity } = useReadContract({
		address: v4?.stateView,
		abi: stateViewAbi,
		functionName: 'getLiquidity',
		args: [poolId],
		query: { enabled: !!v4?.stateView, refetchInterval: 8000 },
	});

	const sqrtPriceX96 = slot0?.[0];
	const quote =
		sqrtPriceX96 && liquidity !== undefined && amount > 0n
			? quoteExactInputSingle(sqrtPriceX96, liquidity, amount, zeroForOne, poolKey.fee)
			: null;

	const { data: allowance } = useReadContract({
		address: payToken,
		abi: erc20Abi,
		functionName: 'allowance',
		args: address && v4?.swapRouter ? [address, v4.swapRouter] : undefined,
		query: { enabled: !!address && !!v4?.swapRouter, refetchInterval: 8000 },
	});
	const needsApproval = amount > 0n && ((allowance as bigint | undefined) ?? 0n) < amount;

	const { writeContract, data: hash, error, isPending, reset } = useWriteContract();
	const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash });

	const priceNow = sqrtPriceX96 ? sqrtPriceX96ToPrice(sqrtPriceX96) : null;
	const limit = (() => {
		if (!quote) {
			return sqrtPriceX96 ? boundedSwapLimit(sqrtPriceX96, zeroForOne) : zeroForOne ? 4295128740n : 0n;
		}
		const bps = BigInt(Math.round(Number(slippage || '0') * 100));
		return zeroForOne
			? (quote.sqrtPriceX96After * (10_000n - bps)) / 10_000n
			: (quote.sqrtPriceX96After * (10_000n + bps)) / 10_000n;
	})();

	const doSwap = () => {
		reset();
		writeContract({
			chainId: REQUIRED_CHAIN.id,
			gas: 6_000_000n,
			address: v4.swapRouter,
			abi: swapRouterAbi,
			functionName: 'swap',
			args: [
				poolKey,
				{ zeroForOne, amountSpecified: -amount, sqrtPriceLimitX96: limit },
				{ takeClaims: false, settleUsingBurn: false },
				'0x',
			],
		});
	};

	const disabled = !address || amount === 0n || wrongNet;

	return (
		<div className="swap-card">
			<div className="swap-head">
				<span>Swap</span>
				<div className="swap-head-right">
					<span className={wrongNet ? 'chain-pill nav-net-warn' : 'chain-pill'}>{REQUIRED_CHAIN.name}</span>
					<button type="button" className="gear" onClick={() => setShowSettings((s) => !s)} aria-label="settings">
						⚙
					</button>
				</div>
			</div>

			{showSettings && (
				<label className="swap-setting">
					<span>max slippage — the room the hook has to front-run</span>
					<span>
						<input value={slippage} onChange={(e) => setSlippage(e.target.value)} inputMode="decimal" /> %
					</span>
				</label>
			)}

			<div className="swap-leg">
				<div className="swap-leg-top">
					<span>You pay</span>
					<span className="dim">
						Balance {pay.balance !== undefined ? Number(formatUnits(pay.balance, pay.decimals)).toFixed(4) : '—'}
					</span>
				</div>
				<div className="swap-leg-row">
					<input
						className="swap-amount"
						placeholder="0"
						value={amountIn}
						inputMode="decimal"
						onChange={(e) => setAmountIn(e.target.value)}
					/>
					<TokenPill symbol={pay.symbol} />
				</div>
				<span className="dim swap-usd">
					{priceNow && amount > 0n
						? `≈ ${(Number(formatUnits(amount, pay.decimals)) * (zeroForOne ? priceNow : 1 / priceNow)).toFixed(2)}`
						: '≈ 0.00'}
				</span>
			</div>

			<button
				type="button"
				className="swap-flip"
				onClick={() => setPayToken(recvToken)}
				aria-label="flip direction"
			>
				↓
			</button>

			<div className="swap-leg">
				<div className="swap-leg-top">
					<span>You receive</span>
					<span className="dim">
						Balance {recv.balance !== undefined ? Number(formatUnits(recv.balance, recv.decimals)).toFixed(4) : '—'}
					</span>
				</div>
				<div className="swap-leg-row">
					<input
						className="swap-amount"
						placeholder="0"
						readOnly
						value={quote ? Number(formatUnits(quote.amountOut, recv.decimals)).toFixed(6) : '0'}
					/>
					<TokenPill symbol={recv.symbol} />
				</div>
				<span className="dim swap-usd">estimate · plain-pool baseline, before the hook</span>
			</div>

			{sqrtPriceX96 !== undefined && liquidity === 0n && (
				<Note tone="warn">Pool has no liquidity — add some in the Pools section first.</Note>
			)}
			{wrongNet && <Note tone="warn">Your wallet is on the wrong network.</Note>}

			{wrongNet ? (
				<button type="button" className="swap-cta" onClick={() => switchChain({ chainId: REQUIRED_CHAIN.id })}>
					Switch to {REQUIRED_CHAIN.name}
				</button>
			) : needsApproval ? (
				<button
					type="button"
					className="swap-cta"
					disabled={!address}
					onClick={() => {
						reset();
						writeContract({
							chainId: REQUIRED_CHAIN.id,
							gas: 120_000n,
							address: payToken,
							abi: erc20Abi,
							functionName: 'approve',
							args: [v4.swapRouter, maxUint256],
						});
					}}
				>
					{isPending ? 'Approving…' : `Approve ${pay.symbol ?? ''}`}
				</button>
			) : (
				<button type="button" className="swap-cta" disabled={disabled} onClick={doSwap}>
					{!address ? 'Connect Wallet' : isPending ? 'Swapping…' : 'Swap'}
				</button>
			)}

			<TxState hash={hash} error={error} confirming={confirming} confirmed={confirmed} />
		</div>
	);
}

function TokenPill({ symbol }: { symbol?: string }) {
	return (
		<span className="token-pill">
			<span className="token-dot" />
			{symbol ?? '—'}
		</span>
	);
}

function useToken(token: Address) {
	const { address } = useAccount();
	const { data: symbol } = useReadContract({ address: token, abi: erc20Abi, functionName: 'symbol' });
	const { data: decimals } = useReadContract({ address: token, abi: erc20Abi, functionName: 'decimals' });
	const { data: balance } = useReadContract({
		address: token,
		abi: erc20Abi,
		functionName: 'balanceOf',
		args: address ? [address] : undefined,
		query: { enabled: !!address, refetchInterval: 8000 },
	});
	return {
		symbol: symbol as string | undefined,
		decimals: (decimals as number | undefined) ?? 18,
		balance: balance as bigint | undefined,
	};
}
