# RediSwapHook — security self-review

This is an internal review against the Uniswap v4 hook security checklist. It is **not an
audit**. The hook has not been audited by a third party. Do not use it with funds you cannot
afford to lose.

## Permissions

| Flag | Enabled | Risk |
|---|---|---|
| `beforeSwap` | yes | HIGH |
| `beforeSwapReturnDelta` | yes | CRITICAL |
| everything else | no | — |

`beforeSwapReturnDelta` is the NoOp / rug-pull vector. Its use here:

- The hook only ever returns `toBeforeSwapDelta(+fillIn, -fillOut)` with `fillIn ≤ 30%` of
  the order and `fillOut` priced **above** the pool's marginal rate (`hookPx ∈ (poolPx, v₂)`,
  with `v₂` gated to the swapper's favourable side).
- It never returns a full-size specified delta, never a positive unspecified delta, and never
  a delta on a swap it is not simultaneously settling from its own buffer.
- Net effect on the swapper: strictly **more output per input** than the plain pool, or no
  change. This is covered by `testFuzz_swapperVanillaOrBetter` (256 runs, both directions,
  belief range 0.7–1.5).

Estimated risk score (checklist rubric): permissions 18, external calls 2 (registry read,
optional sweep callback), state complexity 3, upgrade 0, token handling 2 → ~25, "critical
tier — multiple audits" before mainnet use with real value.

## Checklist

| # | Check | Status |
|---|---|---|
| 1 | Hook callbacks verify `msg.sender == poolManager` | `beforeSwap`, `unlockCallback` both `onlyPoolManager` |
| 2 | Router allowlisting | not needed — hook never trusts `sender` for identity or value |
| 3 | No unbounded loops | `bestForXForY/YForX` loop is bounded by `MAX_ACTIVE_QUOTERS = 32` |
| 4 | Reentrancy guards on external calls | `nonReentrant` on `fundBuffer` and `sweepInventory`; state is zeroed before any transfer or callback |
| 5 | Delta accounting sums to zero | `beforeSwap` `take(fillIn)` + `settle(fillOut)` is cancelled by the returned `BeforeSwapDelta`; `unlockCallback` `donate` is settled in the same unlock. `invariant_hookSolvent` (128k calls, 0 reverts) confirms the hook always physically holds ≥ `buffer + inventory`. |
| 6 | Fee-on-transfer tokens | **not handled.** The hook assumes `amount in == amount received`. A fee-on-transfer currency would break buffer accounting. Restrict pools to standard ERC-20s. |
| 7 | No hardcoded addresses | PoolManager and registry are constructor args |
| 8 | Slippage respected | the hook only ever improves the fill; the swapper's own `sqrtPriceLimitX96` still bounds the residual pool swap |
| 9 | No sensitive on-chain data | none stored |
| 10 | Upgrade mechanism | none — immutable, no admin, no owner |
| 11 | `beforeSwapReturnDelta` justified | see above |
| 12 | Fuzz testing | `testFuzz_swapperVanillaOrBetter`, `testFuzz_hookSolvent` |
| 13 | Invariant testing | `invariant_hookSolvent`, `invariant_costBasisTracksInventory` |

## Native currency

`_decide` reverts `NativeCurrencyUnsupported` if either currency is the zero address. The hook
does not handle ETH.

## The sweep and the LP donation

`sweepInventory` lets any address buy the hook's accumulated inventory at the runner-up belief
`v₂`, floored at the **current pool spot price** so a solver can never buy below the pool's own
rate. Proceeds refill the buffer to cost basis; the surplus is `donate`'d to in-range LPs.

Residual griefing vector: a solver who both (a) posts the two best beliefs at fill time and
(b) posts the two best beliefs again at sweep time, **and** is willing to move the pool spot
against itself in the same block, can suppress part of the LP donation. It cannot touch the
swapper (the vanilla floor is structural) and it cannot buy below spot. It also requires
out-competing every honest quoter on both occasions. The complete fix is a multi-block TWAP
oracle on the sweep price (or stake slashing keyed to that TWAP); both are deferred as
deliberate scope decisions, not oversights.

## Known open items before production

1. TWAP-floored sweep price / stake slashing (above).
2. Fee-on-transfer and non-standard token handling (item 6).
3. External-venue settlement for solvers at scale — the `ISweepCallback` seam exists but no
   reference settler is provided.
4. Third-party audit. `beforeSwapReturnDelta` warrants formal review.
