// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHEX} from "../../src/interfaces/IHEX.sol";

/// @dev Simplified HEX mock for unit tests
contract MockHEX is IHEX {
    uint256 public constant HEARTS_PER_HEX = 1e8;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => Stake[]) internal stakes;

    uint256 public hexDay = 1000;
    /// @dev Simulates HEX EES penalty on early endStake (basis points of principal)
    uint256 public eesPenaltyBps;

    function currentDay() external view returns (uint256) {
        return hexDay;
    }
    uint40 public nextStakeId = 1;

    struct Stake {
        uint40 stakeId;
        uint72 stakedHearts;
        uint72 stakeShares;
        uint16 lockedDay;
        uint16 stakedDays;
        uint16 unlockedDay;
        bool isAutoStake;
    }

    function mint(address to, uint256 hearts) external {
        balanceOf[to] += hearts;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function stakeCount(address stakerAddr) external view returns (uint256) {
        return stakes[stakerAddr].length;
    }

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
        )
    {
        Stake memory s = stakes[stakerAddr][stakeIndex];
        return (
            s.stakeId,
            s.stakedHearts,
            s.stakeShares,
            s.lockedDay,
            s.stakedDays,
            s.unlockedDay,
            s.isAutoStake
        );
    }

    function globalInfo() external view returns (uint256[13] memory g) {
        g[4] = hexDay;
        return g;
    }

    function calcPayoutRewards(uint256 stakeShares, uint256 beginDay, uint256 endDay)
        external
        pure
        returns (uint256 payout)
    {
        payout = stakeShares * (endDay - beginDay) / 100;
    }

    function startStake(uint256 newStakedHearts, uint256 newStakedDays) external {
        uint40 id = nextStakeId++;
        stakes[msg.sender].push(
            Stake({
                stakeId: id,
                stakedHearts: uint72(newStakedHearts),
                stakeShares: uint72(newStakedHearts + newStakedDays),
                lockedDay: uint16(hexDay + 1),
                stakedDays: uint16(newStakedDays),
                unlockedDay: 0,
                isAutoStake: false
            })
        );
        balanceOf[msg.sender] -= newStakedHearts;
    }

    function setEesPenaltyBps(uint256 bps) external {
        eesPenaltyBps = bps;
    }

    function endStake(uint256 stakeIndex, uint48 stakeIdParam) external {
        Stake[] storage list = stakes[msg.sender];
        require(stakeIndex < list.length, "idx");
        require(list[stakeIndex].stakeId == stakeIdParam, "id");
        uint256 hearts = uint256(list[stakeIndex].stakedHearts);
        uint256 penalty = hearts * eesPenaltyBps / 10_000;
        list[stakeIndex] = list[list.length - 1];
        list.pop();
        balanceOf[msg.sender] += hearts - penalty;
    }

    function seedStake(
        address owner,
        uint72 hearts,
        uint16 stakedDays,
        uint16 lockedDay
    ) external returns (uint40 id) {
        id = nextStakeId++;
        stakes[owner].push(
            Stake({
                stakeId: id,
                stakedHearts: hearts,
                stakeShares: uint72(uint256(hearts) + stakedDays),
                lockedDay: lockedDay,
                stakedDays: stakedDays,
                unlockedDay: 0,
                isAutoStake: false
            })
        );
    }
}