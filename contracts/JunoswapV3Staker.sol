// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IJunoswapV3Staker.sol';
import './libraries/IncentiveId.sol';
import './libraries/RewardMath.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/TransferHelperExtended.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';
import '@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

/// @title Juno V3 staking
/// @notice Fork of UniswapV3Staker where the reward is shared between the staked positions only.
/// Uniswap measures a position against the liquidity-seconds of the *entire pool*, so an incentive
/// on a pool where only a slice of the TVL is staked pays out only that slice of the budget. Here
/// the budget drips at totalReward / duration and every second is split between the positions
/// actually staked in the incentive, so a launchpad's fixed reward reaches its participants.
contract JunoswapV3Staker is IJunoswapV3Staker, Multicall {
    using LowGasSafeMath for uint256;

    /// @dev How long a stake must have existed before anyone but its owner may close it out for
    /// having earned nothing. Long enough that no single transaction can manufacture the condition.
    uint256 private constant MIN_EVICTION_STAKE_AGE = 1 hours;

    /// @dev A stake is evictable once its in-range time is at most this fraction of its staked life.
    uint256 private constant EVICTION_UPTIME_DIVISOR = 10;

    /// @notice Represents a staking incentive
    struct Incentive {
        uint256 totalReward;
        uint256 totalRewardUnclaimed;
        uint256 rewardPerLiquidityX128;
        uint128 stakedLiquidity;
        uint64 lastUpdateTime;
        uint64 numberOfStakes;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    /// @dev The last two fields pack into the same slot as the three before them (232 of 256 bits),
    /// so freezing a stake's uptime costs no extra storage slot.
    struct Stake {
        uint256 rewardPerLiquidityInitialX128;
        uint32 secondsInsideInitial;
        uint32 stakeTime;
        uint128 liquidity;
        uint32 secondsInsideFinal;
        bool finalized;
    }

    /// @inheritdoc IJunoswapV3Staker
    IUniswapV3Factory public immutable override factory;
    /// @inheritdoc IJunoswapV3Staker
    INonfungiblePositionManager public immutable override nonfungiblePositionManager;

    /// @inheritdoc IJunoswapV3Staker
    uint256 public immutable override maxIncentiveStartLeadTime;
    /// @inheritdoc IJunoswapV3Staker
    uint256 public immutable override maxIncentiveDuration;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[tokenId][incentiveId] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) public override stakes;

    /// @dev rewards[rewardToken][owner] => uint256
    mapping(IERC20Minimal => mapping(address => uint256)) public override rewards;

    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration
    ) {
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;
    }

    /// @inheritdoc IJunoswapV3Staker
    function createIncentive(IncentiveKey memory key, uint256 reward) external override {
        require(reward > 0, 'JunoswapV3Staker::createIncentive: reward must be positive');
        // topping up is only possible before the incentive starts, so the drip rate is fixed for its
        // whole life and the accumulator never has to be rebased
        require(
            block.timestamp <= key.startTime,
            'JunoswapV3Staker::createIncentive: start time must be now or in the future'
        );
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'JunoswapV3Staker::createIncentive: start time too far into future'
        );
        require(key.startTime < key.endTime, 'JunoswapV3Staker::createIncentive: start time must be before end time');
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            'JunoswapV3Staker::createIncentive: incentive duration is too long'
        );
        require(key.endTime <= type(uint32).max, 'JunoswapV3Staker::createIncentive: end time too far into future');

        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        // credit what actually arrived, not what was asked for: a fee-on-transfer or rebasing token
        // would otherwise leave this incentive's books above the shared balance, and the shortfall
        // is paid out of any other incentive using the same reward token until claiming reverts
        uint256 balanceBefore = key.rewardToken.balanceOf(address(this));
        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);
        uint256 received = key.rewardToken.balanceOf(address(this)).sub(balanceBefore);
        require(received > 0, 'JunoswapV3Staker::createIncentive: no reward received');

        // .add, not +: this contract is on 0.7.6, where a plain addition wraps silently and would
        // slip a huge reward past the cap below
        uint256 totalReward = incentive.totalReward.add(received);
        // keeps the X128 accumulator math well clear of overflow, even for a single wei of liquidity
        require(totalReward <= type(uint128).max, 'JunoswapV3Staker::createIncentive: reward too large');

        incentive.totalReward = totalReward;
        incentive.totalRewardUnclaimed = incentive.totalRewardUnclaimed.add(received);

        emit IncentiveCreated(key.rewardToken, key.pool, key.startTime, key.endTime, key.refundee, received);
    }

    /// @inheritdoc IJunoswapV3Staker
    function endIncentive(IncentiveKey memory key) external override returns (uint256 refund) {
        require(block.timestamp >= key.endTime, 'JunoswapV3Staker::endIncentive: cannot end incentive before end time');

        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        refund = incentive.totalRewardUnclaimed;

        require(refund > 0, 'JunoswapV3Staker::endIncentive: no refund available');
        require(
            incentive.numberOfStakes == 0,
            'JunoswapV3Staker::endIncentive: cannot end incentive while deposits are staked'
        );

        // whatever nobody was staked for, and whatever was forfeited by out of range positions
        incentive.totalRewardUnclaimed = 0;
        TransferHelperExtended.safeTransfer(address(key.rewardToken), key.refundee, refund);

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @notice Upon receiving a Uniswap V3 ERC721, creates the token deposit setting owner to `from`.
    /// Also stakes the token in one or more incentives if `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(msg.sender == address(nonfungiblePositionManager), 'JunoswapV3Staker::onERC721Received: not a univ3 nft');

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager.positions(tokenId);

        deposits[tokenId] = Deposit({owner: from, numberOfStakes: 0, tickLower: tickLower, tickUpper: tickUpper});
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 160) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IJunoswapV3Staker
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'JunoswapV3Staker::transferDeposit: invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, 'JunoswapV3Staker::transferDeposit: can only be called by deposit owner');
        deposits[tokenId].owner = to;
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IJunoswapV3Staker
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external override {
        require(to != address(this), 'JunoswapV3Staker::withdrawToken: cannot withdraw to staker');
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'JunoswapV3Staker::withdrawToken: cannot withdraw token while staked');
        require(deposit.owner == msg.sender, 'JunoswapV3Staker::withdrawToken: only owner can withdraw token');

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    /// @inheritdoc IJunoswapV3Staker
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        require(deposits[tokenId].owner == msg.sender, 'JunoswapV3Staker::stakeToken: only owner can stake token');

        _stakeToken(key, tokenId);
    }

    /// @inheritdoc IJunoswapV3Staker
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        Deposit memory deposit = deposits[tokenId];
        bytes32 incentiveId = IncentiveId.compute(key);
        Stake memory stake = stakes[tokenId][incentiveId];

        require(stake.liquidity != 0, 'JunoswapV3Staker::unstakeToken: stake does not exist');

        Incentive storage incentive = incentives[incentiveId];

        // bring the accumulator up to date while this position is still counted in stakedLiquidity
        uint256 currentTime = _accrue(incentive, key);

        (uint256 stakedSeconds, uint256 secondsInsideStaked) = _stakeUptime(key, deposit, stake, currentTime);

        if (deposit.owner != msg.sender) {
            // anyone may unstake once the incentive is over, or close out a stake that has existed
            // long enough to judge and spent almost none of that time in range: it earns nothing
            // while still diluting everyone else. Both terms are measured over the whole life of
            // the stake, so no single swap can manufacture the condition the way a spot tick check
            // could -- moving the price now cannot un-earn seconds already accrued.
            require(
                block.timestamp >= key.endTime ||
                    (stakedSeconds >= MIN_EVICTION_STAKE_AGE &&
                        secondsInsideStaked * EVICTION_UPTIME_DIVISOR <= stakedSeconds),
                'JunoswapV3Staker::unstakeToken: only owner can unstake an earning token before incentive end time'
            );
        }

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;
        incentive.stakedLiquidity -= stake.liquidity;

        uint256 reward =
            RewardMath.computeRewardAmount(
                incentive.rewardPerLiquidityX128 - stake.rewardPerLiquidityInitialX128,
                stake.liquidity,
                stakedSeconds,
                secondsInsideStaked,
                incentive.totalRewardUnclaimed
            );

        incentive.totalRewardUnclaimed -= reward;
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[key.rewardToken][deposit.owner] += reward;

        delete stakes[tokenId][incentiveId];
        emit TokenUnstaked(tokenId, incentiveId, reward);
    }

    /// @inheritdoc IJunoswapV3Staker
    function finalizeStake(IncentiveKey memory key, uint256 tokenId) external override {
        require(block.timestamp >= key.endTime, 'JunoswapV3Staker::finalizeStake: incentive not ended');

        bytes32 incentiveId = IncentiveId.compute(key);
        Stake storage stored = stakes[tokenId][incentiveId];
        require(stored.liquidity != 0, 'JunoswapV3Staker::finalizeStake: stake does not exist');
        require(!stored.finalized, 'JunoswapV3Staker::finalizeStake: already finalized');

        // store the clamped delta, not the raw counter: called in the block endTime passes, the
        // clamp is zero and the reading is exact
        uint256 inside = _measureUptime(key, deposits[tokenId], stored);
        stored.secondsInsideFinal = uint32(inside);
        stored.finalized = true;

        emit StakeFinalized(tokenId, incentiveId, inside);
    }

    /// @inheritdoc IJunoswapV3Staker
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external override returns (uint256 reward) {
        reward = rewards[rewardToken][msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[rewardToken][msg.sender] -= reward;
        TransferHelperExtended.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IJunoswapV3Staker
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        override
        returns (uint256 reward, uint256 secondsInsideStaked)
    {
        bytes32 incentiveId = IncentiveId.compute(key);
        Stake memory stake = stakes[tokenId][incentiveId];
        require(stake.liquidity > 0, 'JunoswapV3Staker::getRewardInfo: stake does not exist');

        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];

        uint256 currentTime = block.timestamp < key.endTime ? block.timestamp : key.endTime;
        if (
            incentive.lastUpdateTime != 0 && currentTime > incentive.lastUpdateTime && incentive.stakedLiquidity > 0
        ) {
            incentive.rewardPerLiquidityX128 += RewardMath.computeRewardPerLiquidityDeltaX128(
                incentive.totalReward,
                key.endTime - key.startTime,
                incentive.stakedLiquidity,
                currentTime - incentive.lastUpdateTime
            );
        }

        uint256 stakedSeconds;
        (stakedSeconds, secondsInsideStaked) = _stakeUptime(key, deposit, stake, currentTime);

        reward = RewardMath.computeRewardAmount(
            incentive.rewardPerLiquidityX128 - stake.rewardPerLiquidityInitialX128,
            stake.liquidity,
            stakedSeconds,
            secondsInsideStaked,
            incentive.totalRewardUnclaimed
        );
    }

    /// @dev The seconds a stake has been open (capped at endTime) and, of those, the seconds the
    /// pool price was inside its range.
    function _stakeUptime(
        IncentiveKey memory key,
        Deposit memory deposit,
        Stake memory stake,
        uint256 currentTime
    ) private view returns (uint256 stakedSeconds, uint256 secondsInsideStaked) {
        stakedSeconds = currentTime > stake.stakeTime ? currentTime - stake.stakeTime : 0;
        secondsInsideStaked = stake.finalized
            ? uint256(stake.secondsInsideFinal)
            : _measureUptime(key, deposit, stake);
    }

    /// @dev In-range seconds earned since the token was staked, with any that could have accrued
    /// after endTime removed.
    /// @dev The pool's secondsInside counter keeps growing after endTime while stakedSeconds stops
    /// there, so an unclamped ratio would let a position that was never in range during the
    /// incentive reach a full payout just by staying staked until the price sat in its range for
    /// long enough afterwards. At most (block.timestamp - endTime) of the observed growth can have
    /// happened after the incentive ended, so subtracting that much lower-bounds the in-range time
    /// genuinely earned inside the reward window. The bound is exact when read at or before endTime
    /// and loosens by one second per second of delay, which is why finalizeStake exists: freezing
    /// the reading at endTime makes the subtraction zero and pays every honest stake in full, no
    /// matter how late it is unstaked.
    function _measureUptime(
        IncentiveKey memory key,
        Deposit memory deposit,
        Stake memory stake
    ) private view returns (uint256) {
        (, , uint32 secondsInside) = key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);

        // NOTE: this subtraction is deliberate modular arithmetic on a Uniswap accumulator built to
        // wrap, and is correct on 0.7.6. If this contract is ever ported to 0.8, it MUST be wrapped
        // in an `unchecked` block or unstakeToken will revert permanently once the counter wraps.
        uint256 inside = uint256(uint32(secondsInside - stake.secondsInsideInitial));

        uint256 postEnd = block.timestamp > key.endTime ? block.timestamp - key.endTime : 0;
        return inside > postEnd ? inside - postEnd : 0;
    }

    /// @dev Brings the reward accumulator up to date and returns the time it is accurate as of
    /// (block.timestamp, capped at endTime). Seconds during which nothing was staked accrue nothing,
    /// so that reward is left for the refundee rather than handed to whoever stakes next.
    function _accrue(Incentive storage incentive, IncentiveKey memory key) private returns (uint256 currentTime) {
        currentTime = block.timestamp < key.endTime ? block.timestamp : key.endTime;
        uint256 lastUpdateTime = incentive.lastUpdateTime;
        if (lastUpdateTime != 0 && currentTime > lastUpdateTime && incentive.stakedLiquidity > 0) {
            incentive.rewardPerLiquidityX128 += RewardMath.computeRewardPerLiquidityDeltaX128(
                incentive.totalReward,
                key.endTime - key.startTime,
                incentive.stakedLiquidity,
                currentTime - lastUpdateTime
            );
        }
        incentive.lastUpdateTime = uint64(currentTime);
    }

    function _isOutOfRange(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (bool) {
        (, int24 tick, , , , , ) = pool.slot0();
        return tick < tickLower || tick >= tickUpper;
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        require(block.timestamp >= key.startTime, 'JunoswapV3Staker::stakeToken: incentive not started');
        require(block.timestamp < key.endTime, 'JunoswapV3Staker::stakeToken: incentive ended');

        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        require(incentive.totalRewardUnclaimed > 0, 'JunoswapV3Staker::stakeToken: non-existent incentive');
        require(stakes[tokenId][incentiveId].liquidity == 0, 'JunoswapV3Staker::stakeToken: token already staked');

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            NFTPositionInfo.getPositionInfo(factory, nonfungiblePositionManager, tokenId);

        require(pool == key.pool, 'JunoswapV3Staker::stakeToken: token pool is not the incentive pool');
        require(liquidity > 0, 'JunoswapV3Staker::stakeToken: cannot stake token with 0 liquidity');
        // an out of range position earns nothing but still occupies the accumulator's denominator,
        // diluting everyone who is earning, so it must not be let in to begin with
        require(!_isOutOfRange(pool, tickLower, tickUpper), 'JunoswapV3Staker::stakeToken: position out of range');
        // liquidity per unit of capital is unbounded as a range narrows, so a position far out of
        // range can be minted at maxLiquidityPerTick (1.15e34 at the 0.3% tier) for dust and crush
        // every real staker. The pool's own active liquidity is a market-sized ceiling dust cannot reach.
        require(liquidity <= pool.liquidity(), 'JunoswapV3Staker::stakeToken: liquidity exceeds pool');

        _accrue(incentive, key);

        deposits[tokenId].numberOfStakes++;
        incentive.numberOfStakes++;
        // .add + explicit bound, not +=: 0.7.6 does not check this uint128 accumulation
        uint256 newStakedLiquidity = uint256(incentive.stakedLiquidity).add(liquidity);
        require(newStakedLiquidity <= type(uint128).max, 'JunoswapV3Staker::stakeToken: staked liquidity overflow');
        incentive.stakedLiquidity = uint128(newStakedLiquidity);

        (, , uint32 secondsInside) = pool.snapshotCumulativesInside(tickLower, tickUpper);

        stakes[tokenId][incentiveId] = Stake({
            rewardPerLiquidityInitialX128: incentive.rewardPerLiquidityX128,
            secondsInsideInitial: secondsInside,
            stakeTime: uint32(block.timestamp),
            liquidity: liquidity,
            secondsInsideFinal: 0,
            finalized: false
        });

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }
}
