# Remediation diff — JunoswapV3Staker

Changes applied after the security audit (`report.html` / `findings.json`), 2026-09-04.

Fixes **H-01, H-02, H-03, M-02, L-01** — roadmap tiers 0, 1 and 2.
**M-01 and I-01 left open on purpose**; see [Not changed](#not-changed).

- Machine-readable diff of the contract: [`fixes.patch`](fixes.patch)
- Verified: `npx hardhat compile` clean (solc 0.7.6), `node test/reward-model.test.js` passes 12/12 (was 8)

---

## Files touched

| File | Change |
|---|---|
| `contracts/JunoswapV3Staker.sol` | +96 / −18 lines — all five fixes |
| `contracts/interfaces/IJunoswapV3Staker.sol` | `stakes()` tuple, `finalizeStake()`, `StakeFinalized`, NatSpec |
| `test/reward-model.test.js` | model mirrors the new clamp + freeze; 4 cases added, 2 updated |

---

## H-01 — post-`endTime` uptime credited against a window that stops at `endTime`

**Root cause.** The payout ratio is `secondsInside / stakedSeconds`. The denominator is capped at
`endTime` (via `_accrue`), the numerator was not — `snapshotCumulativesInside` keeps counting after
the incentive ends. A position in range for *none* of the incentive could reach a ratio of 1.0 by
staying staked until the price sat in its range long enough afterwards, and collect its whole share
out of the refundee's refund.

**Two parts, and both are needed.**

### 1. Clamp the reading (`_measureUptime`)

At most `block.timestamp − endTime` of the observed growth can have happened after the incentive
ended, so subtracting that lower-bounds the in-range time genuinely earned inside the reward window.

```solidity
uint256 inside = uint256(uint32(secondsInside - stake.secondsInsideInitial));
uint256 postEnd = block.timestamp > key.endTime ? block.timestamp - key.endTime : 0;
return inside > postEnd ? inside - postEnd : 0;
```

### 2. Freeze the reading (`finalizeStake`) — because the clamp alone regresses honest LPs

The clamp is sound but loosens by one second per second of delay, so **on its own it zeroes an
honest staker who simply unstakes late**. The project's own model test 7
(`unstaking long after endTime earns nothing extra`) rejected the clamp-only version — correctly.
Trading a leak against the refundee for a leak against LPs is not a fix.

`finalizeStake` closes it: anyone may freeze a stake's in-range measurement from `endTime`, once,
cheaply enough to batch every outstanding stake through `multicall`. Called in the block `endTime`
passes, the discount is zero and the reading is exact — so honest stakes are paid in full **however
late** they are unstaked.

```solidity
function finalizeStake(IncentiveKey memory key, uint256 tokenId) external override {
    require(block.timestamp >= key.endTime, 'JunoswapV3Staker::finalizeStake: incentive not ended');
    // ... stores the *clamped delta*, not the raw counter
    stored.secondsInsideFinal = uint32(_measureUptime(key, deposits[tokenId], stored));
    stored.finalized = true;
}
```

Two new `Stake` fields (`uint32 secondsInsideFinal`, `bool finalized`) pack into the **existing**
slot — 232 of 256 bits — so this costs no extra storage slot.

**No lever for an attacker, in either direction:** a position out of range during the incentive
measures zero whenever it finalizes, and finalizing later only tightens the discount. Model case 12
asserts this across three freeze times.

**Who should call it:** the refundee. They have the motive (the discount otherwise inflates their
refund at their own stakers' expense) and the means (`endIncentive` is blocked until every stake is
closed anyway).

---

## H-02 — out-of-range liquidity dilutes every honest staker

**Root cause.** `_stakeToken` added any position's liquidity to `stakedLiquidity` regardless of
range. An out-of-range position occupied the accumulator's denominator while being paid nothing, and
its share went to the refundee rather than to the LPs who *were* in range. One position at
`maxLiquidityPerTick`, costing **0.0000019 tokens**, dropped an `L = 1e21` staker to 8.7e-14 of the
budget.

**Fix** — two guards at the entry point:

```solidity
require(!_isOutOfRange(pool, tickLower, tickUpper), 'JunoswapV3Staker::stakeToken: position out of range');
require(liquidity <= pool.liquidity(),              'JunoswapV3Staker::stakeToken: liquidity exceeds pool');
```

The second is what kills the dust attack: liquidity per unit of capital is unbounded as a range
narrows, but the pool's own *active* liquidity is a market-sized ceiling that dust cannot reach.

**Residual, stated plainly:** neither guard covers a position that drifts out of range *after* it is
staked. That case is bounded to real, market-sized positions by the second guard, and it is what the
eviction path (H-03) exists to clear. The architectural fix — keeping out-of-range liquidity out of
the denominator continuously — was **not** applied; it needs tick-crossing hooks and is a redesign,
not a patch.

---

## H-03 — permissionless eviction keyed on a spot tick

**Root cause.** `unstakeToken` let anyone close another owner's stake whenever `_isOutOfRange` was
true, and that read `slot0.tick` — the instantaneous price. One transaction could swap past every
competing staker's range, evict them all, and swap back.

**Fix** — replace the spot proxy with the harm itself, measured over the stake's whole life:

```solidity
block.timestamp >= key.endTime ||
    (stakedSeconds >= MIN_EVICTION_STAKE_AGE &&                       // 1 hours
        secondsInsideStaked * EVICTION_UPTIME_DIVISOR <= stakedSeconds) // <= 10% in range
```

A swap changes the current tick, but **cannot retroactively remove in-range seconds a position has
already banked** — so there is no single-transaction version of this condition. A position that is
genuinely earning is no longer evictable at all; one that has earned essentially nothing over an
hour still is, which is what the path is for.

Chosen over the TWAP option from the report: both quantities are already computed for the payout, so
this adds no external call, and it carries no dependency on the pool's observation cardinality —
where an insufficient window would make `observe` revert and disable eviction entirely.

`unstakeToken` was reordered so the uptime is computed before the permission check. `_accrue` still
runs first; it is idempotent and the whole call reverts if the check fails.

---

## M-02 — reward accounting assumed an exact-transfer ERC-20

**Root cause.** `createIncentive` credited the books with the *requested* amount and transferred
afterwards. With a fee-on-transfer or rebasing token the books sat above the real balance, and the
shortfall was paid out of any **other** incentive sharing that reward token until claiming reverted.

**Fix** — transfer first, credit what actually arrived:

```solidity
uint256 balanceBefore = key.rewardToken.balanceOf(address(this));
TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);
uint256 received = key.rewardToken.balanceOf(address(this)).sub(balanceBefore);
require(received > 0, 'JunoswapV3Staker::createIncentive: no reward received');
```

`IncentiveCreated` now emits `received`, not `reward` — **indexers reading that field will see the
real amount.**

**Not fixed, and not fixable from this side:** blocklisting tokens and tokens with privileged balance
movement (KAP-20 `adminTransfer` on KUB Chain). Document the reward-token requirements for incentive
creators.

---

## L-01 — unchecked arithmetic on solc 0.7.6

Two additions the fork introduced, both silent-wrap on 0.7.6:

```solidity
using LowGasSafeMath for uint256;

// was: incentive.totalReward + reward  -- wrapped past the uint128 cap it feeds
uint256 totalReward = incentive.totalReward.add(received);

// was: incentive.stakedLiquidity += liquidity  -- unchecked uint128 accumulation
uint256 newStakedLiquidity = uint256(incentive.stakedLiquidity).add(liquidity);
require(newStakedLiquidity <= type(uint128).max, 'JunoswapV3Staker::stakeToken: staked liquidity overflow');
incentive.stakedLiquidity = uint128(newStakedLiquidity);
```

A porting note was added at the one place that **must not** be made checked:

```solidity
// NOTE: this subtraction is deliberate modular arithmetic on a Uniswap accumulator built to
// wrap, and is correct on 0.7.6. If this contract is ever ported to 0.8, it MUST be wrapped
// in an `unchecked` block or unstakeToken will revert permanently once the counter wraps.
uint256 inside = uint256(uint32(secondsInside - stake.secondsInsideInitial));
```

---

## Breaking changes

Pre-deployment, so these are free — but they **will** break anything already built against the ABI.

| What | Before | After |
|---|---|---|
| `stakes()` return tuple | 4 values | **6** — adds `secondsInsideFinal`, `finalized` |
| `finalizeStake()` | — | new external function |
| `StakeFinalized` | — | new event |
| `IncentiveCreated.reward` | requested amount | **amount actually received** |
| `unstakeToken` revert string | `...an in-range token...` | `...an earning token...` |
| `stakeToken` | — | two new revert reasons |

**Operational change:** the refundee should call `finalizeStake` for every outstanding stake in the
block `endTime` passes, batched via `multicall`. Skipping it does not break anything — it just
re-opens the H-01 discount against stakers.

---

## Not changed

**M-01 — no minimum range width.** Reward weight is still raw liquidity, so at the 0.01% tier $45 at
the minimum width still earns what $100,000 at ±10% earns. This is a **product decision about who
the incentive is meant to reward, not a defect**, and it is inherited from upstream. Picking a
`minRangeTicks` would bake in a judgement about the pool's expected volatility that this review has
no basis for making. Decide it, then apply Option A or B from the report.

**I-01 — informational.** 2106 timestamp horizon, `multicall` payable with no ETH path, misleading
`endIncentive` revert, `claimReward(…, 0)` meaning "claim all", the `data.length == 160` heuristic.
None is a defect.

---

## Still outstanding

The fixes are verified against **the accounting model and the compiler only.**

- **No on-chain test exists.** `finalizeStake` and the two `_stakeToken` guards are new code paths
  that nothing exercises against a real Uniswap V3 pool. `pool.liquidity()` and
  `snapshotCumulativesInside` behaviour under the new call order are untested.
- **Slither was never run** — not installed on the audit machine.
- Roadmap tier 3 stands: fork tests, Foundry invariants
  (`sum(payouts) + totalRewardUnclaimed == totalReward`; `every deposited NFT is withdrawable`),
  Slither in CI.

Treat this as reviewed-and-compiling, not as tested.
