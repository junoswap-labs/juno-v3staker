# JunoswapV3Staker

Liquidity mining for Uniswap V3 positions, where a fixed reward budget is shared between the
**staked positions only** and pro-rated by in-range uptime.

A fork of [`Uniswap/v3-staker`](https://github.com/Uniswap/v3-staker) (v1.0.2) with the reward model
replaced.

## Why the fork

Upstream measures a position against the liquidity-seconds of the **entire pool**. An incentive on a
pool where only a slice of the TVL is staked therefore pays out only that slice of its budget — the
rest is never distributed.

Here the budget drips at `totalReward / duration` and each second is split between the positions
actually staked in the incentive, so a launchpad's fixed reward reaches its participants regardless
of how much unstaked liquidity sits in the pool.

## How rewards work

- **Drip.** An incentive pays `totalReward / duration` per second, fixed at creation. Topping up is
  only possible before `startTime`, so the rate never has to be rebased.
- **Share.** Each second is split between staked positions in proportion to their liquidity, tracked
  by a `rewardPerLiquidityX128` accumulator. Seconds during which nothing is staked accrue nothing.
- **Uptime.** A payout is scaled by the fraction of the stake's life the pool price spent inside its
  range. Out-of-range time earns nothing.
- **Refund.** Whatever is not distributed — idle seconds, forfeited out-of-range time, rounding dust
  — goes to `key.refundee` via `endIncentive`.

Positions must be **in range** and no larger than the pool's own active liquidity to be staked, so a
dust position at an extreme tick cannot dilute real stakers.

### Closing an incentive

Call `finalizeStake` for each outstanding stake in the block `endTime` passes — it is permissionless
and batchable through `multicall`.

The pool's in-range counter keeps running after `endTime`, so a stake read late is discounted by the
elapsed delay to make sure it cannot be credited for uptime earned outside the reward window.
Freezing the reading at `endTime` removes that discount, so every honest stake is paid in full
however late it is unstaked. The refundee has both the motive and the means to do this: the discount
otherwise inflates their refund at their own stakers' expense, and `endIncentive` is blocked until
every stake is closed anyway.

## No privileged roles

There is no owner, admin, proxy, pause, sweep or upgrade path. `createIncentive` is permissionless
and self-funding, and the four constructor immutables can never change. The LP NFT is retrievable on
a path that touches only the position manager and the pool — it never depends on the reward token.

## Build

```bash
npm install
npm run compile   # hardhat, solc 0.7.6, optimizer runs 1_000_000
npm test          # runnable model of the reward accounting
```

`npm test` runs `test/reward-model.test.js`, a JavaScript mirror of `RewardMath.sol` plus
`_accrue`/`_stakeUptime`, so a change to the sharing formula that breaks full distribution fails
without needing a chain.

## Audit

A security review of this codebase is in [`audit/`](audit/):

| File | |
|---|---|
| [`report.html`](audit/report.html) | Full report — findings, value flow, liveness checks, quantified analysis |
| [`CHANGES.md`](audit/CHANGES.md) | What was fixed and why, with the residual risk on each |
| [`fixes.patch`](audit/fixes.patch) | Unified diff of the remediation |
| [`findings.json`](audit/findings.json) | Machine-readable findings register |

Seven findings, no Critical. Five were fixed (H-01, H-02, H-03, M-02, L-01); **M-01 and I-01 remain
open by design** — see `CHANGES.md`.

## Status

> **Not production ready.** Pre-deployment and **not tested on-chain.** The reward model has no fork
> tests against a real Uniswap V3 pool, no invariant tests, and no static-analysis pass —
> `finalizeStake` and the `stakeToken` guards are new code paths nothing exercises outside the
> accounting model. Do not deploy with real funds before closing tier 3 of the audit roadmap.

Reward tokens must be standard ERC-20: no transfer fee, no rebasing, no blocklist, no privileged
balance movement.

## Licence

GPL-2.0-or-later, per the SPDX headers on every contract.
