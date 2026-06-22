// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPulseXPair} from "../../src/interfaces/IPulseXPair.sol";

contract MockPair is IPulseXPair {
    address public immutable token0;
    address public immutable token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address token0_, address token1_, uint112 r0, uint112 r1) {
        token0 = token0_;
        token1 = token1_;
        reserve0 = r0;
        reserve1 = r1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function bumpCumulative(uint256 p0, uint256 p1) external {
        price0CumulativeLast += p0;
        price1CumulativeLast += p1;
        blockTimestampLast = uint32(block.timestamp);
    }
}