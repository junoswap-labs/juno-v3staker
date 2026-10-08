// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';
import '../contracts/JunoswapV3Staker.sol';
import '../contracts/interfaces/IJunoswapV3Staker.sol';
import '../contracts/libraries/IncentiveId.sol';

/// @dev Audit M-01: the width floor, as a multiple of the pool's own tick spacing.
/// The repo has no forge-std, so the cheatcodes needed are called raw. The Uniswap pool and the
/// position manager are mocked: only what `stakeToken` reads is implemented, so this checks the
/// floor and says nothing about reward accounting against a real pool.
interface Vm {
    function warp(uint256 newTimestamp) external;

    function prank(address sender) external;

    function etch(address who, bytes calldata code) external;

    function expectRevert(bytes calldata revertData) external;
}

contract MockRewardToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Runtime code is copied to the address the staker derives for the pool, where there is no
/// storage, so every value is a constant. The price sits at tick 0, inside every test position.
contract MockPool10 {
    function tickSpacing() external pure virtual returns (int24) {
        return 10;
    }

    function liquidity() external pure returns (uint128) {
        return type(uint128).max;
    }

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

    function snapshotCumulativesInside(int24, int24)
        external
        pure
        returns (
            int56,
            uint160,
            uint32
        )
    {
        return (0, 0, 0);
    }
}

