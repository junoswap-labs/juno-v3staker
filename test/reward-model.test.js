// Runnable model of JunoswapV3Staker's reward accounting: `node test/reward-model.test.js`
// Mirrors libraries/RewardMath.sol + JunoswapV3Staker._accrue one-for-one, so a change to the sharing
// formula that breaks full distribution fails here without needing a chain.
const assert = require('assert')

const Q128 = 1n << 128n
const min = (a, b) => (a < b ? a : b)

class Incentive {
  constructor(reward, startTime, endTime) {
    this.totalReward = BigInt(reward)
    this.unclaimed = BigInt(reward)
    this.accX128 = 0n
    this.stakedLiquidity = 0n
    this.lastUpdate = 0n
    this.startTime = BigInt(startTime)
    this.endTime = BigInt(endTime)
  }

  _accrue(now) {
    const t = min(BigInt(now), this.endTime)
    if (this.lastUpdate !== 0n && t > this.lastUpdate && this.stakedLiquidity > 0n) {
      this.accX128 +=
        (this.totalReward * ((t - this.lastUpdate) << 128n)) /
        ((this.endTime - this.startTime) * this.stakedLiquidity)
    }
    this.lastUpdate = t
    return t
  }

  stake(now, liquidity) {
    this._accrue(now)
    this.stakedLiquidity += BigInt(liquidity)
    return { liquidity: BigInt(liquidity), stakeTime: BigInt(now), accX128: this.accX128, final: null }
  }

  // in-range seconds since the token was staked, minus whatever could have accrued after endTime
  _uptime(now, stake, secondsInside) {
    if (stake.final !== null) return stake.final
    const postEnd = BigInt(now) > this.endTime ? BigInt(now) - this.endTime : 0n
    const inside = BigInt(secondsInside)
    return inside > postEnd ? inside - postEnd : 0n
  }

  // freeze the measurement at endTime, so a late unstake is not discounted
  finalize(now, stake, secondsInside) {
    assert.ok(BigInt(now) >= this.endTime, 'finalize before endTime')
    stake.final = this._uptime(now, stake, secondsInside)
  }

  // secondsInside = the pool's in-range seconds for the range since the token was staked, read at
  // `now` -- so it keeps growing after endTime, exactly as snapshotCumulativesInside does on chain
  unstake(now, stake, secondsInside) {
    const t = this._accrue(now)
    this.stakedLiquidity -= stake.liquidity

    const stakedSeconds = t > stake.stakeTime ? t - stake.stakeTime : 0n
    let inside = this._uptime(now, stake, secondsInside)
    if (inside > stakedSeconds) inside = stakedSeconds

    let reward = 0n
    if (stakedSeconds > 0n) {
      reward = ((this.accX128 - stake.accX128) * stake.liquidity) / Q128
      reward = (reward * inside) / stakedSeconds
      if (reward > this.unclaimed) reward = this.unclaimed
    }
    this.unclaimed -= reward
    return reward
  }
}

const R = 1_000_000n
const [T0, T1] = [1000, 2000] // duration 1000s
// integer division means a few wei of dust can stay behind; it is refundable via endIncentive
const close = (a, b, msg) => assert.ok(a >= b - 2n && a <= b + 2n, `${msg}: ${a} != ${b}`)

// 1. single staker, in range the whole time -> gets the entire budget
{
  const i = new Incentive(R, T0, T1)
  const s = i.stake(T0, 1000)
  close(i.unstake(T1, s, 1000), R, 'sole staker takes the budget')
}

// 2. staked liquidity is a tiny slice of the pool -> still the entire budget.
//    This is the bug being fixed: Uniswap pays R * (L_staked / L_pool), i.e. ~1% here.
{
  const i = new Incentive(R, T0, T1)
  const s = i.stake(T0, 1) // the pool holds 100x more liquidity that nobody staked
  close(i.unstake(T1, s, 1000), R, 'pool TVL does not dilute the payout')
}

// 3. two equal stakers, full duration -> 50/50, nothing left over
{
  const i = new Incentive(R, T0, T1)
  const a = i.stake(T0, 500)
  const b = i.stake(T0, 500)
  close(i.unstake(T1, a, 1000), R / 2n, 'a')
  close(i.unstake(T1, b, 1000), R / 2n, 'b')
  close(i.unclaimed, 0n, 'fully distributed')
}

