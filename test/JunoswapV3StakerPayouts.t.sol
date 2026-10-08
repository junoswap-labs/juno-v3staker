// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';
import '../contracts/JunoswapV3Staker.sol';
import '../contracts/interfaces/IJunoswapV3Staker.sol';
import '../contracts/libraries/IncentiveId.sol';

/// @dev Payout accounting of JunoswapV3Staker: uptime scaling, eviction, several stakers and NFTs,
/// and hostile reward tokens. The repo has no forge-std, so the cheatcodes are called raw. The pool
/// and position manager are mocks: the pool's in-range seconds are set by the test, so these check
/// the staker's own bookkeeping and say nothing about a real Uniswap pool.
interface Vm {
    function warp(uint256 newTimestamp) external;

    function prank(address sender) external;

    function etch(address who, bytes calldata code) external;

    function expectRevert(bytes calldata revertData) external;
}

/// @dev Test-controlled pool state. It sits at a fixed address because the pool mock is etched
/// (code only, no storage) and reads everything from here.
contract PoolControl {
    mapping(int24 => uint32) public inside;
    uint128 public poolLiquidity;

    function setPoolLiquidity(uint128 value) external {
        poolLiquidity = value;
    }

    function setInside(int24 tickLower, uint32 secondsInside) external {
        inside[tickLower] = secondsInside;
    }
}

contract ControlledPool {
    address constant CTL = address(0xC710);

    function tickSpacing() external pure returns (int24) {
        return 10;
    }

    function liquidity() external view returns (uint128) {
        return PoolControl(CTL).poolLiquidity();
    }

    /// @dev Price at tick 0, which is inside every position the tests mint.
    function slot0()
        external
        pure
        returns (
            uint160,
            int24,
            uint16,
            uint16,
            uint16,
            uint8,
            bool
        )
    {
        return (0, 0, 0, 0, 0, 0, true);
    }

    function snapshotCumulativesInside(int24 tickLower, int24)
        external
        view
        returns (
            int56,
            uint160,
            uint32
        )
    {
        return (0, 0, PoolControl(CTL).inside(tickLower));
    }
}

contract MockPositionManager {
    struct Pos {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }
    mapping(uint256 => Pos) public pos;

    function setPosition(
        uint256 tokenId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        pos[tokenId] = Pos(token0, token1, fee, tickLower, tickUpper, liquidity);
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        Pos memory p = pos[tokenId];
        return (0, address(0), p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, p.liquidity, 0, 0, 0, 0);
    }
}

contract PlainToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    /// @dev Basis points burned on every move, standing in for a fee-on-transfer token.
    uint256 public feeBps;

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(
        address from,
        address to,
        uint256 amount
    ) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount - (amount * feeBps) / 10_000;
    }
}

/// @dev ERC777-style token: tells a contract recipient about the incoming transfer after the balance
/// has moved, which is the window a reentrancy attack uses.
contract HookToken is PlainToken {
    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        uint256 size;
        assembly {
            size := extcodesize(to)
        }
        if (size > 0) Receiver(to).tokensReceived();
        return true;
    }
}

interface Receiver {
    function tokensReceived() external;
}

