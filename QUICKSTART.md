# Quickstart — clone & demo

Three ways to run Hyberbola, fastest first. The whole thing is in this repo: a Foundry
project (`hyberbola/`) and an Astro console (`web/`).

---

## Prerequisites

| Tool | Install |
|------|---------|
| **Foundry** | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| **Node** 20+ and **npm** | https://nodejs.org |
| **A browser wallet** (only for the on-chain demo) | MetaMask or any injected wallet |

```bash
git clone --recursive <this-repo> hyberbola && cd hyberbola
# already cloned without --recursive?
git submodule update --init --recursive
```

---

## 1. Run the tests — no wallet, no network (~30s)

```bash
cd hyberbola
forge test
```

Expected: **33 passing, 0 failing**, including two invariants at 128,000 calls each.

See the vanilla-or-better guarantee directly:

```bash
forge test --match-test testFuzz_swapperVanillaOrBetter -vv
forge test --match-test test_awayFromFair_swapperBeatsVanilla -vvv   # prints: plain 992, hooked 1001.8
```

---

## 2. Run the console against the live deployment (~2 min)

The console loads the deployed Unichain Sepolia stack by default — no config.

```bash
cd web
npm install
npm run dev
```

Open the printed URL (usually `http://localhost:4321`).

- **`/`** — the landing page: scroll through the mechanism derivation.
- **`/swap`** — enter a trade size and direction; the flow panel shows the hook's decision,
  the partial fill, and hooked-vs-vanilla output, read live from the chain.
- **`/transactions`** — `preview` the `beforeSwap` decision for any hypothetical swap.

Read-only browsing needs no wallet. To actually trade, do the on-chain demo below.

---

## 3. The full on-chain demo (~10 min)

### 3a. Get on Unichain Sepolia

1. Add **Unichain Sepolia** to your wallet — chain id `1301`, RPC
   `https://unichain-sepolia.drpc.org`, explorer `https://sepolia.uniscan.xyz`.
2. Get testnet ETH from a Unichain Sepolia faucet (e.g. the Alchemy or thirdweb faucet).
   You need enough for gas plus `0.1 ETH` per solver you want to stake.

### 3b. Stand up the fair-price region

Two solvers posting beliefs **above 1.0** create the region a `currency0 → currency1` swap
will be pushed away from.

**Option A — one command.** Fill `hyberbola/.env` from `.env.example` (the deployed addresses
are in the table in [README.md](README.md) and in `web/src/lib/deployed.ts`), then:

```bash
cd hyberbola
export REGISTRY=0x866E9919ee149222f877d3a44d9Eb0FDb97F0662
export HOOK=0x5e2Cd161FbE98325fec1Aa949907716655914088
export CURRENCY0=0xb3D7643A75364eb2b3942bD1c4fbaCA02D34ee33
export CURRENCY1=0xce91739e7dECeB3BfC78D41E3B03aD9208B7A384
export FEE=3000 TICK_SPACING=60
export ARB_KEYS=0xSOLVER_A_KEY,0xSOLVER_B_KEY
export QUOTE_PRICES=1050000000000000000,1020000000000000000   # 1.05 and 1.02, wad

forge script script/SeedDemo.s.sol:SeedDemoScript --rpc-url unichain_sepolia --broadcast
```

Solver keys short on ETH are topped up from `PRIVATE_KEY` automatically, so fresh throwaway
keys work.

**Option B — click through the console.** On `/positions`: use the **Faucet**, then **Stake &
quote** — stake `0.1` ETH and post `1050000000000000000`. Repeat from a second wallet with
`1020000000000000000`.

### 3c. Swap and watch the hook act

1. `/positions` → **Faucet**: mint test USDC / DAI to your swapper wallet.
2. `/positions` → **Hook inventory**: confirm `buffer c1` is non-zero (it is on the live
   deployment — 25,000).
3. `/swap` → direction `currency0 → currency1`, enter e.g. `1000`, **wait for the approve
   receipt**, then **Swap**. The flow shows:
   - node 1 — the decision: winner, runner-up belief, "pushes price away from the region"
   - node 2 — the partial fill: `fillIn → fillOut` and the hook's price
   - node 3 — your execution: vanilla out vs hooked out (**hooked ≥ vanilla**)
   - node 4 — the hook now holds `fillIn` of `currency0`, awaiting a sweep

### 3d. Close the loop

`/transactions` → **Sweep inventory** → `sweep c0`, from any wallet. Watch `buffer c1` climb
back to 25,000 and the LP donation land.

> Quotes expire after 5 minutes — re-post or re-run `SeedDemo` if the demo runs long.
> A deeper runbook, including the MetaMask nonce/approve gotchas, is in [DEMO.md](DEMO.md).

---

## 4. Deploy your own stack

`Deploy.s.sol` deploys everything: two mock ERC-20s, the `QuoteRegistry`, a CREATE2-mined
`RediSwapHook`, initialises the pool, seeds liquidity, and funds the buffer.

```bash
cd hyberbola
cp .env.example .env        # fill in RPC_URL and PRIVATE_KEY

forge script script/Deploy.s.sol:DeployScript --rpc-url unichain_sepolia --broadcast
```

Knobs (all optional, read from `.env`):

| var | default | effect |
|-----|---------|--------|
| `MAX_FILL_BPS` | `3000` | largest share of an order filled from the buffer |
| `HOOK_EDGE_BPS` | `2000` | margin kept below the runner-up belief → LP donation |
| `MIN_STAKE` | `0.1 ether` | solver bond |
| `LIQUIDITY` | `300000e18` | full-range liquidity seeded into the pool |

The script prints `HOOK=`, `REGISTRY=`, `CURRENCY0=`, `CURRENCY1=`. Paste them into
`web/src/lib/deployed.ts`, restart `npm run dev`, and the console points at your deployment.

> The simulation may print `Internal EVM error during simulation` at the end — that's an RPC
> quirk on the post-run trace, not a contract revert; the broadcast still lands. If
> `--broadcast` stalls, add `--slow` or `--skip-simulation`.

---

## Troubleshooting

| symptom | fix |
|---------|-----|
| `forge test` can't find dependencies | `git submodule update --init --recursive` |
| Swap button never appears | the ERC-20 approve must confirm first — wait for the receipt |
| MetaMask "gas limit too high" / `0x515` | you clicked Swap before the approve landed |
| MetaMask "nonce too low" | `forge` sent txs your wallet didn't see — Settings → Advanced → Clear activity tab data, or use a fresh wallet |
| `sweepInventory` reverts `NothingToSweep` | no inventory yet, or the belief no longer clears the cost basis — both are safe no-ops |
