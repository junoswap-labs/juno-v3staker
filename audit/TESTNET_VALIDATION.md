# Testnet validation — M-01 width floor and multi-staker accounting

Run on KUB testnet (chain 25925) against the real Uniswap V3 factory and position manager, on
2026-10-08. This complements the Foundry tests, which mock the pool and position manager.

| | |
|---|---|
| Staker | `0x17Bf4274D5a4AF99c7dfE641894F2bB340C10EF2` (deploy block 34217149, `minRangeSpacings` = 10) |
| Factory / position manager | `0xCBd41F872FD46964bD4Be4d72a8bEBA9D656565b` / `0x690f45C21744eCC4ac0D897ACAC920889c3cFa4b` |
| Replaces | `0x9766424962CBB7482AA58f0c9842673515ABec9a` (no width floor, no `stakeEligibility`) |
| Reward token | tK `0xE7f64C5fEFC61F85A8b851d8B16C4E21F91e60c0` |
| Pools | tT/tKKUB `0x81182579f4271B910bF108913be78f0d9C44AaBa`, tT/tK `0x3a4Ecfe66E07Eeed734C32914EA3EeA65605C20c` (both fee tier 100) |

## What was exercised

| # | Scenario | Result |
|---|---|---|
| 1 | Full-range position (#31) through the whole lifecycle: create incentive, `stakeEligibility` before start, stake, `stakeEligibility` after stake, unstake, claim, withdraw | Passed. Before start: `incentive not started`. After start: eligible. After stake: `token already staked`. Payout 1.35 tK for 81 s of a 10 tK / 600 s incentive, which matches `10 / 600 × 81` |
| 2 | In-range position (#62, 212 ticks wide) as the only staker | Passed. 2.6 tK for 78 s of a 10 tK / 300 s incentive, which matches `10 / 300 × 78` |
| 3 | Position narrower than the floor (#63, 8 ticks, spacing 1, floor 10 ticks) | Rejected with `range too narrow`, by `stakeEligibility` and by the real `safeTransferFrom` stake |
| 4 | Two stakers, two NFTs, staggered entry and exit (#62 from wallet A, #65 from wallet B) | Passed, see below |

## Multi-staker accounting (scenario 4)

Incentive: 10 tK over 300 s. A stakes #62 (liquidity 3.09e23) first. B stakes #65 (liquidity
9.16e22) 36 s later. A unstakes 42 s after that, B 30 s after A. Expected payouts were computed
independently from the block timestamps of the four transactions: the budget drips at
`totalReward / duration`, is split by liquidity among whoever is staked in each interval, and a
lone staker takes the whole drip.

| | Paid (tK) | Expected (tK) |
|---|---|---|
| A | 2.279733 | 2.279733 |
| B | 1.320267 | 1.320267 |

After `endTime`, `endIncentive` refunded 6.4 tK. Paid plus refund is 10.000000 tK, so nothing is
lost or over-paid. Claimed balances equalled the owed amounts. NFTs were withdrawn and returned.

## Not covered

- Positions leaving the range mid-incentive (uptime scaling) and eviction by a non-owner after the
  1-hour / 10% rule.
- More than two stakers, or several NFTs from one owner in the same incentive.
- Fee-on-transfer reward tokens and reentrancy through reward tokens.
- Mainnet. Nothing here was run against KUB mainnet.

## Things worth knowing

- The fee tier 100 pools on KUB use `tickSpacing` 1, not 10. With the default of 10 spacings the
  floor is only 10 ticks (about 0.1%) on those pools. `MIN_RANGE_SPACINGS` is fixed at deploy time,
  so a stricter floor needs a new deployment.
- Payouts are proportional to raw liquidity, so a wide position with a large deposit earns more than
  a narrow one with a small deposit. The floor limits how far a narrow range can win per dollar. It
  does not make rewards proportional to TVL (audit M-01 Option B).
- The scenario 4 harness was a one-off script driving `cast`; it is not committed.