// 4. B joins halfway with the same liquidity -> B earns a quarter, A the rest
{
  const i = new Incentive(R, T0, T1)
  const a = i.stake(T0, 1000)
  const b = i.stake(1500, 1000)
  const ra = i.unstake(T1, a, 1000)
  const rb = i.unstake(T1, b, 500)
  close(rb, R / 4n, 'half the time at half the share')
  close(ra + rb, R, 'fully distributed')
}

// 5. A leaves halfway -> each second is split between whoever is staked for it
{
  const i = new Incentive(R, T0, T1)
  const a = i.stake(T0, 1000)
  const b = i.stake(T0, 1000)
  const ra = i.unstake(1500, a, 500)
  const rb = i.unstake(T1, b, 1000)
  close(ra, R / 4n, 'a')
  close(rb, (R * 3n) / 4n, 'b')
  close(ra + rb, R, 'fully distributed')
}

// 6. out of range half the time -> earns half, the rest stays refundable
{
  const i = new Incentive(R, T0, T1)
  const s = i.stake(T0, 1000)
  close(i.unstake(T1, s, 500), R / 2n, 'out of range earns nothing')
  close(i.unclaimed, R / 2n, 'forfeited reward is refundable')
}

// 7. unstaking long after endTime earns nothing extra -- and, once finalized, nothing less either
{
  const i = new Incentive(R, T0, T1)
  const a = i.stake(T0, 1000)
  const b = i.stake(T0, 1000)
  const rb = i.unstake(T1, b, 1000)
  i.finalize(T1, a, 1000) // freeze a's uptime at endTime: it was in range the whole incentive
  const ra = i.unstake(99999, a, 90000) // in range for ages after the incentive ended
  close(ra, R / 2n, 'a')
  close(rb, R / 2n, 'b')
}

// 8. nobody staked for the first half -> that half is NOT redistributed to latecomers
{
  const i = new Incentive(R, T0, T1)
  const s = i.stake(1500, 1000)
  close(i.unstake(T1, s, 500), R / 2n, 'latecomer only earns for the time it was staked')
  close(i.unclaimed, R / 2n, 'idle time is refundable, not snipeable')
}

// 9. H-01: in range only AFTER endTime earns nothing. Before the clamp this paid the whole budget,
//    because secondsInside kept growing past endTime while stakedSeconds stopped there.
{
  const i = new Incentive(R, T0, T1)
  const s = i.stake(T0, 1000)
  // never in range during [T0, T1]; then in range for the whole 1000s after the incentive ended
  close(i.unstake(3000, s, 1000), 0n, 'post-endTime uptime earns nothing')
  close(i.unclaimed, R, 'the whole budget stays refundable')
}

// 10. H-01: a genuine half-uptime staker still gets its half however late it unstakes, once finalized
{
  const i = new Incentive(R, T0, T1)
  const s = i.stake(T0, 1000)
  i.finalize(T1, s, 500) // 500s of the 1000s incentive spent in range
  // then in range for 10x the incentive duration before getting round to unstaking
  close(i.unstake(12000, s, 500n + 10000n), R / 2n, 'finalized late unstake pays the honest half')
}

// 11. H-01: waiting cannot turn a partial uptime into a full one
{
  const i = new Incentive(R, T0, T1)
  const s = i.stake(T0, 1000)
  // 250s in range before endTime, then sits in range for 10x the incentive duration
  close(i.unstake(12000, s, 250n + 10000n), R / 4n, 'a quarter stays a quarter')
}

// 12. H-01: finalizing cannot be gamed -- an out-of-range staker gets nothing whenever it freezes,
//     so the fix costs the honest nothing and gives the attacker no lever
{
  for (const at of [T1, 2500, 3000]) {
    const i = new Incentive(R, T0, T1)
    const s = i.stake(T0, 1000)
    // in range for 0s of the incentive; by `at` it has banked (at - T1) in-range seconds
    i.finalize(at, s, BigInt(at) - BigInt(T1))
    close(i.unstake(9999, s, 8000), 0n, `out of range earns nothing, finalized at ${at}`)
  }
}

console.log('ok')
