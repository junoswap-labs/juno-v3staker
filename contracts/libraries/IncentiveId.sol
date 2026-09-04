// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '../interfaces/IJunoswapV3Staker.sol';

library IncentiveId {
    /// @notice Calculate the key for a staking incentive
    function compute(IJunoswapV3Staker.IncentiveKey memory key) internal pure returns (bytes32 incentiveId) {
        return keccak256(abi.encode(key));
    }
}
