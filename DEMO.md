# Demoing the hook

The hook (`RediSwapHook`, v3) only does something visible on a swap when there is a **live
quote** for the pool **and** the swap pushes price to the far side of the belief region.
With an empty quote book `preview` returns `intervene: false` and the swap is an ordinary
swap. So a demo is: stand up quoters, then swap and watch the flow on `/swap`.

## What each piece shows

| Setup | Swap `currency0 → currency1` (zeroForOne) | Result |
|---|---|---|
| 0 quoters | any | nothing — hook is inert |
| quotes **below** ~1.0 (e.g. `0.95`) | zeroForOne | nothing — the belief region is not on the swapper's favourable side |
| quotes **above** ~1.0 (e.g. `1.05` and `1.02`) | zeroForOne | hook fills ~30% of the order from its buffer at a price between the pool and `1.02`; the swapper's total output **beats the plain pool**; the hook accrues inventory in `currency0` |

The swapper is never made worse off — the partial fill is priced strictly better than the
pool, and the rest is a smaller (lower-impact) pool swap. The hook's acquired inventory is
cleared later by `sweepInventory`: a solver buys it at the runner-up belief, the buffer is
refilled and the surplus donated to LPs.

## Prerequisites

Every quoter needs, on Unichain Sepolia:

- **`MIN_STAKE` ETH** (currently `0.1`, demo deployment `0.0001`) to stake, plus gas.
- No inventory. Solvers only bring capital when they win a `sweepInventory`, briefly.

The **hook** needs a seeded buffer — `Deploy.s.sol` funds `25_000` of each mock token at
deploy. Top it up any time from `/positions` → **Hook inventory** → *fund buffer*, or by
calling `hook.fundBuffer(currency, amount)` (approve first).

## Path A — one command

`script/SeedDemo.s.sol` deepens liquidity and stands up a quoter per key. Fill
`hyberbola/.env` with the deployed addresses (printed by `Deploy.s.sol`, also in
`web/src/lib/deployed.ts`), then:

```bash
cd hyberbola
export REGISTRY=0x…  HOOK=0x…  CURRENCY0=0x…  CURRENCY1=0x…  FEE=3000  TICK_SPACING=60
export ARB_KEYS=0xkeyA,0xkeyB
export QUOTE_PRICES=1050000000000000000,1020000000000000000   # 1.05 and 1.02, wad
forge script script/SeedDemo.s.sol:SeedDemoScript --rpc-url unichain_sepolia --broadcast
```

Both quotes **above** `1.0` for the `currency0 → currency1` demo. Arb keys short on ETH
are topped up from `PRIVATE_KEY` automatically.

## Deploy knobs

`Deploy.s.sol` reads from `.env`:

- `MAX_FILL_BPS` (default `3000`) — largest fraction of an order the hook fills from buffer.
- `HOOK_EDGE_BPS` (default `2000`) — margin the hook keeps between the pool price and the
  runner-up belief. Lower ⇒ better price for the swapper, thinner margin for LPs.
- `LIQUIDITY` (default `300_000e18`), `MIN_STAKE` (default `0.1 ether`).

## Gotchas

- **Approve must confirm before Swap / fund / sweep.** The mock tokens use solmate's
  ERC-20: `transferFrom` with **zero allowance underflows** (`panic 0x11`). Wait for the
  approve receipt.
- Every write sends an explicit gas cap, so a doomed transaction reverts with a real
  reason instead of `gas limit too high`.
- **`nonce too low` in MetaMask** — the `PRIVATE_KEY` account sent txs via `forge` that
  MetaMask didn't see. Fix: MetaMask → Settings → Advanced → **Clear activity tab data**.
  Better: don't swap from the deployer — use a fresh account, send it ~0.01 ETH, mint
  tokens with the Faucet, swap from there.
- `sweepInventory` reverts with `NothingToSweep` when there is no inventory or the current
  belief no longer clears the cost basis — both are safe no-ops.

## Path B — click through the UI

1. `/positions` → **Faucet**: mint 100k of each token.
2. `/positions` → **Stake & quote**: stake `0.1` ETH, post `1050000000000000000` (1.05),
   expiry 5 min. Repeat with a second wallet at `1020000000000000000` (1.02).
3. `/positions` → **Hook inventory**: check `buffer c1` is non-zero (fund it if not).
4. `/swap` → direction `currency0 → currency1`, enter an amount, watch the flow:
   - node 1: the decision — winner, runner-up belief, "pushes price away from the region"
   - node 2: the partial fill — `fillIn → fillOut` and the price the hook gave
   - node 3: your execution — vanilla out vs hooked out (hooked ≥ vanilla)
   - node 4: the hook now holds `fillIn` of `currency0`, waiting to be swept
5. Connect the **swapper** wallet, hit **Swap**.
6. `/transactions` → **Sweep inventory**: as any wallet, `sweep c0`. Watch `buffer c1`
   climb back and the pool LPs receive a donation.

Quotes expire after `MAX_QUOTE_DURATION` (5 min) — re-post or re-run `SeedDemo`.
