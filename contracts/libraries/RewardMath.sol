// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '@uniswap/v3-core/contracts/libraries/FullMath.sol';

/// @title Math for computing rewards shared between stakers
/// @notice Uniswap's RewardMath measures a position against the liquidity-seconds of the *whole pool*,
/// so an incentive whose stakers hold only a slice of the pool's TVL silently under-distributes its
/// budget. Here the reward drips at a fixed rate (totalReward / duration) and each second is split
/// between the positions *staked in the incentive* only.
library RewardMath {
    uint256 private constant Q128 = 0x100000000000000000000000000000000;

    /// @notice The increase of the reward-per-staked-liquidity accumulator over `secondsElapsed`
    /// @param totalReward The incentive's whole reward budget
    /// @param duration endTime - startTime, in seconds
    /// @param stakedLiquidity The liquidity staked in the incentive over the elapsed period, non-zero
    /// @param secondsElapsed Seconds since the accumulator was last updated
    function computeRewardPerLiquidityDeltaX128(
        uint256 totalReward,
        uint256 duration,
        uint128 stakedLiquidity,
        uint256 secondsElapsed
    ) internal pure returns (uint256) {
        // == totalReward * (secondsElapsed / duration) / stakedLiquidity, as a UQ128.128
        return FullMath.mulDiv(totalReward, secondsElapsed << 128, duration * uint256(stakedLiquidity));
    }

    /// @notice The reward owed to a stake being closed out
    /// @param rewardPerLiquidityDeltaX128 Accumulator growth since the token was staked
    /// @param liquidity The liquidity of the stake
    /// @param stakedSeconds Seconds the token was staked for, capped at endTime
    /// @param secondsInside Of those, the seconds the pool price was inside the position's range
    /// @param totalRewardUnclaimed What is left of the budget, an upper bound on the payout
    /// @return reward The amount of reward tokens owed
    /// @dev Out-of-range time earns nothing: the payout is scaled by the position's in-range uptime,
    /// and what is forfeited stays in the incentive for the refundee to reclaim with endIncentive.
    function computeRewardAmount(
        uint256 rewardPerLiquidityDeltaX128,
        uint128 liquidity,
        uint256 stakedSeconds,
        uint256 secondsInside,
        uint256 totalRewardUnclaimed
    ) internal pure returns (uint256 reward) {
        if (stakedSeconds == 0) return 0;
        if (secondsInside > stakedSeconds) secondsInside = stakedSeconds;

        reward = FullMath.mulDiv(rewardPerLiquidityDeltaX128, liquidity, Q128);
        reward = FullMath.mulDiv(reward, secondsInside, stakedSeconds);

        // rounding can never let the last staker out with more than what is left
        if (reward > totalRewardUnclaimed) reward = totalRewardUnclaimed;
    }
}
