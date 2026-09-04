// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol';

/// @title Juno V3 Staker Interface
/// @notice Liquidity mining for Uniswap V3 positions where the reward is shared between the *staked*
/// positions only, instead of being diluted by the liquidity of the whole pool (as in UniswapV3Staker).
interface IJunoswapV3Staker is IERC721Receiver, IMulticall {
    /// @param rewardToken The token being distributed as a reward
    /// @param pool The Uniswap V3 pool
    /// @param startTime The time when the incentive program begins
    /// @param endTime The time when rewards stop accruing
    /// @param refundee The address which receives any remaining reward tokens when the incentive is ended
    struct IncentiveKey {
        IERC20Minimal rewardToken;
        IUniswapV3Pool pool;
        uint256 startTime;
        uint256 endTime;
        address refundee;
    }

    /// @notice The Uniswap V3 Factory
    function factory() external view returns (IUniswapV3Factory);

    /// @notice The nonfungible position manager with which this staking contract is compatible
    function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);

    /// @notice The max duration of an incentive in seconds
    function maxIncentiveDuration() external view returns (uint256);

    /// @notice The max amount of seconds into the future the incentive startTime can be set
    function maxIncentiveStartLeadTime() external view returns (uint256);

    /// @notice Represents a staking incentive
    /// @param incentiveId The ID of the incentive computed from its parameters
    /// @return totalReward The whole reward budget, which drips linearly between start and end time
    /// @return totalRewardUnclaimed The amount of reward token not yet credited to stakers
    /// @return rewardPerLiquidityX128 Accumulated reward per unit of staked liquidity, as a UQ128.128
    /// @return stakedLiquidity The liquidity currently staked in the incentive
    /// @return lastUpdateTime The last time the accumulator was updated (capped at endTime)
    /// @return numberOfStakes The count of deposits that are currently staked for the incentive
    function incentives(bytes32 incentiveId)
        external
        view
        returns (
            uint256 totalReward,
            uint256 totalRewardUnclaimed,
            uint256 rewardPerLiquidityX128,
            uint128 stakedLiquidity,
            uint64 lastUpdateTime,
            uint64 numberOfStakes
        );

    /// @notice Returns information about a deposited NFT
    function deposits(uint256 tokenId)
        external
        view
        returns (
            address owner,
            uint48 numberOfStakes,
            int24 tickLower,
            int24 tickUpper
        );

    /// @notice Returns information about a staked liquidity NFT
    /// @param tokenId The ID of the staked token
    /// @param incentiveId The ID of the incentive for which the token is staked
    /// @return rewardPerLiquidityInitialX128 The incentive's accumulator when the token was staked
    /// @return secondsInsideInitial The pool's secondsInside snapshot for the range at stake time
    /// @return stakeTime The timestamp the token was staked
    /// @return liquidity The amount of liquidity in the NFT as of the time it was staked
    /// @return secondsInsideFinal The in-range seconds frozen by finalizeStake, 0 until then
    /// @return finalized Whether the in-range measurement has been frozen
    function stakes(uint256 tokenId, bytes32 incentiveId)
        external
        view
        returns (
            uint256 rewardPerLiquidityInitialX128,
            uint32 secondsInsideInitial,
            uint32 stakeTime,
            uint128 liquidity,
            uint32 secondsInsideFinal,
            bool finalized
        );

    /// @notice Returns amounts of reward tokens owed to a given address
    function rewards(IERC20Minimal rewardToken, address owner) external view returns (uint256 rewardsOwed);

    /// @notice Creates a new liquidity mining incentive program, pulling in `reward` reward tokens
    function createIncentive(IncentiveKey memory key, uint256 reward) external;

    /// @notice Ends an incentive after the end time has passed and all stakes have been withdrawn,
    /// refunding whatever could not be distributed (e.g. time during which nothing was staked)
    function endIncentive(IncentiveKey memory key) external returns (uint256 refund);

    /// @notice Transfers ownership of a deposit from the sender to the given recipient
    function transferDeposit(uint256 tokenId, address to) external;

    /// @notice Withdraws a Uniswap V3 LP token `tokenId` from this contract to the recipient `to`
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external;

    /// @notice Stakes a Uniswap V3 LP token
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Unstakes a Uniswap V3 LP token, crediting its reward to the deposit owner.
    /// @dev Callable by the deposit owner at any time; by anyone once the incentive has ended, or
    /// once the stake has been open at least an hour and spent at most a tenth of that time in range
    /// (such a position earns nothing but would otherwise keep diluting everyone else's share).
    /// Both terms are measured over the whole life of the stake, so the eviction condition cannot be
    /// created by moving the pool price within a single transaction.
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Freezes a stake's in-range measurement at the incentive's end. Callable by anyone
    /// from `endTime`, once per stake, and cheap enough to batch every outstanding stake through
    /// `multicall`.
    /// @dev The pool's in-range counter keeps running after `endTime`, so a stake read late is
    /// discounted by the elapsed delay to make sure it cannot be credited for uptime earned outside
    /// the reward window. Freezing the reading in the block `endTime` passes removes that discount
    /// entirely, so every honest stake is paid in full however late it is unstaked. The refundee has
    /// both the motive and the means to call this — the discount otherwise inflates their refund at
    /// their own stakers' expense, and their refund is blocked until every stake is closed anyway.
    function finalizeStake(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Transfers `amountRequested` of accrued `rewardToken` rewards from the contract to `to`
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external returns (uint256 reward);

    /// @notice Calculates the reward amount that will be received for the given stake
    /// @return reward The reward accrued to the NFT for the given incentive thus far
    /// @return secondsInsideStaked The seconds the position has been in range since it was staked
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        returns (uint256 reward, uint256 secondsInsideStaked);

    event IncentiveCreated(
        IERC20Minimal indexed rewardToken,
        IUniswapV3Pool indexed pool,
        uint256 startTime,
        uint256 endTime,
        address refundee,
        uint256 reward
    );

    event IncentiveEnded(bytes32 indexed incentiveId, uint256 refund);

    event DepositTransferred(uint256 indexed tokenId, address indexed oldOwner, address indexed newOwner);

    event TokenStaked(uint256 indexed tokenId, bytes32 indexed incentiveId, uint128 liquidity);

    event TokenUnstaked(uint256 indexed tokenId, bytes32 indexed incentiveId, uint256 reward);

    event StakeFinalized(uint256 indexed tokenId, bytes32 indexed incentiveId, uint256 secondsInside);

    event RewardClaimed(address indexed to, uint256 reward);
}