/// @dev A staking account that, on receiving reward tokens, tries to claim again.
contract ReentrantClaimer is Receiver {
    JunoswapV3Staker staker;
    IERC20Minimal token;
    uint256 public reentries;
    uint256 public reentrantPayout;

    constructor(JunoswapV3Staker _staker, IERC20Minimal _token) {
        staker = _staker;
        token = _token;
    }

    function claim() external {
        staker.claimReward(token, address(this), 0);
    }

    function tokensReceived() external override {
        reentries++;
        if (reentries == 1) {
            uint256 before = token.balanceOf(address(this));
            staker.claimReward(token, address(this), 0);
            reentrantPayout = token.balanceOf(address(this)) - before;
        }
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract JunoswapV3StakerPayoutsTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant FACTORY = address(0xFAC701);
    address constant TOKEN0 = address(0x1111);
    address constant TOKEN1 = address(0x2222);
    address constant CTL = address(0xC710);
    uint24 constant FEE = 100;
    uint256 constant T0 = 1_000_000;
    uint256 constant DURATION = 10 hours; // long enough for the one-hour eviction rule
    uint256 constant REWARD = 36000 ether; // 1 token per second

    address constant A = address(0xA1);
    address constant B = address(0xB2);
    address constant C = address(0xC3);
    address constant STRANGER = address(0x5757);

    PlainToken reward;
    MockPositionManager manager;
    JunoswapV3Staker staker;
    IJunoswapV3Staker.IncentiveKey key;
    bytes32 incentiveId;

    function setUp() public {
        manager = new MockPositionManager();
        vm.etch(CTL, codeOf(address(new PoolControl())));
        PoolControl(CTL).setPoolLiquidity(type(uint128).max);
        vm.etch(poolAddress(), codeOf(address(new ControlledPool())));
        staker = new JunoswapV3Staker(
            IUniswapV3Factory(FACTORY),
            INonfungiblePositionManager(address(manager)),
            30 days,
            365 days,
            10
        );
        reward = new PlainToken();
        _openIncentive(IERC20Minimal(address(reward)));
    }

    function _openIncentive(IERC20Minimal token) internal {
        vm.warp(T0 - 10);
        key = IJunoswapV3Staker.IncentiveKey({
            rewardToken: token,
            pool: IUniswapV3Pool(poolAddress()),
            startTime: T0,
            endTime: T0 + DURATION,
            refundee: address(this)
        });
        incentiveId = IncentiveId.compute(key);
        PlainToken(address(token)).mint(address(this), REWARD);
        PlainToken(address(token)).approve(address(staker), REWARD);
        staker.createIncentive(key, REWARD);
    }

    // -- helpers --

    function codeOf(address a) internal view returns (bytes memory c) {
        uint256 n;
        assembly {
            n := extcodesize(a)
        }
        c = new bytes(n);
        assembly {
            extcodecopy(a, add(c, 0x20), 0, n)
        }
    }

    function poolAddress() internal pure returns (address) {
        return PoolAddress.computeAddress(FACTORY, PoolAddress.PoolKey({token0: TOKEN0, token1: TOKEN1, fee: FEE}));
    }

    /// @dev Each token id gets its own lower tick, so the control contract can give each position
    /// its own in-range clock. Width 2000 clears the width floor.
    function lowerOf(uint256 tokenId) internal pure returns (int24) {
        return -1000 - int24(tokenId) * 10;
    }

    function stake(
        address owner,
        uint256 tokenId,
        uint128 liquidity
    ) internal {
        int24 lower = lowerOf(tokenId);
        manager.setPosition(tokenId, TOKEN0, TOKEN1, FEE, lower, lower + 2000, liquidity);
        bytes memory data = abi.encode(key);
        vm.prank(address(manager));
        staker.onERC721Received(address(0), owner, tokenId, data);
    }

    function unstake(address caller, uint256 tokenId) internal {
        vm.prank(caller);
        staker.unstakeToken(key, tokenId);
    }

    /// @dev The position was inside its range for `secondsInside` seconds since it was staked.
    function setInside(uint256 tokenId, uint32 secondsInside) internal {
        PoolControl(CTL).setInside(lowerOf(tokenId), secondsInside);
    }

    function owed(address who) internal view returns (uint256) {
        return staker.rewards(IERC20Minimal(address(reward)), who);
    }

    function near(
        uint256 got,
        uint256 want,
        string memory what
    ) internal pure {
        uint256 diff = got > want ? got - want : want - got;
        require(diff <= 1e6, what); // a few wei of mulDiv rounding on 1e18-scaled amounts
    }

    // -- 1. uptime scaling and eviction --

    function test_outOfRangeTimeEarnsNothing() public {
        vm.warp(T0);
        stake(A, 1, 1e18);
        vm.warp(T0 + 500);
        setInside(1, 125); // in range for a quarter of the 500 s it was staked
        unstake(A, 1);
        near(owed(A), 125 ether, 'dripped 500, scaled by 125/500');

        // the forfeited 375 plus every second nobody was staked stays in the incentive
        vm.warp(T0 + DURATION);
        require(staker.endIncentive(key) == REWARD - owed(A), 'refund = budget minus what was paid');
    }

    function test_neverInRangeEarnsNothing() public {
        vm.warp(T0);
        stake(A, 1, 1e18);
        vm.warp(T0 + 500);
        setInside(1, 0);
        unstake(A, 1);
        require(owed(A) == 0, 'a position that was never in range is paid nothing');
    }

    function test_strangerCannotEvictBeforeAnHour() public {
        vm.warp(T0);
        stake(A, 1, 1e18);
        vm.warp(T0 + 3599);
        setInside(1, 0);
        vm.expectRevert(
            bytes('JunoswapV3Staker::unstakeToken: only owner can unstake an earning token before incentive end time')
        );
        unstake(STRANGER, 1);
    }

    function test_strangerEvictsAnIdleStakeAfterAnHour() public {
        vm.warp(T0);
        stake(A, 1, 1e18);
        vm.warp(T0 + 1 hours);
        setInside(1, 0);
        unstake(STRANGER, 1);
        require(owed(STRANGER) == 0 && owed(A) == 0, 'an idle stake earned nothing, and the caller gains nothing');
        (, , , uint128 liquidity, , ) = staker.stakes(1, incentiveId);
        require(liquidity == 0, 'the stake is closed');
    }

    function test_evictionThresholdIsTenPercentOfTheStakeAge() public {
        vm.warp(T0);
        stake(A, 1, 1e18);
        stake(B, 2, 1e18);
        vm.warp(T0 + 1 hours);

        setInside(1, 361); // 10.03%: earning, protected
        vm.expectRevert(
            bytes('JunoswapV3Staker::unstakeToken: only owner can unstake an earning token before incentive end time')
        );
        unstake(STRANGER, 1);

        setInside(2, 360); // exactly 10%: may be closed
        unstake(STRANGER, 2);
        near(owed(B), 360 ether * 1 / 2, 'an evicted stake is still paid what it earned, to its owner');
    }

    function test_anyoneMayUnstakeOnceTheIncentiveIsOver() public {
        vm.warp(T0);
        stake(A, 1, 1e18);
        vm.warp(T0 + DURATION);
        setInside(1, uint32(DURATION));
        unstake(STRANGER, 1);
        near(owed(A), REWARD, 'the reward goes to the owner, not to the caller');
        require(owed(STRANGER) == 0, 'the caller earns nothing');
    }

    // -- 2. several stakers, several NFTs --

    function test_threeStakersAndTwoNftsFromOneOwner() public {
        // r = 1 token/s. Liquidity: A#1 = 1, B#3 = 2, A#2 = 3, C#4 = 4 (units of 1e18).
        vm.warp(T0);
        stake(A, 1, 1e18);
        vm.warp(T0 + 100);
        stake(B, 3, 2e18);
        vm.warp(T0 + 200);
        stake(A, 2, 3e18);
        stake(C, 4, 4e18);

        vm.warp(T0 + 400);
        setInside(1, 400);
        unstake(A, 1);
        vm.warp(T0 + 600);
        setInside(3, 500);
        unstake(B, 3);
        vm.warp(T0 + 800);
        setInside(2, 600);
        setInside(4, 600);
        unstake(A, 2);
        unstake(C, 4);

        // 0-100: #1 alone.   100-200: #1:#3 = 1:2.   200-400: 1:2:3:4.
        // 400-600: #3:#2:#4 = 2:3:4.   600-800: #2:#4 = 3:4.   800-end: nobody.
        uint256 u = 1 ether; // runtime values, since Solidity folds literal division into rationals
        uint256 e1 = 100 * u + (100 * u) / 3 + (200 * u) / 10;
        uint256 e3 = (200 * u) / 3 + (400 * u) / 10 + (400 * u) / 9;
        uint256 e2 = (600 * u) / 10 + (600 * u) / 9 + (600 * u) / 7;
        uint256 e4 = (800 * u) / 10 + (800 * u) / 9 + (800 * u) / 7;

        near(owed(A), e1 + e2, 'A: two NFTs in one incentive are paid separately and summed');
        near(owed(B), e3, 'B');
        near(owed(C), e4, 'C');

        // conservation: paid + refund is exactly the budget, and the idle 200 s is in the refund
        vm.warp(T0 + DURATION);
        uint256 paid = owed(A) + owed(B) + owed(C);
        uint256 refund = staker.endIncentive(key);
        require(paid + refund == REWARD, 'paid plus refund equals the budget');
        require(refund >= DURATION * 1 ether - 800 ether, 'every second with nothing staked is refunded');
    }

    // -- 3. hostile reward tokens --

    function test_feeOnTransferRewardCreditsOnlyWhatArrived() public {
        PlainToken fot = new PlainToken();
        fot.setFeeBps(1000); // 10% lost on every move
        _openIncentive(IERC20Minimal(address(fot)));

        (uint256 totalReward, uint256 unclaimed, , , , ) = staker.incentives(incentiveId);
        uint256 arrived = (REWARD * 9) / 10;
        require(totalReward == arrived && unclaimed == arrived, 'books hold what arrived, not what was sent');
        require(fot.balanceOf(address(staker)) == arrived, 'and the staker really holds that much');

        // nobody stakes: everything that arrived is refunded, and paying it out must not exceed the balance
        vm.warp(T0 + DURATION);
        require(staker.endIncentive(key) == arrived, 'refund is what was credited');
    }

    function test_reentrantClaimCannotPayTwice() public {
        HookToken hook = new HookToken();
        _openIncentive(IERC20Minimal(address(hook)));
        ReentrantClaimer attacker = new ReentrantClaimer(staker, IERC20Minimal(address(hook)));

        vm.warp(T0);
        stake(address(attacker), 1, 1e18);
        vm.warp(T0 + 500);
        setInside(1, 500);
        unstake(address(attacker), 1);
        uint256 entitled = staker.rewards(IERC20Minimal(address(hook)), address(attacker));
        require(entitled > 0, 'the attacker earned something to claim');

        attacker.claim();

        require(attacker.reentries() >= 1, 'the token did call back into the attacker');
        require(attacker.reentrantPayout() == 0, 'the nested claim paid nothing');
        require(hook.balanceOf(address(attacker)) == entitled, 'the attacker received exactly what it was owed');
        require(staker.rewards(IERC20Minimal(address(hook)), address(attacker)) == 0, 'and nothing is left to claim');
        require(
            hook.balanceOf(address(staker)) == REWARD - entitled,
            'the rest of the budget is still in the staker'
        );
    }
}
