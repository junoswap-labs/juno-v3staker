# JunoswapV3Staker vs Uniswap v3-staker v1.0.2 — review scope

Compared against `v3staker/original/v3-staker` (`UniswapV3Staker.sol`, package version 1.0.2).
Contract and interface names are normalised before diffing, and line endings are ignored, so the
`.diff` files in [`upstream-diff/`](upstream-diff/) show only real changes.

| File | Status vs upstream |
|---|---|
| `libraries/NFTPositionInfo.sol` | identical |
| `libraries/TransferHelperExtended.sol` | identical |
| `libraries/IncentiveId.sol` | import and type renamed only |
| `libraries/RewardMath.sol` | **rewritten** — new model (see below) |
| `interfaces/IJunoswapV3Staker.sol` | updated for the new model |
| `JunoswapV3Staker.sol` | **modified** — about 300 changed lines |

Everything not listed as changed is upstream code and carries upstream's track record.
A reviewer's time is best spent on the sections below.

## What changed, and what to check

### 1. Reward model (`RewardMath.sol`, `_accrue`, `_stakeUptime`, `_measureUptime`)
- Upstream pays against the liquidity-seconds of the **whole pool**. Here the budget drips at
  `totalReward / duration` and is split between **staked** liquidity through a
  `rewardPerLiquidityX128` accumulator.
- A stake's payout is scaled by its in-range uptime: `secondsInside / stakedSeconds`.
- Check: rounding direction, overflow bounds of the X128 accumulator, and that
  `sum(payouts) + totalRewardUnclaimed == totalReward` always holds.

### 2. Storage layout
- `Incentive`: replaces `totalSecondsClaimedX128` with `totalReward`, `rewardPerLiquidityX128`,
  `stakedLiquidity`, `lastUpdateTime`; `numberOfStakes` widens to `uint64`.
- `Stake`: new struct with `stakeTime`, `secondsInsideInitial/Final`, `finalized`; `stakes` is now a
  public mapping, so its getter returns six values (upstream returns two).
- Check: packing and the `uint32` time fields (valid to 2106).

### 3. New code paths with no on-chain test (highest priority)
- **`finalizeStake`** — freezes a stake's in-range time at `endTime`. Anyone may call it.
- **`stakeToken` guards** — `position out of range` and `liquidity exceeds pool` (uses `pool.liquidity()`).
- **`unstakeToken` eviction** — non-owners may close a stake after `endTime`, or after it has existed
  for 1 hour with at most 10% in-range uptime. Replaces upstream's rule that anyone may unstake after
  `endTime` only.
- **`_measureUptime` post-end clamp** — subtracts `block.timestamp - endTime` from the pool's counter.
  Subtraction is deliberate modular arithmetic and is only correct on solc 0.7.6.

### 4. Hardening not in upstream
- `createIncentive` credits the **received** amount (balance delta), not the requested one, and caps
  `totalReward` at `uint128.max` using `LowGasSafeMath`.
- `createIncentive` requires `endTime <= uint32.max`.
- `minRangeSpacings` (audit M-01, Option A): immutable, set at deployment; `0` disables the floor. A stake must span at least `minRangeSpacings × pool.tickSpacing()` ticks (`deploy.sh` default 10). Upstream has no such floor. Test: `test/JunoswapV3StakerMinRange.t.sol`.

### 5. Unchanged on purpose
- No owner, admin, pause or upgrade path. `endIncentive`, `depositToken` flow, `withdrawToken`,
  `claimReward`, `multicall` follow upstream.

## Not covered by this document
Behaviour that the diff cannot show: the interaction with a real Uniswap V3 pool, fee-on-transfer
tokens, and reentrancy through reward tokens. These need fork and invariant tests.
