// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice HEX staking interface (PulseChain: 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39)
interface IHEX {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    function stakeCount(address stakerAddr) external view returns (uint256);
    function stakeLists(address stakerAddr, uint256 stakeIndex)
        external
        view
        returns (
            uint40 stakeId,
            uint72 stakedHearts,
            uint72 stakeShares,
            uint16 lockedDay,
            uint16 stakedDays,
            uint16 unlockedDay,
            bool isAutoStake
        );

    /// @dev Prefer currentDay() over globalInfo()[4] for clarity
    function currentDay() external view returns (uint256);
    function globalInfo() external view returns (uint256[13] memory);

    function calcPayoutRewards(uint256 stakeShares, uint256 beginDay, uint256 endDay)
        external
        view
        returns (uint256 payout);

    function startStake(uint256 newStakedHearts, uint256 newStakedDays) external;
    function endStake(uint256 stakeIndex, uint48 stakeIdParam) external;
}