/// @dev Same pool, 0.3% tier: tick spacing 60.
contract MockPool60 is MockPool10 {
    function tickSpacing() external pure override returns (int24) {
        return 60;
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

contract JunoswapV3StakerMinRangeTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant FACTORY = address(0xFAC701);
    address constant TOKEN0 = address(0x1111);
    address constant TOKEN1 = address(0x2222);
    address constant LP = address(0x1B);
    uint24 constant FEE_001 = 100; // spacing 10 in MockPool10
    uint24 constant FEE_03 = 3000; // spacing 60 in MockPool60
    uint256 constant REWARD = 100 ether;
    uint128 constant LIQ = 1e18;

    MockRewardToken reward;
    MockPositionManager manager;
    uint256 start;
    uint256 end;

    function setUp() public {
        reward = new MockRewardToken();
        manager = new MockPositionManager();
        vm.warp(1_000_000);
        start = 1_000_100;
        end = start + 1 days;
        vm.etch(poolAddress(FEE_001), codeOf(address(new MockPool10())));
        vm.etch(poolAddress(FEE_03), codeOf(address(new MockPool60())));
    }

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

    function poolAddress(uint24 fee) internal pure returns (address) {
        return PoolAddress.computeAddress(FACTORY, PoolAddress.PoolKey({token0: TOKEN0, token1: TOKEN1, fee: fee}));
    }

    function newStaker(uint256 minRangeSpacings) internal returns (JunoswapV3Staker) {
        return new JunoswapV3Staker(IUniswapV3Factory(FACTORY), INonfungiblePositionManager(address(manager)), 30 days, 365 days, minRangeSpacings);
    }

    function keyFor(uint24 fee) internal view returns (IJunoswapV3Staker.IncentiveKey memory) {
        return
            IJunoswapV3Staker.IncentiveKey({
                rewardToken: IERC20Minimal(address(reward)),
                pool: IUniswapV3Pool(poolAddress(fee)),
                startTime: start,
                endTime: end,
                refundee: address(this)
            });
    }

    /// @dev A funded, started incentive on the pool of the given fee tier.
    function startedIncentive(JunoswapV3Staker staker, uint24 fee)
        internal
        returns (IJunoswapV3Staker.IncentiveKey memory key)
    {
        key = keyFor(fee);
        reward.mint(address(this), REWARD);
        reward.approve(address(staker), REWARD);
        vm.warp(1_000_000);
        staker.createIncentive(key, REWARD);
        vm.warp(start + 10);
    }

    function stakeWidth(
        JunoswapV3Staker staker,
        IJunoswapV3Staker.IncentiveKey memory key,
        uint24 fee,
        uint256 tokenId,
        int24 width
    ) internal {
        manager.setPosition(tokenId, TOKEN0, TOKEN1, fee, -width / 2, width / 2, LIQ);
        bytes memory data = abi.encode(key);
        vm.prank(address(manager));
        staker.onERC721Received(address(0), LP, tokenId, data);
    }

    function stakedLiquidity(
        JunoswapV3Staker staker,
        IJunoswapV3Staker.IncentiveKey memory key,
        uint256 tokenId
    ) internal view returns (uint128 liquidity) {
        (, , , liquidity, , ) = staker.stakes(tokenId, IncentiveId.compute(key));
    }

    function test_rejectsARangeNarrowerThanTenSpacings() public {
        setUp();
        JunoswapV3Staker staker = newStaker(10);
        IJunoswapV3Staker.IncentiveKey memory key = startedIncentive(staker, FEE_001);
        manager.setPosition(1, TOKEN0, TOKEN1, FEE_001, -50, 40, LIQ); // 90 wide: 9 spacings of 10
        bytes memory data = abi.encode(key);
        vm.expectRevert(bytes('JunoswapV3Staker::stakeToken: range too narrow'));
        vm.prank(address(manager));
        staker.onERC721Received(address(0), LP, 1, data);
    }

    function test_acceptsExactlyTenSpacings() public {
        setUp();
        JunoswapV3Staker staker = newStaker(10);
        IJunoswapV3Staker.IncentiveKey memory key = startedIncentive(staker, FEE_001);
        stakeWidth(staker, key, FEE_001, 2, 100); // 100 wide: exactly 10 spacings
        require(stakedLiquidity(staker, key, 2) == LIQ, 'a 10-spacing range should stake');
    }

    function test_theFloorScalesWithThePoolsTickSpacing() public {
        setUp();
        JunoswapV3Staker staker = newStaker(10);
        IJunoswapV3Staker.IncentiveKey memory key = startedIncentive(staker, FEE_03);

        // 0.3% tier, spacing 60: the floor is 600, so 500 is too narrow even though it would pass
        // the 100 that the 0.01% tier needs.
        manager.setPosition(3, TOKEN0, TOKEN1, FEE_03, -250, 250, LIQ);
        bytes memory data = abi.encode(key);
        vm.expectRevert(bytes('JunoswapV3Staker::stakeToken: range too narrow'));
        vm.prank(address(manager));
        staker.onERC721Received(address(0), LP, 3, data);

        stakeWidth(staker, key, FEE_03, 4, 600);
        require(stakedLiquidity(staker, key, 4) == LIQ, 'a 600-wide range should stake at spacing 60');
    }

    function test_zeroDisablesTheFloor() public {
        setUp();
        JunoswapV3Staker staker = newStaker(0);
        IJunoswapV3Staker.IncentiveKey memory key = startedIncentive(staker, FEE_001);
        stakeWidth(staker, key, FEE_001, 5, 10); // a single spacing
        require(stakedLiquidity(staker, key, 5) == LIQ, 'no floor should mean any width stakes');
    }

    function test_theFloorIsReadableAndFixed() public {
        setUp();
        require(newStaker(10).minRangeSpacings() == 10, 'minRangeSpacings not exposed');
    }

    function test_stakeEligibilityReportsTheReasonAStakeWouldRevertWith() public {
        setUp();
        JunoswapV3Staker staker = newStaker(10);
        IJunoswapV3Staker.IncentiveKey memory key = startedIncentive(staker, FEE_001);

        manager.setPosition(6, TOKEN0, TOKEN1, FEE_001, -50, 40, LIQ);
        (bool ok, string memory reason) = staker.stakeEligibility(key, 6);
        require(!ok, 'a 9-spacing range is not eligible');
        require(
            keccak256(bytes(reason)) == keccak256(bytes('JunoswapV3Staker::stakeToken: range too narrow')),
            reason
        );

        manager.setPosition(7, TOKEN0, TOKEN1, FEE_001, -50, 50, LIQ);
        (ok, reason) = staker.stakeEligibility(key, 7);
        require(ok && bytes(reason).length == 0, 'a 10-spacing range is eligible');

        manager.setPosition(8, TOKEN0, TOKEN1, FEE_001, -50, 50, 0);
        (ok, reason) = staker.stakeEligibility(key, 8);
        require(!ok, 'zero liquidity is not eligible');

        stakeWidth(staker, key, FEE_001, 7, 100);
        (ok, ) = staker.stakeEligibility(key, 7);
        require(!ok, 'an already staked token is not eligible');
    }
}
